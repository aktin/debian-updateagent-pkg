#!/bin/bash
#--------------------------------------
# Script Name:  build.sh
# Version:      1.0
# Authors:      skurka@ukaachen.de, akombeiz@ukaachen.de
# Date:         14 Nov 24
# Purpose:      Creates update agent Debian package components for the specified version.
#--------------------------------------

set -euo pipefail

readonly VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
  echo "Error: VERSION is not specified." >&2
  echo "Usage: $0 <version>"
  exit 1
fi

dir_current="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${dir_current}/debian/build.sh" "${VERSION}"
