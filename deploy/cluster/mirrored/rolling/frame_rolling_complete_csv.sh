#!/bin/bash
# frame_rolling_complete_csv.sh - fill idx_frame_start / idx_frame_end of subject_trial.csv from
# the protocol .tsv (slide + relax phases by default), by calling frame_rolling_complete_csv.py.
#
# Usage:
#   ./frame_rolling_complete_csv.sh [csv] [extra options]
#     csv   : subject_trial.csv to complete   (required, no default)
#   Data folder: $DATA_ROOT, else $DATA_DIR/rawdata (DATA_DIR is already exported).
#   Extra options are passed to the Python script (--dry-run, --force, --verbose, --phase ...).
#   frame_jump is NOT an option: write it in the `frame_jump` column of the CSV
#   (an empty cell = the value of dic_params.txt).
#
# Examples:
#   ./frame_rolling_complete_csv.sh $PROJECT_DIR/subject_trial.csv
#   ./frame_rolling_complete_csv.sh $PROJECT_DIR/subject_trial.csv --dry-run          # preview, writes nothing
#   ./frame_rolling_complete_csv.sh my.csv --verbose      # another CSV
#
# SOURCE CSV (never modified), columns read by header name:
#   subject,trial[,phase][,idx_frame_start,idx_frame_end,frame_jump]
#   - trial : 5 | 1:3 | 1:2:9 | [1,2,7,8] | [1:3,7]  -> expanded to one row per trial
#   - phase : loading | slide (sliding) | relax | unloading | combination with '+',
#             e.g. slide+relax (default when empty, or --phase) | all
#   - frame_jump : copied as is to the staged CSV
# The result goes to <csv>_staged.csv (next to the source) and contains ONLY the index
# columns: subject,trial,idx_frame_start,idx_frame_end,frame_jump. Cells idx_frame_start/end
# already filled in the source are kept as typed (--force overwrites). --expand-only does only
# the trial expansion (no protocol read, phase column kept).
#
# Protocol folder searched per subject: ${DATA_ROOT}/<subject>/speckles/<MATERIAL>/protocol/*.tsv
# with MATERIAL=glass by default, e.g.
#   DATA_ROOT=.../data_staged/slip_and_roll_rolling/rawdata
#   -> .../rawdata/DD4_rolling/speckles/glass/protocol/*.tsv
# (change with MATERIAL=... or PROTOCOL_DIR_TEMPLATE='{data_root}/{subject}/...').
#
# CHANGELOG
# 2026-11-17  created
# 2026-11-17  jump = 2nd positional argument (default 1); compact output
# 2026-11-17  jump removed: set frame_jump in the CSV instead
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

python3 "${HERE}/frame_rolling_complete_csv.py" \
    --csv "${CSV}" \
    --data-root "${DATA_ROOT}" \
    --protocol-dir-template "${TEMPLATE}" \
    --material "${MATERIAL}" \
    "$@"
