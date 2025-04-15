#!/bin/bash

set -e

# --- Configuration ---
VMID=9000
VMNAME="coreos-latest"
COREDIR="/var/lib/vz/template/coreos"
IGN_URL="https://raw.githubusercontent.com/DarksideVT/homelab/refs/heads/main/coreos/default.ign"
DISK_SIZE="10G"
STREAM_URL="https://builds.coreos.fedoraproject.org/streams/stable.json"

# --- Get latest PXE URLs ---
echo "Fetching latest Fedora CoreOS PXE URLs..."
json=$(curl -s "$STREAM_URL")

KERNEL_URL=$(echo "$json" | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.kernel.location')
KERNEL_SHA256_URL=$(echo "$json" | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.kernel.sha256')
INITRD_URL=$(echo "$json" | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.initramfs.location')
INITRD_SHA256_URL=$(echo "$json" | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.initramfs.sha256')
ROOTFS_URL=$(echo "$json" | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')

if [[ -z "$KERNEL_URL" || -z "$INITRD_URL" ]]; then
  echo "Error: Could not parse PXE URLs from stream metadata"
  exit 1
fi

echo "Latest kernel: $KERNEL_URL"
echo "Latest initrd: $INITRD_URL"


# --- Prepare directory and download files ---
mkdir -p "$COREDIR"
cd "$COREDIR" || exit 1

# Check if the files already exist checking the hash
if [[ -f "vmlinuz" && -f "initrd.img" ]]; then
  echo "Files already exist, checking hashes..."
  if [[ "$(sha256sum vmlinuz | awk '{print $1}')" == "$(curl -s "$KERNEL_SHA256_URL")" && "$(sha256sum initrd.img | awk '{print $1}')" == "$(curl -s "$INITRD_SHA256_URL")" ]]; then
    echo "Files are up to date."
    exit 0
  else
    echo "Files are outdated, downloading new ones..."
  fi
else
  echo "Files do not exist, downloading..."
fi

echo "Downloading latest kernel and initrd..."
curl -L -o vmlinuz "$KERNEL_URL"
curl -L -o initrd.img "$INITRD_URL"

# --- Create or configure the VM ---
DISK_ID="vm-${VMID}-disk-0"
if ! qm status "$VMID" &>/dev/null; then
  echo "Creating VM $VMID..."
  qm create "$VMID" \
    --name "$VMNAME" \
    --memory 4096 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --boot order=scsi0 \
    --agent enabled=1 \
else
  echo "VM $VMID already exists."
fi

echo "Creating ZFS volume..."
zfs create -V $DISK_SIZE gohan/$DISK_ID

echo "Attaching volume to VM..."
qm set "$VMID" --scsi0 gohan:$DISK_ID
sleep 3

echo "Setting BIOS to OVMF and machine type to q35..."
qm set "$VMID" --bios ovmf

echo "Waiting for ZFS device /dev/zvol/gohan/$DISK_ID to be ready..."
for i in {1..20}; do
  if [[ -e "/dev/zvol/gohan/$DISK_ID" ]]; then
    echo "ZFS volume $DISK_ID is ready."
    break
  fi
  echo "Still waiting... ($i)"
  sleep 1
done

echo "Configuring kernel/initrd/ignition using args..."
qm set "$VMID" \
--args "-kernel $COREDIR/vmlinuz -initrd $COREDIR/initrd.img -append \"coreos.live.rootfs_url=$ROOTFS_URL console=ttyS0 ignition.firstboot ignition.platform.id=qemu ignition.config.url=${IGN_URL}\""
# Set the correct bois and machine type
# echo "Set the correct bois and machine type"
# qm set "$VMID" --bios ovmf --machine q35

echo "Starting the VM for initial Ignition provisioning..."
qm start "$VMID"

echo "Waiting for VM to shut down after provisioning..."
while qm status "$VMID" | grep -q "status: running"; do
  sleep 5
done

# # --- Convert disk to template ---
# echo "Converting disk to template..."
# qm template "$VMID"

# echo "✅ VM $VMID has been converted to a CoreOS template."
# echo "You can now clone it like so:"
# echo "  qm clone $VMID <new-vm-id> --name <new-name> --full"
