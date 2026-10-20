# OpenConnect VPN Connector GitHub Action

📖 **Documentation**: [English](README.md) | [简体中文](README.zh-CN.md)

A GitHub Action that connects a job to a VPN using `openconnect` and keeps the tunnel up for the rest of the workflow. Supports Cisco AnyConnect, GlobalProtect, Fortinet, Pulse/Juniper and more.

## Table of Contents

- [Features](#features)
- [Input Parameters](#input-parameters)
- [Outputs](#outputs)
- [Usage](#usage)
- [Automatic Installation](#automatic-installation)
- [Protocol Support](#protocol-support)
- [Platform Support](#platform-support)
- [Migrating from v1](#migrating-from-v1)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [License](#license)
- [Contributing](#contributing)

## Features

- ✅ Eight VPN protocols (AnyConnect, GlobalProtect, Fortinet, Pulse, Juniper, F5, Array, NC)
- ✅ Client certificate authentication (PEM certificate, optional separate key)
- ✅ Automatic installation of `openconnect` and its routing script when missing
- ✅ Detached tunnel: the connection never blocks the workflow
- ✅ Fail-fast status check that keeps the real `openconnect` output for debugging
- ✅ Precise teardown by PID, so unrelated VPN processes on a shared runner are untouched
- ✅ Tunnel address, PID and log path exposed as action outputs

## Input Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `server` | VPN server address (URL or IP) | Yes | - |
| `username` | VPN username | Yes | - |
| `password` | VPN password | Yes | - |
| `group` | VPN group / authentication group | No | - |
| `protocol` | VPN protocol, see [Protocol Support](#protocol-support) | No | `anyconnect` |
| `cert` | Client certificate in PEM format (include the private key, or provide `cert_key`) | No | - |
| `cert_key` | Private key in PEM format, when it is not part of `cert` | No | - |

## Outputs

Declare an `id` on the step to read them:

| Output | Description |
|--------|-------------|
| `vpn_ip` | IPv4 address assigned to the tunnel interface (empty when it could not be detected) |
| `pid` | PID of the backgrounded `openconnect` process |
| `log_file` | Path of the `openconnect` log, useful when the connection fails |

## Usage

### Basic Usage

```yaml
name: Connect to VPN
on: [push]

jobs:
  connect-vpn:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Connect to VPN
        uses: persiliao/openconnect-action@v2
        with:
          server: 'vpn.example.com'
          username: ${{ secrets.VPN_USERNAME }}
          password: ${{ secrets.VPN_PASSWORD }}
          group: 'YourVPNGroup'
          protocol: 'anyconnect'
```

### Usage in Container Jobs

Add the network permissions the tunnel needs to the `container` configuration:

```yaml
jobs:
  container-job:
    runs-on: ubuntu-latest
    container:
      image: node:20
      options: --cap-add=NET_ADMIN --device=/dev/net/tun
    steps:
      - uses: actions/checkout@v4

      - name: Connect to VPN
        uses: persiliao/openconnect-action@v2
        with:
          server: 'vpn.company.com'
          username: ${{ secrets.VPN_USER }}
          password: ${{ secrets.VPN_PASS }}

      - name: Run tests through the VPN
        run: npm test
```

The action uses `sudo` only when the step is not already running as root, and
falls back to running directly when `sudo` is not installed in the image.

### Client Certificate Authentication

```yaml
- name: Connect with a client certificate
  uses: persiliao/openconnect-action@v2
  with:
    server: 'secure-vpn.example.com'
    username: 'service-account'
    password: ${{ secrets.VPN_SERVICE_PASSWORD }}
    cert: ${{ secrets.VPN_CLIENT_CERT }}      # PEM
    cert_key: ${{ secrets.VPN_CLIENT_KEY }}   # optional, when not in `cert`
    protocol: 'pulse'
```

### Complete CI/CD Workflow

```yaml
name: Deploy to Internal Network
on:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Connect to the production VPN
        id: vpn
        uses: persiliao/openconnect-action@v2
        with:
          server: 'prod-vpn.company.com'
          username: ${{ secrets.PROD_VPN_USER }}
          password: ${{ secrets.PROD_VPN_PASS }}
          group: 'Production'

      - name: Show the assigned tunnel address
        run: echo "VPN address is ${{ steps.vpn.outputs.vpn_ip }}"

      - name: Deploy to the internal server
        run: ./deploy.sh

      - name: Disconnect from the production VPN
        if: always()
        uses: persiliao/openconnect-action/disconnect@v2
```

### Disconnecting

A composite action cannot run code after the caller's own steps, so teardown is
a separate entry point. Add `if: always()` so the tunnel is closed even when a
job step fails:

```yaml
- name: Disconnect VPN
  if: always()
  uses: persiliao/openconnect-action/disconnect@v2
```

It stops exactly the process this action started (tracked through a PID file)
and removes the certificate material written during the connection.

## Automatic Installation

`openconnect` does not need to be pre-installed. The action checks for the
binary and installs it with the detected package manager:

| Runner / OS | Package manager | Command used |
|-------------|-----------------|--------------|
| Ubuntu / Debian (incl. containers) | `apt` | `apt-get install -y openconnect vpnc-scripts` |
| Alpine (containers) | `apk` | `apk add --no-cache openconnect vpnc-scripts` |
| Fedora / RHEL (dnf) | `dnf` | `dnf install -y openconnect vpnc-scripts` |
| Fedora / RHEL (yum) | `yum` | `yum install -y openconnect vpnc-scripts` |
| macOS (`macos-latest`) | `brew` | `brew install openconnect` |

Notes:

- On RHEL / CentOS `openconnect` lives in EPEL, so install `epel-release` first.
- The action also verifies that a `vpnc-script` routing script exists and fails
  with an actionable message when it does not. Without that script the TLS
  session comes up but no route is ever installed.
- On unsupported operating systems the action stops with a clear error instead
  of guessing.

## Protocol Support

| Value | VPN product |
|-------|-------------|
| `anyconnect` | Cisco AnyConnect |
| `gp` | GlobalProtect |
| `pulse` | Pulse Connect Secure (openconnect >= 8.05) |
| `jnpr` | Juniper / Pulse Secure |
| `nc` | Juniper Network Connect |
| `f5` | F5 BIG-IP Edge Gateway |
| `fortinet` | FortiGate SSL VPN |
| `array` | Array Networks VPN |

A protocol that is newer than the installed `openconnect` triggers a warning
annotation before the connection is attempted.

## Platform Support

| Platform | Status |
|----------|--------|
| `ubuntu-*` hosted runners | Fully supported |
| Linux containers | Supported with `--cap-add=NET_ADMIN --device=/dev/net/tun` |
| `macos-*` runners | Best effort: needs root and utun access, not granted by default on hosted runners |
| `windows-*` runners | Not supported (needs `pgrep`, `pkill`, `ip`) |

## Migrating from v1

- **`background` input removed.** It only accepted `false` in theory: keeping the
  tunnel in the foreground blocks the step forever, so no later step ever runs.
  The tunnel is always detached now; delete the input.
- **`disconnect` input removed.** Both actions used to run back to back inside a
  single invocation, which disconnected the tunnel before your own steps ran.
  Use `persiliao/openconnect-action/disconnect@v2` at the end of the job instead.
- **Client certificates now use `--ssl-cert`** (PEM), matching the documented
  format. Older `openconnect` builds automatically fall back to `--certificate`.
  `cert_key` is new for a key stored separately from the certificate.
- **Pin a version explicitly.** Release tags are movable pointers; for
  supply-chain sensitive workloads pin the full commit SHA:
  `uses: persiliao/openconnect-action@<40-char-sha>`.

## Security Best Practices

1. **Use GitHub Secrets** for every credential; the password is delivered on
   stdin and never appears in the process arguments.
2. **Principle of least privilege**: use VPN accounts with minimal permissions.
3. **Always disconnect**: finish the job with `disconnect@v2` guarded by `if: always()`.
4. **Prefer certificate authentication** over password authentication.
5. **Restrict workflow permissions**:

```yaml
permissions:
  contents: read
```

## Troubleshooting

### The connection fails and the reason is unclear

The action keeps the raw `openconnect` output. It is printed inline when the
connection fails and also written to the file exposed by the `log_file` output.

### "Permission denied" while creating the tunnel

Add the device permissions to the container:
`options: --cap-add=NET_ADMIN --device=/dev/net/tun`

### Connected, but the intranet is unreachable

That is the classic symptom of a missing routing script. The action checks for
`vpnc-script` and refuses to run without it; install the `vpnc-scripts` package
(on RHEL/CentOS enable EPEL first).

### The tunnel drops during a long job

The action passes `--reconnect-timeout=60`, so `openconnect` retries for a minute
before giving up. For flaky links consider a self-hosted runner.

### Authentication never finishes

Servers that demand an interactive second factor cannot be served by a
non-interactive runner. The foreground phase is capped by a timeout so the step
fails fast instead of hanging the job. If your VPN supports it, use certificate
authentication.

### Debug logs

`ACTIONS_STEP_DEBUG` is a repository **secret**, not a workflow environment
variable: add it under *Settings → Secrets and variables → Actions*, then re-run
the workflow.

## Development

Run everything inside a throwaway container:

```bash
# Test suite (needs root or sudo inside the container)
docker run --rm -v "$PWD:/work" -w /work ubuntu:22.04 bash tests/run_tests.sh

# Shell lint
docker run --rm -v "$PWD:/code" -w /code koalaman/shellcheck:stable -x -s bash src/*.sh

# Action metadata lint
docker run --rm -v "$PWD:/repo" rhysd/actionlint:latest
```

CI runs the same checks on every push and pull request.

## License

MIT License - See [LICENSE](LICENSE) file for details

## Contributing

Issues and pull requests are welcome. Please keep changes covered by
`tests/run_tests.sh` and update both README versions in the same commit.
