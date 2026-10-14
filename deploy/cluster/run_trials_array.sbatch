#!/bin/bash
# =============================================================================
# run_trials_array.sbatch - SLURM array over a list of trials (run mode "b")
#
# Each array task runs ONE trial. SLURM_ARRAY_TASK_ID (1-based) indexes into the
# trial list, which is taken either from --trials <list> or --trials-file <path>
# passed to cppxdic. The subject is fixed for the whole array (set via SUBJECT).
#
# SIZING THE ARRAY:
#   The array index range must match the number of trials in the list, 1-based.
#   For an inline list  TRIALS="7,12,25"     -> --array=1-3
#   For a trials file:
#       N=$(grep -vcE '^\s*(#|$)' trials.txt) # count non-blank, non-comment lines
#       sbatch --array=1-${N} run_trials_array.sbatch
#
# USAGE:
#   sbatch --array=1-3 \
#          --export=ALL,SUBJECT=S09,TRIALS="7,12,25" \
#          deploy/cluster/run_trials_array.sbatch
#   # or with a file:
#   sbatch --array=1-$(grep -vcE '^\s*(#|$)' trials.txt) \
#          --export=ALL,SUBJECT=S09,TRIALS_FILE=trials.txt \
#          deploy/cluster/run_trials_array.sbatch
#
# SINGULARITY BIND MOUNTS (added):
#   When SINGULARITY_IMAGE is set and DATA_DIR / OUTPUT_DIR are set (they are
#   passed through by --export=ALL when exported in your shell), the container
#   gets the same mounts as submit_job.sh:
#       DATA_DIR   -> /data    (read-only)
#       OUTPUT_DIR -> /output  (read-write)
#   so a dic_params.txt written with the container paths /data and /output
#   works unchanged. If DATA_DIR / OUTPUT_DIR are unset, no mount is added
#   (previous behaviour). Do not ALSO export SINGULARITY_BIND / APPTAINER_BIND
#   with the same targets (duplicate mounts).
# =============================================================================
#SBATCH --job-name=cppxdic-trials
#SBATCH --output=logs/cppxdic_%A_%a.out
#SBATCH --error=logs/cppxdic_%A_%a.err
#SBATCH --array=1-3
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=6
#SBATCH --mem=16G

set -euo pipefail

# ---- User-configurable knobs (override via --export=ALL,VAR=value) ----------
SUBJECT="${SUBJECT:-S09}"                 # subject id, e.g. S09
TRIALS="${TRIALS:-}"                       # inline list, e.g. "7,12,25"
TRIALS_FILE="${TRIALS_FILE:-}"             # alternative: file, one trial/line
CPPXDIC_BIN="${CPPXDIC_BIN:-./build/cppxdic}"
SINGULARITY_IMAGE="${SINGULARITY_IMAGE:-}" # optional .sif; if set, run via singularity
WORKDIR="${WORKDIR:-$PWD}"                  # dir containing *_params.txt files
DATA_DIR="${DATA_DIR:-}"                    # host input tree  -> /data   (container)
OUTPUT_DIR="${OUTPUT_DIR:-}"                # host output tree -> /output (container)

mkdir -p logs
cd "${WORKDIR}"

# Build the trial-source argument for cppxdic.
if [[ -n "${TRIALS_FILE}" ]]; then
    TRIAL_ARG=(--trials-file "${TRIALS_FILE}")
elif [[ -n "${TRIALS}" ]]; then
    TRIAL_ARG=(--trials "${TRIALS}")
else
    echo "ERROR: set TRIALS or TRIALS_FILE" >&2
    exit 1
fi

# Build the optional bind-mount arguments (container runs only).
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

echo "Array task ${SLURM_ARRAY_TASK_ID} / job ${SLURM_ARRAY_JOB_ID}"
echo "Subject=${SUBJECT}  Trial source=${TRIAL_ARG[*]}"
if [[ -n "${SINGULARITY_IMAGE}" ]]; then
    echo "Image=${SINGULARITY_IMAGE}  Binds=${BIND_ARGS[*]:-none}"
fi

# cppxdic reads SLURM_ARRAY_TASK_ID itself and picks the Nth trial.
if [[ -n "${SINGULARITY_IMAGE}" ]]; then
    singularity exec ${BIND_ARGS[@]+"${BIND_ARGS[@]}"} \
        --env SLURM_ARRAY_TASK_ID="${SLURM_ARRAY_TASK_ID}" \
        "${SINGULARITY_IMAGE}" cppxdic --subject "${SUBJECT}" "${TRIAL_ARG[@]}"
else
    "${CPPXDIC_BIN}" --subject "${SUBJECT}" "${TRIAL_ARG[@]}"
fi
