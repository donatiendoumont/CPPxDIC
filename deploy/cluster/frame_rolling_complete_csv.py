#!/usr/bin/env python3
"""
frame_rolling_complete_csv.py - build a staged subject_trial CSV (frame indices only) from a
source CSV that lists subjects, trials and the phase(s) to track.

SOURCE CSV (never modified). Columns are recognised by their header name, in any order:
    subject, trial, phase, idx_frame_start, idx_frame_end, frame_jump
(aliases: start / end / jump). Only subject and trial are required. Without a header line the
order is subject,trial,idx_frame_start,idx_frame_end,frame_jump.

STEP 1 - expand the trial column (one row per trial). The cell may be:
      5            a single trial
      1:3          a range, inclusive            -> 1, 2, 3
      1:2:9        start:step:stop (Matlab-like) -> 1, 3, 5, 7, 9
      [1,2,7,8]    a list (brackets optional)    -> 1, 2, 7, 8
      [1:3,7,9:10] lists and ranges mixed        -> 1, 2, 3, 7, 9, 10
  A list written with commas must be in brackets or quoted when it is not the last field:
  `DD4_rolling,[1,2,7,8]` and `DD4_rolling,"1,2,7,8"` are both understood.
  The other cells of the row are copied on every expanded row.

STEP 2 - frame window of each (subject, trial) from the protocol .tsv of the subject, the
same way as the Matlab script get_protocol_frame_rolling:

    N_phase = floor(NrOfCycles[mov_phase] * FpsCam / 1e3)        (NrOfCycles = duration, ms)
    frames  = loading 1..N_loading, then slide, then relax, then unloading (consecutive)

  The `phase` cell chooses the phase(s): loading, slide (or sliding), relax, unloading, or a
  combination joined with '+', e.g. `slide+relax` (the default when the cell is empty, or
  --phase). A combination covers the first frame of the earliest phase to the last frame of
  the latest one; non-adjacent phases (e.g. loading+relax) include the phases between them
  and are reported with a warning. `all` = the four phases.

OUTPUT (the staged CSV) contains ONLY the index columns, ready for cppxdic:
    subject,trial,idx_frame_start,idx_frame_end,frame_jump
Frames are 1-based. frame_jump is never computed: it is copied from the `frame_jump` column of
the source CSV (an empty cell = the dic_params.txt value). Cells idx_frame_start/idx_frame_end
already filled in the source are kept as typed; --force overwrites them. The result goes to <csv>_staged.csv next to the source, or to
--output; the source CSV is never modified (unless --in-place, after a backup). With
--expand-only only step 1 is done (no protocol read; the phase column is kept).
Standard library only.

CHANGELOG
2026-11-17  created
2026-11-17  step 1: trial ranges/lists expanded to one row per trial; --expand-only
2026-11-17  result written to <csv>_staged.csv (source untouched); --in-place for the old way
2026-11-17  `phase` column (loading/slide/relax/unloading and combinations); columns read by
            header name; staged CSV keeps only the index columns
2026-11-17  --jump removed: frame_jump is set in the source CSV (empty = dic_params.txt)
"""

import argparse
import csv
import datetime
import glob
import math
import os
import re
import shutil
import sys

OUT_HEADER = ["subject", "trial", "idx_frame_start", "idx_frame_end", "frame_jump"]

# Row numbers (1-based, within the rows of one trial) of each movement, as in the Matlab script.
MOV = {"loading": 3, "slide": 4, "relax": 5, "unloading": 6}
ORDER = ["loading", "slide", "relax", "unloading"]
PHASE_ALIASES = {"loading": "loading", "load": "loading",
                 "slide": "slide", "sliding": "slide",
                 "relax": "relax", "relaxation": "relax",
                 "unloading": "unloading", "unload": "unloading"}

COLUMN_ALIASES = {"subject": "subject", "trial": "trial", "phase": "phase", "phases": "phase",
                  "idx_frame_start": "start", "start": "start",
                  "idx_frame_end": "end", "end": "end",
                  "frame_jump": "jump", "jump": "jump"}
POSITIONAL = ["subject", "trial", "start", "end", "jump"]


