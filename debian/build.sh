#!/bin/bash
set -euo pipefail

# Required parameters
PACKAGE="${1}"
VERSION="${2}"

# Check if variables are empty
if [ -z "${PACKAGE}" ]; then echo "\$PACKAGE is empty."; exit 1; fi
if [ -z "${VERSION}" ]; then echo "\$VERSION is empty."; exit 1; fi

# Directory this script is located in
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DBUILD="${DIR}/build/${PACKAGE}_${VERSION}"
DEPEND_I2B2="$(echo "${PACKAGE}" | awk -F '-' '{print $1"-"$2"-i2b2"}')"

# Cleanup
rm -rf "${DIR}/build"

# Load common linux files
. "$(dirname "${DIR}")/common/build.sh"
build_linux

mkdir -p "${DBUILD}/DEBIAN"
sedvars "${DIR}/control" "${DBUILD}/DEBIAN/control"
sedvars "${DIR}/postinst" "${DBUILD}/DEBIAN/postinst"
sedvars "${DIR}/prerm" "${DBUILD}/DEBIAN/prerm"
chmod +x "${DBUILD}/DEBIAN/postinst" "${DBUILD}/DEBIAN/prerm"

dpkg-deb --build "${DBUILD}"
rm -rf "${DBUILD}"

