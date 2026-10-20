#!/usr/bin/env bash
#
# common.sh - Shared helpers for the OpenConnect GitHub Action.
#
# Provides logging, privilege escalation, OS / package-manager detection,
# automatic installation of the `openconnect` CLI and its routing script,
# protocol/version checks and VPN state helpers.
# Sourced by main.sh and disconnect.sh.
#
# Author: Persi.Liao <xiangchu.liao@gmail.com>
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared state paths
# ---------------------------------------------------------------------------
# The connect and disconnect entry points run in different processes (and,
# when using disconnect/action.yml, in a separate Action invocation), so they
# exchange state through files under the runner temp directory.
STATE_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
OPENCONNECT_PID_FILE="${OPENCONNECT_PID_FILE:-${STATE_DIR}/openconnect-action.pid}"
OPENCONNECT_LOG_FILE="${OPENCONNECT_LOG_FILE:-${STATE_DIR}/openconnect-action.log}"
OPENCONNECT_CERT_FILE="${OPENCONNECT_CERT_FILE:-${STATE_DIR}/openconnect-action-cert.pem}"
OPENCONNECT_KEY_FILE="${OPENCONNECT_KEY_FILE:-${STATE_DIR}/openconnect-action-key.pem}"

# Timing knobs. Overridable so the test suite can run fast.
VPN_POLL_INTERVAL="${VPN_POLL_INTERVAL:-1}"
VPN_WAIT_TIMEOUT="${VPN_WAIT_TIMEOUT:-60}"
# Upper bound for the foreground phase of openconnect. Protects the workflow
# from a server that waits for interactive input (e.g. a second factor) and
# would otherwise block the step until the job times out.
VPN_CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-90}"
VPN_STOP_TIMEOUT="${VPN_STOP_TIMEOUT:-10}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
# Plain informational line.
log() { printf '%s\n' "$*"; }

# GitHub Actions error annotation. Printing only: the caller decides how to
# fail, so that `set -e` cannot silently skip the caller's own error handling.
err() { printf '::error::%s\n' "$*" >&2; }

# GitHub Actions error annotation that also terminates the script.
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

# GitHub Actions notice annotation.
notice() { printf '::notice::%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Privilege escalation
# ---------------------------------------------------------------------------
# Run a command as root: use sudo when available and we are not already root,
# otherwise invoke it directly. This keeps the action working both on runners
# that run as root and on those that require sudo.
run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    # Keep the caller's PATH: sudo's default secure_path hides non-system
    # locations, for example the Homebrew sbin directory on macOS.
    sudo env "PATH=$PATH" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# OS / package-manager detection
# ---------------------------------------------------------------------------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v apk >/dev/null 2>&1; then
    printf 'apk'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  elif command -v brew >/dev/null 2>&1; then
    printf 'brew'
  else
    printf 'unknown'
  fi
}

# ---------------------------------------------------------------------------
# Routing script (vpnc-script)
# ---------------------------------------------------------------------------
# openconnect needs a routing script to configure the tunnel interface. A
# missing script still lets the TLS session come up, but no route is ever
# installed, which produces the confusing "connected but cannot reach the
# intranet" failure. Common installation prefixes are probed explicitly.
vpnc_script_path() {
  local candidate
  for candidate in \
    /usr/share/vpnc-scripts/vpnc-script \
    /etc/vpnc/vpnc-script \
    /usr/local/share/vpnc-scripts/vpnc-script \
    /opt/homebrew/share/vpnc-scripts/vpnc-script \
    /usr/local/etc/vpnc/vpnc-script; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Ensure the openconnect CLI (and a routing script) are available.
# ---------------------------------------------------------------------------
# Exits with a GitHub Actions error annotation when openconnect cannot be
# obtained or no routing script is present.
ensure_openconnect() {
  if ! command -v openconnect >/dev/null 2>&1; then
    log "openconnect not found - attempting automatic installation..."
    local pm
    pm="$(detect_pkg_manager)"

    case "$pm" in
      apt)
        run_root apt-get update -y
        run_root apt-get install -y --no-install-recommends openconnect vpnc-scripts
        ;;
      apk)
        run_root apk add --no-cache openconnect
        # The routing script package name is not stable across Alpine
        # releases; a missing script is reported by ensure_vpnc_script below.
        run_root apk add --no-cache vpnc-scripts || log "vpnc-scripts package unavailable on this image"
        ;;
      dnf)
        run_root dnf install -y openconnect
        run_root dnf install -y vpnc-scripts || log "vpnc-scripts package unavailable, see the note below on RHEL/CentOS"
        ;;
      yum)
        run_root yum install -y openconnect \
          || { err "Failed to install openconnect with yum. On RHEL/CentOS the package lives in EPEL: install epel-release first."; return 1; }
        run_root yum install -y vpnc-scripts || log "vpnc-scripts package unavailable, see the note below on RHEL/CentOS"
        ;;
      brew)
        # Homebrew must not be run as root.
        brew install openconnect
        ;;
      *)
        err "Unsupported operating system / package manager. Please install 'openconnect' manually before using this action."
        return 1
        ;;
    esac

    if ! command -v openconnect >/dev/null 2>&1; then
      err "Automatic installation of openconnect failed. Please install it manually."
      return 1
    fi
  fi

  log "openconnect ready: $(openconnect_version_or_unknown)"
}

