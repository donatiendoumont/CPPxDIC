#!/bin/bash
# =============================================================================
# submit_csv.sh - prepare the trial CSV and give you the two values your sbatch line needs:
#   CSV = absolute path of the staged CSV   (subject,trial,idx_frame_start,idx_frame_end,frame_jump)
#   N   = number of data rows = number of array tasks
# Resources (--cpus-per-task, --mem, --time) stay on YOUR sbatch line.
#
# Steps: ${FRAME_SCRIPT}  <source csv>  ->  <csv>_staged.csv, then N = its rows.
# FRAME_SCRIPT = the script that computes the frame window of each trial. It is set (full path)
# by the project.env of the project (source mirrored/<project>/project.env), so
# there is nothing to choose by hand. It is required: without it the script stops.
# N must be known BEFORE sbatch (the array size is fixed at submission).
#
# Use it with `source` so that CSV and N are set in your shell:
#     source ~/CPPxDIC/deploy/cluster/submit_csv.sh $PROJECT_DIR/subject_trial.csv
#     sbatch --array=1-${N} --cpus-per-task=8 --mem=16G --time=02:00:00 \
#            --export=ALL,SUBJECT_TRIAL_CSV=$CSV,WORKDIR=$CONFIG_DIR \
#            deploy/cluster/run_subject_trial_array.sbatch
# (Run directly, `./submit_csv.sh ...` prepares the CSV and prints CSV and N, but cannot set
#  them in your shell.)
#
# Arguments: <csv> [options of ${FRAME_SCRIPT}, e.g. --dry-run --force --phase 4+5]
#   csv   source CSV (required, no default). The source is never modified.
#   frame_jump: write it in the `frame_jump` column of the CSV (empty = dic_params.txt).
#
# Needs: the project variables (source mirrored/<project>/project.env first).
# Nothing is deleted. Does not submit anything.
#
# CHANGELOG
# 2026-11-17  created as submit_subject_trial_csv.sh (prepared + submitted)
# 2026-11-17  renamed submit_csv.sh: only the CSV part; resources stay on the sbatch line
# 2026-11-18  FRAME_SCRIPT variable: choose the frame-window script (rolling by default,
#             standard or oscillation)
# 2026-11-18  project folders: no default CSV (it must be given); FRAME_SCRIPT must
#             be set (by the project.env of the project)
# =============================================================================

# Sourced or executed? (no `set -e` here: it must not close the user's shell)
_sc_sourced=0
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && _sc_sourced=1

_sc_main() {
    local here csv staged n frame_script
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # script that computes the frame window of each trial (bare name = next to this script)
    if [[ -z "${FRAME_SCRIPT:-}" ]]; then
        echo "ERROR: FRAME_SCRIPT is not set: source mirrored/<project>/project.env first" >&2; return 1
    fi
    frame_script="${FRAME_SCRIPT}"
    case "${frame_script}" in /*|./*|../*) ;; *) frame_script="${here}/${frame_script}" ;; esac
    if [[ ! -x "${frame_script}" ]]; then
        echo "ERROR: FRAME_SCRIPT not found or not executable: ${frame_script}" >&2; return 1
    fi

    if [[ -z "${CONFIG_DIR:-}" ]]; then echo "ERROR: CONFIG_DIR is not set: source mirrored/<project>/project.env first" >&2; return 1; fi

    # no default CSV: it must be given (e.g. $PROJECT_DIR/subject_trial.csv)
    csv=""
    if [[ $# -gt 0 && "$1" != --* ]]; then csv="$1"; shift; fi
    if [[ -z "${csv}" ]]; then
        echo "ERROR: give the source CSV: source submit_csv.sh <csv> [options]" >&2; return 1
    fi
    if [[ ! -f "${csv}" ]]; then echo "ERROR: CSV not found: ${csv}" >&2; return 1; fi
    csv="$(cd "$(dirname "${csv}")" && pwd)/$(basename "${csv}")"   # absolute: the sbatch does cd WORKDIR

    # 1. staged CSV (a failure here stops everything before any job is submitted)
    echo "Frame script: ${frame_script}"
    "${frame_script}" "${csv}" "$@" || return 1
    if [[ "${csv}" == *_staged.csv ]]; then staged="${csv}"; else staged="${csv%.csv}_staged.csv"; fi
    if [[ " $* " == *" --dry-run "* ]]; then
        echo "(--dry-run: nothing written, CSV and N not set)"; return 0
    fi
    if [[ ! -f "${staged}" ]]; then echo "ERROR: staged CSV not found: ${staged}" >&2; return 1; fi

    # 2. number of tasks = data rows (no header, comment or blank line)
    n=$(grep -vcE '^\s*(#|"?subject"?,|$)' "${staged}")
    if [[ "${n}" -lt 1 ]]; then echo "ERROR: no data row in ${staged}" >&2; return 1; fi

    CSV="${staged}"
    N="${n}"
    echo "CSV=${CSV}"
    echo "N=${N}"
    return 0
}

_sc_main "$@"
_sc_rc=$?
unset -f _sc_main
if [[ ${_sc_sourced} -eq 1 ]]; then
    unset _sc_sourced
    return ${_sc_rc}
else
    exit ${_sc_rc}
fi
