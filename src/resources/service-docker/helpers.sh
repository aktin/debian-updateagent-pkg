#!/bin/bash
#--------------------------------------
# Script Name:  helpers.sh
# Version:      1.0
# Authors:      whoy@ukaachen.de
# Date:         31 Aug 26
# Purpose:      Library for general helper functions 
#--------------------------------------


# Native loggers: for host-level executions (debian-native DWH updates, socket-setup) with no
# per-tenant context. Journal-only, no stdout/stderr echo - these scripts don't tee their output
# into a per-run log file, so an echo here would only duplicate what systemd already journals.
log_native_info() {
  logger -t "__PACKAGE_NAME__" -p user.info -- "${1:-}" 2>/dev/null || true
}

log_native_warn() {
  logger -t "__PACKAGE_NAME__" -p user.warning -- "${1:-}" 2>/dev/null || true
}

log_native_error() {
  logger -t "__PACKAGE_NAME__" -p user.err -- "${1:-}" 2>/dev/null || true
}

# Docker loggers: tag every line with the tenant (dwh_prefix) they concern and write it to stderr
# only. systemd captures the service's stderr into the journal, and the docker service scripts tee
# the same stream into a per-tenant log file - so a separate `logger` call would just double every
# line in the journal. All lines are journaled at the service's default priority.
log_docker_info() {
  local message="${1:-}"
  echo "[INFO] tenant=${dwh_prefix:-unknown} $message" >&2
}

log_docker_warn() {
  local message="${1:-}"
  echo "[WARN] tenant=${dwh_prefix:-unknown} $message" >&2
}

log_docker_error() {
  local message="${1:-}"
  echo "[ERROR] tenant=${dwh_prefix:-unknown} $message" >&2
}

# Write stdin to a file atomically: fill a temp file in the same directory, fix its
# permissions, then rename it over the target.
write_file_atomically() {
  local dest="$1"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  if cat >"$tmp" && chmod 0644 "$tmp"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Get version of last released data warehouse, from the AKTIN Github rspository.
# Per default it excludes rc/beta/alpha/pre/dev tags entirely. If this script is given "false", it includes them,
# but a full release still ranks above its own
function get_latest_j2ee_release() {
  local full_release_only="${1:-true}"
  local tags latest

  tags=$(curl -s __DWH_GITHUB_TAGS_API__ | grep -oP '"name":\s*"\K[^"]+') || true

  # filter only full releases if the tag is set to "true"
  if [[ "$full_release_only" == "true" ]]; then
    tags=$(printf '%s\n' "$tags" | grep -P '^v?[0-9]+(\.[0-9]+)*$') || true
  fi

  # sort tags accounting for full versions before their pre-release versions
  latest=$(
    paste \
      <(printf '%s\n' "$tags" | sed -E 's/[-.]?(rc|beta|alpha|pre|dev)([0-9]*)$/~\1\2/I') \
      <(printf '%s\n' "$tags") \
    | sort -t $'\t' -k1,1V \
    | tail -1 \
    | cut -f2
  )
  echo "$latest"
}

# Find a docker data warehouse identifier, by matching the requesting client's IP against existing
# docker container IPs
function get_compose_prefix_from_ip() {
  local ip="$1"

  # list all docker containers and their network interfaces and search for the target ip
  dwh_prefix="$(
    docker ps -q | while read -r cid; do
      docker inspect \
      --format '{{.Id}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}} {{index .Config.Labels "com.docker.compose.project"}}' \
      "$cid"
    done | awk -v ip="$ip" '{ for (i = 2; i < NF; i++) if ($i == ip) { print $NF; exit } }'
  )"

  if [[ -z "$ip" || -z "$dwh_prefix" ]]; then
    log_docker_warn "Could not determine Docker Compose project for client IP: ${ip}"
    return 1
  fi

  echo "$dwh_prefix"
}

function docker_ensure_update_dir() {
  local dwh_prefix="$1"
  local update_dir="__DOCKER_VOLUMES_DIR__${dwh_prefix}_aktin_data/_data/update"
  mkdir -p "$update_dir"
  echo "$update_dir"
}

# Find the compose.yml file location for a given container name.
function docker_get_compose_location_by_container() {
  local container_name="$1"
  local compose_container="$container_name"
  local compose_working_dir compose_config_files compose_dir
  compose_working_dir="$(docker inspect "$compose_container" --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  compose_config_files="$(docker inspect "$compose_container" --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}')"

  if [[ -n "$compose_working_dir" ]]; then
    compose_dir="$compose_working_dir"
  elif [[ -n "$compose_config_files" ]]; then
    compose_dir="$(dirname "${compose_config_files%%,*}")"
  else
    log_docker_warn "Could not determine Docker Compose directory for container: ${compose_container}"
    return 1
  fi

  if [[ ! -d "$compose_dir" ]]; then
    log_docker_warn "Docker Compose directory does not exist: ${compose_dir}"
    return 1
  fi
  echo "$compose_dir"
}

