#!/bin/bash
set -e

echo "::group::Disconnecting VPN"

if ! pgrep -x "openconnect" > /dev/null; then
  echo 'No active VPN connection found'
  exit 1
fi

sudo pkill -INT openconnect
sleep 5

if pgrep -x "openconnect" > /dev/null; then
  sudo pkill -9 openconnect
  echo 'VPN disconnected unexpectedly'
  exit 0
else
  echo "VPN disconnected"
  exit 0
fi

echo "::endgroup::"