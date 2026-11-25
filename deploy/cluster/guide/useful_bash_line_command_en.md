# Useful bash command line

<!-- English translation of useful_bash_line_command.md (French original, snapshot of 2026-11-23). Content unchanged; only the language. -->

## Switching project (rolling / oscillation): procedure

Each project has its own folder in `~/CPPxDIC/deploy/cluster/mirrored/` (`rolling/` and `osc/`) with everything that concerns it: its parameters (`configs/`), its CSV files (`subject_trial.csv`, `template_<project>.csv`), its frame script and a `project.env` file. Details are in `mirrored/README.md`.

There is NO default project: in every new shell you must source the `project.env` of the project you want. It sets `PROJECT_DIR` (the project folder), `CONFIG_DIR` (its parameters), `FRAME_SCRIPT` (its frame script), `DATA_DIR` (staged data), `OUTPUT_DIR` (results) and `RAW_DIR` (raw data, shared by both projects). Always check the active project first: `echo $PROJECT_NAME`. Sourcing another `project.env` replaces all these variables at once.

The same 5 steps apply to both projects; only the `project.env` and the subject change:

1 - choose the project

`source ~/CPPxDIC/deploy/cluster/mirrored/osc/project.env`

(rolling: `source ~/CPPxDIC/deploy/cluster/mirrored/rolling/project.env`)

2 - stage the videos: copies the renamed videos AND the protocol to `$DATA_DIR/rawdata/<subject>/speckles/glass/{vid,protocol}`. Always run without `--apply` first (dry run), then with it:

`bash $GLOBALSCRATCH/stage_videos.sh --src-root $RAW_DIR --dst-root $DATA_DIR --subject NC_osc`

`bash $GLOBALSCRATCH/stage_videos.sh --src-root $RAW_DIR --dst-root $DATA_DIR --subject NC_osc --apply`

(subjects: DD4_rolling, NC_rolling for `rolling`; NC_osc for `osc`. The `glass` material of NC_osc is to be confirmed. Since 18/11/2026, `stage_videos.sh` accepts the 91 videos of NC_osc.)

3 - reference files: `REF_MASK_*` and `REF_SEED_*` must be in `$OUTPUT_DIR/<subject>/glass/` (like `analysis/slip_and_roll_rolling/DD4_rolling/glass/`).

4 - create the source CSV (no script creates it; it is never modified): copy the project template (`template_rolling.csv` or `template_osc.csv`, one header line and examples) to `subject_trial.csv` in the project folder, then edit the copy. Each project has its own folder, hence the same CSV name.

`cp $PROJECT_DIR/template_osc.csv $PROJECT_DIR/subject_trial.csv`

`nano $PROJECT_DIR/subject_trial.csv`

(rolling: `cp $PROJECT_DIR/template_rolling.csv $PROJECT_DIR/subject_trial.csv`)

Columns (one line per trial or group of trials):
- `subject`: the subject folder (rolling: DD4_rolling, NC_rolling; osc: NC_osc).
- `trial`: `5`, `1:3`, `1:2:9`, `"[1,2,7,8]"` or `"[1:3,7]"`; a group gives one row per trial. A list with commas is written between quotes, otherwise a spreadsheet splits it into several columns (the scripts accept both spellings).
- `phase`: rolling = `loading`, `slide`, `relax`, `unloading` (joined with `+`), `all`; empty = `slide+relax`. osc = movement numbers of the protocol (`4`, `3+4`, `3:5`) or `osc` (the movement with Relative = 2); empty = `osc`.
- `nbr_osc` (osc only): number of oscillations kept; empty = all. A number smaller than `Nosc` requires `osc` to be the last movement of the window (`osc` or `3+osc`, not `osc+5`).
- `frame_jump`: 1 = every image, 2 = every other image; empty = value of `dic_params.txt`.

5 - stage the frames: the script reads this CSV, the protocol copied at step 2 and the project script (`$FRAME_SCRIPT`), then WRITES `subject_trial_staged.csv` (next to the source) and sets `$CSV` and `$N`. The CSV must always be given explicitly (no default CSV):

`source ~/CPPxDIC/deploy/cluster/submit_csv.sh $PROJECT_DIR/subject_trial.csv`

