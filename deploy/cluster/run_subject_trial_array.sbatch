#!/bin/bash
# =============================================================================
# run_subject_trial_array.sbatch - SLURM array over (subject, trial) pairs from
# subject_trial.csv (run mode "c").
#
# Each array task runs ONE (subject, trial) pair. SLURM_ARRAY_TASK_ID (1-based)
# selects the Nth DATA line of subject_trial.csv (the header line is skipped),
# setting both the subject and the trial for that task. cppxdic does the row
# selection internally from SLURM_ARRAY_TASK_ID.
#
# CSV FORMAT: subject,trial[,start,end,jump]  (plain text, no quotes, one trial per row)
#   Optional columns 3-5 set the frame window of THAT trial (start >= 1, end >= start,
#   end = 0 -> end of video, jump >= 1). An empty or missing field keeps the value of
#   dic_params.txt (idx_frame_start / idx_frame_end / frame_jump), which therefore
#   remains the default for every trial. Example:
#       subject,trial,idx_frame_start,idx_frame_end,frame_jump
#       DD4_rolling,2,16,161,1
#       DD4_rolling,3,16,161,1
#       NC_rolling,2,,,             <- all from dic_params.txt
#       NC_rolling,3,15,,2          <- start=15 and jump=2, end from dic_params.txt
#   NOTE: the script does `cd ${WORKDIR}` BEFORE reading the CSV, so a relative
#   SUBJECT_TRIAL_CSV is resolved from WORKDIR. Use an absolute path (or put the CSV
#   in WORKDIR).
#
# SIZING THE ARRAY:
#   The array index range must equal the number of DATA rows (lines minus the
#   header). Compute it from the CSV:
#       N=$(($(wc -l < subject_trial.csv) - 1))   # subtract the header line
#   or, robust to blank/comment lines and a trailing newline-less file:
#       N=$(grep -vcE '^\s*(#|subject,|$)' subject_trial.csv)
#   then:
#       sbatch --array=1-${N} run_subject_trial_array.sbatch
#   gen_subject_trial also prints the exact "--array=1-N" line to use.
#
# USAGE:
#   N=$(grep -vcE '^\s*(#|subject,|$)' subject_trial.csv)
#   sbatch --array=1-${N} \
#          --export=ALL,SUBJECT_TRIAL_CSV=subject_trial.csv \
#          deploy/cluster/run_subject_trial_array.sbatch
# =============================================================================
#SBATCH --job-name=cppxdic-st
#SBATCH --output=logs/cppxdic_st_%A_%a.out
#SBATCH --error=logs/cppxdic_st_%A_%a.err
#SBATCH --array=1-1
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=6
#SBATCH --mem=16G

set -euo pipefail

# ---- User-configurable knobs (override via --export=ALL,VAR=value) ----------
SUBJECT_TRIAL_CSV="${SUBJECT_TRIAL_CSV:-subject_trial.csv}"
CPPXDIC_BIN="${CPPXDIC_BIN:-./build/cppxdic}"
SINGULARITY_IMAGE="${SINGULARITY_IMAGE:-}" # optional .sif; if set, run via singularity
WORKDIR="${WORKDIR:-$PWD}"                  # dir containing the CSV + *_params.txt
DATA_DIR="${DATA_DIR:-}"                    # host input tree  -> /data   (container)
OUTPUT_DIR="${OUTPUT_DIR:-}"                # host output tree -> /output (container)

mkdir -p logs
cd "${WORKDIR}"

# Optional bind mounts (container runs only), same as run_trials_array.sbatch and
# submit_job.sh: DATA_DIR -> /data (read-only), OUTPUT_DIR -> /output (read-write), so a
# dic_params.txt written with the container paths /data and /output works unchanged.
# Without them the container cannot see the videos ("video not found ... /data/rawdata/...").
# DATA_DIR / OUTPUT_DIR come from your shell through --export=ALL. Do not ALSO export
# SINGULARITY_BIND / APPTAINER_BIND with the same targets (duplicate mounts).
BIND_ARGS=()
if [[ -n "${DATA_DIR}" ]]; then
    if [[ ! -d "${DATA_DIR}" ]]; then
        echo "ERROR: DATA_DIR not found: ${DATA_DIR}" >&2
        exit 1
    fi
    BIND_ARGS+=(--bind "${DATA_DIR}:/data:ro")
fi
if [[ -n "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
    BIND_ARGS+=(--bind "${OUTPUT_DIR}:/output:rw")
fi

if [[ ! -f "${SUBJECT_TRIAL_CSV}" ]]; then
    echo "ERROR: CSV not found: ${SUBJECT_TRIAL_CSV}" >&2
    exit 1
fi

echo "Array task ${SLURM_ARRAY_TASK_ID} / job ${SLURM_ARRAY_JOB_ID}"
echo "CSV=${SUBJECT_TRIAL_CSV} -> selecting data row ${SLURM_ARRAY_TASK_ID}"

# cppxdic reads SLURM_ARRAY_TASK_ID itself, skips the header, and picks the Nth
# (subject, trial) data row -- setting both subject and trial for this task.
if [[ -n "${SINGULARITY_IMAGE}" ]]; then
    echo "Image=${SINGULARITY_IMAGE}  Binds=${BIND_ARGS[*]:-none}"
    singularity exec ${BIND_ARGS[@]+"${BIND_ARGS[@]}"} \
        --env SLURM_ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID}" \
        "${SINGULARITY_IMAGE}" cppxdic --subject-trial-csv "${SUBJECT_TRIAL_CSV}"
else
    "${CPPXDIC_BIN}" --subject-trial-csv "${SUBJECT_TRIAL_CSV}"
fi
