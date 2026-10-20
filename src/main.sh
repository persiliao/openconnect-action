#!/usr/bin/env bash
#
# main.sh - Establish an OpenConnect VPN connection in the background.
#
# Inputs are supplied via environment variables (see action.yml):
#   VPN_SERVER, VPN_PROTOCOL, VPN_USER, VPN_PASSWORD, VPN_GROUP,
#   VPN_CERT, VPN_CERT_KEY
#
# The tunnel is always detached: a composite action step that kept the
# connection in the foreground would block the workflow forever. The PID is
# recorded so that disconnect/action.yml can tear exactly this tunnel down.
#
# Author: Persi.Liao <xiangchu.liao@gmail.com>
#
set -euo pipefail

# Load shared helpers by resolving the directory this script lives in.
ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${ACTION_DIR}/common.sh"

# Private key material is written below: never let it inherit loose defaults.
umask 077

echo "::group::Setting up OpenConnect VPN connection"

# ---------------------------------------------------------------------------
# Normalise inputs (safe under `set -u`)
# ---------------------------------------------------------------------------
VPN_SERVER="${VPN_SERVER:-}"
VPN_PROTOCOL="${VPN_PROTOCOL:-anyconnect}"
VPN_USER="${VPN_USER:-}"
VPN_PASSWORD="${VPN_PASSWORD:-}"
VPN_GROUP="${VPN_GROUP:-}"
VPN_CERT="${VPN_CERT:-}"
VPN_CERT_KEY="${VPN_CERT_KEY:-}"

# ---------------------------------------------------------------------------
# Validate required inputs
# ---------------------------------------------------------------------------
if [ -z "$VPN_SERVER" ];   then fail "Missing required input: 'server'"; fi
if [ -z "$VPN_USER" ];     then fail "Missing required input: 'username'"; fi
if [ -z "$VPN_PASSWORD" ]; then fail "Missing required input: 'password'"; fi

# ---------------------------------------------------------------------------
# Validate protocol (exact match, no globbing on user input)
# ---------------------------------------------------------------------------
VALID_PROTOCOLS=("anyconnect" "nc" "jnpr" "pulse" "gp" "f5" "fortinet" "array")
protocol_is_valid=0
for candidate in "${VALID_PROTOCOLS[@]}"; do
  if [ "$candidate" = "$VPN_PROTOCOL" ]; then
    protocol_is_valid=1
    break
  fi
done
if [ "$protocol_is_valid" -eq 0 ]; then
  fail "Invalid protocol '${VPN_PROTOCOL}'. Valid options: ${VALID_PROTOCOLS[*]}"
fi

# ---------------------------------------------------------------------------
# Make sure the CLI and its routing script are present
# ---------------------------------------------------------------------------
ensure_openconnect
VPN_SCRIPT="$(ensure_vpnc_script)"
check_protocol_support "$VPN_PROTOCOL"
log "Routing script: ${VPN_SCRIPT}"

# ---------------------------------------------------------------------------
# Build command arguments (array avoids unsafe word-splitting)
# ---------------------------------------------------------------------------
ARGS=(
  --background
  --pid-file="$OPENCONNECT_PID_FILE"
  --script="$VPN_SCRIPT"
  --user="$VPN_USER"
  --protocol="$VPN_PROTOCOL"
  --passwd-on-stdin
  # Keep a dropped tunnel recoverable instead of silently losing the route.
  --reconnect-timeout=60
)

if [ -n "$VPN_GROUP" ]; then
  ARGS+=(--authgroup="$VPN_GROUP")
fi

if [ -n "$VPN_CERT" ]; then
  # PEM material goes through --ssl-cert on every openconnect release that
  # offers it; older builds only understand the legacy --certificate flag.
  if openconnect --help 2>&1 | grep -q -- '--ssl-cert'; then
    ARGS+=(--ssl-cert="$OPENCONNECT_CERT_FILE")
  else
    ARGS+=(--certificate="$OPENCONNECT_CERT_FILE")
  fi
  printf '%s\n' "$VPN_CERT" > "$OPENCONNECT_CERT_FILE"
  chmod 600 "$OPENCONNECT_CERT_FILE"
  log "Using client certificate authentication"

  if [ -n "$VPN_CERT_KEY" ]; then
    printf '%s\n' "$VPN_CERT_KEY" > "$OPENCONNECT_KEY_FILE"
    chmod 600 "$OPENCONNECT_KEY_FILE"
    ARGS+=(--ssl-key="$OPENCONNECT_KEY_FILE")
    log "Using private key from the 'cert_key' input"
  fi
fi

# A stale PID file from an earlier step would be mistaken for a live tunnel.
rm -f "$OPENCONNECT_PID_FILE"

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
log "Connecting to ${VPN_SERVER} using protocol '${VPN_PROTOCOL}'..."
connect_rc=0
printf '%s\n' "$VPN_PASSWORD" \
  | run_root timeout "$VPN_CONNECT_TIMEOUT" openconnect "${ARGS[@]}" "$VPN_SERVER" 2>&1 \
  | tee "$OPENCONNECT_LOG_FILE" || connect_rc=$?

# With --background the foreground process exits non-zero as soon as the
# handshake or authentication fails, so this is the primary failure signal.
if [ "$connect_rc" -ne 0 ]; then
  fail "openconnect exited with status ${connect_rc} while establishing the connection. See the log above and ${OPENCONNECT_LOG_FILE}."
fi
echo "::endgroup::"

# ---------------------------------------------------------------------------
# Wait for the tunnel to come up
# ---------------------------------------------------------------------------
connected=0
vpn_ip=""
vpn_pid_now=""
elapsed=0
while [ "$elapsed" -le "$VPN_WAIT_TIMEOUT" ]; do
  if vpn_pid_now="$(vpn_pid)"; then
    if ! pid_alive "$vpn_pid_now"; then
      echo "::group::openconnect log"
      cat "$OPENCONNECT_LOG_FILE" 2>/dev/null || true
      echo "::endgroup::"
      fail "VPN connection failed: openconnect (pid ${vpn_pid_now}) exited before the tunnel came up."
    fi
    if tunnel_has_address; then
      connected=1
      vpn_ip="$(tunnel_address || true)"
      break
    fi
  fi
  sleep "$VPN_POLL_INTERVAL"
  elapsed=$((elapsed + VPN_POLL_INTERVAL))
done

if [ "$connected" -eq 1 ]; then
  notice "VPN connection established (pid ${vpn_pid_now}, address ${vpn_ip:-unknown})."
else
  # The tunnel process is alive but no tun/utun interface could be detected.
  # That is usually an unusual interface name or a missing `ip` command, so it
  # is reported instead of failing an otherwise working connection.
  notice "openconnect is running (pid $(vpn_pid || printf 'unknown')) but no tunnel interface was detected. Verify connectivity in the next step."
fi

# ---------------------------------------------------------------------------
# Expose results to the calling workflow
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'vpn_ip=%s\n' "${vpn_ip:-}"
    printf 'pid=%s\n' "$(vpn_pid || true)"
    printf 'log_file=%s\n' "$OPENCONNECT_LOG_FILE"
  } >> "$GITHUB_OUTPUT"
fi

exit 0
