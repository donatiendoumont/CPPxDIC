#!/usr/bin/env python3
"""
frame_standard_complete.py - build a staged subject_trial CSV (frame indices only) from a source
CSV that lists subjects, trials and the protocol MOVEMENT NUMBERS to track. General version of
frame_rolling_complete_csv.py: no phase names (loading, slide, ...), only the movement numbers
(column MovNo of the protocol .tsv), so any protocol can be used.

SOURCE CSV (never modified). Columns are recognised by their header name, in any order:
    subject, trial, phase, idx_frame_start, idx_frame_end, frame_jump
(aliases of `phase`: mov, mvt, movement, movements; of the others: start / end / jump).
Only subject, trial and (here or in --phase) the movements are required. Without a header line
the order is subject,trial,idx_frame_start,idx_frame_end,frame_jump.

STEP 1 - expand the trial column (one row per trial). The cell may be:
      5            a single trial
      1:3          a range, inclusive            -> 1, 2, 3
      1:2:9        start:step:stop (Matlab-like) -> 1, 3, 5, 7, 9
      [1,2,7,8]    a list (brackets optional)    -> 1, 2, 7, 8
      [1:3,7,9:10] lists and ranges mixed        -> 1, 2, 3, 7, 9, 10
  A list written with commas must be in brackets or quoted when it is not the last field.
  The other cells of the row are copied on every expanded row.

STEP 2 - frame window of each (subject, trial) from the protocol .tsv of the subject.
  The `phase` cell lists the MovNo values to keep:
      4            one movement
      3+4+5        several movements, joined with '+'   (',' or ';' also work inside quotes)
      3:5          a range, inclusive -> 3, 4, 5
  The window runs from the first frame of the earliest movement to the last frame of the latest
  one. Movements that are not adjacent in the video include the ones in between (a warning is
  printed). An empty cell uses --phase (error if there is none).

  How frames are counted (same rule as the Matlab get_protocol_frame_*):
    - the video contains, in protocol order, the movements whose TrigCam = 1;
    - N(mov) = floor(NrOfCycles[mov] * FpsCam / 1e3)   (NrOfCycles = duration in ms,
      FpsCam read on the first row of the trial);
    - frames are consecutive and 1-based: movement k starts after the frames of the previous
      recorded movements. The sum of N is compared with NbFrCam (a warning when far apart).
  A movement with TrigCam != 1 is not in the video: asking for it is an error.

OUTPUT (the staged CSV) contains ONLY the index columns, ready for cppxdic:
    subject,trial,idx_frame_start,idx_frame_end,frame_jump
Frames are 1-based. frame_jump is never computed: it is copied from the `frame_jump` column of
the source CSV (an empty cell = the dic_params.txt value). Cells idx_frame_start/idx_frame_end
already filled in the source are kept as typed; --force overwrites them. The result goes to
<csv>_staged.csv next to the source, or to --output; the source CSV is never modified (unless
--in-place, after a backup). With --expand-only only step 1 is done (no protocol read).
Standard library only. frame_oscillation_complete.py imports this file (from its own folder or from here).

Protocol folder searched per subject (change with --protocol-dir-template or --protocol-file):
    {data_root}/{subject}/speckles/{material}/protocol/*.tsv     (exactly one .tsv)

CHANGELOG
2026-11-18  created from frame_rolling_complete_csv.py: movement numbers instead of phase names,
            recorded movements = TrigCam 1, shared pipeline reused by the oscillation script
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

COLUMN_ALIASES = {"subject": "subject", "trial": "trial",
                  "phase": "phase", "phases": "phase", "mov": "phase", "mvt": "phase",
                  "movement": "phase", "movements": "phase",
                  "idx_frame_start": "start", "start": "start",
                  "idx_frame_end": "end", "end": "end",
                  "frame_jump": "jump", "jump": "jump"}
POSITIONAL = ["subject", "trial", "start", "end", "jump"]
BASE_PROTOCOL_COLUMNS = ["TrialNo", "MovNo", "NrOfCycles", "FpsCam", "NbFrCam", "TrigCam"]


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


# --------------------------------------------------------------------------- movements
def parse_movs(cell, default=""):
    """'3+4+5' -> [3,4,5]; '3:5' -> [3,4,5]; '4' -> [4]. Empty cell -> default, else error."""
    s = (cell or "").strip().strip("\"'") or (default or "").strip()
    if not s:
        raise ValueError("no movement given (fill the phase cell or use --phase)")
    s = s.replace("[", " ").replace("]", " ")
    tokens = [t for t in re.split(r"[+,;|&/\s]+", s) if t]
    out = set()
    for tok in tokens:
        try:
            nums = [int(p) for p in tok.split(":")]
        except ValueError:
            raise ValueError(f"invalid movement '{tok}' in '{cell}' (use numbers, '+' and ':')")
        if len(nums) == 1:
            out.add(nums[0])
        elif len(nums) == 2 and nums[1] >= nums[0]:
            out.update(range(nums[0], nums[1] + 1))
        else:
            raise ValueError(f"invalid movement range '{tok}'")
    if not out or min(out) < 1:
        raise ValueError(f"movement numbers must be >= 1 (got '{s}')")
    return sorted(out)


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


def read_protocol(path, need):
    """Return a list of dict rows (tab-separated, header on the first line)."""
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows = [{k.strip(): (v or "").strip() for k, v in r.items() if k is not None}
                for r in reader]
        cols = [c.strip() for c in (reader.fieldnames or [])]
    missing = [c for c in need if c not in cols]
    if missing:
        raise RuntimeError(f"column(s) {missing} missing in {path}; available: {cols}")
    return rows


def trial_rows(rows, trial):
    """Protocol rows (movements) of one trial, in file order, with the integer MovNo in '_mov'."""
    tr = [r for r in rows if r["TrialNo"] != "" and int(float(r["TrialNo"])) == trial]
    if not tr:
        raise RuntimeError(f"trial {trial} is not in the protocol")
    seen = set()
    for r in tr:
        r["_mov"] = int(float(r["MovNo"]))
        if r["_mov"] in seen:
            raise RuntimeError(f"trial {trial}: MovNo {r['_mov']} appears twice in the protocol")
        seen.add(r["_mov"])
    return tr


def build_layout(tr, repeat=None):
    """Consecutive frame ranges of the recorded movements (TrigCam = 1) of one trial.
    repeat(row) -> factor applied to NrOfCycles (default 1; the oscillation script uses Nosc)."""
    fps = float(tr[0]["FpsCam"] or 0)
    nfr_vid = int(float(tr[0]["NbFrCam"] or 0))
    if not fps > 0:
        raise RuntimeError(f"invalid FpsCam={tr[0]['FpsCam']!r} on the first row of the trial")
    seq, last = [], 0
    for r in tr:
        if float(r["TrigCam"] or 0) != 1:
            continue
        dur = float(r["NrOfCycles"]) * (repeat(r) if repeat else 1)   # ms
        n = int(math.floor(dur * fps / 1e3))
        seq.append({"mov": r["_mov"], "start": last + 1, "end": last + n, "n": n, "row": r})
        last += n
    if not seq:
        raise RuntimeError("no movement with TrigCam = 1 in this trial")
    return {"seq": seq, "fps": fps, "nfr_vid": nfr_vid, "total": last}


def window_from_movs(layout, movs):
    """Frame window covering the chosen movements: (start, end, gap)."""
    seq = layout["seq"]
    pos = {s["mov"]: i for i, s in enumerate(seq)}
    missing = [m for m in movs if m not in pos]
    if missing:
        raise RuntimeError(f"movement(s) {missing} are not in the video (TrigCam != 1 or absent); "
                           f"recorded movements: {[s['mov'] for s in seq]}")
    idx = sorted(pos[m] for m in movs)
    empty = [seq[i]["mov"] for i in idx if seq[i]["n"] <= 0]
    if empty:
        raise RuntimeError(f"movement(s) {empty} have 0 frames (duration x fps too small)")
    return {"start": seq[idx[0]]["start"], "end": seq[idx[-1]]["end"],
            "gap": idx != list(range(idx[0], idx[-1] + 1))}


def standard_window(proto, trial, row, args):
    movs = parse_movs(row["phase"], args.phase)
    layout = build_layout(trial_rows(proto, trial))
    w = window_from_movs(layout, movs)
    w.update(movs=movs, label="mov " + "+".join(map(str, movs)), layout=layout, warnings=[])
    return w


# --------------------------------------------------------------------------- csv io
def read_csv(path, extra_cols=()):
    """Read the source CSV. Returns (rows as dicts, set of recognised column names)."""
    aliases = dict(COLUMN_ALIASES)
    aliases.update({c: c for c in extra_cols})
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
                names = [aliases.get(c.lower()) for c in raw]
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
        row = {k: "" for k in POSITIONAL + ["phase"] + list(extra_cols)}
        for nm, cell in zip(names, ln):
            if nm:
                row[nm] = cell.strip()
        if not row["subject"] or not row["trial"]:
            sys.exit(f"ERROR: line without subject or trial: {','.join(ln)}")
        rows.append(row)
    if unknown:
        print(f"Note: ignored column(s) of the source CSV: {', '.join(unknown)}")
    return rows, set(n for n in (names or []) if n)


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
def make_parser(description, phase_default=None, phase_help=""):
    ap = argparse.ArgumentParser(description=description)
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
    ap.add_argument("--phase", default=phase_default,
                    help="movement number(s) for rows whose phase cell is empty or absent"
                         + (" " + phase_help if phase_help else "")
                         + ("" if phase_default is None else " (default: %(default)s)"))
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
                    help="also print the frames of each recorded movement and the fps")
    return ap


def run_pipeline(args, ap, window_fn, protocol_columns, extra_cols=()):
    """Shared by frame_standard_complete.py and frame_oscillation_complete.py.
    window_fn(proto_rows, trial, csv_row, args) -> dict with start, end, gap, label, layout,
    warnings (list of str)."""
    if not args.expand_only and not args.protocol_file and not args.data_root:
        ap.error("give --data-root (or $DATA_ROOT), or --protocol-file, or use --expand-only")

    rows, cols = read_csv(args.csv, extra_cols)
    if not rows:
        sys.exit(f"ERROR: no data rows in {args.csv}")
    has_phase = "phase" in cols

    # ---- step 1: one row per trial
    try:
        rows, n_exp = expand_rows(rows)
    except ValueError as e:
        sys.exit(f"ERROR: {e}; nothing written.")
    print(f"Step 1: {len(rows)} (subject, trial) row(s) after expansion"
          f" ({n_exp} trial cell(s) expanded).")
    if args.expand_only:
        keep_extra = [c for c in extra_cols if c in cols]
        names = ["subject", "trial"] + (["phase"] if has_phase else []) + keep_extra + \
                ["start", "end", "jump"]
        heads = ["subject", "trial"] + (["phase"] if has_phase else []) + keep_extra + \
                ["idx_frame_start", "idx_frame_end", "frame_jump"]
        for r in rows:
            print("  " + ",".join(r[k] for k in names[:2 + (1 if has_phase else 0) + len(keep_extra)]))
        write_csv(args, heads, [[r[k] for k in names] for r in rows])
        return

    # ---- step 2: frame window from the protocol
    cache, problems, summary, table = {}, 0, [], []
    for r in rows:
        subject = r["subject"]
        try:
            trial = int(r["trial"])
            if subject not in cache:
                pf = find_protocol_file(args, subject)
                cache[subject] = (pf, read_protocol(pf, protocol_columns))
            pf, proto = cache[subject]
            w = window_fn(proto, trial, r, args)
        except Exception as e:  # keep going: report every problem at the end
            problems += 1
            summary.append(f"  {subject},{r['trial']}: ERROR {e}")
            continue

        label, lay = w["label"], w["layout"]
        for msg in w.get("warnings", []):
            summary.append(f"  {subject},{trial} [{label}]: WARNING {msg}")
        if w["gap"]:
            summary.append(f"  {subject},{trial} [{label}]: WARNING non-adjacent movements, the "
                           "window also includes the movements in between")
        if w["end"] > lay["nfr_vid"] > 0:
            summary.append(f"  {subject},{trial} [{label}]: WARNING end={w['end']} > "
                           f"NbFrCam={lay['nfr_vid']} (cppxdic truncates to the video length)")
        if lay["nfr_vid"] > 0 and abs(lay["total"] - lay["nfr_vid"]) > max(5, 0.02 * lay["nfr_vid"]):
            summary.append(f"  {subject},{trial} [{label}]: WARNING the recorded movements add "
                           f"up to {lay['total']} frames but NbFrCam={lay['nfr_vid']}: check "
                           "which movements have TrigCam=1")
        new = {"start": str(w["start"]), "end": str(w["end"])}   # jump: from the source CSV
        kept = []
        for key, val in new.items():
            if r[key] == "" or args.force:
                r[key] = val
            elif r[key] != val:
                kept.append(f"{key}={r[key]} (protocol: {val})")
        note = f"  [kept by hand: {', '.join(kept)}]" if kept else ""
        detail = ""
        if args.verbose:
            detail = ("  (frames: " + " ".join(f"mov{s['mov']}={s['n']}" for s in lay["seq"]) +
                      f"; total={lay['total']} NbFrCam={lay['nfr_vid']} fps={lay['fps']:g})")
        summary.append(f"  {subject},{trial} [{label}]: start={r['start']} end={r['end']} "
                       f"jump={r['jump'] or '(dic_params)'}{note}{detail}")
        table.append([subject, str(trial), r["start"], r["end"], r["jump"]])

    print(f"Step 2: protocol-based windows for {len(rows)} row(s):")
    print("\n".join(summary))
    if problems:
        sys.exit(f"ERROR: {problems} row(s) could not be computed; nothing written.")
    write_csv(args, OUT_HEADER, table)


def main():
    ap = make_parser(__doc__.split("\n\n")[0])
    args = ap.parse_args()
    if args.phase is not None:
        try:
            parse_movs("", args.phase)
        except ValueError as e:
            ap.error(f"--phase: {e}")
    run_pipeline(args, ap, standard_window, BASE_PROTOCOL_COLUMNS)


if __name__ == "__main__":
    main()
