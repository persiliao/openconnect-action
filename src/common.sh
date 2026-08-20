#!/usr/bin/env bash
#
# common.sh - Shared helpers for the OpenConnect GitHub Action.
#
# Provides logging, privilege escalation, OS / package-manager detection,
# automatic installation of the `openconnect` CLI when it is missing, and a
# portable "is the VPN running?" check. Sourced by main.sh and disconnect.sh.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
# Plain informational line.
log() { printf '%s\n' "$*" >&1; }

# GitHub Actions error annotation. Returns 1 so it can be used as `err && ...`.
err() { printf '::error::%s\n' "$*" >&2; return 1; }

# GitHub Actions error annotation that also terminates the script.
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

# GitHub Actions notice annotation.
notice() { printf '::notice::%s\n' "$*" >&1; }

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
    sudo "$@"
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
# Ensure the openconnect CLI is available, installing it if necessary.
# ---------------------------------------------------------------------------
# Returns 0 when openconnect is present, 1 when it could not be obtained.
# Relies on `set -e` in the caller to abort on an unrecoverable install error.
ensure_openconnect() {
  if command -v openconnect >/dev/null 2>&1; then
    log "openconnect already installed at: $(command -v openconnect)"
    return 0
  fi

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
      ;;
    dnf)
      run_root dnf install -y openconnect
      ;;
    yum)
      run_root yum install -y openconnect
      ;;
    brew)
      brew install openconnect
      ;;
    *)
      err "Unsupported operating system / package manager. Please install 'openconnect' manually before using this action."
      return 1
      ;;
  esac

  if command -v openconnect >/dev/null 2>&1; then
    log "openconnect installed successfully at: $(command -v openconnect)"
    return 0
  fi

  err "Automatic installation of openconnect failed. Please install it manually."
  return 1
}

# ---------------------------------------------------------------------------
# Connection state check
# ---------------------------------------------------------------------------
# Returns 0 if an openconnect process is running, 1 otherwise. Tolerates
# systems where pgrep is unavailable (e.g. some minimal containers) by
# falling back to `ps`.
vpn_is_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x openconnect >/dev/null 2>&1
  else
    ps -o comm= -A 2>/dev/null | grep -qx openconnect
  fi
}