# --------------------------------------------------------------------------- step 1: trials
def expand_trials(cell):
    """'1:3' -> [1,2,3]; '[1,2,7,8]' -> [1,2,7,8]; '1:2:9' -> [1,3,5,7,9]; '5' -> [5]."""
    s = cell.strip().strip("\"'").replace("[", " ").replace("]", " ").strip()
    tokens = [t for t in re.split(r"[,;\s]+", s) if t]
    if not tokens:
        raise ValueError("empty trial cell")
    out = []
    for tok in tokens:
        parts = tok.split(":")
        try:
            nums = [int(p) for p in parts]
        except ValueError:
            raise ValueError(f"invalid trial '{tok}' in '{cell}'")
        if len(nums) == 1:
            out.append(nums[0])
        elif len(nums) in (2, 3):
            a, b = nums[0], nums[-1]
            step = nums[1] if len(nums) == 3 else (1 if b >= a else -1)
            if step == 0:
                raise ValueError(f"step 0 in '{tok}'")
            stop = b + (1 if step > 0 else -1)  # inclusive end, like Matlab a:s:b
            seq = list(range(a, stop, step))
            if not seq:
                raise ValueError(f"empty range '{tok}'")
            out.extend(seq)
        else:
            raise ValueError(f"invalid range '{tok}'")
    for t in out:
        if t < 1:
            raise ValueError(f"trial must be >= 1 (got {t} in '{cell}')")
    return out


def expand_rows(rows):
    """One output row per trial of each input row. Returns (new_rows, n_expanded_cells)."""
    new, n_exp = [], 0
    for r in rows:
        trials = expand_trials(r["trial"])
        if len(trials) > 1 or r["trial"].strip() != str(trials[0]):
            n_exp += 1
        for t in trials:
            nr = dict(r)
            nr["trial"] = str(t)
            new.append(nr)
    return new, n_exp


# --------------------------------------------------------------------------- phases
def parse_phases(cell, default):
    """'slide+relax' -> ['slide','relax'] (canonical order); '' -> default; 'all' -> all four."""
    s = (cell or "").strip().lower() or default.strip().lower()
    tokens = [t for t in re.split(r"[+/|&,;\s]+", s) if t]
    if not tokens:
        raise ValueError("empty phase")
    chosen = set()
    for t in tokens:
        if t == "all":
            chosen.update(ORDER)
        elif t in PHASE_ALIASES:
            chosen.add(PHASE_ALIASES[t])
        else:
            raise ValueError(f"unknown phase '{t}' (use loading, slide, relax, unloading, "
                             "joined with '+', or all)")
    return [p for p in ORDER if p in chosen]


# --------------------------------------------------------------------------- step 2: protocol
def find_protocol_file(args, subject):
    if args.protocol_file:
        return args.protocol_file
    pdir = args.protocol_dir_template.format(data_root=args.data_root, subject=subject,
                                             material=args.material)
    files = sorted(glob.glob(os.path.join(pdir, "*.tsv")))
    if len(files) != 1:
        raise RuntimeError(
            f"{len(files)} .tsv file(s) in {pdir} (expected exactly 1; "
            f"use --protocol-file or --protocol-dir-template)")
    return files[0]


def read_protocol(path):
    """Return a list of dict rows (tab-separated, header on the first line)."""
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows = [{k.strip(): (v or "").strip() for k, v in r.items() if k is not None}
                for r in reader]
        cols = [c.strip() for c in (reader.fieldnames or [])]
    need = ["TrialNo", "NrOfCycles", "FpsCam", "NbFrCam"]
    missing = [c for c in need if c not in cols]
    if missing:
        raise RuntimeError(f"column(s) {missing} missing in {path}; available: {cols}")
    return rows


def trial_window(rows, trial, phases):
    """Frame window of the chosen phase(s) of one trial. Mirrors the Matlab script."""
    tr = [r for r in rows if r["TrialNo"] != "" and int(float(r["TrialNo"])) == trial]
    if len(tr) < MOV["unloading"]:
        raise RuntimeError(
            f"trial {trial}: {len(tr)} protocol row(s), need at least {MOV['unloading']} movements")
    fps = float(tr[0]["FpsCam"])
    nfr_vid = int(float(tr[0]["NbFrCam"]))
    if not fps > 0:
        raise RuntimeError(f"trial {trial}: invalid FpsCam={tr[0]['FpsCam']}")
    dur = [float(r["NrOfCycles"]) for r in tr]  # ms, one value per movement

    n = {p: int(math.floor(dur[MOV[p] - 1] * fps / 1e3)) for p in ORDER}
    ranges, last = {}, 0
    for p in ORDER:  # consecutive phases, like idx_fr_* in the Matlab script
        ranges[p] = (last + 1, last + n[p])
        last += n[p]

    empty = [p for p in phases if n[p] <= 0]
    if empty:
        raise RuntimeError(f"trial {trial}: phase {'+'.join(empty)} has 0 frames "
                           f"(duration x fps too small)")
    idx = [ORDER.index(p) for p in phases]
    gap = idx != list(range(min(idx), max(idx) + 1))
    return {"start": min(ranges[p][0] for p in phases),
            "end": max(ranges[p][1] for p in phases),
            "n": n, "fps": fps, "nfr_vid": nfr_vid, "gap": gap}


