# ROSA Virtualization BGP Plugin

Automatically advertise OpenShift Virtualization VM IP addresses via BGP on Red Hat OpenShift Service on AWS (ROSA).

## The Problem

When migrating VMs to ROSA, they typically lose their original IP addresses and become unreachable from on-premises networks without manual configuration. Traditional solutions require:
- **Load balancers** for each VM (expensive, limited throughput)
- **Static routes** manually updated for each VM (operationally complex)
- **NAT** which breaks applications expecting specific IPs (doesn't work for migrations)

For hybrid cloud scenarios where VMs need to maintain their IP addresses and be directly routable from on-premises networks, you need dynamic routing.

## The Solution: BGP + Kubernetes Operators

This plugin uses **BGP (Border Gateway Protocol)** - the same routing protocol that powers the internet - to automatically advertise VM IP addresses to your network.

**Why BGP?**
- **Dynamic**: Routes automatically added/removed as VMs are created/deleted
- **Standard**: Works with any enterprise router (Cisco, Juniper, Arista, etc.)
- **Scalable**: Handles thousands of routes efficiently
- **Resilient**: Built-in failover and redundancy

**How It Works:**

1. **FRR-K8s** (Free Range Routing) runs as a DaemonSet on your cluster nodes, providing a production-grade BGP speaker that integrates with Kubernetes via custom resources (FRRConfiguration).

2. **This operator** watches for VirtualMachine objects with secondary networks (ClusterUserDefinedNetworks) and automatically creates FRRConfiguration custom resources containing `/32` routes for each VM's IP address.

3. **FRR-K8s** reads these FRRConfiguration resources and advertises the routes via BGP to your on-premises routers, making the VMs instantly routable without manual intervention.

**Result:** Deploy a VM with IP `192.168.100.5`, and within seconds your on-premises network knows how to reach it - no manual configuration required.

## What It Does

When you create VMs with secondary networks (ClusterUserDefinedNetworks), this controller:
1. **Watches** for VirtualMachine resources in labeled namespaces
2. **Extracts** the VM's secondary network IP address
3. **Creates** FRRConfiguration custom resources with `/32` routes
4. **FRR-K8s** reads these configs and advertises routes via BGP
5. **Your network** automatically learns how to route to the VM

**Use case:** Migrating VMs from on-prem while maintaining their IP addresses and network segments, or building hybrid applications that require direct IP connectivity between cloud and on-premises workloads.

## Try a Demo

Fully automated demo with Site-to-Site VPN and BGP - **zero manual configuration required!**

Just be authenticated to your ROSA cluster, then:

```bash
# 1. Setup VPN infrastructure (auto-detects everything from your cluster)
./hack/setup-demo-vpn.sh

# 2. Configure on-prem router
./hack/configure-onprem-router.sh

# 3. Deploy BGP configuration to ROSA
./hack/deploy-bgp-config.sh

# 4. Deploy test VMs
oc apply -f manifests/05-examples/demo-vms.yaml

# 5. Verify BGP (shows routes being advertised)
./hack/verify-bgp.sh

# 6. Cleanup when done
./hack/cleanup-demo-vpn.sh
```

**What gets auto-detected:**
- ✅ AWS Region and ROSA VPC from your cluster
- ✅ Non-overlapping network CIDRs
- ✅ BGP ASNs and VPN credentials
- ✅ Optimal EC2 instance configuration

**Cost:** ~$0.06/hour (~$1.50 for full day)

See [`hack/README.md`](hack/README.md) for details.

## Architecture

```
┌─────────────────────────────┐      ┌──────────────────────────┐
│ ROSA Cluster                │      │ On-Premises / Other VPC  │
│                             │      │                          │
│  ┌──────────────┐           │      │  ┌────────────┐          │
│  │ VMs on CUDN  │           │      │  │ BGP Router │          │
│  │ 192.168.x.x  │           │      │  │ AS 65000   │          │
│  └──────┬───────┘           │      │  └─────▲──────┘          │
│         │                   │      │        │                 │
│  ┌──────▼──────────┐        │      │        │                 │
│  │ BGP Controller  │        │  BGP │        │                 │
│  │ (watches VMs)   │        │ ◄────┼────────┘                 │
│  └──────┬──────────┘        │      │                          │
│         │                   │      │   Routes learned:        │
│  ┌──────▼──────────┐        │      │   • 192.168.100.5/32     │
│  │ FRR-K8s         │        │      │   • 192.168.100.6/32     │
│  │ AS 65100        │        │      │                          │
│  └─────────────────┘        │      │                          │
└─────────────────────────────┘      └──────────────────────────┘
```


## Prerequisites

- ROSA cluster with metal nodes (bare metal required for virtualization)
- OpenShift Virtualization installed
- Site-to-Site VPN or network connectivity to BGP peer

## Production Setup

See [docs/PRODUCTION-SETUP.md](docs/PRODUCTION-SETUP.md) for:
- Cluster requirements and discovery
- Network configuration
- BGP peering setup
- Troubleshooting
- Production best practices

## Project Structure

```
├── cmd/controller/          # Controller entry point
├── pkg/controller/          # VM watcher and FRR config generator
├── manifests/
│   ├── 02-networking/       # ClusterUserDefinedNetwork
│   ├── 03-frr/             # FRR base config and BGP peers
│   ├── 04-controller/       # Controller deployment
│   └── 05-examples/         # Example VMs
├── hack/                    # Setup and demo scripts
└── docs/                    # Documentation
```

## Contributing

Issues and PRs welcome! This is a community project demonstrating BGP integration with OpenShift Virtualization.

## License

Apache 2.0
