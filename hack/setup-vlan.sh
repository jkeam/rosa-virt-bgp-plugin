#!/bin/bash
set -e

echo "VLAN Trunk Setup Helper for ROSA"
echo "=================================="
echo ""
echo "This script helps configure VLAN trunking on ROSA worker nodes."
echo "It requires the Kubernetes NMState Operator to be installed."
echo ""

# Check if NMState operator is installed
if ! kubectl get crd nodenetworkconfigurationpolicies.nmstate.io &> /dev/null; then
    echo "Error: Kubernetes NMState Operator not found"
    echo "Please install the NMState operator from OperatorHub first"
    exit 1
fi

echo "✓ NMState operator detected"
echo ""

# Prompt for configuration
read -p "Enter VLAN ID (default: 100): " VLAN_ID
VLAN_ID=${VLAN_ID:-100}

read -p "Enter physical interface name (default: ens5): " INTERFACE
INTERFACE=${INTERFACE:-ens5}

read -p "Enter OVS bridge name (default: br-vlan): " BRIDGE
BRIDGE=${BRIDGE:-br-vlan}

echo ""
echo "Configuration:"
echo "  VLAN ID: $VLAN_ID"
echo "  Interface: $INTERFACE"
echo "  Bridge: $BRIDGE"
echo ""

read -p "Apply this configuration? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled"
    exit 0
fi

# Create NNCP
cat <<EOF | kubectl apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: vlan-trunk-config
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
    - name: $BRIDGE
      type: ovs-bridge
      state: up
      bridge:
        options:
          stp: false
        port:
        - name: ${INTERFACE}.${VLAN_ID}
          vlan:
            base-iface: $INTERFACE
            id: $VLAN_ID
        - name: $BRIDGE
    - name: ${INTERFACE}.${VLAN_ID}
      type: vlan
      state: up
      vlan:
        base-iface: $INTERFACE
        id: $VLAN_ID
EOF

echo ""
echo "✓ NodeNetworkConfigurationPolicy created"
echo ""
echo "Next steps:"
echo "  1. Wait for NNCP to be applied to all nodes:"
echo "     kubectl get nncp vlan-trunk-config -w"
echo "  2. Verify network state on nodes:"
echo "     kubectl get nnce"
echo "  3. Update manifests/02-networking/user-defined-network.yaml"
echo "     to reference the correct bridge mapping"
