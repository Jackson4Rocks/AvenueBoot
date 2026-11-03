#!/usr/bin/env bash
#
# AVENUEBOOT — Windows installer USB creator for Linux
# Works ONLY with Windows ISOs (Linux ISOs are not supported) and boots in UEFI mode only.
# Creates a FAT32 installer drive and splits oversized install.wim files.
#
set -Eeuo pipefail

AVENUEBOOT_VERSION='1.0.0'

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

ISO_PATH=''
TARGET_DEV=''
CONFIRM_YES=0
DRY_RUN=0
LIST_DEVICES=0
ISO_MOUNT=''
USB_MOUNT=''
PARTITION=''
LARGE_WIM=''
DISK_PATHS=()
DISK_SIZES=()
DISK_REMOVABLE=()
PACKAGE_MANAGER=''
PACKAGE_FAMILY=''

info() { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%b[  OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b[ WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
err()  { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%b+-- %s%b\n' "$CYAN$BOLD" "$*" "$RESET"; }

print_banner() {
  printf '%b' "$CYAN$BOLD"
  cat <<'EOF'
▄▄▄▄▄  ▄     ▄ ▄▄▄▄▄▄ ▄    ▄  ▄     ▄ ▄▄▄▄▄▄ ▄▄▄▄    ▄▄▄▄▄▄  ▄▄▄▄▄▄ ▄▄▄▄▄▄▄▄▄
█     █ █     █ █      █▄    █ █     █ █      █   ▀▄ █     ▄ █     ▄     █
█▄▄▄▄▄▀ █     ▄ █▄▄▄   █ ▀▄  █ █     ▄ █▄▄▄   █▄▄▄▄▀ █     ▄ █     ▄     ▄
█     ▀ ▄     █ ▄      █   ▀▄█ ▄     █ ▄      ▀    █ █     █ █     █     █
█     █  ▀▄▄▄▀  █▄▄▄▄▄ ▀▄    █ ▀▄▄▄▄▄▀ █▄▄▄▄▄ ▀▄▄▄▀  ▀▄▄▄▄▄▀ ▀▄▄▄▄▄▀     █
EOF
  printf '%b\n' "$RESET"
  printf '%b  WINDOWS INSTALLER USB CREATOR%b\n' "$BOLD" "$RESET"
  printf '%b  v%s  |  UEFI boot  |  FAT32  |  ISO file copy  |  No raw imaging%b\n' "$DIM" "$AVENUEBOOT_VERSION" "$RESET"
  printf '%b  ----------------------------------------------------------------%b\n\n' "$DIM" "$RESET"
}

usage() {
  cat <<'EOF'
Usage: AvenueBoot.sh [OPTIONS]

Create a UEFI-bootable Windows installer USB from a Microsoft ISO. The USB is
partitioned as FAT32 and the ISO files are copied; the ISO is not raw-imaged.
If sources/install.wim exceeds FAT32's file-size limit, it is split into
Windows Setup-compatible .swm files.
Designed for UEFI boot. It does not create legacy-BIOS boot media.

Options:
  -i, --iso FILE       Windows ISO path
  -d, --device DEVICE  Whole USB device (for example /dev/sdb, not /dev/sdb1)
  -y, --yes            Approve dependency installation and skip the erase prompt
                       (requires both --iso and --device; automation only)
      --list-devices   List detected disks and exit
      --dry-run        Validate inputs without changing disks (dependencies may
                       still be installed if needed)
  -h, --help           Show this help

Examples:
  sudo ./AvenueBoot.sh
  sudo ./AvenueBoot.sh --iso ~/Downloads/Win11.iso --device /dev/sdb
  sudo ./AvenueBoot.sh -i Win11.iso -d /dev/sdb --yes

Missing dependencies are offered for installation from your distribution's
package manager. Installing a package requires administrator privileges.
Creating the installer erases all data on the selected device.
Dependencies: util-linux, parted, dosfstools, rsync; wimtools is installed
when the ISO contains an install.wim larger than 4 GiB.
EOF
}

cleanup() {
  local status=$?
  if [[ -n "$USB_MOUNT" ]] && mountpoint -q "$USB_MOUNT" 2>/dev/null; then
    umount "$USB_MOUNT" || warn "Could not unmount $USB_MOUNT"
  fi
  if [[ -n "$ISO_MOUNT" ]] && mountpoint -q "$ISO_MOUNT" 2>/dev/null; then
    umount "$ISO_MOUNT" || warn "Could not unmount $ISO_MOUNT"
  fi
  [[ -n "$USB_MOUNT" ]] && rmdir "$USB_MOUNT" 2>/dev/null || true
  [[ -n "$ISO_MOUNT" ]] && rmdir "$ISO_MOUNT" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

on_error() {
  local status=$?
  err "Command failed at line ${BASH_LINENO[0]} (exit $status): $BASH_COMMAND"
  exit "$status"
}
trap on_error ERR

parse_args() {
  while (($#)); do
    case "$1" in
      -i|--iso)
        (($# >= 2)) || die "Missing value for $1."
        ISO_PATH=$2
        shift 2
        ;;
      -d|--device)
        (($# >= 2)) || die "Missing value for $1."
        TARGET_DEV=$2
        shift 2
        ;;
      -y|--yes) CONFIRM_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --list-devices) LIST_DEVICES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; (($# == 0)) || die "Unexpected positional arguments."; break ;;
      -*) die "Unknown option: $1. Use --help for usage." ;;
      *) die "Unexpected positional argument: $1. Use --help for usage." ;;
    esac
  done

  if (( CONFIRM_YES )) && { [[ -z "$ISO_PATH" || -z "$TARGET_DEV" ]]; }; then
    die "--yes requires both --iso and --device."
  fi
  if (( CONFIRM_YES && DRY_RUN )); then
    die "--dry-run and --yes cannot be combined."
  fi
  if (( LIST_DEVICES )) && { [[ -n "$ISO_PATH" || -n "$TARGET_DEV" || $CONFIRM_YES -eq 1 || $DRY_RUN -eq 1 ]]; }; then
    die "--list-devices cannot be combined with flashing options."
  fi
}

detect_package_manager() {
  local distro_id='' distro_like=''
  if [[ -r /etc/os-release ]]; then
    while IFS='=' read -r key value; do
      value=${value#\"}
      value=${value%\"}
      case "$key" in
        ID) distro_id=${value,,} ;;
        ID_LIKE) distro_like=${value,,} ;;
      esac
    done < /etc/os-release
  fi

  case " $distro_id $distro_like " in
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*) PACKAGE_FAMILY=debian ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) PACKAGE_FAMILY=fedora ;;
    *" arch "*|*" manjaro "*|*" endeavouros "*) PACKAGE_FAMILY=arch ;;
    *" opensuse "*|*" suse "*) PACKAGE_FAMILY=suse ;;
    *" alpine "*) PACKAGE_FAMILY=alpine ;;
    *" void "*) PACKAGE_FAMILY=void ;;
    *" gentoo "*) PACKAGE_FAMILY=gentoo ;;
  esac

  case "$PACKAGE_FAMILY" in
    debian) PACKAGE_MANAGER=apt-get ;;
    fedora) PACKAGE_MANAGER=dnf ;;
    arch) PACKAGE_MANAGER=pacman ;;
    suse) PACKAGE_MANAGER=zypper ;;
    alpine) PACKAGE_MANAGER=apk ;;
    void) PACKAGE_MANAGER=xbps-install ;;
    gentoo) PACKAGE_MANAGER=emerge ;;
  esac

  [[ -n "$PACKAGE_MANAGER" ]] && command -v "$PACKAGE_MANAGER" >/dev/null 2>&1
}

