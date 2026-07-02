#!/bin/bash
# Setup two-VPC demo with Site-to-Site VPN
# VPC 1: ROSA cluster (existing)
# VPC 2: Simulated "on-premises" datacenter with strongSwan/FRR router

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/auto-config.sh"

echo "========================================="
echo "AWS Site-to-Site VPN Demo Setup"
echo "========================================="
echo ""
echo "This creates:"
echo "  • Second VPC as simulated on-prem datacenter"
echo "  • EC2 instance running strongSwan + FRR"
echo "  • Site-to-Site VPN with BGP peering"
echo "  • Full bidirectional routing"
echo ""
echo "Cost: ~\$0.05-0.10/hour (~\$1-2 for full demo)"
echo ""

# Check for auto-confirm flag
AUTO_CONFIRM=${AUTO_CONFIRM:-false}

# Check prerequisites
echo "Checking prerequisites..."
if ! command -v aws &> /dev/null; then
    echo "❌ Error: AWS CLI not found"
    echo "Install: brew install awscli"
    exit 1
fi

if ! command -v oc &> /dev/null; then
    echo "❌ Error: oc CLI not found"
    exit 1
fi

if ! oc cluster-info &> /dev/null; then
    echo "❌ Error: Not connected to OpenShift cluster"
    echo "Run: oc login"
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ Error: AWS credentials not configured"
    exit 1
fi

# Show which AWS account/profile
AWS_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text)
if [ -n "$AWS_PROFILE" ]; then
    echo "✅ AWS CLI configured (profile: $AWS_PROFILE, account: $AWS_ACCOUNT)"
else
    echo "✅ AWS CLI configured (account: $AWS_ACCOUNT)"
fi

echo ""

# Auto-detect and generate configuration
auto_configure || exit 1

# Show configuration
print_config

if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Continue with this configuration? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Create "on-prem" VPC
echo ""
echo "Creating simulated on-premises VPC..."
export ONPREM_VPC_ID=$(aws ec2 create-vpc \
  --region "$AWS_REGION" \
  --cidr-block "$ONPREM_VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=rosa-virt-bgp-onprem}]" \
  --query 'Vpc.VpcId' \
  --output text)

echo "✅ On-prem VPC: $ONPREM_VPC_ID"

# Enable DNS hostnames
aws ec2 modify-vpc-attribute \
  --region "$AWS_REGION" \
  --vpc-id "$ONPREM_VPC_ID" \
  --enable-dns-hostnames

# Create Internet Gateway for on-prem VPC
echo "  Creating Internet Gateway..."
export ONPREM_IGW=$(aws ec2 create-internet-gateway \
  --region "$AWS_REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=rosa-virt-bgp-onprem-igw}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --region "$AWS_REGION" \
  --vpc-id "$ONPREM_VPC_ID" \
  --internet-gateway-id "$ONPREM_IGW"

# Create subnet
echo "  Creating subnet..."
export ONPREM_SUBNET=$(aws ec2 create-subnet \
  --region "$AWS_REGION" \
  --vpc-id "$ONPREM_VPC_ID" \
  --cidr-block "$ONPREM_SUBNET_CIDR" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=rosa-virt-bgp-onprem-subnet}]" \
  --query 'Subnet.SubnetId' \
  --output text)

