#!/bin/bash
#--------------------------------------
# Script Name:  helpers.sh
# Version:      1.0
# Authors:      whoy@ukaachen.de
# Date:         31 Aug 26
# Purpose:      Library for general helper functions 
#--------------------------------------


# Native logger: logs into system journal
log_native() {
  local level="$1" message="${2:-}"
  local priority
  case "$level" in
    info)  priority="user.info" ;;
    warn)  priority="user.warning" ;;
    error) priority="user.err" ;;
  esac
  logger -t "__PACKAGE_NAME__" -p "$priority" -- "$message" 2>/dev/null || true
}

# Docker loggers: tag each line with the tenant and write to stderr only. systemd journals it and
# the service scripts tee the same stream to a per-tenant log file.
log_docker() {
  local level="$1" message="${2:-}"
  local tag
  case "$level" in
    info)  tag="INFO" ;;
    warn)  tag="WARNING" ;;
    error) tag="ERR" ;;
  esac
  echo "[$tag] tenant=${dwh_prefix:-unknown} $message" >&2
}

# Write stdin to a file atomically: fill a temp file in the same directory, fix its
# permissions, then rename it over the target.
write_file_atomically() {
  local dest="$1"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  if cat >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$dest"; then
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

# Remove a single leading v from version string
function normalize_version() {
  local version="${1:-}"
  echo "${version#[vV]}"
}

# Serialize runs sharing KEY: non-blocking flock on fd 9 (held until exit). On contention,
# log and exit 0 - the already-running instance finishes the work.
function acquire_singleton_lock() {
  local key="$1"
  exec 9>"/tmp/${key}.lock"
  if ! flock -n 9; then
    log_docker warn "another '${key}' run is in progress; skipping duplicate request"
    exit 0
  fi
}

# Latest DWH release tag from the AKTIN GitHub repo. Excludes pre-release tags.
function get_latest_j2ee_release() {
  local tags latest

  tags=$(curl -s __DWH_GITHUB_TAGS_API__ | grep -oP '"name":\s*"\K[^"]+' | grep -P '^v?[0-9]+(\.[0-9]+)*$') || true
  latest=$(printf '%s\n' "$tags" | sort -V | tail -1)
  echo "$latest"
}

# Find a docker data warehouse identifier, by matching the requesting client's IP against existing
# docker container IPs
function get_compose_prefix_from_ip() {
  local ip="$1"

  # list all docker containers and their network interfaces and search for the target ip
  dwh_prefix="$(
    docker inspect \
      --format '{{.Id}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}} {{index .Config.Labels "com.docker.compose.project"}}' \
      $(docker ps -q) 2>/dev/null \
    | awk -v ip="$ip" '{ for (i = 2; i < NF; i++) if ($i == ip) { print $NF; exit } }'
  )"

  if [[ -z "$ip" || -z "$dwh_prefix" ]]; then
    log_docker warn "Could not determine Docker Compose project for client IP: ${ip}"
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
  local compose_dir
  compose_dir="$(docker inspect "$container_name" --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"

  if [[ ! -d "$compose_dir" ]]; then
    log_docker warn "Docker Compose directory does not exist: ${compose_dir}"
    return 1
  fi
  echo "$compose_dir"
}

# DWH version deployed in the wildfly container, via jboss CLI.
function docker_get_currently_deployed_version() {
  local container_name="$1"
  local installed
  # "|| true": a no-match grep is a valid empty result, not a pipefail abort.
  installed=$(docker exec "$container_name" __WILDFLY_CLI__ --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | awk '{print $1}' \
    | sed 's/dwh-j2ee-\(.*\)\.ear/\1/') || true
  echo "$installed"
}

function docker_is_wildfly_deployed() {
  local wildfly_container="$1"
  docker exec "$wildfly_container" __WILDFLY_CLI__ --connect --command="deployment-info" >/dev/null 2>&1
}

# Wait until a deployment exists (not its status). Returns non-zero on timeout.
function docker_wait_for_deployment() {
  local wildfly_container="$1"
  local timeout_seconds="${2:-300}"
  local check_interval_seconds="${3:-5}"
  local deadline_ts=$((SECONDS + timeout_seconds))

  log_docker info "Waiting up to ${timeout_seconds}s for WildFly deployment"
  while (( SECONDS < deadline_ts )); do
    if docker_is_wildfly_deployed "$wildfly_container"; then
      return 0
    fi
    sleep "$check_interval_seconds"
  done

  log_docker warn "WildFly deployment was not available after ${timeout_seconds}s"
  return 1
}

# Installed DWH version and deployment status from the same jboss-cli deployment-info
# row: prints "<version> <status>" so a caller needing both reads them from one exec.
function docker_get_deployment_info() {
  local container_name="$1"
  # "|| true": a no-match grep is a valid empty result, not a pipefail abort.
  docker exec "$container_name" __WILDFLY_CLI__ --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | sed 's/dwh-j2ee-\([^[:space:]]*\)\.ear/\1/' \
    | awk '{print $1, $NF}' || true
}


# Validate if data warehouse is deployed correctly and matches the deployed version against the latest candidate version.
# returns: true if matching, false if not
function docker_post_update_validation() {
  local wildfly_container="$1"
  local success="false"
  local installed status candidate

  if docker_wait_for_deployment "$wildfly_container"; then
    read -r installed status < <(docker_get_deployment_info "$wildfly_container")
    installed="$(normalize_version "$installed")"
    log_docker info "Got installed version $installed"
    log_docker info "Got deployment status $status"

    candidate="$(normalize_version "$(get_latest_j2ee_release)")"
    log_docker info "Got target candidate $candidate"

    if [[ "$installed" == "$candidate" && "$status" == "OK" ]]; then
      success="true"
    fi
    log_docker info "==> Update finished, installed: $installed (status: $status), candidate was $candidate. Update successful: $success"
  fi
  echo "$success"
}

# Restore the backed-up compose config and bring the stack up. Best effort: each step
# logs on failure rather than aborting - this runs on an already-failing update path.
function docker_restore_compose_backup() {
  local compose_dir="$1"
  local wildfly_container="$2"
  local restored

  log_docker warn "restoring previous compose configuration"

  if ! cd "$compose_dir"; then
    log_docker error "could not enter compose directory '$compose_dir' to restore backup"
    return 1
  fi
  if [[ ! -f backup-compose.yml ]]; then
    log_docker error "no compose backup found at '$compose_dir/backup-compose.yml'"
    return 1
  fi

  cp backup-compose.yml compose.yml || log_docker error "could not restore compose.yml from backup"
  docker compose up -d || log_docker error "failed to restart previous docker compose configuration"

  restored="$(docker_post_update_validation "$wildfly_container")"
  log_docker info "status of data warehouse after restore: $restored"
}
