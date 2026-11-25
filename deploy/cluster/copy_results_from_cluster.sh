#!/usr/bin/env bash
# copy_results_from_cluster.sh - copy CPPxDIC results from the cluster to this machine, keeping the same structure.
#
# What it copies (under <remote root>/<expe>/<material>/, material = glass by default, see -m):
#   REF_MASK_*.mat, REF_SEED_*.mat                     (ROI and seed files, at material level)
#   <trial>/<phase>/mirrored_pair*/...                 (ncorr*.bin, myDIC2DpairResults_*.mat, dic_info_*.mat)
# Trial folders are named with %03d (trial 1 -> 001).
# Not copied by default: the temporary folders tmp_* (extracted frames, ncorr work images; use -a to include them).
# Nothing on the cluster is modified or deleted: it only reads.
#
# Needs only ssh and tar (no rsync): the files are streamed with "tar over ssh", so it works in Git Bash on Windows.
# ssh asks for your password / uses your key as usual.
#
# Examples
#   ./copy_results_from_cluster.sh -H manneback.example.org -e DD4_rolling -d /d/data/results            # all trials
#   ./copy_results_from_cluster.sh -H myhost -e DD4_rolling -t 1,3,5 -d /d/data/results                  # trials 1, 3 and 5
#   ./copy_results_from_cluster.sh -H myhost -e DD4_rolling -t 1-4,8 -d /d/data/results -b              # 1 to 4 and 8, without ncorr*.bin
#   ./copy_results_from_cluster.sh -H myhost -e DD4_rolling -t all -d /d/data/results -n                 # only list what would be copied
# The host can also be given once with:  export CLUSTER_HOST=myhost
set -u -o pipefail

REMOTE_ROOT_DEFAULT="${CLUSTER_REMOTE_ROOT:-}"   # e.g. /globalscratch/<group>/<login>/analysis/<project>
USER_DEFAULT="${CLUSTER_USER:-}"                       # your cluster login

usage() {
  cat <<EOF
Usage: $(basename "$0") -e EXPE -d DEST [-t TRIALS] [-m MATERIAL] [-H HOST] [-u USER] [-r REMOTE_ROOT] [-b] [-a] [-z] [-k] [-n]

  -e EXPE         subject name, e.g. DD4_rolling                                      (required)
  -d DEST         local folder; <DEST>/<EXPE>/... is created with the same structure     (required)
  -t TRIALS       'all' (default) or a list: 1,3,5   1-4   1-4,8   (numbers; folders are named 001, 002, ... = %03d)
  -m MATERIAL     sub-folder of the subject to read (default: glass); 'any' = every material folder
  -H HOST         cluster host name (or set CLUSTER_HOST)                                (required)
  -u USER         login name                                (default: ${USER_DEFAULT})
  -r REMOTE_ROOT  analysis folder on the cluster            (default: ${REMOTE_ROOT_DEFAULT})
  -b              do not copy the ncorr*.bin files (intermediate results, the largest ones)
  -a              also copy the tmp_* folders
  -z              compress during the transfer (useful on a slow connection)
  -k              keep: do not overwrite files that already exist in DEST
  -n              dry run: list what would be copied, copy nothing
  -h              this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

EXPE=""; DEST=""; TRIALS="all"; MATERIAL="glass"; HOST="${CLUSTER_HOST:-}"; LOGIN="$USER_DEFAULT"; REMOTE_ROOT="$REMOTE_ROOT_DEFAULT"
NO_BIN=0; WITH_TMP=0; ZIP=0; KEEP=0; DRY=0
while getopts "e:d:t:m:H:u:r:bazknh" opt; do
  case "$opt" in
    e) EXPE="$OPTARG" ;;
    d) DEST="$OPTARG" ;;
    t) TRIALS="$OPTARG" ;;
    m) MATERIAL="$OPTARG" ;;
    H) HOST="$OPTARG" ;;
    u) LOGIN="$OPTARG" ;;
    r) REMOTE_ROOT="$OPTARG" ;;
    b) NO_BIN=1 ;;
    a) WITH_TMP=1 ;;
    z) ZIP=1 ;;
    k) KEEP=1 ;;
    n) DRY=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$EXPE" ] || { usage >&2; die "give the subject name with -e"; }
