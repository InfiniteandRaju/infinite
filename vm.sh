#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# =============================

display_header() {
    clear
    cat << "EOF"
========================================================================
  _    _  ____  _____ _____ _   _  _____ ____   ______     ________
 | |  | |/ __ \|  __ \_   _| \ | |/ ____|  _ \ / __ \ \   / /___  /
 | |__| | |  | | |__) || | | \  | |  __| |_) | |  | \ \_/ /   / /
 |  __  | |  | |  ___/ | | |   \ | | |_ |  _ <| |  | |\   /   / /
 | |  | | |__| | |    _| |_| |\  | |__| | |_) | |__| | | |   / /__
 |_|  |_|\____/|_|   |_____|_| \_|\_____|____/ \____/  |_|  /_____|
                                                                  
                    POWERED BY HOPINGBOYZ
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
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore, and contain only letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
    esac
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "virt-install" "wget" "cloud-localds" "genisoimage" "qemu-img")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "On Ubuntu/Debian: sudo apt install qemu-system virt-install wget cloud-image-utils genisoimage"
        exit 1
    fi
}

cleanup() {
    if [ -f "user-data" ]; then rm -f "user-data"; fi
    if [ -f "meta-data" ]; then rm -f "meta-data"; fi
}

# OS list for menu
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
    
    print_status "INFO" "Select an OS to set up:"
    local options=()
    local i=1
    for name in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $name"
        options[$i]="$name"
        ((i++))
    done

    read -p "$(print_status "INPUT" "Enter choice 1-${#options[@]}: ")" opt
    if ! [[ "$opt" =~ ^[0-9]+$ ]] || [ "$opt" -lt 1 ] || [ "$opt" -gt ${#options[@]} ]; then
        print_status "ERROR" "Invalid option"
        exit 1
    fi

    NAME="${options[$opt]}"
    IFS='|' read -r TYPE CODENAME IMG_URL VARIANT DEFAULT_USER DEFAULT_PASS <<< "${OS_OPTIONS[$NAME]}"

    # Ask for VM specifics
    read -p "$(print_status "INPUT" "VM Name: ")" VM_NAME
    read -p "$(print_status "INPUT" "Memory in MB (e.g., 2048): ")" MEMORY
    read -p "$(print_status "INPUT" "CPU count (e.g., 2): ")" CPUS
    read -p "$(print_status "INPUT" "Disk size (e.g., 20G): ")" DISK_SIZE

    validate_input number "$MEMORY" || exit 1
    validate_input number "$CPUS"    || exit 1
    validate_input size   "$DISK_SIZE"|| exit 1
    validate_input name   "$VM_NAME"  || exit 1

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    if [[ "$TYPE" == "ubuntu" || "$TYPE" == "debian" ]]; then
        # linux cloud-image path
        print_status "INFO" "Using cloud-image: $IMG_URL"
        wget -O "$IMG_FILE" "$IMG_URL"

        # resize
        print_status "INFO" "Resizing disk image to $DISK_SIZE"
        qemu-img resize "$IMG_FILE" "$DISK_SIZE"

        # create seed
        cat > user-data <<EOF
#cloud-config
hostname: $VM_NAME
ssh_pwauth: true
disable_root: false
users:
  - name: ${DEFAULT_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $(openssl passwd -6 "$DEFAULT_PASS")
chpasswd:
  list: |
    root:$DEFAULT_PASS
    ${DEFAULT_USER}:$DEFAULT_PASS
  expire: false
EOF

        cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $VM_NAME
EOF

        genisoimage -output "$SEED_FILE" -volid cidata -joliet -rock user-data meta-data

        print_status "INFO" "Launching VM (Linux Cloud-Init)"
        virt-install \
          --name "$VM_NAME" \
          --memory "$MEMORY" \
          --vcpus "$CPUS" \
          --disk "file=$IMG_FILE,format=qcow2,bus=virtio" \
          --disk "file=$SEED_FILE,format=raw,if=virtio,device=cdrom" \
          --os-variant "$VARIANT" \
          --network bridge=br0,model=virtio \
          --graphics vnc,listen=0.0.0.0 \
          --noautoconsole

        print_status "SUCCESS" "VM $VM_NAME created (type: $NAME)"
        exit 0

    elif [[ "$TYPE" == "windows" ]]; then
        # Windows path using ISO
        print_status "INFO" "Using ISO: $IMG_URL"
        ISO_PATH="$IMG_URL"
        VIRTIO_ISO="$IMAGES/virtio-win.iso"  # ensure you have this

        print_status "INFO" "Launching VM (Windows)"
        virt-install \
          --name "$VM_NAME" \
          --memory "$MEMORY" \
          --vcpus "$CPUS" \
          --disk "file=$VM_DIR/$VM_NAME.qcow2,format=qcow2,bus=virtio" \
          --cdrom "$ISO_PATH" \
          --disk "file=$VIRTIO_ISO,device=cdrom" \
          --os-variant "$VARIANT" \
          --network bridge=br0,model=virtio \
          --graphics vnc,listen=0.0.0.0 \
          --noautoconsole

        print_status "SUCCESS" "VM $VM_NAME created (Windows: $NAME)"
        print_status "WARN" "During Windows setup: click 'Load Driver' and point to VirtIO drivers from CD."
        exit 0

    else
        print_status "ERROR" "Unsupported OS type: $TYPE"
        exit 1
    fi
}

trap cleanup EXIT
check_dependencies
main_menu