# --------------------------------------------------------------------------- csv io
def read_csv(path):
    """Read the source CSV. Returns (rows as dicts, has_phase_column)."""
    with open(path, newline="", encoding="utf-8-sig") as f:
        lines = [ln for ln in csv.reader(f)]
    names, rows, unknown = None, [], []
    for ln in lines:
        if not ln or all(not c.strip() for c in ln):
            continue
        if ln[0].strip().startswith("#"):
            continue
        if names is None:
            if ln[0].strip().lower().startswith("subject"):
                raw = [c.strip() for c in ln]
                names = [COLUMN_ALIASES.get(c.lower()) for c in raw]
                unknown = [c for c, nm in zip(raw, names) if nm is None and c]
                if "subject" not in names or "trial" not in names:
                    sys.exit("ERROR: the header must contain 'subject' and 'trial'")
                continue
            names = list(POSITIONAL)
        # Unquoted bracket list such as DD4_rolling,[1,2,7,8],... was split on its commas:
        # glue the pieces back until the closing bracket.
        ti = names.index("trial")
        if ti < len(ln) and "[" in ln[ti] and "]" not in ln[ti]:
            for j in range(ti + 1, len(ln)):
                if "]" in ln[j]:
                    ln = ln[:ti] + [",".join(ln[ti:j + 1])] + ln[j + 1:]
                    break
        row = {k: "" for k in POSITIONAL + ["phase"]}
        for nm, cell in zip(names, ln):
            if nm:
                row[nm] = cell.strip()
        if not row["subject"] or not row["trial"]:
            sys.exit(f"ERROR: line without subject or trial: {','.join(ln)}")
        rows.append(row)
    if unknown:
        print(f"Note: ignored column(s) of the source CSV: {', '.join(unknown)}")
    return rows, bool(names) and "phase" in names


def staged_path(args):
    """Where the result goes: --output, else <name>_staged.csv next to the source CSV.
    The source file is left untouched (unless it is already named *_staged or --in-place)."""
    if args.output:
        return args.output
    if args.in_place:
        return args.csv
    stem, ext = os.path.splitext(args.csv)
    if stem.endswith("_staged"):
        return args.csv
    return f"{stem}_staged{ext or '.csv'}"


