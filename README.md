# Ballista on CloudLab

A parameterized CloudLab profile that brings up `1 scheduler + N executors`
running Apache Ballista from your git fork, with an optional Image-Backed
Dataset auto-mounted on each executor for benchmark workloads.

## Files

| File | Role |
|---|---|
| `profile.py` | CloudLab geni-lib profile. Repo-based: drop in the top of a public git repo. |
| `setup.sh` | Runs on every node at boot. Builds Ballista, launches scheduler/executor. |

Bring your own dataset-prep script and benchmark driver (kept out of this
repo so the profile stays dataset-agnostic).

## Storage layout

- `/` — OS, Rust, packages.
- `/mnt/work` — Blockstore for Ballista source + build, executor `--work-dir`. Ephemeral; fresh every experiment.
- `/mnt/data` — Blockstore for your dataset (executors only). Ephemeral, optionally pre-populated from an Image-Backed Dataset (`datasetURN`).

## First-ever setup (one time per dataset)

1. Push these files to a public git repo.
2. CloudLab → Create Profile → Repository-based → your repo URL.
3. Instantiate with `datasetURN` left blank.
4. SSH `executor-0`, stage your dataset into `/mnt/data/` (your own script).
5. CloudLab UI → Storage → Create Dataset → Image Backed → pick the experiment, `executor-0`, Blockstore `executor-0-data`. Save the URN.
6. Edit `profile.py`'s `datasetURN` default (or just pass it at instantiate time).

## Every experiment after

1. Instantiate with `datasetURN` set. `/mnt/data` is populated on every executor at boot.
2. SSH `scheduler`. Run your benchmark driver against `scheduler:50050`, pointing at `/mnt/data/<your-layout>` for data.

## Knobs in `profile.py`

- `nExecutors` — how many executors.
- `ballistaRepo` / `ballistaRef` — your Ballista fork + branch/tag/commit SHA. Triggers clean rebuild each experiment.
- `phystype` — hardware type (e.g. `c220g2`, `c6420`, `xl170`).
- `concurrentTasks` — per-executor parallelism (`--concurrent-tasks`). 0 = all cores.
- `linkBandwidth` / `linkLatency` / `linkPlr` — LAN shaping via Emulab dummynet.
- `datasetURN` — URN of the Image-Backed Dataset. Blank for first-ever experiment.
- `dataDiskSize` / `workDiskSize` — Blockstore sizes.
