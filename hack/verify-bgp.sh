#!/bin/bash
set -e

echo "Verifying BGP Configuration and Peering Status..."
echo "================================================="
echo ""

# Check if FRR pods are running
echo "1. Checking FRR-K8s pods..."
if kubectl get pods -n frr-k8s-system -l app=frr-k8s &> /dev/null; then
    kubectl get pods -n frr-k8s-system -l app=frr-k8s
    echo "✓ FRR-K8s pods found"
else
    echo "✗ FRR-K8s pods not found"
    exit 1
fi

echo ""

# Check FRRConfigurations
echo "2. Checking FRRConfiguration resources..."
kubectl get frrconfigurations -n frr-k8s-system
echo ""

# Check BGP session status on first FRR pod
echo "3. Checking BGP session status..."
FRR_POD=$(kubectl get pods -n frr-k8s-system -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}')

if [ -z "$FRR_POD" ]; then
    echo "✗ No FRR pods found"
    exit 1
fi

echo "Using pod: $FRR_POD"
echo ""

echo "BGP Summary:"
kubectl exec -n frr-k8s-system "$FRR_POD" -- vtysh -c "show bgp summary" || echo "BGP not configured yet"
echo ""

echo "BGP IPv4 Routes:"
kubectl exec -n frr-k8s-system "$FRR_POD" -- vtysh -c "show bgp ipv4 unicast" || echo "No routes advertised yet"
echo ""

# Check BFD status
echo "4. Checking BFD status..."
kubectl exec -n frr-k8s-system "$FRR_POD" -- vtysh -c "show bfd peers" || echo "BFD not configured"
echo ""

# Check controller status
echo "5. Checking BGP-VM Controller status..."
if kubectl get pods -n rosa-virt-bgp-system -l app=bgp-vm-controller &> /dev/null; then
    kubectl get pods -n rosa-virt-bgp-system -l app=bgp-vm-controller
    echo "✓ Controller pods found"
else
    echo "✗ Controller pods not found"
fi

echo ""

# Check VMs with BGP annotations
echo "6. Checking VMs with BGP network..."
if kubectl get vmi -n vm-workloads &> /dev/null; then
    echo "VirtualMachineInstances:"
    kubectl get vmi -n vm-workloads -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,IPS:.status.interfaces[*].ips
else
    echo "No VirtualMachineInstances found in vm-workloads namespace"
fi

echo ""
echo "================================================="
echo "Verification complete!"
