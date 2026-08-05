#!/bin/bash
#--------------------------------------
# Script Name:  helpers.sh
# Version:      1.0
# Authors:      whoy@ukaachen.de
# Date:         25 Jun 26
# Purpose:      Service script to collect DWH package version information for docker DWHs
#--------------------------------------


function log() {
  local message="$1"
  echo "[LOGGING] tenant=${dwh_prefix:-unknown} $message" >&2
}

function docker_get_latest_release() {
  local latest=""
  latest=$(curl -s https://api.github.com/repos/aktin/dwh-j2ee/tags \
    | grep -oP '"name":\s*"\K[^"]+' \
    | sort -V \
    | tail -1)
  echo "$latest"
}

function get_compose_prefix_from_ip() {
  local ip="$1"
  dwh_prefix="$(
    docker ps -q | while read -r cid; do
      docker inspect \
      --format '{{.Id}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}} {{index .Config.Labels "com.docker.compose.project"}}' \
      "$cid"
    done | awk -v ip="$ip" '$0 ~ ip {print $NF; exit}'
  )"

  if [[ -z "$dwh_prefix" ]]; then
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

function docker_get_currently_deployed_version() {
  local container_name="$1"
  installed=$(sudo docker exec "$container_name" /opt/wildfly/bin/jboss-cli.sh --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | awk '{print $1}' \
    | sed 's/dwh-j2ee-\(.*\)\.ear/\1/')
  echo "$installed"
}

function docker_wait_for_deployment() {
  wildfly_container="$1"
  timeout_seconds="${2:-300}"
  check_interval_seconds="${3:-5}"
  deadline_ts=$((SECONDS + timeout_seconds))
  installed=""

  while (( SECONDS < deadline_ts )); do
    if deployment_info=$(sudo docker exec "$wildfly_container" /opt/wildfly/bin/jboss-cli.sh --connect --command="deployment-info" 2>/dev/null); then
      installed=$(
        awk '/dwh-j2ee-.*\.ear/ {
          name = $1
          sub(/^dwh-j2ee-/, "", name)
          sub(/\.ear$/, "", name)
          print name
          exit
        }' <<< "$deployment_info"
      )

      if [[ -n "$installed" ]]; then
        break
      fi
    fi

    log "WildFly deployment not ready yet, waiting ${check_interval_seconds}s"
    sleep "$check_interval_seconds"
  done

  if [[ -z "$installed" ]]; then
    log "WildFly deployment was not available after ${timeout_seconds}s"
  fi
}

function docker_get_deployment_status() {
  local container_name="$1"
  sudo docker exec "$container_name" /opt/wildfly/bin/jboss-cli.sh --connect --command="deployment-info" \
    | grep 'dwh-j2ee-.*\.ear' \
    | awk '{print $NF}'
}

function docker_post_update_validation() {
  wildfly_container="$1"

  installed="$(docker_get_currently_deployed_version $wildfly_container)"
  installed="v$installed" # because of git tagging rules adding v before version
  log "Got installed version $installed"

  status="$(docker_get_deployment_status $wildfly_container)"
  log "Got deployment status $status"

  candidate="$(docker_get_latest_release)"
  log "Got target candidate $candidate"

  if [[ "$installed" == "$candidate" && "$status" == "OK" ]]; then
    success="true"
  else
    success="false"
  fi
  log "==> Update finished, installed: $installed (status: $status), candidate was $candidate. Update successful: $success"

  echo "$success"
}