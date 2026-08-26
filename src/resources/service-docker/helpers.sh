#!/bin/bash
#--------------------------------------
# Script Name:  helpers.sh
# Version:      1.0
# Authors:      whoy@ukaachen.de
# Date:         13 Aug 26
# Purpose:      Library for general helper functions 
#--------------------------------------


log() {
  local message="${1:-}"
  echo "[LOGGING] tenant=${dwh_prefix:-unknown} $message" >&2
  logger -t "__PACKAGE_NAME__" -p user.info -- "$message" 2>/dev/null || true
}

# Get version of last released data warehouse, from the AKTIN Github rspository
function get_latest_j2ee_release() {
  local latest=""
  latest=$(curl -s __DWH_GITHUB_TAGS_API__ \
    | grep -oP '"name":\s*"\K[^"]+' \
    | sort -V \
    | tail -1) || true
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
    log "Could not determine Docker Compose project for client IP: ${ip}" >&2
    exit 1
  fi

  echo "$dwh_prefix"
}

function docker_ensure_update_dir() {
  local dwh_prefix="$1"
  update_dir="__DOCKER_VOLUMES_DIR__${dwh_prefix}_aktin_data/_data/update"
  mkdir -p "$update_dir"
  echo "$update_dir"
}

# Find the compose.yml file location for a given container name.
function docker_get_compose_location_by_container() {
  local container_name="$1"
  compose_container="$container_name"
  compose_working_dir="$(docker inspect "$compose_container" --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  compose_config_files="$(docker inspect "$compose_container" --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}')"

  if [[ -n "$compose_working_dir" ]]; then
    compose_dir="$compose_working_dir"
  elif [[ -n "$compose_config_files" ]]; then
    compose_dir="$(dirname "${compose_config_files%%,*}")"
  else
    log "Could not determine Docker Compose directory for container: ${compose_container}"
    exit 1
  fi

  if [[ ! -d "$compose_dir" ]]; then
    log "Docker Compose directory does not exist: ${compose_dir}"
    exit 1
  fi
  echo "$compose_dir"
}

# This function finds the data warehouse version inside a given wildfly container. It uses the jboss CLI inside the container.
function docker_get_currently_deployed_version() {
  local container_name="$1"
  # "|| true" prevents a no-match grep (deployment not present/ready) from tripping "set -e" via
  # pipefail and aborting the whole script; an empty result is a valid, callers-handle-it outcome.
  installed=$(sudo docker exec "$container_name" __WILDFLY_CLI__ --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | awk '{print $1}' \
    | sed 's/dwh-j2ee-\(.*\)\.ear/\1/') || true
  echo "$installed"
}

# Wait until JBoss is reachable and finds a deployment. Does not check deployment status, only if the deployment exists.
# returns: 0 if deployment was found, non-zero if timeout was reached.
function docker_wait_for_deployment() {
  wildfly_container="$1"
  timeout_seconds="${2:-300}"
  check_interval_seconds="${3:-5}"
  deadline_ts=$((SECONDS + timeout_seconds))
  installed=""

  while (( SECONDS < deadline_ts )); do
    if deployment_info=$(sudo docker exec "$wildfly_container" __WILDFLY_CLI__ --connect --command="deployment-info" 2>/dev/null); then
      installed=$(
        awk '/dwh-j2ee-.*\.ear/ {
          name = $1
          sub(/^dwh-j2ee-/, "", name)
          sub(/\.ear$/, "", name)
          print name
          exit
        }' <<< "$deployment_info"
      )

      return 0
    fi

    log "WildFly deployment not ready yet, waiting ${check_interval_seconds}s"
    sleep "$check_interval_seconds"
  done

  log "WildFly deployment was not available after ${timeout_seconds}s"
  return 1
}

# Use JBoss CLI inside wildfly container to obtain data warehouse deployment status
function docker_get_deployment_status() {
  local container_name="$1"
  sudo docker exec "$container_name" __WILDFLY_CLI__ --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | awk '{print $NF}' || true
}


# Validate if data warehouse is deployed correctly and matches the deployed version against the latest candidate version.
# returns: true if matching, false if not
function docker_post_update_validation() {
  wildfly_container="$1"
  success="false"

  if docker_wait_for_deployment "$wildfly_container"; then
    installed="$(docker_get_currently_deployed_version $wildfly_container)"
    installed="v$installed" # because of git tagging rules adding v before version
    log "Got installed version $installed"

    status="$(docker_get_deployment_status $wildfly_container)"
    log "Got deployment status $status"

    candidate="$(get_latest_j2ee_release)"
    log "Got target candidate $candidate"

    if [[ "$installed" == "$candidate" && "$status" == "OK" ]]; then
      success="true"
    fi
    log "==> Update finished, installed: $installed (status: $status), candidate was $candidate. Update successful: $success"
  fi
  echo "$success"
}