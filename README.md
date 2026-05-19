# Docker PBS Cluster

A containerized OpenPBS cluster for CI testing of software that requires a working batch system.

## Architecture

| Container | Role | PBS Daemons |
|-----------|------|-------------|
| `pbsserver` | Head node (server + scheduler) | `pbs_server`, `pbs_sched`, `pbs_comm`, PostgreSQL |
| `pbsfrontend` | Login/submission node | Client tools only (`qsub`, `qstat`, `qdel`, `pbsnodes`) |
| `pbsnode1-3` | Compute/execution hosts | `pbs_mom` |

## Quick Start

```bash
docker compose up --build -d
```

## Verify the Cluster

```bash
# Check node status
docker exec pbs-frontend pbsnodes -a

# Submit a test job
docker exec pbs-frontend qsub -- /bin/hostname

# Check job status
docker exec pbs-frontend qstat

# SSH to compute nodes
docker exec pbs-frontend ssh pbsnode1 hostname
```

## Shut Down

```bash
docker compose down
```

## Configuration

- **OpenPBS Version**: Set via `OPENPBS_VERSION` build arg in Dockerfiles (default: `23.06.06`)
- **Queue**: A default execution queue `workq` is created automatically
- **Nodes**: 3 compute nodes are registered with the server at startup
- **Authentication**: PBS built-in auth (no external auth daemon like munge needed)
- **Shared Storage**: `/home/admin` is shared across all containers via a Docker volume

## PBS Commands (vs. Slurm equivalents)

| PBS Command | Slurm Equivalent | Purpose |
|-------------|-------------------|---------|
| `qsub` | `sbatch` | Submit a batch job |
| `qstat` | `squeue` | Show job status |
| `qdel` | `scancel` | Cancel a job |
| `pbsnodes` | `sinfo` | Show node status |
| `qmgr` | `scontrol` | Cluster management |
| `qsub -- cmd` | `srun cmd` | Run interactive/immediate command |

## Notes

- OpenPBS is the open-source community edition of PBS Professional
- The server container requires PostgreSQL for its datastore
- Compute nodes (`pbs_mom`) register with the server automatically
- All containers share the same `admin` user with passwordless sudo
