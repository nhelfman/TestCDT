# a script to set up a throttled I/O device using dmsetup
# This script creates a loop device, formats it, sets up a throttled I/O device with a specified delay
DELAY=50

# Remove existing device (if exists)
if mountpoint -q ~/throttled_io 2>/dev/null; then
    echo "Unmounting ~/throttled_io..."
    if sudo umount ~/throttled_io; then
        echo "Successfully unmounted ~/throttled_io"
    else
        echo "Error: Failed to unmount ~/throttled_io"
        exit 1
    fi
else
    echo "Skipping unmount: ~/throttled_io is not mounted"
fi

if sudo dmsetup info throttled_io &>/dev/null; then
    echo "Removing device-mapper device 'throttled_io'..."
    if sudo dmsetup remove throttled_io; then
        echo "Successfully removed device-mapper device 'throttled_io'"
    else
        echo "Error: Failed to remove device-mapper device 'throttled_io'"
        exit 1
    fi
else
    echo "Skipping dmsetup remove: device 'throttled_io' does not exist"
fi

# Get the loop device and size
LOOP_DEV=$(sudo losetup -j /tmp/throttled.img 2>/dev/null | cut -d: -f1)

if [ -z "$LOOP_DEV" ]; then
    echo "No existing loop device found for /tmp/throttled.img, creating new one..."
    # Create the image file if it doesn't exist
    if [ ! -f /tmp/throttled.img ]; then
        echo "Creating /tmp/throttled.img..."
        if sudo dd if=/dev/zero of=/tmp/throttled.img bs=1M count=100 status=progress; then
            echo "Successfully created /tmp/throttled.img"
        else
            echo "Error: Failed to create /tmp/throttled.img"
            exit 1
        fi
    fi
    # Set up the loop device
    echo "Setting up loop device..."
    if LOOP_DEV=$(sudo losetup --find --show /tmp/throttled.img); then
        echo "Successfully created loop device: $LOOP_DEV"
    else
        echo "Error: Failed to create loop device"
        exit 1
    fi
    NEED_FORMAT=true
else
    echo "Found existing loop device: $LOOP_DEV"
    # Check if filesystem exists on the device
    if ! sudo blkid "$LOOP_DEV" &>/dev/null; then
        echo "No filesystem detected on $LOOP_DEV"
        NEED_FORMAT=true
    else
        NEED_FORMAT=false
    fi
fi

# Format the device if needed
if [ "$NEED_FORMAT" = true ]; then
    echo "Formatting $LOOP_DEV with ext4 filesystem..."
    if sudo mkfs.ext4 -F "$LOOP_DEV"; then
        echo "Successfully formatted $LOOP_DEV"
    else
        echo "Error: Failed to format $LOOP_DEV"
        exit 1
    fi
fi

echo "Getting device size..."
if SIZE=$(sudo blockdev --getsz "$LOOP_DEV"); then
    echo "Device size: $SIZE sectors"
else
    echo "Error: Failed to get device size for $LOOP_DEV"
    exit 1
fi

# Set delay in io reads
echo "Creating throttled I/O device with ${DELAY}ms delay..."
if echo "0 $SIZE delay $LOOP_DEV 0 $DELAY $LOOP_DEV 0 $DELAY" | sudo dmsetup create throttled_io; then
    echo "Successfully created throttled I/O device"
else
    echo "Error: Failed to create throttled I/O device"
    exit 1
fi

# Create mount point if it doesn't exist
if [ ! -d ~/throttled_io ]; then
    echo "Creating mount point ~/throttled_io..."
    if mkdir -p ~/throttled_io; then
        echo "Successfully created mount point"
    else
        echo "Error: Failed to create mount point ~/throttled_io"
        exit 1
    fi
fi

# Remount
echo "Mounting /dev/mapper/throttled_io to ~/throttled_io..."
if sudo mount /dev/mapper/throttled_io ~/throttled_io; then
    echo "Successfully mounted throttled I/O device"
else
    echo "Error: Failed to mount throttled I/O device"
    exit 1
fi

echo "Setting ownership to $USER..."
if sudo chown "$USER:$USER" ~/throttled_io; then
    echo "Successfully set ownership"
else
    echo "Error: Failed to set ownership"
    exit 1
fi

echo "Throttled I/O setup complete!"