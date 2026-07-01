# Architecture

## Overview

The ROSA Virt BGP Plugin enables native BGP networking between on-premises VLANs and VMs running on OpenShift Virtualization with ROSA. This solution bypasses AWS load balancers and VPN tunnels to provide direct Layer 2 connectivity with dynamic route advertisement.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Corporate Network                         │
│                  (On-Premises Routers)                       │
│                         AS 65001                             │
└────────────────────┬────────────────────────────────────────┘
                     │ BGP Peering (TCP/179)
                     │ Advertises VM /32 routes
                     │
┌────────────────────┼────────────────────────────────────────┐
│                    │         ROSA Cluster                    │
│  ┌─────────────────▼──────────────────────┐                 │
│  │        FRR-K8s (DaemonSet)             │                 │
│  │     AS 65000 - BGP Speaker             │                 │
│  │   Reads FRRConfiguration CRs           │                 │
│  │   Advertises: 10.10.10.5/32, etc.     │                 │
│  └────────────────────────────────────────┘                 │
│                    ▲                                         │
│                    │ Creates/Updates FRRConfiguration        │
│  ┌─────────────────┴──────────────────────┐                 │
│  │    BGP-VM Controller (Deployment)      │                 │
│  │  - Watches VirtualMachineInstances     │                 │
│  │  - Extracts IPs from VMI status        │                 │
│  │  - Generates FRRConfiguration CRs      │                 │
│  └────────────────────────────────────────┘                 │
│                    ▲                                         │
│                    │ Kubernetes API Watch                    │
│  ┌─────────────────┴──────────────────────┐                 │
│  │     OpenShift Virtualization VMs       │                 │
│  │   ┌────────────────────────────────┐   │                 │
│  │   │ VM: fedora-vm-01               │   │                 │
│  │   │ - eth0: Pod Network (NAT)      │   │                 │
│  │   │ - eth1: CUDN (10.10.10.5/24)   │   │                 │
│  │   └────────────────────────────────┘   │                 │
│  └────────────────────────────────────────┘                 │
│                    │                                         │
│  ┌─────────────────▼──────────────────────┐                 │
│  │   CUDN Layer (OVN-Kubernetes)          │                 │
│  │   - Topology: Localnet (L2 Direct)     │                 │
│  │   - VLAN 100 Trunk on EC2 NICs         │                 │
│  │   - Persistent IPAM via IPAMClaim      │                 │
│  │   - Subnet: 10.10.10.0/24              │                 │
│  │   - Gateway: 10.10.10.1                │                 │
│  └────────────────────────────────────────┘                 │
│                    │                                         │
└────────────────────┼─────────────────────────────────────────┘
                     │ VLAN 100 Trunk (AWS EC2 NIC)
                     │ Configured via NMState
                     │
        ┌────────────▼────────────┐
        │   Physical VLAN 100     │
        │   10.10.10.0/24         │
        │   Gateway: 10.10.10.1   │
        └─────────────────────────┘
```

## Components

### 1. Cluster User-Defined Network (CUDN)

**Purpose:** Creates an isolated Layer 2 network segment for VMs with direct physical connectivity.

**Key Features:**
- **Localnet Topology:** Direct mapping to physical VLAN, no overlay encapsulation
- **Persistent IPAM:** IP addresses persist across VM restarts and migrations via `IPAMClaim` resources
- **OVN-Kubernetes Integration:** Managed by OVN as a secondary network alongside the default pod network
- **VLAN Mapping:** Maps to physical VLAN via OVS bridge configuration

**Configuration:**
```yaml
ClusterUserDefinedNetwork:
  network:
    topology: Localnet
    subnets: ["10.10.10.0/24"]
    localnetConfig:
      bridgeMappings:
      - physicalNetworkName: vlan100
        ovsBridge: br-vlan
    ipamLifecycle: Persistent
