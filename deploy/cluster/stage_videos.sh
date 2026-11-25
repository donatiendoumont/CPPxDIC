#!/bin/bash
# =============================================================================
# stage_videos.sh - turn ONE subject folder, copied as-is from the local PC, into
# the folder layout cppxdic expects, with unambiguous video names. The source is
# never modified: everything is copied to a new tree.
#
# SOURCE (what you copy from the PC; subject folder directly holds the sub-folders):
#     <SRC_ROOT>/<subject>/vid/*.mp4
#     <SRC_ROOT>/<subject>/protocol/*
#     <SRC_ROOT>/<subject>/calib/   robot/      (ignored: cppxdic does not read them
#                                                from the data tree)
#
# DESTINATION (what cppxdic wants under data_path):
#     <DST_ROOT>/rawdata/<subject>/speckles/glass/vid/*.mp4      (renamed)
#     <DST_ROOT>/rawdata/<subject>/speckles/glass/protocol/*     (copied)
#
# Why rename: cppxdic finds a video by searching the file name for the trial number
# ("_<NNN>_" in camerapairs mode, a bare "NNN" substring in the mirrored fallback).
# Acquisition names such as
#     slip_and_roll_DD4_001_150_010_trial003_cam_1.mp4
# contain other numbers (150, 010, trial003) that collide with other trial numbers
# (e.g. trial 10 matches "_010_" of trial 1; trial 1 matches "trial001" of trial 14).
#
# New name (trial number is the only free-standing number between underscores):
#     <subject>_glass_speckles_<NNN>_F<force>S<speed>_cam_<id>.mp4
#     e.g. DD4_rolling_glass_speckles_001_F150S010_cam_1.mp4
# The condition codes are kept (F..S..), glued so that "_010_" cannot match them.
# The acquisition counter "trialNNN" is dropped from the name but kept in the
# mapping CSV (<DST_ROOT>/video_name_map_<subject>.csv) for traceability.
#
# Usage (DRY RUN by default; nothing is written until --apply):
#     ./stage_videos.sh --src-root $GLOBALSCRATCH/incoming \
#                       --dst-root $GLOBALSCRATCH/data_staged/<project> \
#                       --subject DD4_rolling
#     ./stage_videos.sh ... --apply
#
# The part of the file name before the trial number (e.g. slip_and_roll_DD4) is
# detected automatically. Give --prefix <name> only if the folder mixes several
# prefixes (the script then stops and lists them).
#
# If two acquisitions share the same trial index (e.g. 064 recorded twice, with
# counters trial020 and trial021), the script stops. Decide which one is valid and
# leave the other out (repeatable option, matches the START of the source file name):
#     --exclude-prefix slip_and_roll_DD4_064_190_050_trial020_
#
# Then run cppxdic with DATA_DIR=<DST_ROOT> (it is bound on /data in the container).
#
# CHANGELOG: 2026-10-14 created (Claude Code session, CPPxDIC mirrored-mode setup).
# CHANGELOG: 2026-10-14 source layout changed to <SRC_ROOT>/<subject>/{vid,protocol,...};
#            the rawdata/<subject>/speckles/glass/ levels are created in the destination.
# CHANGELOG: 2026-10-14 --prefix is now optional (detected from the file names).
# CHANGELOG: 2026-11-23 option --material removed: "glass" is a fixed value required by cppxdic (folder speckles/glass, file names).
# CHANGELOG: 2026-11-18 the two numbers before _trialNNN accept any number of digits (NC_osc
#            names carry NbFrCam, up to 4 digits); the rolling names give the same result.
# =============================================================================
set -euo pipefail

SRC_ROOT=""; DST_ROOT=""; SUBJECT="DD4_rolling"; MATERIAL="glass"   # fixed: cppxdic reads speckles/glass (not an option)
PREFIX=""; APPLY=0   # PREFIX empty = detected automatically
EXCLUDES=()   # source-name prefixes to leave out (e.g. one of two acquisitions of the same trial)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src-root) SRC_ROOT="$2"; shift 2 ;;
        --dst-root) DST_ROOT="$2"; shift 2 ;;
        --subject)  SUBJECT="$2";  shift 2 ;;
        --prefix)   PREFIX="$2";   shift 2 ;;
        --exclude-prefix) EXCLUDES+=("$2"); shift 2 ;;   # repeatable
        --apply)    APPLY=1;       shift ;;
        -h|--help)  sed -n '2,52p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "${SRC_ROOT}" && -n "${DST_ROOT}" ]] || { echo "ERROR: --src-root and --dst-root are required" >&2; exit 2; }

SRC_SUBJ="${SRC_ROOT}/${SUBJECT}"
SRC_VID="${SRC_SUBJ}/vid"
SRC_PROTO="${SRC_SUBJ}/protocol"
DST_SPECK="${DST_ROOT}/rawdata/${SUBJECT}/speckles/${MATERIAL}"
DST_VID="${DST_SPECK}/vid"
MAP_CSV="${DST_ROOT}/video_name_map_${SUBJECT}.csv"

if [[ ! -d "${SRC_VID}" ]]; then
    echo "ERROR: source video dir not found: ${SRC_VID}" >&2
    echo "       Expected <src-root>/<subject>/vid. Found in ${SRC_ROOT}:" >&2
    ls -1 "${SRC_ROOT}" 2>/dev/null | head -10 >&2 || true
    exit 1
