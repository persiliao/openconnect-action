#!/usr/bin/env bash
#
# disconnect.sh - Tear down an OpenConnect VPN connection.
#
set -euo pipefail

# Load shared helpers by resolving the directory this script lives in.
ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${ACTION_DIR}/common.sh"

echo "::group::Disconnecting VPN"

if ! vpn_is_running; then
  log "No active openconnect process found - nothing to do."
  echo "::endgroup::"
  exit 0
fi

log "Sending SIGINT to openconnect..."
run_root pkill -INT openconnect || true
sleep 5

if vpn_is_running; then
  log "Process still alive - sending SIGKILL..."
  run_root pkill -9 openconnect || true
  sleep 2
fi

if vpn_is_running; then
  fail "Failed to terminate the openconnect process."
fi

echo "::endgroup::"
notice "VPN disconnected successfully."