[ -n "$DEST" ] || { usage >&2; die "give the destination folder with -d"; }
[ -n "$HOST" ] || { usage >&2; die "give the cluster host with -H (or set CLUSTER_HOST)"; }
[ -n "$LOGIN" ] || die "give your cluster login with -u (or set CLUSTER_USER)"
[ -n "$REMOTE_ROOT" ] || die "give the analysis folder with -r (or set CLUSTER_REMOTE_ROOT), e.g. /globalscratch/<group>/<login>/analysis/<project>"
# These values are pasted into a command run on the cluster: accept only harmless characters.
[[ "$EXPE" =~ ^[A-Za-z0-9_.-]+$ ]]        || die "subject name '$EXPE' has unexpected characters"
[[ "$MATERIAL" =~ ^[A-Za-z0-9_.-]+$ ]]    || die "material '$MATERIAL' has unexpected characters"
[[ "$REMOTE_ROOT" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "remote root '$REMOTE_ROOT' has unexpected characters"
[[ "$LOGIN" =~ ^[A-Za-z0-9_.-]+$ ]]       || die "user name '$LOGIN' has unexpected characters"

# Windows paths (D:\data) -> Git Bash paths (/d/data) when cygpath exists.
if command -v cygpath >/dev/null 2>&1; then DEST="$(cygpath -u "$DEST")"; fi

# ---- trial list: 'all', or 1,3,5 / 1-4 / 1-4,8  ->  001 003 005 ...
TRIAL_DIRS=()
if [ "$TRIALS" != "all" ]; then
  IFS=', ' read -r -a parts <<< "$TRIALS"
  for p in "${parts[@]}"; do
    [ -n "$p" ] || continue
    if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
      [ "$a" -le "$b" ] || die "bad range '$p'"
      for ((i = a; i <= b; i++)); do TRIAL_DIRS+=("$(printf '%03d' "$i")"); done
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      TRIAL_DIRS+=("$(printf '%03d' "$((10#$p))")")
    else
      die "cannot read trial '$p' (use all, 1,3,5, 1-4 or 1-4,8)"
    fi
  done
  [ "${#TRIAL_DIRS[@]}" -gt 0 ] || die "empty trial list"
fi

# ---- remote command (runs in the cluster's shell)
SSH_CMD="${SSH_CMD:-ssh}"            # SSH_CMD / SSH_OPTS can be overridden (used for tests)
SSH_OPTS="${SSH_OPTS:-}"
TARGET="${LOGIN}@${HOST}"
remote() { $SSH_CMD $SSH_OPTS "$TARGET" "$1"; }

EXCL=""
[ "$WITH_TMP" -eq 1 ] || EXCL="$EXCL --exclude='tmp_*'"
[ "$NO_BIN" -eq 0 ]   || EXCL="$EXCL --exclude='ncorr*.bin'"
TARZ=""; [ "$ZIP" -eq 0 ] || TARZ="z"

if [ "$MATERIAL" = "any" ]; then BASE="$EXPE"; DEPTH=2; else BASE="$EXPE/$MATERIAL"; DEPTH=1; fi
if [ "${#TRIAL_DIRS[@]}" -eq 0 ]; then
  REMOTE_CMD="cd '$REMOTE_ROOT' && tar -c${TARZ}f - $EXCL '$BASE'"
else
  NAMES="-name 'REF_*'"
  for t in "${TRIAL_DIRS[@]}"; do NAMES="$NAMES -o -name '$t'"; done
  REMOTE_CMD="cd '$REMOTE_ROOT' && find '$BASE' -mindepth $DEPTH -maxdepth $DEPTH \\( $NAMES \\) -print0 | tar --null $EXCL -T - -c${TARZ}f -"     # --exclude must come before -T
fi

echo "Cluster : $TARGET:$REMOTE_ROOT/$BASE"
echo "Trials  : $([ "${#TRIAL_DIRS[@]}" -eq 0 ] && echo all || echo "${TRIAL_DIRS[*]}")"
echo "Local   : $DEST/$EXPE"
[ "$NO_BIN" -eq 1 ] && echo "Options : ncorr*.bin not copied"
[ "$WITH_TMP" -eq 1 ] && echo "Options : tmp_* folders included"
[ "$DRY" -eq 1 ] && echo "Dry run : nothing will be copied"

remote "test -d '$REMOTE_ROOT/$BASE'" || die "folder $REMOTE_ROOT/$BASE not found on the cluster (or connection failed)"

if [ "$DRY" -eq 1 ]; then
  remote "$REMOTE_CMD" | tar -t${TARZ}vf -
  st=("${PIPESTATUS[@]}")
else
  mkdir -p "$DEST" || die "cannot create $DEST"
  KEEPOPT=""; [ "$KEEP" -eq 0 ] || KEEPOPT="--skip-old-files"
  remote "$REMOTE_CMD" | tar -x${TARZ}f - -C "$DEST" $KEEPOPT
  st=("${PIPESTATUS[@]}")
fi
[ "${st[0]}" -eq 0 ] || die "the transfer failed on the cluster side (exit code ${st[0]})"
[ "${st[1]}" -eq 0 ] || die "the transfer failed on this machine (exit code ${st[1]})"

if [ "$DRY" -eq 0 ]; then
  echo
  echo "Done. $(find "$DEST/$EXPE" -type f | wc -l) file(s), $(du -sh "$DEST/$EXPE" | cut -f1) in $DEST/$EXPE"
  # which requested trials were not found on the cluster?
  for t in "${TRIAL_DIRS[@]}"; do
    find "$DEST/$BASE" -mindepth "$DEPTH" -maxdepth "$DEPTH" -name "$t" 2>/dev/null | grep -q . || echo "WARNING: trial $t not found on the cluster for $EXPE"
  done
fi
