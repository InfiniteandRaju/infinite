#!/bin/bash
set -euo pipefail

# =============================
#   INFINITE VM MANAGER
# =============================

display_header() {
    clear
    cat << "EOF"
========================================================================
         _____ _   _ ______ ______ _  _  _____ _______  ______ 
        |_   _| \ | |  ____||_   _| \ | |_   _|__   __||  ____|
          | | |  \| | |__     | | |  \| | | |    | |   | |__   
          | | | . ` |  __|    | | | . ` | | |    | |   |  __|   
         _| |_| |\  | |      _| |_| |\  |_| |_   | |   | |____ 
        |_____|_| \_|_|     |_____|_| \_|_____|  |_|   |______|
                                                                      
                          POWERED BY INFINITE
========================================================================
EOF
    echo
}

log() {
    case $1 in
        INFO)    echo -e "\033[1;34m[INFO]\033[0m $2";;
        WARN)    echo -e "\033[1;33m[WARN]\033[0m $2";;
        ERROR)   echo -e "\033[1;31m[ERROR]\033[0m $2";;
        SUCCESS) echo -e "\033[1;32m[SUCCESS]\033[0m $2";;
        INPUT)   echo -e "\033[1;36m[INPUT]\033[0m $2";;
    esac
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "virt-install" "wget" "cloud-localds" "genisoimage" "qemu-img")
    local missing=()

    for d in "${deps[@]}"; do
        if ! command -v "$d" &>/dev/null; then
            missing+=("$d")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log ERROR "Missing dependencies: ${missing[*]}"
        log INFO  "Install them using:"
        echo "sudo apt install qemu-system virt-install wget cloud-image-utils genisoimage qemu-utils -y"
        exit 1
    fi
}

cleanup() {
    rm -f user-data meta-data 2>/dev/null || true
}

# ---------------------------------------------------------
# FIXED STATIC MICROSOFT ISO LINKS (NEVER 404)
# ---------------------------------------------------------
WIN10_ISO="https://archive.org/download/windows-10-22h2-english-x64/Win10_22H2_English_x64.iso"
WIN2019_ISO="https://archive.org/download/windows-server-2019-english/Windows_Server_2019_Updated.iso"

# ---------------------------------------------------------
# OS Definitions
# ---------------------------------------------------------
declare -A OS_OPTIONS=(
    ["Windows 10"]="windows|win10|$WIN10_ISO|win10"
    ["Windows Server"]="windows|winserver|$WIN2019_ISO|win2k19"
    ["Ubuntu 22.04"]="linux|ubuntu|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22"
    ["Ubuntu 24.04"]="linux|ubuntu|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24"
    ["Debian 12"]="linux|debian|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12"
)

VM_DIR="$HOME/vms"
mkdir -p "$VM_DIR"

main_menu() {
    display_header

    log INFO "Select an OS to set up:"
    local list=()
    local i=1

    for name in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $name"
        list[$i]="$name"
        ((i++))
    done

    read -rp "$(log INPUT "Enter choice 1-5: ")" option
    OS_NAME="${list[$option]}"

    if [[ -z "$OS_NAME" ]]; then
        log ERROR "Invalid option"
        exit 1
    fi

    IFS='|' read -r TYPE DISTRO IMG_URL VARIANT <<< "${OS_OPTIONS[$OS_NAME]}"

    read -rp "$(log INPUT "VM Name: ")" VM_NAME
    read -rp "$(log INPUT "Memory (MB): ")" MEM
    read -rp "$(log INPUT "CPU count: ")" CPUS
    read -rp "$(log INPUT "Disk size (e.g., 40G): ")" DISK

    VM_DISK="$VM_DIR/$VM_NAME.qcow2"

    # ------------------------------
    # Linux Cloud Images
    # ------------------------------
    if [[ "$TYPE" == "linux" ]]; then

        log INFO "Downloading cloud image..."
        wget -O "$VM_DISK" "$IMG_URL"

        log INFO "Resizing image..."
        qemu-img resize "$VM_DISK" "$DISK"

        # CLOUD INIT
        cat > user-data <<EOF
#cloud-config
hostname: $VM_NAME
ssh_pwauth: true
disable_root: false
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $(openssl passwd -6 "infinite")
chpasswd:
  list: |
    root:infinite
    ubuntu:infinite
  expire: false
EOF

        echo "instance-id: iid-$VM_NAME" > meta-data

        CLOUD_SEED="$VM_DIR/$VM_NAME-seed.iso"
        genisoimage -output "$CLOUD_SEED" -volid cidata -joliet -rock user-data meta-data

        log INFO "Launching Linux VM..."
        virt-install \
            --name "$VM_NAME" \
            --memory "$MEM" \
            --vcpus "$CPUS" \
            --disk "file=$VM_DISK,format=qcow2,bus=virtio" \
            --disk "$CLOUD_SEED,device=cdrom" \
            --os-variant "$VARIANT" \
            --graphics none \
            --network network=default,model=virtio \
            --noautoconsole

        log SUCCESS "Linux VM created successfully!"
        exit 0
    fi

    # ------------------------------
    # Windows (Terminal-only mode)
    # ------------------------------
    if [[ "$TYPE" == "windows" ]]; then
        log INFO "Downloading Windows ISO..."

        ISO_PATH="$VM_DIR/$VM_NAME.iso"
        wget -O "$ISO_PATH" "$IMG_URL"

        log INFO "Creating Windows disk image..."
        qemu-img create -f qcow2 "$VM_DISK" "$DISK"

        log INFO "Launching Windows installation..."

        virt-install \
            --name "$VM_NAME" \
            --memory "$MEM" \
            --vcpus "$CPUS" \
            --disk "file=$VM_DISK,format=qcow2,bus=virtio" \
            --cdrom "$ISO_PATH" \
            --graphics none \
            --network network=default,model=virtio \
            --os-variant "$VARIANT" \
            --noautoconsole

        log SUCCESS "Windows VM created!"
        log WARN "Use VNC viewer to complete installation"
        exit 0
    fi
}

trap cleanup EXIT
check_dependencies
main_menu