```

### 2. FRR-K8s (BGP Speaker)

**Purpose:** BGP routing daemon running inside the cluster to peer with on-premises routers.

**Deployment:**
- DaemonSet: One instance per node
- Host networking: Direct access to physical network
- Privileged: Requires NET_ADMIN capability for routing

**Functionality:**
- Reads `FRRConfiguration` Custom Resources
- Merges multiple configs additively
- Establishes BGP sessions with external peers
- Advertises routes with BFD for fast failover

**BGP Session:**
```
Local AS: 65000
Remote AS: 65001 (on-prem routers)
Protocol: BGP4
Authentication: MD5
Failover: BFD (300ms detect)
```

### 3. BGP-VM Controller

**Purpose:** Kubernetes operator that watches VMs and generates BGP route advertisements.

**Architecture:**
- **Language:** Go with Kubebuilder/controller-runtime
- **Deployment:** 2 replicas with leader election
- **Watch Resources:** VirtualMachineInstance, IPAMClaim
- **Managed Resources:** FRRConfiguration

**Reconciliation Loop:**
1. Watch `VirtualMachineInstance` resources
2. Filter for VMs with CUDN secondary network
3. Extract IP addresses (VMI status → annotations → IPAMClaim)
4. Aggregate all VM IPs per namespace
5. Generate/update `FRRConfiguration` with /32 host routes
6. Clean up config when VMs are deleted

**FRRConfiguration Generation:**
```yaml
# One config per namespace, aggregates all VMs
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: bgp-vm-routes-vm-workloads
spec:
  bgp:
    routers:
    - asn: 65000
      prefixes:
      - 10.10.10.5/32    # fedora-vm-01
      - 10.10.10.6/32    # rhel-vm-01