openconnect_version_or_unknown() {
  local version
  version="$(openconnect_version 2>/dev/null || true)"
  printf '%s\n' "${version:-unknown version}"
}

# Print the routing script location, failing with an actionable message when
# none can be found.
ensure_vpnc_script() {
  local script
  if script="$(vpnc_script_path)"; then
    printf '%s\n' "$script"
    return 0
  fi

  err "No vpnc-script routing script was found. openconnect needs it to configure the tunnel interface. Install the 'vpnc-scripts' package (Debian/Ubuntu: vpnc-scripts, Fedora: vpnc-scripts, RHEL/CentOS: epel-release then vpnc-scripts) and re-run the action."
  return 1
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
openconnect_version() {
  openconnect --version 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1
}

# Normalise "major.minor" to a single comparable integer. Implemented without
# `sort -V` because busybox sort (Alpine images) does not support it.
version_num() {
  printf '%s' "$1" | awk -F. '{printf "%d%02d", $1, $2}'
}

# version_ge A B -> success when version A is greater than or equal to B.
version_ge() {
  [ "$(version_num "$1")" -ge "$(version_num "$2")" ]
}

# Lowest openconnect version that supports a given protocol.
protocol_min_version() {
  case "$1" in
    anyconnect|nc) printf '5.00' ;;
    jnpr|gp)       printf '5.00' ;;
    f5)            printf '7.00' ;;
    fortinet)      printf '7.11' ;;
    array)         printf '8.00' ;;
    pulse)         printf '8.05' ;;
    *)             return 1 ;;
  esac
}

# Warn (without failing) when the installed openconnect is older than the
# protocol requires. The CLI stays the final authority, so an unparseable
# version simply skips the check.
check_protocol_support() {
  local protocol="$1" minimum version
  minimum="$(protocol_min_version "$protocol")" || return 0
  version="$(openconnect_version 2>/dev/null || true)"
  [ -z "$version" ] && return 0
  if ! version_ge "$version" "$minimum"; then
    notice "Protocol '${protocol}' needs openconnect >= ${minimum}, but ${version} is installed. The connection may be rejected by the CLI."
  fi
}

# ---------------------------------------------------------------------------
# Connection state
# ---------------------------------------------------------------------------
# Read the PID recorded by openconnect --pid-file. Prints nothing when absent.
vpn_pid() {
  local pid
  [ -f "$OPENCONNECT_PID_FILE" ] || return 1
  pid="$(tr -cd '0-9' < "$OPENCONNECT_PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  printf '%s\n' "$pid"
}

pid_alive() {
  local pid="${1:-}"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if command -v ps >/dev/null 2>&1; then
    ps -p "$pid" >/dev/null 2>&1
    return $?
  fi
  # Minimal images without `ps`: Linux exposes the process through /proc.
  if [ -e "/proc/$pid" ]; then
    return 0
  fi
  # Last resort (macOS without ps): signal 0 only tests existence.
  kill -0 "$pid" 2>/dev/null
}

# Whether the process started by this action is still running. Falls back to a
# name match when no PID file exists (e.g. connect and disconnect ran with
# different temp directories).
vpn_is_running() {
  local pid
  if pid="$(vpn_pid)"; then
    pid_alive "$pid"
    return $?
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x openconnect >/dev/null 2>&1
  else
    ps -o comm= -A 2>/dev/null | grep -qx openconnect
  fi
}

# Tunnel interfaces created by openconnect are named tunN (Linux) or utunN
# (macOS). The check is advisory: an unusual interface name must not turn a
# working connection into a failure.
tunnel_has_address() {
  if command -v ip >/dev/null 2>&1; then
    ip -o addr show 2>/dev/null | awk '{print $2}' | grep -qE '^(utun|tun|ppp)[0-9]*$'
    return $?
  fi
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig -a 2>/dev/null | grep -qE '^(utun|tun|ppp)[0-9]*'
    return $?
  fi
  return 1
}

# IPv4 address assigned to the tunnel interface, empty when it cannot be read.
tunnel_address() {
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^(utun|tun|ppp)[0-9]*$/ {print $4; exit}' | cut -d/ -f1
    return 0
  fi
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig -a 2>/dev/null | awk '/^(utun|tun|ppp)[0-9]*/ {found=$1} /inet /{if (found) {print $2; exit}}'
    return 0
  fi
}
