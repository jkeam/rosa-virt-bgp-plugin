#!/bin/bash
# Verify BGP setup and routing

set -e

# Load configuration
if [ ! -f "$HOME/.rosa-virt-bgp/config.sh" ]; then
    echo "❌ Error: Configuration not found"
    echo "Run ./hack/setup-demo-vpn.sh first"
    exit 1
fi

source "$HOME/.rosa-virt-bgp/config.sh"

echo "========================================="
echo "BGP Verification"
echo "========================================="
echo ""

echo "On-Prem Router ($ONPREM_PUBLIC_IP)"
echo "===================================="
echo ""

# Check on-prem router BGP
echo "BGP Summary:"
ssh -i ~/.ssh/$SSH_KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$ONPREM_PUBLIC_IP \
    "sudo vtysh -c 'show bgp summary'" 2>/dev/null || echo "❌ Could not connect to on-prem router"

echo ""
echo "BGP Routes:"
ssh -i ~/.ssh/$SSH_KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$ONPREM_PUBLIC_IP \
    "sudo vtysh -c 'show bgp ipv4 unicast'" 2>/dev/null || true

echo ""
echo ""
echo "ROSA Cluster"
echo "============"
echo ""

# Check ROSA FRR-K8s
if ! oc get pods -n frr-k8s-system &>/dev/null; then
    echo "❌ FRR-K8s not deployed in cluster"
    echo "Deploy with: oc apply -f manifests/03-frr/"
    exit 1
fi

FRR_POD=$(oc get pods -n frr-k8s-system -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$FRR_POD" ]; then
    echo "❌ No FRR-K8s pods found"
    exit 1
fi

echo "BGP Summary (from $FRR_POD):"
oc exec -n frr-k8s-system "$FRR_POD" -c frr -- vtysh -c 'show bgp summary' 2>/dev/null || echo "❌ Could not get BGP status"

echo ""
echo "BGP Routes:"
oc exec -n frr-k8s-system "$FRR_POD" -c frr -- vtysh -c 'show bgp ipv4 unicast' 2>/dev/null || true

echo ""
echo "Advertised Routes to On-Prem:"
oc exec -n frr-k8s-system "$FRR_POD" -c frr -- vtysh -c "show bgp ipv4 unicast neighbors $ONPREM_PRIVATE_IP advertised-routes" 2>/dev/null || true

echo ""
echo ""
echo "VPN Status"
echo "=========="
echo ""

# Check AWS VPN status
echo "AWS VPN Connection:"
aws ec2 describe-vpn-connections \
    --region "$AWS_REGION" \
    --vpn-connection-ids "$VPN_CONN_ID" \
    --query 'VpnConnections[0].VgwTelemetry[*].{Tunnel:OutsideIpAddress,Status:Status,Message:StatusMessage,BGPRoutes:AcceptedRouteCount}' \
    --output table 2>/dev/null || echo "❌ Could not get VPN status"

echo ""
echo "ROSA VPC Route Tables:"
aws ec2 describe-route-tables \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$ROSA_VPC_ID" \
    --query "RouteTables[].Routes[?Origin=='EnableVgwRoutePropagation'].{Destination:DestinationCidrBlock,Gateway:GatewayId,Origin:Origin}" \
    --output table 2>/dev/null || true

echo ""
echo ""
echo "Connectivity Test"
echo "================="
echo ""

# Test connectivity
echo "Ping from on-prem to ROSA node:"
ROSA_NODE_IP=$(echo $ROSA_NODE_IPS | awk '{print $1}')
ssh -i ~/.ssh/$SSH_KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$ONPREM_PUBLIC_IP \
    "ping -c 3 -I $ONPREM_PRIVATE_IP $ROSA_NODE_IP" 2>/dev/null || echo "❌ Ping failed"

echo ""
echo "========================================="
echo "Verification Complete"
echo "========================================="
echo ""

# Summary
echo "Expected BGP Configuration:"
echo "  On-Prem ASN:     $BGP_ASN_ONPREM"
echo "  ROSA ASN:        $BGP_ASN_ROSA"
echo "  On-Prem CIDR:    $ONPREM_VPC_CIDR"
echo "  ROSA CIDR:       $ROSA_VPC_CIDR"
echo "  VM Network:      $VM_SECONDARY_NETWORK_CIDR"
echo ""
