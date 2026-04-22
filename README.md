<img width="1902" height="986" alt="image" src="https://github.com/user-attachments/assets/cda53b3e-ffb1-457a-9793-e4afa475a92f" />

# MTProxy Manager

Interactive Bash manager for installing and managing Telegram MTProxy on **Ubuntu 22.04 / 24.04** servers.

Built as a practical utility to simplify MTProxy deployment, updates, and routine maintenance with a small interactive menu.

## Features

- Install MTProxy from the official Telegram source
- Start, restart, and stop the proxy
- Update proxy binaries and Telegram config files
- Change MTProxy secret
- Change FakeTLS domain
- Show active client IPs
- View recent service logs
- Create and manage a systemd service
- Open the client port with iptables and persist the rule

## Supported Systems

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- root access
- iptables-based firewall management

## Quick Install

### Stable
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/mtproxy-manager/v1.1/mtproxy-manager.sh)
```

### Latest (main)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/mtproxy-manager/main/mtproxy-manager.sh)
```

### Pre-release / Beta
Use only for testing.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/mtproxy-manager/v1.2.0-beta.2/mtproxy-manager.sh)
```
