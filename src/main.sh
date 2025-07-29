#!/bin/bash
set -e

echo "::group::Setting up OpenConnect VPN connection"

# Validate protocol parameter
VALID_PROTOCOLS=("anyconnect" "nc" "gp" "pulse" "f5" "fortinet" "array")
if [[ ! " ${VALID_PROTOCOLS[*]} " =~ " ${VPN_PROTOCOL} " ]]; then
  echo "::error::Invalid protocol specified. Valid options are: ${VALID_PROTOCOLS[*]}"
  exit 1
fi

# Build protocol argument
PROTOCOL_OPT="--protocol=${VPN_PROTOCOL}"

# Build cert argument
if [ -n "$VPN_CERT" ]; then
  echo "Using certificate authentication"
  CERT_FILE="/tmp/vpn-cert.pem"
  echo "$VPN_CERT" > "$CERT_FILE"
  chmod 600 "$CERT_FILE"
  CERT_OPT="--certificate=$CERT_FILE"
fi

# Build authgroup argument
GROUP_OPT=""
if [ -n "$VPN_GROUP" ]; then
  GROUP_OPT="--authgroup=$VPN_GROUP"
fi

# Build background optargumention
BACKGROUND_OPT=""
if [ "$RUN_IN_BACKGROUND" = "true" ]; then
  BACKGROUND_OPT="--background"
fi

# Execute connection command
echo "$VPN_PASSWORD" | sudo openconnect \
  --quiet \
  --user="$VPN_USER" \
  $PROTOCOL_OPT \
  $GROUP_OPT \
  $CERT_OPT \
  --passwd-on-stdin \
  $BACKGROUND_OPT \
  "$VPN_SERVER"

# Wait for connection establishment
sleep 10

echo "::endgroup::"

# Validate connect
if ! pgrep -x "openconnect" > /dev/null; then
  echo "::error::VPN connection failed"
  exit 1
fi

echo "VPN connection established successfully"