(Other CSV files created automatically: `video_name_map_<subject>.csv` in `$DATA_DIR` by `stage_videos.sh --apply`, a simple table of old/new video names.)

then launch the job with the `sbatch` line of the section "Launch job execution" below: it already uses `$CSV`, `$N` and `$CONFIG_DIR` (the project parameters), and the results go to the project's `$OUTPUT_DIR`. If the material is not `glass`: put `MATERIAL=<material>` in front of the `source` command. As long as the oscillation data are not staged, add in front of the command `DATA_ROOT=$RAW_DIR PROTOCOL_DIR_TEMPLATE='{data_root}/{subject}/protocol'`.

## Create a data structure format that xdic accepts

- The raw data (all subjects of both projects) are in `$RAW_DIR` (= data/slip_and_roll, never renamed); the staged data go to `$DATA_DIR`, which depends on the project (see `project.env` above). Choose the project before staging.

- bash to verify the data folder

`bash $GLOBALSCRATCH/stage_videos.sh --src-root $RAW_DIR --dst-root $DATA_DIR --subject DD4_rolling --exclude-prefix slip_and_roll_DD4_064_190_050_trial020_`

- bash to apply the data staging in the format xdic will understand

`bash $GLOBALSCRATCH/stage_videos.sh --src-root $RAW_DIR --dst-root $DATA_DIR --subject DD4_rolling --apply`

- MNG (microneurography) data: `stage_video_mng.sh` (in `deploy/cluster/`). Source `<RAW_DIR>/<expe>/cam/<unit>/vid/*.mp4` and `<RAW_DIR>/<expe>/protocol/MNG_Block<N>*.tsv`; destination `<DATA_DIR>/rawdata/<expe>_<unit>_block<N>/speckles/glass/{vid,protocol}`, one staged subject per block found in the file names. Example: `expe008_U01_block1_005_807_050_trial004_2026_10_28_11h25m22_cam_5.mp4` becomes `expe008_U01_block1_glass_speckles_005_F807S050_cam_5.mp4`. Dry run first, then `--apply`:

`bash ~/CPPxDIC/deploy/cluster/stage_video_mng.sh --src-root $RAW_DIR --dst-root $DATA_DIR --expe expe008 --unit U01`

`bash ~/CPPxDIC/deploy/cluster/stage_video_mng.sh --src-root $RAW_DIR --dst-root $DATA_DIR --expe expe008 --unit U01 --apply`

(`--block <N>` stages one block only; `--exclude-prefix <start of a file name>` leaves a file out. The script stops if two files give the same staged name.)


## Avoid retyping all the variables at every connection

- `source` is only needed if `~/.bashrc` was modified; otherwise there is no need to run it.
# run each line one by one: source

`source ~/.bashrc`

- copy of bashrc: save a backup of the file before modifying it
`cp ~/.bashrc ~/.bashrc.bak`

- edit bashrc
`nano ~/.bashrc`


- bashrc version 18/11/2026 (no default project: everything that depends on the project comes from its `project.env`)

```bash
export SIF_IMAGE=/home/ucl/inma/<login>/CPPxDIC/deploy/cluster/cppxdic_mirrored.sif
export SINGULARITY_IMAGE=$SIF_IMAGE
```

Do not put `DATA_DIR`, `OUTPUT_DIR` or `CONFIG_DIR` in the bashrc, and do not type an `export` by hand for these variables: they come from the sourced `project.env`, and a manual `export` would overwrite what it set.

## Create the trials and frames to track
1 - Edit a CSV in the project folder (`$PROJECT_DIR/subject_trial.csv`, copied from `template_<project>.csv`):
subject,trial,phase,frame_jump\
DD4_rolling,2:3,slide+relax,\
NC_rolling,"[1,2,12]",loading,\
NC_rolling,7,all,2

The phases (rolling):
    - loading = contact initiation,
    - slide = lateral movement of the plate,
    - relax = relaxation after the movement, i.e. the robot is still,
    - unloading = unloading.

Oscillation project (`osc/project.env`): the `phase` column contains movement numbers of the protocol (`MovNo`, for example `4`, `3+4`, `3:5`); the word `osc` designates the oscillation movement (the one with Relative = 2); `nbr_osc` = number of oscillations to keep (empty = all, i.e. `Nosc` of the protocol):

