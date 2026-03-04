# GitHub Actions Multi-Runner Setup

Scripts for deploying multiple GitHub Actions self-hosted runners on a single Debian/Ubuntu machine with resource isolation, Docker configuration, and automated maintenance.

## Features

- **Multiple runners** on a single machine with unique names and systemd services
- **Resource isolation** via systemd cgroups v2 (CPU, memory, swap limits per runner)
- **Docker configuration** with BuildKit, log rotation, address pool isolation, and automatic cleanup
- **Per-runner Docker isolation** via unique `COMPOSE_PROJECT_NAME` environment variables
- **Pre-installed tools**: Claude Code CLI, bun (configurable)
- **Automated maintenance**: weekly updates for pre-installed tools, workspace cleanup, Docker pruning
- **Clean removal** script to unregister and remove all runners

## Requirements

- Debian 12+ or Ubuntu 22.04+ (cgroups v2 required)
- Root access (sudo)
- `gh` CLI authenticated, or a GitHub registration token
- Network access to GitHub and package registries

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/YOUR_ORG/gh-runner-setup.git
cd gh-runner-setup

# 2. Copy and edit the config
cp config.env my-config.env
nano my-config.env  # Set GITHUB_URL, runner count, labels, resource limits

# 3. Run the setup
sudo ./setup-runners.sh my-config.env
```

## Configuration

Edit `config.env` before running. Key settings:

| Variable | Description | Default |
|----------|-------------|---------|
| `GITHUB_URL` | Repository or org URL | (required) |
| `NUM_RUNNERS` | Number of runner instances | `6` |
| `RUNNER_NAME_PREFIX` | Name prefix (e.g., `myhost`) | `runner` |
| `RUNNER_LABELS` | Comma-separated labels | `self-hosted,linux,x64` |
| `CPU_QUOTA_PER_RUNNER` | CPU limit per runner (400% = 4 cores) | `400%` |
| `MEMORY_MAX` | Hard memory limit per runner | `5G` |
| `INSTALL_DOCKER` | Install and configure Docker CE | `true` |
| `INSTALL_CLAUDE_CODE` | Pre-install Claude Code CLI | `true` |

### Sizing Guide

| Machine | Recommended Runners | CPU per Runner | Memory per Runner |
|---------|-------------------|----------------|-------------------|
| 8 cores, 16GB | 2-3 | 200-300% | 4G |
| 16 cores, 32GB | 4-6 | 300-400% | 4-5G |
| 24 cores, 64GB | 6-8 | 300-400% | 6-8G |
| 32+ cores, 128GB | 8-12 | 300-400% | 8-10G |

Leave ~4 cores and ~6GB RAM for the OS, Docker daemon, and other services.

## Files

```
config.env          # Configuration (copy and edit)
setup-runners.sh    # Main setup script
maintenance.sh      # Maintenance script (copied to /opt by setup)
remove-runners.sh   # Clean removal script
```

## Management

```bash
# Check all runners
systemctl list-units 'actions.runner.*'

# Stop/start all runners
systemctl stop 'actions.runner.*'
systemctl start 'actions.runner.*'

# View resource usage
systemd-cgtop github-runners.slice

# Run maintenance manually
sudo /opt/runner-maintenance.sh

# Check maintenance timer
systemctl list-timers runner-maintenance.timer

# View runner logs
journalctl -u 'actions.runner.*' --since '1h ago'
```

## Removal

```bash
sudo ./remove-runners.sh config.env
# Optionally delete runner directories:
sudo rm -rf /opt/actions-runner*
```

## How It Works

### Resource Isolation

Each runner gets a systemd drop-in override that places it in a shared `github-runners.slice` with per-runner limits:

- `CPUQuota`: Limits CPU time (400% = 4 cores)
- `MemoryHigh`: Soft memory limit (triggers reclaim pressure)
- `MemoryMax`: Hard memory limit (OOM kills)
- `Nice`: Lower scheduling priority so interactive tasks aren't affected

### Docker Contention

Multiple runners sharing Docker can cause issues. This setup mitigates them:

- **Network collisions**: `default-address-pools` gives each Docker network a unique /24 subnet
- **Compose collisions**: Each runner gets a unique `COMPOSE_PROJECT_NAME` environment variable
- **Log bloat**: Container logs capped at 10MB x 3 files
- **Disk growth**: Daily container/image prune + weekly full prune cron

### Maintenance

The weekly maintenance timer (`runner-maintenance.timer`) runs `/opt/runner-maintenance.sh` which:

1. Updates Claude Code CLI to latest version
2. Updates bun runtime
3. Checks for system package updates
4. Reports runner version (runners auto-update)
5. Cleans old tool cache entries (>30 days)
6. Prunes Docker resources
7. Reports disk usage

## License

MIT