package_names() {
  case "$PACKAGE_FAMILY:$1" in
    debian:base) printf '%s\n' util-linux parted dosfstools rsync coreutils findutils grep gawk ;;
    fedora:base) printf '%s\n' util-linux parted dosfstools rsync coreutils findutils grep gawk ;;
    arch:base) printf '%s\n' util-linux parted dosfstools rsync coreutils findutils grep gawk ;;
    suse:base) printf '%s\n' util-linux parted dosfstools rsync coreutils findutils grep gawk ;;
    alpine:base) printf '%s\n' util-linux parted dosfstools rsync coreutils findutils grep gawk ;;
    void:base) printf '%s\n' util-linux parted dosfstools rsync coreutils findutils grep gawk ;;
    gentoo:base) printf '%s\n' sys-apps/util-linux sys-block/parted sys-fs/dosfstools net-misc/rsync sys-apps/coreutils sys-apps/findutils sys-apps/grep sys-apps/gawk ;;
    debian:wim) printf '%s\n' wimtools ;;
    fedora:wim) printf '%s\n' wimlib-utils ;;
    arch:wim|suse:wim|alpine:wim|void:wim) printf '%s\n' wimlib ;;
    gentoo:wim) printf '%s\n' app-arch/wimlib ;;
    *) return 1 ;;
  esac
}

