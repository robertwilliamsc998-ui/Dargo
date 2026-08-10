#!/usr/bin/env bash
set -euo pipefail
echo "Checking shell syntax..."
bash -n "$(dirname "$0")/../install.sh"
echo "OK"
