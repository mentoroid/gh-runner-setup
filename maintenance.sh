#!/usr/bin/env bash
# GitHub Actions Runner Maintenance Script
# Variables RUNNER_USER, RUNNER_BASE_DIR, NUM_RUNNERS are injected by setup-runners.sh
set -euo pipefail

# Defaults (overridden by injected variables)
RUNNER_USER="${RUNNER_USER:-github-runner}"
RUNNER_BASE_DIR="${RUNNER_BASE_DIR:-/opt}"
NUM_RUNNERS="${NUM_RUNNERS:-6}"

LOG_TAG="runner-maintenance"
log() { echo "$(date -Iseconds) $*" | logger -t "$LOG_TAG"; echo "$*"; }

log "=== Runner maintenance started ==="

# 1. Update Claude Code CLI (if installed)
if sudo -u "$RUNNER_USER" bash -c "export HOME=/home/${RUNNER_USER} && export PATH=\$HOME/.npm-global/bin:\$PATH && command -v claude" &>/dev/null; then
  log "Updating Claude Code..."
  sudo -u "$RUNNER_USER" bash -c "
    export HOME=/home/${RUNNER_USER}
    export NPM_CONFIG_PREFIX=\$HOME/.npm-global
    export PATH=\$HOME/.npm-global/bin:\$PATH
    npm update -g @anthropic-ai/claude-code 2>&1
  " | logger -t "$LOG_TAG"
  CLAUDE_VER=$(sudo -u "$RUNNER_USER" bash -c "export HOME=/home/${RUNNER_USER} && export PATH=\$HOME/.npm-global/bin:\$PATH && claude --version 2>/dev/null" || echo "unknown")
  log "Claude Code: $CLAUDE_VER"
fi

# 2. Update bun (if installed)
if [ -f "/home/${RUNNER_USER}/.bun/bin/bun" ]; then
  log "Updating bun..."
  sudo -u "$RUNNER_USER" bash -c "
    export HOME=/home/${RUNNER_USER}
    export BUN_INSTALL=\$HOME/.bun
    curl -fsSL https://bun.sh/install | bash 2>&1
  " | logger -t "$LOG_TAG"
  BUN_VER=$(sudo -u "$RUNNER_USER" bash -c "export HOME=/home/${RUNNER_USER} && \$HOME/.bun/bin/bun --version 2>/dev/null" || echo "unknown")
  log "Bun: $BUN_VER"
fi

# 3. System package updates check
log "Checking system package updates..."
apt-get update -qq 2>&1 | logger -t "$LOG_TAG"
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c '/' || true)
log "$UPGRADABLE packages upgradable"

# 4. Check GitHub Actions runner version
CURRENT_RUNNER_VER=""
for bindir in "${RUNNER_BASE_DIR}"/actions-runner/bin.*; do
  if [ -d "$bindir" ]; then
    VER=$(echo "$bindir" | grep -oP '\d+\.\d+\.\d+' || true)
    if [ -n "$VER" ]; then
      CURRENT_RUNNER_VER="$VER"
    fi
  fi
done
LATEST_RUNNER_VER=$(curl -sfL https://api.github.com/repos/actions/runner/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+' || echo "unknown")
log "Runner: current=${CURRENT_RUNNER_VER:-unknown} latest=$LATEST_RUNNER_VER"
if [ -n "$CURRENT_RUNNER_VER" ] && [ "$CURRENT_RUNNER_VER" != "$LATEST_RUNNER_VER" ] && [ "$LATEST_RUNNER_VER" != "unknown" ]; then
  log "NOTE: Runner update available ($CURRENT_RUNNER_VER -> $LATEST_RUNNER_VER). Runners auto-update on next job."
fi

# 5. Clean runner work directories (old tool cache entries >30 days)
log "Cleaning runner work directories..."
FREED=0
for i in $(seq 1 "$NUM_RUNNERS"); do
  RUNNER_NUM=$(printf "%02d" "$i")
  if [ "$i" -eq 1 ]; then
    WORK_DIR="${RUNNER_BASE_DIR}/actions-runner/_work"
  else
    WORK_DIR="${RUNNER_BASE_DIR}/actions-runner-${RUNNER_NUM}/_work"
  fi
  if [ -d "$WORK_DIR" ]; then
    SIZE_BEFORE=$(du -sm "$WORK_DIR" 2>/dev/null | cut -f1 || echo 0)
    while IFS= read -r tooldir; do
      find "$tooldir" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2>/dev/null
    done < <(find "$WORK_DIR" -maxdepth 3 -name "_tool" -type d 2>/dev/null)
    SIZE_AFTER=$(du -sm "$WORK_DIR" 2>/dev/null | cut -f1 || echo 0)
    DELTA=$((SIZE_BEFORE - SIZE_AFTER))
    FREED=$((FREED + DELTA))
  fi
done
log "Freed ${FREED}MB from runner work directories"

# 6. Docker cleanup (if docker is available)
if command -v docker &>/dev/null; then
  log "Docker cleanup..."
  docker system prune -f 2>&1 | logger -t "$LOG_TAG"
fi

# 7. Report disk usage
log "Disk usage:"
df -h / /home 2>/dev/null | logger -t "$LOG_TAG"
df -h / /home 2>/dev/null

log "=== Runner maintenance complete ==="
