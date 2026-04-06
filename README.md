<img width="1902" height="986" alt="image" src="https://github.com/user-attachments/assets/cda53b3e-ffb1-457a-9793-e4afa475a92f" />

# MTProxy Manager
Built as a quick personal utility to simplify MTProxy deployment and maintenance.

## Quick Install
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/mtproxy-manager/main/mtproxy-manager.sh)
```

## Requirements
- Debian / Ubuntu
- root access
- open port (default and recommended 443)

## Menu Options
- Install proxy
- Remove proxy
- Start/Restart proxy
- Update proxy
- Change secret
- Change TLS domain
- Show active users

## File Locations
- `/opt/MTProxy`
- `/etc/mtproxy-manager/config`
- `/etc/mtproxy-manager/secret`
- `/etc/systemd/system/mtproxy.service`

## Notes
- Uses iptables for port opening
- Installs MTProxy from official source
- Stores config in /etc/mtproxy-manager
