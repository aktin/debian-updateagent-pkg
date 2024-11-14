#!/bin/bash
#--------------------------------------
# Script Name:  build.sh
# Version:      1.0
# Authors:      skurka@ukaachen.de, akombeiz@ukaachen.de
# Date:         14 Nov 24
# Purpose:      Builds the AKTIN update agent Debian package. Creates service files, management scripts, and builds the final package with proper
#               versioning and dependencies.
#--------------------------------------

set -euo pipefail

readonly PACKAGE_NAME="aktin-notaufnahme-updateagent"

CLEANUP=false
PACKAGE_VERSION=""

usage() {
  echo "Usage: $0 <PACKAGE_VERSION> [--cleanup]" >&2
  echo "  PACKAGE_VERSION    Version number for the package (must start with a number)" >&2
  echo "  --cleanup          Optional: Remove build directory after package creation" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --cleanup)
      CLEANUP=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -z "${PACKAGE_VERSION}" ]]; then
        PACKAGE_VERSION="$1"
      else
        echo "Error: Unexpected argument '$1'" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [[ -z "${PACKAGE_VERSION}" ]]; then
  PACKAGE_VERSION="${PACKAGE_VERSION:-${1:-}}"
fi
readonly PACKAGE_VERSION="${PACKAGE_VERSION:-${1:-}}"
if [[ -z "${PACKAGE_VERSION}" ]]; then
  echo "Error: PACKAGE_VERSION is not specified." >&2
  echo "Usage: $0 <PACKAGE_VERSION>" >&2
  exit 1
elif ! [[ "${PACKAGE_VERSION}" =~ ^[0-9] ]]; then
  echo "Error: PACKAGE_VERSION must start with a number." >&2
  echo "Example: 1.0.0, 2.1.0-rc1" >&2
  exit 1
fi

# Define relevant directories as absolute paths
readonly DIR_CURRENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR_SRC="$(dirname "${DIR_CURRENT}")"
readonly DIR_BUILD="${DIR_SRC}/build/${PACKAGE_NAME}_${PACKAGE_VERSION}"
readonly DIR_RESOURCES="${DIR_SRC}/resources"

clean_up_build_environment() {
  echo "Cleaning up previous build environment..."
  rm -rf "${DIR_BUILD}"
}

init_build_environment() {
  echo "Initializing build environment..."
  if [[ ! -d "${DIR_BUILD}" ]]; then
    mkdir -p "${DIR_BUILD}"
  fi
}

prepare_service_files() {
  local dwh_package_name="$(echo "${PACKAGE_NAME}" | awk -F '-' '{print $1"-"$2"-dwh"}')"
  local update_dir="/var/lib/aktin/update"
  echo "Preparing update agent service files..."

  # Replace placeholders
  mkdir -p "${DIR_BUILD}/usr/bin"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" -e "s|__DWH_PACKAGE_NAME__|${dwh_package_name}|g" -e "s|__AKTIN_UPDATE_DIR__|${update_dir}|g" "${DIR_RESOURCES}/service" > "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" -e "s|__DWH_PACKAGE_NAME__|${dwh_package_name}|g" -e "s|__AKTIN_UPDATE_DIR__|${update_dir}|g" "${DIR_RESOURCES}/service-info" > "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-info"

  mkdir -p "${DIR_BUILD}/lib/systemd/system"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_RESOURCES}/service.socket" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}.socket"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_RESOURCES}/service@.service" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}@.service"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_RESOURCES}/service-info.socket" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-info.socket"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_RESOURCES}/service-info@.service" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-info@.service"

  mkdir -p "${DIR_BUILD}/etc/apt/apt.conf.d"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_RESOURCES}/apt.update.post-invoke" > "${DIR_BUILD}/etc/apt/apt.conf.d/99${PACKAGE_NAME}-info"

  # Set proper executable permissions
  chmod +x "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}" "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-info"
}

prepare_management_scripts_and_files() {
  local dwh_package_name="$(echo "${PACKAGE_NAME}" | awk -F '-' '{print $1"-"$2"-dwh"}')"
  echo "Preparing Debian package management files..."
  mkdir -p "${DIR_BUILD}/DEBIAN"

  # Replace placeholders
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" -e "s|__PACKAGE_VERSION__|${PACKAGE_VERSION}|g" -e "s|__DWH_PACKAGE_NAME__|${dwh_package_name}|g" "${DIR_CURRENT}/control" > "${DIR_BUILD}/DEBIAN/control"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_CURRENT}/prerm" > "${DIR_BUILD}/DEBIAN/prerm"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_CURRENT}/postinst" > "${DIR_BUILD}/DEBIAN/postinst"

  # Set proper executable permissions
  chmod 0755 "${DIR_BUILD}/DEBIAN/"*
}

build_package() {
  echo "Building Debian package..."
  dpkg-deb --build "${DIR_BUILD}"
  if [[ "${CLEANUP}" == true ]]; then
    echo "Cleaning up build directory..."
    rm -rf "${DIR_BUILD}"
  fi
}

main() {
  set -euo pipefail
  clean_up_build_environment
  init_build_environment
  prepare_service_files
  prepare_management_scripts_and_files
  build_package
}

main
