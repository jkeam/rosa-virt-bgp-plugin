#!/bin/bash
# Setup two-VPC demo with Site-to-Site VPN
# VPC 1: ROSA cluster (existing)
# VPC 2: Simulated "on-premises" datacenter with FRR router

set -e

echo "========================================="
echo "AWS Site-to-Site VPN Demo Setup"
echo "========================================="
echo ""
echo "This creates:"
echo "  • Second VPC (172.16.0.0/16) as simulated on-prem"
echo "  • EC2 instance running FRR (BGP router)"
echo "  • Site-to-Site VPN with BGP peering"
echo "  • Full bidirectional routing"
echo ""
echo "Cost: ~\$0.06/hour (~\$1.50 for full demo)"
echo ""

# Check for auto-confirm flag
AUTO_CONFIRM=${AUTO_CONFIRM:-false}

# Check prerequisites
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

if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Continue? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Get AWS region from cluster
export AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
echo ""
echo "✅ Region: $AWS_REGION"

# Get ROSA VPC
echo ""
echo "Getting ROSA VPC information..."
INSTANCE_ID=$(oc get nodes -o jsonpath='{.items[0].spec.providerID}' | cut -d/ -f5)
export ROSA_VPC_ID=$(aws ec2 describe-instances \
  --region $AWS_REGION \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text)

echo "✅ ROSA VPC: $ROSA_VPC_ID"

# Create "on-prem" VPC
echo ""
echo "Creating simulated on-premises VPC..."
export ONPREM_VPC_ID=$(aws ec2 create-vpc \
  --region $AWS_REGION \
  --cidr-block 172.16.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=demo-onprem-vpc}]' \
  --query 'Vpc.VpcId' \
  --output text)

echo "✅ On-prem VPC: $ONPREM_VPC_ID"

# Enable DNS hostnames
aws ec2 modify-vpc-attribute \
  --region $AWS_REGION \
  --vpc-id $ONPREM_VPC_ID \
  --enable-dns-hostnames

# Create Internet Gateway for on-prem VPC
echo "  Creating Internet Gateway..."
ONPREM_IGW=$(aws ec2 create-internet-gateway \
  --region $AWS_REGION \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=demo-onprem-igw}]' \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --region $AWS_REGION \
  --vpc-id $ONPREM_VPC_ID \
  --internet-gateway-id $ONPREM_IGW

# Create subnet
echo "  Creating subnet..."
export ONPREM_SUBNET=$(aws ec2 create-subnet \
  --region $AWS_REGION \
  --vpc-id $ONPREM_VPC_ID \
  --cidr-block 172.16.1.0/24 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=demo-onprem-subnet}]' \
  --query 'Subnet.SubnetId' \
  --output text)

# Create route table
echo "  Creating route table..."
ONPREM_RT=$(aws ec2 create-route-table \
  --region $AWS_REGION \
  --vpc-id $ONPREM_VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=demo-onprem-rt}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

# Add default route via IGW
aws ec2 create-route \
  --region $AWS_REGION \
  --route-table-id $ONPREM_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $ONPREM_IGW >/dev/null

# Associate route table with subnet
aws ec2 associate-route-table \
  --region $AWS_REGION \
  --subnet-id $ONPREM_SUBNET \
  --route-table-id $ONPREM_RT >/dev/null

# Create security group for on-prem router
echo "  Creating security group..."
ONPREM_SG=$(aws ec2 create-security-group \
  --region $AWS_REGION \
  --vpc-id $ONPREM_VPC_ID \
  --group-name demo-onprem-router-sg \
  --description "Security group for demo on-prem router" \
  --query 'GroupId' \
  --output text)

# Allow SSH from anywhere
aws ec2 authorize-security-group-ingress \
  --region $AWS_REGION \
  --group-id $ONPREM_SG \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 >/dev/null

# Allow IPsec (for VPN)
aws ec2 authorize-security-group-ingress \
  --region $AWS_REGION \
  --group-id $ONPREM_SG \
  --protocol udp \
  --port 500 \
  --cidr 0.0.0.0/0 >/dev/null

aws ec2 authorize-security-group-ingress \
  --region $AWS_REGION \
  --group-id $ONPREM_SG \
  --protocol udp \
  --port 4500 \
  --cidr 0.0.0.0/0 >/dev/null

