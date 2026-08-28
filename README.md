# debian-updateagent-pkg

This Debian package provides automated update management for the [AKTIN DWH system](https://github.com/aktin/debian-dwh-pkg). It uses systemd socket activation to monitor and execute DWH package updates, ensuring the system stays current with minimal manual intervention.

## Prerequisites
- `unattended-upgrades` (declared package dependency)
- `systemd` (required for socket activation; not a declared package dependency, assumed present)
- Optional: an existing AKTIN DWH installation, either Debian-native (`wildfly.service`) or
  Docker-based (a docker-compose stack using the `ghcr.io/aktin/notaufnahme-dwh-*` images).
  Detected automatically at runtime by each service script (not at install time) — the package
  installs correctly with either, both, or neither present.

## Installation
```bash
sudo dpkg -i aktin-notaufnahme-updateagent_<version>.deb
sudo apt-get install -f  # Install missing dependencies if any
```

The base package installs without requiring an AKTIN DWH instance. `postinst` handles setup
automatically — it enables persistent journal storage and then enables/starts all four socket
units via the bundled `socket-setup` helper. No manual step is required.

```bash
sudo /usr/lib/aktin-notaufnahme-updateagent/socket-setup configure
```

This is the command `postinst` already runs for you; invoke it manually only to re-enable/restart
the sockets later (e.g. after running `socket-setup remove`). Ownership of the update directories
is not handled by this helper — each service script `chown`s its own update directory to the
`wildfly` user on every run.

## Components
- Update execution service (Port 1003)
- Version info service (Port 1002)
- Docker update execution service (Port 1005)
- Docker version info service (Port 1004)
- APT hooks for automatic version checks (Debian-native and Docker)
- Status monitoring and logging system

## Key Features
- Socket-activated update services
- Docker DWH support alongside Debian-native WildFly installations
- Automated version checking
- Update status reporting
- Integration with APT system
- Update directories owned by the `wildfly` user after each run, so the DWH can read its own status files
- Automatic rollback for Docker DWH updates: if the new deployment fails validation, the previous `compose.yml` is restored and re-deployed

## File Locations
- Update directory (Debian-native DWH): `/var/lib/aktin/update`
- Update directory (Docker DWH, one per tenant): `/var/lib/docker/volumes/<compose_project>_aktin_data/_data/update`
  - `<compose_project>` is the docker-compose project name of the DWH stack being updated. The
    directory is inside that stack's own `aktin_data` volume, so the files below live alongside
    the DWH's own data, not on the host's `/var/lib/aktin`.
- Service scripts: `/usr/bin/aktin-notaufnahme-updateagent`, `-info`, `-docker`, `-docker-info`
- Socket configurations: `/lib/systemd/system`
- APT hooks: `/etc/apt/apt.conf.d/99aktin-notaufnahme-updateagent-info` (Debian-native),
  `/etc/apt/apt.conf.d/99aktin-notaufnahme-updateagent-docker-info` (Docker)

## Configuration
All configuration for this package — filesystem paths, socket ports, service/user names,
external URLs — lives in two files under `src/resources/`: `versions` (the package version) and
`template_vars` (everything else). Nothing else in the repo should contain a hard-coded path, port, or
URL; templates reference these values via `__PLACEHOLDER__` tokens that `build.sh` substitutes at
build time.

## Building
```bash
./src/debian/build.sh [--cleanup] [--skip-deb-build] [--full-clean]
```
Options:
- `--cleanup`: Remove build directory after package creation
- `--skip-deb-build`: Skip the Debian package build step
- `--full-clean`: Remove the build and downloads directories before starting

## Status Files
Debian-native and Docker updates write the same three file names, into their respective update
directory from [File Locations](#file-locations) above — the directory differs, the file names
and meaning don't. Docker's update directory additionally keeps a `server.log` backup of the
DWH's WildFly log from just before the update, copied back into the redeployed container
afterwards.
- `info`: Current and candidate version information
- `log`: Update execution logs
- `result`: Update execution results with success status (reflects the original update attempt,
  not whether an automatic rollback below succeeded). Docker's `result` additionally includes
  `update.error`, empty on success and set to a short stage name (e.g. `fetch_compose`,
  `compose_up`, `post_update_validation`) identifying which step failed otherwise
- `server.log` (Docker only): Backup of the container's WildFly log taken immediately before the update

Before touching anything, the Docker update also backs up the current `compose.yml` into a
`backup/` folder inside the DWH's compose project directory (not the update directory above). If
the new deployment fails validation, that backup is restored and redeployed automatically; on a
successful update the backup is deleted. The `backup/` folder is left in place after a failed
rollback attempt for manual inspection.

## Support
For support, contact: [it-support@aktin.org](mailto:it-support@aktin.org)

Homepage: https://www.aktin.org/