```

## Data Flow

### VM Creation to BGP Advertisement

1. **User Action:** Create `VirtualMachine` with CUDN secondary network
   ```yaml
   interfaces:
   - name: bgp-network
     bridge: {}
   networks:
   - name: bgp-network
     multus:
       networkName: vm-bgp-net
   ```

2. **IPAM Allocation:** OVN-Kubernetes IPAM creates `IPAMClaim` and assigns persistent IP
   - Subnet: `10.10.10.0/24`
   - Assigned IP: `10.10.10.5`
   - Claim persists across restarts

3. **VM Boot:** VM starts with two interfaces
   - `eth0`: Default pod network (masquerade NAT)
   - `eth1`: CUDN network (bridge mode, direct L2)

4. **IP Discovery:** Controller watches VMI, detects new instance
   - Checks `.status.interfaces[].ips[]` for CUDN interface
   - Falls back to annotations if status not populated
   - Validates IP is within configured subnet

5. **Config Generation:** Controller creates/updates `FRRConfiguration`
   - One config per namespace
   - Aggregates all running VMs
   - Each VM gets a /32 host route

6. **FRR Merge:** FRR-K8s daemon detects config change
   - Merges all `FRRConfiguration` resources
   - Updates FRR running configuration
   - No service restart required

7. **BGP Advertisement:** FRR advertises new route to peers
   ```
   Network: 10.10.10.5/32
   Next-Hop: 10.10.10.1 (VLAN gateway)
   AS-Path: 65000
   Origin: IGP
   ```

8. **Traffic Flow:** On-prem router updates routing table
   - Packets to `10.10.10.5` forwarded to VLAN 100
   - Arrive at any ROSA worker node (L2 domain)
   - OVS bridge forwards to VM's interface
   - VM responds directly

### VM Migration

1. **Live Migration Triggered:** VM migrates from node1 to node2
2. **IP Preserved:** IPAMClaim ensures same IP on new node
3. **Route Maintained:** BGP advertisement continues (next-hop unchanged)
4. **No Downtime:** L2 adjacency means migration is transparent
5. **Controller Re-sync:** Reconciles after migration completes

### VM Deletion

1. **Delete Event:** User deletes VirtualMachine
2. **Controller Detects:** Finalizer on VMI triggers cleanup
3. **Config Update:** Controller removes IP from `FRRConfiguration`
4. **BGP Withdrawal:** FRR withdraws /32 route from peers
5. **IPAM Release:** IPAMClaim deleted, IP returned to pool

## Key Design Decisions

### Localnet vs. Overlay

**Choice:** Localnet topology

**Rationale:**
- Direct L2 connectivity to physical network
- No encapsulation overhead (VXLAN/Geneve)
- Standard network troubleshooting tools work
- Simpler routing (no tunnel endpoints)

**Trade-off:** Requires VLAN trunk configuration on AWS EC2 NICs

### /32 Host Routes vs. Subnet Aggregation

**Choice:** Advertise each VM IP as /32 host route

**Rationale:**
- Precise control over individual VM reachability
- Supports VM migration (route follows VM)
- Enables anycast scenarios (multiple VMs same IP)
- Graceful shutdown (withdraw specific VM)

**Trade-off:** More entries in BGP RIB (acceptable for 100s-1000s of VMs)

### Namespace-Scoped FRRConfiguration

**Choice:** One `FRRConfiguration` per namespace

**Rationale:**
- Scales better than one-per-VM (fewer CRs)
- Aligns with namespace isolation model
- Simpler for FRR to merge
- Atomic updates (all VMs in namespace updated together)

**Trade-off:** All VMs in namespace share BGP config (acceptable)

### Controller Watch Pattern

**Choice:** Watch VMI with predicate filtering

**Rationale:**
- Efficient: Only reconcile relevant VMs
- Event-driven: Immediate response to changes
- Standard pattern: Kubernetes-native

**Predicates:**
- Running phase only
- Has CUDN network attachment
- Resource version changed

## Comparison to Alternatives

### vs. Red Hat S2S VPN Solution

| Aspect | BGP Plugin | Red Hat S2S VPN |
|--------|-----------|-----------------|
| Protocol | BGP | IPsec/IKEv2 |
| Routing | Dynamic | Static |
| Bandwidth | Physical network | 1.25 Gbps (AWS limit) |
| Latency | No encapsulation | IPsec overhead |
| IP Management | Automatic IPAM | Manual per VM |
| HA | BGP convergence | 5-second VIP failover |
| Complexity | Moderate | High (certs, VPN config) |

### vs. AWS ELB/NLB

| Aspect | BGP Plugin | AWS Load Balancer |
|--------|-----------|-------------------|
| IP Reachability | Direct VM IP | LB IP only |
| VM Migration | Supported | Breaks (IP changes) |
| Bandwidth | Physical network | LB limits |
| Cost | Infrastructure only | Per-hour + data transfer |
| Flexibility | Native L2 | L4/L7 proxying |

## Security Considerations

### BGP Authentication

- MD5 password authentication on BGP sessions
- Secrets stored in Kubernetes Secret
- Rotate passwords via Secret update

### Route Filtering

- Prefix lists on FRR limit advertised subnets
- Only CUDN subnet routes advertised
- On-prem routers should filter received routes

### Network Segmentation

- CUDN isolated from default pod network
- NetworkPolicy controls cross-network traffic
- IPAM prevents IP spoofing within CUDN

### RBAC

- Controller uses least-privilege ServiceAccount
- Only needs: watch VMI, manage FRRConfiguration
- No access to VM disks or secrets

## Scalability

### VM Limits

- **Tested:** Up to 100 VMs per namespace
- **Theoretical:** 1000s (limited by BGP RIB size)
- **Bottleneck:** On-prem router BGP capacity

### Controller Performance

- **Watch Efficiency:** Predicate filtering reduces reconciliations
- **HA:** Leader election supports multi-replica
- **Memory:** ~100MB per 100 VMs

### BGP Convergence

- **Route Add:** <1 second
- **Route Withdraw:** <1 second
- **Failover with BFD:** 300ms-1s

## Future Enhancements

- **IPv6 Support:** Dual-stack CUDN
- **BGP Communities:** Policy-based routing
- **Route Health Checks:** Withdraw routes for unhealthy VMs
- **Multi-CUDN:** VMs with multiple secondary networks
- **Anycast:** Multiple VMs sharing same IP
- **Advanced Filtering:** Label selectors for selective advertisement
