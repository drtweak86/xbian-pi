
# osmc-oneclick (XBian Edition — cron-based)

This bundle is tailored for **XBian**:
- Keeps the project name/paths as **/opt/osmc-oneclick**
- Replaces `systemd` with **cron** for all periodic/boot-time tasks
- Uses XBian specifics: `service xbmc` and `/home/xbian/.kodi`

## Quick install (as `xbian` user)
```bash
git clone https://github.com/yourfork/osmc-oneclick.git ~/osmc-oneclick
cd ~/osmc-oneclick
bash install_xbian.sh
```

### What it does
- Copies `phases/` + `assets/` to `/opt/osmc-oneclick`
- Creates `/boot/firstboot.sh` and a boot hook `/etc/boot.d/99-oneclick` (XBian) so phases run once after reboot
- Installs **cron jobs** from `cron/osmc-oneclick`:
  - Wi‑Fi autoswitch: every 2 min
  - WG autoswitch: every 5 min
  - Daily backup: 03:10
  - Weekly maintenance: Sunday 04:00
- Installs a tiny **if-speedtest** helper
- (Optional) Installs **Argon One** service if Pi 4 and Argon case present

> Tip: If you don’t want to reboot, you can run `/boot/firstboot.sh` manually once.
