# GitHub Actions Multi-Runner Setup

Scripts for deploying multiple GitHub Actions self-hosted runners on a single Debian/Ubuntu machine with resource isolation, Docker configuration, and automated maintenance.

## Background

This was built from hands-on experience setting up a bare-metal GPU workstation as a CI runner fleet. The reference machine:

- **CPU**: AMD 24-core
- **RAM**: 30GB
- **GPU**: NVIDIA RTX 4090 (24GB VRAM)
- **Storage**: 54GB root, 808GB /home, separate /var (21GB) and /tmp (2.7GB)
- **OS**: Debian 13 (trixie), kernel 6.12, Secure Boot enabled
- **Network**: USB Ethernet adapter (primary), onboard NIC (secondary)

We deployed **6 concurrent runners** serving a single repo, handling Claude Code reviews, Terraform plans, Checkov security scans, TFLint, and integration tests — all running in parallel across the runners.

## Features

- **Multiple runners** on a single machine with unique names and systemd services
- **Resource isolation** via systemd cgroups v2 (CPU, memory, swap limits per runner)
- **Docker configuration** with BuildKit, log rotation, address pool isolation, and automatic cleanup
- **Per-runner Docker isolation** via unique `COMPOSE_PROJECT_NAME` environment variables
- **Pre-installed tools**: Claude Code CLI, bun (configurable) — avoids repeated downloads per job
- **Automated maintenance**: weekly updates for pre-installed tools, workspace cleanup, Docker pruning
- **Clean removal** script to unregister and remove all runners

## Requirements

- Debian 12+ or Ubuntu 22.04+ (cgroups v2 required)
- Root access (sudo)
- `gh` CLI authenticated, or a GitHub registration token
- Network access to GitHub and package registries

### Verified Working With

| Component | Version | Notes |
|-----------|---------|-------|
| Debian | 13 (trixie) | Also works on 12 (bookworm) and Ubuntu 22.04+ |
| GitHub Runner | 2.332.0 | Auto-updates on next job when new version released |
| Docker CE | 29.2.1 | Use Docker's official repo, not Debian's `docker.io` package |
| Node.js | 24.x LTS | Via NodeSource repo |
| Terraform | 1.14.x | Via HashiCorp repo — but workflows typically use `hashicorp/setup-terraform` action |
| Claude Code | 2.x | Pre-installed to avoid checksum failures from parallel downloads |

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/mentoroid/gh-runner-setup.git
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
| 24 cores, 30GB | 6 | 400% | 4-5G |
| 32+ cores, 128GB | 8-12 | 300-400% | 8-10G |

Leave ~4 cores and ~6GB RAM for the OS, Docker daemon, and other services.

## Gotchas & Lessons Learned

These are real issues we hit during setup. Save yourself the debugging.

### Docker: Use Docker CE, not Debian's `docker.io`

Debian's `docker.io` package (v26.x) is significantly behind Docker CE (v29.x). The `docker-buildx` Debian package conflicts with `docker-buildx-plugin` from Docker's repo. If upgrading:

```bash
# Remove Debian docker first to avoid file conflicts
sudo apt remove -y docker.io docker-buildx
# Then install Docker CE from Docker's official repo
```

### Claude Code Action: Checksum Failures on Parallel Downloads

When multiple runners all start `claude-code-action` jobs simultaneously, they all try to download and install Claude Code at the same time. We saw consistent "Checksum verification failed" errors across 3-4 parallel jobs. **Pre-installing Claude Code on the runner** (`npm install -g @anthropic-ai/claude-code`) fixes this — the action detects the existing install and skips the download.

### Claude Code Action: Workflow Validation on Old PRs

PRs created before `claude-code-review.yml` was added (or modified) to the default branch will fail with:

> "Workflow validation failed. The workflow file must exist and have identical content to the version on the repository's default branch."

This is a security feature of `claude-code-action`, not a runner issue. Those PRs need to merge `main` into their branch to pick up the matching workflow file.

### /tmp Partition Size

If your machine has a small `/tmp` partition (ours was 2.7GB), large package installs (PyTorch, CUDA toolkits) will fail silently or with cryptic errors. Override with:

```bash
TMPDIR=/some/larger/path pip install <package>
```

### Secure Boot + NVIDIA Drivers

If Secure Boot is enabled, DKMS-built kernel modules (NVIDIA drivers, etc.) need MOK (Machine Owner Key) signing. The NVIDIA `.run` installer supports this directly:

```bash
sudo ./NVIDIA-Linux-x86_64-*.run --silent --dkms \
  --module-signing-secret-key=/var/lib/dkms/mok.key \
  --module-signing-public-key=/var/lib/dkms/mok.pub
```

You'll need to enroll the MOK key via `mokutil --import` and complete enrollment at the UEFI console on next boot.

### Registration Token Expiry

The GitHub runner registration token expires after **1 hour**. Get the token and run `config.sh` in the same session. The setup script handles this by getting one token and registering all runners immediately.

### Runner Auto-Updates

Runners auto-update themselves when they pick up a job and a new version is available. You don't need to manually update runner binaries — GitHub pushes updates through the job mechanism. The maintenance script checks and reports the version but doesn't force updates.

### Debian Package Versions Lag Behind

Git, jq, and other tools from Debian repos will be behind upstream. This is fine for CI — the workflows that need specific versions (Terraform, Node.js, Python) use `setup-*` actions that download their own binaries. Don't fight the distro for tools that don't matter.

### Machine Reboot Issues

Some bare-metal machines (especially with USB NICs or NVIDIA drivers) have issues with `reboot`. If your machine hangs on reboot, use `shutdown -h now` and power-cycle instead. Also ensure USB network adapters are configured with `allow-hotplug` in `/etc/network/interfaces` so they come up reliably on boot.

### `dpkg` Stuck on Debconf Prompts

When installing packages non-interactively (e.g., NVIDIA drivers via apt), `dpkg` can hang waiting for debconf input. Always prefix with:

```bash
DEBIAN_FRONTEND=noninteractive sudo apt install -y <package>
```

If it gets stuck, find and kill the hung postinst process, then run:

```bash
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a
```

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

# Check runners on GitHub
gh api repos/YOUR_ORG/YOUR_REPO/actions/runners --jq '.runners[] | "\(.name)\t\(.status)\t\(.busy)"'
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

All runners share a single system user (`github-runner` by default). This is fine when all runners serve the same repo/org. For multi-tenant setups with untrusted workloads, create separate users per runner.

### Docker Contention

Multiple runners sharing Docker can cause issues. This setup mitigates them:

- **Network collisions**: `default-address-pools` gives each Docker network a unique /24 subnet
- **Compose collisions**: Each runner gets a unique `COMPOSE_PROJECT_NAME` environment variable
- **Container name collisions**: Workflows should use `${{ github.run_id }}` in container names
- **Log bloat**: Container logs capped at 10MB x 3 files
- **Disk growth**: Daily container/image prune + weekly full prune cron
- **GPU contention**: If you have a single GPU, dedicate one runner with a `gpu-exclusive` label and route GPU-bound jobs to it via `runs-on: [self-hosted, gpu-exclusive]`

### Maintenance

The weekly maintenance timer (`runner-maintenance.timer`) runs `/opt/runner-maintenance.sh` which:

1. Updates Claude Code CLI to latest version
2. Updates bun runtime
3. Checks for system package updates (reports count, doesn't auto-install)
4. Reports runner version vs latest (runners auto-update themselves)
5. Cleans old tool cache entries (>30 days) from runner work directories
6. Prunes Docker resources
7. Reports disk usage

## License

MIT
