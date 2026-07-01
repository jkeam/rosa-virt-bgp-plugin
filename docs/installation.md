# Installation Guide

This guide walks through deploying the ROSA Virt BGP Plugin on a ROSA cluster with OpenShift Virtualization.

## Prerequisites

### Required Components

1. **ROSA Cluster** (4.14+)
   - With metal worker nodes for OpenShift Virtualization
   - Access to cluster-admin role

2. **OpenShift Virtualization Operator**
   - Installed from OperatorHub
   - HyperConverged CR configured

3. **Kubernetes NMState Operator**
   - Required for VLAN trunk configuration
   - Install from OperatorHub

4. **On-Premises Infrastructure**
   - BGP-capable router (Cisco, Juniper, FRR, etc.)
   - VLAN connectivity to AWS (Direct Connect or VPN)
   - Available AS number for ROSA cluster

### Tools Required

- `kubectl` or `oc` CLI
- `make` (for automated deployment)
- Access to container registry (optional, for custom builds)

## Installation Steps

### Step 1: Clone Repository

```bash
git clone https://github.com/jkeam/rosa-virt-bgp-plugin.git
cd rosa-virt-bgp-plugin
```

### Step 2: Install Prerequisites

```bash
./hack/install-prereqs.sh
```

This script:
- Installs FRR-K8s CRDs
- Verifies OpenShift Virtualization is available
- Checks for NMState Operator

### Step 3: Configure Network Parameters

Edit the configuration files to match your environment:

#### 3a. Update VLAN Configuration

Edit `manifests/01-prerequisites/nncp-vlan-trunk.yaml`:

```yaml
spec:
  desiredState:
    interfaces:
    - name: br-vlan
      bridge:
        port:
        - name: ens5.100        # Change VLAN ID here
          vlan:
            id: 100             # Your VLAN ID
```

**Important:** Update `ens5` to match your EC2 instance's primary network interface name. Check with:
```bash
oc debug node/<node-name> -- chroot /host ip link show
```

#### 3b. Update CUDN Subnet

Edit `manifests/02-networking/user-defined-network.yaml`:

```yaml
spec:
  network:
    subnets:
    - "10.10.10.0/24"          # Your VM subnet
    excludeSubnets:
    - "10.10.10.1/32"          # VLAN gateway
    - "10.10.10.254/32"        # Broadcast
```

#### 3c. Update BGP Configuration

Edit `manifests/03-frr/frr-config-base.yaml`:

```yaml
spec:
  bgp:
    routers:
    - asn: 65000               # Your cluster ASN
      routerID: 10.0.1.100     # Unique router ID
```

Edit `manifests/03-frr/frr-config-bgp-peer.yaml`:

```yaml
spec:
  bgp:
    routers:
    - asn: 65000               # Must match base config
      neighbors:
      - asn: 65001             # On-prem router ASN
        address: 10.10.10.1    # On-prem router IP
```

#### 3d. Update BGP Password

Edit `manifests/03-frr/bgp-secret.yaml`:

```yaml
stringData:
  password: "your-secure-bgp-password"
```

**Production Note:** Consider using SealedSecrets or external secret management (e.g., AWS Secrets Manager integration).

#### 3e. Update Controller Configuration

Edit `manifests/04-controller/configmap.yaml`:

```yaml
data:
  config.yaml: |
    networkName: "bgp-network"
    cudnSubnet: "10.10.10.0/24"    # Must match CUDN subnet
    bgpASN: 65000                   # Must match FRR config
```

### Step 4: Configure VLAN Trunk

Run the helper script:

```bash
./hack/setup-vlan.sh
```

This creates a `NodeNetworkConfigurationPolicy` to configure VLAN trunking on worker nodes.

**Monitor the rollout:**
```bash
kubectl get nncp vlan-trunk-config -w
```

Wait until `STATUS` shows `Available` on all nodes.

**Verify:**
```bash
kubectl get nnce
```

### Step 5: Deploy Network Components

```bash
kubectl apply -f manifests/01-prerequisites/namespace.yaml
kubectl apply -f manifests/02-networking/
```

**Verify CUDN:**
```bash
kubectl get clusteruserdefinednetwork vm-bgp-network
kubectl get networkattachmentdefinition -n vm-workloads
```

### Step 6: Deploy FRR-K8s

```bash
kubectl apply -f manifests/03-frr/
```

**Verify FRR pods:**
```bash
kubectl get pods -n frr-k8s-system -w
```

Wait for all pods to be `Running`.

**Check BGP session:**
```bash
FRR_POD=$(kubectl get pod -n frr-k8s-system -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp summary"
```

Expected output:
```
Neighbor        V         AS   MsgRcvd   MsgSent   Up/Down State
10.10.10.1      4      65001         5         6  00:01:23 Established
```