run_package_manager() {
  local mode=$1
  shift
  local -a privilege=()
  local -a install_flags=()
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "Installing packages requires root. Re-run with sudo."
    privilege=(sudo)
    sudo -v || die "Could not obtain administrator permission to install dependencies."
  fi
  (( CONFIRM_YES )) && install_flags=(-y)

  case "$PACKAGE_MANAGER:$mode" in
    apt-get:base|apt-get:wim)
      if [[ "$mode" == base ]]; then
        "${privilege[@]}" apt-get update
      fi
      "${privilege[@]}" apt-get install "${install_flags[@]}" "$@"
      ;;
    dnf:*) "${privilege[@]}" dnf install -y "$@" ;;
    pacman:*) "${privilege[@]}" pacman -S --needed --noconfirm "$@" ;;
    zypper:*) "${privilege[@]}" zypper --non-interactive install "$@" ;;
    apk:*) "${privilege[@]}" apk add "$@" ;;
    xbps-install:*) "${privilege[@]}" xbps-install -S "$@" ;;
    emerge:*) "${privilege[@]}" emerge --ask=n "$@" ;;
    *) die "Unsupported package manager: $PACKAGE_MANAGER" ;;
  esac
}

install_packages() {
  local mode=$1 package_text answer
  shift
  package_text=$(printf '%s ' "$@")
  package_text=${package_text% }
  printf '\n%bDependency installation%b\n' "$BOLD" "$RESET"
  printf '  Package manager: %s\n  Packages:        %s\n' "$PACKAGE_MANAGER" "$package_text"

  if (( ! CONFIRM_YES )); then
    [[ -t 0 ]] || die "Cannot prompt to install dependencies without a terminal. Re-run interactively or use --yes."
    read -r -p "Install these packages now? [y/N] " answer || die "Dependency installation cancelled."
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] ||
      die "Dependency installation declined."
  else
    warn "Installing dependencies as requested by --yes."
  fi

  run_package_manager "$mode" "$@"
}