# This function finds the data warehouse version inside a given wildfly container. It uses the jboss CLI inside the container.
function docker_get_currently_deployed_version() {
  local container_name="$1"
  local installed
  # "|| true" prevents a no-match grep (deployment not present/ready) from tripping "set -e" via
  # pipefail and aborting the whole script; an empty result is a valid, callers-handle-it outcome.
  installed=$(docker exec "$container_name" __WILDFLY_CLI__ --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | awk '{print $1}' \
    | sed 's/dwh-j2ee-\(.*\)\.ear/\1/') || true
  echo "$installed"
}

function docker_is_wildfly_deployed() {
  local wildfly_container="$1"
  if docker exec "$wildfly_container" __WILDFLY_CLI__ --connect --command="deployment-info" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Wait until JBoss is reachable and finds a deployment. Does not check deployment status, only if the deployment exists.
# returns: 0 if deployment was found, non-zero if timeout was reached.
function docker_wait_for_deployment() {
  local wildfly_container="$1"
  local timeout_seconds="${2:-300}"
  local check_interval_seconds="${3:-5}"
  local deadline_ts=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline_ts )); do
    if docker_is_wildfly_deployed "$wildfly_container"; then
      return 0
    fi
    log_docker_info "WildFly deployment not ready yet, waiting ${check_interval_seconds}s"
    sleep "$check_interval_seconds"
  done

  log_docker_warn "WildFly deployment was not available after ${timeout_seconds}s"
  return 1
}

# Use JBoss CLI inside wildfly container to obtain data warehouse deployment status
function docker_get_deployment_status() {
  local container_name="$1"
  docker exec "$container_name" __WILDFLY_CLI__ --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | awk '{print $NF}' || true
}


# Validate if data warehouse is deployed correctly and matches the deployed version against the latest candidate version.
# returns: true if matching, false if not
function docker_post_update_validation() {
  local wildfly_container="$1"
  local success="false"
  local installed status candidate

  if docker_wait_for_deployment "$wildfly_container"; then
    installed="$(docker_get_currently_deployed_version $wildfly_container)"
    installed="v$installed" # because of git tagging rules adding v before version
    log_docker_info "Got installed version $installed"

    status="$(docker_get_deployment_status $wildfly_container)"
    log_docker_info "Got deployment status $status"

    candidate="$(get_latest_j2ee_release)"
    log_docker_info "Got target candidate $candidate"

    if [[ "$installed" == "$candidate" && "$status" == "OK" ]]; then
      success="true"
    fi
    log_docker_info "==> Update finished, installed: $installed (status: $status), candidate was $candidate. Update successful: $success"
  fi
  echo "$success"
}

# Roll a data warehouse back to its backed-up compose config and bring it up again.
# Best effort: every step logs on failure instead of aborting, because this runs on
# an already-failing update path where the priority is getting the old stack running.
function docker_restore_compose_backup() {
  local compose_dir="$1"
  local wildfly_container="$2"
  local restored

  log_docker_warn "restoring previous compose configuration"

  if ! cd "$compose_dir"; then
    log_docker_error "could not enter compose directory '$compose_dir' to restore backup"
    return 1
  fi
  if [[ ! -f backup-compose.yml ]]; then
    log_docker_error "no compose backup found at '$compose_dir/backup-compose.yml'"
    return 1
  fi

  cp backup-compose.yml compose.yml || log_docker_error "could not restore compose.yml from backup"
  docker compose up -d || log_docker_error "failed to restart previous docker compose configuration"

  restored="$(docker_post_update_validation "$wildfly_container")"
  log_docker_info "status of data warehouse after restore: $restored"
}

# remove old version info file if exists. log errors during removing. Checks if the file was truly removed and logs if still exists. For native/debian cliants only.
rm_info_native() {
  local info_path="__AKTIN_UPDATE_DIR__/info"

  # remove file and log error if one occured
  if [[ -f "$info_path" ]]; then
    log_native_info "Found old version info file. Attempting to remove..."
    error_msg="$(rm "$info_path" 2>&1 >/dev/null)" || true
    [[ -n "$error_msg" ]] && log_native_error "$error_msg"  # log rm error message if not empty
  fi

  # sanity check
  if [[ -f "$info_path" ]]; then
    log_native_error "Version info file could not be removed."
  else
    log_native_info "Ensured version info file has been removed."
  fi
}

# remove old version info file for given update directory. For docker clients only.
rm_info_docker() {
  local info_path="$1"

  # remove file and log error if one occured
  if [[ -f "$info_path" ]]; then
    log_docker_info "Found old version info file. Attempting to remove..."
    error_msg="$(rm "$info_path" 2>&1 >/dev/null)" || true
    [[ -n "$error_msg" ]] && log_docker_error "$error_msg"  # log rm error message if not empty
  fi

  # sanity check
  if [[ -f "$info_path" ]]; then
    log_docker_error "Version info file could not be removed."
  else
    log_docker_info "Ensured version info file has been removed."
  fi
}

rm_file_docker() {
  local target="$1"

  # remove file and log error if one occured
  if [[ -f "$target" ]]; then
    log_docker_info "Found removal target $target"
    error_msg="$(rm "$target" 2>&1 >/dev/null)" || true
    [[ -n "$error_msg" ]] && log_docker_error "$error_msg"  # log rm error message if not empty
  fi

  # sanity check
  if [[ -f "$target" ]]; then
    log_docker_error "File could not be removed."
  else
    log_docker_info "File has been removed."
  fi
}
