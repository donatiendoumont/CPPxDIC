#!/bin/bash
# =============================================================================
# stage_video_mng.sh - MNG (microneurography) version of stage_videos.sh.
# Turns the videos of ONE acquisition unit (e.g. expe008 / U01), copied as-is from the
# PC or the lab share, into the folder layout cppxdic expects, with unambiguous video
# names. The source is never modified: everything is copied to a new tree.
#
# SOURCE (<SRC_ROOT> = e.g. $RAW_DIR):
#     <SRC_ROOT>/<expe>/cam/<unit>/vid/*.mp4          e.g. expe008/cam/U01/vid/
#     <SRC_ROOT>/<expe>/protocol/MNG_Block<N>*.tsv    one protocol per block
#
# DESTINATION (one staged subject per block found in the video names):
#     <DST_ROOT>/rawdata/<expe>_<unit>_block<N>/speckles/glass/vid/*.mp4        (renamed)
#     <DST_ROOT>/rawdata/<expe>_<unit>_block<N>/speckles/glass/protocol/MNG_Block<N>*.tsv
# The level speckles/glass is required by cppxdic ("glass" is written in the names and
# in the folders; it is not an option).
#
# Names (the trial index is the only free-standing number between underscores):
#     in : expe008_U01_block1_005_807_050_trial004_2026_10_28_11h25m22_cam_5.mp4
#          <expe>_<unit>_block<N>_<trial>_<NbFrCam>_<fps>_trial<counter>_<timestamp>_cam_<id>.mp4
#     out: expe008_U01_block1_glass_speckles_005_F807S050_cam_5.mp4
#          <subject>_glass_speckles_<trial>_F<NbFrCam>S<fps>_cam_<id>.mp4
# <id> can contain an underscore (cam_0_0, cam_0_1). The block number N in the file name
# gives the subject (..._block1) and picks the protocol (MNG_Block1*.tsv). The acquisition
# counter and the timestamp are dropped from the name but kept in the mapping CSV
# (<DST_ROOT>/video_name_map_<subject>.csv).
#
# Usage (DRY RUN by default; nothing is written until --apply):
#     bash stage_video_mng.sh --src-root $RAW_DIR --dst-root $DATA_DIR --expe expe008 --unit U01
#     bash stage_video_mng.sh ... --apply
# Optional: --exclude-prefix <start of a source file name> (repeatable) to leave a file out,
#           --block <N> to stage only that block.
# The script stops if two source files give the same staged name.
#
# CHANGELOG: 2026-11-23 created from stage_videos.sh (Claude Code session, MNG project).
# =============================================================================
set -euo pipefail

SRC_ROOT=""; DST_ROOT=""; EXPE=""; UNIT=""; ONLY_BLOCK=""; APPLY=0
EXCLUDES=()
MATERIAL="glass"   # required by cppxdic (folder speckles/glass and file names); not an option

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src-root) SRC_ROOT="$2"; shift 2 ;;
        --dst-root) DST_ROOT="$2"; shift 2 ;;
        --expe)     EXPE="$2";     shift 2 ;;
        --unit)     UNIT="$2";     shift 2 ;;
        --block)    ONLY_BLOCK="$2"; shift 2 ;;
        --exclude-prefix) EXCLUDES+=("$2"); shift 2 ;;
        --apply)    APPLY=1;       shift ;;
        -h|--help)  sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "${SRC_ROOT}" && -n "${DST_ROOT}" && -n "${EXPE}" && -n "${UNIT}" ]] \
    || { echo "ERROR: --src-root, --dst-root, --expe and --unit are required" >&2; exit 2; }

SRC_VID="${SRC_ROOT}/${EXPE}/cam/${UNIT}/vid"
SRC_PROTO="${SRC_ROOT}/${EXPE}/protocol"

if [[ ! -d "${SRC_VID}" ]]; then
    echo "ERROR: source video dir not found: ${SRC_VID}" >&2
    echo "       Expected <src-root>/<expe>/cam/<unit>/vid. Found in ${SRC_ROOT}/${EXPE}:" >&2
    ls -1 "${SRC_ROOT}/${EXPE}" 2>/dev/null | head -10 >&2 || true
    exit 1
fi

# Safety: never write inside the source tree.
SRC_REAL="$(realpath "${SRC_ROOT}")"
DST_REAL="$(realpath -m "${DST_ROOT}")"
case "${DST_REAL}/" in
    "${SRC_REAL}/"*) echo "ERROR: --dst-root must not be inside --src-root" >&2; exit 1 ;;
esac

RE="^(.+)_(U[0-9]+)_block([0-9]+)_([0-9]{3})_([0-9]+)_([0-9]+)_trial([0-9]{3})_(.+)_cam_(.+)\.mp4$"

declare -A SEEN=() BLOCK_N=() MAP_LINES=() NVID=()
COPY_SRC=(); COPY_DST=()   # copied only after all checks pass
n_ok=0; n_skip=0; n_dup=0; n_excl=0

