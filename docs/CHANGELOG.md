# i2a.sh Changelog

## [Unreleased] - 2026-02-02

### Added

#### Encryption Features

- Full disk encryption support via `--encryption` or `--luks` flags
- LUKS2 container with strong encryption (AES-XTS-PLAIN64, 512-bit key, SHA256 hash)
- LVM on LUKS for flexible volume management
- Automatic swap sizing (RAM size, capped at 8GB)
- LUKS password parameter via `--luks-password` flag
- mkinitcpio configuration with `encrypt` and `lvm2` hooks
- GRUB configuration with `cryptdevice=UUID=...` kernel parameter
- /etc/crypttab generation for encrypted systems
- Enhanced EFI partition (512MB) for encrypted installations

#### Network Detection Improvements

- `detect_physical_interface()` function for intelligent interface detection
- Filters virtual interfaces (docker*, veth*, br-_, virbr_, vlan*, tun*, tap*, dummy*, kube\*)
- Checks carrier status to ensure link is active
- Prefers interface from default route
- Falls back to first candidate with IPv4 address
- `validate_network_config()` function to verify interface validity

#### Input Validation

- `validate_inputs()` function for comprehensive validation
- Password length check (minimum 6 characters)
- LUKS password length check (minimum 8 characters)
- Architecture support verification
- Disk block device verification
- Network connectivity pre-check to archlinux.org
- Encryption password requirement validation

#### Error Handling

- Enhanced emergency shell with clear instructions
- Log file location hints in error messages
- Force reboot command documentation
- Validation before destructive operations

#### Documentation

- IMPLEMENTATION_SUMMARY.md with complete change documentation
- TESTING_GUIDE.md with comprehensive test cases
- Updated usage examples in print_info()

### Changed

#### Network Configuration

- IPv4 detection endpoint: `https://ip.gs` (was: ipv4-api.speedtest.net/getip)
- IPv6 detection endpoint: `https://api64.ipify.org` (was: ipv6-api.speedtest.net/getip)
- Network interface detection now uses robust filtering logic
- Interface selection considers virtual interfaces and link status

#### Package Management

- Added `lvm2` and `cryptsetup` to base_packages
- Added `cryptsetup`, `lvm2`, and `device-mapper` to Alpine dependencies

#### Disk Setup

- Conditional disk setup based on encryption flag
- Encrypted path: 1MB BIOS + 512MB EFI + remaining LUKS
- Unencrypted path: 1MB BIOS + 100MB EFI + remaining Arch (unchanged)
- Smart disk variable handling for both /dev/sda and /dev/nvme\* devices

#### Boot Configuration

- Dual GRUB configuration (encrypted vs unencrypted)
- Conditional fstab/crypttab generation
- Enhanced unmount sequence for LVM/LUKS cleanup

#### User Interface

- Updated example usage in print_info()
- Added encryption status to info display
- Enhanced confirmation prompt with validation

### Fixed

- Virtual interface filtering prevents incorrect network detection on Docker hosts
- Robust interface detection handles multi-NIC systems correctly
- Password validation prevents common input errors
- NVMe disk partition naming handled correctly in both encryption modes

### Security

- LUKS2 with industry-standard encryption parameters
- PBKDF2 with 200,000 iterations for key derivation
- Mandatory password length enforcement
- Secure boot support maintained for both BIOS and UEFI

### Compatibility

- 100% backward compatible - encryption is opt-in
- All existing flags work with new encryption flags
- No breaking changes to default (unencrypted) behavior
- Supports both BIOS and UEFI boot modes
- Works with standard disks (/dev/sda) and NVMe devices (/dev/nvme\*)

### Technical Details

#### Partition Layouts

**Unencrypted (Default):**

```
/dev/sda1    1MB       ef02    BIOS boot partition
/dev/sda2    100MB     ef00    EFI system partition
/dev/sda3    remaining 8304    Arch Linux root (btrfs+zstd)
```

**Encrypted (New):**

```
/dev/sda1    1MB       ef02    BIOS boot partition
/dev/sda2    512MB     ef00    EFI system partition
/dev/sda3    remaining 8309    Linux LUKS
  └─cryptlvm                   LUKS2 container
    └─vg0                      LVM volume group
      ├─vg0-swap  <RAM>        Linux swap (max 8GB)
      └─vg0-root  100%FREE     Arch root (btrfs+zstd)
```

#### Code Metrics

- Total lines: 545 (was 371)
- Lines added: ~173
- New functions: 3
- New variables: 2
- New CLI flags: 2

### Usage Examples

**Unencrypted (Existing):**

```bash
bash i2a.sh --pwd mypassword --reflector
```

**Encrypted (New):**

```bash
bash i2a.sh --pwd rootpass --encryption --luks-password cryptpass --reflector
```

**Encrypted with LTS:**

```bash
bash i2a.sh --pwd root123 --lts --encryption --luks-password luks456
```

**One-liner with encryption:**

```bash
bash <(wget -qO - 'https://raw.githubusercontent.com/tanbi-org/i2a/master/i2a.sh') \
  --reflector --pwd mypwd --encryption --luks-password myluks
```

---

## [Previous Versions]

### Original Version

- Debian to Arch Linux conversion
- Three-stage installation (Debian → Alpine → Arch)
- UEFI and BIOS support
- Network configuration (static or DHCP)
- LTS kernel option
- Mirror selection and reflector support
- System optimization and hardening
- SSH root login configuration
- Dropbear SSH in Alpine stage

---

## Migration Notes

### Upgrading from Previous Version

No migration needed - this update is fully backward compatible:

1. **Default behavior unchanged:** Without `--encryption`, script works exactly as before
2. **New optional flags:** `--encryption` and `--luks-password` are opt-in
3. **Network detection improved:** Automatically handles virtual interfaces
4. **Input validation added:** Catches errors before destructive operations

### Testing Recommendations

Before deploying to production:

1. Test unencrypted installation in VM (verify no regression)
2. Test encrypted installation in VM (verify new features)
3. Test on systems with Docker installed (verify interface filtering)
4. Test with both BIOS and UEFI boot modes

---

## Known Issues / Limitations

1. **Password at Boot:** Encrypted systems require password entry on every boot (by design)
2. **No Migration Path:** Cannot convert existing unencrypted installation to encrypted
3. **Single LUKS Password:** No backup unlock methods (could be enhanced)
4. **RAM Requirement:** System needs adequate RAM for Alpine rootfs + Arch bootstrap

---

## Future Enhancements (Potential)

- [ ] Keyfile support for LUKS unlock
- [ ] TPM2 integration for automatic unlock
- [ ] Multiple LUKS password slots
- [ ] Custom LVM layout configuration
- [ ] Encryption progress indicators
- [ ] ZFS with native encryption as alternative
- [ ] Automated recovery key generation
- [ ] Support for detached LUKS headers

---

## Credits

**Original Script:** https://github.com/tanbi-org/i2a
**Enhancements:** Claude Code (Anthropic) - February 2, 2026
**License:** BSD 3-Clause

---

## Notes

This changelog follows the [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format.
Version numbers follow [Semantic Versioning](https://semver.org/).
