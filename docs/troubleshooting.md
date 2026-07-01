# Troubleshooting Guide

## Common Issues

### 1. BGP Session Not Establishing

**Symptoms:**
- `show bgp summary` shows neighbor in `Active` or `Connect` state
- No routes being advertised

**Diagnosis:**
```bash
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp neighbors 10.10.10.1"
```

**Common Causes:**

1. **Network unreachable**
   - VLAN trunk not configured
   - Security group blocking TCP/179
   - On-prem router not reachable from ROSA

   **Fix:**
   ```bash
   # Verify VLAN trunk
   kubectl get nncp vlan-trunk-config
   kubectl get nnce

   # Test connectivity from node
   oc debug node/<node-name>
   chroot /host ping 10.10.10.1
   ```

2. **MD5 password mismatch**
   - Password in Secret doesn't match on-prem router

   **Fix:**
   ```bash
   # Update secret
   kubectl edit secret bgp-peer-secret -n frr-k8s-system
   ```

3. **ASN mismatch**
   - Local or remote ASN configured incorrectly

   **Fix:** Verify ASN in `manifests/03-frr/frr-config-bgp-peer.yaml`

### 2. VMs Not Getting IPs

**Symptoms:**
- VMI shows `Running` but no IP in status
- IPAMClaim not created

**Diagnosis:**
```bash
kubectl get vmi <vm-name> -n vm-workloads -o yaml | grep -A 20 interfaces
kubectl get ipamclaim -n vm-workloads
```

**Common Causes:**

1. **CUDN not applied to namespace**
   - Namespace missing `bgp-enabled: "true"` label

   **Fix:**
   ```bash
   kubectl label namespace vm-workloads bgp-enabled=true
   ```

2. **NetworkAttachmentDefinition incorrect**
   - Wrong namespace or missing

   **Fix:**
   ```bash
   kubectl get nad -n vm-workloads
   kubectl apply -f manifests/02-networking/nad.yaml
   ```

3. **IPAM exhausted**
   - All IPs in subnet allocated

   **Fix:**
   ```bash
   # Check allocated IPs
   kubectl get ipamclaim -n vm-workloads
   # Expand subnet or delete unused VMs
   ```

### 3. FRRConfiguration Not Created

**Symptoms:**
- VM running with IP but no FRRConfiguration
- Routes not advertised

**Diagnosis:**
```bash
kubectl logs -n rosa-virt-bgp-system -l app=bgp-vm-controller --tail=100
kubectl get frrconfig -n frr-k8s-system
```

**Common Causes:**

1. **Controller RBAC insufficient**
   - ServiceAccount missing permissions

   **Fix:**
   ```bash
   kubectl apply -f manifests/04-controller/rbac.yaml
   ```

2. **VM IP outside configured subnet**
   - Controller filters IPs not in `cudnSubnet`

   **Fix:** Verify ConfigMap subnet matches CUDN:
   ```bash
   kubectl get configmap bgp-vm-controller-config -n rosa-virt-bgp-system -o yaml
   ```

3. **VM not detected as having CUDN interface**
   - Network name mismatch

   **Fix:** Verify `networkName` in ConfigMap matches VM spec

### 4. Routes Not Being Advertised

**Symptoms:**
- FRRConfiguration exists with prefixes
- BGP session established
- Routes not in `show bgp ipv4`

**Diagnosis:**
```bash
kubectl get frrconfig bgp-vm-routes-vm-workloads -n frr-k8s-system -o yaml
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp ipv4"
```

**Common Causes:**

1. **Prefix filtering too restrictive**
   - `toAdvertise.allowed.mode: filtered` blocking routes

   **Fix:** Check neighbor config allows VM subnet

2. **FRR not reloading config**
   - FRR-K8s daemon issue

   **Fix:**
   ```bash
   # Check FRR-K8s logs
   kubectl logs -n frr-k8s-system -l app=frr-k8s --tail=50

   # Restart FRR pod
   kubectl delete pod -n frr-k8s-system -l app=frr-k8s
   ```

### 5. VM Migration Breaks Connectivity

**Symptoms:**
- VM migrated successfully
- IP remains same but unreachable

**Common Causes:**

1. **VLAN not available on destination node**
   - NNCP not applied to all nodes

   **Fix:**
   ```bash
   kubectl get nnce
   # Ensure all nodes have vlan-trunk-config applied
   ```

2. **BGP route not updated**
   - Rare controller sync issue

   **Fix:**
   ```bash
   # Force reconciliation
   kubectl annotate vmi <vm-name> -n vm-workloads \
     rosa-virt-bgp.io/force-sync="$(date +%s)"
   ```

## Debugging Commands

### Check BGP Status

```bash
FRR_POD=$(kubectl get pod -n frr-k8s-system -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}')

# BGP summary
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp summary"

# BGP neighbors detail
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp neighbors"

# Advertised routes
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp ipv4 unicast neighbors 10.10.10.1 advertised-routes"

# Received routes
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bgp ipv4 unicast neighbors 10.10.10.1 routes"

# BFD status
kubectl exec -n frr-k8s-system $FRR_POD -- vtysh -c "show bfd peers"
```

### Check VM Networking

```bash
# VM status
kubectl get vmi <vm-name> -n vm-workloads -o yaml

# VM interfaces
kubectl get vmi <vm-name> -n vm-workloads \
  -o jsonpath='{.status.interfaces}' | jq '.'

# IPAMClaim
kubectl get ipamclaim -n vm-workloads

# Use debug script
./hack/debug-vm-networking.sh <vm-name> vm-workloads
```

### Check Controller

```bash
# Controller logs
kubectl logs -n rosa-virt-bgp-system -l app=bgp-vm-controller -f

# Controller status
kubectl get pods -n rosa-virt-bgp-system

# Leader election
kubectl get lease -n rosa-virt-bgp-system

# Metrics
kubectl port-forward -n rosa-virt-bgp-system svc/bgp-vm-controller-metrics 8080:8080
curl localhost:8080/metrics
```

### Check Network Configuration

```bash
# VLAN trunk status
kubectl get nncp vlan-trunk-config
kubectl get nnce

# CUDN
kubectl get cudn vm-bgp-network -o yaml

# NetworkAttachmentDefinition
kubectl get nad -n vm-workloads

# OVS bridges on node
oc debug node/<node-name>
chroot /host ovs-vsctl show
```

## Verification Script

Use the automated verification script:

```bash
./hack/verify-bgp.sh
```

This checks:
- FRR pods running
- FRRConfiguration resources
- BGP session status
- Advertised routes
- Controller status
- VM status and IPs

## Getting Help

If issues persist:

1. **Collect diagnostics:**
   ```bash
   # Create diagnostic bundle
   mkdir -p diagnostics
   kubectl get all -n rosa-virt-bgp-system -o yaml > diagnostics/controller.yaml
   kubectl get all -n frr-k8s-system -o yaml > diagnostics/frr.yaml
   kubectl logs -n rosa-virt-bgp-system -l app=bgp-vm-controller > diagnostics/controller.log
   kubectl logs -n frr-k8s-system -l app=frr-k8s > diagnostics/frr.log
   kubectl get frrconfig -n frr-k8s-system -o yaml > diagnostics/frrconfig.yaml
   ```

2. **Check documentation:**
   - [Architecture](architecture.md)
   - [Installation Guide](installation.md)
   - [Configuration Reference](configuration.md)

3. **File an issue:**
   - Include diagnostic bundle
   - Describe expected vs actual behavior
   - Include relevant logs and manifests
