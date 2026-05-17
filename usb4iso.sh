#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage:
	sudo ./usb4iso.sh -i <path-to-iso> -d <target-device> [-u <user-data>] [-m <meta-data>]

Example:
	sudo ./usb4iso.sh -i ~/Downloads/linux.iso -d /dev/sdb
	sudo ./usb4iso.sh -i ~/Downloads/linux.iso -d /dev/sdb -u ./user-data -m ./meta-data

Notes:
	- This will ERASE all data on the target device.
	- Target must be the whole device (e.g. /dev/sdb), not a partition (/dev/sdb1).
	- If -u and -m are provided, a small FAT partition labeled CIDATA is added.
  - If -u and -m are provided, the ISO is remastered to inject the kernel arg 'autoinstall'.
EOF
}

################################################################################
# Check whether a required command exists in PATH.
# Exit with an error message if it is missing.
################################################################################
require_cmd() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Error: required command '$cmd' not found." >&2
		exit 1
	fi
}

####################################################blk###########################
# Check whether the given device is 
#  a (whole) block device /dev/sda
#  not a partition /dev/sda1
# Returns rc=0 if valid whole block device, 
#         rc=1 otherwise.
################################################################################
is_block_device() {
	local dev="$1"
	[[ -b "$dev" ]] || return 1
	[[ ! "$dev" =~ [0-9]$ ]] || return 1
	return 0
}

################################################################################
# Inject "autoinstall" into kernel cmdlines of extracted boot config files.
# Read an extracted boot config and add the kernel argument "autoinstall"
# only to kernel launch lines (linux/append). This avoids the interactive
# confirmation prompt and keeps repeat runs safe by not duplicating the arg.
################################################################################
inject_autoinstall_arg() {
  local in_file="$1"
  local out_file="$2"
  awk '
  {
    line=$0
    # Touch only kernel command lines and keep idempotency if arg already exists.
    if (line ~ /^[[:space:]]*(linux|append)[[:space:]]/ && line !~ /(^|[[:space:]])autoinstall([[:space:]]|$)/) {
      # Ubuntu live entries often terminate with " ---"; insert before it.
      if (line ~ / ---/) {
        sub(/ ---/, " autoinstall ---", line)
      } else {
        line = line " autoinstall"
      }
    }
    print line
  }
  ' "$in_file" > "$out_file"
}

################################################################################
# Build a modified ISO with autoinstall kernel argument in boot config.
# Uses xorriso replay mode to preserve bootability metadata.
################################################################################
remaster_iso_with_autoinstall() {
  local src_iso="$1"
  local dst_iso="$2"
  local tmp_dir
  local grub_cfg_src
  local grub_cfg_dst

  require_cmd xorriso
  tmp_dir="$(mktemp -d)"
  grub_cfg_src="$tmp_dir/grub.cfg.src"
  grub_cfg_dst="$tmp_dir/grub.cfg"

  # UEFI-only flow: patch GRUB config used by modern Ubuntu installer media.
  if ! xorriso -indev "$src_iso" -osirrox on -extract /boot/grub/grub.cfg "$grub_cfg_src" >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    echo "Error: could not extract /boot/grub/grub.cfg from ISO for UEFI remaster." >&2
    exit 1
  fi
  inject_autoinstall_arg "$grub_cfg_src" "$grub_cfg_dst"

  # Replay ISO boot metadata and replace only edited config files.
  xorriso -indev "$src_iso" -outdev "$dst_iso" -boot_image any replay \
    -map "$grub_cfg_dst" /boot/grub/grub.cfg \
    -commit -end >/dev/null

  rm -rf "$tmp_dir"
}

################################################################################
#   P A R S E   C O M M A N D - L I N E   A R G U M E N T S
################################################################################
ISO_PATH=""
TARGET_DEV=""
USER_DATA_PATH=""
META_DATA_PATH=""

while getopts ":i:d:u:m:h" opt; do
  case "$opt" in
    # i is used for ISO path
    i) ISO_PATH="$OPTARG" ;;

    # d for target device
    # for device, not partition, e.g. /dev/sdb, not /dev/sdb1
    d) TARGET_DEV="$OPTARG" ;;

    # u for user-data
    u) USER_DATA_PATH="$OPTARG" ;;

    # m for meta-data
    m) META_DATA_PATH="$OPTARG" ;;

    # h prints help and exits successfully
    h)
      usage
      exit 0
      ;;

    # : means a required option argument is missing
    :)
    echo "Error: option -$OPTARG requires an argument." >&2
      usage
      exit 1
			;;

      # \? means an unknown option was provided
      \?)
        echo "Error: invalid option -$OPTARG" >&2
        usage
        exit 1
        ;;
  esac
done

# Check that the mandatory ISO path argument was provided. "-i"
if [[ -z "$ISO_PATH" ]]; then
	usage
	exit 1
fi

# Check that the mandatory target device argument was provided. "-d"
if [[ -z "$TARGET_DEV" ]]; then
	usage
	exit 1
fi

# Check that the script is running as root because raw disk writes require it.
if [[ "$EUID" -ne 0 ]]; then
	echo "Error: run this script as root (use sudo)." >&2
	exit 1
fi

################################################################################
#
#   M A I N    
#
################################################################################
require_cmd lsblk
require_cmd dd
require_cmd sync
require_cmd sgdisk
require_cmd mkfs.vfat
require_cmd mount
require_cmd umount

# Ensure the provided ISO file exists before proceeding.
if [[ ! -f "$ISO_PATH" ]]; then
	echo "Error: ISO file not found: $ISO_PATH" >&2
	exit 1
fi

SOURCE_ISO="$ISO_PATH"
TMP_REMIX_ISO=""

