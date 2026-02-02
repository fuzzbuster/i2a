#!/bin/bash

## License: BSD 3
## It can reinstall vm to archlinux.
## New archlinux root password: i2a@@@
## Written By https://github.com/tanbi-org

set -Eeuo pipefail
set +h

workdir='/mnt'
password='i2a@@@'

case $(uname -m) in aarch64|arm64) machine="arm64";;x86_64|amd64) machine="x86_64";; *) machine="";; esac

kernel='linux'
mirror='https://mirrors.kernel.org/archlinux'
reflector=false
cn_mirror=false
base_packages='grub openssh sudo irqbalance haveged btrfs-progs lvm2 cryptsetup'
extra_packages='wget curl vim bash-completion screen'
encryption=false
luks_password=''

uefi=$([ -d /sys/firmware/efi ] && echo true || echo false)
disk="/dev/$(lsblk -no PKNAME "$(df /boot | grep -Eo '/dev/[a-z0-9]+')")"

dhcp=false
realv4=$(curl --connect-timeout 3 -Ls https://ip.gs)
realv6=$(curl --connect-timeout 3 -Ls https://api64.ipify.org)
nameserver="nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 2606:4700:4700::1111"


function log() {
  local _on=$'\e[0;32m'
  local _off=$'\e[0m'
    local _date=$(date +"%Y-%m-%d %H:%M:%S")
  echo "${_on}[${_date}]${_off} $@" >&2;
}

function fatal() {
  log "$@";log "Exiting."
  exit 1
}

function detect_physical_interface() {
  # Filter virtual interfaces and find active physical interface
  local virtual_patterns='lo|docker|veth|br-|virbr|vlan|tun|tap|dummy|kube'
  local candidate_interfaces=()

  for iface in /sys/class/net/*; do
    local iface_name=$(basename "$iface")
    if ! echo "$iface_name" | grep -qE "^($virtual_patterns)"; then
      if [ -f "/sys/class/net/$iface_name/carrier" ]; then
        local carrier=$(cat "/sys/class/net/$iface_name/carrier" 2>/dev/null || echo "0")
        if [ "$carrier" = "1" ]; then
          candidate_interfaces+=("$iface_name")
        fi
      fi
    fi
  done

  # Prefer interface from default route
  local default_iface=$(ip route show default | awk '/default/{print $5; exit}')
  if [ -n "$default_iface" ]; then
    for iface in "${candidate_interfaces[@]}"; do
      if [ "$iface" = "$default_iface" ]; then
        echo "$default_iface"
        return 0
      fi
    done
  fi

  # Fallback to first candidate with IP
  for iface in "${candidate_interfaces[@]}"; do
    if ip -4 addr show dev "$iface" | grep -q "inet "; then
      echo "$iface"
      return 0
    fi
  done

  if [ ${#candidate_interfaces[@]} -gt 0 ]; then
    echo "${candidate_interfaces[0]}"
    return 0
  fi

  return 1
}

function validate_network_config() {
  local iface=$1
  [ -d "/sys/class/net/$iface" ] || fatal "Interface $iface does not exist"
  ip -4 addr show dev "$iface" | grep -q "inet " || fatal "Interface $iface has no IPv4 address"
  return 0
}

function validate_inputs() {
  [ ${#password} -lt 6 ] && fatal "Password must be at least 6 characters"

  if [ "$encryption" = "true" ]; then
    [ ${#luks_password} -lt 8 ] && fatal "LUKS password must be at least 8 characters"
  fi

  [ -z "$machine" ] && fatal "Unsupported architecture: $(uname -m)"
  [ ! -b "$disk" ] && fatal "Disk $disk is not a block device"

  # Check connectivity to the mirror we'll actually use
  local test_url="${mirror}"
  curl --connect-timeout 5 -Ls "${test_url}" > /dev/null 2>&1 || \
    log "Warning: Cannot reach ${test_url} - installation may be slow or fail"
}

# Detect and validate network interface
interface=$(detect_physical_interface) || fatal "Failed to detect active network interface"
validate_network_config "$interface"
ip_mac=$(ip link show "${interface}" | awk '/link\/ether/{print $2}')
ip4_addr=$(ip -o -4 addr show dev "${interface}" | awk '{print $4}' | head -n 1)
ip4_gw=$(ip route show dev "${interface}" | awk '/default/{print $3}' | head -n 1)
ip6_addr=$(ip -o -6 addr show dev "${interface}" | awk '{print $4}' | head -n 1)
ip6_gw=$(ip -6 route show dev "${interface}" | awk '/default/{print $3}' | head -n 1)


function install_debian_dependencies() {
  log "[*] Installing required Debian tools..."
  apt update
  apt install -y gdisk btrfs-progs cryptsetup lvm2 zstd arch-install-scripts wget curl dosfstools dropbear-bin
  modprobe btrfs dm-crypt

  # Verify critical tools
  for tool in sgdisk cryptsetup pvcreate zstd wget arch-chroot genfstab; do
    command -v $tool >/dev/null 2>&1 || fatal "Missing tool: $tool"
  done

  log "[*] All dependencies installed successfully"
}

function partition_and_format_disk() {
  log "[*] Partitioning disk: ${disk}..."

  if [ "$encryption" = "true" ]; then
    log "[*] Setting up encrypted disk with LVM..."
    sgdisk -g --align-end --clear \
      --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
      --new 0:0:+512M --typecode=0:ef00 --change-name=0:'EFI system partition' \
      --new 0:0:0 --typecode=0:8309 --change-name=0:'Linux LUKS' \
      ${disk}

    [[ $disk == /dev/nvme* ]] && disk="${disk}p"

    mkfs.vfat -F 32 ${disk}2

    log "[*] Creating LUKS container..."
    echo -n "${luks_password}" | cryptsetup luksFormat --type luks2 \
      --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
      --pbkdf pbkdf2 --pbkdf-force-iterations 200000 --batch-mode ${disk}3 -

    echo -n "${luks_password}" | cryptsetup open ${disk}3 cryptlvm -

    log "[*] Setting up LVM..."
    pvcreate /dev/mapper/cryptlvm
    vgcreate vg0 /dev/mapper/cryptlvm

    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    swap_mb=$((ram_mb > 8192 ? 8192 : ram_mb))

    lvcreate -L ${swap_mb}M vg0 -n swap
    lvcreate -l 100%FREE vg0 -n root

    mkswap /dev/vg0/swap
    mkfs.btrfs -f -L ArchRoot /dev/vg0/root
    udevadm settle

    mount /dev/vg0/root -o compress=zstd,autodefrag,noatime ${workdir}
    swapon /dev/vg0/swap
    mkdir -p ${workdir}/boot/efi
    mount ${disk}2 ${workdir}/boot/efi

    LUKS_UUID=$(blkid -s UUID -o value ${disk}3)
    log "[*] LUKS UUID: ${LUKS_UUID}"
  else
    log "[*] Setting up unencrypted disk..."
    sgdisk -g --align-end --clear \
      --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
      --new 0:0:+100M --typecode=0:ef00 --change-name=0:'EFI system partition' \
      --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
      ${disk}

    [[ $disk == /dev/nvme* ]] && disk="${disk}p"

    mkfs.vfat -F 32 ${disk}2
    mkfs.btrfs -f -L ArchRoot ${disk}3
    udevadm settle

    mount ${disk}3 -o compress=zstd,autodefrag,noatime ${workdir}
    mkdir -p ${workdir}/boot/efi
    mount ${disk}2 ${workdir}/boot/efi
  fi

  log "[*] Disk partitioning and formatting complete"
}

function download_arch_bootstrap() {
  log "[*] Downloading Arch Linux bootstrap..."
  wget -q --show-progress -O - "${mirror}/iso/latest/archlinux-bootstrap-${machine}.tar.zst" | \
    zstd -d | tar -xf - --directory=${workdir} --strip-components=1

  [ -f ${workdir}/usr/bin/pacman ] || fatal "Arch bootstrap extraction failed"
  log "[*] Bootstrap downloaded and extracted successfully"
}

function setup_chroot_environment() {
  log "[*] Setting up chroot environment..."

  mount -t proc proc ${workdir}/proc
  mount -t sysfs sys ${workdir}/sys
  mount -t devtmpfs dev ${workdir}/dev
  mkdir -p ${workdir}/dev/pts
  mount -t devpts pts ${workdir}/dev/pts

  cp /etc/resolv.conf ${workdir}/etc/resolv.conf

  # Configure network
  if [ "$dhcp" = "true" ]; then
    cat > ${workdir}/etc/systemd/network/default.network <<EONET
[Match]
Name=en* eth*
[Network]
DHCP=yes
[DHCP]
UseMTU=yes
UseDNS=yes
UseDomains=yes
EONET
  else
    cat > ${workdir}/etc/systemd/network/default.network <<EONET
[Match]
Name=en* eth*
[Network]
Address=${ip4_addr}
Gateway=${ip4_gw}
DNS=1.1.1.1
[Route]
Gateway=${ip4_gw}
GatewayOnLink=yes
[Match]
Name=en* eth*
[Network]
IPv6AcceptRA=0
Address=${ip6_addr}
DNS=2606:4700:4700::1111
[Route]
Gateway=${ip6_gw}
GatewayOnLink=yes
EONET
  fi

  log "[*] Chroot environment ready"
}

function install_arch_base_system() {
  log "[*] Installing Arch Linux base system..."

  # Configure pacman
  sed -i 's|#Color|Color|' ${workdir}/etc/pacman.conf
  sed -i 's|#ParallelDownloads|ParallelDownloads|' ${workdir}/etc/pacman.conf
  echo 'Server = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch' >> ${workdir}/etc/pacman.d/mirrorlist
  echo "Server = ${mirror}/\$repo/os/\$arch" >> ${workdir}/etc/pacman.d/mirrorlist

  # Initialize pacman
  arch-chroot ${workdir} pacman-key --init
  arch-chroot ${workdir} pacman-key --populate archlinux
  arch-chroot ${workdir} pacman --disable-sandbox -Sy
  arch-chroot ${workdir} pacman --disable-sandbox --needed --noconfirm -Su archlinux-keyring
  arch-chroot ${workdir} pacman --disable-sandbox --needed --noconfirm -Su $kernel $base_packages $extra_packages

  if [ "$reflector" = "true" ]; then
    log "[*] Optimizing mirrors with reflector..."
    arch-chroot ${workdir} pacman --disable-sandbox -S --noconfirm reflector
    arch-chroot ${workdir} reflector -l 30 -p https --sort rate --save /etc/pacman.d/mirrorlist
  fi

  arch-chroot ${workdir} pacman -Q linux grub openssh >/dev/null 2>&1 || fatal "Base packages installation failed"
  log "[*] Base system installed successfully"
}

function configure_arch_system() {
  log "[*] Configuring Arch Linux system..."

  # Locale & Timezone
  sed -i 's/^#en_US/en_US/' ${workdir}/etc/locale.gen
  echo 'LANG=en_US.utf8' > ${workdir}/etc/locale.conf
  arch-chroot ${workdir} locale-gen
  arch-chroot ${workdir} ln -sf /usr/share/zoneinfo/UTC /etc/localtime

  # Enable services
  arch-chroot ${workdir} ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
  arch-chroot ${workdir} systemctl enable systemd-timesyncd.service
  arch-chroot ${workdir} systemctl enable haveged.service
  arch-chroot ${workdir} systemctl enable irqbalance.service
  arch-chroot ${workdir} systemctl enable systemd-networkd.service
  arch-chroot ${workdir} systemctl enable systemd-resolved.service
  arch-chroot ${workdir} systemctl enable sshd.service

  # Set root password
  echo "root:${password}" | arch-chroot ${workdir} chpasswd
  arch-chroot ${workdir} ssh-keygen -t ed25519 -f /etc/ssh/ed25519_key -N ""
  arch-chroot ${workdir} ssh-keygen -t rsa -b 4096 -f /etc/ssh/rsa_key -N ""

  # SSH configuration
  arch-chroot ${workdir} /bin/bash -c "echo 'IyEvYmluL2Jhc2gKCmNhdCA+IC9ldGMvc3NoL3NzaGRfY29uZmlnIDw8ICJFT0YiCkluY2x1ZGUgL2V0Yy9zc2gvc3NoZF9jb25maWcuZC8qLmNvbmYKUG9ydCAgMjIKUGVybWl0Um9vdExvZ2luIHllcwpQYXNzd29yZEF1dGhlbnRpY2F0aW9uIHllcwpQdWJrZXlBdXRoZW50aWNhdGlvbiB5ZXMKQ2hhbGxlbmdlUmVzcG9uc2VBdXRoZW50aWNhdGlvbiBubwpLYmRJbnRlcmFjdGl2ZUF1dGhlbnRpY2F0aW9uIG5vCkF1dGhvcml6ZWRLZXlzRmlsZSAgL3Jvb3QvLnNzaC9hdXRob3JpemVkX2tleXMKU3Vic3lzdGVtICAgICBzZnRwICAgIC91c3IvbGliL3NzaC9zZnRwLXNlcnZlcgpYMTFGb3J3YXJkaW5nIG5vCkFsbG93VXNlcnMgcm9vdApQcmludE1vdGQgbm8KQWNjZXB0RW52IExBTkcgTENfKgpFT0YK' | base64 -d | bash"

  # Encryption configuration
  if [ "$encryption" = "true" ]; then
    log "[*] Configuring initramfs for encryption..."
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)/' ${workdir}/etc/mkinitcpio.conf
    arch-chroot ${workdir} mkinitcpio -P
  fi

  # System optimization
  arch-chroot ${workdir} /bin/bash -c "echo 'IyEvYmluL2Jhc2gKY2F0ID4gL3Jvb3QvLnByb2ZpbGUgPDxFT0YKZXhwb3J0IFBTMT0nXFtcZVswOzMybVxdXHVAXGggXFtcZVswOzM0bVxdXHdcW1xlWzA7MzZtXF1cblwkIFxbXGVbMG1cXScKYWxpYXMgZ2V0aXA9J2N1cmwgLS1jb25uZWN0LXRpbWVvdXQgMyAtTHMgaHR0cHM6Ly9pcHY0LWFwaS5zcGVlZHRlc3QubmV0L2dldGlwJwphbGlhcyBnZXRpcDY9J2N1cmwgLS1jb25uZWN0LXRpbWVvdXQgMyAtTHMgaHR0cHM6Ly9pcHY2LWFwaS5zcGVlZHRlc3QubmV0L2dldGlwJwphbGlhcyBuZXRjaGVjaz0ncGluZyAxLjEuMS4xJwphbGlhcyBscz0nbHMgLS1jb2xvcj1hdXRvJwphbGlhcyBncmVwPSdncmVwIC0tY29sb3I9YXV0bycgCmFsaWFzIGZncmVwPSdmZ3JlcCAtLWNvbG9yPWF1dG8nCmFsaWFzIGVncmVwPSdlZ3JlcCAtLWNvbG9yPWF1dG8nCmFsaWFzIHJtPSdybSAtaScKYWxpYXMgY3A9J2NwIC1pJwphbGlhcyBtdj0nbXYgLWknCmFsaWFzIGxsPSdscyAtbGgnCmFsaWFzIGxhPSdscyAtbEFoJwphbGlhcyAuLj0nY2QgLi4vJwphbGlhcyAuLi49J2NkIC4uLy4uLycKYWxpYXMgcGc9J3BzIGF1eCB8Z3JlcCAtaScKYWxpYXMgaGc9J2hpc3RvcnkgfGdyZXAgLWknCmFsaWFzIGxnPSdscyAtQSB8Z3JlcCAtaScKYWxpYXMgZGY9J2RmIC1UaCcKYWxpYXMgZnJlZT0nZnJlZSAtaCcKZXhwb3J0IEhJU1RUSU1FRk9STUFUPSIlRiAlVCBcYHdob2FtaVxgICIKZXhwb3J0IExBTkc9ZW5fVVMuVVRGLTgKZXhwb3J0IEVESVRPUj0idmltIgpleHBvcnQgUEFUSD0kUEFUSDouCkVPRgoKY2F0ID4gL3Jvb3QvLnZpbXJjIDw8RU9GCnN5bnRheCBvbgpzZXQgdHM9MgpzZXQgbm9iYWNrdXAKc2V0IGV4cGFuZHRhYgpFT0YKClsgLWYgL2V0Yy9zZWN1cml0eS9saW1pdHMuY29uZiBdICYmIExJTUlUPScxMDQ4NTc2JyAmJiBzZWQgLWkgJy9eXChcKlx8cm9vdFwpW1s6c3BhY2U6XV0qXChoYXJkXHxzb2Z0XClbWzpzcGFjZTpdXSpcKG5vZmlsZVx8bWVtbG9ja1wpL2QnIC9ldGMvc2VjdXJpdHkvbGltaXRzLmNvbmYgJiYgZWNobyAtbmUgIipcdGhhcmRcdG1lbWxvY2tcdCR7TElNSVR9XG4qXHRzb2Z0XHRtZW1sb2NrXHQke0xJTUlUfVxucm9vdFx0aGFyZFx0bWVtbG9ja1x0JHtMSU1JVH1cbnJvb3RcdHNvZnRcdG1lbWxvY2tcdCR7TElNSVR9XG4qXHRoYXJkXHRub2ZpbGVcdCR7TElNSVR9XG4qXHRzb2Z0XHRub2ZpbGVcdCR7TElNSVR9XG5yb290XHRoYXJkXHRub2ZpbGVcdCR7TElNSVR9XG5yb290XHRzb2Z0XHRub2ZpbGVcdCR7TElNSVR9XG5cbiIgPj4vZXRjL3NlY3VyaXR5L2xpbWl0cy5jb25mOwoKWyAtZiAvZXRjL3N5c3RlbWQvc3lzdGVtLmNvbmYgXSAmJiBzZWQgLWkgJ3MvI1w/RGVmYXVsdExpbWl0Tk9GSUxFPS4qL0RlZmF1bHRMaW1pdE5PRklMRT0xMDQ4NTc2LycgL2V0Yy9zeXN0ZW1kL3N5c3RlbS5jb25mOwoKY2F0ID4gL2V0Yy9zeXN0ZW1kL2pvdXJuYWxkLmNvbmYgIDw8IkVPRiIKW0pvdXJuYWxdClN0b3JhZ2U9YXV0bwpDb21wcmVzcz15ZXMKRm9yd2FyZFRvU3lzbG9nPW5vClN5c3RlbU1heFVzZT04TQpSdW50aW1lTWF4VXNlPThNClJhdGVMaW1pdEludGVydmFsU2VjPTMwcwpSYXRlTGltaXRCdXJzdD0xMDAKRU9GCgpjYXQgPiAvZXRjL3N5c2N0bC5kLzk5LXN5c2N0bC5jb25mICA8PCJFT0YiCnZtLnN3YXBwaW5lc3MgPSAwCm5ldC5pcHY0LnRjcF9ub3RzZW50X2xvd2F0ID0gMTMxMDcyCm5ldC5jb3JlLnJtZW1fbWF4ID0gNTM2ODcwOTEyCm5ldC5jb3JlLndtZW1fbWF4ID0gNTM2ODcwOTEyCm5ldC5jb3JlLm5ldGRldl9tYXhfYmFja2xvZyA9IDI1MDAwMApuZXQuY29yZS5zb21heGNvbm4gPSA0MDk2Cm5ldC5pcHY0LnRjcF9zeW5jb29raWVzID0gMQpuZXQuaXB2NC50Y3BfdHdfcmV1c2UgPSAxCm5ldC5pcHY0LmlwX2xvY2FsX3BvcnRfcmFuZ2UgPSAxMDAwMCA2NTAwMApuZXQuaXB2NC50Y3BfbWF4X3N5bl9iYWNrbG9nID0gODE5MgpuZXQuaXB2NC50Y3BfbWF4X3R3X2J1Y2tldHMgPSA1MDAwCm5ldC5pcHY0LnRjcF9mYXN0b3BlbiA9IDMKbmV0LmlwdjQudGNwX3JtZW0gPSA4MTkyIDI2MjE0NCA1MzY4NzA5MTIKbmV0LmlwdjQudGNwX3dtZW0gPSA0MDk2IDE2Mzg0IDUzNjg3MDkxMgpuZXQuaXB2NC50Y3BfYWR2X3dpbl9zY2FsZSA9IC0yCm5ldC5pcHY0LmlwX2ZvcndhcmQgPSAxCm5ldC5jb3JlLmRlZmF1bHRfcWRpc2MgPSBmcQpuZXQuaXB2NC50Y3BfY29uZ2VzdGlvbl9jb250cm9sID0gYmJyCkVPRg==' | base64 -d | bash"

  log "[*] System configuration complete"
}

function install_bootloader() {
  log "[*] Installing GRUB bootloader..."

  arch-chroot ${workdir} mkdir -p /boot/grub

  if [ "$encryption" = "true" ]; then
    arch-chroot ${workdir} /bin/bash <<GRUBEOF
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"rootflags=compress-force=zstd cryptdevice=UUID=${LUKS_UUID}:cryptlvm\"|" /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"|' /etc/default/grub
echo 'GRUB_TERMINAL="serial console"' >> /etc/default/grub
echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >> /etc/default/grub
GRUBEOF
  else
    arch-chroot ${workdir} /bin/bash -c "echo 'IyEvYmluL2Jhc2gKZWNobyAiR1JVQl9ESVNBQkxFX09TX1BST0JFUj10cnVlIiA+PiAvZXRjL2RlZmF1bHQvZ3J1YgpzZWQgLWkgJ3MvXkdSVUJfVElNRU9VVD0uKiQvR1JVQl9USU1FT1VUPTUvJyAvZXRjL2RlZmF1bHQvZ3J1YgpzZWQgLWkgJ3MvXkdSVUJfQ01ETElORV9MSU5VWF9ERUZBVUxUPS4qL0dSVUJfQ01ETElORV9MSU5VWF9ERUZBVUxUPVwicm9vdGZsYWdzPWNvbXByZXNzLWZvcmNlPXpzdGRcIi8nIC9ldGMvZGVmYXVsdC9ncnViCnNlZCAtaSAnc3xeR1JVQl9DTURMSU5FX0xJTlVYPS4qfEdSVUJfQ01ETElORV9MSU5VWD0ibmV0LmlmbmFtZXM9MCBiaW9zZGV2bmFtZT0wInxnJyAvZXRjL2RlZmF1bHQvZ3J1YgplY2hvICdHUlVCX1RFUk1JTkFMPSJzZXJpYWwgY29uc29sZSInID4+IC9ldGMvZGVmYXVsdC9ncnViCmVjaG8gJ0dSVUJfU0VSSUFMX0NPTU1BTkQ9InNlcmlhbCAtLXNwZWVkPTExNTIwMCInID4+IC9ldGMvZGVmYXVsdC9ncnVi' | base64 -d | bash"
  fi

  arch-chroot ${workdir} grub-mkconfig -o /boot/grub/grub.cfg

  if [ "$uefi" = "true" ]; then
    arch-chroot ${workdir} pacman --disable-sandbox --needed --noconfirm -Su efibootmgr
    mkdir -p ${workdir}/sys/firmware/efi/efivars
    mount --rbind /sys/firmware/efi/efivars ${workdir}/sys/firmware/efi/efivars
    arch-chroot ${workdir} grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --bootloader-id=GRUB
    umount ${workdir}/sys/firmware/efi/efivars
  else
    arch-chroot ${workdir} grub-install --target=i386-pc ${disk}
  fi

  # Verify GRUB configuration
  [ -f ${workdir}/boot/grub/grub.cfg ] || fatal "GRUB configuration failed"
  grep -q "linux" ${workdir}/boot/grub/grub.cfg || fatal "GRUB configuration missing kernel entries"

  log "[*] GRUB installation verified successfully"
}

function generate_fstab_crypttab() {
  log "[*] Generating fstab and crypttab..."

  genfstab -U ${workdir} >> ${workdir}/etc/fstab

  if [ "$encryption" = "true" ]; then
    echo "cryptlvm UUID=${LUKS_UUID} none luks" > ${workdir}/etc/crypttab
  fi

  grep -q "/boot/efi" ${workdir}/etc/fstab || fatal "fstab missing EFI entry"
  log "[*] fstab and crypttab generated successfully"
}

function setup_monitoring_ssh() {
  log "[*] Starting monitoring SSH on port 2222..."

  # Generate temporary keys
  mkdir -p /tmp/dropbear_keys
  dropbearkey -t rsa -f /tmp/dropbear_keys/dropbear_rsa_host_key 2>/dev/null

  # Start Dropbear (background) - allows monitoring during Debian deletion
  dropbear -p 2222 -r /tmp/dropbear_keys/dropbear_rsa_host_key -E 2>/dev/null &

  log "[*] Monitoring SSH available at port 2222"
  log "[*] Login: root / ${password}"
}

function cleanup_chroot_and_unmount() {
  log "[*] Unmounting Arch chroot..."

  if [ "$encryption" = "true" ]; then
    swapoff /dev/vg0/swap 2>/dev/null || true
    umount -l ${workdir}/boot/efi 2>/dev/null || true
    umount -l ${workdir}/dev/pts 2>/dev/null || true
    umount -l ${workdir}/dev 2>/dev/null || true
    umount -l ${workdir}/sys 2>/dev/null || true
    umount -l ${workdir}/proc 2>/dev/null || true
    umount -l ${workdir} 2>/dev/null || true
    vgchange -an vg0 2>/dev/null || true
    cryptsetup close cryptlvm 2>/dev/null || true
  else
    umount -l ${workdir}/boot/efi 2>/dev/null || true
    umount -l ${workdir}/dev/pts 2>/dev/null || true
    umount -l ${workdir}/dev 2>/dev/null || true
    umount -l ${workdir}/sys 2>/dev/null || true
    umount -l ${workdir}/proc 2>/dev/null || true
    umount -l ${workdir} 2>/dev/null || true
  fi

  log "[*] Unmounting complete"
}

function verify_installation() {
  log "[*] Verifying installation before proceeding..."

  local checks=(
    "${workdir}/boot/grub/grub.cfg:GRUB configuration"
    "${workdir}/etc/fstab:fstab"
    "${workdir}/usr/bin/pacman:Pacman"
    "${workdir}/bin/systemctl:systemd"
    "${workdir}/etc/systemd/network/default.network:Network config"
  )

  for check in "${checks[@]}"; do
    local file="${check%%:*}"
    local name="${check##*:}"
    if [ ! -f "$file" ] && [ ! -L "$file" ]; then
      fatal "Verification failed: $name missing"
    fi
  done

  # Verify GRUB contains kernel entries
  grep -q "linux" ${workdir}/boot/grub/grub.cfg || fatal "GRUB missing kernel entries"

  log "[*] All verification checks passed"
}

function delete_debian_system() {
  log "[*] Deleting Debian system files..."
  log "[!] This will destroy the running system. Arch installation is complete."

  # Stop services that might interfere
  systemctl stop NetworkManager 2>/dev/null || true
  killall -9 systemd-networkd dhclient 2>/dev/null || true

  # Copy critical binaries to /tmp
  mkdir -p /tmp/bin
  cp /bin/sync /bin/sleep /sbin/reboot /tmp/bin/ 2>/dev/null || true

  # Delete Debian system (preserve virtual filesystems and temporary files)
  log "[*] Removing Debian directories..."
  rm -rf /bin /boot /etc /home /lib* /opt /root /sbin /srv /usr /var 2>/dev/null || true

  log "[*] Debian system deleted. Only /dev, /proc, /sys, /tmp, /mnt remain."
}

function final_reboot() {
  log "[*] Syncing filesystems..."
  sync ; sync ; sync

  log "[*] ================================================"
  log "[*] Installation complete!"
  log "[*] System will reboot in 5 seconds..."
  log "[*] After reboot, login with: root / ${password}"
  log "[*] ================================================"

  sleep 5

  # Use absolute path or builtin command
  if [ -x /tmp/bin/reboot ]; then
    /tmp/bin/reboot -f
  else
    reboot -f
  fi
}

function print_info(){
  log '**************************************************************************'
  log "[*] e.g. --lts --reflector --pwd i2a@@@ --cn-mirror --encryption --luks-password yourkey"
  log "[*] DHCP: $dhcp  Reflector: ${reflector}  CN Mirror: ${cn_mirror}  Encryption: ${encryption}"
  log "[*] MACH: $machine KERNEL: $kernel UEFI: ${uefi}"
  log "[*] V4: $ip4_addr $ip4_gw"
  log "[*] V6: $ip6_addr $ip6_gw"
  log "[*] Arch Mirror: $mirror"
  log '**************************************************************************'
}

function parse_command_and_confirm() {
  while [ $# -gt 0 ]; do
    case $1 in
      --mirror)
        mirror=$2
        shift
        ;;
      --pwd)
        password=$2
        shift
        ;;
      --lts)
        kernel='linux-lts'
        ;;
      --dhcp)
        dhcp=true
        ;;
      --uefi)
        uefi=true
        ;;
      --reflector)
        reflector=true
        ;;
      --cn-mirror)
        cn_mirror=true
        ;;
      --encryption|--luks)
        encryption=true
        ;;
      --luks-password)
        luks_password=$2
        encryption=true
        shift
        ;;
      *)
        fatal "Unsupported parameters: $1"
    esac
    shift
  done

  # Apply CN mirror settings if requested
  if [ "$cn_mirror" = "true" ]; then
    log "[*] Using China mirrors for faster download..."
    # Use Tsinghua mirror for Arch Linux (one of the fastest in China)
    mirror='https://mirrors.tuna.tsinghua.edu.cn/archlinux'
  fi

  # Validate encryption password if encryption enabled
  if [ "$encryption" = "true" ] && [ -z "$luks_password" ]; then
    fatal "Encryption enabled but no --luks-password provided"
  fi

  validate_inputs
  print_info
  read -r -p "[*] This operation will clear all data. Are you sure you want to continue? [y/N] " _confirm </dev/tty
  case "$_confirm" in
    [yY][eE][sS]|[yY])
      true
      ;;
    *)
      false
      ;;
  esac
}

[ ${EUID} -eq 0 ] || fatal '[-] This script must be run as root.'
[ ${UID} -eq 0 ] || fatal '[-] This script must be run as root.'

if parse_command_and_confirm "$@" ; then
  # Stage 1: Prepare Debian environment
  install_debian_dependencies

  # Stage 2: Disk preparation
  partition_and_format_disk

  # Stage 3: Arch installation
  download_arch_bootstrap
  setup_chroot_environment
  install_arch_base_system
  configure_arch_system
  install_bootloader
  generate_fstab_crypttab

  # Stage 4: Verification and cleanup
  verify_installation
  cleanup_chroot_and_unmount
  setup_monitoring_ssh
  delete_debian_system
  final_reboot
else
  echo -e "Installation cancelled."
  exit 1
fi
