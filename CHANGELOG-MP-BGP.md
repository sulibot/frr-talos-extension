# MP-BGP Migration for FRR Talos Extension

## Date: 2026-01-26

## Summary

Updated the FRR Talos extension to use MP-BGP (Multi-Protocol BGP) for Cilium peering instead of dual-session BGP. This provides a more efficient and IPv6-first approach to BGP peering between FRR and Cilium.

## Changes Made

### 1. FRR Configuration Template ([frr.conf.j2](frr.conf.j2))

**Removed:**
- Separate VRF-based BGP router configuration for Cilium peering
- Dual BGP sessions (one for IPv4, one for IPv6)
- VRF import statements in upstream BGP configuration

**Added:**
- Single MP-BGP neighbor configuration using IPv6 as the transport
- Extended-nexthop capability for carrying IPv4 routes over IPv6 session
- Both IPv4 and IPv6 address families activated on single neighbor

**Configuration Changes:**

Before (Dual-Session):
```
router bgp <asn> vrf cilium
 neighbor 169.254.101.2 remote-as <asn>  # IPv4 session
 neighbor fd00:65:c111::2 remote-as <asn>  # IPv6 session
```

After (MP-BGP):
```
router bgp <asn>
 neighbor fd00:65:c111::2 remote-as <asn>  # Single IPv6 session
 neighbor fd00:65:c111::2 capability extended-nexthop

 address-family ipv4 unicast
  neighbor fd00:65:c111::2 activate  # IPv4 routes over IPv6
 exit-address-family

 address-family ipv6 unicast
  neighbor fd00:65:c111::2 activate  # IPv6 routes
 exit-address-family
```

### 2. Monitoring Script ([docker-start](docker-start))

**Changed:**
- Updated BGP status monitoring command from `show bgp vrf all summary wide` to `show bgp summary`
- Simplified since we no longer use VRF for Cilium peering

## Technical Benefits

### 1. **Efficiency**
- Single TCP session instead of two separate sessions
- Lower memory and CPU overhead per node
- Reduced BGP control plane traffic

### 2. **IPv6-First Architecture**
- Aligns with modern network design principles
- Uses IPv6 as the primary transport protocol
- IPv4 routes carried as secondary (via extended-nexthop)

### 3. **Simplified Configuration**
- No VRF required for local peering
- Fewer BGP neighbor definitions
- Cleaner routing table (no VRF import/export)

### 4. **Standards Compliance**
- Uses RFC 5549 (extended-nexthop capability)
- Widely supported across BGP implementations
- Industry best practice for dual-stack environments

## Testing

Tested on Debian Trixie VMs with:
- FRR 10.3
- GoBGP 3.36 (simulating Cilium BGP control plane)
- Network namespace separation (veth-cilium in "cilium" namespace)

**Test Results:**
- ✅ BGP session establishes over IPv6 (fd00:65:c111::1 ↔ fd00:65:c111::2)
- ✅ IPv4 routes advertised and received with IPv6 next-hop
- ✅ IPv6 routes advertised and received
- ✅ Single neighbor appears in both address families
- ✅ Veth pair with namespace separation working correctly

## Deployment Notes

### Prerequisites
1. Cilium must support MP-BGP configuration (Cilium 1.14+)
2. Update Cilium BGP node configs to use single MP-BGP session

### Cilium Configuration Changes Required

**Current (Dual-Session):**
```yaml
peers:
  - localAddress: "169.254.101.2"
    peerAddress: "169.254.101.1"
    peerASN: <asn>
  - localAddress: "fd00:65:c111::2"
    peerAddress: "fd00:65:c111::1"
    peerASN: <asn>
```

**Updated (MP-BGP):**
```yaml
peers:
  - localAddress: "fd00:65:c111::2"
    peerAddress: "fd00:65:c111::1"
    peerASN: <asn>
    families:
      - afi: ipv4
        safi: unicast
      - afi: ipv6
        safi: unicast
```

### Rollout Strategy

1. **Test in non-production** (completed on debtest01/debtest02)
2. **Update FRR extension** (this commit)
3. **Update Cilium BGP configs** (see: `/Users/sulibot/repos/github/home-ops/kubernetes/apps/networking/cilium/bgp/`)
4. **Rolling update** of Talos nodes
5. **Verify** BGP sessions re-establish
6. **Monitor** LoadBalancer VIP advertisements

### Rollback Plan

If issues occur:
1. Revert FRR extension to previous version
2. Revert Cilium BGP configs to dual-session
3. Restart FRR containers on affected nodes

## Verification Commands

After deployment, verify MP-BGP status:

```bash
# On Talos node (via system extension container)
vtysh -c "show bgp summary"
# Should show single neighbor fd00:65:c111::2 in both IPv4 and IPv6 summary

vtysh -c "show bgp ipv4 unicast"
# Should show Cilium LoadBalancer VIPs with IPv6 next-hop

vtysh -c "show bgp ipv6 unicast"
# Should show IPv6 routes if configured
```

## Related Documentation

- RFC 5549: Advertising IPv4 Network Layer Reachability Information with an IPv6 Next Hop
- FRR Documentation: https://docs.frrouting.org/en/latest/bgp.html
- Cilium BGP Control Plane: https://docs.cilium.io/en/stable/network/bgp-control-plane/

## Future Considerations

Per user request: "Ideally the cilium config would not be per node so it will work regardless of the number of k8s nodes deployed in the cluster."

**Current State:**
- Cilium BGP configs are per-node (CiliumBGPNodeConfig)
- Each node has unique AS number (e.g., 4210101011, 4210101012, etc.)

**Future Enhancement:**
- Investigate using CiliumBGPClusterConfig with node selectors
- Use consistent AS number across all nodes
- Dynamic peer configuration based on node metadata
- This is a nice-to-have optimization for future implementation