ensure_base_dependencies() {
  local -a required=(
    lsblk findmnt mount umount mountpoint parted partprobe mkfs.fat
    wipefs blockdev udevadm rsync find stat du readlink dirname grep awk mktemp sort sync
  )
  local -a missing=()
  local command
  for command in "${required[@]}"; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done

  if ((${#missing[@]} == 0)); then
    ok "All required commands are available."
    return
  fi

  warn "Missing commands: ${missing[*]}"
  detect_package_manager ||
    die "Could not identify a supported package manager. Install util-linux, parted, dosfstools, rsync, coreutils, findutils, grep, and gawk manually."

  local -a packages=()
  mapfile -t packages < <(package_names base)
  install_packages base "${packages[@]}"

  missing=()
  for command in "${required[@]}"; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done
  ((${#missing[@]} == 0)) ||
    die "Required commands are still missing after installation: ${missing[*]}"
  ok "Dependencies installed."
}

ensure_wim_dependency() {
  command -v wimlib-imagex >/dev/null 2>&1 && return
  [[ -n "$PACKAGE_MANAGER" ]] || detect_package_manager ||
    die "wimlib-imagex is required to split install.wim, but no supported package manager was found."
  local -a packages=()
  mapfile -t packages < <(package_names wim)
  install_packages wim "${packages[@]}"
  command -v wimlib-imagex >/dev/null 2>&1 ||
    die "wimlib-imagex is still unavailable after installing ${packages[*]}."
  ok "WIM splitting tools are ready."
}

require_root() {
  if (( EUID != 0 )); then
    die "Root privileges are required. Re-run with sudo."
  fi
}

scan_devices() {
  DISK_PATHS=()
  DISK_SIZES=()
  DISK_REMOVABLE=()
  local path size removable type
  while read -r path size removable type; do
    [[ "$type" == disk ]] || continue
    [[ "$path" == /dev/loop* || "$path" == /dev/ram* || "$path" == /dev/zram* ]] && continue
    DISK_PATHS+=("$path")
    DISK_SIZES+=("$size")
    DISK_REMOVABLE+=("$removable")
  done < <(lsblk -dnpo PATH,SIZE,RM,TYPE 2>/dev/null)
}

list_devices() {
  scan_devices
  if ((${#DISK_PATHS[@]} == 0)); then
    info "No disk devices found."
    return
  fi

  printf '%b%-4s %-18s %-10s %-12s %s%b\n' "$BOLD" "#" "DEVICE" "SIZE" "MEDIA" "MODEL" "$RESET"
  local index model media
  for index in "${!DISK_PATHS[@]}"; do
    model=$(lsblk -dnro MODEL -- "${DISK_PATHS[$index]}" 2>/dev/null)
    [[ -n "$model" ]] || model='Unknown model'
    media='fixed'
    [[ "${DISK_REMOVABLE[$index]}" == 1 ]] && media='removable'
    printf '%-4s %-18s %-10s %-12s %s\n' "$((index + 1))" "${DISK_PATHS[$index]}" \
      "${DISK_SIZES[$index]}" "$media" "$model"
  done
}

select_device() {
  step "Choose destination disk"
  if [[ -n "$TARGET_DEV" ]]; then
    [[ -b "$TARGET_DEV" ]] || die "Not a block device: $TARGET_DEV"
  else
    scan_devices
    ((${#DISK_PATHS[@]})) || die "No disk devices found."
    printf '%bAvailable disks%b\n' "$BOLD" "$RESET"
    local index model media
    for index in "${!DISK_PATHS[@]}"; do
      model=$(lsblk -dnro MODEL -- "${DISK_PATHS[$index]}" 2>/dev/null)
      [[ -n "$model" ]] || model='Unknown model'
      media='fixed'
      [[ "${DISK_REMOVABLE[$index]}" == 1 ]] && media='removable'
      printf '  %2d) %-18s %-10s %-12s %s\n' "$((index + 1))" "${DISK_PATHS[$index]}" \
        "${DISK_SIZES[$index]}" "$media" "$model"
    done
    local choice
    while true; do
      read -r -p "Select disk [1-${#DISK_PATHS[@]}]: " choice || die "No device selected."
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DISK_PATHS[@]} )); then
        TARGET_DEV=${DISK_PATHS[$((choice - 1))]}
        break
      fi
      err "Choose a number from 1 to ${#DISK_PATHS[@]}."
    done
  fi

  TARGET_DEV=$(readlink -f -- "$TARGET_DEV") || die "Could not resolve target device."
  [[ "$(lsblk -dnro TYPE -- "$TARGET_DEV" 2>/dev/null)" == disk ]] ||
    die "Target must be a whole disk, not a partition: $TARGET_DEV"
  [[ "$TARGET_DEV" != /dev/loop* && "$TARGET_DEV" != /dev/ram* && "$TARGET_DEV" != /dev/zram* ]] ||
    die "Loop, RAM, and zram devices cannot be used as targets."
  local target_model target_size
  target_model=$(lsblk -dnro MODEL -- "$TARGET_DEV" 2>/dev/null)
  target_size=$(lsblk -dnro SIZE -- "$TARGET_DEV" 2>/dev/null)
  ok "Target: $TARGET_DEV ($target_size, ${target_model:-unknown model})"
}

validate_target() {
  step "Check device safety"
  local system_path source_device iso_device target_devices
  local -a system_paths=(/ /boot /boot/efi /usr /var)
  target_devices=$(lsblk -nrpo MAJ:MIN -- "$TARGET_DEV" 2>/dev/null)
  for system_path in "${system_paths[@]}"; do
    [[ -e "$system_path" ]] || continue
    source_device=$(findmnt -T "$system_path" -nro MAJ:MIN 2>/dev/null || true)
    if device_is_on_target "$source_device" "$target_devices"; then
      die "Refusing to erase the disk containing the running system filesystem ($system_path): $TARGET_DEV"
    fi
  done
  iso_device=$(findmnt -T "$ISO_PATH" -nro MAJ:MIN 2>/dev/null || true)
  if device_is_on_target "$iso_device" "$target_devices"; then
    die "The ISO is stored on the target disk. Move it to another disk before flashing."
  fi
  local size
  size=$(blockdev --getsize64 "$TARGET_DEV") || die "Could not read target size."
  (( size > 0 )) || die "Target device reports an invalid size."
}

device_is_on_target() {
  local source_major_minor=$1 target_devices=$2 source_path ancestor target_device candidate major_minor
  [[ -n "$source_major_minor" ]] || return 1
  source_path=''
  while read -r candidate major_minor; do
    if [[ "$major_minor" == "$source_major_minor" ]]; then
      source_path=$candidate
      break
    fi
  done < <(lsblk -nrpo PATH,MAJ:MIN)
  [[ -n "$source_path" ]] || return 1
  while IFS= read -r ancestor; do
    while IFS= read -r target_device; do
      [[ "$ancestor" == "$target_device" ]] && return 0
    done <<< "$target_devices"
  done < <(lsblk -s -nrpo MAJ:MIN -- "$source_path" 2>/dev/null)
  return 1
}

select_iso() {
  step "Choose Windows ISO"
  if [[ -z "$ISO_PATH" ]]; then
    local -a isos=()
    while IFS= read -r -d '' path; do isos+=("$path"); done \
      < <(find "$PWD" -maxdepth 1 -type f -iname '*.iso' -print0 | sort -z)
    if ((${#isos[@]})); then
      printf '%bISOs in %s:%b\n' "$BOLD" "$PWD" "$RESET"
      local index
      for index in "${!isos[@]}"; do
        printf '  %d) %s (%s bytes)\n' "$((index + 1))" "${isos[$index]}" \
          "$(stat -c %s -- "${isos[$index]}")"
      done
    fi
    while true; do
      local choice
      read -r -p "ISO path or listed number: " choice || die "No ISO selected."
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#isos[@]} )); then
        ISO_PATH=${isos[$((choice - 1))]}
        break
      elif [[ -f "$choice" ]]; then
        ISO_PATH=$choice
        break
      else
        err "Enter a listed number or a valid ISO path."
      fi
    done
  fi

  ISO_PATH=${ISO_PATH/#\~/$HOME}
  ISO_PATH=$(readlink -f -- "$ISO_PATH") || die "Could not resolve ISO path."
  [[ -f "$ISO_PATH" && -r "$ISO_PATH" ]] || die "ISO is not a readable file: $ISO_PATH"
  ok "ISO: $ISO_PATH"
}

prepare_iso() {
  step "Inspect ISO"
  ISO_MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/avenueboot-iso.XXXXXX")
  mount -o loop,ro,nosuid,nodev -- "$ISO_PATH" "$ISO_MOUNT" ||
    die "Could not mount ISO. Verify that it is a valid, readable ISO file."
  [[ -d "$ISO_MOUNT/boot" && -d "$ISO_MOUNT/sources" ]] ||
    die "ISO does not look like Windows installation media (missing boot/ or sources/)."
}

check_capacity_and_large_files() {
  step "Check ISO and capacity"
  local device_size content_size path bytes relative
  device_size=$(blockdev --getsize64 "$TARGET_DEV")
  content_size=$(du -sb -- "$ISO_MOUNT")
  content_size=${content_size%%$'\t'*}
  (( device_size > content_size + 134217728 )) ||
    die "Target is too small: ISO contents need about $content_size bytes; disk has $device_size bytes."
  local content_display
  content_display=$(du -sh -- "$ISO_MOUNT")
  content_display=${content_display%%$'\t'*}
  info "ISO contents: $content_display"

  LARGE_WIM=''
  while IFS= read -r -d '' path; do
    bytes=$(stat -c %s -- "$path")
    (( bytes <= 4294967295 )) && continue
    relative=${path#"$ISO_MOUNT"/}
    if [[ "${relative,,}" == sources/install.wim ]]; then
      [[ -z "$LARGE_WIM" ]] || die "ISO contains multiple oversized install.wim files."
      LARGE_WIM=$relative
      warn "install.wim is larger than FAT32 permits; it will be split into .swm files."
    else
      die "FAT32 cannot store this ISO file (>4 GiB): $relative. Cannot safely create this installer."
    fi
  done < <(find "$ISO_MOUNT" -type f -size +4294967295c -print0)
  if [[ -n "$LARGE_WIM" ]] && ! command -v wimlib-imagex >/dev/null 2>&1; then
    ensure_wim_dependency
  fi
}

confirm_wipe() {
  printf '\n%bPreflight complete%b\n' "$BOLD" "$RESET"
  printf '  ISO:    %s\n  Device: %s\n' "$ISO_PATH" "$TARGET_DEV"
  if (( DRY_RUN )); then
    info "Dry run passed. No disk changes were made."
    exit 0
  fi

  printf '\n%b%s%b\n' "$RED$BOLD" "ERASE WARNING" "$RESET"
  printf '%bAll data on the selected device will be permanently erased.%b\n' "$RED" "$RESET"
  if (( CONFIRM_YES )); then
    warn "Proceeding without an interactive confirmation (--yes)."
    return
  fi
  local confirmation
  read -r -p "Type the device path exactly to continue ($TARGET_DEV): " confirmation ||
    die "Confirmation was not received."
  [[ "$confirmation" == "$TARGET_DEV" ]] || die "Confirmation did not match; no disk changes were made."
}

unmount_target_partitions() {
  local path mount_target
  while IFS= read -r path; do
    [[ -b "$path" ]] || continue
    while IFS= read -r mount_target; do
      [[ -n "$mount_target" ]] || continue
      info "Unmounting $mount_target"
      umount -- "$mount_target" || die "Could not unmount $mount_target. Close files using it and retry."
    done < <(findmnt -rn -S "$path" -o TARGET 2>/dev/null || true)
  done < <(lsblk -nrpo PATH -- "$TARGET_DEV")
}

partition_and_format() {
  step "Partitioning and formatting $TARGET_DEV"
  unmount_target_partitions
  wipefs --all --force "$TARGET_DEV"
  parted --script --align optimal "$TARGET_DEV" \
    mklabel msdos \
    mkpart primary fat32 1MiB 100% \
    set 1 boot on
  partprobe "$TARGET_DEV"
  udevadm settle

  PARTITION=''
  local device_path device_type
  while read -r device_path device_type; do
    if [[ "$device_type" == part ]]; then
      PARTITION=$device_path
      break
    fi
  done < <(lsblk -lnpo PATH,TYPE -- "$TARGET_DEV")
  [[ -b "$PARTITION" ]] || die "Could not locate the new USB partition."
  mkfs.fat -F 32 -n AVENUEBOOT "$PARTITION"
}

copy_iso() {
  step "Copying Windows installer files"
  USB_MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/avenueboot-usb.XXXXXX")
  mount -t vfat -o rw,nosuid,nodev,noatime -- "$PARTITION" "$USB_MOUNT"
  info "Using direct local copies with progress reporting."
  local -a rsync_options=(-r --whole-file --info=progress2 --no-perms --no-owner --no-group)
  if [[ -n "$LARGE_WIM" ]]; then
    rsync_options+=(--exclude="/$LARGE_WIM")
  fi
  rsync "${rsync_options[@]}" -- "$ISO_MOUNT/" "$USB_MOUNT/"

  if [[ -n "$LARGE_WIM" ]]; then
    step "Splitting oversized install.wim for FAT32"
    local wim_destination="$USB_MOUNT/$(dirname -- "$LARGE_WIM")"
    wimlib-imagex split "$ISO_MOUNT/$LARGE_WIM" 3800 \
      --output-dir="$wim_destination"
  fi
  sync -f "$USB_MOUNT"
  umount "$USB_MOUNT"
  ok "Installer files copied."
}

main() {
  parse_args "$@"
  print_banner
  if (( LIST_DEVICES )); then
    command -v lsblk >/dev/null 2>&1 || die "lsblk is required."
    list_devices
    return
  fi

  step "Check and prepare dependencies"
  ensure_base_dependencies
  step "Check administrator access"
  require_root
  select_device
  select_iso
  validate_target
  prepare_iso
  check_capacity_and_large_files

  confirm_wipe
  partition_and_format
  copy_iso
  printf '\n%b+==================================================================+%b\n' "$GREEN$BOLD" "$RESET"
  printf '%b|  FLASH COMPLETE                                                 |%b\n' "$GREEN$BOLD" "$RESET"
  printf '%b+==================================================================+%b\n' "$GREEN$BOLD" "$RESET"
  printf '  Installer: %s\n  USB disk:  %s\n\n' "$ISO_PATH" "$TARGET_DEV"
  info "Safely eject the drive before unplugging it."
}

main "$@"
