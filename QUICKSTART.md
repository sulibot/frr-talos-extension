# FRR Talos Extension - Quick Start Guide

This guide will help you get BGP routing working on your Talos cluster in 15 minutes.

## Prerequisites

- Talos Linux cluster (or single node)
- Access to an upstream BGP router
- Basic understanding of BGP concepts (ASN, router ID, neighbors)

## What You'll Accomplish

By the end of this guide, your Talos nodes will:
- Peer with your upstream router via BGP
- Receive default routes (0.0.0.0/0 and ::/0)
- Have working internet connectivity via BGP

## Step 1: Gather Required Information

You need these details:

| Parameter | Example | Description |
|-----------|---------|-------------|
| **Your ASN** | `65001` | Your BGP Autonomous System Number |
| **Upstream ASN** | `65000` | Your router's BGP ASN |
| **Node Router ID** | `10.255.101.11` | IPv4 address for BGP router ID (usually loopback) |
| **Upstream Neighbor** | `fe80::%ens18` | Link-local IPv6 of upstream router on your interface |
| **Network Interface** | `ens18` | Your node's network interface facing the router |

**Finding your upstream router's link-local address:**
```bash
# From your router or Talos node:
ip -6 neigh show dev ens18 | grep fe80
```

## Step 2: Choose Your Installation Method

### Option A: Using Terraform (Recommended)

Best for: Multiple nodes, infrastructure-as-code, reproducible deployments

**Pros:**
- Per-node configuration automatic
- Easy to manage multiple clusters
- Config changes tracked in git
- No manual YAML editing

**Cons:**
- Requires Terraform/OpenTofu knowledge
- Initial setup more complex

