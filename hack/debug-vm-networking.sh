#!/bin/bash

# Debug VM Networking Script
# Usage: ./debug-vm-networking.sh [vm-name] [namespace]

VM_NAME=${1:-""}
NAMESPACE=${2:-"vm-workloads"}

if [ -z "$VM_NAME" ]; then
    echo "Usage: $0 <vm-name> [namespace]"
    echo ""
    echo "Available VMs:"
    kubectl get vmi -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase
    exit 1
fi

echo "Debugging VM: $VM_NAME in namespace: $NAMESPACE"
echo "======================================================"
echo ""

# Check if VM exists
if ! kubectl get vmi "$VM_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo "Error: VirtualMachineInstance '$VM_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

# Get VM details
echo "1. VM Status:"
kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o yaml | grep -A 20 "status:"
echo ""

# Get network interfaces
echo "2. Network Interfaces:"
kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces}' | jq '.'
echo ""

# Check annotations
echo "3. Annotations:"
kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations}' | jq '.'
echo ""

# Check IPAMClaim if referenced
echo "4. IPAMClaim (if any):"
IPAM_CLAIM=$(kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/ipamclaim-reference}')
if [ -n "$IPAM_CLAIM" ]; then
    kubectl get ipamclaim "$IPAM_CLAIM" -n "$NAMESPACE" -o yaml
else
    echo "No IPAMClaim annotation found"
fi
echo ""

# Check FRRConfiguration for this namespace
echo "5. FRRConfiguration for namespace:"
FRR_CONFIG_NAME="bgp-vm-routes-$NAMESPACE"
if kubectl get frrconfig "$FRR_CONFIG_NAME" -n frr-k8s-system &> /dev/null; then
    kubectl get frrconfig "$FRR_CONFIG_NAME" -n frr-k8s-system -o yaml | grep -A 50 "spec:"
else
    echo "No FRRConfiguration found for this namespace"
fi
echo ""

# Check pod for this VMI
echo "6. Associated Pod:"
POD_NAME=$(kubectl get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.name}')
if kubectl get pod "virt-launcher-$POD_NAME" -n "$NAMESPACE" &> /dev/null; then
    kubectl get pod "virt-launcher-$POD_NAME" -n "$NAMESPACE"
    echo ""
    echo "Pod Network Details:"
    kubectl exec -n "$NAMESPACE" "virt-launcher-$POD_NAME" -- ip addr show || echo "Cannot execute in pod"
else
    echo "No virt-launcher pod found"
fi

echo ""
echo "======================================================"
echo "Debug complete!"
echo ""
echo "Common issues:"
echo "  - VM Phase not 'Running': Wait for VM to fully boot"
echo "  - No IPs in interfaces: Check CUDN configuration and IPAM"
echo "  - No FRRConfiguration: Check controller logs for errors"
echo "  - IPs outside expected subnet: Check CUDN subnet configuration"
