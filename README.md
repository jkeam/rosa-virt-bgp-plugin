# ROSA Virt BGP Plugin

Native BGP networking for OpenShift Virtualization on ROSA - enabling direct IP reachability between on-premises VLANs and cloud-hosted VMs.

## Overview

This solution brings a native BGP engine directly inside your ROSA cluster using **Cluster User-Defined Networks (CUDN)** and **FRRouting (FRR)**. It creates a dedicated, flat network island for VMs and uses embedded BGP speakers to advertise VM IP addresses directly to your corporate routers.

**The Result:** Your on-premises network can talk to cloud-hosted VMs directly by IP address, bypassing AWS load balancers completely while preserving native VM features like live migration.

## Why This Solution?

Traditional hybrid cloud connectivity approaches have significant limitations:

| Approach | Bandwidth | Routing | IP Management | Complexity |
|----------|-----------|---------|---------------|------------|
| **VPN (IPsec)** | 1.25 Gbps cap | Static | Manual per VM | High |
| **AWS Load Balancer** | Limited by LB | N/A | LB IP only | Medium |
| **This Solution** | Physical network | Dynamic BGP | Automatic IPAM | Medium |

### Key Benefits

- ✅ **No bandwidth limits** - Only constrained by physical network capacity
- ✅ **Dynamic routing** - BGP automatically handles topology changes
- ✅ **Lower latency** - No IPsec encapsulation overhead  
- ✅ **Better security** - IPAM-enabled CUDN prevents IP spoofing
- ✅ **Production-grade HA** - BGP convergence with BFD fast failover
- ✅ **Operational simplicity** - No per-VM manual configuration
- ✅ **VM mobility** - Live migration preserves connectivity

## Architecture

```
┌─────────────────────────────────┐
│     Corporate Network           │
│   (On-Prem BGP Routers)         │
│         AS 65001                │
└────────────┬────────────────────┘
             │ BGP Peering
             │ Advertises VM /32 routes
             │
┌────────────┼────────────────────────────────┐
│            │    ROSA Cluster                │
│  ┌─────────▼──────────────┐                 │
│  │   FRR-K8s DaemonSet    │                 │
│  │   (BGP Speaker)         │                 │
│  └─────────▲──────────────┘                 │
│            │ FRRConfiguration CRs            │
│  ┌─────────┴──────────────┐                 │
│  │  BGP-VM Controller     │                 │
│  │  (Watches VMs)         │                 │
│  └─────────▲──────────────┘                 │
│            │ Kubernetes API                  │
│  ┌─────────┴──────────────┐                 │
│  │ OpenShift Virt VMs     │                 │
│  │ - 10.10.10.5/24        │                 │
│  └─────────┬──────────────┘                 │
│            │                                 │
│  ┌─────────▼──────────────┐                 │
│  │  CUDN (L2 Network)     │                 │
│  │  VLAN 100 Trunk        │                 │
│  └────────────────────────┘                 │
└─────────────────────────────────────────────┘
```

**Components:**
1. **CUDN Layer** - Isolated Layer 2 network with persistent IPAM
2. **FRR-K8s** - BGP speaker running on each node
3. **BGP-VM Controller** - Watches VMs and generates route advertisements
4. **OpenShift Virt VMs** - VMs with secondary CUDN interfaces

## Quick Start

### Prerequisites

- ROSA cluster (4.14+) with metal worker nodes
- OpenShift Virtualization Operator installed
- Kubernetes NMState Operator installed
- BGP-capable on-premises router with VLAN connectivity to AWS

### Installation

```bash
# Clone repository
git clone https://github.com/jkeam/rosa-virt-bgp-plugin.git
cd rosa-virt-bgp-plugin

# Install prerequisites
./hack/install-prereqs.sh

# Configure parameters (edit manifests to match your environment)
# - VLAN ID and interface names
# - IP subnet for VMs
# - BGP ASN and neighbor addresses
# - BGP password

# Deploy
make deploy

# Deploy example VM
kubectl apply -f manifests/05-examples/example-vm-fedora.yaml

# Verify
./hack/verify-bgp.sh
```

See [Installation Guide](docs/installation.md) for detailed steps.

## How It Works

### Data Flow: VM Creation to BGP Advertisement

