# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`i2a` is a Bash script that automates the reinstallation of a Debian system to Arch Linux. The script performs a direct system conversion by partitioning the disk, installing Arch Linux in a chroot environment, and then deleting the Debian system before rebooting.

## Architecture

### Two-Stage Installation Process

1. **Stage 1: Debian Environment** (i2a.sh main execution)
   - Detects system configuration (UEFI/BIOS, network, disk)
   - Installs required Debian tools (gdisk, cryptsetup, lvm2, btrfs-progs, zstd, arch-install-scripts)
   - Partitions disk with GPT (BIOS boot, EFI, root/LUKS partitions)
   - Formats partitions (vfat for EFI, btrfs or LVM on LUKS for root)
   - Downloads Arch Linux bootstrap tarball to /mnt
   - Configures network, pacman, and installs base system via arch-chroot
   - Configures encryption (if enabled): mkinitcpio hooks + GRUB cryptdevice
   - Installs and configures GRUB bootloader
   - Verifies installation completeness (9 checkpoints)
   - Starts monitoring SSH on port 2222
   - Deletes Debian system files (preserving /dev, /proc, /sys, /tmp, /mnt)
   - Reboots into Arch Linux

2. **Stage 2: Arch Linux System**
   - Fresh Arch Linux installation with configured services
   - Default credentials: root/i2a@@@ (or custom via `--pwd`)
   - SSH enabled with root login permitted

> **Note**: This is a refactored architecture. For details about the change from Alpine+switch-root to direct installation, see [docs/REFACTORING.md](docs/REFACTORING.md).

### Network Configuration

The script uses intelligent network detection:
- Filters virtual interfaces (docker*, veth*, br-*, virbr*, etc.)
- Checks carrier status for active links
- Prefers interface from default route
- Auto-detects IPv4/IPv6 addresses and gateways
- MAC address for interface matching

Can use DHCP (`--dhcp` flag) or static configuration based on detected settings.

Uses reliable IP detection endpoints:
- IPv4: ip.gs
- IPv6: api64.ipify.org

### Disk Partitioning Schemes

**Unencrypted (default):**
- 1MB BIOS boot partition (type ef02)
- 100MB EFI system partition (type ef00, vfat)
- Remaining space for root (type 8304, btrfs with zstd compression)

**Encrypted (--encryption):**
- 1MB BIOS boot partition (type ef02)
- 512MB EFI system partition (type ef00, vfat)
- Remaining space for LUKS container (type 8309)
  - LVM on LUKS: vg0 volume group
    - vg0-swap: RAM size (max 8GB)
    - vg0-root: Remaining space (btrfs with zstd)

Handles both standard disks (/dev/sda) and NVMe (/dev/nvme0n1p notation).

## Command Line Options

- `--pwd PASSWORD` - Set custom root password (default: i2a@@@)
- `--encryption` or `--luks` - Enable full disk encryption with LVM on LUKS
- `--luks-password PASSWORD` - Set LUKS encryption password (enables encryption)
- `--cn-mirror` - Use China mirrors (Tsinghua for Arch, 50-100x faster)
- `--lts` - Install linux-lts kernel instead of linux
- `--dhcp` - Use DHCP instead of static network configuration
- `--uefi` - Force UEFI boot mode (auto-detected by default)
- `--reflector` - Use reflector to find fastest mirrors
- `--mirror URL` - Set custom Arch Linux mirror

## Running the Script

**Direct execution** (international):
```bash
bash <(wget -qO - 'https://raw.githubusercontent.com/tanbi-org/i2a/master/i2a.sh') --reflector --pwd yourpwd
```

**China users** (50-100x faster):
```bash
bash <(wget -qO - 'https://raw.githubusercontent.com/tanbi-org/i2a/master/i2a.sh') --cn-mirror --pwd yourpwd
```

**Local execution with encryption**:
```bash
sudo bash i2a.sh --pwd rootpass --cn-mirror --encryption --luks-password cryptpass
```

Must be run as root on a Debian-based system with internet connectivity.