### Step 7: Deploy BGP-VM Controller

```bash
kubectl apply -f manifests/04-controller/
```

**Verify controller:**
```bash
kubectl get pods -n rosa-virt-bgp-system -w
```

**Check logs:**
```bash
kubectl logs -n rosa-virt-bgp-system -l app=bgp-vm-controller -f
```

Look for:
```
INFO    starting manager
INFO    starting BGP-VM controller
```

### Step 8: Deploy Example VMs

```bash
kubectl apply -f manifests/05-examples/example-vm-fedora.yaml
```

**Monitor VM creation:**
```bash
kubectl get vmi -n vm-workloads -w
```

Wait for `PHASE: Running`.

**Check VM IP:**
```bash
kubectl get vmi fedora-vm-01 -n vm-workloads \
  -o jsonpath='{.status.interfaces[1].ips[0]}'
```

### Step 9: Verify BGP Advertisement

```bash
./hack/verify-bgp.sh
```

Check:
1. FRR pods running
2. FRRConfiguration created for vm-workloads namespace
3. BGP session in "Established" state
4. VM IP advertised as /32 route

**On FRR pod:**
```bash
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp ipv4"
```

Expected output:
```
Network          Next Hop            Metric LocPrf Weight Path
*> 10.10.10.5/32    10.10.10.1               0         32768 i
```

### Step 10: Test Connectivity

From on-premises network:

```bash
# Ping VM from on-prem
ping 10.10.10.5

# SSH to VM (if configured)
ssh user@10.10.10.5

# Curl web service
curl http://10.10.10.5
```

## Verification Checklist

- [ ] NMState operator installed
- [ ] VLAN trunk configured on all worker nodes (`kubectl get nncp`)
- [ ] CUDN created (`kubectl get cudn`)
- [ ] NetworkAttachmentDefinition exists (`kubectl get nad -n vm-workloads`)
- [ ] FRR-K8s pods running (`kubectl get pods -n frr-k8s-system`)
- [ ] BGP session established (`show bgp summary`)
- [ ] Controller pods running (`kubectl get pods -n rosa-virt-bgp-system`)
- [ ] VM running with CUDN IP (`kubectl get vmi`)
- [ ] FRRConfiguration created (`kubectl get frrconfig -n frr-k8s-system`)
- [ ] VM IP advertised via BGP (`show bgp ipv4`)
- [ ] On-prem can ping VM IP

## Troubleshooting

### BGP Session Not Established

**Check neighbor configuration:**
```bash
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp neighbors"
```

**Common issues:**
- Firewall blocking TCP/179
- MD5 password mismatch
- Incorrect ASN configuration
- Network unreachable (VLAN not configured)

**Fix:**
1. Verify on-prem router config matches
2. Check security groups allow BGP traffic
3. Verify VLAN trunk is up

### VM Not Getting IP

**Check VMI status:**
```bash
kubectl get vmi -n vm-workloads -o yaml
```

**Look for:**
- `status.interfaces[]` populated
- `status.phase: Running`

**Common issues:**
- CUDN not applied to namespace
- NetworkAttachmentDefinition incorrect
- VM not started

**Debug:**
```bash
./hack/debug-vm-networking.sh fedora-vm-01 vm-workloads
```

### FRRConfiguration Not Created

**Check controller logs:**
```bash
kubectl logs -n rosa-virt-bgp-system -l app=bgp-vm-controller --tail=50
```

**Common issues:**
- Controller RBAC insufficient
- VM not in Running phase
- IP not in expected subnet

**Fix:**
1. Verify RBAC permissions
2. Wait for VM to fully boot
3. Check controller config matches CUDN subnet

### Routes Not Advertised

**Verify FRRConfiguration exists:**
```bash
kubectl get frrconfig bgp-vm-routes-vm-workloads -n frr-k8s-system -o yaml
```

**Check prefixes:**
```yaml
spec:
  bgp:
    routers:
    - prefixes:
      - 10.10.10.5/32    # Should contain VM IPs
```

**If empty:**
- Controller may not have discovered VMs yet
- Check controller logs for errors

## Uninstallation

```bash
# Remove example VMs
kubectl delete -f manifests/05-examples/

# Remove controller
kubectl delete -f manifests/04-controller/

# Remove FRR
kubectl delete -f manifests/03-frr/

# Remove networking
kubectl delete -f manifests/02-networking/

# Remove VLAN config
kubectl delete nncp vlan-trunk-config

# Remove namespaces
kubectl delete namespace rosa-virt-bgp-system frr-k8s-system vm-workloads
```

## Next Steps

- See [Configuration Reference](configuration.md) for advanced options
- See [Troubleshooting Guide](troubleshooting.md) for common issues
- Review [Architecture](architecture.md) for implementation details
