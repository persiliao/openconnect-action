#!/usr/bin/env bash
#
# run_tests.sh - Test suite for the OpenConnect GitHub Action scripts.
#
# No external test framework is required so the suite can run on any runner
# and inside a throwaway container:
#   docker run --rm -v "$PWD:/work" -w /work ubuntu:22.04 bash tests/run_tests.sh
#
# Author: Persi.Liao <xiangchu.liao@gmail.com>
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/src"
WORK="$(mktemp -d)"
BIN="${WORK}/bin"
mkdir -p "$BIN"

pass=0
failures=0

ok()   { pass=$((pass + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { failures=$((failures + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
group(){ printf '\n== %s\n' "$1"; }

assert_eq() { # expected actual name
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected [$1], got [$2])"; fi
}
assert_contains() { # haystack needle name
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi
}
assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected [$2])"; else ok "$3"; fi
}
assert_rc() { # expected_rc actual_rc name
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected rc $1, got $2)"; fi
}

# --- test fixtures ---------------------------------------------------------

# Fake openconnect binary. Behaviour is selected through MOCK_MODE.
cat > "${BIN}/openconnect" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "Openconnect VPN client v8.20 (GnuTLS)"; exit 0 ;;
  --help)    echo "  --ssl-cert=FILE   Use SSL client certificate FILE"; exit 0 ;;
esac
printf '%s\n' "$@" > "${MOCK_ARGS_FILE:?}"
printf 'mock: received %d arguments\n' "$#"
pid_file=""
for arg in "$@"; do
  case "$arg" in --pid-file=*) pid_file="${arg#--pid-file=}" ;; esac
done
case "${MOCK_MODE:-stay}" in
  earlyfail)
    echo "mock: authentication failed (HTTP 401)" >&2
    exit 22
    ;;
  deadpid)
    # Record a PID that cannot exist, as if the daemon died right after fork.
    printf '99999999\n' > "$pid_file"
    exit 0
    ;;
  *)
    # Emulate --background: fork a long-lived daemon, then exit straight away.
    # The daemon must not keep the caller's stdout pipe open, exactly like a
    # real daemonizing openconnect, otherwise `tee` never sees EOF.
    sleep 30 </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$pid_file"
    exit 0
    ;;
esac
MOCK
chmod +x "${BIN}/openconnect"

# Fake `ip` reporting a configured tunnel, so the success path is deterministic.
cat > "${BIN}/ip" <<'MOCKIP'
#!/bin/sh
printf '2: tun9    inet 10.99.99.9/24 brd 10.99.99.255 scope global tun9\n'
MOCKIP
chmod +x "${BIN}/ip"

# openconnect needs a routing script to be present; provide one for the tests.
# CI runners are not root, so the system location needs privilege escalation.
if [ ! -f /usr/share/vpnc-scripts/vpnc-script ]; then
  privilege=""
  [ "$(id -u)" -eq 0 ] || privilege="sudo"
  # shellcheck disable=SC2086  # an empty privilege prefix must disappear
  $privilege mkdir -p /usr/share/vpnc-scripts
  printf '#!/bin/sh\nexit 0\n' | $privilege tee /usr/share/vpnc-scripts/vpnc-script >/dev/null
  $privilege chmod +x /usr/share/vpnc-scripts/vpnc-script
fi
if [ ! -f /usr/share/vpnc-scripts/vpnc-script ]; then
  printf 'Cannot provide a vpnc-script for the tests: run as root or install sudo.\n' >&2
  exit 1
fi

export PATH="${BIN}:${PATH}"
export RUNNER_TEMP="${WORK}/runner_temp"
mkdir -p "$RUNNER_TEMP"
export VPN_POLL_INTERVAL=1 VPN_WAIT_TIMEOUT=3 VPN_STOP_TIMEOUT=2
export MOCK_ARGS_FILE="${WORK}/args.txt"

# Common inputs for the connect script.
connect_env() {
  export VPN_SERVER="vpn.example.com" VPN_USER="tester" VPN_PASSWORD="s3cret"
  export VPN_PROTOCOL="${test_protocol:-anyconnect}" VPN_GROUP="" VPN_CERT="${test_cert:-}" VPN_CERT_KEY=""
}
run_main()  { ( connect_env; bash "${SRC}/main.sh" 2>&1 ); }
run_disc()  { ( bash "${SRC}/disconnect.sh" 2>&1 ); }

