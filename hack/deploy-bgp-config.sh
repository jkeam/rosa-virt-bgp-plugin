#!/bin/bash
# Deploy BGP configuration to ROSA cluster
# Uses auto-detected configuration from setup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
if [ ! -f "$HOME/.rosa-virt-bgp/config.sh" ]; then
    echo "❌ Error: Configuration not found"
    echo "Run ./hack/setup-demo-vpn.sh first"
    exit 1
fi

source "$HOME/.rosa-virt-bgp/config.sh"

echo "========================================="
echo "Deploy BGP Configuration"
echo "========================================="
echo ""

# Check cluster connection
if ! oc cluster-info &> /dev/null; then
    echo "❌ Error: Not connected to OpenShift cluster"
    exit 1
fi

echo "Deploying FRR BGP configuration..."
echo ""

# Create FRR namespace if needed
oc create namespace frr-k8s-system 2>/dev/null || true

# Deploy BGP peer configuration with dynamic values
cat <<EOF | oc apply -f -
---
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: bgp-peers
  namespace: frr-k8s-system
spec:
  bgp:
    routers:
    - asn: $BGP_ASN_ROSA
      prefixes:
      - $VM_SECONDARY_NETWORK_CIDR
      neighbors:
      # On-prem router - peering via VPN
      - asn: $BGP_ASN_ONPREM
        address: $ONPREM_PRIVATE_IP
        port: 179
        ebgpMultiHop: true
        toReceive:
          allowed:
            mode: all
        toAdvertise:
          allowed:
            mode: filtered
            prefixes:
            - $VM_SECONDARY_NETWORK_CIDR
EOF

echo "✅ BGP peer configuration deployed"
echo ""

# Deploy secondary network configuration
echo "Deploying secondary network configuration..."

cat <<EOF | oc apply -f -
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: vm-bgp-network
spec:
  namespaceSelector:
    matchLabels:
      bgp-enabled: "true"
  network:
    topology: Layer2
    layer2:
      role: Secondary
      subnets:
      - "$VM_SECONDARY_NETWORK_CIDR"
      excludeSubnets:
      - "$(echo $VM_SECONDARY_NETWORK_CIDR | awk -F'[./]' '{print $1"."$2"."$3".1/32"}')"      # Reserve .1 for first VM
      - "$(echo $VM_SECONDARY_NETWORK_CIDR | awk -F'[./]' '{print $1"."$2"."$3".254/32"}')"    # Reserve .254 for broadcast
      ipam:
        lifecycle: Persistent
        mode: Enabled
EOF

echo "✅ Secondary network configuration deployed"
echo ""

echo "========================================="
echo "✅ BGP Configuration Complete"
echo "========================================="
echo ""
echo "Configuration deployed:"
echo "  BGP ASN (ROSA):      $BGP_ASN_ROSA"
echo "  BGP ASN (On-Prem):   $BGP_ASN_ONPREM"
echo "  On-Prem Router IP:   $ONPREM_PRIVATE_IP"
echo "  VM Secondary CIDR:   $VM_SECONDARY_NETWORK_CIDR"
echo ""
echo "Next: Deploy test VMs with:"
echo "  oc apply -f manifests/05-examples/demo-vms.yaml"
echo ""
