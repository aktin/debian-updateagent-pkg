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
- Update directory: `/var/lib/aktin/update`
- Service scripts: `/usr/bin/aktin-notaufnahme-updateagent`
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
- `info`: Contains current and candidate version information
- `log`: Update execution logs
- `result`: Update execution results with success status
- `docker-info`: Placeholder output for Docker version information
- `docker-result`: Placeholder output for Docker update execution

## Support
For support, contact: [it-support@aktin.org](mailto:it-support@aktin.org)

Homepage: https://www.aktin.org/