subject,trial,phase,nbr_osc,frame_jump\
NC_osc,1:3,osc,,\
NC_osc,4,3+osc,3,

For another type of protocol, `frame_standard_complete.sh` (in `deploy/cluster/`) also accepts movement numbers: put `FRAME_SCRIPT=~/CPPxDIC/deploy/cluster/frame_standard_complete.sh` in front of the `source submit_csv.sh` command.

2 - prepare a staged CSV for job execution (the frame computation script is the project's, `$FRAME_SCRIPT`; the CSV must be given):

`source ~/CPPxDIC/deploy/cluster/submit_csv.sh $PROJECT_DIR/subject_trial.csv`

## Launch job execution

Run from the CPPxDIC project

`sbatch --array=1-${N} --cpus-per-task=8 --mem=16G --time=02:00:00 --export=ALL,SUBJECT_TRIAL_CSV=$CSV,WORKDIR=$CONFIG_DIR deploy/cluster/run_subject_trial_array.sbatch`

(`--cpus-per-task` must equal `step_d_total_threads` of `dic_params.txt`: 8 threads, 16 GB, from the measurements of 18/11/2026.)

## Copy the results from the cluster to my PC (`copy_results_from_cluster.sh`)

Run it **on your PC**, in Git Bash (not on the cluster). The script is in the repository: `deploy/cluster/copy_results_from_cluster.sh`. It needs only `ssh` and `tar` (no rsync), only reads on the cluster (nothing is modified or deleted there), and keeps the same folder structure on the PC.

What it copies, under `<remote root>/<subject>/glass/`: the `REF_MASK_*.mat` and `REF_SEED_*.mat` files, and for each trial `<trial>/<phase>/mirrored_pair*/` (`ncorr*.bin`, `myDIC2DpairResults_*.mat`, `dic_info_*.mat`). Trial folders are named with 3 digits (trial 1 = `001`). The `tmp_*` folders (extracted frames, working images) are not copied unless you ask with `-a`.

Set once per terminal your host, login and the analysis folder of your project (otherwise give `-H`, `-u`, `-r` each time):

`export CLUSTER_HOST=lemaitre4 CLUSTER_USER=<login> CLUSTER_REMOTE_ROOT=/globalscratch/ucl/inma/<login>/analysis/<project>`

Always list first what would be copied (`-n`, dry run):

`./copy_results_from_cluster.sh -e DD4_rolling -d /d/data/results -t all -n`

then copy for real. Examples:

`./copy_results_from_cluster.sh -e DD4_rolling -d /d/data/results` (all trials, default material `glass`)

`./copy_results_from_cluster.sh -e DD4_rolling -d /d/data/results -t 1,3,5` (trials 1, 3 and 5)

`./copy_results_from_cluster.sh -e DD4_rolling -d /d/data/results -t 1-4,8 -b` (trials 1 to 4 and 8, without the large `ncorr*.bin`)

Options:
- `-e <subject>` (required): the subject folder, same name as the `subject` column of the CSV. `-d <dest>` (required): local folder; the files go to `<dest>/<subject>/...`.
- `-t`: `all` (default), or `1,3,5`, `1-4`, `1-4,8`.
- `-m <material>`: material folder to read (default `glass`; `any` = every material folder).
- `-b`: skip the `ncorr*.bin` files (intermediate results, the largest ones).
- `-a`: also copy the `tmp_*` folders. `-z`: compress during the transfer (slow connection).
- `-k`: keep, do not overwrite files that already exist in the destination.
- `-n`: dry run. `-h`: help.

The project folder differs between projects: `CLUSTER_REMOTE_ROOT` ends with `analysis/<project>` (for example `analysis/slip_and_roll_rolling`), so change it when you change project. On Windows paths are written `/d/data/results` in Git Bash.

## Follow ALL my jobs

`squeue --me`

## Cancel ALL my jobs

`scancel --me`

## See the memory used

sacct -j <JOBID> --format=JobID,Elapsed,MaxRSS,AllocCPUS,TotalCPU,State
