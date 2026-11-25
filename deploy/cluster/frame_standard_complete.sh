#!/bin/bash
# frame_standard_complete.sh - fill idx_frame_start / idx_frame_end of subject_trial.csv from
# the protocol .tsv for the movement numbers (MovNo) listed in the `phase` column, by calling
# frame_standard_complete.py. Protocol-independent version of frame_rolling_complete_csv.sh.
#
# Usage:
#   ./frame_standard_complete.sh [csv] [extra options]
#     csv   : subject_trial.csv to complete   (required, no default)
#   Data folder: $DATA_ROOT, else $DATA_DIR/rawdata (DATA_DIR is already exported).
#   Extra options are passed to the Python script (--dry-run, --force, --verbose, --phase ...).
#   frame_jump is NOT an option: write it in the `frame_jump` column of the CSV
#   (an empty cell = the value of dic_params.txt).
#
# Examples:
#   ./frame_standard_complete.sh $PROJECT_DIR/subject_trial.csv
#   ./frame_standard_complete.sh $PROJECT_DIR/subject_trial.csv --dry-run             # preview, writes nothing
#   ./frame_standard_complete.sh my.csv --phase 4+5       # movements 4 and 5 where phase is empty
#
# SOURCE CSV (never modified), columns read by header name:
#   subject,trial[,phase][,idx_frame_start,idx_frame_end,frame_jump]
#   - trial : 5 | 1:3 | 1:2:9 | [1,2,7,8] | [1:3,7]  -> expanded to one row per trial
#   - phase : MovNo of the protocol to keep: 4 | 3+4+5 | 3:5  (aliases of the header: mov, mvt,
#             movement). The window goes from the first frame of the earliest movement to the
#             last frame of the latest one. Empty cell = --phase (error if there is none).
#   - frame_jump : copied as is to the staged CSV
# The video holds the movements with TrigCam = 1; frames = floor(NrOfCycles * FpsCam / 1e3) per
# movement, consecutive and 1-based (see the docstring of frame_standard_complete.py).
# The result goes to <csv>_staged.csv (next to the source) and contains ONLY the index
# columns: subject,trial,idx_frame_start,idx_frame_end,frame_jump. Cells idx_frame_start/end
# already filled in the source are kept as typed (--force overwrites). --expand-only does only
# the trial expansion (no protocol read, phase column kept).
#
# Protocol folder searched per subject: ${DATA_ROOT}/<subject>/speckles/<MATERIAL>/protocol/*.tsv
# with MATERIAL=glass by default, e.g.
#   DATA_ROOT=.../data_staged/slip_and_roll/rawdata
#   -> .../rawdata/DD4_rolling/speckles/glass/protocol/*.tsv
# (change with MATERIAL=... or PROTOCOL_DIR_TEMPLATE='{data_root}/{subject}/...').
#
# CHANGELOG
# 2026-11-18  created from frame_rolling_complete_csv.sh (movement numbers instead of phase names)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The CSV is required (no default) and must come BEFORE any --option.
CSV=""
if [[ $# -gt 0 && "$1" != --* ]]; then CSV="$1"; shift; fi
: "${CSV:?give the source CSV: $(basename "$0") <csv> [options]}"

# Raw-data folder: $DATA_ROOT if set, otherwise $DATA_DIR/rawdata (DATA_DIR is already exported
# in the shell: .../data_staged/$PROJECT_NAME).
DATA_ROOT="${DATA_ROOT:-${DATA_DIR:+${DATA_DIR}/rawdata}}"
# The data folder is not needed when only expanding trial ranges (--expand-only).
if [[ " $* " != *" --expand-only "* ]]; then
    : "${DATA_ROOT:?set DATA_DIR (or DATA_ROOT) to the data folder}"
fi
DEFAULT_TEMPLATE='{data_root}/{subject}/speckles/{material}/protocol'
TEMPLATE="${PROTOCOL_DIR_TEMPLATE:-$DEFAULT_TEMPLATE}"
MATERIAL="${MATERIAL:-glass}"

python3 "${HERE}/frame_standard_complete.py" \
    --csv "${CSV}" \
    --data-root "${DATA_ROOT}" \
    --protocol-dir-template "${TEMPLATE}" \
    --material "${MATERIAL}" \
    "$@"
