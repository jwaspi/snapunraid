#!/bin/bash
# run.sh - convenience wrapper for the SnapUnraid test suite.
# Requires: bash, jq, awk, grep (all present on Unraid). No network needed.
set -e
exec bash "$(dirname "${BASH_SOURCE[0]}")/test.sh" "$@"