# Create route table
echo "  Creating route table..."
export ONPREM_RT=$(aws ec2 create-route-table \
  --region "$AWS_REGION" \
  --vpc-id "$ONPREM_VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=rosa-virt-bgp-onprem-rt}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)

# Add default route via IGW
aws ec2 create-route \
  --region "$AWS_REGION" \
  --route-table-id "$ONPREM_RT" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$ONPREM_IGW" >/dev/null

# Associate route table with subnet
aws ec2 associate-route-table \
  --region "$AWS_REGION" \
  --subnet-id "$ONPREM_SUBNET" \
  --route-table-id "$ONPREM_RT" >/dev/null

# Create security group for on-prem router
echo "  Creating security group..."
export ONPREM_SG=$(aws ec2 create-security-group \
  --region "$AWS_REGION" \
  --vpc-id "$ONPREM_VPC_ID" \
  --group-name rosa-virt-bgp-router-sg \
  --description "Security group for ROSA virt BGP demo router" \
  --query 'GroupId' \
  --output text)

# Allow SSH from anywhere
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ONPREM_SG" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 >/dev/null

# Allow IPsec (for VPN)
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ONPREM_SG" \
  --protocol udp \
  --port 500 \
  --cidr 0.0.0.0/0 >/dev/null

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ONPREM_SG" \
  --protocol udp \
  --port 4500 \
  --cidr 0.0.0.0/0 >/dev/null

# Allow ESP protocol (IPsec)
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ONPREM_SG" \
  --ip-permissions IpProtocol=50,IpRanges=[{CidrIp=0.0.0.0/0}] >/dev/null

# Allow all from ROSA VPC
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ONPREM_SG" \
  --protocol all \
  --cidr "$ROSA_VPC_CIDR" >/dev/null

# Allow all internal traffic
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ONPREM_SG" \
  --protocol all \
  --cidr "$ONPREM_VPC_CIDR" >/dev/null

echo "✅ On-prem VPC infrastructure created"

# Get or create SSH key pair
echo ""
echo "Setting up SSH key..."
if ! aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$SSH_KEY_NAME" &>/dev/null; then
    aws ec2 create-key-pair \
      --region "$AWS_REGION" \
      --key-name "$SSH_KEY_NAME" \
      --query 'KeyMaterial' \
      --output text > ~/.ssh/$SSH_KEY_NAME.pem
    chmod 600 ~/.ssh/$SSH_KEY_NAME.pem
    echo "✅ Created SSH key: ~/.ssh/$SSH_KEY_NAME.pem"
else
    echo "✅ Using existing SSH key: $SSH_KEY_NAME"
    if [ ! -f ~/.ssh/$SSH_KEY_NAME.pem ]; then
        echo "⚠️  Warning: Key exists in AWS but not found locally at ~/.ssh/$SSH_KEY_NAME.pem"
    fi
fi

# Get AMI ID based on configuration
echo ""
echo "Finding ${ONPREM_OS} AMI (${ONPREM_INSTANCE_ARCH})..."

case "$ONPREM_OS" in
    centos-stream-10)
        # CentOS Stream 10 from official owner (different naming pattern)
        AMI_ID=$(aws ec2 describe-images \
          --region "$AWS_REGION" \
          --owners 125523088429 \
          --filters \
              "Name=name,Values=CentOS Stream 10 ${ONPREM_INSTANCE_ARCH}*" \
              "Name=state,Values=available" \
          --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
          --output text)
        ;;
    amazon-linux-2023)
        AMI_ID=$(aws ec2 describe-images \
          --region "$AWS_REGION" \
          --owners amazon \
          --filters \
              "Name=name,Values=al2023-ami-2023.*-kernel-6.1-${ONPREM_INSTANCE_ARCH}" \
              "Name=state,Values=available" \
          --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
          --output text)
        ;;
    *)
        echo "❌ Error: Unsupported OS: $ONPREM_OS"
        exit 1
        ;;
esac

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
    echo "❌ Error: Could not find AMI for $ONPREM_OS ($ONPREM_INSTANCE_ARCH)"
    exit 1
fi

echo "✅ AMI: $AMI_ID"

# Launch EC2 instance
echo ""
echo "Launching EC2 instance ($ONPREM_INSTANCE_TYPE)..."
export INSTANCE_ID=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$ONPREM_INSTANCE_TYPE" \
  --key-name "$SSH_KEY_NAME" \
  --subnet-id "$ONPREM_SUBNET" \
  --security-group-ids "$ONPREM_SG" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=rosa-virt-bgp-router}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "✅ Instance launching: $INSTANCE_ID"

# Wait for instance to be running
echo "  Waiting for instance to be running..."
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

# Get instance IPs
export ONPREM_PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

export ONPREM_PRIVATE_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo "✅ Instance running"
echo "   Public IP: $ONPREM_PUBLIC_IP"
echo "   Private IP: $ONPREM_PRIVATE_IP"

