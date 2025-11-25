#!/bin/bash

# Setup throttled I/O directory with configurable delay
# Usage: ./setup-throttled-io.sh [delay_ms]
# Default delay is 5ms

set -e

DELAY_MS=${1:-5}
MOUNT_POINT="$HOME/throttled_io"
IMG_FILE="/tmp/throttled.img"
IMG_SIZE_MB=100
DM_NAME="throttled_io"
DM_DEVICE="/dev/mapper/$DM_NAME"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

cleanup_existing() {
    log_info "Cleaning up existing setup..."

    # Unmount if mounted
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Unmounting $MOUNT_POINT..."
        sudo umount "$MOUNT_POINT" || log_warn "Failed to unmount, may not be mounted"
    fi

    # Remove device mapper if exists
    if sudo dmsetup info "$DM_NAME" &>/dev/null; then
        log_info "Removing device mapper $DM_NAME..."
        sudo dmsetup remove "$DM_NAME" || log_warn "Failed to remove device mapper"
    fi

    # Detach loop device if attached
    if [ -f "$IMG_FILE" ]; then
        LOOP_DEV=$(sudo losetup -j "$IMG_FILE" 2>/dev/null | cut -d: -f1)
        if [ -n "$LOOP_DEV" ]; then
            log_info "Detaching loop device $LOOP_DEV..."
            sudo losetup -d "$LOOP_DEV" || log_warn "Failed to detach loop device"
        fi
    fi
}

create_image() {
    if [ ! -f "$IMG_FILE" ]; then
        log_info "Creating image file $IMG_FILE (${IMG_SIZE_MB}MB)..."
        sudo dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=progress
        sudo chmod 666 "$IMG_FILE"
    else
        log_info "Image file $IMG_FILE already exists"
    fi
}

setup_loop_device() {
    log_info "Setting up loop device..."
    
    # Check if already attached
    LOOP_DEV=$(sudo losetup -j "$IMG_FILE" 2>/dev/null | cut -d: -f1)
    
    if [ -z "$LOOP_DEV" ]; then
        LOOP_DEV=$(sudo losetup -f --show "$IMG_FILE")
        log_info "Created loop device: $LOOP_DEV"
    else
        log_info "Using existing loop device: $LOOP_DEV"
    fi
    
    echo "$LOOP_DEV"
}

format_if_needed() {
    local loop_dev=$1
    
    # Check if already formatted
    if ! sudo blkid "$loop_dev" &>/dev/null; then
        log_info "Formatting $loop_dev with ext4..."
        sudo mkfs.ext4 -F "$loop_dev"
    else
        log_info "Device $loop_dev already formatted"
    fi
}

create_throttled_device() {
    local loop_dev=$1
    local delay=$2
    
    log_info "Creating throttled device with ${delay}ms delay..."
    
    SIZE=$(sudo blockdev --getsz "$loop_dev")
    
    if [ -z "$SIZE" ] || [ "$SIZE" -eq 0 ]; then
        log_error "Failed to get device size"
        exit 1
    fi
    
    log_info "Device size: $SIZE sectors"
    
    # Create delay device mapper
    # Format: start_sector num_sectors delay underlying_device offset_sectors read_delay_ms [write_device write_offset write_delay_ms]
    echo "0 $SIZE delay $loop_dev 0 $delay $loop_dev 0 $delay" | sudo dmsetup create "$DM_NAME"
    
    log_info "Created device mapper: $DM_DEVICE"
}

mount_device() {
    log_info "Creating mount point $MOUNT_POINT..."
    mkdir -p "$MOUNT_POINT"
    
    log_info "Mounting $DM_DEVICE to $MOUNT_POINT..."
    sudo mount "$DM_DEVICE" "$MOUNT_POINT"
    
    log_info "Setting ownership to $USER..."
    sudo chown "$USER:$USER" "$MOUNT_POINT"
}

verify_setup() {
    log_info "Verifying setup..."
    
    if ! mountpoint -q "$MOUNT_POINT"; then
        log_error "Mount point verification failed"
        exit 1
    fi
    
    # Test write
    TEST_FILE="$MOUNT_POINT/.test_write_$$"
    if echo "test" > "$TEST_FILE" 2>/dev/null; then
        rm -f "$TEST_FILE"
        log_info "Write test passed"
    else
        log_error "Write test failed"
        exit 1
    fi
    
    log_info "Setup complete!"
    echo ""
    echo "=========================================="
    echo "Throttled I/O Directory: $MOUNT_POINT"
    echo "I/O Delay: ${DELAY_MS}ms (read and write)"
    echo "=========================================="
}

main() {
    echo "=========================================="
    echo "Throttled I/O Setup Script"
    echo "Delay: ${DELAY_MS}ms"
    echo "=========================================="
    echo ""
    
    # Check for root/sudo
    if ! sudo -v; then
        log_error "This script requires sudo privileges"
        exit 1
    fi
    
    # Check for required tools
    for cmd in losetup dmsetup blockdev mkfs.ext4; do
        if ! command -v $cmd &>/dev/null; then
            log_error "Required command '$cmd' not found"
            exit 1
        fi
    done
    
    cleanup_existing
    create_image
    
    LOOP_DEV=$(setup_loop_device)
    format_if_needed "$LOOP_DEV"
    create_throttled_device "$LOOP_DEV" "$DELAY_MS"
    mount_device
    verify_setup
}

main "$@"
