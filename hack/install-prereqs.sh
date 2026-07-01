#!/bin/bash
set -e

echo "Installing prerequisites for ROSA Virt BGP Plugin..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl first."
    exit 1
fi

echo "✓ kubectl found"

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "Error: Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✓ Connected to cluster"

# Install FRR-K8s CRDs
echo "Installing FRR-K8s CRDs..."
kubectl apply -f https://raw.githubusercontent.com/metallb/frr-k8s/v0.0.14/config/crd/bases/frrk8s.metallb.io_frrconfigurations.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/frr-k8s/v0.0.14/config/crd/bases/frrk8s.metallb.io_frrnodestates.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/frr-k8s/v0.0.14/config/crd/bases/frrk8s.metallb.io_bfdprofiles.yaml

echo "✓ FRR-K8s CRDs installed"

# Check if OpenShift Virtualization is installed
if kubectl get crd virtualmachineinstances.kubevirt.io &> /dev/null; then
    echo "✓ OpenShift Virtualization detected"
else
    echo "⚠ Warning: OpenShift Virtualization CRDs not found"
    echo "  Please ensure OpenShift Virtualization operator is installed"
fi

# Check if NMState operator is available
if kubectl get crd nodenetworkconfigurationpolicies.nmstate.io &> /dev/null; then
    echo "✓ Kubernetes NMState Operator detected"
else
    echo "⚠ Warning: NMState CRDs not found"
    echo "  VLAN trunk configuration requires the Kubernetes NMState Operator"
    echo "  Install from OperatorHub or skip VLAN configuration"
fi

echo ""
echo "Prerequisites check complete!"
echo ""
echo "Next steps:"
echo "  1. Review and customize manifests in manifests/ directory"
echo "  2. Update BGP ASN, router IPs, and VLAN configuration"
echo "  3. Run 'make deploy' to install the controller"
