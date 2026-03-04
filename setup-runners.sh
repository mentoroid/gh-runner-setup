#!/usr/bin/env bash
set -euo pipefail

# GitHub Actions Multi-Runner Setup Script
# Sets up multiple self-hosted runners on a single Debian/Ubuntu machine
# with systemd resource limits, Docker configuration, and maintenance automation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/config.env}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  echo "Usage: $0 [config.env]"
  exit 1
fi

# shellcheck source=config.env disable=SC1091
source "$CONFIG_FILE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root (use sudo)"
  exit 1
fi

# Validate required config
if [ -z "${GITHUB_URL:-}" ] || [[ "$GITHUB_URL" == *"YOUR_ORG"* ]]; then
  err "GITHUB_URL not configured. Edit config.env first."
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  armv7l)  RUNNER_ARCH="arm" ;;
  *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

log "Architecture: $ARCH ($RUNNER_ARCH)"

###############################################################################
# 1. System prerequisites
###############################################################################
log "Installing system prerequisites..."
apt-get update -qq
apt-get install -y -qq curl jq git unzip ca-certificates gnupg

###############################################################################
# 2. Create runner user
###############################################################################
if ! id "$RUNNER_USER" &>/dev/null; then
  log "Creating user: $RUNNER_USER"
  useradd -r -m -s /bin/bash -d "/home/${RUNNER_USER}" "$RUNNER_USER"
else
  log "User $RUNNER_USER already exists"
fi

###############################################################################
# 3. Docker setup
###############################################################################
if [ "${INSTALL_DOCKER:-false}" = true ]; then
  if ! command -v docker &>/dev/null || [[ "$(docker --version)" != *"Docker Engine"* ]]; then
    log "Installing Docker CE..."

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Detect distro
    if [ -f /etc/os-release ]; then
      # shellcheck source=/dev/null
      . /etc/os-release
      DISTRO_CODENAME="${VERSION_CODENAME:-}"
      DISTRO_ID="${ID:-}"
    fi

    # Add repo (Debian or Ubuntu)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq

    # Remove conflicting packages
    apt-get remove -y docker.io docker-buildx containerd runc 2>/dev/null || true

    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    log "Docker already installed: $(docker --version)"
  fi

  # Add runner user to docker group
  usermod -aG docker "$RUNNER_USER"

  # Configure Docker daemon
  log "Configuring Docker daemon..."
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<DOCKEREOF
{
  "default-address-pools": [
    {"base": "172.17.0.0/12", "size": 24}
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE:-10m}",
    "max-file": "${DOCKER_LOG_MAX_FILES:-3}"
  },
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  }
}
DOCKEREOF

  systemctl restart docker

  # Docker cleanup cron
  cat > /etc/cron.d/docker-prune <<'CRONEOF'
# Weekly Docker cleanup - Sunday 3 AM
0 3 * * 0 root docker system prune -af --volumes 2>&1 | logger -t docker-prune
# Daily cleanup of stopped containers and dangling images
0 4 * * * root docker container prune -f 2>&1 | logger -t docker-prune && docker image prune -f 2>&1 | logger -t docker-prune
CRONEOF

  log "Docker configured with BuildKit, log rotation, and cleanup cron"
fi

