# Production Setup Guide

Complete guide for deploying the ROSA Virtualization BGP Plugin in production environments.

## Prerequisites

### Cluster Requirements

- **ROSA cluster** with HyperShift or Classic
- **Bare metal nodes** (m5zn.metal or similar) - required for OpenShift Virtualization
- **OpenShift Virtualization** installed and configured
- **Cluster admin** access

### Network Requirements

- **Site-to-Site VPN** or Direct Connect to ROSA VPC
- **BGP peer** (on-premises router or cloud router)
- **AS numbers** assigned for cluster (e.g., 65100) and peer (e.g., 65000)
- **IP subnet** for VM secondary network (e.g., 192.168.100.0/24)

## Installation

### Step 1: Install FRR-K8s

```bash
./hack/install-prereqs.sh
```

This installs FRR-K8s v0.0.23 and grants necessary permissions.

**Wait for FRR pods:**
```bash
oc get pods -n frr-k8s-system -w
```

### Step 2: Deploy BGP Controller

```bash
# Build and push controller image (if using your own registry)
export IMG=quay.io/your-org/rosa-virt-bgp-controller:v0.1.0
make docker-build docker-push

# Deploy
make deploy
```

**Verify controller:**
```bash
oc get pods -n rosa-virt-bgp-system
```

### Step 3: Configure Networking

#### Discover Your Cluster Values

Before applying manifests, gather these values:

**1. Get cluster node IP (for BGP router ID):**
```bash
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IP: $NODE_IP"
```

**2. Decide on VM network subnet:**
```bash
# Example: 192.168.100.0/24
# Ensure this doesn't conflict with existing networks
VM_SUBNET="192.168.100.0/24"
```

**3. Get BGP peer information:**
- Peer IP address
- Peer ASN (e.g., 65000)
- Cluster ASN (e.g., 65100)
- BGP password (optional but recommended)

#### Apply Network Configuration

**1. Update and apply ClusterUserDefinedNetwork:**

Edit `manifests/02-networking/user-defined-network.yaml`:
```yaml
spec:
  network:
    layer2:
      subnets:
      - "192.168.100.0/24"  # Your VM subnet
```

```bash
oc apply -f manifests/02-networking/
```

**2. Update and apply FRR base config:**

Edit `manifests/03-frr/frr-config-base.yaml`:
```yaml
spec:
  bgp:
    routers:
    - asn: 65100  # Your cluster ASN
      id: 10.0.1.127  # Your node IP from above
```

```bash
oc apply -f manifests/03-frr/frr-config-base.yaml
```

### Step 4: Configure BGP Peering

**1. Create BGP secret (if using authentication):**

Edit `manifests/03-frr/bgp-secret.yaml`:
```yaml
stringData:
  password: "your-bgp-password"
```

```bash
oc apply -f manifests/03-frr/bgp-secret.yaml
```

**2. Configure BGP peer:**

Edit `manifests/03-frr/frr-config-bgp-peer.yaml`:
```yaml
spec:
  bgp:
    routers:
    - asn: 65100  # Must match base config
      neighbors:
      - asn: 65000  # Peer ASN
        address: 192.168.1.1  # Peer IP
        port: 179  # Standard BGP port (use 1179 for non-privileged)
        ebgpMultiHop: true  # If peer isn't directly connected
        passwordSecret:  # Optional
          name: bgp-peer-secret
          namespace: frr-k8s-system
```

```bash
oc apply -f manifests/03-frr/frr-config-bgp-peer.yaml
```

### Step 5: Verify BGP Session

```bash
# Get FRR pod
FRR_POD=$(oc get pods -n frr-k8s-system -l control-plane=frr-k8s -o name | head -1)

# Check BGP summary
oc exec -n frr-k8s-system $FRR_POD -c frr -- vtysh -c 'show bgp summary'
```

**Expected output:**
```
Neighbor        V    AS  MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down  State/PfxRcd
192.168.1.1     4 65000       15      18        0    0    0 00:05:22  Established
```

