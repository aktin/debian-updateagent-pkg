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

# Lock files created by this run, cleaned up on exit so a mid-run abort (set -e,
# docker hang, systemd SIGTERM) never strands an info.lock. SIGKILL and power loss
# still can't be caught - consumers must also treat a stale lock as expired.
_OWN_LOCKS=()
_LOCK_TOKEN="$$-${RANDOM}-$(date +%s)"

# Remove PATH if it exists and hasn't been touched for MAX_AGE seconds (default 60).
# Breaks a plain marker lock (e.g. info.lock) stranded by a SIGKILLed predecessor;
# flock-based locks don't need this, the kernel frees them on process death.
function clear_stale_lock() {
  local path="$1" max_age="${2:-60}" mtime now
  [[ -e "$path" ]] || return 0
  mtime="$(stat -c %Y "$path" 2>/dev/null)" || return 0
  now="$(date +%s)"
  if (( now - mtime > max_age )); then
    log_docker warn "removing stale lock $path ($(( now - mtime ))s old)"
    rm -f "$path"
  fi
}

# Create a lock file tagged with this run's token and remember it for cleanup.
function create_own_lock() {
  local path="$1"
  printf '%s\n' "$_LOCK_TOKEN" > "$path" || return 1
  _OWN_LOCKS+=("$path")
}

# Remove only the locks this run still owns (token unchanged). Safe to call
# repeatedly and when the lock was already removed on the happy path.
function cleanup_own_locks() {
  local path
  for path in "${_OWN_LOCKS[@]:-}"; do
    [[ "$(cat "$path" 2>/dev/null)" == "$_LOCK_TOKEN" ]] && rm -f "$path"
  done
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
  if docker exec "$wildfly_container" __WILDFLY_CLI__ --connect --command="deployment-info" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Wait until a deployment exists (not its status). Returns non-zero on timeout.
function docker_wait_for_deployment() {
  local wildfly_container="$1"
  local timeout_seconds="${2:-300}"
  local check_interval_seconds="${3:-5}"
  local deadline_ts=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline_ts )); do
    if docker_is_wildfly_deployed "$wildfly_container"; then
      return 0
    fi
    log_docker info "WildFly deployment not ready yet, waiting ${check_interval_seconds}s"
    sleep "$check_interval_seconds"
  done

  log_docker warn "WildFly deployment was not available after ${timeout_seconds}s"
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
    installed="$(normalize_version "$(docker_get_currently_deployed_version $wildfly_container)")"
    log_docker info "Got installed version $installed"

    status="$(docker_get_deployment_status $wildfly_container)"
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

# Remove the native version info file, logging any rm error and verifying it's gone.
rm_info_native() {
  local info_path="__AKTIN_UPDATE_DIR__/info"

  if [[ -f "$info_path" ]]; then
    log_native info "Found old version info file. Attempting to remove..."
    error_msg="$(rm "$info_path" 2>&1 >/dev/null)" || true
    [[ -n "$error_msg" ]] && log_native error "$error_msg"
  fi

  if [[ -f "$info_path" ]]; then
    log_native error "Version info file could not be removed."
  else
    log_native info "Ensured version info file has been removed."
  fi
}

# Remove the docker version info file at the given path, logging and verifying as above.
rm_info_docker() {
  local info_path="$1"

  if [[ -f "$info_path" ]]; then
    log_docker info "Found old version info file. Attempting to remove..."
    error_msg="$(rm "$info_path" 2>&1 >/dev/null)" || true
    [[ -n "$error_msg" ]] && log_docker error "$error_msg"
  fi

  if [[ -f "$info_path" ]]; then
    log_docker error "Version info file could not be removed."
  else
    log_docker info "Ensured version info file has been removed."
  fi
}

# Remove an arbitrary file (docker context), logging and verifying as above.
rm_file_docker() {
  local target="$1"

  if [[ -f "$target" ]]; then
    log_docker info "Found removal target $target"
    error_msg="$(rm "$target" 2>&1 >/dev/null)" || true
    [[ -n "$error_msg" ]] && log_docker error "$error_msg"
  fi

  if [[ -f "$target" ]]; then
    log_docker error "File could not be removed."
  else
    log_docker info "File has been removed."
  fi
}