###############################################################################
# 4. Detect runner version
###############################################################################
if [ -z "${RUNNER_VERSION:-}" ]; then
  log "Detecting latest runner version..."
  RUNNER_VERSION=$(curl -sfL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
fi
log "Runner version: $RUNNER_VERSION"

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
TARBALL_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

# Download tarball once
TARBALL_PATH="/tmp/${TARBALL}"
if [ ! -f "$TARBALL_PATH" ]; then
  log "Downloading runner tarball..."
  curl -sL -o "$TARBALL_PATH" "$TARBALL_URL"
fi

###############################################################################
# 5. Get registration token
###############################################################################
log "Obtaining registration token..."
warn "You need the 'gh' CLI authenticated, or provide a token manually."

if command -v gh &>/dev/null; then
  # Detect if URL is org-level or repo-level
  URL_PATH="${GITHUB_URL#https://github.com/}"
  SLASH_COUNT=$(echo "$URL_PATH" | tr -cd '/' | wc -c)

  if [ "$SLASH_COUNT" -ge 1 ]; then
    # Repo-level
    TOKEN=$(gh api "repos/${URL_PATH}/actions/runners/registration-token" --method POST --jq '.token')
  else
    # Org-level
    TOKEN=$(gh api "orgs/${URL_PATH}/actions/runners/registration-token" --method POST --jq '.token')
  fi
  log "Registration token obtained (valid for 1 hour)"
else
  echo ""
  echo "Enter a registration token (get from GitHub > Settings > Actions > Runners > New):"
  read -r TOKEN
fi

if [ -z "${TOKEN:-}" ]; then
  err "Failed to obtain registration token"
  exit 1
fi

###############################################################################
# 6. Create systemd slice
###############################################################################
log "Creating systemd resource slice..."
cat > /etc/systemd/system/github-runners.slice <<SLICEEOF
[Unit]
Description=GitHub Actions Runners Slice
Before=slices.target

[Slice]
CPUQuota=${SLICE_CPU_QUOTA}
MemoryMax=${SLICE_MEMORY_MAX}
MemoryHigh=${SLICE_MEMORY_HIGH}
SLICEEOF

###############################################################################
# 7. Install runners
###############################################################################
for i in $(seq 1 "$NUM_RUNNERS"); do
  RUNNER_NUM=$(printf "%02d" "$i")
  RUNNER_NAME="${RUNNER_NAME_PREFIX}-${RUNNER_NUM}"

  if [ "$i" -eq 1 ]; then
    RUNNER_DIR="${RUNNER_BASE_DIR}/actions-runner"
  else
    RUNNER_DIR="${RUNNER_BASE_DIR}/actions-runner-${RUNNER_NUM}"
  fi

  log "Setting up ${RUNNER_NAME} in ${RUNNER_DIR}..."

  # Create directory
  mkdir -p "$RUNNER_DIR"
  chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

  # Skip if already configured
  if [ -f "${RUNNER_DIR}/.runner" ]; then
    warn "${RUNNER_NAME} already configured, skipping (use --force to reconfigure)"
    continue
  fi

  # Extract runner
  cd "$RUNNER_DIR"
  sudo -u "$RUNNER_USER" tar xzf "$TARBALL_PATH"

  # Register runner
  sudo -u "$RUNNER_USER" ./config.sh \
    --url "$GITHUB_URL" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --unattended \
    --replace

  # Install systemd service
  ./svc.sh install "$RUNNER_USER"

  # Get service name
  SERVICE_NAME=$(cat .service)

  # Add resource limit overrides
  mkdir -p "/etc/systemd/system/${SERVICE_NAME}.d"
  cat > "/etc/systemd/system/${SERVICE_NAME}.d/resources.conf" <<RESEOF
[Service]
Slice=github-runners.slice
CPUQuota=${CPU_QUOTA_PER_RUNNER}
MemoryHigh=${MEMORY_HIGH}
MemoryMax=${MEMORY_MAX}
MemorySwapMax=${MEMORY_SWAP_MAX}
Nice=${NICE_VALUE}
TasksMax=${TASKS_MAX}

# Docker contention: unique compose project per runner
Environment=DOCKER_BUILDKIT=1
Environment=COMPOSE_PROJECT_NAME=runner-${RUNNER_NUM}
RESEOF

  log "${RUNNER_NAME} installed"
done

# Reload and start all
systemctl daemon-reload

for i in $(seq 1 "$NUM_RUNNERS"); do
  RUNNER_NUM=$(printf "%02d" "$i")
  if [ "$i" -eq 1 ]; then
    RUNNER_DIR="${RUNNER_BASE_DIR}/actions-runner"
  else
    RUNNER_DIR="${RUNNER_BASE_DIR}/actions-runner-${RUNNER_NUM}"
  fi
  if [ -f "${RUNNER_DIR}/.service" ]; then
    SERVICE_NAME=$(cat "${RUNNER_DIR}/.service")
    systemctl start "$SERVICE_NAME"
    log "Started $SERVICE_NAME"
  fi
done

###############################################################################
# 8. Pre-install tools
###############################################################################
if [ "${INSTALL_CLAUDE_CODE:-false}" = true ]; then
  log "Pre-installing Claude Code..."
  sudo -u "$RUNNER_USER" bash -c "
    export HOME=/home/${RUNNER_USER}
    export NPM_CONFIG_PREFIX=\$HOME/.npm-global
    mkdir -p \$NPM_CONFIG_PREFIX
    export PATH=\$HOME/.npm-global/bin:\$PATH
    npm install -g @anthropic-ai/claude-code 2>&1
  " | tail -5
  CLAUDE_VER=$(sudo -u "$RUNNER_USER" bash -c "export HOME=/home/${RUNNER_USER} && export PATH=\$HOME/.npm-global/bin:\$PATH && claude --version 2>/dev/null" || echo "failed")
  log "Claude Code: $CLAUDE_VER"
fi

if [ "${INSTALL_BUN:-false}" = true ]; then
  log "Pre-installing bun..."
  sudo -u "$RUNNER_USER" bash -c "
    export HOME=/home/${RUNNER_USER}
    export BUN_INSTALL=\$HOME/.bun
    curl -fsSL https://bun.sh/install | bash 2>&1
  " | tail -3
  BUN_VER=$(sudo -u "$RUNNER_USER" bash -c "export HOME=/home/${RUNNER_USER} && \$HOME/.bun/bin/bun --version 2>/dev/null" || echo "failed")
  log "Bun: $BUN_VER"
fi

###############################################################################
# 9. Maintenance timer
###############################################################################
if [ "${ENABLE_MAINTENANCE_TIMER:-false}" = true ]; then
  log "Installing maintenance script and timer..."

  # Copy maintenance script
  cp "${SCRIPT_DIR}/maintenance.sh" /opt/runner-maintenance.sh
  chmod +x /opt/runner-maintenance.sh

  # Inject config into maintenance script header
  sed -i "2i\\RUNNER_USER=\"${RUNNER_USER}\"" /opt/runner-maintenance.sh
  sed -i "3i\\RUNNER_BASE_DIR=\"${RUNNER_BASE_DIR}\"" /opt/runner-maintenance.sh
  sed -i "4i\\NUM_RUNNERS=${NUM_RUNNERS}" /opt/runner-maintenance.sh

  cat > /etc/systemd/system/runner-maintenance.service <<SVCEOF
[Unit]
Description=GitHub Actions Runner Maintenance
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/runner-maintenance.sh
TimeoutStartSec=600
SVCEOF

  cat > /etc/systemd/system/runner-maintenance.timer <<TIMEREOF
[Unit]
Description=Weekly GitHub Actions Runner Maintenance

[Timer]
OnCalendar=${MAINTENANCE_SCHEDULE}
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

  systemctl daemon-reload
  systemctl enable runner-maintenance.timer
  systemctl start runner-maintenance.timer
  log "Maintenance timer enabled"
fi

###############################################################################
# Cleanup
###############################################################################
rm -f "$TARBALL_PATH"

###############################################################################
# Summary
###############################################################################
echo ""
echo "=============================================="
echo "  GitHub Actions Multi-Runner Setup Complete"
echo "=============================================="
echo ""
echo "Runners: ${NUM_RUNNERS}x ${RUNNER_NAME_PREFIX}-01..$(printf "%02d" "$NUM_RUNNERS")"
echo "User:    ${RUNNER_USER}"
echo "Labels:  ${RUNNER_LABELS}"
echo "Limits:  CPU=${CPU_QUOTA_PER_RUNNER} Mem=${MEMORY_MAX} per runner"
echo ""
echo "Commands:"
echo "  Status:      systemctl list-units 'actions.runner.*'"
echo "  Stop all:    systemctl stop 'actions.runner.*'"
echo "  Start all:   systemctl start 'actions.runner.*'"
echo "  Maintenance: /opt/runner-maintenance.sh"
echo "  Logs:        journalctl -u actions.runner.* --since '1h ago'"
echo ""
