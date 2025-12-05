# FRR Diagnostic Scripts

These scripts provide quick access to common FRR vtysh commands for troubleshooting and monitoring.

## Usage with Talos

Call these scripts via talosctl:

```bash
# Show BGP summary
talosctl --nodes <node> read /usr/local/bin/frr-scripts/bgp-summary | sh

# Or use exec to run directly in the container
talosctl --nodes <node> service ext-frr
# Then get the container ID and:
talosctl --nodes <node> exec -- ctr -n services t exec -t --exec-id diag ext-frr /usr/local/bin/frr-scripts/bgp-summary
```

## Available Scripts

### bgp-summary
Quick BGP status overview for all VRFs
```bash
/usr/local/bin/frr-scripts/bgp-summary
```

### bgp-neighbors
Detailed information about BGP neighbors (IPv4 and IPv6)
```bash
/usr/local/bin/frr-scripts/bgp-neighbors
```

### bgp-routes-adv
Show routes being advertised to BGP neighbors
```bash
/usr/local/bin/frr-scripts/bgp-routes-adv
```

### bgp-routes-recv
Show routes received from BGP neighbors
```bash
/usr/local/bin/frr-scripts/bgp-routes-recv
```

### show-config
Display current running FRR configuration
```bash
/usr/local/bin/frr-scripts/show-config
```

### route-summary
Summary of routing tables (IPv4, IPv6, VRF)
```bash
/usr/local/bin/frr-scripts/route-summary
```

### bfd-status
BFD peer status (brief and detailed)
```bash
/usr/local/bin/frr-scripts/bfd-status
```

### bgp-full-status
Complete diagnostic report with all BGP and routing information
```bash
/usr/local/bin/frr-scripts/bgp-full-status
```

## Automatic Monitoring

The FRR container automatically runs comprehensive status checks every 5 minutes for the first 5 cycles (25 minutes total). These checks include:

- BGP summary and neighbor details
- Routes advertised/received
- Running configuration
- BFD status (if enabled)
- Routing table summaries
- VRF status

You can grep the logs for specific sections:
```bash
talosctl --nodes <node> logs ext-frr | grep "BGP Summary" -A 20
talosctl --nodes <node> logs ext-frr | grep "Routes Advertised" -A 50
```
