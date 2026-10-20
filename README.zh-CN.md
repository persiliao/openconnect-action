# OpenConnect VPN 连接器 GitHub Action

📖 **文档**：[English](README.md) | [简体中文](README.zh-CN.md)

使用 `openconnect` 为当前 job 建立 VPN 连接，并在后续步骤中保持隧道的 GitHub Action。支持 Cisco AnyConnect、GlobalProtect、Fortinet、Pulse/Juniper 等网关。

## 目录

- [功能特性](#功能特性)
- [输入参数](#输入参数)
- [输出参数](#输出参数)
- [使用方法](#使用方法)
- [自动安装](#自动安装)
- [协议支持](#协议支持)
- [平台支持](#平台支持)
- [从 v1 迁移](#从-v1-迁移)
- [安全最佳实践](#安全最佳实践)
- [故障排查](#故障排查)
- [本地开发](#本地开发)
- [许可证](#许可证)
- [参与贡献](#参与贡献)

## 功能特性

- ✅ 支持八种 VPN 协议（AnyConnect、GlobalProtect、Fortinet、Pulse、Juniper、F5、Array、NC）
- ✅ 客户端证书认证（PEM 证书，可单独提供私钥）
- ✅ 缺失时自动安装 `openconnect` 及其路由脚本
- ✅ 隧道始终后台运行，不会阻塞工作流
- ✅ 快速失败的连接检查，并保留 `openconnect` 的真实输出便于定位
- ✅ 按 PID 精确断开，不会误伤共享 runner 上无关的 VPN 进程
- ✅ 隧道地址、PID、日志路径以 action 输出形式暴露

## 输入参数

| 参数 | 说明 | 必填 | 默认值 |
|------|------|------|--------|
| `server` | VPN 服务器地址（URL 或 IP） | 是 | - |
| `username` | VPN 用户名 | 是 | - |
| `password` | VPN 密码 | 是 | - |
| `group` | VPN 分组 / 认证组 | 否 | - |
| `protocol` | VPN 协议，见[协议支持](#协议支持) | 否 | `anyconnect` |
| `cert` | PEM 格式客户端证书（同时包含私钥，或另行提供 `cert_key`） | 否 | - |
| `cert_key` | PEM 格式私钥，当它未包含在 `cert` 中时使用 | 否 | - |

## 输出参数

在步骤上声明 `id` 后即可读取：

| 输出 | 说明 |
|------|------|
| `vpn_ip` | 隧道接口获得的 IPv4 地址（无法探测时为空） |
| `pid` | 后台 `openconnect` 进程的 PID |
| `log_file` | `openconnect` 日志路径，连接失败时非常有用 |

## 使用方法

### 基础用法

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

### 在容器 job 中使用

需要在 `container` 配置中放开隧道所需的网络权限：

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

Action 只在步骤并非以 root 运行时使用 `sudo`；若镜像中没有 `sudo`，则直接执行命令。

### 客户端证书认证

```yaml
- name: Connect with a client certificate
  uses: persiliao/openconnect-action@v2
  with:
    server: 'secure-vpn.example.com'
    username: 'service-account'
    password: ${{ secrets.VPN_SERVICE_PASSWORD }}
    cert: ${{ secrets.VPN_CLIENT_CERT }}      # PEM
    cert_key: ${{ secrets.VPN_CLIENT_KEY }}   # 可选，私钥未包含在 cert 中时提供
    protocol: 'pulse'
```

### 完整 CI/CD 工作流示例

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

### 断开连接

composite action 无法在调用方自己的步骤之后再执行代码，因此断开被设计为独立入口。请配合 `if: always()`，保证步骤失败时隧道依然被关闭：

```yaml
- name: Disconnect VPN
  if: always()
  uses: persiliao/openconnect-action/disconnect@v2
```

它只会终止本 action 启动的进程（通过 PID 文件追踪），并清理连接阶段写入的证书材料。

## 自动安装

无需预先安装 `openconnect`。Action 会检查二进制是否存在，缺失时按探测到的包管理器安装：

| 运行环境 / 系统 | 包管理器 | 使用的命令 |
|-----------------|----------|------------|
| Ubuntu / Debian（含容器） | `apt` | `apt-get install -y openconnect vpnc-scripts` |
| Alpine（容器） | `apk` | `apk add --no-cache openconnect vpnc-scripts` |
| Fedora / RHEL (dnf) | `dnf` | `dnf install -y openconnect vpnc-scripts` |
| Fedora / RHEL (yum) | `yum` | `yum install -y openconnect vpnc-scripts` |
| macOS（`macos-latest`） | `brew` | `brew install openconnect` |

说明：

- RHEL / CentOS 上 `openconnect` 位于 EPEL 源，请先安装 `epel-release`。
- Action 还会校验 `vpnc-script` 路由脚本是否存在，缺失时给出明确的错误提示。没有该脚本时 TLS 会话可以建立，但路由永远不会生效。
- 在不支持的系统上，Action 会直接报错，而不会猜测处理方式。

## 协议支持

| 取值 | VPN 产品 |
|------|----------|
| `anyconnect` | Cisco AnyConnect |
| `gp` | GlobalProtect |
| `pulse` | Pulse Connect Secure（需 openconnect >= 8.05） |
| `jnpr` | Juniper / Pulse Secure |
| `nc` | Juniper Network Connect |
| `f5` | F5 BIG-IP Edge Gateway |
| `fortinet` | FortiGate SSL VPN |
| `array` | Array Networks VPN |

当所选协议比已安装的 `openconnect` 更新时，Action 会在尝试连接前先输出一条警告标注。

## 平台支持

| 平台 | 支持情况 |
|------|----------|
| `ubuntu-*` 托管 runner | 完整支持 |
| Linux 容器 | 需 `--cap-add=NET_ADMIN --device=/dev/net/tun` |
| `macos-*` runner | 尽力而为：需要 root 与 utun 权限，托管 runner 默认不具备 |
| `windows-*` runner | 不支持（依赖 `pgrep`、`pkill`、`ip`） |

## 从 v1 迁移

- **移除 `background` 输入。** 该取值在实践中只有 `true` 可用：让隧道保持前台会永久阻塞当前步骤，后续步骤永远不会执行。现在隧道始终后台运行，删除该输入即可。
- **移除 `disconnect` 输入。** 原先连接与断开在同一次调用中紧邻执行，隧道在你自己的步骤开始前就已经断开。请在 job 结尾改用 `persiliao/openconnect-action/disconnect@v2`。
- **客户端证书改用 `--ssl-cert`**（PEM），与文档描述一致；旧版本 `openconnect` 自动回退到 `--certificate`。新增 `cert_key` 用于证书与私钥分开存放的场景。
- **请显式锁定版本。** 发布标签是可移动的指针，对供应链要求严格的工作流建议固定完整提交 SHA：`uses: persiliao/openconnect-action@<40 位 SHA>`。

## 安全最佳实践

1. **所有凭据使用 GitHub Secrets**；密码通过 stdin 传递，不会出现在进程命令行参数中。
2. **最小权限原则**：使用权限最小的 VPN 账号。
3. **务必断开**：在 job 结尾用 `if: always()` 调用 `disconnect@v2`。
4. **优先使用证书认证**，而不是密码认证。
5. **收敛工作流权限**：

```yaml
permissions:
  contents: read
```

## 故障排查

### 连接失败但看不出原因

Action 会保留 `openconnect` 的原始输出：连接失败时直接打印在日志中，同时写入 `log_file` 输出指向的文件。

### 创建隧道时出现 “Permission denied”

为容器补充设备权限：`options: --cap-add=NET_ADMIN --device=/dev/net/tun`

### 已连接但访问不通内网

这是路由脚本缺失的典型表现。Action 会检查 `vpnc-script` 并在缺失时拒绝运行，请安装 `vpnc-scripts` 包（RHEL/CentOS 需先启用 EPEL）。

### 长时间运行的 job 中隧道中断

Action 传入 `--reconnect-timeout=60`，`openconnect` 在放弃前会重连一分钟。链路不稳定时建议使用自托管 runner。

### 认证迟迟不结束

要求交互式二次认证的服务器无法在非交互 runner 上完成。前台阶段设有超时上限，步骤会快速失败而不是把整个 job 挂住。若 VPN 支持，请改用证书认证。

### 调试日志

`ACTIONS_STEP_DEBUG` 是仓库 **Secret**，不是工作流环境变量：请在 *Settings → Secrets and variables → Actions* 中添加，然后重新运行工作流。

## 本地开发

所有检查都在一次性容器中执行：

```bash
# 测试套件（容器内需要 root 或 sudo）
docker run --rm -v "$PWD:/work" -w /work ubuntu:22.04 bash tests/run_tests.sh

# Shell 静态检查
docker run --rm -v "$PWD:/code" -w /code koalaman/shellcheck:stable -x -s bash src/*.sh

# Action 元数据检查
docker run --rm -v "$PWD:/repo" rhysd/actionlint:latest
```

CI 会在每次 push 和 pull request 上执行同样的检查。

## 许可证

MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 参与贡献

欢迎提交 Issue 和 Pull Request。请为改动补充 `tests/run_tests.sh` 中的覆盖，并在同一次提交中同步两个版本的 README。