def write_csv(args, header, table):
    if args.dry_run:
        print(f"\n--dry-run: nothing written. {staged_path(args)} would contain:")
        for tr in [header] + table:
            print(",".join(tr))
        return
    target = staged_path(args)
    if os.path.abspath(target) == os.path.abspath(args.csv):
        # input is already the *_staged file (or --in-place): keep a backup of it
        bak = f"{args.csv}.bak_{datetime.date.today().isoformat()}"
        if not os.path.exists(bak):
            shutil.copy2(args.csv, bak)
            print(f"Backup: {bak}")
    tmp = target + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        csv.writer(f, lineterminator="\n").writerows([header] + table)
    os.replace(tmp, target)
    print(f"Written: {target}")


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--csv", required=True, help="source CSV (never modified)")
    ap.add_argument("--data-root", default=os.environ.get("DATA_ROOT", ""),
                    help="root of the raw data (default: $DATA_ROOT)")
    ap.add_argument("--protocol-dir-template",
                    default="{data_root}/{subject}/speckles/{material}/protocol",
                    help="folder holding the protocol .tsv; {data_root}, {subject} and "
                         "{material} are replaced (default: %(default)s)")
    ap.add_argument("--material", default="glass",
                    help="value of {material} in the template (default: %(default)s)")
    ap.add_argument("--protocol-file", help="explicit .tsv, used for every subject")
    ap.add_argument("--phase", default="slide+relax",
                    help="phase(s) for rows whose phase cell is empty or absent "
                         "(default: %(default)s)")
    ap.add_argument("--force", action="store_true",
                    help="overwrite idx_frame_start/idx_frame_end cells that are already filled "
                         "(frame_jump is never computed: it is copied from the source CSV)")
    ap.add_argument("--expand-only", action="store_true",
                    help="only expand trial ranges/lists into one row per trial "
                         "(no protocol is read; the phase column is kept)")
    ap.add_argument("--output", help="write here (default: <csv>_staged.csv; the source "
                                     "CSV is never modified)")
    ap.add_argument("--in-place", action="store_true",
                    help="rewrite the source CSV itself (after a .bak backup)")
    ap.add_argument("--dry-run", action="store_true", help="print the result, write nothing")
    ap.add_argument("--verbose", action="store_true",
                    help="also print the frames of each phase and the fps")
    args = ap.parse_args()

    if not args.expand_only and not args.protocol_file and not args.data_root:
        ap.error("give --data-root (or $DATA_ROOT), or --protocol-file, or use --expand-only")
    try:
        parse_phases("", args.phase)
    except ValueError as e:
        ap.error(f"--phase: {e}")

    rows, has_phase = read_csv(args.csv)
    if not rows:
        sys.exit(f"ERROR: no data rows in {args.csv}")

    # ---- step 1: one row per trial
    try:
        rows, n_exp = expand_rows(rows)
    except ValueError as e:
        sys.exit(f"ERROR: {e}; nothing written.")
    print(f"Step 1: {len(rows)} (subject, trial) row(s) after expansion"
          f" ({n_exp} trial cell(s) expanded).")
    if args.expand_only:
        cols = ["subject", "trial"] + (["phase"] if has_phase else []) + \
               ["idx_frame_start", "idx_frame_end", "frame_jump"]
        keys = ["subject", "trial"] + (["phase"] if has_phase else []) + ["start", "end", "jump"]
        for r in rows:
            print(f"  {r['subject']},{r['trial']}" + (f",{r['phase']}" if has_phase else ""))
        write_csv(args, cols, [[r[k] for k in keys] for r in rows])
        return

    # ---- step 2: frame window of the chosen phase(s) from the protocol
    cache, problems, summary, table = {}, 0, [], []
    for r in rows:
        subject = r["subject"]
        try:
            trial = int(r["trial"])
            phases = parse_phases(r["phase"], args.phase)
            if subject not in cache:
                pf = find_protocol_file(args, subject)
                cache[subject] = (pf, read_protocol(pf))
            pf, proto = cache[subject]
            w = trial_window(proto, trial, phases)
        except Exception as e:  # keep going: report every problem at the end
            problems += 1
            summary.append(f"  {subject},{r['trial']}: ERROR {e}")
            continue

        label = "+".join(phases)
        if w["gap"]:
            summary.append(f"  {subject},{trial} [{label}]: WARNING non-adjacent phases, the "
                           "window also includes the phases in between")
        if w["end"] > w["nfr_vid"]:
            summary.append(f"  {subject},{trial} [{label}]: WARNING end={w['end']} > "
                           f"NbFrCam={w['nfr_vid']} (cppxdic truncates to the video length)")
        new = {"start": str(w["start"]), "end": str(w["end"])}   # jump: from the source CSV
        kept = []
        for key, val in new.items():
            if r[key] == "" or args.force:
                r[key] = val
            elif r[key] != val:
                kept.append(f"{key}={r[key]} (protocol: {val})")
        note = f"  [kept by hand: {', '.join(kept)}]" if kept else ""
        detail = ("  (frames: " + " ".join(f"{p}={w['n'][p]}" for p in ORDER) +
                  f", fps={w['fps']:g})" if args.verbose else "")
        summary.append(f"  {subject},{trial} [{label}]: start={r['start']} end={r['end']} "
                       f"jump={r['jump'] or '(dic_params)'}{note}{detail}")
        table.append([subject, str(trial), r["start"], r["end"], r["jump"]])

    print(f"Step 2: protocol-based windows for {len(rows)} row(s):")
    print("\n".join(summary))
    if problems:
        sys.exit(f"ERROR: {problems} row(s) could not be computed; nothing written.")
    write_csv(args, OUT_HEADER, table)


if __name__ == "__main__":
    main()