# --- 1. regression guards on the sources ----------------------------------
group "static regression guards"
main_src="$(cat "${SRC}/main.sh")"
assert_not_contains "$main_src" "sudo openconnect" "connect command goes through run_root, not a hardcoded sudo"
assert_contains     "$main_src" 'run_root timeout' "connect honours a foreground timeout"
assert_contains     "$main_src" "--pid-file"       "connect records a PID file"
assert_contains "$(cat "${SRC}/common.sh")" 'env "PATH=$PATH"' "privilege escalation preserves PATH for non-system installs"
err_helper="$(grep '^err()' "${SRC}/common.sh")"
assert_not_contains "$err_helper" "return" "err() only prints, the caller controls failure"

action_yml="$(cat "${REPO_ROOT}/action.yml")"
assert_not_contains "$action_yml" "background:" "the foreground 'background' input was removed"
assert_not_contains "$action_yml" "disconnect:" "disconnect moved to its own action"
assert_contains     "$action_yml" "cert_key:"   "cert_key input is exposed"
assert_contains     "$action_yml" "vpn_ip:"     "vpn_ip output is exposed"
assert_not_contains "$action_yml" "always()"    "redundant always() guard removed"

disc_yml="$(cat "${REPO_ROOT}/disconnect/action.yml")"
assert_contains "$disc_yml" "using: 'composite'"   "disconnect entry point is a composite action"
assert_contains "$disc_yml" "src/disconnect.sh"    "disconnect entry point reuses the shared script"

# --- 2. helpers in common.sh ----------------------------------------------
group "common.sh helpers"
helper_out="$(
  cd "$WORK" && OPENCONNECT_PID_FILE="${WORK}/nope.pid" bash -c "
    set -uo pipefail
    source '${SRC}/common.sh'
    printf '%s\n' \"\$(detect_pkg_manager)\"
    printf '%s\n' \"\$(protocol_min_version pulse)\"
    version_ge 8.20 8.05 && echo ge1
    version_ge 7.11 8.00 || echo ge2
    version_ge 8.05 8.05 && echo ge3
    protocol_min_version bogus || echo unknown_protocol
    vpn_pid || echo no_pid
    pid_alive '' || echo empty_pid_dead
    pid_alive \$\$ && echo self_alive
    pid_alive 99999999 || echo huge_pid_dead
    PATH=/nonexistent /bin/bash -c 'set -u; source ${SRC}/common.sh; pid_alive $$ && echo proc_fallback'
  " 2>&1
)"
assert_contains "$helper_out" "apt"                    "detect_pkg_manager finds apt"
assert_contains "$helper_out" "8.05"                   "protocol_min_version knows pulse"
assert_contains "$helper_out" "ge1"                    "version_ge accepts 8.20 >= 8.05"
assert_contains "$helper_out" "ge2"                    "version_ge rejects 7.11 >= 8.00"
assert_contains "$helper_out" "ge3"                    "version_ge is inclusive on equal versions"
assert_contains "$helper_out" "unknown_protocol"       "protocol_min_version rejects unknown protocols"
assert_contains "$helper_out" "no_pid"                 "vpn_pid reports a missing PID file"
assert_contains "$helper_out" "empty_pid_dead"         "pid_alive rejects non-numeric input"
assert_contains "$helper_out" "huge_pid_dead"          "pid_alive reports a PID that cannot exist"
assert_contains "$helper_out" "proc_fallback"          "pid_alive works without ps, through /proc"
assert_contains "$helper_out" "self_alive"             "pid_alive sees its own shell"

# --- 3. input validation ---------------------------------------------------
group "input validation"
out="$( VPN_SERVER="" VPN_USER=u VPN_PASSWORD=p bash "${SRC}/main.sh" 2>&1 )"; rc=$?
assert_rc 1 "$rc" "missing server is rejected"
assert_contains "$out" "Missing required input: 'server'" "missing server names the offending input"

test_protocol="bogus"; out="$(run_main)"; rc=$?; unset test_protocol
assert_rc 1 "$rc" "invalid protocol is rejected"
assert_contains "$out" "Invalid protocol 'bogus'" "invalid protocol is reported"