# Allow all from ROSA VPC
ROSA_CIDR=$(aws ec2 describe-vpcs \
  --region $AWS_REGION \
  --vpc-ids $ROSA_VPC_ID \
  --query 'Vpcs[0].CidrBlock' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --region $AWS_REGION \
  --group-id $ONPREM_SG \
  --protocol all \
  --cidr $ROSA_CIDR >/dev/null

# Allow all internal traffic
aws ec2 authorize-security-group-ingress \
  --region $AWS_REGION \
  --group-id $ONPREM_SG \
  --protocol all \
  --cidr 172.16.0.0/16 >/dev/null

echo "✅ On-prem VPC infrastructure created"

# Get or create SSH key pair
echo ""
echo "Setting up SSH key..."
KEY_NAME="demo-onprem-router-key"
if ! aws ec2 describe-key-pairs --region $AWS_REGION --key-names $KEY_NAME &>/dev/null; then
    aws ec2 create-key-pair \
      --region $AWS_REGION \
      --key-name $KEY_NAME \
      --query 'KeyMaterial' \
      --output text > ~/.ssh/$KEY_NAME.pem
    chmod 600 ~/.ssh/$KEY_NAME.pem
    echo "✅ Created SSH key: ~/.ssh/$KEY_NAME.pem"
else
    echo "✅ Using existing SSH key: $KEY_NAME"
fi

# Get latest Amazon Linux 2023 AMI
echo ""
echo "Finding Amazon Linux 2023 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region $AWS_REGION \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-kernel-6.1-arm64" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

echo "✅ AMI: $AMI_ID"

# Create user data for FRR setup
echo ""
echo "Preparing EC2 instance with FRR..."

cat > /tmp/onprem-router-userdata.sh <<'USERDATA_EOF'
#!/bin/bash
# Install and configure FRR on Amazon Linux 2023

# Install FRR
curl -s https://deb.frrouting.org/frr/keys.gpg | sudo tee /usr/share/keyrings/frrouting.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr $(lsb_release -s -c) frr-stable" | sudo tee /etc/apt/sources.list.d/frr.list

# For AL2023, use RPM instead
sudo dnf install -y frr frr-pythontools

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Configure FRR daemons
cat > /etc/frr/daemons <<EOF
bgpd=yes
zebra=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no
EOF

# Start FRR
sudo systemctl enable frr
sudo systemctl start frr

# Mark as complete
touch /var/lib/cloud/instance/frr-configured
USERDATA_EOF

# Launch EC2 instance
echo "Launching EC2 instance (t4g.micro)..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region $AWS_REGION \
  --image-id $AMI_ID \
  --instance-type t4g.micro \
  --key-name $KEY_NAME \
  --subnet-id $ONPREM_SUBNET \
  --security-group-ids $ONPREM_SG \
  --associate-public-ip-address \
  --user-data file:///tmp/onprem-router-userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=demo-onprem-router}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "✅ Instance launching: $INSTANCE_ID"

# Wait for instance to be running
echo "  Waiting for instance to be running..."
aws ec2 wait instance-running --region $AWS_REGION --instance-ids $INSTANCE_ID

# Get instance public IP
ONPREM_PUBLIC_IP=$(aws ec2 describe-instances \
  --region $AWS_REGION \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

ONPREM_PRIVATE_IP=$(aws ec2 describe-instances \
  --region $AWS_REGION \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo "✅ Instance running"
echo "   Public IP: $ONPREM_PUBLIC_IP"
echo "   Private IP: $ONPREM_PRIVATE_IP"

# Create VPN Gateway
echo ""
echo "Creating AWS Site-to-Site VPN..."
echo "  Creating VPN Gateway..."
VGW_ID=$(aws ec2 create-vpn-gateway \
  --region $AWS_REGION \
  --type ipsec.1 \
  --amazon-side-asn 65100 \
  --tag-specifications 'ResourceType=vpn-gateway,Tags=[{Key=Name,Value=demo-rosa-vgw}]' \
  --query 'VpnGateway.VpnGatewayId' \
  --output text)

echo "✅ VPN Gateway: $VGW_ID"

# Attach to ROSA VPC
echo "  Attaching VPN Gateway to ROSA VPC..."
aws ec2 attach-vpn-gateway \
  --region $AWS_REGION \
  --vpn-gateway-id $VGW_ID \
  --vpc-id $ROSA_VPC_ID >/dev/null

# Wait for attachment
sleep 5

# Enable route propagation on ROSA VPC route tables
echo "  Enabling route propagation..."
for RT in $(aws ec2 describe-route-tables \
  --region $AWS_REGION \
  --filters "Name=vpc-id,Values=$ROSA_VPC_ID" \
  --query 'RouteTables[*].RouteTableId' \
  --output text); do
  aws ec2 enable-vgw-route-propagation \
    --region $AWS_REGION \
    --route-table-id $RT \
    --gateway-id $VGW_ID 2>/dev/null || true
done

# Create Customer Gateway
echo "  Creating Customer Gateway..."
CGW_ID=$(aws ec2 create-customer-gateway \
  --region $AWS_REGION \
  --type ipsec.1 \
  --public-ip $ONPREM_PUBLIC_IP \
  --bgp-asn 65000 \
  --tag-specifications 'ResourceType=customer-gateway,Tags=[{Key=Name,Value=demo-onprem-cgw}]' \
  --query 'CustomerGateway.CustomerGatewayId' \
  --output text)

echo "✅ Customer Gateway: $CGW_ID"

# Create VPN Connection
echo "  Creating VPN Connection (this takes ~5 minutes)..."
VPN_CONN_ID=$(aws ec2 create-vpn-connection \
  --region $AWS_REGION \
  --type ipsec.1 \
  --customer-gateway-id $CGW_ID \
  --vpn-gateway-id $VGW_ID \
  --options "StaticRoutesOnly=false,TunnelOptions=[{PreSharedKey=demoVPNpassword123}]" \
  --tag-specifications 'ResourceType=vpn-connection,Tags=[{Key=Name,Value=demo-s2s-vpn}]' \
  --query 'VpnConnection.VpnConnectionId' \
  --output text)

echo "✅ VPN Connection: $VPN_CONN_ID"

# Wait for VPN to be available
echo "  Waiting for VPN to be available..."
aws ec2 wait vpn-connection-available --region $AWS_REGION --vpn-connection-ids $VPN_CONN_ID

# Get VPN configuration
echo "  Downloading VPN configuration..."
VPN_CONFIG=$(aws ec2 describe-vpn-connections \
  --region $AWS_REGION \
  --vpn-connection-ids $VPN_CONN_ID \
  --query 'VpnConnections[0].CustomerGatewayConfiguration' \
  --output text)

# Extract tunnel IPs (AWS side)
TUNNEL1_IP=$(echo "$VPN_CONFIG" | grep -o '<vpn_gateway>.*</vpn_gateway>' | head -1 | sed 's/<[^>]*>//g')
TUNNEL2_IP=$(echo "$VPN_CONFIG" | grep -o '<vpn_gateway>.*</vpn_gateway>' | tail -1 | sed 's/<[^>]*>//g')

echo "✅ VPN tunnels ready"
echo "   Tunnel 1: $TUNNEL1_IP"
echo "   Tunnel 2: $TUNNEL2_IP"

# Save configuration
mkdir -p ~/.rosa-demo-vpn
cat > ~/.rosa-demo-vpn/config.sh <<EOF
export AWS_REGION=$AWS_REGION
export ROSA_VPC_ID=$ROSA_VPC_ID
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
export TUNNEL2_IP=$TUNNEL2_IP
export KEY_NAME=$KEY_NAME
EOF

echo ""
echo "========================================="
echo "✅ Setup Complete!"
echo "========================================="
echo ""
echo "Configuration saved to: ~/.rosa-demo-vpn/config.sh"
echo ""
echo "Next steps:"
echo ""
echo "1. Wait ~2 minutes for EC2 instance to finish FRR installation"
echo ""
echo "2. Configure strongSwan and FRR on the instance:"
echo "   ./hack/configure-onprem-router.sh"
echo ""
echo "3. Deploy test VMs and watch BGP routes:"
echo "   oc apply -f manifests/05-examples/demo-vms.yaml"
echo ""
echo "4. SSH to on-prem router to see routes:"
echo "   ssh -i ~/.ssh/$KEY_NAME.pem ec2-user@$ONPREM_PUBLIC_IP"
echo "   sudo vtysh -c 'show ip bgp'"
echo ""
echo "5. When done, cleanup:"
echo "   ./hack/cleanup-demo-vpn.sh"
echo ""
echo "Cost: ~\$0.06/hour while running"
echo ""
