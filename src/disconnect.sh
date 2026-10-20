#!/usr/bin/env bash
#
# disconnect.sh - Tear down the OpenConnect VPN connection started by
# src/main.sh. Prefers the recorded PID file so that unrelated openconnect
# processes on a shared runner are never touched; only falls back to a
# process-name match when no PID file is available.
#
# Author: Persi.Liao <xiangchu.liao@gmail.com>
#
set -euo pipefail

# Load shared helpers by resolving the directory this script lives in.
ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${ACTION_DIR}/common.sh"

echo "::group::Disconnecting VPN"

# Stop one PID: SIGINT, wait, then SIGKILL. Returns 0 once it is gone.
stop_pid() {
  local pid="$1" waited=0
  run_root kill -INT "$pid" 2>/dev/null || true
  while pid_alive "$pid" && [ "$waited" -lt "$VPN_STOP_TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if pid_alive "$pid"; then
    log "Process ${pid} ignored SIGINT - sending SIGKILL..."
    run_root kill -KILL "$pid" 2>/dev/null || true
    sleep 2
  fi
  ! pid_alive "$pid"
}

# Remove material the connect step left behind (the log is kept for debugging).
cleanup_state() {
  rm -f "$OPENCONNECT_PID_FILE" "$OPENCONNECT_CERT_FILE" "$OPENCONNECT_KEY_FILE"
}

if vpn_pid_now="$(vpn_pid)"; then
  if ! pid_alive "$vpn_pid_now"; then
    log "Recorded openconnect process ${vpn_pid_now} is already gone - cleaning up."
    cleanup_state
    echo "::endgroup::"
    exit 0
  fi

  log "Stopping openconnect (pid ${vpn_pid_now})..."
  if ! stop_pid "$vpn_pid_now"; then
    fail "Failed to terminate the openconnect process ${vpn_pid_now}."
  fi
elif vpn_is_running; then
  # No PID file available: fall back to a name match. `-x` keeps the match on
  # the exact process name instead of an arbitrary command line.
  log "No PID file found - falling back to stopping openconnect processes by name."
  run_root pkill -x -INT openconnect || true
  waited=0
  while vpn_is_running && [ "$waited" -lt "$VPN_STOP_TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if vpn_is_running; then
    log "Processes still alive - sending SIGKILL..."
    run_root pkill -x -KILL openconnect || true
    sleep 2
  fi
  if vpn_is_running; then
    fail "Failed to terminate the openconnect process."
  fi
else
  log "No active openconnect process found - nothing to do."
  echo "::endgroup::"
  exit 0
fi

cleanup_state
echo "::endgroup::"
notice "VPN disconnected successfully."