Look for **Established** state.

## Deploying VMs

### Create VM with Secondary Network

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: my-vm
  namespace: my-namespace  # Must have label bgp-enabled=true
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        devices:
          interfaces:
          - name: default
            masquerade: {}
          - name: secondary  # Secondary network for BGP
            bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
      - name: default
        pod: {}
      - name: secondary
        multus:
          networkName: vm-bgp-network  # References the CUDN
      # ... volumes, etc
```

**Label the namespace:**
```bash
oc label namespace my-namespace bgp-enabled=true
```

### Verify Route Advertisement

**1. Check controller detected the VM:**
```bash
oc logs -n rosa-virt-bgp-system deployment/bgp-vm-controller --tail 20
```

**2. Check FRRConfiguration was created:**
```bash
oc get frrconfigurations -n my-namespace
```

**3. Verify BGP is advertising the route:**
```bash
FRR_POD=$(oc get pods -n frr-k8s-system -l control-plane=frr-k8s -o name | head -1)
oc exec -n frr-k8s-system $FRR_POD -c frr -- vtysh -c 'show ip bgp'
```

**4. Check on BGP peer (on-prem router):**
```bash
# On your router, check received routes
# Example for FRR:
vtysh -c 'show ip bgp'

# Look for the VM IP as /32 route
```

## Network Connectivity Options

### Option 1: AWS Site-to-Site VPN

**Recommended for:** Production hybrid cloud connectivity

**Setup:**
1. Create VPN Gateway and attach to ROSA VPC
2. Create Customer Gateway for on-prem router
3. Create VPN Connection with BGP enabled
4. Configure on-prem router with IPsec and BGP

**Resources:**
- [Red Hat ROSA S2S VPN Guide](https://cloud.redhat.com/experts/rosa/s2s-vpn/)
- [AWS VPN Documentation](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html)

### Option 2: AWS Transit Gateway

**Recommended for:** Multi-VPC or multi-region setups

**Setup:**
1. Create Transit Gateway
2. Attach ROSA VPC to TGW
3. Configure BGP on TGW
4. Enable route propagation

**Resources:**
- [AWS Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/)

### Option 3: AWS Direct Connect

**Recommended for:** High bandwidth, low latency requirements

Provides dedicated network connection between on-prem and AWS.

## Topology Options

### Layer2 (Recommended for Most Cases)

Simple overlay network within the cluster. No physical network mapping required.

```yaml
network:
  topology: Layer2
  layer2:
    role: Secondary
    subnets:
    - "192.168.100.0/24"
```

**Use when:**
- VMs don't need to communicate with physical VLANs
- Simpler setup preferred
- Demo or development environments

### Localnet (Advanced)

Maps to physical network interfaces on nodes. Requires OVN bridge mapping configuration.

```yaml
network:
  topology: Localnet
  localnet:
    role: Secondary
    subnets:
    - "192.168.100.0/24"
    physicalNetworkName: vlan100
