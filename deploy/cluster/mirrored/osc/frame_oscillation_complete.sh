#!/bin/bash
# frame_oscillation_complete.sh - fill idx_frame_start / idx_frame_end of subject_trial.csv for the
# OSCILLATION project, by calling frame_oscillation_complete.py (which needs
# frame_standard_complete.py, in this folder or in deploy/cluster).
#
# Usage:
#   ./frame_oscillation_complete.sh [csv] [extra options]
#     csv   : subject_trial.csv to complete   (required, no default)
#   Data folder: $DATA_ROOT, else $DATA_DIR/rawdata (DATA_DIR is already exported).
#   Extra options are passed to the Python script (--dry-run, --force, --verbose, --phase ...).
#   frame_jump is NOT an option: write it in the `frame_jump` column of the CSV
#   (an empty cell = the value of dic_params.txt).
#
# Examples:
#   ./frame_oscillation_complete.sh $PROJECT_DIR/subject_trial.csv
#   ./frame_oscillation_complete.sh $PROJECT_DIR/subject_trial.csv --dry-run --verbose
#   ./frame_oscillation_complete.sh my.csv --phase 3+osc  # loading + oscillation where empty
#
# SOURCE CSV (never modified), columns read by header name:
#   subject,trial[,phase][,nbr_osc][,idx_frame_start,idx_frame_end,frame_jump]
#   - trial   : 5 | 1:3 | 1:2:9 | [1,2,7,8] | [1:3,7]  -> expanded to one row per trial
#   - phase   : MovNo to keep: 4 | 3+4 | 3:5 ; the word `osc` = the oscillation movement (the
#               one with Relative = 2). Empty cell = --phase (default: osc).
#   - nbr_osc : number of oscillations to keep (empty = Nosc of the protocol, i.e. all). The
#               oscillation movement lasts NrOfCycles * Nosc ms; with nbr_osc < Nosc the window
#               stops after NrOfCycles * nbr_osc ms, which requires the oscillation movement to be
#               the last movement of the window (phase=osc or 3+osc, not osc+5).
#   - frame_jump : copied as is to the staged CSV
# The result goes to <csv>_staged.csv (next to the source) and contains ONLY the index
# columns: subject,trial,idx_frame_start,idx_frame_end,frame_jump. (Details: docstring of
# frame_oscillation_complete.py.)
#
# Protocol folder searched per subject: ${DATA_ROOT}/<subject>/speckles/<MATERIAL>/protocol/*.tsv
# (same default as the rolling script, i.e. once the oscillation data are staged like rolling).
# Not staged yet? Point to the raw data tree, which has no speckles/<material> level:
#   DATA_ROOT=$GLOBALSCRATCH/data/slip_and_roll \
#   PROTOCOL_DIR_TEMPLATE='{data_root}/{subject}/protocol' ./frame_oscillation_complete.sh ...
#
# CHANGELOG
# 2026-11-18  created from frame_rolling_complete_csv.sh
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

python3 "${HERE}/frame_oscillation_complete.py" \
    --csv "${CSV}" \
    --data-root "${DATA_ROOT}" \
    --protocol-dir-template "${TEMPLATE}" \
    --material "${MATERIAL}" \
    "$@"
