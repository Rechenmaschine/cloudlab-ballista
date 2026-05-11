#!/usr/bin/env bash
# setup.sh — runs on every node at experiment startup.
# Builds Ballista from the given repo+ref and launches the role-specific
# daemon. That's the whole job. Data prep and workload-gen are yours to
# do manually on the scheduler after SSH.
#
# Ballista is built on /mnt/work (an ephemeral Blockstore that doesn't
# survive experiment termination), so every new experiment with a fresh
# ballistaRef gets a clean from-scratch build. Reboots WITHIN one
# experiment skip the rebuild because the Blockstore persists across
# reboots inside the experiment.
#
# Usage: setup.sh <role> <ballista_repo> <ballista_ref> <concurrent_tasks>
set -euo pipefail

# Redirect everything to a stable log file (we run as root via sudo, so
# /var/log/ is writable). The CloudLab startup-service log lives elsewhere
# and may not honor user-side redirects from the outer shell.
exec >>/var/log/ballista-setup.log 2>&1

# Loud failure: drop a marker file, print to log, and propagate non-zero
# exit so CloudLab sees the Startup service failed.
trap 'rc=$?; \
      echo "[FAILED $(date -Is)] setup.sh rc=$rc line=$LINENO cmd=\"$BASH_COMMAND\"" \
        | tee /var/log/ballista-setup.FAILED >&2; \
      exit $rc' ERR

ROLE="${1:?role required}"
BALLISTA_REPO="${2:?ballista repo url required}"
BALLISTA_REF="${3:?ballista ref required}"
CONCURRENT_TASKS="${4:-0}"

SCHEDULER_HOST="scheduler"

echo "[$(date -Is)] $(geni-get client_id) role=$ROLE ref=$BALLISTA_REF tasks=$CONCURRENT_TASKS"

# 1) Build deps
export DEBIAN_FRONTEND=noninteractive
# man-db rebuilds its index after every package install and is notoriously
# slow on fresh Blockstores. We don't need man pages, so disable it.
echo 'set man-db/auto-update false' | debconf-communicate >/dev/null || true
dpkg-divert --local --rename --add /usr/bin/mandb >/dev/null || true
ln -sf /bin/true /usr/bin/mandb
apt-get update
apt-get install -y --no-install-recommends \
    build-essential pkg-config libssl-dev cmake unzip \
    git curl ca-certificates netcat-openbsd

# 1b) protoc (Ubuntu 22.04 ships v3.12; Ballista's substrait dep uses
# proto3 optional fields which need >= 3.15. Install upstream release.)
PROTOC_VERSION=27.3
if ! protoc --version 2>/dev/null | grep -qE "libprotoc (2[7-9]|[3-9][0-9])"; then
    PROTOC_ZIP=protoc-${PROTOC_VERSION}-linux-x86_64.zip
    curl -fsSL -o "/tmp/${PROTOC_ZIP}" \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/${PROTOC_ZIP}"
    unzip -o "/tmp/${PROTOC_ZIP}" -d /usr/local
    rm "/tmp/${PROTOC_ZIP}"
fi

# 2) Rust (default install path: $HOME/.cargo, which is /root/.cargo here).
if ! command -v cargo >/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
fi
source "$HOME/.cargo/env"

# 3) Fetch + build Ballista on /mnt/work (ephemeral, not snapshotted).
chmod 1777 /mnt/work || true
BALLISTA_DIR=/mnt/work/ballista
mkdir -p "$BALLISTA_DIR"
if [[ ! -d "$BALLISTA_DIR/.git" ]]; then
    git init "$BALLISTA_DIR"
    git -C "$BALLISTA_DIR" remote add origin "$BALLISTA_REPO"
fi
git -C "$BALLISTA_DIR" fetch --depth 1 origin "$BALLISTA_REF"
git -C "$BALLISTA_DIR" checkout FETCH_HEAD
cd "$BALLISTA_DIR"
case "$ROLE" in
    scheduler) cargo build --release -p ballista-scheduler ;;
    executor)  cargo build --release -p ballista-executor ;;
esac

# 4) Launch daemon
if [[ "$ROLE" == "scheduler" ]]; then
    nohup "$BALLISTA_DIR/target/release/ballista-scheduler" \
        --bind-host 0.0.0.0 --bind-port 50050 \
        >/var/log/ballista-scheduler.log 2>&1 &
    DAEMON_PID=$!
    echo "[$(date -Is)] Scheduler launched (pid=$DAEMON_PID)"

elif [[ "$ROLE" == "executor" ]]; then
    until nc -z "$SCHEDULER_HOST" 50050; do sleep 5; done

    DATA_IP="$(ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1)"
    EXTRA=""
    [[ "$CONCURRENT_TASKS" -gt 0 ]] && EXTRA="--concurrent-tasks $CONCURRENT_TASKS"

    mkdir -p /mnt/work/ballista-rundir
    # shellcheck disable=SC2086
    nohup "$BALLISTA_DIR/target/release/ballista-executor" \
        --bind-host 0.0.0.0 --external-host "$DATA_IP" \
        --bind-port 50051 \
        --scheduler-host "$SCHEDULER_HOST" --scheduler-port 50050 \
        --work-dir /mnt/work/ballista-rundir \
        $EXTRA \
        >/var/log/ballista-executor.log 2>&1 &
    DAEMON_PID=$!
    echo "[$(date -Is)] Executor launched (pid=$DAEMON_PID)"

else
    echo "Unknown role: $ROLE" >&2
    exit 1
fi

# 5) Liveness check: daemon should still be alive 3s after launch.
sleep 3
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "[FAILED $(date -Is)] $ROLE daemon (pid=$DAEMON_PID) died within 3s" \
        | tee /var/log/ballista-setup.FAILED >&2
    echo "--- tail of daemon log ---" >&2
    tail -n 50 "/var/log/ballista-${ROLE}.log" >&2 || true
    exit 1
fi

echo "[SUCCESS $(date -Is)] $ROLE setup complete (pid=$DAEMON_PID)"
