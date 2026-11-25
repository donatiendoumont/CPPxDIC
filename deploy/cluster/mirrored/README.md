# Mirrored mode: one folder per project

Everything that depends on a project lives in its own folder. `REPORT.md` is the Manneback run report
of the mirrored mode (older, independent of the projects).

| Folder | Project | Raw subjects (`$RAW_DIR`) |
| --- | --- | --- |
| `rolling/` | tractive rolling, sliding | `DD4_rolling`, `NC_rolling` |
| `osc/` | oscillation | `NC_osc` |
| `template/` | starting point for a NEW project: `cp -r template <my_project>`, then edit `project.env` (2 lines) and the CSV | (yours) |

Each project folder contains:

| File | Role |
| --- | --- |
| `project.env` | sets `PROJECT_NAME`, `PROJECT_DIR`, `CONFIG_DIR`, `FRAME_SCRIPT`, `RAW_DIR`, `DATA_DIR`, `OUTPUT_DIR` |
| `configs/` | `dic_params.txt`, `ncorr_params.txt`, `visualization_params.txt` of the project (bind-mounted in the container: no rebuild to change them) |
| `template_<project>.csv` | template of the source CSV: copy it to `subject_trial.csv` then edit |
| `subject_trial.csv` | source CSV (never modified by the scripts); `*_staged.csv` is written next to it |
| `frame_*_complete*.py/.sh` | compute the frame window of each trial from the protocol |

Shared, one level up (`deploy/cluster/`): `frame_standard_complete.py/.sh` (generic, by `MovNo`), `submit_csv.sh`,
`run_subject_trial_array.sbatch`, `cppxdic_mirrored.def`, `monitor_job.sh`, `stage_videos.sh`, `stage_video_mng.sh`, `copy_results_from_cluster.sh`. The folder `deploy/cluster/configs/` is only the
generic default (image defaults, other modes): the parameters actually used are the ones of the project.

## Use

```bash
source ~/CPPxDIC/deploy/cluster/mirrored/osc/project.env      # no default project: choose one in each shell
bash ~/CPPxDIC/deploy/cluster/stage_videos.sh --src-root $RAW_DIR --dst-root $DATA_DIR --subject NC_osc          # dry run
cp $PROJECT_DIR/template_osc.csv $PROJECT_DIR/subject_trial.csv && nano $PROJECT_DIR/subject_trial.csv
source ~/CPPxDIC/deploy/cluster/submit_csv.sh $PROJECT_DIR/subject_trial.csv     # the CSV is always given; sets CSV and N
cd ~/CPPxDIC && sbatch --array=1-${N} --cpus-per-task=8 --mem=16G --time=02:00:00 \
    --export=ALL,SUBJECT_TRIAL_CSV=$CSV,WORKDIR=$CONFIG_DIR deploy/cluster/run_subject_trial_array.sbatch
```

A shell keeps the variables of the last `project.env` it sourced: check with `echo $PROJECT_NAME`.
