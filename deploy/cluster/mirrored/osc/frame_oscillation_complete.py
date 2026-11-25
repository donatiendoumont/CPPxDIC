#!/usr/bin/env python3
"""
frame_oscillation_complete.py - build a staged subject_trial CSV (frame indices only) for the
OSCILLATION project. Same as frame_standard_complete.py (movement numbers in the `phase` column,
trials expanded, source CSV never modified), plus the number of oscillations to keep.

SOURCE CSV columns (by header name, any order):
    subject, trial, phase, nbr_osc, idx_frame_start, idx_frame_end, frame_jump
  phase    MovNo of the protocol to keep: 4 | 3+4 | 3:5 | 3+osc ... ('osc' = the oscillation
           movement; an empty cell = --phase, default 'osc'). Same syntax as the standard script.
  nbr_osc  number of oscillations to keep (optional). Empty = all the oscillations of the
           protocol, i.e. the Nosc column of the protocol (read on the first row of the trial).

THE OSCILLATION MOVEMENT is the one whose Relative = 2 in the protocol (exactly one per trial;
not hard-coded to MovNo 4). Its NrOfCycles is the duration of ONE oscillation (ms), so, as in
the Matlab get_protocol_frame_rolling:
    N(osc movement)  = floor(NrOfCycles * Nosc * FpsCam / 1e3)     frames in the video
    N(other movement) = floor(NrOfCycles * FpsCam / 1e3)
    frames are 1-based and consecutive over the movements with TrigCam = 1
    (e.g. NrOfCycles=3770, Nosc=10, FpsCam=50 -> 1885 frames for the oscillation movement).
  With nbr_osc < Nosc the window of the oscillation movement stops after
    floor(NrOfCycles * nbr_osc * FpsCam / 1e3) frames from its first frame. The movements AFTER
  the oscillation still start after all Nosc oscillations (that is where they really are in the
  video), so nbr_osc < Nosc is only accepted when the oscillation movement is the LAST movement
  of the window (e.g. phase = 3+osc, not osc+5).
  nbr_osc greater than Nosc is an error; nbr_osc is ignored (with a warning) when the oscillation
  movement is not in the window.

OUTPUT: subject,trial,idx_frame_start,idx_frame_end,frame_jump  (<csv>_staged.csv). frame_jump
is copied from the source CSV (empty = dic_params.txt). See frame_standard_complete.py for the
trial syntax (5, 1:3, [1,2,7,8]), --force, --expand-only, --dry-run, --verbose, --output.
Needs frame_standard_complete.py (in this folder or in deploy/cluster, two folders up).
Standard library only.

Protocol folder (default template of the standard script; the oscillation data are usually NOT
under speckles/<material>), e.g.:
    --data-root $GLOBALSCRATCH/data/slip_and_roll \\
    --protocol-dir-template '{data_root}/{subject}/protocol'

CHANGELOG
2026-11-18  created (Relative=2 oscillation movement, nbr_osc, Nosc from the protocol)
"""

import math
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                              # same folder
sys.path.insert(1, os.path.join(_HERE, "..", ".."))      # deploy/cluster
import frame_standard_complete as std  # noqa: E402

OSC_COLUMNS = std.BASE_PROTOCOL_COLUMNS + ["Nosc", "Relative"]


def oscillation_window(proto, trial, row, args):
    tr = std.trial_rows(proto, trial)
    osc_rows = [r for r in tr if float(r["Relative"] or 0) == 2]
    if len(osc_rows) != 1:
        raise RuntimeError(f"{len(osc_rows)} movement(s) with Relative = 2 (expected exactly 1)")
    orow = osc_rows[0]
    omov = orow["_mov"]
    if float(orow["TrigCam"] or 0) != 1:
        raise RuntimeError(f"oscillation movement {omov} has TrigCam != 1 (not in the video)")
    nosc = int(float(tr[0]["Nosc"] or 0))        # Matlab: Nosc = t_trial.Nosc(1)
    if nosc < 1:
        raise RuntimeError(f"invalid Nosc={tr[0]['Nosc']!r} on the first row of the trial")

    cell = (row.get("nbr_osc") or "").strip()
    if cell == "":
        nbr = nosc
    else:
        try:
            f = float(cell)
        except ValueError:
            raise RuntimeError(f"nbr_osc must be a whole number (got '{cell}')")
        if f != int(f) or f < 1:
            raise RuntimeError(f"nbr_osc must be a whole number >= 1 (got '{cell}')")
        nbr = int(f)
        if nbr > nosc:
            raise RuntimeError(f"nbr_osc={nbr} is larger than Nosc={nosc} of the protocol")

    text = (row["phase"] or "").strip() or (args.phase or "")
    movs = std.parse_movs(re.sub(r"\bosc\b", str(omov), text, flags=re.IGNORECASE))

    layout = std.build_layout(tr, repeat=lambda r: nosc if r is orow else 1)
    w = std.window_from_movs(layout, movs)
    warnings = []
    if omov in movs:
        if nbr < nosc:
            if omov != max(movs):
                raise RuntimeError(
                    f"nbr_osc={nbr} < Nosc={nosc} needs the oscillation movement ({omov}) to be "
                    f"the last movement of the window (phase={text})")
            seg = next(s for s in layout["seq"] if s["mov"] == omov)
            n_keep = int(math.floor(float(orow["NrOfCycles"]) * nbr * layout["fps"] / 1e3))
            if n_keep < 1:
                raise RuntimeError(f"nbr_osc={nbr} gives 0 frames (duration x fps too small)")
            w["end"] = seg["start"] + n_keep - 1
    elif cell != "":
        warnings.append(f"nbr_osc={cell} ignored: the oscillation movement ({omov}) is not in "
                        f"the window (phase={text})")
    w.update(movs=movs, layout=layout, warnings=warnings,
             label="mov " + "+".join(map(str, movs)) + f"; osc=mov{omov} {nbr}/{nosc}")
    return w


def main():
    ap = std.make_parser(__doc__.split("\n\n")[0], phase_default="osc",
                         phase_help="('osc' = the oscillation movement, Relative = 2)")
    args = ap.parse_args()
    try:
        std.parse_movs(re.sub(r"\bosc\b", "1", args.phase, flags=re.IGNORECASE))
    except ValueError as e:
        ap.error(f"--phase: {e}")
    std.run_pipeline(args, ap, oscillation_window, OSC_COLUMNS, extra_cols=["nbr_osc"])


if __name__ == "__main__":
    main()
