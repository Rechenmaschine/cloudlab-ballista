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
    build-essential pkg-config libssl-dev cmake unzip tmux \
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

# 2) Rust — install system-wide under /usr/local so every user gets cargo
# on login (via /etc/profile.d). The default rustup location depends on
# $HOME, which varies based on how setup.sh is invoked (sudo, geniuser,
# etc.), so we pin it explicitly.
export CARGO_HOME=/usr/local/cargo
export RUSTUP_HOME=/usr/local/rustup
if [[ ! -x "$CARGO_HOME/bin/cargo" ]]; then
    # rustup refuses to run when $HOME doesn't match euid's home (sudo
    # leakage). Pin both env vars explicitly to root so the check passes.
    HOME=/root curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | HOME=/root sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
fi
chmod -R a+rX "$CARGO_HOME" "$RUSTUP_HOME"
cat >/etc/profile.d/cargo.sh <<'EOF'
export CARGO_HOME=/usr/local/cargo
export RUSTUP_HOME=/usr/local/rustup
export PATH="$CARGO_HOME/bin:$PATH"
EOF
chmod 0644 /etc/profile.d/cargo.sh
export PATH="$CARGO_HOME/bin:$PATH"

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
    scheduler)
        cargo build --release -p ballista-scheduler -p ballista-cli
        ln -sf "$BALLISTA_DIR/target/release/ballista-scheduler" /usr/local/bin/ballista-scheduler
        ln -sf "$BALLISTA_DIR/target/release/ballista-cli"       /usr/local/bin/ballista-cli
        ;;
    executor)
        cargo build --release -p ballista-executor
        ln -sf "$BALLISTA_DIR/target/release/ballista-executor"  /usr/local/bin/ballista-executor
        ;;
esac

# Shared cargo install dirs stay root-owned but world-rwx so any user can
# `cargo build` against this CARGO_HOME without sudo.
chmod -R a+rwX /usr/local/cargo /usr/local/rustup 2>/dev/null || true

# Hand ownership of the ballista dir to the project user (CloudLab puts
# real users under /users/, excluding the geniuser service account) so
# git/cargo/rm/etc. all Just Work without sudo or safe.directory tricks.
# Also symlink it into their home for convenience.
PROJECT_USER=$(ls /users 2>/dev/null | grep -v '^geniuser$' | head -n1)
if [[ -n "$PROJECT_USER" ]]; then
    chown -R "$PROJECT_USER" /mnt/work/ballista
    ln -sfn /mnt/work/ballista "/users/$PROJECT_USER/ballista"
    chown -h "$PROJECT_USER" "/users/$PROJECT_USER/ballista"
fi

# 4) Launch daemon inside a detached tmux session, owned by the project
# user (not root). That way `tmux attach`, `tail`, and `kill` all work
# without sudo. Falls back to root if no project user was found.
TMUX_SESSION=ballista
RUN_AS="${PROJECT_USER:-root}"
LOG_DIR="/var/log/ballista"
LOG_FILE="${LOG_DIR}/${ROLE}.log"
mkdir -p "$LOG_DIR"
chown "$RUN_AS" "$LOG_DIR"
mkdir -p /mnt/work/ballista-rundir
chown "$RUN_AS" /mnt/work/ballista-rundir

if [[ "$ROLE" == "scheduler" ]]; then
    CMD=(
        ballista-scheduler
        --bind-host 0.0.0.0 --bind-port 50050
        # Advertise to executors via the LAN hostname so their status
        # reports/heartbeats don't try to reach localhost.
        --external-host "$SCHEDULER_HOST"
    )
elif [[ "$ROLE" == "executor" ]]; then
    until nc -z "$SCHEDULER_HOST" 50050; do sleep 5; done
    # The LAN interface name varies (eth1, eno1, enp...). Resolve the
    # local IP by asking the kernel which source IP it would use to reach
    # the scheduler — that's guaranteed to be on the experiment LAN.
    DATA_IP="$(ip -4 -o route get "$(getent hosts "$SCHEDULER_HOST" | awk '{print $1}')" \
               | sed -n 's/.*src \([0-9.]*\).*/\1/p')"
    CMD=(
        ballista-executor
        --bind-host 0.0.0.0 --external-host "$DATA_IP"
        --bind-port 50051
        --scheduler-host "$SCHEDULER_HOST" --scheduler-port 50050
        --work-dir /mnt/work/ballista-rundir
    )
    [[ "$CONCURRENT_TASKS" -gt 0 ]] && CMD+=(--concurrent-tasks "$CONCURRENT_TASKS")
else
    echo "Unknown role: $ROLE" >&2
    exit 1
fi

# Kill any pre-existing session of the same name (idempotent re-runs).
runuser -u "$RUN_AS" -- tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Start detached, owned by $RUN_AS. tee splits output to log file too.
runuser -u "$RUN_AS" -- tmux new-session -d -s "$TMUX_SESSION" \
    "exec '${CMD[0]}' ${CMD[*]:1} 2>&1 | tee '$LOG_FILE'"

echo "[$(date -Is)] $ROLE launched as $RUN_AS in tmux session '$TMUX_SESSION' (log: $LOG_FILE)"

# 5) Liveness check: tmux session should still exist 3s later.
sleep 3
if ! runuser -u "$RUN_AS" -- tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[FAILED $(date -Is)] $ROLE daemon died within 3s; tmux session gone" \
        | tee /var/log/ballista-setup.FAILED >&2
    echo "--- tail of daemon log ---" >&2
    tail -n 50 "$LOG_FILE" >&2 || true
    exit 1
fi

echo "[SUCCESS $(date -Is)] $ROLE setup complete. Attach with: sudo tmux attach -t $TMUX_SESSION"
