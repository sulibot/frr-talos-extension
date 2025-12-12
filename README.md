# FRR Talos System Extension

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

BGP routing for Talos Linux with dynamic configuration via native `frr.conf` templates.

**🚀 New User?** → **[Read the Quick Start Guide](QUICKSTART.md)** for step-by-step setup instructions!

## Table of Contents

- [Overview](#overview)
- [Why frr.conf?](#why-frrconf)
- [Quick Start (Terraform)](#quick-start)
- [Usage Without Terraform](#usage-without-terraform)
- [Common FRR Configuration Examples](#common-frr-configuration-examples)
- [Troubleshooting](#troubleshooting)
- [Cilium Integration](#cilium-integration-optional)
- [Examples & Documentation](#examples)

## Acknowledgments

This project is based on work by:
- [jsenecal/frr-talos-extension](https://github.com/jsenecal/frr-talos-extension) by Jonathan Senecal
- [abckey/frr-talos-extension](https://github.com/abckey/frr-talos-extension) by Kai Zhang

## Overview

This FRR extension provides BGP routing capabilities for Talos Linux nodes with a **no-rebuild configuration model**:

- **Native frr.conf is the source of truth** - use FRR's native configuration syntax
- **Configuration is data** - delivered via Talos ExtensionServiceConfig
- **Extension image is immutable** - no rebuilds required for config changes
- **Terraform-friendly** - render configs from templates and apply via Talos

## Why frr.conf?

This extension uses native FRR configuration format (`frr.conf`) instead of structured YAML for several reasons:

1. **Full FRR feature support** - Access all FRR BGP capabilities without abstraction layers
2. **Direct migration path** - Easy to migrate from existing FRR deployments
3. **Better documentation** - FRR community docs apply directly
4. **Immutable image** - Config changes don't require rebuilding the extension image
5. **Terraform integration** - Render per-node configs from templates and inject via ExtensionServiceConfig

## Features

- **Configuration via ExtensionServiceConfig**: All settings in YAML configuration files
- **Multiple BGP Peers**: Configure unlimited peers with individual settings
- **Per-Peer Configuration**: Different passwords, timers, BFD profiles per peer
- **BGP Routing**: Full BGP support with FRR 10.5.0
- **Prometheus Metrics**: Built-in metrics exporter on port 9342 (frr_exporter v1.8.0)
- **Cilium Integration**: Works with Cilium BGP Control Plane for LoadBalancer services
- **BFD Support**: Fast failure detection with configurable profiles
- **Dual Stack**: IPv4 and IPv6 support with per-peer address families

## Quick Start

### Configuration Workflow

The recommended workflow is: **Render → Inject → Apply**

1. **Render** - Use Terraform `templatefile()` to render `frr.conf` from a Jinja2 template with per-node variables
2. **Inject** - Embed the rendered config into Talos ExtensionServiceConfig via `content: |`
3. **Apply** - Deploy to nodes with `talosctl apply-config` (no image rebuild needed)

### Installation

1. Add the extension to your custom Talos installer:

```hcl
# terraform/install-schematic.hcl
install_custom_extensions = [
  "ghcr.io/sulibot/frr-talos-extension:latest",
]
```

2. Build custom installer with the extension (one-time step):

```bash
cd terraform/talos-installer-build
terragrunt apply
```

### Configuration

#### Recommended: Terraform Template Rendering

Use Terraform to render native `frr.conf` per node:

```hcl
# main.tf
locals {
  frr_configs = {
    for node_name, node in local.all_nodes : node_name => templatefile("${path.module}/frr.conf.j2", {
      hostname      = node.hostname
      router_id     = node.ipv4_loopback
      router_id_v6  = node.ipv6_loopback
      local_asn     = 4210000000 + (var.cluster_id * 1000) + node.suffix
      remote_asn    = 4200001000
    })
  }
}

# Per-node ExtensionServiceConfig
config_patch = yamlencode({
  apiVersion = "v1alpha1"
  kind       = "ExtensionServiceConfig"
  name       = "frr"
  configFiles = [
    {
      content   = local.frr_configs[node_name]
      mountPath = "/usr/local/etc/frr/frr.conf"
    },
    {
      content   = "zebra=true\nbgpd=true\nstaticd=true"
      mountPath = "/usr/local/etc/frr/daemons"
    },
    {
      content   = "service integrated-vtysh-config\nhostname ${node.hostname}"
      mountPath = "/usr/local/etc/frr/vtysh.conf"
    }
  ]
})
```

See `examples/terraform/bgp-only/` for a complete working example.

#### Alternative: Inline Static Config

For testing or simple deployments, you can embed static config directly:

```yaml
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: frr
configFiles:
  - content: |
      frr version 10.2
      frr defaults datacenter
      hostname node01
      log syslog informational
      service integrated-vtysh-config
      !
      router bgp 4210101011
       bgp router-id 10.255.101.11
       no bgp default ipv4-unicast
       neighbor fe80::%ens18 remote-as 4200001000
       !
       address-family ipv4 unicast
        neighbor fe80::%ens18 activate
        neighbor fe80::%ens18 extended-nexthop
       exit-address-family
      !
    mountPath: /usr/local/etc/frr/frr.conf
```

### Updating Configuration

To update routing config (change ASN, add peers, modify route maps):

1. Edit your Terraform template or variables
2. Run `terragrunt plan` to see changes
3. Run `terragrunt apply` to generate new machine configs
4. Apply to nodes: `talosctl apply-config --file <node-config.yaml>`

**No image rebuild or registry push required** - just re-apply Talos config.

## Usage Without Terraform

If you're not using Terraform, you can still use this extension by manually creating the `frr.conf` and embedding it in your Talos machine configuration.

### Step 1: Create your frr.conf

Create a file `frr.conf` with your BGP configuration:

```bash
! FRR Configuration for node01
frr version 10.2
frr defaults datacenter
hostname node01
log syslog informational
service integrated-vtysh-config
!
router bgp 4210101011
 bgp router-id 10.255.101.11
 no bgp default ipv4-unicast
 neighbor fe80::%ens18 remote-as 4200001000
 neighbor fe80::%ens18 description "Upstream Router"
 !
 address-family ipv4 unicast
  neighbor fe80::%ens18 activate
  neighbor fe80::%ens18 extended-nexthop
 exit-address-family
 !
 address-family ipv6 unicast
  neighbor fe80::%ens18 activate
 exit-address-family
exit
!
line vty
!
```

### Step 2: Add to Talos machine configuration

Add this to your Talos node's YAML configuration:

```yaml
machine:
  install:
    extensions:
      - image: ghcr.io/sulibot/frr-talos-extension:latest
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
      router bgp 4210101011
       bgp router-id 10.255.101.11
       no bgp default ipv4-unicast
       neighbor fe80::%ens18 remote-as 4200001000
       !
       address-family ipv4 unicast
        neighbor fe80::%ens18 activate
        neighbor fe80::%ens18 extended-nexthop
       exit-address-family
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

### Step 3: Apply configuration

```bash
talosctl apply-config --file node01-config.yaml --nodes node01
```

### Step 4: Verify FRR is running

```bash
# Check service status
talosctl -n node01 service frr status

# Access FRR shell
talosctl -n node01 exec --namespace system --cmd /usr/bin/vtysh -- vtysh

# Inside vtysh:
show running-config
show bgp summary
show ip bgp
show ipv6 bgp
```

## Common FRR Configuration Examples

### Basic BGP with Link-Local IPv6 Peering

```
router bgp 65001
 bgp router-id 10.0.0.1
 no bgp default ipv4-unicast
 neighbor fe80::%ens18 remote-as 65000
 !
 address-family ipv4 unicast
  neighbor fe80::%ens18 activate
  neighbor fe80::%ens18 extended-nexthop
 exit-address-family
exit
```

### BGP with BFD (Fast Failover)

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
 neighbor fe80::%ens18 remote-as 65000
 neighbor fe80::%ens18 bfd
 neighbor fe80::%ens18 bfd profile fast
exit
```

### BGP with Route Filtering (Import Only Default Route)

```
ipv6 prefix-list DEFAULT-ONLY-v6 seq 10 permit ::/0
ip prefix-list DEFAULT-ONLY-v4 seq 10 permit 0.0.0.0/0
!
route-map IMPORT-DEFAULT-v4 permit 10
 match ip address prefix-list DEFAULT-ONLY-v4
exit
!
route-map IMPORT-DEFAULT-v4 deny 90
exit
!
route-map IMPORT-DEFAULT-v6 permit 10
 match ipv6 address prefix-list DEFAULT-ONLY-v6
exit
!
route-map IMPORT-DEFAULT-v6 deny 90
exit
!
router bgp 65001
 neighbor fe80::%ens18 remote-as 65000
 !
 address-family ipv4 unicast
  neighbor fe80::%ens18 route-map IMPORT-DEFAULT-v4 in
 exit-address-family
 !
 address-family ipv6 unicast
  neighbor fe80::%ens18 route-map IMPORT-DEFAULT-v6 in
 exit-address-family
exit
```

### BGP Advertising Loopback Networks

```
! Define what to advertise
ip prefix-list LOOPBACKS seq 10 permit 10.255.0.0/16 ge 32
ipv6 prefix-list LOOPBACKS-V6 seq 10 permit fd00:255::/32 ge 128
!
route-map ADVERTISE-LOOPBACKS permit 10
 match ip address prefix-list LOOPBACKS
exit
!
route-map ADVERTISE-LOOPBACKS-V6 permit 10
 match ipv6 address prefix-list LOOPBACKS-V6
exit
!
router bgp 65001
 address-family ipv4 unicast
  neighbor fe80::%ens18 route-map ADVERTISE-LOOPBACKS out
 exit-address-family
 !
 address-family ipv6 unicast
  neighbor fe80::%ens18 route-map ADVERTISE-LOOPBACKS-V6 out
 exit-address-family
exit
```

## Troubleshooting

### Check FRR service status

```bash
talosctl -n <node> service frr status
```

### View FRR logs

```bash
talosctl -n <node> logs system/frr
```

### Access FRR VTY shell

```bash
talosctl -n <node> exec --namespace system --cmd /usr/bin/vtysh -- vtysh
```

Inside vtysh, useful commands:
```
show running-config          # View current configuration
show bgp summary             # BGP neighbor status
show ip bgp                  # IPv4 routes received via BGP
show ipv6 bgp                # IPv6 routes received via BGP
show ip route                # Kernel routing table
show bfd peers               # BFD session status
```

### Common Issues

#### BGP neighbor not establishing

Check link-local connectivity:
```bash
talosctl -n <node> exec -- ping6 -c 3 -I ens18 fe80::<upstream-router-ll>
```

Verify neighbor config:
```bash
vtysh -c "show bgp neighbors"
```

#### Routes not appearing in kernel

Check if BGP is receiving routes:
```bash
vtysh -c "show ip bgp"
vtysh -c "show ipv6 bgp"
```

Check if routes are in kernel:
```bash
talosctl -n <node> get routes
```

Verify protocol is exporting to kernel:
```bash
vtysh -c "show ip protocol"
```

#### Extended Next-Hop not working

Ensure both sides support RFC 5549:
```bash
vtysh -c "show bgp neighbors <neighbor> | grep extended-nexthop"
```

Should show: `extended-nexthop capability: advertised and received`

### Updating Configuration

To update FRR config after initial deployment:

**With Terraform:**
```bash
# Edit template or variables
vim terraform/modules/talos_config/frr.conf.j2

# Regenerate configs
cd terraform/cluster-101/machine-config-generate
terragrunt apply

# Apply to nodes
talosctl apply-config --file outputs/node01.yaml --nodes node01
```

**Without Terraform:**
```bash
# Edit your machine config YAML file
vim node01-config.yaml

# Apply updated config
talosctl apply-config --file node01-config.yaml --nodes node01
```

The FRR service will automatically reload with the new configuration.

## Cilium Integration (Optional)

This extension works standalone for host networking, but can also integrate with Cilium BGP Control Plane for LoadBalancer IP advertisement.

### Architecture

- **FRR handles upstream peering** - Peers with your physical network (ToR switches, routers)
- **Cilium handles pod networking** - Installs pod routes in kernel
- **FRR redistributes kernel routes** - Advertises Cilium pod CIDRs to upstream

### Configuration

No special Cilium integration needed - FRR automatically redistributes kernel routes that Cilium installs.

Example Cilium BGP configuration:
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeeringPolicy
metadata:
  name: node-bgp
spec:
  nodeSelector:
    matchLabels:
      bgp: enabled
  virtualRouters:
  - localASN: 64512
    exportPodCIDR: true
    neighbors:
    - peerAddress: 169.254.1.1/32  # FRR on veth
      peerASN: 64512
```

See `examples/cilium-bgp-config.yaml` for a complete example.

## Examples

The `examples/` directory contains complete working configurations:

### Terraform Examples
- **[examples/terraform/bgp-only/](examples/terraform/bgp-only/)** - Complete Terraform module example
  - Shows how to use `templatefile()` to render configs
  - Per-node configuration with variables
  - ExtensionServiceConfig generation

### Talos Configuration Examples
- **[examples/extension-service-config.yaml](examples/extension-service-config.yaml)** - Basic inline config
- **[examples/extension-service-config-host-mounted.yaml](examples/extension-service-config-host-mounted.yaml)** - Using host-mounted config file
- **[examples/talos-config-example.yaml](examples/talos-config-example.yaml)** - Complete node configuration

### FRR Configuration Examples
- **[examples/config.yaml](examples/config.yaml)** - Basic BGP configuration
- **[examples/config-bfd.yaml](examples/config-bfd.yaml)** - BGP with BFD fast failover
- **[examples/config-network-announce.yaml](examples/config-network-announce.yaml)** - Advertising networks

### Cilium Integration Examples
- **[examples/cilium-bgp-config.yaml](examples/cilium-bgp-config.yaml)** - Cilium BGP peering policy
- **[examples/cilium-values.yaml](examples/cilium-values.yaml)** - Cilium Helm values

## Prometheus Metrics

FRR extension v1.0.17+ exposes Prometheus metrics on port 9342 via [frr_exporter](https://github.com/tynany/frr_exporter).

### Available Metrics

See [frr_exporter documentation](https://github.com/tynany/frr_exporter) for complete metric list.

**Key metrics:**
- `frr_bgp_peer_state` - BGP peer state (1=established, 0=down)
- `frr_bgp_peer_uptime_seconds` - BGP peer uptime
- `frr_bgp_peer_prefixes_received_count_total` - Routes received from peer
- `frr_bgp_peer_prefixes_advertised_count_total` - Routes advertised to peer
- `frr_bfd_peer_status` - BFD peer state (1=up, 0=down)
- `frr_bfd_peer_uptime_seconds` - BFD peer uptime

### Accessing Metrics

```bash
# From any host with network access
curl http://[fd00:101::11]:9342/metrics

# Check if port is listening
talosctl -n <node-ip> read /proc/net/tcp6 | grep 247E  # 9342 in hex
```

### Prometheus Integration

Configure Prometheus to scrape the metrics endpoint:

```yaml
- job_name: 'frr-exporter'
  scrape_interval: 30s
  static_configs:
    - targets:
        - 'node1-ip:9342'
        - 'node2-ip:9342'
```

Example PromQL queries:

```promql
# BGP session health
frr_bgp_peer_state{peer="fe80::xxx"}

# Total routes per node
sum(frr_bgp_peer_prefixes_received_count_total) by (instance)

# BFD session uptime
frr_bfd_peer_uptime_seconds
```

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** - Complete beginner-friendly setup guide
- [BFD Configuration](docs/BFD-CONFIGURATION.md) - Detailed BFD setup and profiles
- [Configuration Guide](docs/CONFIGURATION.md) - Complete configuration reference
- [Deployment Guide](docs/DEPLOYMENT.md) - Step-by-step deployment instructions
- [Talos Integration](docs/TALOS-INTEGRATION.md) - ExtensionServiceConfig details

## FAQ

### Do I need to rebuild the extension image to change my BGP config?

No! That's the whole point of this architecture. Just update your ExtensionServiceConfig and `talosctl apply-config`.

### Can I use this without Terraform?

Yes! See the [Usage Without Terraform](#usage-without-terraform) section.

### Does this work with Cilium?

Yes! FRR handles upstream peering, Cilium handles pod networking. See [Cilium Integration](#cilium-integration-optional).

### Can I use IPv4-only BGP?

Yes, but we recommend link-local IPv6 with extended-nexthop (RFC 5549) for unnumbered BGP.

### How do I update FRR to a newer version?

Update the base image in `Dockerfile` and rebuild. The extension uses the official FRR container as a base.

### Can I run multiple BGP daemons or protocols?

This extension is BGP-only. For OSPF/IS-IS, fork and modify the `daemons` file.

## Image

Pre-built images are available at:
- `ghcr.io/sulibot/frr-talos-extension:latest`
- `ghcr.io/jsenecal/frr-talos-extension` (upstream)

## Contributing

Contributions welcome! Please:

1. Test your changes with Talos
2. Update documentation for any config changes
3. Add examples for new features
4. Follow existing code style

## License

This project is licensed under GPL v3 - see [LICENCE.txt](LICENCE.txt) for details.

FRR itself is licensed under GPL v2+ - see https://frrouting.org/
