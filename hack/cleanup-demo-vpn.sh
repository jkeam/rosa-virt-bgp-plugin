#!/bin/bash
# Cleanup two-VPC demo infrastructure

set -e

echo "========================================="
echo "Demo VPN Cleanup"
echo "========================================="
echo ""

# Load configuration
if [ ! -f ~/.rosa-demo-vpn/config.sh ]; then
    echo "❌ Error: No demo VPN found to cleanup"
    exit 1
fi

source ~/.rosa-demo-vpn/config.sh

echo "This will delete:"
echo "  • VPN Connection: $VPN_CONN_ID"
echo "  • Customer Gateway: $CGW_ID"
echo "  • VPN Gateway: $VGW_ID"
echo "  • EC2 Instance: $INSTANCE_ID"
echo "  • On-prem VPC: $ONPREM_VPC_ID"
echo ""
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    exit 0
fi

echo ""
echo "Deleting resources..."

# Delete VPN Connection
echo "  Deleting VPN connection..."
aws ec2 delete-vpn-connection \
  --region $AWS_REGION \
  --vpn-connection-id $VPN_CONN_ID 2>/dev/null || echo "  (already deleted)"

# Wait a bit for VPN to delete
sleep 10

# Delete Customer Gateway
echo "  Deleting customer gateway..."
aws ec2 delete-customer-gateway \
  --region $AWS_REGION \
  --customer-gateway-id $CGW_ID 2>/dev/null || echo "  (already deleted)"

# Detach and delete VPN Gateway
echo "  Detaching VPN gateway..."
aws ec2 detach-vpn-gateway \
  --region $AWS_REGION \
  --vpn-gateway-id $VGW_ID \
  --vpc-id $ROSA_VPC_ID 2>/dev/null || echo "  (already detached)"

sleep 5

echo "  Deleting VPN gateway..."
aws ec2 delete-vpn-gateway \
  --region $AWS_REGION \
  --vpn-gateway-id $VGW_ID 2>/dev/null || echo "  (already deleted)"

# Terminate EC2 instance
echo "  Terminating EC2 instance..."
aws ec2 terminate-instances \
  --region $AWS_REGION \
  --instance-ids $INSTANCE_ID >/dev/null 2>&1 || echo "  (already terminated)"

echo "  Waiting for instance to terminate..."
aws ec2 wait instance-terminated --region $AWS_REGION --instance-ids $INSTANCE_ID 2>/dev/null || true

# Delete on-prem VPC resources
echo "  Deleting on-prem VPC resources..."

# Detach and delete IGW
aws ec2 detach-internet-gateway \
  --region $AWS_REGION \
  --internet-gateway-id $ONPREM_IGW \
  --vpc-id $ONPREM_VPC_ID 2>/dev/null || true

aws ec2 delete-internet-gateway \
  --region $AWS_REGION \
  --internet-gateway-id $ONPREM_IGW 2>/dev/null || true

# Delete subnet
aws ec2 delete-subnet \
  --region $AWS_REGION \
  --subnet-id $ONPREM_SUBNET 2>/dev/null || true

# Delete route table
aws ec2 delete-route-table \
  --region $AWS_REGION \
  --route-table-id $ONPREM_RT 2>/dev/null || true

# Delete security group
aws ec2 delete-security-group \
  --region $AWS_REGION \
  --group-id $ONPREM_SG 2>/dev/null || true

# Delete VPC
aws ec2 delete-vpc \
  --region $AWS_REGION \
  --vpc-id $ONPREM_VPC_ID 2>/dev/null || true

# Delete SSH key
echo "  Deleting SSH key..."
aws ec2 delete-key-pair \
  --region $AWS_REGION \
  --key-name $KEY_NAME 2>/dev/null || true

rm -f ~/.ssh/$KEY_NAME.pem

# Delete local config
rm -rf ~/.rosa-demo-vpn

echo ""
echo "✅ Cleanup complete!"
echo ""