1. **User creates VM** with CUDN secondary network interface
2. **OVN-Kubernetes IPAM** assigns persistent IP (e.g., 10.10.10.5) via IPAMClaim
3. **VM boots** with two NICs: pod network (primary) + CUDN (secondary)
4. **Controller discovers** new VMI and extracts IP from status
5. **Controller generates** FRRConfiguration CR with /32 host route
6. **FRR-K8s merges** configs and updates BGP routing table
7. **BGP advertises** route to on-prem router with next-hop as VLAN gateway
8. **Corporate network** routes traffic directly to VM IP

### VM Migration

- VM migrates between nodes with same IP (IPAMClaim persistence)
- BGP route remains advertised (next-hop unchanged)
- No downtime - L2 adjacency makes migration transparent

### VM Deletion

- Controller detects deletion and updates FRRConfiguration
- BGP withdraws /32 route
- IP returned to IPAM pool

## Configuration

### CUDN Network

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: vm-bgp-network
spec:
  network:
    topology: Localnet           # Direct L2 connectivity
    subnets: ["10.10.10.0/24"]
    ipamLifecycle: Persistent    # IPs survive restarts/migrations
```

### BGP Configuration

```yaml
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
spec:
  bgp:
    routers:
    - asn: 65000                 # Local AS
      neighbors:
      - asn: 65001               # On-prem router AS
        address: 10.10.10.1      # On-prem router IP
        bfdProfile: default      # Fast failover
```

### Example VM

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
spec:
  template:
    spec:
      domain:
        devices:
          interfaces:
          - name: default
            masquerade: {}       # Pod network
          - name: bgp-network
            bridge: {}           # CUDN secondary network
      networks:
      - name: default
        pod: {}
      - name: bgp-network
        multus:
          networkName: vm-bgp-net
```

## Documentation

- [Architecture](docs/architecture.md) - Detailed system design and data flow
- [Installation](docs/installation.md) - Step-by-step setup guide
- [Configuration](docs/configuration.md) - Parameter reference and examples
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions

## Verification

```bash
# Check BGP session status
./hack/verify-bgp.sh

# Debug VM networking
./hack/debug-vm-networking.sh <vm-name>

# Manual checks
kubectl exec -n frr-k8s-system <frr-pod> -- vtysh -c "show bgp summary"
kubectl get vmi -n vm-workloads
kubectl get frrconfig -n frr-k8s-system
```

## Comparison to Alternatives

### vs. Red Hat S2S VPN Solution

- **BGP Plugin:** Native Layer 2, dynamic routing, no bandwidth cap, automatic IPAM
- **S2S VPN:** IPsec tunnels, static routing, 1.25 Gbps limit, manual IP config

### vs. AWS Load Balancers

- **BGP Plugin:** Direct VM IP access, supports live migration, physical network bandwidth
- **Load Balancers:** Proxy layer, IP changes break migration, LB bandwidth limits

## Requirements

- **ROSA:** 4.14+ with metal worker nodes
- **OpenShift Virtualization:** Operator installed and configured
- **NMState:** For VLAN trunk configuration
- **Network:** VLAN connectivity between AWS and on-premises (Direct Connect or VPN)
- **BGP Router:** On-premises router supporting BGP4

## Development

```bash
# Build controller
make build

# Run tests
make test

# Build Docker image
make docker-build

# Deploy to cluster
make deploy
```

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request with tests

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.

## Future Enhancements

- [ ] Helm chart for easier deployment
- [ ] IPv6 dual-stack support
- [ ] BGP communities for policy routing
- [ ] Route health checks (withdraw unhealthy VMs)
- [ ] Multi-CUDN support (VMs with multiple secondary networks)
- [ ] Web UI dashboard for BGP status visualization
- [ ] Advanced filtering with label selectors

## Support

- **Issues:** Report bugs and feature requests via [GitHub Issues](https://github.com/jkeam/rosa-virt-bgp-plugin/issues)
- **Documentation:** See [docs/](docs/) directory
- **Questions:** Use GitHub Discussions

---

**Built for production hybrid cloud environments** where on-premises and cloud VMs need seamless Layer 2 connectivity without VPN overhead or load balancer constraints.
