#!/bin/bash
# Helper script to set hostname with root privileges
# This script is called by the web interface to change the system hostname
# It should be owned by root and have setuid permissions

set -e

NEW_HOSTNAME="$1"

# Validate input
if [[ -z "$NEW_HOSTNAME" ]]; then
    echo "Error: Hostname cannot be empty" >&2
    exit 1
fi

# Validate hostname format (RFC 1123)
if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Error: Invalid hostname format" >&2
    exit 1
fi

# Check for reserved names
if [[ "${NEW_HOSTNAME,,}" == "localhost" ]] || [[ "${NEW_HOSTNAME,,}" == "localhost.localdomain" ]]; then
    echo "Error: Reserved hostname" >&2
    exit 1
fi

# Get old hostname before changing
OLD_HOSTNAME=$(hostname)

# Set hostname using hostnamectl
hostnamectl set-hostname "$NEW_HOSTNAME"

# Update /etc/hostname
echo "$NEW_HOSTNAME" > /etc/hostname

# Update /etc/hosts - replace old hostname entry or add new one
if grep -q "127.0.1.1" /etc/hosts; then
    # Replace existing 127.0.1.1 line
    sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
else
    # Add new entry
    echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
fi

# Restart Avahi to broadcast new hostname
systemctl restart avahi-daemon 2>/dev/null || true

echo "Hostname changed from '$OLD_HOSTNAME' to '$NEW_HOSTNAME'"
exit 0