# Create VPN Gateway
echo ""
echo "Creating AWS Site-to-Site VPN..."
echo "  Creating VPN Gateway..."
export VGW_ID=$(aws ec2 create-vpn-gateway \
  --region "$AWS_REGION" \
  --type ipsec.1 \
  --amazon-side-asn "$BGP_ASN_ROSA" \
  --tag-specifications "ResourceType=vpn-gateway,Tags=[{Key=Name,Value=rosa-virt-bgp-vgw}]" \
  --query 'VpnGateway.VpnGatewayId' \
  --output text)

echo "✅ VPN Gateway: $VGW_ID"

# Attach to ROSA VPC
echo "  Attaching VPN Gateway to ROSA VPC..."
aws ec2 attach-vpn-gateway \
  --region "$AWS_REGION" \
  --vpn-gateway-id "$VGW_ID" \
  --vpc-id "$ROSA_VPC_ID" >/dev/null

# Wait for attachment
sleep 5

# Enable route propagation on ROSA VPC route tables
echo "  Enabling route propagation..."
for RT in $(aws ec2 describe-route-tables \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$ROSA_VPC_ID" \
  --query 'RouteTables[*].RouteTableId' \
  --output text); do
  aws ec2 enable-vgw-route-propagation \
    --region "$AWS_REGION" \
    --route-table-id "$RT" \
    --gateway-id "$VGW_ID" 2>/dev/null || true
done

# Add route for VPN tunnel inside network to ROSA subnet route tables
echo "  Adding route for VPN tunnel inside network..."
ROSA_SUBNET=$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$ROSA_VPC_ID" "Name=cidr-block,Values=$(echo $ROSA_VPC_CIDR | cut -d/ -f1 | awk -F. '{print $1"."$2".1.0/24"}')" \
  --query 'Subnets[0].SubnetId' \
  --output text)

if [ -n "$ROSA_SUBNET" ] && [ "$ROSA_SUBNET" != "None" ]; then
    ROSA_RT=$(aws ec2 describe-route-tables \
      --region "$AWS_REGION" \
      --filters "Name=association.subnet-id,Values=$ROSA_SUBNET" \
      --query 'RouteTables[0].RouteTableId' \
      --output text)

    if [ -n "$ROSA_RT" ] && [ "$ROSA_RT" != "None" ]; then
        aws ec2 create-route \
          --region "$AWS_REGION" \
          --route-table-id "$ROSA_RT" \
          --destination-cidr-block 169.254.0.0/16 \
          --gateway-id "$VGW_ID" 2>/dev/null || true
    fi
fi

# Create Customer Gateway
echo "  Creating Customer Gateway..."
export CGW_ID=$(aws ec2 create-customer-gateway \
  --region "$AWS_REGION" \
  --type ipsec.1 \
  --public-ip "$ONPREM_PUBLIC_IP" \
  --bgp-asn "$BGP_ASN_ONPREM" \
  --tag-specifications "ResourceType=customer-gateway,Tags=[{Key=Name,Value=rosa-virt-bgp-cgw}]" \
  --query 'CustomerGateway.CustomerGatewayId' \
  --output text)

echo "✅ Customer Gateway: $CGW_ID"

# Create VPN Connection
echo "  Creating VPN Connection (this takes ~5 minutes)..."
export VPN_CONN_ID=$(aws ec2 create-vpn-connection \
  --region "$AWS_REGION" \
  --type ipsec.1 \
  --customer-gateway-id "$CGW_ID" \
  --vpn-gateway-id "$VGW_ID" \
  --options "StaticRoutesOnly=false,TunnelOptions=[{PreSharedKey='$VPN_PSK'}]" \
  --tag-specifications "ResourceType=vpn-connection,Tags=[{Key=Name,Value=rosa-virt-bgp-vpn}]" \
  --query 'VpnConnection.VpnConnectionId' \
  --output text)

echo "✅ VPN Connection: $VPN_CONN_ID"

# Wait for VPN to be available
echo "  Waiting for VPN to be available..."
aws ec2 wait vpn-connection-available --region "$AWS_REGION" --vpn-connection-ids "$VPN_CONN_ID"

# Get VPN tunnel details
echo "  Getting VPN tunnel details..."
VPN_DETAILS=$(aws ec2 describe-vpn-connections \
  --region "$AWS_REGION" \
  --vpn-connection-ids "$VPN_CONN_ID" \
  --query 'VpnConnections[0]' \
  --output json)

export TUNNEL1_IP=$(echo "$VPN_DETAILS" | jq -r '.VgwTelemetry[0].OutsideIpAddress')
export TUNNEL1_INSIDE_CGW=$(echo "$VPN_DETAILS" | jq -r '.Options.TunnelOptions[0].TunnelInsideCidr' | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3"."$4+2}')
export TUNNEL1_INSIDE_VGW=$(echo "$VPN_DETAILS" | jq -r '.Options.TunnelOptions[0].TunnelInsideCidr' | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3"."$4+1}')

echo "✅ VPN tunnel ready"
echo "   Tunnel 1 Outside: $TUNNEL1_IP"
echo "   Tunnel 1 Inside: $TUNNEL1_INSIDE_CGW (CGW) <-> $TUNNEL1_INSIDE_VGW (VGW)"

# Update saved configuration with deployment details
cat >> "$HOME/.rosa-virt-bgp/config.sh" <<EOF

# Deployment Details (added after setup)
export ONPREM_VPC_ID=$ONPREM_VPC_ID
export ONPREM_SUBNET=$ONPREM_SUBNET
export ONPREM_SG=$ONPREM_SG
export ONPREM_IGW=$ONPREM_IGW
export ONPREM_RT=$ONPREM_RT
export INSTANCE_ID=$INSTANCE_ID
export ONPREM_PUBLIC_IP=$ONPREM_PUBLIC_IP
export ONPREM_PRIVATE_IP=$ONPREM_PRIVATE_IP
export VGW_ID=$VGW_ID
export CGW_ID=$CGW_ID
export VPN_CONN_ID=$VPN_CONN_ID
export TUNNEL1_IP=$TUNNEL1_IP
export TUNNEL1_INSIDE_CGW=$TUNNEL1_INSIDE_CGW
export TUNNEL1_INSIDE_VGW=$TUNNEL1_INSIDE_VGW
EOF

# Add security group rule for on-prem CIDR to ROSA nodes
echo ""
echo "Updating ROSA node security groups..."
ROSA_NODE_SG=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids $(oc get nodes -o jsonpath='{.items[0].spec.providerID}' | cut -d/ -f5) \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ROSA_NODE_SG" \
  --protocol all \
  --cidr "$ONPREM_VPC_CIDR" 2>/dev/null || echo "  (rule may already exist)"

echo ""
echo "========================================="
echo "✅ Setup Complete!"
echo "========================================="
echo ""
echo "Configuration saved to: ~/.rosa-virt-bgp/config.sh"
echo ""
echo "Next steps:"
echo ""
echo "1. Wait ~2 minutes for EC2 instance to finish initialization"
echo ""
echo "2. Configure strongSwan and FRR on the on-prem router:"
echo "   ./hack/configure-onprem-router.sh"
echo ""
echo "3. Deploy BGP configuration to ROSA cluster:"
echo "   ./hack/deploy-bgp-config.sh"
echo ""
echo "4. Deploy test VMs and watch BGP routes:"
echo "   oc apply -f manifests/02-networking/user-defined-network.yaml"
echo "   oc apply -f manifests/05-examples/demo-vms.yaml"
echo ""
echo "5. Verify BGP is working:"
echo "   ./hack/verify-bgp.sh"
echo ""
echo "6. SSH to on-prem router:"
echo "   ssh -i ~/.ssh/$SSH_KEY_NAME.pem ec2-user@$ONPREM_PUBLIC_IP"
echo ""
echo "7. When done, cleanup:"
echo "   ./hack/cleanup-demo-vpn.sh"
echo ""
echo "Estimated cost: ~\$0.05-0.10/hour while running"
echo ""
