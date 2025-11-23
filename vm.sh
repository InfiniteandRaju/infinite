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
          | | |  \| | |__     | | |  \| | | |    | |   | |__   
          | | | . ` |  __|    | | | . ` | | |    | |   |  __|   
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
        "INFO")    echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN")    echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR")   echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT")   echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *)         echo "[$type] $message" ;;
    esac
}

validate_input() {
    local type=$1
    local value=$2
    
    case $type in
        "number")
            [[ "$value" =~ ^[0-9]+$ ]] || { print_status ERROR "Must be a number"; return 1; }
            ;;
        "size")
            [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || { print_status ERROR "Size must include G or M (e.g., 40G)"; return 1; }
            ;;
        "name")
            [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || { print_status ERROR "Invalid VM name"; return 1; }
            ;;
    esac
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "virt-install" "wget" "cloud-localds" "genisoimage" "qemu-img")
    local missing=()

    for d in "${deps[@]}"; do
        command -v "$d" >/dev/null 2>&1 || missing+=("$d")
    done

    if (( ${#missing[@]} > 0 )); then
        print_status ERROR "Missing dependencies: ${missing[*]}"
        print_status INFO "Install on Ubuntu/Debian:"
        echo "sudo apt install qemu-system virt-install wget cloud-image-utils genisoimage qemu-utils"
        exit 1
    fi
}

cleanup() {
    rm -f user-data meta-data 2>/dev/null || true
}

# List OS Options
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Windows 10"]="windows|win10|https://software-download.microsoft.com/db/Win10_22H2_English_x64.iso|win10|Administrator|Admin123"
    ["Windows Server"]="windows|winserver|https://software-download.microsoft.com/pr/Windows_Server_2019_Updated_Dec_2021.iso|win2k19|Administrator|Admin123"
)

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

main_menu() {
    display_header

    print_status INFO "Select an OS to set up:"
    local options=()
    local i=1
    for k in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $k"
        options[$i]="$k"
        ((i++))
    done

    read -p "$(print_status INPUT "Enter choice 1-${#options[@]}: ")" opt
    NAME="${options[$opt]}"

    IFS='|' read -r TYPE CODENAME IMG_URL VARIANT DEFAULT_USER DEFAULT_PASS <<< "${OS_OPTIONS[$NAME]}"

    read -p "$(print_status INPUT "VM Name: ")" VM_NAME
    read -p "$(print_status INPUT "Memory (MB): ")" MEMORY
    read -p "$(print_status INPUT "CPU count: ")" CPUS
    read -p "$(print_status INPUT "Disk size (e.g., 40G): ")" DISK_SIZE

    validate_input name "$VM_NAME"
    validate_input number "$MEMORY"
    validate_input number "$CPUS"
    validate_input size "$DISK_SIZE"

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    ISO_FILE="$VM_DIR/$VM_NAME.iso"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"

    if [[ "$TYPE" == "ubuntu" || "$TYPE" == "debian" ]]; then
        print_status INFO "Downloading cloud-image..."
        wget -O "$IMG_FILE" "$IMG_URL"

        print_status INFO "Resizing disk..."
        qemu-img resize "$IMG_FILE" "$DISK_SIZE"

        # Cloud-init config
        cat > user-data <<EOF
#cloud-config
hostname: $VM_NAME
ssh_pwauth: true
disable_root: false
users:
  - name: $DEFAULT_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $(openssl passwd -6 "$DEFAULT_PASS")
chpasswd:
  list: |
    root:$DEFAULT_PASS
    $DEFAULT_USER:$DEFAULT_PASS
  expire: false
EOF

        cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $VM_NAME
EOF

        genisoimage -output "$SEED_FILE" -volid cidata -joliet -rock user-data meta-data

        print_status INFO "Launching Linux VM..."
        virt-install \
            --name "$VM_NAME" \
            --memory "$MEMORY" \
            --vcpus "$CPUS" \
            --disk "file=$IMG_FILE,format=qcow2,bus=virtio" \
            --disk "file=$SEED_FILE,device=cdrom" \
            --os-variant "$VARIANT" \
            --network bridge=br0,model=virtio \
            --graphics vnc,listen=0.0.0.0 \
            --noautoconsole

        print_status SUCCESS "$VM_NAME created successfully!"
        exit 0
    fi

    # ============ WINDOWS MODE ===============
    if [[ "$TYPE" == "windows" ]]; then
        print_status INFO "Downloading Windows ISO..."
        wget -O "$ISO_FILE" "$IMG_URL"

        VIRTIO_ISO="$VM_DIR/virtio-win.iso"
        if [ ! -f "$VIRTIO_ISO" ]; then
            print_status INFO "Downloading VirtIO drivers..."
            wget -O "$VIRTIO_ISO" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
        fi

        print_status INFO "Creating Windows disk..."
        qemu-img create -f qcow2 "$VM_DIR/$VM_NAME.qcow2" "$DISK_SIZE"

        print_status INFO "Launching Windows VM..."
        virt-install \
            --name "$VM_NAME" \
            --memory "$MEMORY" \
            --vcpus "$CPUS" \
            --disk "file=$VM_DIR/$VM_NAME.qcow2,format=qcow2,bus=virtio" \
            --disk "file=$ISO_FILE,device=cdrom" \
            --disk "file=$VIRTIO_ISO,device=cdrom" \
            --os-variant "$VARIANT" \
            --network bridge=br0,model=virtio \
            --graphics vnc,listen=0.0.0.0 \
            --noautoconsole

        print_status SUCCESS "Windows VM created! Connect using VNC."
        exit 0
    fi
}

trap cleanup EXIT
check_dependencies
main_menu
