#!/bin/bash
#--------------------------------------
# Script Name:  build.sh
# Version:      1.1
# Authors:      skurka@ukaachen.de, akombeiz@ukaachen.de
# Date:         06 Dec 24
# Purpose:      Builds the AKTIN update agent Debian package. Creates service files, management scripts, and builds the final package with proper
#               versioning and dependencies.
#--------------------------------------

set -euo pipefail

readonly PACKAGE_NAME="aktin-notaufnahme-updateagent"

CLEANUP=false
SKIP_BUILD=false
FULL_CLEAN=false

usage() {
  echo "Usage: $0 [--cleanup] [--skip-deb-build] [--full-clean]" >&2
  echo "  --cleanup          Optional: Remove build directory after package creation" >&2
  echo "  --skip-deb-build   Optional: Skip the debian package build step" >&2
  echo "  --full-clean       Optional: Remove build and downloads directories before starting" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --cleanup)
      CLEANUP=true
      shift
      ;;
    --skip-deb-build)
      SKIP_BUILD=true
      shift
      ;;
    --full-clean)
      FULL_CLEAN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: Unexpected argument '$1'" >&2
      usage
      ;;
  esac
done

# Define relevant directories as absolute paths
readonly DIR_DEBIAN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR_SRC="$(dirname "${DIR_DEBIAN}")"
readonly DIR_RESOURCES="${DIR_SRC}/resources"
readonly DIR_DOWNLOADS="${DIR_SRC}/downloads"

# Load version-specific variables from file
set -a
. "${DIR_RESOURCES}/versions"
set +a
readonly DIR_BUILD="${DIR_SRC}/build/${PACKAGE_NAME}_${PACKAGE_VERSION}"

clean_up_build_environment() {
  echo "Cleaning up previous build environment..."
  rm -rf "${DIR_BUILD}"
  if [[ "${FULL_CLEAN}" == true ]]; then
    echo "Performing full clean..."
    rm -rf "${DIR_SRC}/build"
    rm -rf "${DIR_DOWNLOADS}"
  fi
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
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" -e "s|__PACKAGE_VERSION__|${PACKAGE_VERSION}|g" -e "s|__DWH_PACKAGE_NAME__|${dwh_package_name}|g" "${DIR_DEBIAN}/control" > "${DIR_BUILD}/DEBIAN/control"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_DEBIAN}/prerm" > "${DIR_BUILD}/DEBIAN/prerm"
  sed -e "s|__PACKAGE_NAME__|${PACKAGE_NAME}|g" "${DIR_DEBIAN}/postinst" > "${DIR_BUILD}/DEBIAN/postinst"

  # Set proper executable permissions
  chmod 0755 "${DIR_BUILD}/DEBIAN/"*
}

build_package() {
  if [[ "${SKIP_BUILD}" == false ]]; then
    echo "Building Debian package..."
    dpkg-deb --build "${DIR_BUILD}"
    if [[ "${CLEANUP}" == true ]]; then
      echo "Cleaning up build directory..."
      rm -rf "${DIR_BUILD}"
    fi
  else
    echo "Debian build skipped"
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
