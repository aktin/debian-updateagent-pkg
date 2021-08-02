#!/bin/bash
set -euo pipefail

# Check if variables are empty
if [ -z "${PACKAGE}" ]; then echo "\$PACKAGE is empty."; exit 1; fi
if [ -z "${VERSION}" ]; then echo "\$VERSION is empty."; exit 1; fi
if [ -z "${DBUILD}" ]; then echo "\$DBUILD is empty."; exit 1; fi

# Superdirectory this script is located in + /resources
DRESOURCES="$( cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" &> /dev/null && pwd )/resources"

function sedvars() {
	mkdir -p "$(dirname "$2")"
	sed -e "s|__AKTINUPDATEDIR__|/var/lib/aktin/update|g" \
	    -e "s|__PACKAGE__|${PACKAGE}|g" \
	    -e "s|__VERSION__|${VERSION}|g" \
	    "${1}" > "${2}"
}

function build_linux() {
	sedvars "${DRESOURCES}/update" "${DBUILD}/usr/bin/${PACKAGE}"
	sedvars "${DRESOURCES}/update.service" "${DBUILD}/lib/systemd/system/${PACKAGE}@.service"
	sedvars "${DRESOURCES}/update.socket" "${DBUILD}/lib/systemd/system/${PACKAGE}.socket"
	sedvars "${DRESOURCES}/info" "${DBUILD}/usr/bin/${PACKAGE}-info"
	sedvars "${DRESOURCES}/apt.update.post-invoke" "${DBUILD}/etc/apt/apt.conf.d/99${PACKAGE}-info"
	sedvars "${DRESOURCES}/info.service" "${DBUILD}/lib/systemd/system/${PACKAGE}-info@.service"
	sedvars "${DRESOURCES}/info.socket" "${DBUILD}/lib/systemd/system/${PACKAGE}-info.socket"
	chmod +x "${DBUILD}/usr/bin/${PACKAGE}" "${DBUILD}/usr/bin/${PACKAGE}-info"
}

