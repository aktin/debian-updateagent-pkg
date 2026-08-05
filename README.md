# debian-updateagent-pkg

This Debian package provides automated update management for the [AKTIN DWH system](https://github.com/aktin/debian-dwh-pkg). It uses systemd socket activation to monitor and execute DWH package updates, ensuring the system stays current with minimal manual intervention.

## Prerequisites
- AKTIN DWH package
- unattended-upgrades
- systemd

## Installation
```bash
sudo dpkg -i aktin-notaufnahme-updateagent_<version>.deb
sudo apt-get install -f  # Install missing dependencies if any
```

The base package installs without requiring an AKTIN DWH instance. Instance-specific runtime setup is handled separately:

```bash
sudo /usr/lib/aktin-notaufnahme-updateagent/socket-setup configure
```

That helper applies host-coupled configuration such as `wildfly` ownership and enabling or starting the socket units.

## Components
- Update execution service (Port 1003)
- Version info service (Port 1002)
- Docker update execution service (Port 1005)
- Docker version info service (Port 1004)
- APT hook for automatic version checks
- Status monitoring and logging system

## Key Features
- Socket-activated update services
- Automated version checking
- Update status reporting
- Integration with APT system
- Secure execution under WildFly user

## File Locations
- Update directory (Debian-native DWH): `/var/lib/aktin/update`
- Update directory (Docker DWH, one per tenant): `/var/lib/docker/volumes/<compose_project>_aktin_data/_data/update`
  - `<compose_project>` is the docker-compose project name of the DWH stack being updated. The
    directory is inside that stack's own `aktin_data` volume, so the files below live alongside
    the DWH's own data, not on the host's `/var/lib/aktin`.
- Service scripts: `/usr/bin/aktin-notaufnahme-updateagent`, `-info`, `-docker`, `-docker-info`
- Socket configurations: `/lib/systemd/system`
- APT hook: `/etc/apt/apt.conf.d/99aktin-notaufnahme-updateagent-info`

## Building
```bash
./build.sh [--cleanup] [--skip-deb-build]
```
Options:
- `--cleanup`: Remove build directory after package creation
- `--skip-deb-build`: Skip the Debian package build step

## Status Files
Debian-native and Docker updates write the same three file names, into their respective update
directory from [File Locations](#file-locations) above — the directory differs, the file names
and meaning don't. Docker's update directory additionally keeps a `server.log` backup of the
DWH's WildFly log from just before the update, copied back into the redeployed container
afterwards.
- `info`: Current and candidate version information
- `log`: Update execution logs
- `result`: Update execution results with success status
- `server.log` (Docker only): Backup of the container's WildFly log taken immediately before the update

## Support
For support, contact: [it-support@aktin.org](mailto:it-support@aktin.org)

Homepage: https://www.aktin.org/