# Validate optional cloud-init inputs: require both files together 
# and ensure both paths exist.
if [[ -n "$USER_DATA_PATH" || -n "$META_DATA_PATH" ]]; then
	if [[ -z "$USER_DATA_PATH" || -z "$META_DATA_PATH" ]]; then
		echo "Error: both -u <user-data> and -m <meta-data> must be provided together." >&2
		exit 1
	fi
	if [[ ! -f "$USER_DATA_PATH" ]]; then
		echo "Error: user-data file not found: $USER_DATA_PATH" >&2
		exit 1
	fi
	if [[ ! -f "$META_DATA_PATH" ]]; then
		echo "Error: meta-data file not found: $META_DATA_PATH" >&2
		exit 1
	fi

  # Keep original ISO untouched by writing a temporary remastered copy.
  TMP_REMIX_ISO="$(mktemp --suffix=.iso)"
  echo "Preparing remastered ISO with autoinstall kernel argument..."
  remaster_iso_with_autoinstall "$ISO_PATH" "$TMP_REMIX_ISO"
  # Use the remastered image for dd so first boot is already autoinstall-enabled.
  SOURCE_ISO="$TMP_REMIX_ISO"
fi

# Ensure target is a whole disk device (e.g. /dev/sdb), not a partition.
if ! is_block_device "$TARGET_DEV"; then
	echo "Error: target must be an existing whole block device (like /dev/sdb), not a partition." >&2
	exit 1
fi

# Verify the target device is visible/known to lsblk before writing.
if ! lsblk -dn -o NAME "$TARGET_DEV" >/dev/null 2>&1; then
	echo "Error: device not recognized by lsblk: $TARGET_DEV" >&2
	exit 1
fi

echo "ISO:     $ISO_PATH"
echo "DEVICE:  $TARGET_DEV"
if [[ -n "$USER_DATA_PATH" ]]; then
	echo "SEED:    user-data=$USER_DATA_PATH meta-data=$META_DATA_PATH"
  echo "BOOT:    autoinstall kernel argument injected"
else
	echo "SEED:    none"
fi
echo
echo "Current device info:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$TARGET_DEV"
echo

read -r -p "Type YES to continue and erase $TARGET_DEV: " CONFIRM
if [[ ! "$CONFIRM" =~ ^([Yy][Ee][Ss])$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "Unmounting mounted partitions on $TARGET_DEV..."
while read -r part _; do
	if [[ -n "$part" && -e "/dev/$part" ]]; then
		umount "/dev/$part" 2>/dev/null || true
	fi
done < <(lsblk -ln -o NAME,TYPE "$TARGET_DEV" | awk '$2=="part" {print $1}')

# Write the ISO to the target device using dd. 
# This will erase all data on the device.
echo "Writing ISO to $TARGET_DEV (this may take a while)..."
dd if="$SOURCE_ISO" of="$TARGET_DEV" bs=4M status=progress conv=fsync
sync

# If cloud-init seed data was provided, 
#   add a new partition to the end of the disk, 
#   format it as FAT, and copy the user-data and meta-data files there.
# CIDATA is the standard label for cloud-init seed partitions
if [[ -n "$USER_DATA_PATH" ]]; then
  echo "Adding cloud-init CIDATA partition..."
  # Move backup GPT data structures to the end of the disk
  sgdisk -e "$TARGET_DEV"   
  # Create 64MB partition with type "Microsoft basic data" (0700) 
  # and label "CIDATA"
  # Microsoft basic data can hold FAT, NTFS, exFAT, etc. 
  # we will format it as FAT with command mkfs.vfat below.
  sgdisk -n 0:0:+64M -t 0:0700 -c 0:CIDATA "$TARGET_DEV" 
  # nofify kernel of partition table changes, 
  # but ignore errors since some kernels may not support this
  partprobe "$TARGET_DEV" || true
  udevadm settle || true

  # Find the newly created CIDATA partition 
  # by looking for a partition with that label on the target device.
  # exit if partition not found or device node doesn't exist.
  CIDATA_PART=""
  while read -r part label; do
    if [[ "$label" == "CIDATA" ]]; then
      CIDATA_PART="/dev/$part"
      break
    fi
  done < <(lsblk -ln -o NAME,PARTLABEL "$TARGET_DEV")

  if [[ -z "$CIDATA_PART" || ! -b "$CIDATA_PART" ]]; then
    echo "Error: could not find newly created CIDATA partition on $TARGET_DEV" >&2
    exit 1
  fi

  # Format the CIDATA partition as FAT 
  # and copy the user-data and meta-data files there.
  mkfs.vfat -n CIDATA "$CIDATA_PART"
  # Create a temporary mount point 
  TMP_MNT="$(mktemp -d)"
  # Use a trap to ensure we clean up the mount point 
  # and unmount if something goes wrong.
  trap 'umount "$TMP_MNT" 2>/dev/null || true; rmdir "$TMP_MNT" 2>/dev/null || true' EXIT
  # Mount the CIDATA partition, copy the files, and unmount.
  mount "$CIDATA_PART" "$TMP_MNT"
  cp "$USER_DATA_PATH" "$TMP_MNT/user-data"
  cp "$META_DATA_PATH" "$TMP_MNT/meta-data"
  sync
  umount "$TMP_MNT"
  rmdir "$TMP_MNT"
  trap - EXIT

  echo "cloud-init seed written to $CIDATA_PART"
fi

if [[ -n "$TMP_REMIX_ISO" && -f "$TMP_REMIX_ISO" ]]; then
  # Remove temporary remastered ISO artifact after writing USB.
  rm -f "$TMP_REMIX_ISO"
fi

echo
echo "Done. Bootable USB created on $TARGET_DEV."
