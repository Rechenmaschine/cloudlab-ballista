# Ballista + Redbench on CloudLab

A parameterized CloudLab profile that brings up `1 scheduler + N executors`
running Apache Ballista from your git fork, with IMDb parquet data on each
executor for replaying Redbench-generated workloads.

## Files

| File | Role |
|---|---|
| `profile.py` | CloudLab geni-lib profile. Repo-based: drop in the top of a public git repo. |
| `setup.sh` | Runs on every node at boot. Builds Ballista, launches scheduler/executor. |
| `prep_imdb.sh` | Manual one-time IMDb data prep. Writes to `/mnt/data/imdb_parquet`. |
| `run_redbench.py` | Replay driver. Reads workload from disk, fires queries against the scheduler, writes timings to CSV. |

## Storage layout

- `/` — OS, Rust, packages.
- `/mnt/work` — Blockstore for Ballista source + build, executor `--work-dir`. Ephemeral; fresh every experiment.
- `/mnt/data` — Blockstore for IMDb parquet (executors only). Ephemeral, optionally pre-populated from an Image-Backed Dataset (`imdbDatasetURN`).

## First-ever setup (one time per project)

1. Push these files to a public git repo.
2. CloudLab → Create Profile → Repository-based → your repo URL.
3. Instantiate with `imdbDatasetURN` left blank.
4. SSH `executor-0`, run `sudo bash /local/repo/prep_imdb.sh` (~15 min).
5. CloudLab UI → Storage → Create Dataset → Image Backed → pick the experiment, `executor-0`, Blockstore `executor-0-data`. Save the URN.
6. Edit `profile.py`'s `imdbDatasetURN` default (or just pass it at instantiate time).

## Every experiment after

1. Instantiate with `imdbDatasetURN` set. `/mnt/data` is populated on every executor at boot.
2. SSH `scheduler`. Generate a workload manually (see Redbench docs); the `output/` dir holds queries.
3. Run:
   ```bash
   python3 /local/repo/run_redbench.py \
       --workload-dir /local/Redbench/output \
       --scheduler scheduler:50050 \
       --data-dir /mnt/data/imdb_parquet \
       --results /local/results.csv
   ```

## Knobs in `profile.py`

- `nExecutors` — how many executors.
- `ballistaRepo` / `ballistaRef` — your Ballista fork + branch/tag/commit SHA. Triggers clean rebuild each experiment.
- `phystype` — hardware type (e.g. `c220g2`, `c6420`, `xl170`).
- `concurrentTasks` — per-executor parallelism (`--concurrent-tasks`). 0 = all cores.
- `linkBandwidth` / `linkLatency` / `linkPlr` — LAN shaping via Emulab dummynet.
- `imdbDatasetURN` — URN of the Image-Backed Dataset. Blank for first-ever experiment.
- `imdbDataSize` / `workDiskSize` — Blockstore sizes.
