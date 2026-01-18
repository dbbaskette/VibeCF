# Cloud Foundry on Docker with BOSH Docker CPI

A complete automation script to deploy Cloud Foundry on Docker using BOSH's Docker CPI. This provides a lightweight, local CF installation suitable for development, testing, and learning.

## Overview

This deployment uses:
- **BOSH Docker CPI** - Official Cloud Foundry BOSH CPI for Docker
- **cf-deployment** - Canonical CF deployment manifest
- **bosh-lite ops file** - Minimized CF footprint for local deployments

## System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 8 GB | 16+ GB |
| Disk | 50 GB | 100+ GB |
| CPU | 4 cores | 8+ cores |

### Supported Platforms
- Ubuntu 22.04+ (recommended)
- Debian 11+
- Other Linux distributions with Docker support

## Quick Start

```bash
# Clone this repo or copy the files
chmod +x deploy.sh

# Run full deployment (takes 30-60 minutes)
./deploy.sh

# Or deploy in stages
./deploy.sh director  # BOSH Director only
./deploy.sh cf        # Cloud Foundry (after director)
```

## Commands

| Command | Description |
|---------|-------------|
| `./deploy.sh` or `./deploy.sh full` | Full deployment |
| `./deploy.sh director` | Deploy BOSH Director only |
| `./deploy.sh cf` | Deploy CF only (director must exist) |
| `./deploy.sh status` | Show deployment status |
| `./deploy.sh info` | Show CF connection info |
| `./deploy.sh destroy` | Tear down everything |

## Configuration

Environment variables can be set before running:

```bash
# Custom host IP (auto-detected by default)
export HOST_IP=192.168.1.100

# Custom system domain
export SYSTEM_DOMAIN=cf.local

./deploy.sh
```

## Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Docker Host                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │           Docker Network: cf-network                 │    │
│  │                  10.245.0.0/16                       │    │
│  │                                                      │    │
│  │  ┌──────────────┐  ┌──────────────┐                 │    │
│  │  │    BOSH      │  │    CF VMs    │                 │    │
│  │  │   Director   │  │  (containers)│                 │    │
│  │  │  10.245.0.2  │  │ 10.245.0.11+ │                 │    │
│  │  └──────────────┘  └──────────────┘                 │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## File Structure

After deployment:

```
vibecf/
├── deploy.sh                    # Main deployment script
├── helpers.sh                   # Helper functions/aliases
├── ops/
│   └── reduce-resources.yml     # Ops file for low-resource environments
├── README.md                    # This file
└── workspace/
    ├── bosh-deployment/         # BOSH deployment manifests
    ├── cf-deployment/           # CF deployment manifests
    ├── state/
    │   ├── director-state.json  # BOSH Director state
    │   ├── cloud-config.yml     # Cloud config
    │   ├── bosh-env.sh          # BOSH environment vars
    │   └── cf-info.txt          # CF connection info
    └── creds/
        ├── director-creds.yml   # Director credentials
        └── cf-creds.yml         # CF credentials
```

## Accessing Cloud Foundry

After deployment, connection info is displayed and saved to `workspace/state/cf-info.txt`:

```bash
# Login to CF
cf login -a https://api.<HOST_IP>.nip.io -u admin --skip-ssl-validation

# Create org and space
cf create-org myorg
cf target -o myorg
cf create-space dev
cf target -s dev

# Push an app
cf push myapp
```

## Managing the Deployment

### Using Helper Scripts (Recommended)

A `helpers.sh` script is provided to simplify common tasks. Source it to access shortcuts:

```bash
source helpers.sh

# List commands
cf_help

# Quick status checks
bosh_vms
docker_cf_containers

# SSH into a VM (e.g., router/0)
bosh_ssh router/0

# Tail logs
bosh_logs router/0

# Login to CF and setup basic org/space
cf_setup
```

### Manual Management

If you prefer running commands manually:

### View BOSH Status

```bash
source workspace/state/bosh-env.sh
bosh -e docker vms
bosh -e docker deployments
```

### SSH into VMs

```bash
source workspace/state/bosh-env.sh
bosh -e docker -d cf ssh <instance>
```

### View Logs

```bash
source workspace/state/bosh-env.sh
bosh -e docker -d cf logs <instance>
```

### Redeploy CF

```bash
./deploy.sh cf
```

## Known Limitations

1. **Persistent Disks**: The Docker CPI has limited support for persistent disk operations during `bosh deploy` (works during `bosh create-env`).

2. **Performance**: Running CF in Docker containers is slower than on dedicated VMs/cloud infrastructure.

3. **Networking**: Some advanced networking features may not work as expected.

4. **Windows Cells**: Not supported with Docker CPI.

## Troubleshooting

### "Docker socket not writable"

```bash
sudo chmod a+rw /var/run/docker.sock
# Or add your user to docker group:
sudo usermod -aG docker $USER
newgrp docker
```

### Director deployment fails

Check Docker is running:
```bash
docker info
```

Check network exists:
```bash
docker network ls | grep cf-network
```

### CF deployment hangs

Monitor with:
```bash
source workspace/state/bosh-env.sh
bosh -e docker task --recent
```

### Out of disk space

Clean up Docker:
```bash
docker system prune -a
```

### DNS resolution issues

If apps can't resolve each other, ensure BOSH DNS runtime config is applied:
```bash
source workspace/state/bosh-env.sh
bosh -e docker configs
```

## Resource Tuning

For systems with limited resources, you can modify `workspace/state/cloud-config.yml` after initial setup:

```yaml
vm_types:
- name: minimal
  cloud_properties:
    cpus: 1
    memory: 1024  # Reduce memory
    ephemeral_disk: 5120  # Reduce disk
```

Then update:
```bash
source workspace/state/bosh-env.sh
bosh -e docker update-cloud-config workspace/state/cloud-config.yml
./deploy.sh cf  # Redeploy
```

## Contributing

Issues and PRs welcome!

## License

Apache 2.0

## References

- [BOSH Docker CPI](https://github.com/cloudfoundry/bosh-docker-cpi-release)
- [bosh-deployment](https://github.com/cloudfoundry/bosh-deployment)
- [cf-deployment](https://github.com/cloudfoundry/cf-deployment)
- [BOSH Documentation](https://bosh.io/docs/)
- [Cloud Foundry Documentation](https://docs.cloudfoundry.org/)