## Testing Considerations

This script performs destructive disk operations. Testing should be done in:
- Virtual machines (recommended)
- Disposable cloud instances
- Systems with full backups

Do not run on production systems without understanding the complete disk wipe implications.

## Important Functions

### Stage 1: Preparation
- `install_debian_dependencies()` - Installs required Debian packages and kernel modules
- `partition_and_format_disk()` - Creates GPT partitions and formats filesystems

### Stage 2: Arch Installation
- `download_arch_bootstrap()` - Downloads and extracts Arch bootstrap to /mnt
- `setup_chroot_environment()` - Mounts virtual filesystems and configures network
- `install_arch_base_system()` - Installs base packages via arch-chroot
- `configure_arch_system()` - Configures locale, services, SSH, system optimization
- `install_bootloader()` - Installs and configures GRUB for UEFI/BIOS
- `generate_fstab_crypttab()` - Generates fstab and crypttab files

### Stage 3: Cleanup and Reboot
- `verify_installation()` - Checks that all critical files exist before deletion
- `cleanup_chroot_and_unmount()` - Unmounts chroot filesystems
- `setup_monitoring_ssh()` - Starts Dropbear SSH on port 2222 for monitoring
- `delete_debian_system()` - Removes Debian system files
- `final_reboot()` - Syncs and reboots into Arch

## Important Variables

- `workdir='/mnt'` - Mount point for Arch installation
- `password='i2a@@@'` - Default root password
- `encryption=false` - Full disk encryption flag
- `luks_password` - LUKS encryption password
- `cn_mirror=false` - China mirrors flag
- `mirror` - Arch mirror URL (changes with cn_mirror)
- `disk` - Auto-detected from current boot device
- `uefi` - Auto-detected UEFI vs BIOS mode
- `machine` - Architecture detection (x86_64/arm64)
- Network variables: `interface`, `ip4_addr`, `ip4_gw`, `ip6_addr`, `ip6_gw`

## Security Notes

- SSH root login is explicitly enabled with password authentication
- Default password should always be changed via `--pwd` flag
- Full disk encryption available via `--encryption` flag:
  - LUKS2 with AES-XTS-PLAIN64 cipher
  - 512-bit key size (256-bit security)
  - PBKDF2 with 200,000 iterations
- The script includes system optimization settings in base64-encoded blocks
- Dropbear SSH runs on port 2222 during deletion phase for remote monitoring

## Encryption Architecture

When `--encryption` is used:
- LUKS2 container on partition 3
- LVM on LUKS: vg0 volume group
  - Automatic swap sizing (RAM size, max 8GB)
  - Root volume uses remaining space
- mkinitcpio configured with `encrypt` and `lvm2` hooks
- GRUB passes `cryptdevice=UUID=...` kernel parameter
- Boot requires LUKS password entry

## China Mirror Optimization

When `--cn-mirror` is used:
- Arch: Uses Tsinghua mirror (mirrors.tuna.tsinghua.edu.cn)
- Speed improvement: 50-100x faster for China users
- Alternative mirrors: USTC, Aliyun, Huawei Cloud available via `--mirror`

## Verification and Safety

The script includes multiple verification points:

1. **Dependency verification** - Checks all required tools are installed
2. **Partition verification** - Waits for udev and checks block devices exist
3. **LUKS verification** - Checks cryptlvm device exists after opening
4. **Mount verification** - Checks /mnt is mounted
5. **Bootstrap verification** - Checks pacman exists in extracted bootstrap
6. **Package verification** - Checks critical packages installed
7. **GRUB verification** - Checks grub.cfg exists and contains kernel entries
8. **fstab verification** - Checks EFI entry exists
9. **Full installation verification** - Checks all critical files before deletion

These verification points ensure the system is not damaged if installation fails.

## Monitoring During Installation

A Dropbear SSH server starts on port 2222 after Arch installation completes, allowing remote monitoring during the Debian deletion phase. This provides visibility into the final stages of installation, which is particularly useful for remote installations.

Login: root / [your --pwd password]
