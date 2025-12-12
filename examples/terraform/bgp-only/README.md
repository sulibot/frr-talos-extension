# Terraform BGP-Only Example

This example demonstrates the recommended workflow for configuring the FRR Talos extension using Terraform's `templatefile()` function with configurable variables.

## Workflow: Render → Inject → Apply

1. **Render** - Terraform renders `frr.conf` from `frr.conf.j2` template with per-node variables
2. **Inject** - Rendered config is embedded into `ExtensionServiceConfig` via `content: |`
3. **Apply** - Deploy to Talos nodes with `talosctl apply-config`

## Architecture Benefits

- **Immutable extension image** - No rebuilds for config changes
- **Per-node configuration** - Each node gets customized config (ASN, router ID, etc.)
- **Feature toggles** - Enable/disable BFD, loopback advertisement via variables
- **Version controlled** - Config is code, changes tracked in git
- **No external storage** - Config delivered via Talos native mechanism

## Files

- `frr.conf.j2` - Native FRR configuration template with conditional features
- `main.tf` - Terraform code with variables and config rendering
- `README.md` - This file

## Configuration Variables

This example demonstrates all available configuration options:

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_id` | `101` | Cluster identifier |
| `bgp_asn_base` | `4210000000` | Base ASN (final = base + cluster_id*1000 + suffix) |
| `bgp_remote_asn` | `4200001000` | Upstream router ASN |
| `bgp_interface` | `ens18` | Network interface for BGP peering |
| `bgp_enable_bfd` | `false` | Enable BFD for fast failover |
| `bgp_advertise_loopbacks` | `false` | Advertise loopback addresses |

## Usage

### Basic Setup (Minimal Configuration)

1. Copy this example to your Terraform module:

```bash
cp -r examples/terraform/bgp-only/* terraform/modules/talos_config/
```

2. Customize node inventory in `main.tf`:

```hcl
locals {
  nodes = {
    "node01" = {
      hostname        = "node01"
      ipv4_loopback   = "10.255.101.11"
      ipv6_loopback   = "fd00:255:101::11"
      suffix          = 11
    }
    # ... more nodes
  }
}
```

3. (Optional) Override defaults with variables:

```hcl
# terraform.tfvars
cluster_id       = 101
bgp_remote_asn   = 65000  # Your upstream router ASN
```

3. Preview rendered configs:

```bash
terraform init
terraform plan
terraform output frr_configs
```

4. Use in your Talos machine configuration:

```hcl
# In your talos_config module
locals {
  frr_configs = {
    for node_name, node in local.all_nodes : node_name => templatefile(
      "${path.module}/frr.conf.j2",
      {
        hostname   = node.hostname
        router_id  = node.ipv4_loopback
        local_asn  = 4210000000 + (var.cluster_id * 1000) + node.suffix
        remote_asn = 4200001000
      }
    )
  }

  machine_configs = {
    for node_name, node in local.all_nodes : node_name => {
      config_patch = join("\n---\n", [
        yamlencode({
          machine = {
            network = { ... }
          }
        }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "ExtensionServiceConfig"
          name       = "frr"
          configFiles = [
            {
              content   = local.frr_configs[node_name]
              mountPath = "/usr/local/etc/frr/frr.conf"
            },
            # ... daemons and vtysh.conf
          ]
        })
      ])
    }
  }
}
```

5. Apply to Talos nodes:

```bash
cd terraform/cluster-101/machine-config-generate
terragrunt apply

# Apply to nodes
talosctl apply-config --file outputs/solcp01.yaml --nodes solcp01
```

## Updating Configuration

To change BGP settings (ASN, peers, route maps):

1. Edit `frr.conf.j2` template
2. Run `terraform apply` to regenerate configs
3. Run `talosctl apply-config` to push to nodes

**No image rebuild required!**

## Template Variables

The `frr.conf.j2` template expects these variables:

| Variable | Example | Description |
|----------|---------|-------------|
| `hostname` | `solcp01` | Node hostname |
| `router_id` | `10.255.101.11` | BGP router ID (IPv4 loopback) |
| `local_asn` | `4210101011` | Local BGP ASN |
| `remote_asn` | `4200001000` | Remote BGP ASN (upstream) |

## Advanced Configuration Examples

### Example 1: Enable BFD for Fast Failover

```hcl
# terraform.tfvars
bgp_enable_bfd = true
```

This enables BFD with:
- Detection time: ~900ms
- receive/transmit interval: 300ms
- detect-multiplier: 3

### Example 2: Advertise Loopback Addresses

```hcl
# terraform.tfvars
bgp_advertise_loopbacks = true
```

Advertises:
- IPv4: `10.255.<cluster_id>.0/24` with `/32` loopbacks
- IPv6: `fd00:255:<cluster_id>::/48` with `/128` loopbacks

### Example 3: Production Setup (All Features)

```hcl
# terraform.tfvars
cluster_id                = 100
bgp_asn_base              = 4210000000
bgp_remote_asn            = 65000
bgp_interface             = "bond0"
bgp_enable_bfd            = true
bgp_advertise_loopbacks   = true
```

### Example 4: Multi-Cluster Setup

```hcl
# cluster-101.tfvars
cluster_id       = 101
bgp_remote_asn   = 4200001000  # PVE FRR

# cluster-102.tfvars
cluster_id       = 102
bgp_remote_asn   = 65000       # Different upstream
bgp_interface    = "eth0"
```

## Extending the Template

The template supports conditional features via Terraform's template syntax. To add more BGP features, edit `frr.conf.j2`:

### Add BFD support:

```j2
bfd
 profile normal
  detect-multiplier 3
  receive-interval 300
  transmit-interval 300
 exit
exit
!
router bgp ${local_asn}
 neighbor fe80::%ens18 remote-as ${remote_asn}
 neighbor fe80::%ens18 bfd
 neighbor fe80::%ens18 bfd profile normal
!
```

### Add Cilium peering:

```j2
router bgp ${local_asn}
 ! Cilium peer on veth interface
 neighbor 169.254.1.1 remote-as ${cilium_asn}
 neighbor 169.254.1.1 description "Cilium BGP Control Plane"
 !
 address-family ipv4 unicast
  neighbor 169.254.1.1 activate
  neighbor 169.254.1.1 route-map ALLOW-ALL in
  neighbor 169.254.1.1 route-map ALLOW-ALL out
 exit-address-family
!
```

### Advertise loopbacks:

```j2
! IPv4 prefix list for loopback advertisement
ip prefix-list LOOPBACKS seq 10 permit 10.255.${cluster_id}.0/24 ge 32
!
route-map ADVERTISE-LOOPBACKS permit 10
 match ip address prefix-list LOOPBACKS
!
router bgp ${local_asn}
 address-family ipv4 unicast
  neighbor fe80::%ens18 route-map ADVERTISE-LOOPBACKS out
 exit-address-family
!
```

## Verification

After applying config, verify BGP sessions:

```bash
# Check FRR service status
talosctl -n solcp01 service frr status

# Check BGP summary
talosctl -n solcp01 read /proc/$(talosctl -n solcp01 get processes | grep bgpd | awk '{print $2}')/cmdline
vtysh -c "show bgp summary"

# Check received routes
vtysh -c "show ip bgp"
vtysh -c "show ipv6 bgp"

# Check kernel routing table
talosctl -n solcp01 get routes
```