fi

# Safety: never write inside the source tree.
SRC_REAL="$(realpath "${SRC_ROOT}")"
DST_REAL="$(realpath -m "${DST_ROOT}")"   # -m: works even if the path does not exist yet
case "${DST_REAL}/" in
    "${SRC_REAL}/"*) echo "ERROR: --dst-root must not be inside --src-root" >&2; exit 1 ;;
esac

# Generic name pattern: <any prefix>_NNN_AAA_BBB_trialNNN_cam_<id>.mp4
# (the three numbers right before "_trialNNN_cam_" are trial index, force, speed).
# Only the trial index is exactly 3 digits; the two others may have any number of digits:
# in the oscillation names (osc_NC_001_2006_050_trial000_cam_1.mp4) they are NbFrCam (2006,
# 4 digits) and the fps. In the new name they still go in the F<..>S<..> part, so for the
# oscillation project "F" holds NbFrCam and "S" the fps (only a label: cppxdic looks for
# _<trial>_ right after "speckles").
RE="^(.+)_([0-9]{3})_([0-9]+)_([0-9]+)_trial([0-9]{3})_cam_(.+)\.mp4$"

declare -A SEEN=()
declare -A PREFIXES_FOUND=()
COPY_SRC=(); COPY_NEW=()
n_ok=0; n_skip=0; n_dup=0; n_excl=0
MAP_LINES=("old_name,new_name,trial_index,force_code,speed_code,acquisition_counter,cam")

shopt -s nullglob
for f in "${SRC_VID}"/*.mp4; do
    old="$(basename "$f")"
    skip_it=0
    for ex in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
        if [[ "${old}" == "${ex}"* ]]; then skip_it=1; break; fi
    done
    if [[ ${skip_it} -eq 1 ]]; then
        n_excl=$((n_excl + 1))
        continue
    fi
    if [[ "${old}" =~ ${RE} ]] && { [[ -z "${PREFIX}" ]] || [[ "${BASH_REMATCH[1]}" == "${PREFIX}" ]]; }; then
        pfx="${BASH_REMATCH[1]}"
        t="${BASH_REMATCH[2]}"; fo="${BASH_REMATCH[3]}"; sp="${BASH_REMATCH[4]}"
        ac="${BASH_REMATCH[5]}"; cam="${BASH_REMATCH[6]}"
        PREFIXES_FOUND["${pfx}"]=1
        new="${SUBJECT}_${MATERIAL}_speckles_${t}_F${fo}S${sp}_cam_${cam}.mp4"
        key="${t}|${cam}"
        if [[ -n "${SEEN[$key]:-}" ]]; then
            echo "ERROR: two source files map to trial ${t} cam ${cam}: ${SEEN[$key]} and ${old}" >&2
            n_dup=$((n_dup + 1))
            continue
        fi
        SEEN[$key]="${old}"
        MAP_LINES+=("${old},${new},${t},${fo},${sp},${ac},${cam}")
        n_ok=$((n_ok + 1))
        COPY_SRC+=("$f"); COPY_NEW+=("${new}")   # copied only after all checks pass
        if [[ ${APPLY} -eq 0 && ${n_ok} -le 6 ]]; then
            echo "  ${old}  ->  ${new}"
        fi
    else
        echo "SKIP (name does not match the expected pattern): ${old}" >&2
        n_skip=$((n_skip + 1))
    fi
done

echo "Matched: ${n_ok}   skipped: ${n_skip}   excluded: ${n_excl}   duplicates: ${n_dup}"
echo "Name prefix : ${!PREFIXES_FOUND[*]}"
if [[ ${#PREFIXES_FOUND[@]} -gt 1 ]]; then
    echo "ERROR: several different name prefixes found (above). Several subjects mixed in one folder?" >&2
    echo "       Re-run with --prefix <the one to keep>." >&2
    exit 1
fi
if [[ ${n_dup} -gt 0 ]]; then
    echo "ERROR: duplicate target names; nothing was copied." >&2
    exit 1
fi
if [[ -d "${SRC_PROTO}" ]]; then
    echo "Protocol    : ${SRC_PROTO}  ->  ${DST_SPECK}/protocol"
else
    echo "WARN: no protocol folder at ${SRC_PROTO} (cppxdic will use the frame window from dic_params.txt)" >&2
fi

if [[ ${APPLY} -eq 1 ]]; then
    mkdir -p "${DST_VID}"
    for i in "${!COPY_SRC[@]}"; do
        cp -p -n -- "${COPY_SRC[$i]}" "${DST_VID}/${COPY_NEW[$i]}"
    done
    if [[ -d "${SRC_PROTO}" ]]; then
        mkdir -p "${DST_SPECK}/protocol"
        cp -p -n -r -- "${SRC_PROTO}/." "${DST_SPECK}/protocol/"
    fi
    printf '%s\n' "${MAP_LINES[@]}" > "${MAP_CSV}"
    echo "Staged tree : ${DST_ROOT}"
    echo "Mapping CSV : ${MAP_CSV}"
    echo "Use it with : DATA_DIR=${DST_ROOT}"
else
    echo "(dry run: nothing written. Re-run with --apply to copy.)"
fi