→ [Continue to Terraform Setup](#terraform-setup)

### Option B: Manual YAML Configuration

Best for: Single node, testing, learning, no Terraform

**Pros:**
- Simple, direct approach
- No additional tools required
- Easy to understand

**Cons:**
- Manual per-node configuration
- Harder to scale to multiple nodes
- Config changes require manual editing

→ [Continue to Manual Setup](#manual-setup)

---

## Terraform Setup

### Prerequisites
- Terraform or OpenTofu installed
- Custom Talos installer build capability

### 1. Add Extension to Install Schematic

Create or edit `install-schematic.hcl`:

```hcl
# terraform/install-schematic.hcl
install_custom_extensions = [
  "ghcr.io/sulibot/frr-talos-extension:latest",
]
```

### 2. Build Custom Installer

```bash
cd terraform/talos-installer-build
terragrunt apply
```

This builds a Talos installer image with the FRR extension included. Takes ~5 minutes.

### 3. Create FRR Configuration Template

Create `frr.conf.j2` in your Terraform module:

```jinja2
! FRR Configuration for ${hostname}
frr version 10.2
frr defaults datacenter
hostname ${hostname}
log syslog informational
service integrated-vtysh-config
!
! Import only default routes from upstream
ipv6 prefix-list DEFAULT-ONLY-v6 seq 10 permit ::/0
ip prefix-list DEFAULT-ONLY-v4 seq 10 permit 0.0.0.0/0
!
route-map IMPORT-DEFAULT-v4 permit 10
 match ip address prefix-list DEFAULT-ONLY-v4
exit
route-map IMPORT-DEFAULT-v4 deny 90
exit
!
route-map IMPORT-DEFAULT-v6 permit 10
 match ipv6 address prefix-list DEFAULT-ONLY-v6
exit
route-map IMPORT-DEFAULT-v6 deny 90
exit
!
! BGP Configuration
router bgp ${local_asn}
 bgp router-id ${router_id}
 no bgp default ipv4-unicast
 bgp graceful-restart
 !
 neighbor fe80::%ens18 remote-as ${remote_asn}
 !
 address-family ipv4 unicast
  neighbor fe80::%ens18 activate
  neighbor fe80::%ens18 route-map IMPORT-DEFAULT-v4 in
  neighbor fe80::%ens18 extended-nexthop
 exit-address-family
 !
 address-family ipv6 unicast
  neighbor fe80::%ens18 activate
  neighbor fe80::%ens18 route-map IMPORT-DEFAULT-v6 in
 exit-address-family
exit
!
line vty
!
```

### 4. Add to Talos Config Module

In your `talos_config` module's `main.tf`:

```hcl
locals {
  # Render FRR config per node
  frr_configs = {
    for node_name, node in local.all_nodes : node_name => templatefile("${path.module}/frr.conf.j2", {
      hostname   = node.hostname
      router_id  = node.loopback_ipv4  # e.g., "10.255.101.11"
      local_asn  = 65001               # Your ASN
      remote_asn = 65000               # Upstream router ASN
    })
  }

  machine_configs = {
    for node_name, node in local.all_nodes : node_name => {
      config_patch = join("\n---\n", [
        # ... your existing machine config ...
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "ExtensionServiceConfig"
          name       = "frr"
          configFiles = [
            {
              content   = local.frr_configs[node_name]
              mountPath = "/usr/local/etc/frr/frr.conf"
            },
            {
              content   = "zebra=true\nzebra_options=\"-n -A 127.0.0.1\"\nbgpd=true\nbgpd_options=\"-A 127.0.0.1\"\nstaticd=true\nstaticd_options=\"-A 127.0.0.1\""
              mountPath = "/usr/local/etc/frr/daemons"
            },
            {
              content   = "service integrated-vtysh-config\nhostname ${node.hostname}"
              mountPath = "/usr/local/etc/frr/vtysh.conf"
            }
          ]
        })
      ])
    }
  }
}
```

### 5. Generate and Apply Configs

```bash
# Generate machine configs
cd terraform/cluster-101/machine-config-generate
terragrunt apply

# Bootstrap or apply to nodes
talosctl apply-config --file outputs/node01.yaml --nodes node01
```

### 6. Verify BGP Session

```bash
# Check FRR service
talosctl -n node01 service frr status

# Check BGP neighbors
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh -c "show bgp summary"

# Check routes
talosctl -n node01 get routes
```

✅ **Success!** If you see BGP state = Established and routes learned, you're done!

---

## Manual Setup

### 1. Create Machine Config with Extension

Create a file `node01-config.yaml`:

```yaml
version: v1alpha1
machine:
  install:
    extensions:
      - image: ghcr.io/sulibot/frr-talos-extension:latest
  network:
    hostname: node01
    interfaces:
      - interface: ens18
        addresses:
          - 192.168.1.11/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.1.1  # Temporary until BGP takes over
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: frr
configFiles:
  - content: |
      ! FRR Configuration for node01
      frr version 10.2
      frr defaults datacenter
      hostname node01
      log syslog informational
      service integrated-vtysh-config
      !
      ! Import only default routes
      ipv6 prefix-list DEFAULT-ONLY-v6 seq 10 permit ::/0
      ip prefix-list DEFAULT-ONLY-v4 seq 10 permit 0.0.0.0/0
      !
      route-map IMPORT-DEFAULT-v4 permit 10
       match ip address prefix-list DEFAULT-ONLY-v4
      exit
      route-map IMPORT-DEFAULT-v4 deny 90
      exit
      !
      route-map IMPORT-DEFAULT-v6 permit 10
       match ipv6 address prefix-list DEFAULT-ONLY-v6
      exit
      route-map IMPORT-DEFAULT-v6 deny 90
      exit
      !
      ! BGP Configuration
      router bgp 65001
       bgp router-id 10.255.101.11
       no bgp default ipv4-unicast
       bgp graceful-restart
       !
       neighbor fe80::%ens18 remote-as 65000
       !
       address-family ipv4 unicast
        neighbor fe80::%ens18 activate
        neighbor fe80::%ens18 route-map IMPORT-DEFAULT-v4 in
        neighbor fe80::%ens18 extended-nexthop
       exit-address-family
       !
       address-family ipv6 unicast
        neighbor fe80::%ens18 activate
        neighbor fe80::%ens18 route-map IMPORT-DEFAULT-v6 in
       exit-address-family
      exit
      !
      line vty
      !
    mountPath: /usr/local/etc/frr/frr.conf
  - content: |
      zebra=true
      zebra_options="-n -A 127.0.0.1"
      bgpd=true
      bgpd_options="-A 127.0.0.1"
      staticd=true
      staticd_options="-A 127.0.0.1"
    mountPath: /usr/local/etc/frr/daemons
  - content: |
      service integrated-vtysh-config
      hostname node01
    mountPath: /usr/local/etc/frr/vtysh.conf
```

**Important:** Replace these values:
- `65001` → Your BGP ASN
- `65000` → Upstream router's ASN
- `10.255.101.11` → Your node's router ID (loopback IP)
- `ens18` → Your network interface
- `192.168.1.11/24` → Your node's IP address
- `192.168.1.1` → Your temporary gateway

### 2. Apply Configuration

```bash
talosctl apply-config --file node01-config.yaml --nodes node01
```

### 3. Wait for Bootstrap

The node will reboot and install the FRR extension. This takes 2-5 minutes.

### 4. Verify BGP Session

```bash
# Wait for node to be ready
talosctl -n node01 health

# Check FRR service
talosctl -n node01 service frr status

# Check BGP neighbors (should show "Established")
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh -c "show bgp summary"

# Check if routes are received
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh -c "show ip bgp"
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh -c "show ipv6 bgp"

# Verify kernel routing table
talosctl -n node01 get routes
```

### 5. Test Connectivity

```bash
# Ping internet via BGP-learned routes
talosctl -n node01 exec -- ping -c 3 1.1.1.1
talosctl -n node01 exec -- ping6 -c 3 2606:4700:4700::1111
```

✅ **Success!** If pings work, BGP is functioning correctly!

---

## Troubleshooting

### BGP Neighbor Shows "Active" Instead of "Established"

**Cause:** Cannot reach upstream router

**Fix:**
```bash
# Test link-local connectivity (replace with your router's link-local)
talosctl -n node01 exec -- ping6 -c 3 -I ens18 fe80::1

# Check for firewall rules blocking BGP (port 179)
talosctl -n node01 exec -- tcpdump -i ens18 port 179
```

### BGP Neighbor Shows "Idle"

**Cause:** FRR not running or misconfigured

**Fix:**
```bash
# Check service status
talosctl -n node01 service frr status

# View FRR logs
talosctl -n node01 logs system/frr

# Check config syntax
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh -c "show running-config"
```

### BGP Establishes But No Routes Received

**Cause:** Route map filtering all routes or upstream not advertising

**Fix:**
```bash
# Check what routes peer is advertising
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh -c "show ip bgp neighbors <neighbor-ip> advertised-routes"

# Check what routes are being filtered
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh -c "show ip bgp neighbors <neighbor-ip> routes"

# Temporarily remove route-map to test
# Edit your config, remove route-map lines, reapply
```

### Routes Received but Not in Kernel

**Cause:** Zebra (kernel interface) not running

**Fix:**
```bash
# Check daemons config
talosctl -n node01 read /usr/local/etc/frr/daemons

# Should show: zebra=true and bgpd=true

# Restart FRR
talosctl -n node01 service frr restart
```

## Next Steps

### Add BFD for Fast Failover

Add to your `frr.conf` before `router bgp`:

```
bfd
 profile fast
  detect-multiplier 3
  receive-interval 300
  transmit-interval 300
 exit
exit
!
router bgp 65001
 neighbor fe80::%ens18 bfd
 neighbor fe80::%ens18 bfd profile fast
```

BFD detects link failures in ~900ms instead of ~90 seconds with BGP keepalives.

### Advertise Loopback Networks

Add to your `frr.conf`:

```
ip prefix-list LOOPBACKS seq 10 permit 10.255.0.0/16 ge 32
!
route-map ADVERTISE-LOOPBACKS permit 10
 match ip address prefix-list LOOPBACKS
exit
!
router bgp 65001
 address-family ipv4 unicast
  neighbor fe80::%ens18 route-map ADVERTISE-LOOPBACKS out
 exit-address-family
```

### Add Multiple Peers

```
router bgp 65001
 neighbor fe80::%ens18 remote-as 65000
 neighbor fe80::%ens19 remote-as 65000  # Second uplink
 neighbor 192.168.1.1 remote-as 65002   # Different peer
```

## Getting Help

- **FRR Documentation:** https://docs.frrouting.org/en/latest/bgp.html
- **GitHub Issues:** https://github.com/sulibot/frr-talos-extension/issues
- **Talos Documentation:** https://www.talos.dev/

## Summary

You now have:
- ✅ FRR extension installed on Talos
- ✅ BGP peering with upstream router
- ✅ Default routes learned via BGP
- ✅ Working internet connectivity

Your configuration is:
- **Immutable** - Extension image never needs rebuilding
- **Version controlled** - Config is code in git
- **Updatable** - Change config and `talosctl apply-config`

Happy routing! 🎉
