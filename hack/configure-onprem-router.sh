#!/bin/bash
# Configure the on-prem router EC2 instance with strongSwan and FRR

set -e

echo "========================================="
echo "Configure On-Prem Router"
echo "========================================="
echo ""

# Load configuration
if [ ! -f ~/.rosa-demo-vpn/config.sh ]; then
    echo "❌ Error: Setup not found. Run ./hack/setup-demo-vpn.sh first"
    exit 1
fi

source ~/.rosa-demo-vpn/config.sh

echo "Configuring router at $ONPREM_PUBLIC_IP..."
echo ""

# Create FRR configuration
cat > /tmp/frr-config.conf <<EOF
!
frr version 8.0
frr defaults traditional
hostname demo-onprem-router
log syslog informational
no ipv6 forwarding
!
router bgp 65000
 bgp router-id $ONPREM_PRIVATE_IP
 neighbor $TUNNEL1_IP remote-as 65100
 neighbor $TUNNEL1_IP ebgp-multihop 255
 neighbor $TUNNEL2_IP remote-as 65100
 neighbor $TUNNEL2_IP ebgp-multihop 255
 !
 address-family ipv4 unicast
  neighbor $TUNNEL1_IP soft-reconfiguration inbound
  neighbor $TUNNEL2_IP soft-reconfiguration inbound
 exit-address-family
!
line vty
!
EOF

# Create strongSwan configuration
cat > /tmp/ipsec.conf <<'IPSEC_EOF'
# /etc/ipsec.conf - strongSwan IPsec configuration file

config setup
    charondebug="all"
    uniqueids=yes

conn %default
    ikelifetime=28800s
    keylife=3600s
    rekeymargin=3m
    keyingtries=%forever
    authby=psk
    mobike=no
    keyexchange=ikev2
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256-modp2048!

conn Tunnel1
    auto=start
    left=%defaultroute
    leftid=ONPREM_PUBLIC_IP
    leftsubnet=0.0.0.0/0
    right=TUNNEL1_IP
    rightsubnet=0.0.0.0/0
    dpdaction=restart
    dpddelay=10s
    dpdtimeout=30s

conn Tunnel2
    auto=start
    left=%defaultroute
    leftid=ONPREM_PUBLIC_IP
    leftsubnet=0.0.0.0/0
    right=TUNNEL2_IP
    rightsubnet=0.0.0.0/0
    dpdaction=restart
    dpddelay=10s
    dpdtimeout=30s
IPSEC_EOF

# Substitute actual IPs (works on both macOS and Linux)
perl -pi -e "s/ONPREM_PUBLIC_IP/$ONPREM_PUBLIC_IP/g" /tmp/ipsec.conf
perl -pi -e "s/TUNNEL1_IP/$TUNNEL1_IP/g" /tmp/ipsec.conf
perl -pi -e "s/TUNNEL2_IP/$TUNNEL2_IP/g" /tmp/ipsec.conf

# Create IPsec secrets
cat > /tmp/ipsec.secrets <<EOF
# /etc/ipsec.secrets - strongSwan IPsec secrets file
$ONPREM_PUBLIC_IP $TUNNEL1_IP : PSK "demoVPNpassword123"
$ONPREM_PUBLIC_IP $TUNNEL2_IP : PSK "demoVPNpassword123"
EOF

# Create setup script to run on EC2
cat > /tmp/setup-router.sh <<'SETUP_EOF'
#!/bin/bash
set -e

echo "Installing strongSwan..."
sudo dnf install -y strongswan

echo "Configuring IPsec..."
sudo cp /tmp/ipsec.conf /etc/strongswan/ipsec.conf
sudo cp /tmp/ipsec.secrets /etc/strongswan/ipsec.secrets
sudo chmod 600 /etc/strongswan/ipsec.secrets

echo "Configuring FRR..."
sudo cp /tmp/frr-config.conf /etc/frr/frr.conf
sudo chown frr:frr /etc/frr/frr.conf
sudo chmod 640 /etc/frr/frr.conf

echo "Starting strongSwan..."
sudo systemctl enable strongswan
sudo systemctl start strongswan

echo "Restarting FRR..."
sudo systemctl restart frr

echo "✅ Configuration complete!"
echo ""
echo "Checking VPN status..."
sleep 5
sudo strongswan status

echo ""
echo "Checking BGP status..."
sleep 5
sudo vtysh -c 'show bgp summary'
SETUP_EOF

chmod +x /tmp/setup-router.sh

# Copy files to EC2
echo "Copying configuration files to EC2..."
scp -i ~/.ssh/$KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    /tmp/ipsec.conf \
    /tmp/ipsec.secrets \
    /tmp/frr-config.conf \
    /tmp/setup-router.sh \
    ec2-user@$ONPREM_PUBLIC_IP:/tmp/

# Run setup script on EC2
echo ""
echo "Running configuration on EC2 instance..."
ssh -i ~/.ssh/$KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$ONPREM_PUBLIC_IP \
    'bash /tmp/setup-router.sh'

echo ""
echo "========================================="
echo "✅ Router Configuration Complete!"
echo "========================================="
echo ""
echo "VPN tunnels are establishing..."
echo "BGP peering will establish once tunnels are up (~1 minute)"
echo ""
echo "To check status:"
echo "  ssh -i ~/.ssh/$KEY_NAME.pem ec2-user@$ONPREM_PUBLIC_IP"
echo ""
echo "Then run:"
echo "  sudo strongswan status          # Check VPN tunnels"
echo "  sudo vtysh -c 'show bgp summary' # Check BGP"
echo "  sudo vtysh -c 'show ip bgp'      # See routes"
echo ""
