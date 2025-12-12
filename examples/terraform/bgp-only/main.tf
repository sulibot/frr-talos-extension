# Example: Terraform rendering of native frr.conf for Talos nodes
# This demonstrates the recommended "Render → Inject → Apply" workflow

# Configuration variables (customize these)
variable "cluster_id" {
  description = "Cluster ID"
  type        = number
  default     = 101
}

variable "bgp_asn_base" {
  description = "Base ASN for BGP. Final ASN = base + (cluster_id * 1000) + node_suffix"
  type        = number
  default     = 4210000000
}

variable "bgp_remote_asn" {
  description = "Upstream router BGP ASN"
  type        = number
  default     = 4200001000
}

variable "bgp_interface" {
  description = "Network interface for BGP peering"
  type        = string
  default     = "ens18"
}

variable "bgp_enable_bfd" {
  description = "Enable BFD for fast failover"
  type        = bool
  default     = false
}

variable "bgp_advertise_loopbacks" {
  description = "Advertise node loopback addresses"
  type        = bool
  default     = false
}

locals {
  # Example node data (replace with your actual node inventory)
  nodes = {
    "solcp01" = {
      hostname        = "solcp01"
      ipv4_loopback   = "10.255.101.11"
      ipv6_loopback   = "fd00:255:101::11"
      suffix          = 11
    }
    "solcp02" = {
      hostname        = "solcp02"
      ipv4_loopback   = "10.255.101.12"
      ipv6_loopback   = "fd00:255:101::12"
      suffix          = 12
    }
    "solcp03" = {
      hostname        = "solcp03"
      ipv4_loopback   = "10.255.101.13"
      ipv6_loopback   = "fd00:255:101::13"
      suffix          = 13
    }
  }

  # Render FRR config per node using templatefile()
  frr_configs = {
    for node_name, node in local.nodes : node_name => templatefile("${path.module}/frr.conf.j2", {
      # Node identity
      hostname   = node.hostname
      router_id  = node.ipv4_loopback

      # BGP configuration
      local_asn  = var.bgp_asn_base + (var.cluster_id * 1000) + node.suffix
      remote_asn = var.bgp_remote_asn

      # Network configuration
      interface        = var.bgp_interface
      cluster_id       = var.cluster_id
      node_suffix      = node.suffix
      loopback_ipv4    = node.ipv4_loopback
      loopback_ipv6    = node.ipv6_loopback

      # Feature flags
      enable_bfd               = var.bgp_enable_bfd
      advertise_loopbacks      = var.bgp_advertise_loopbacks
    })
  }

  # Generate ExtensionServiceConfig for each node
  extension_configs = {
    for node_name, node in local.nodes : node_name => yamlencode({
      apiVersion = "v1alpha1"
      kind       = "ExtensionServiceConfig"
      name       = "frr"
      configFiles = [
        {
          content   = local.frr_configs[node_name]
          mountPath = "/usr/local/etc/frr/frr.conf"
        },
        {
          content = <<-EOT
            zebra=true
            zebra_options="-n -A 127.0.0.1"
            bgpd=true
            bgpd_options="-A 127.0.0.1"
            staticd=true
            staticd_options="-A 127.0.0.1"
          EOT
          mountPath = "/usr/local/etc/frr/daemons"
        },
        {
          content   = "service integrated-vtysh-config\nhostname ${node.hostname}\n"
          mountPath = "/usr/local/etc/frr/vtysh.conf"
        }
      ]
    })
  }
}

# Output rendered configs for inspection
output "frr_configs" {
  description = "Rendered frr.conf per node"
  value       = local.frr_configs
}

output "extension_configs" {
  description = "Full ExtensionServiceConfig YAML per node"
  value       = local.extension_configs
}

# Usage in actual Talos machine config:
#
# config_patch = join("\n---\n", [
#   yamlencode({
#     machine = {
#       network = { ... }
#     }
#   }),
#   local.extension_configs[node_name]
# ])
