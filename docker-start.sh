#!/bin/bash

set -e

log() {
    echo -e "[$(date +%Y-%m-%d-%H:%M:%S)][frr] $*" >&2
}

# Load configuration from files only
log "Loading configuration from files..."

# Validate and load configuration
log "Validating configuration"
python3 /usr/local/bin/config_loader.py --validate || {
    log "Configuration validation failed"
    exit 1
}

log "Generating configuration context"
python3 /usr/local/bin/config_loader.py --json > /run/config.json
CONFIG_SOURCE="/run/config.json"

log "Configuration loaded from: ${CONFIG_SOURCE}"

FRR_TEMPLATE="/etc/frr/frr.conf.j2"
log "Using FRR template: ${FRR_TEMPLATE}"

log "Setting up network (Host Network Mode)"
# FRR runs in host network and uses BGP listen range to accept
# connections from Cilium (any IP in fd00::/8 with matching ASN).
log "Network setup complete (Option A - Host Network)."

# --- Filesystem Setup ---
# The rootfs is read-only. We need /etc/frr to be writable for config generation.
# We use a tmpfs overlay to avoid dependencies on the host filesystem.
log "Mounting tmpfs on /etc/frr"
mount -t tmpfs -o size=8M tmpfs /etc/frr

# Populate /etc/frr with default files from the image
if [ -d /etc/frr.defaults ]; then
    log "Populating /etc/frr from /etc/frr.defaults"
    cp -a /etc/frr.defaults/* /etc/frr/
else
    log "WARNING: /etc/frr.defaults not found, creating minimal setup"
    mkdir -p /etc/frr
fi

# --- Fix for FRR Daemons (Writable /var paths) ---
# FRR daemons need to write PID files, sockets, and logs.
# Since the rootfs is read-only, we mount tmpfs over these specific directories.
log "Mounting tmpfs for FRR runtime directories"
for dir in /var/run/frr /var/lib/frr /var/log/frr; do
    # Check if directory exists (it should in standard FRR images)
    if [ -d "$dir" ]; then
        log "Mounting tmpfs on $dir"
        mount -t tmpfs -o size=8M,noatime,mode=0755 tmpfs "$dir"
        chown frr:frr "$dir"
    else
        # If directory doesn't exist, try to create it (in case parent is writable)
        if mkdir -p "$dir" 2>/dev/null; then
            log "Created $dir, mounting tmpfs..."
            mount -t tmpfs -o size=8M,noatime,mode=0755 tmpfs "$dir"
            chown frr:frr "$dir"
        else
            log "WARNING: Directory $dir does not exist and cannot be created (parent read-only). Daemon startup may fail."
        fi
    fi
done

# Generate FRR configuration
log "Generating FRR configuration from template: ${FRR_TEMPLATE}"

# Use the JSON context from config_loader
python3 /usr/local/bin/render_template.py ${FRR_TEMPLATE} ${CONFIG_SOURCE} /etc/frr/frr.conf

log "Generated FRR configuration:"
cat /etc/frr/frr.conf

# Create vtysh.conf if it doesn't exist
[ -r /etc/frr/vtysh.conf ] || touch /etc/frr/vtysh.conf

# Set ownership
chown -R frr:frr /etc/frr || true

# Enable syslog
log "Starting syslogd"
syslogd -n -O - &

# Note: Writable directories are mounted from host via frr.yaml
# Host /run/frr-* → Container /var/{run,tmp,lib,log}/frr
# This works because host's /run is writable tmpfs

# Start FRR
log "Starting FRR daemons (including BFD if enabled)"
/usr/lib/frr/frrinit.sh start

# Wait for daemons to start
sleep 5

# Dump Cilium neighbor FSM state for troubleshooting
log "Dumping Cilium neighbor FSM state"
/usr/local/bin/dump-bgp-state.sh || true

# Check BFD status if configured
if grep -q "bfdd=true" /etc/frr/daemons 2>/dev/null; then
    log "Checking BFD daemon status"
    vtysh -c "show bfd peers" || true
fi

# Show process list
log "Current processes:"
ps -ef | grep -E "(bgpd|bfdd|zebra)" || true

# Monitoring loop with BFD status
MONITOR_INTERVAL=${MONITOR_INTERVAL:-60}
MONITOR_COUNT=${MONITOR_COUNT:-5}

count=0
while true; do
    if [ $count -lt ${MONITOR_COUNT} ]; then
        log "=== Status Check (${count}/${MONITOR_COUNT}) ==="

        # BGP status (MP-BGP includes both IPv4 and IPv6)
        vtysh -c "show bgp summary" || true

        # BFD status if configured
        if grep -q "bfdd=true" /etc/frr/daemons 2>/dev/null; then
            log "BFD Peer Status:"
            vtysh -c "show bfd peers brief" || true
        fi

        # Routing table
        vtysh -c "show ip route summary" || true

        if [ -n "${PEER_IPV6_REMOTE}" ]; then
            vtysh -c "show ipv6 route summary" || true
        fi

        count=$((count + 1))
    fi

    sleep ${MONITOR_INTERVAL}
done
