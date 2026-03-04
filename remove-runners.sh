#!/usr/bin/env bash
set -euo pipefail

# GitHub Actions Multi-Runner Removal Script
# Cleanly removes all runners from this machine

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/config.env}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

# shellcheck source=config.env disable=SC1091
source "$CONFIG_FILE"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root"
  exit 1
fi

echo "This will remove all ${NUM_RUNNERS} runners from this machine."
echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r

# Get removal token
if command -v gh &>/dev/null; then
  URL_PATH="${GITHUB_URL#https://github.com/}"
  SLASH_COUNT=$(echo "$URL_PATH" | tr -cd '/' | wc -c)
  if [ "$SLASH_COUNT" -ge 1 ]; then
    TOKEN=$(gh api "repos/${URL_PATH}/actions/runners/remove-token" --method POST --jq '.token')
  else
    TOKEN=$(gh api "orgs/${URL_PATH}/actions/runners/remove-token" --method POST --jq '.token')
  fi
else
  echo "Enter a removal token:"
  read -r TOKEN
fi

for i in $(seq 1 "$NUM_RUNNERS"); do
  RUNNER_NUM=$(printf "%02d" "$i")
  if [ "$i" -eq 1 ]; then
    RUNNER_DIR="${RUNNER_BASE_DIR}/actions-runner"
  else
    RUNNER_DIR="${RUNNER_BASE_DIR}/actions-runner-${RUNNER_NUM}"
  fi

  if [ ! -d "$RUNNER_DIR" ]; then
    echo "Skipping ${RUNNER_DIR} (not found)"
    continue
  fi

  echo "=== Removing runner in ${RUNNER_DIR} ==="
  cd "$RUNNER_DIR"

  # Stop and uninstall service
  if [ -f .service ]; then
    ./svc.sh stop 2>/dev/null || true
    ./svc.sh uninstall 2>/dev/null || true
  fi

  # Unregister runner
  if [ -f .runner ]; then
    sudo -u "$RUNNER_USER" ./config.sh remove --token "$TOKEN" 2>/dev/null || true
  fi

  echo "Removed runner from ${RUNNER_DIR}"
done

# Remove systemd slice and maintenance timer
rm -f /etc/systemd/system/github-runners.slice
rm -f /etc/systemd/system/runner-maintenance.service
rm -f /etc/systemd/system/runner-maintenance.timer
systemctl daemon-reload

echo ""
echo "All runners removed. Runner directories are still on disk."
echo "To delete them: rm -rf ${RUNNER_BASE_DIR}/actions-runner*"
