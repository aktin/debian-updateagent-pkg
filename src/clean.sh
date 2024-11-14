#!/bin/bash
#--------------------------------------
# Script Name:  clean.sh
# Version:      1.0
# Authors:      skurka@ukaachen.de, akombeiz@ukaachen.de
# Date:         14 Nov 24
# Purpose:      Cleans up update agent Debian package build directories.
#--------------------------------------

set -euo pipefail

dir_current="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -rf "${dir_current}/build"