# --- 4. connect: success path ---------------------------------------------
group "connect success path"
out="$(run_main)"; rc=$?
assert_rc 0 "$rc" "connect succeeds against the mock"
assert_contains "$out" "Routing script:" "connect resolves the routing script"
mock_args="$(cat "$MOCK_ARGS_FILE")"
assert_contains "$mock_args" "--background"                  "openconnect is started detached"
assert_contains "$mock_args" "--passwd-on-stdin"             "password is passed on stdin, never on the command line"
assert_contains "$mock_args" "--protocol=anyconnect"         "protocol is forwarded"
assert_contains "$mock_args" "--reconnect-timeout=60"        "reconnect timeout is enabled"
assert_contains "$mock_args" "--script=/usr/share/vpnc-scripts/vpnc-script" "routing script is passed explicitly"
assert_not_contains "$mock_args" "s3cret" "the password never reaches the process arguments"
tunnel_notice="$(printf '%s' "$out" | grep -c 'VPN connection established' || true)"
assert_eq 1 "$tunnel_notice" "the established tunnel is announced exactly once"

# --- 5. connect: failure paths surface the real cause ---------------------
group "connect failure paths"
export MOCK_MODE=earlyfail
out="$(run_main)"; rc=$?
unset MOCK_MODE
assert_rc 1 "$rc" "handshake failure fails the step"
assert_contains "$out" "authentication failed (HTTP 401)" "openconnect output is surfaced to the user"
assert_contains "$out" "exited with status 22" "the openconnect exit status is reported"

export MOCK_MODE=deadpid
out="$(run_main)"; rc=$?
unset MOCK_MODE
assert_rc 1 "$rc" "a daemon that dies right after fork fails"
assert_contains "$out" "exited before the tunnel came up" "the dead-daemon case is explained"

# --- 6. certificate handling ---------------------------------------------
group "certificate handling"
export test_cert="-----BEGIN CERTIFICATE-----
mock
-----END CERTIFICATE-----"
out="$(run_main)"; rc=$?
mock_args="$(cat "$MOCK_ARGS_FILE")"
assert_rc 0 "$rc" "connect with a client certificate succeeds"
assert_contains "$mock_args" "--ssl-cert=${RUNNER_TEMP}/openconnect-action-cert.pem" "PEM material uses --ssl-cert"
cert_perms="$(stat -c '%a' "${RUNNER_TEMP}/openconnect-action-cert.pem" 2>/dev/null || stat -f '%Lp' "${RUNNER_TEMP}/openconnect-action-cert.pem")"
assert_eq 600 "$cert_perms" "the certificate file is only readable by its owner"
assert_not_contains "$out" "openconnect-action-cert.pem" "the certificate path is not logged"

# --- 7. disconnect --------------------------------------------------------
group "disconnect"
rm -f "${RUNNER_TEMP}/openconnect-action.pid"
out="$(run_disc)"; rc=$?
assert_rc 0 "$rc" "disconnect without a tunnel succeeds"
assert_contains "$out" "nothing to do" "disconnect reports there is nothing to stop"

printf '99999999\n' > "${RUNNER_TEMP}/openconnect-action.pid"
out="$(run_disc)"; rc=$?
assert_rc 0 "$rc" "disconnect tolerates a stale PID file"
assert_contains "$out" "already gone" "a stale PID file is reported and cleaned up"
if [ -e "${RUNNER_TEMP}/openconnect-action.pid" ]; then bad "the stale PID file is removed"; else ok "the stale PID file is removed"; fi

sleep 60 & victim=$!
printf '%s\n' "$victim" > "${RUNNER_TEMP}/openconnect-action.pid"
printf 'cert\n' > "${RUNNER_TEMP}/openconnect-action-cert.pem"
out="$(run_disc)"; rc=$?
assert_rc 0 "$rc" "disconnect stops the recorded PID"
assert_contains "$out" "VPN disconnected successfully" "disconnect reports success"
reaped=0
wait "$victim" 2>/dev/null || reaped=$?
if [ "$reaped" -eq 0 ]; then bad "the recorded process exited cleanly (expected an interrupt signal)"; else ok "the recorded process was terminated"; fi
if [ -e "${RUNNER_TEMP}/openconnect-action.pid" ]; then bad "the PID file is removed"; else ok "the PID file is removed"; fi
if [ -e "${RUNNER_TEMP}/openconnect-action-cert.pem" ]; then bad "the certificate file is removed"; else ok "the certificate file is removed"; fi

# --- summary --------------------------------------------------------------
rm -rf "$WORK"
printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ] || exit 1
