# OpenConnect Action

Connecting to VPN via OpenConnect protocol (Cisco AnyConnect compatible).

## Usage

### Basic Authentication

```yaml
steps:
  - uses: actions/checkout@v3
  
  - uses: persiliao/openconnect-action@v1
    with:
      server: ${{ secrets.VPN_SERVER }}
      username: ${{ secrets.VPN_USER }}
      password: ${{ secrets.VPN_PASSWORD }}
      group: ${{ secrets.VPN_GROUP }}  # optional
      
  - run: echo "Now connected to VPN"
```

### Certificate Authentication

```yaml
steps:
  - uses: persiliao/openconnect-action@v1
    with:
      server: ${{ secrets.VPN_SERVER }}
      username: ${{ secrets.VPN_USER }}
      password: ${{ secrets.VPN_PASSWORD }}
      cert: ${{ secrets.VPN_CERT }}
```

### Advanced Options

```yaml
steps:
  - uses: persiliao/openconnect-action@v1
    with:
      server: 'vpn.example.com'
      username: 'ci-user'
      password: 's3cr3t'
      background: 'false'  # run in foreground
      disconnect: 'false'  # keep connection alive
      
  # ... your steps ...
  
  - uses: persiliao/openconnect-action@v1
    with:
      disconnect: 'true'  # manually disconnect
```

## Inputs

| Input        | Required | Description                             |
| ------------ | -------- | --------------------------------------- |
| `server`     | Yes      | VPN server address                      |
| `username`   | Yes      | VPN username                            |
| `password`   | Yes      | VPN password                            |
| `protocol`   | No       | VPN protocol type (default: anyconnect) |
| `group`      | No       | VPN group/authentication realm          |
| `cert`       | No       | Client certificate in PEM format        |
| `background` | No       | Run in background (default: true)       |
| `disconnect` | No       | Auto-disconnect (default: false)         |

## Secrets

Store sensitive information as GitHub secrets:

- `VPN_SERVER`
- `VPN_USER`
- `VPN_PASSWORD`
- `VPN_PROTOCOL` (optional)
- `VPN_GROUP` (optional)
- `VPN_CERT` (optional)