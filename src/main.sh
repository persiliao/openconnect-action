#!/usr/bin/env bash
#
# main.sh - Establish an OpenConnect VPN connection.
#
# Inputs are supplied via environment variables (see action.yml):
#   VPN_SERVER, VPN_PROTOCOL, VPN_USER, VPN_PASSWORD, VPN_GROUP,
#   VPN_CERT, RUN_IN_BACKGROUND
#
set -euo pipefail

# Load shared helpers by resolving the directory this script lives in.
ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${ACTION_DIR}/common.sh"

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
RUN_IN_BACKGROUND="${RUN_IN_BACKGROUND:-true}"

# ---------------------------------------------------------------------------
# Validate required inputs
# ---------------------------------------------------------------------------
[ -z "$VPN_SERVER" ]   && fail "Missing required input: 'server'"
[ -z "$VPN_USER" ]     && fail "Missing required input: 'username'"
[ -z "$VPN_PASSWORD" ] && fail "Missing required input: 'password'"

# ---------------------------------------------------------------------------
# Validate protocol
# ---------------------------------------------------------------------------
VALID_PROTOCOLS=("anyconnect" "nc" "jnpr" "pulse" "gp" "f5" "fortinet" "array")
if [[ ! " ${VALID_PROTOCOLS[*]} " =~ " ${VPN_PROTOCOL} " ]]; then
  fail "Invalid protocol '${VPN_PROTOCOL}'. Valid options: ${VALID_PROTOCOLS[*]}"
fi

# ---------------------------------------------------------------------------
# Make sure the CLI is present (install automatically if missing)
# ---------------------------------------------------------------------------
ensure_openconnect

# ---------------------------------------------------------------------------
# Build command arguments (array avoids unsafe word-splitting)
# ---------------------------------------------------------------------------
ARGS=(--quiet --user="$VPN_USER" --protocol="$VPN_PROTOCOL" --passwd-on-stdin)

if [ -n "$VPN_GROUP" ]; then
  ARGS+=(--authgroup="$VPN_GROUP")
fi

if [ -n "$VPN_CERT" ]; then
  CERT_FILE="$(mktemp -t vpn-cert.XXXXXX.pem)"
  printf '%s\n' "$VPN_CERT" > "$CERT_FILE"
  chmod 600 "$CERT_FILE"
  ARGS+=(--certificate="$CERT_FILE")
  log "Using client certificate authentication (stored at ${CERT_FILE})"
fi

if [ "$RUN_IN_BACKGROUND" = "true" ]; then
  ARGS+=(--background)
fi

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
log "Connecting to ${VPN_SERVER} using protocol '${VPN_PROTOCOL}'..."
printf '%s\n' "$VPN_PASSWORD" | sudo openconnect "${ARGS[@]}" "$VPN_SERVER"

# Give the tunnel a moment to come up before validating.
SLEEP_SECONDS=10
log "Waiting ${SLEEP_SECONDS}s for the tunnel to establish..."
sleep "$SLEEP_SECONDS"

echo "::endgroup::"

if ! vpn_is_running; then
  fail "VPN connection failed - openconnect process is not running."
fi

notice "VPN connection established successfully."
