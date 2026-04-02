# fix-suspend

Fix suspend, hibernate, and resume on the **Dell Precision 3551** running Ubuntu 24.04 LTS.

Out of the box, this laptop uses s2idle (modern standby) which drains the battery, wakes immediately from USB/ethernet interrupts, and has a firmware-level ACPI interrupt storm on GPE6E. This script fixes all of it.

## What it does

| Problem | Fix |
|---|---|
| s2idle drains battery while suspended | Switches to deep S3 sleep via kernel parameter |
| Laptop wakes immediately after suspend | Disables spurious wake sources (XHC, GLAN, PCI bridges) |
| Battery dies if left suspended | Lid close triggers suspend-then-hibernate (hibernates after 60 min) |
| Hibernate resume doesn't work | Configures GRUB `resume=` / `resume_offset=` for swap file + initramfs |
| GPE6E interrupt storm (~15k/min) | Detects and disables runaway ACPI GPEs on boot |
| Touchpad cursor jitters and zooms off | Udev hwdb fuzz + libinput size hint for correct acceleration |
| Nvidia GPU glitches on resume | Ensures VRAM preservation and nvidia suspend/resume services |
| Missing hardware support | Installs the Ubuntu HWE kernel |

## Usage

```bash
sudo bash fix-suspend.sh
```

Then reboot.

## What it changes

- `/etc/default/grub` — adds `mem_sleep_default=deep`, `resume=`, `resume_offset=`
- `/etc/initramfs-tools/conf.d/resume` — sets `RESUME=none` (kernel params handle swap file)
- `/etc/systemd/sleep.conf.d/99-fix-suspend.conf` — enables suspend-then-hibernate
- `/etc/systemd/logind.conf.d/99-fix-suspend.conf` — lid/power button behavior
- `/etc/systemd/system/fix-suspend-wakeup.service` — disables wake sources and GPE storms on boot
- `/etc/udev/hwdb.d/99-touchpad-fuzz.hwdb` — ALPS touchpad axis fuzz to filter jitter
- `/etc/libinput/local-overrides.quirks` — ALPS touchpad size hint for correct acceleration
- Enables `nvidia-suspend`, `nvidia-hibernate`, `nvidia-resume` systemd services
- Rebuilds GRUB and initramfs

A timestamped backup of `/etc/default/grub` is created before any changes.

## Hardware

- **Model:** Dell Precision 3551
- **CPU:** Intel 10th Gen CometLake-H
- **GPU:** Intel UHD + Nvidia Quadro P620
- **OS:** Ubuntu 24.04 LTS (Noble Numbat)
- **Kernel:** HWE (6.17+)

May also work on other Dell laptops from the same era (Precision 3541, Latitude 5510/5511, etc.) that share the same Intel CometLake platform and ACPI firmware.

## Reverting

To undo everything:

```bash
# Restore GRUB (find your backup)
sudo cp /etc/default/grub.bak.TIMESTAMP /etc/default/grub
sudo update-grub

# Remove configs
sudo rm /etc/systemd/sleep.conf.d/99-fix-suspend.conf
sudo rm /etc/systemd/logind.conf.d/99-fix-suspend.conf
sudo rm /etc/initramfs-tools/conf.d/resume

# Disable the wakeup service
sudo systemctl disable --now fix-suspend-wakeup.service
sudo rm /etc/systemd/system/fix-suspend-wakeup.service
sudo systemctl daemon-reload

# Rebuild initramfs and reboot
sudo update-initramfs -u -k all
sudo reboot
```
