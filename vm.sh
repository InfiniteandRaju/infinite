#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# =============================

display_header() {
    clear
    cat << "EOF"
========================================================================
         _____ _   _ ______ ______ _  _  _____ _______  ______ 
        |_   _| \ | |  ____||_   _| \ | |_   _|__   __||  ____|
          | | |  \| | |__     | | |  \| | |    | |   | |__   
          | | | . ` |  __|    | | | . ` | |    | |   |  __|   
         _| |_| |\  | |      _| |_| |\  |_| |_   | |   | |____ 
        |_____|_| \_|_|     |_____|_| \_|_____|  |_|   |______|
                                                                      
                          POWERED BY INFINITE
========================================================================
EOF
    echo
}

print_status() {
    local type=$1
    local message=$2
    
    case $type in
        "INFO")    echo -e "\033[1;34m[INFO]\033[0m $message"    ;;
        "WARN")    echo -e "\033[1;33m[WARN]\033[0m $message"    ;;
        "ERROR")   echo -e "\033[1;31m[ERROR]\033[0m $message"   ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT")   echo -e "\033[1;36m[INPUT]\033[0m $message"   ;;
        *)         echo "[$type] $message"                       ;;
    esac
}

validate_input() {
    local type=$1
    local value=$2
    
    case $type in
        "number")
            [[ "$value" =~ ^[0-9]+$ ]] || { print_status "ERROR" "Must be a number"; return 1; }
            ;;
        "size")
            [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || { print_status "ERROR" "Must be size like 40G or 1024M"; return 1; }
            ;;
        "name")
            [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || { print_status "ERROR" "Invalid VM name"; return 1; }
            ;;
    esac

    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "virt-install" "wget" "cloud-localds" "genisoimage" "qemu-img")
    local missing=()

    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null || missing+=("$dep")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing: ${missing[*]}"
        print_status "INFO" "Install: sudo apt install qemu-system virt-install cloud-image-utils genisoimage wget"
        exit 1
    fi
}

cleanup() {
    rm -f user-data meta-data || true
}

declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12"
    ["Windows 10"]="windows|win10|manual|windows10"
    ["Windows Server"]="windows|winserver|manual|windowsserver"
)

VM_DIR="$HOME/vms"
mkdir -p "$VM_DIR"

main_menu() {
    display_header

    print_status "INFO" "Select an OS to install:"
    local i=1
    local options=()

    for name in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $name"
        options[$i]="$name"
        ((i++))
    done

    read -p "$(print_status 'INPUT' "Enter choice 1-${#options[@]}: ")" choice

    NAME="${options[$choice]}"
    IFS='|' read -r TYPE CODENAME IMG_URL VARIANT <<< "${OS_OPTIONS[$NAME]}"

    read -p "$(print_status 'INPUT' 'VM Name: ')" VM_NAME
    read -p "$(print_status 'INPUT' 'Memory (MB): ')" MEMORY
    read -p "$(print_status 'INPUT' 'CPU count: ')" CPUS
    read -p "$(print_status 'INPUT' 'Disk size (e.g., 40G): ')" DISK_SIZE

    validate_input name "$VM_NAME"
    validate_input number "$MEMORY"
    validate_input number "$CPUS"
    validate_input size "$DISK_SIZE"

    IMAGE="$VM_DIR/$VM_NAME.qcow2"

    if [[ "$TYPE" == "windows" ]]; then
        echo
        print_status "INFO" "Windows selected → user must enter ISO link"
        read -p "$(print_status 'INPUT' 'Enter Windows ISO download URL: ')" CUSTOM_ISO

        print_status "INFO" "Downloading Windows ISO..."
        wget -O "$VM_DIR/$VM_NAME.iso" "$CUSTOM_ISO"

        print_status "INFO" "Creating disk image..."
        qemu-img create -f qcow2 "$IMAGE" "$DISK_SIZE"

        print_status "INFO" "Starting Windows VM..."
        virt-install \
            --name "$VM_NAME" \
            --memory "$MEMORY" \
            --vcpus "$CPUS" \
            --disk "file=$IMAGE,format=qcow2" \
            --cdrom "$VM_DIR/$VM_NAME.iso" \
            --os-variant win10 \
            --network bridge=br0,model=virtio \
            --graphics vnc,listen=0.0.0.0 \
            --noautoconsole

        print_status "SUCCESS" "Windows VM created!"
        exit 0
    fi

    # Linux process
    print_status "INFO" "Downloading Linux cloud image..."
    wget -O "$IMAGE" "$IMG_URL"

    print_status "INFO" "Resizing disk..."
    qemu-img resize "$IMAGE" "$DISK_SIZE"

    cat > user-data <<EOF
#cloud-config
password: ubuntu
chpasswd: { expire: False }
ssh_pwauth: True
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $VM_NAME
EOF

    SEED="$VM_DIR/$VM_NAME-seed.iso"
    genisoimage -output "$SEED" -volid cidata -joliet -rock user-data meta-data

    print_status "INFO" "Launching Linux VM..."
    virt-install \
        --name "$VM_NAME" \
        --memory "$MEMORY" \
        --vcpus "$CPUS" \
        --disk "file=$IMAGE,bus=virtio" \
        --disk "file=$SEED,device=cdrom" \
        --os-variant "$VARIANT" \
        --network bridge=br0,model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --noautoconsole

    print_status "SUCCESS" "Linux VM created!"
}

trap cleanup EXIT
check_dependencies
main_menu