```

**Use when:**
- VMs need Layer 2 connectivity to physical network
- Integration with existing VLAN infrastructure
- Production environments with specific network requirements

**Additional setup required:**
- Configure OVN bridge mappings on nodes
- Ensure physical network interfaces are available

## Troubleshooting

### BGP Session Not Establishing

**Check connectivity:**
```bash
FRR_POD=$(oc get pods -n frr-k8s-system -l control-plane=frr-k8s -o name | head -1)
oc exec -n frr-k8s-system $FRR_POD -c frr -- ping -c 3 <peer-ip>
```

**Check BGP configuration:**
```bash
oc exec -n frr-k8s-system $FRR_POD -c frr -- vtysh -c 'show run'
```

**Check BGP neighbor details:**
```bash
oc exec -n frr-k8s-system $FRR_POD -c frr -- vtysh -c 'show bgp neighbors <peer-ip>'
```

**Common issues:**
- Firewall blocking BGP port (179 or 1179)
- Incorrect AS numbers
- Password mismatch
- Network unreachable

### VMs Not Getting Secondary IPs

**Check CUDN:**
```bash
oc get clusteruserdefinednetwork vm-bgp-network -o yaml
```

**Check NAD (NetworkAttachmentDefinition):**
```bash
oc get network-attachment-definitions -n <namespace>
```

**Check VM pod events:**
```bash
oc describe vmi <vm-name> -n <namespace>
```

**Common issues:**
- Namespace not labeled with `bgp-enabled=true`
- NAD not created in namespace
- Localnet topology without bridge mapping configured

### Controller Not Creating FRRConfigurations

**Check controller logs:**
```bash
oc logs -n rosa-virt-bgp-system deployment/bgp-vm-controller -f
```

**Check controller has permissions:**
```bash
oc get clusterrole bgp-vm-controller-role -o yaml
```

**Common issues:**
- VM doesn't have secondary network
- Secondary network doesn't match configured network name
- Namespace not labeled

### Routes Not Being Advertised

**Verify FRRConfiguration exists:**
```bash
oc get frrconfigurations -n <namespace> -o yaml
```

**Check FRR received the config:**
```bash
FRR_POD=$(oc get pods -n frr-k8s-system -l control-plane=frr-k8s -o name | head -1)
oc exec -n frr-k8s-system $FRR_POD -c frr -- vtysh -c 'show bgp ipv4 unicast advertised-routes <peer-ip>'
```

**Check FRR-K8s controller logs:**
```bash
oc logs -n frr-k8s-system -l control-plane=frr-k8s -c controller --tail 50
```

## Production Best Practices

### High Availability

- **Multiple metal nodes** - Deploy VMs across multiple nodes for redundancy
- **BGP multihop** - Use when peer isn't directly connected
- **BFD** - Enable for fast failure detection (already configured in base config)
- **Multiple BGP peers** - Configure redundant routers for failover

### Security

- **BGP authentication** - Always use MD5 passwords in production
- **Network policies** - Restrict traffic to/from VMs
- **SCC policies** - Already configured (privileged for FRR, anyuid for controller)
- **Firewall rules** - Limit BGP access to trusted peers only

### Monitoring

**Monitor BGP session health:**
```bash
# Create ServiceMonitor for FRR metrics
# FRR-K8s exposes Prometheus metrics on port 7472
```

**Monitor controller:**
```bash
# Check controller logs regularly
oc logs -n rosa-virt-bgp-system deployment/bgp-vm-controller --tail 100
```

**Alert on:**
- BGP session state changes
- FRRConfiguration creation failures
- Controller restarts

### Capacity Planning

- **IP addressing** - Plan subnet size based on expected VMs
- **BGP table size** - Each VM adds one /32 route
- **FRR resource limits** - Adjust if advertising many routes
- **Controller resource limits** - Scale based on VM count

## Upgrading

### Upgrade FRR-K8s

```bash
# Update version in install script
FRR_K8S_VERSION="v0.0.24"  # Example newer version

# Apply
./hack/install-prereqs.sh
```

**Note:** Check FRR-K8s release notes for API changes.

### Upgrade Controller

```bash
# Build new version
export IMG=quay.io/your-org/rosa-virt-bgp-controller:v0.2.0
make docker-build docker-push

# Update deployment
make deploy
```

## Related Projects

- **[msemanrh/rosa-bgp](https://github.com/msemanrh/rosa-bgp)** - Advertises Pod network CIDR for Pod-to-VPC routing
- **[Red Hat S2S VPN](https://cloud.redhat.com/experts/rosa/s2s-vpn/)** - Site-to-Site VPN with static routes

These can be used together with this plugin for comprehensive network integration.

## Support

This is a community project. For issues:
- Check troubleshooting section above
- Review FRR-K8s documentation
- Open GitHub issue with logs and configuration
