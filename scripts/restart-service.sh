#!/bin/bash
# Helper script to restart system services with root privileges
# Called by the web interface via sudoers.
# Only whitelisted services are allowed.

set -e

SERVICE="$1"

# Validate input
if [[ -z "$SERVICE" ]]; then
    echo "Error: Service name required" >&2
    exit 1
fi

# Whitelist of allowed services
ALLOWED_SERVICES=("cups" "avahi-daemon" "printserver-web")

VALID=false
for allowed in "${ALLOWED_SERVICES[@]}"; do
    if [[ "$SERVICE" == "$allowed" ]]; then
        VALID=true
        break
    fi
done

if [[ "$VALID" != "true" ]]; then
    echo "Error: Service '$SERVICE' is not allowed" >&2
    exit 1
fi

# Restart the service
systemctl restart "$SERVICE"

echo "Service '$SERVICE' restarted successfully"
exit 0
