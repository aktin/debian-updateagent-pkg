#!/bin/bash
#--------------------------------------
# Script Name:  build.sh
# Version:      2.0
# Authors:      skurka@ukaachen.de, akombeiz@ukaachen.de, whoy@ukaachen.de
# Date:         11 Aug 26
# Purpose:      Builds the AKTIN update agent Debian package. Injects variables into maintainer scripts.
#               Creates service files, management scripts, and builds the final package with proper
#               versioning and dependencies.
#--------------------------------------

set -euo pipefail

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

# Load package configuration and version-specific variables from file
set -a
. "${DIR_RESOURCES}/config"
. "${DIR_RESOURCES}/versions"
set +a
readonly PACKAGE_LIB_DIR="/usr/lib/${PACKAGE_NAME}"
dwh_package_name="$(echo "${PACKAGE_NAME}" | awk -F '-' '{print $1"-"$2"-dwh"}')"
readonly DIR_BUILD="${DIR_SRC}/build/${PACKAGE_NAME}_${PACKAGE_VERSION}"

# Declare list containing environment variables and insert variables, that
# cannot be loaded automatically from configuration files
SED_ARGS=(
-e "s|__PACKAGE_LIB_DIR__|${PACKAGE_LIB_DIR}|g"
-e "s|__DWH_PACKAGE_NAME__|${dwh_package_name}|g"
)

# Automatically load all variables inside the config files and store them inside the list of environment variables.
while read -r key; do
  SED_ARGS+=(-e "s|__${key}__|${!key}|g")
done < <(grep -ohP '^[A-Za-z_][A-Za-z0-9_]*(?==)' "${DIR_RESOURCES}/config" "${DIR_RESOURCES}/versions")
readonly SED_ARGS


clean_up_build_environment() {
  echo "Cleaning up previous build environment..."
  rm -rf "${DIR_BUILD}"
  if [[ "${FULL_CLEAN}" == true ]]; then
    echo "Performing full clean..."
    rm -rf "${DIR_SRC}/build" || true
  fi
}

init_build_environment() {
  echo "Initializing build environment..."
  if [[ ! -d "${DIR_BUILD}" ]]; then
    mkdir -p "${DIR_BUILD}"
  fi
}

prepare_service_files() {
  echo "Preparing update agent service files..."

  # Replace placeholders
  mkdir -p "${DIR_BUILD}/usr/bin"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-debian/service" > "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-debian/service-info" > "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-info"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/service-docker" > "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-docker"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/service-docker-info" > "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-docker-info"

  mkdir -p "${DIR_BUILD}/lib/systemd/system"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-debian/service.socket" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}.socket"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-debian/service@.service" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}@.service"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-debian/service-info.socket" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-info.socket"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-debian/service-info@.service" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-info@.service"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/service-docker.socket" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-docker.socket"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/service-docker@.service" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-docker@.service"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/service-docker-info.socket" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-docker-info.socket"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/service-docker-info@.service" > "${DIR_BUILD}/lib/systemd/system/${PACKAGE_NAME}-docker-info@.service"

  mkdir -p "${DIR_BUILD}/etc/apt/apt.conf.d"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-debian/apt.update.post-invoke" > "${DIR_BUILD}/etc/apt/apt.conf.d/99${PACKAGE_NAME}-info"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/apt.update.post-invoke" > "${DIR_BUILD}/etc/apt/apt.conf.d/99${PACKAGE_NAME}-docker-info"

  mkdir -p "${DIR_BUILD}${PACKAGE_LIB_DIR}"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/socket-setup" > "${DIR_BUILD}${PACKAGE_LIB_DIR}/socket-setup"
  sed "${SED_ARGS[@]}" "${DIR_RESOURCES}/service-docker/helpers.sh" > "${DIR_BUILD}${PACKAGE_LIB_DIR}/helpers.sh"

  # Set proper executable permissions
  chmod +x "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}" "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-info" "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-docker" "${DIR_BUILD}/usr/bin/${PACKAGE_NAME}-docker-info" "${DIR_BUILD}${PACKAGE_LIB_DIR}/socket-setup"
}

prepare_management_scripts_and_files() {
  echo "Preparing Debian package management files..."
  mkdir -p "${DIR_BUILD}/DEBIAN"

  # Replace placeholders
  sed "${SED_ARGS[@]}" "${DIR_DEBIAN}/control" > "${DIR_BUILD}/DEBIAN/control"
  sed "${SED_ARGS[@]}" "${DIR_DEBIAN}/preinst" > "${DIR_BUILD}/DEBIAN/preinst"
  sed "${SED_ARGS[@]}" "${DIR_DEBIAN}/prerm" > "${DIR_BUILD}/DEBIAN/prerm"
  sed "${SED_ARGS[@]}" "${DIR_DEBIAN}/postinst" > "${DIR_BUILD}/DEBIAN/postinst"
  sed "${SED_ARGS[@]}" "${DIR_DEBIAN}/postrm" > "${DIR_BUILD}/DEBIAN/postrm"

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
