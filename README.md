# OpenConnect VPN Connector GitHub Action

A GitHub Action for connecting to OpenConnect VPN in GitHub Actions workflows. Supports Cisco AnyConnect, Juniper, Palo Alto Networks, and other VPN servers.

## Features

- ✅ Multiple VPN protocol support (AnyConnect, Juniper, Pulse Secure, etc.)
- ✅ Client certificate authentication
- ✅ Background mode operation
- ✅ Automatic disconnection
- ✅ Docker container support
- ✅ **Automatic installation** of the `openconnect` CLI when missing
- ✅ Robust input validation and connection status checks

## Input Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `server` | VPN server address (URL or IP) | Yes | - |
| `username` | VPN username | Yes | - |
| `password` | VPN password | Yes | - |
| `group` | VPN group (optional) | No | - |
| `protocol` | VPN protocol type | No | `anyconnect` |
| `cert` | Client certificate in PEM format | No | - |
| `background` | Run VPN connection in background | No | `true` |
| `disconnect` | Automatically disconnect when workflow completes | No | `false` |

## Usage

### Basic Usage Example

```yaml
name: Connect to VPN
on: [push]

jobs:
  connect-vpn:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
        
      - name: Connect to VPN
        uses: persiliao/openconnect-action@v1
        with:
          server: 'vpn.example.com'
          username: ${{ secrets.VPN_USERNAME }}
          password: ${{ secrets.VPN_PASSWORD }}
          group: 'YourVPNGroup'
          protocol: 'anyconnect'
```

### Usage in Docker Container Jobs

If you need to use this Action in Docker container jobs, you must add network device permissions to the `container` configuration:

```yaml
name: Run tests through VPN
on: [push]

jobs:
  container-job:
    runs-on: ubuntu-latest
    container:
      image: node:16-alpine
      # Required options to allow VPN connections
      options: --cap-add=NET_ADMIN --device=/dev/net/tun --device=/dev/vhost-net
      
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
        
      - name: Connect to VPN
        uses: persiliao/openconnect-action@v1
        with:
          server: 'vpn.company.com'
          username: ${{ secrets.VPN_USER }}
          password: ${{ secrets.VPN_PASS }}
          background: 'true'
          
      - name: Run tests through VPN
        run: |
          curl https://internal.company-api.com
          npm test
```

### Using with Client Certificate Authentication

```yaml
- name: Connect to VPN with certificate
  uses: persiliao/openconnect-action@v1
  with:
    server: 'secure-vpn.example.com'
    username: 'service-account'
    password: ${{ secrets.VPN_SERVICE_PASSWORD }}
    cert: ${{ secrets.VPN_CLIENT_CERT }}
    protocol: 'juniper'
```

### Complete CI/CD Workflow Example

```yaml
name: Deploy to Internal Network
on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          
      - name: Install dependencies
        run: npm ci
        
      - name: Run tests locally
        run: npm test
        
      - name: Connect to Production VPN
        uses: persiliao/openconnect-action@v1
        with:
          server: 'prod-vpn.company.com'
          username: ${{ secrets.PROD_VPN_USER }}
          password: ${{ secrets.PROD_VPN_PASS }}
          group: 'Production'
          
      - name: Build application
        run: npm run build
        
      - name: Deploy to internal server
        run: |
          scp -o StrictHostKeyChecking=no -r dist/* deploy@internal-server:/var/www/app/
          
      - name: Run integration tests through VPN
        run: |
          npm run test:integration
          
      - name: Disconnect to Production VPN
        uses: persiliao/openconnect-action@v1
        with:
          disconnect: 'true'
```

## Automatic Installation

The action no longer requires `openconnect` to be pre-installed on the runner.
Before connecting, it checks whether the `openconnect` binary is available and,
if not, installs it automatically using the package manager detected for the
current OS:

| Runner / OS                | Package manager | Command used                                  |
|----------------------------|-----------------|-----------------------------------------------|
| Ubuntu / Debian (incl. containers) | `apt`  | `apt-get install -y openconnect vpnc-scripts` |
| Alpine (containers)        | `apk`           | `apk add --no-cache openconnect`              |
| Fedora / RHEL (dnf)        | `dnf`           | `dnf install -y openconnect`                  |
| Fedora / RHEL (yum)        | `yum`           | `yum install -y openconnect`                  |
| macOS (`macos-latest`)     | `brew`          | `brew install openconnect`                    |

Privilege escalation is handled automatically: `sudo` is used only when the
step is not already running as root. If the OS / package manager is not
supported, the action fails with a clear error asking you to install
`openconnect` manually.

## Protocol Support

Currently supports the following protocols (`protocol` parameter):

- `anyconnect` - Cisco AnyConnect
- `nc` - Juniper Network Connect
- `jnpr` - Juniper/Pulse Secure
- `pulse` - Pulse Connect Secure
- `gp` - GlobalProtect
- `f5` - F5 BIG-IP Edge Gateway
- `fortinet` - FortiGate SSL VPN
- `array` - Array Networks VPN

## Security Best Practices

1. **Use GitHub Secrets**: Never hardcode VPN credentials in your code
2. **Principle of Least Privilege**: Use VPN accounts with minimal required permissions
3. **Auto-disconnect**: Set `disconnect: 'true'` to ensure VPN connections are terminated
4. **Certificate Authentication**: Prefer client certificate authentication over password authentication
5. **Restrict Action Permissions**: Limit permissions in your workflow file:

```yaml
permissions:
  contents: read
  # Only grant the permissions actually needed
```

## Troubleshooting

### Common Issues

1. **Connection Failed with "Permission denied"**
   - Ensure correct device permissions are added when running in containers
   - Verify `--cap-add=NET_ADMIN` and `--device=/dev/net/tun` and `--device=/dev/vhost-net` options

2. **Unstable VPN Connection**
   - Ensure the Runner has stable network connectivity
   - Consider using self-hosted Runners for VPN connections

3. **Certificate Format Issues**
   - Ensure certificates are in valid PEM format
   - Verify certificates include the complete certificate chain

### Debug Mode

Add the `ACTIONS_STEP_DEBUG` secret to enable debug logging:

```yaml
env:
  ACTIONS_STEP_DEBUG: true
```

## Dependencies

`openconnect` is installed automatically by the action when missing (see
[Automatic Installation](#automatic-installation)), so no manual setup is
required on supported runners. For unsupported operating systems, install the
following manually before using the action:

- `openconnect` (the CLI binary)
- `vpnc-script` or equivalent (tunnel routing script)
- `sudo` (only needed when the step does not already run as root)

## License

MIT License - See LICENSE file for details

## Contributing

Issues and Pull Requests are welcome to help improve this Action.