shopt -s nullglob
for f in "${SRC_VID}"/*.mp4; do
    old="$(basename "$f")"
    skip_it=0
    for ex in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
        if [[ "${old}" == "${ex}"* ]]; then skip_it=1; break; fi
    done
    if [[ ${skip_it} -eq 1 ]]; then n_excl=$((n_excl + 1)); continue; fi
    if [[ ! "${old}" =~ ${RE} ]]; then
        echo "SKIP (name does not match the expected pattern): ${old}" >&2
        n_skip=$((n_skip + 1)); continue
    fi
    ex_="${BASH_REMATCH[1]}"; un="${BASH_REMATCH[2]}"; blk="${BASH_REMATCH[3]}"
    t="${BASH_REMATCH[4]}"; nf="${BASH_REMATCH[5]}"; fps="${BASH_REMATCH[6]}"
    ac="${BASH_REMATCH[7]}"; ts="${BASH_REMATCH[8]}"; cam="${BASH_REMATCH[9]}"
    if [[ "${ex_}" != "${EXPE}" || "${un}" != "${UNIT}" ]]; then
        echo "SKIP (file is ${ex_}/${un}, expected ${EXPE}/${UNIT}): ${old}" >&2
        n_skip=$((n_skip + 1)); continue
    fi
    if [[ -n "${ONLY_BLOCK}" && "${blk}" != "${ONLY_BLOCK}" ]]; then continue; fi
    subj="${EXPE}_${UNIT}_block${blk}"
    new="${subj}_${MATERIAL}_speckles_${t}_F${nf}S${fps}_cam_${cam}.mp4"
    key="${subj}|${t}|${cam}"
    if [[ -n "${SEEN[$key]:-}" ]]; then
        echo "ERROR: two source files map to ${subj} trial ${t} cam ${cam}: ${SEEN[$key]} and ${old}" >&2
        n_dup=$((n_dup + 1)); continue
    fi
    SEEN[$key]="${old}"
    BLOCK_N["${subj}"]="${blk}"
    NVID["${subj}"]=$(( ${NVID[$subj]:-0} + 1 ))
    if [[ -z "${MAP_LINES[$subj]:-}" ]]; then
        MAP_LINES["${subj}"]="old_name,new_name,trial_index,nbfrcam,fps,acquisition_counter,timestamp,cam"
    fi
    MAP_LINES["${subj}"]+=$'\n'"${old},${new},${t},${nf},${fps},${ac},${ts},${cam}"
    COPY_SRC+=("$f"); COPY_DST+=("${DST_ROOT}/rawdata/${subj}/speckles/${MATERIAL}/vid/${new}")
    n_ok=$((n_ok + 1))
    if [[ ${APPLY} -eq 0 && ${n_ok} -le 4 ]]; then echo "  ${old}  ->  ${new}"; fi
done

echo "Matched: ${n_ok}   skipped: ${n_skip}   excluded: ${n_excl}   duplicates: ${n_dup}"
if [[ ${n_dup} -gt 0 ]]; then
    echo "ERROR: duplicate target names; nothing was copied." >&2
    exit 1
fi
if [[ ${n_ok} -eq 0 ]]; then
    echo "ERROR: no video matched in ${SRC_VID}" >&2
    exit 1
fi

# Protocol of each block: MNG_Block<N>.tsv or MNG_Block<N>_*.tsv (so block 1 never takes MNG_Block10).
declare -A PROTO=()
for subj in "${!BLOCK_N[@]}"; do
    n="${BLOCK_N[$subj]}"
    found=()
    for p in "${SRC_PROTO}/MNG_Block${n}.tsv" "${SRC_PROTO}"/MNG_Block${n}_*.tsv; do
        [[ -f "$p" ]] && found+=("$p")
    done
    if [[ ${#found[@]} -eq 0 ]]; then
        echo "  ${subj}: ${NVID[$subj]} videos, WARN no protocol MNG_Block${n}*.tsv in ${SRC_PROTO}" >&2
    else
        echo "  ${subj}: ${NVID[$subj]} videos, protocol: $(printf '%s ' "${found[@]##*/}")"
        PROTO["${subj}"]="${found[*]}"
    fi
done

if [[ ${APPLY} -eq 1 ]]; then
    for i in "${!COPY_SRC[@]}"; do
        mkdir -p "$(dirname "${COPY_DST[$i]}")"
        cp -p -n -- "${COPY_SRC[$i]}" "${COPY_DST[$i]}"
    done
    for subj in "${!PROTO[@]}"; do
        d="${DST_ROOT}/rawdata/${subj}/speckles/${MATERIAL}/protocol"
        mkdir -p "$d"
        for p in ${PROTO[$subj]}; do cp -p -n -- "$p" "$d/"; done
    done
    for subj in "${!MAP_LINES[@]}"; do
        printf '%s\n' "${MAP_LINES[$subj]}" > "${DST_ROOT}/video_name_map_${subj}.csv"
    done
    echo "Staged tree : ${DST_ROOT}/rawdata/<subject>/speckles/${MATERIAL}/{vid,protocol}"
    echo "Mapping CSV : ${DST_ROOT}/video_name_map_<subject>.csv"
else
    echo "(dry run: nothing written. Re-run with --apply to copy.)"
fi
