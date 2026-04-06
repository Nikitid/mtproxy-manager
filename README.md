<img width="1053" height="421" alt="image" src="https://github.com/user-attachments/assets/b3a2bd18-ef9e-4264-9a45-03dba2cd201c" />

# MTProxy Manager
Built as a quick, personal tool to simplify MTProxy deployment and management.

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/mtproxy-manager/main/mtproxy-manager.sh)
```

## Requirements
- Debian / Ubuntu
- root access
- open port (default and recommended 443)

## Notes
- Uses iptables for port opening
- Installs MTProxy from official source
- Stores config in /etc/mtproxy-manager
