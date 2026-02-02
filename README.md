# i2a - Debian to Arch Linux Reinstall Script

Automated script to reinstall a Debian system to Arch Linux with optional full disk encryption.

## Quick Start

```bash
# International users
bash <(wget -qO - 'https://raw.githubusercontent.com/tanbi-org/i2a/master/i2a.sh') --reflector --pwd yourpwd

# China users (50-100x faster)
bash <(wget -qO - 'https://raw.githubusercontent.com/tanbi-org/i2a/master/i2a.sh') --cn-mirror --pwd yourpwd

# With encryption
bash <(wget -qO - 'https://raw.githubusercontent.com/tanbi-org/i2a/master/i2a.sh') \
  --cn-mirror --pwd rootpass --encryption --luks-password cryptpass
```

## Features

- ✅ Direct installation (no intermediate Alpine stage)
- ✅ Compatible with systemd v255+ (no switch-root required)
- ✅ Full disk encryption (LVM on LUKS)
- ✅ Intelligent network detection (filters virtual interfaces)
- ✅ China mirror support (50-100x faster)
- ✅ UEFI and BIOS support
- ✅ Automatic system optimization
- ✅ Monitoring SSH on port 2222 during installation

## Options

```bash
--pwd PASSWORD          # Root password (required)
--cn-mirror            # Use China mirrors (recommended for CN users)
--encryption           # Enable full disk encryption
--luks-password PASS   # LUKS password (required if --encryption)
--lts                  # Use LTS kernel
--dhcp                 # Use DHCP
--reflector            # Auto-select fastest mirror
```

## Similar Projects

> Reference: [Arch Wiki - Install Arch Linux from existing Linux](https://wiki.archlinux.org/title/Install_Arch_Linux_from_existing_Linux)

There are multiple tools which automate the installation of Arch Linux from another Linux distribution:

- **[archstrap](https://github.com/hartwork/image-bootstrap)** (Bash) - Arch Linux bootstrap script
- **[vps2arch](https://gitlab.com/drizzt/vps2arch)** (Bash) - Convert VPS to Arch Linux (does not perform PGP signature verification)
- **[digitalocean-debian-to-arch](https://github.com/gh2o/digitalocean-debian-to-arch)** (Bash) - DigitalOcean specific with disk repartitioning (does not perform PGP signature verification)
- **[image-bootstrap](https://github.com/hartwork/image-bootstrap)** (Python) - Image bootstrap tool (does not perform PGP signature verification)

**i2a advantages**:
- ✅ Performs PGP signature verification (via pacman-key)
- ✅ Compatible with systemd v255+
- ✅ Full LUKS encryption support with LVM
- ✅ China mirror optimization (50-100x faster)
- ✅ Remote installation monitoring (SSH port 2222)

## Documentation

- [CLAUDE.md](CLAUDE.md) - Technical architecture and implementation details
- [Refactoring Guide](docs/REFACTORING.md) - Alpine→Direct installation refactoring details
- [Changelog](docs/CHANGELOG.md) - Version history

## Warning

⚠️ **This script will erase all data on the disk.** Use in VMs for testing first.

## License

BSD 3-Clause
