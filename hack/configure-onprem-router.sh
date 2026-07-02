#!/bin/bash
# Configure the on-prem router EC2 instance with strongSwan and FRR

set -e

echo "========================================="
echo "Configure On-Prem Router"
echo "========================================="
echo ""

# Load configuration
if [ ! -f "$HOME/.rosa-virt-bgp/config.sh" ]; then
    echo "❌ Error: Configuration not found"
    echo "Run ./hack/setup-demo-vpn.sh first"
    exit 1
fi

source "$HOME/.rosa-virt-bgp/config.sh"

echo "Configuring router at $ONPREM_PUBLIC_IP..."
echo "  OS: $ONPREM_OS"
echo "  On-Prem IP: $ONPREM_PRIVATE_IP"
echo "  VPN Tunnel: $TUNNEL1_IP"
echo "  BGP ASN: $BGP_ASN_ONPREM"
echo ""

# Wait for instance to be ready
echo "Waiting for instance to be accessible via SSH..."
for i in {1..30}; do
    if ssh -i ~/.ssh/$SSH_KEY_NAME.pem \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        ec2-user@$ONPREM_PUBLIC_IP "echo 'ready'" &>/dev/null; then
        echo "✅ Instance is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Error: Instance not accessible after 2.5 minutes"
        exit 1
    fi
    echo "  Attempt $i/30..."
    sleep 5
done

# Install and configure based on OS
echo ""
echo "Installing strongSwan and FRR..."

ssh -i ~/.ssh/$SSH_KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$ONPREM_PUBLIC_IP bash <<ENDSSH
set -e

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p >/dev/null

# Install based on OS
if [ "$ONPREM_OS" == "centos-stream-10" ]; then
    # CentOS Stream 10
    echo "Installing packages for CentOS Stream 10..."

    # Install EPEL for FRR
    sudo dnf install -y epel-release

    # Install strongSwan and FRR
    sudo dnf install -y strongswan frr

elif [ "$ONPREM_OS" == "amazon-linux-2023" ]; then
    # Amazon Linux 2023
    echo "Installing packages for Amazon Linux 2023..."

    # Install strongSwan
    sudo dnf install -y strongswan

    # Install FRR from repo
    sudo dnf install -y frr frr-pythontools
fi

# Configure strongSwan
echo "Configuring strongSwan..."

# Create strongSwan config
sudo tee /etc/strongswan/swanctl/conf.d/aws-tunnel1.conf > /dev/null <<'EOF'
connections {
    Tunnel1 {
        local_addrs = %any
        remote_addrs = $TUNNEL1_IP

        local {
            auth = psk
            id = $ONPREM_PUBLIC_IP
        }
        remote {
            auth = psk
            id = $TUNNEL1_IP
        }

        children {
            Tunnel1 {
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                mode = tunnel
                esp_proposals = aes128-sha1-modp2048
                start_action = start
                dpd_action = restart
                if_id_in = 100
                if_id_out = 100
            }
        }

        version = 2
        proposals = aes128-sha1-modp2048
        rekey_time = 28800s
        dpd_delay = 10s
    }
}

secrets {
    ike-tunnel1 {
        id = $ONPREM_PUBLIC_IP
        secret = "$VPN_PSK"
    }
}
EOF

# Create XFRM interface
sudo ip link add xfrm0 type xfrm dev \$(ip route | grep default | awk '{print \$5}') if_id 100 2>/dev/null || true
sudo ip addr add $TUNNEL1_INSIDE_CGW/30 dev xfrm0 2>/dev/null || true
sudo ip link set xfrm0 up

# Add route for ROSA VPC via tunnel
sudo ip route add $ROSA_VPC_CIDR dev xfrm0 2>/dev/null || true

# Persist XFRM interface config
cat > /tmp/xfrm-setup.sh <<'XFRM_EOF'
#!/bin/bash
ip link add xfrm0 type xfrm dev \$(ip route | grep default | awk '{print \$5}') if_id 100 2>/dev/null || true
ip addr add $TUNNEL1_INSIDE_CGW/30 dev xfrm0 2>/dev/null || true
ip link set xfrm0 up
ip route add $ROSA_VPC_CIDR dev xfrm0 2>/dev/null || true
XFRM_EOF

sudo mv /tmp/xfrm-setup.sh /usr/local/bin/xfrm-setup.sh
sudo chmod +x /usr/local/bin/xfrm-setup.sh

# Create systemd service for XFRM interface
sudo tee /etc/systemd/system/xfrm-tunnel.service > /dev/null <<'SERVICE_EOF'
[Unit]
Description=XFRM Tunnel Interface
After=network.target strongswan.service
Requires=strongswan.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xfrm-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable xfrm-tunnel.service

# Start strongSwan
sudo systemctl enable strongswan
sudo systemctl restart strongswan

# Wait for IPsec to come up
sleep 10

# Configure FRR
echo "Configuring FRR..."

# Create FRR config
sudo tee /etc/frr/frr.conf > /dev/null <<'FRR_EOF'
!
frr version 10.2
frr defaults traditional
hostname rosa-virt-bgp-router
log syslog informational
no ipv6 forwarding
!
router bgp $BGP_ASN_ONPREM
 bgp router-id $ONPREM_PRIVATE_IP
 neighbor $TUNNEL1_INSIDE_VGW remote-as $BGP_ASN_ROSA
 neighbor $TUNNEL1_INSIDE_VGW ebgp-multihop 255
 !
 address-family ipv4 unicast
  network $ONPREM_VPC_CIDR
  neighbor $TUNNEL1_INSIDE_VGW soft-reconfiguration inbound
  neighbor $TUNNEL1_INSIDE_VGW route-map ALLOW-ALL in
  neighbor $TUNNEL1_INSIDE_VGW route-map ALLOW-ALL out
 exit-address-family
exit
!
! Peer with ROSA nodes directly
$(for ip in $ROSA_NODE_IPS; do
    echo "router bgp $BGP_ASN_ONPREM"
    echo " neighbor \$ip remote-as $BGP_ASN_ROSA"
    echo " neighbor \$ip ebgp-multihop 255"
    echo " !"
    echo " address-family ipv4 unicast"
    echo "  neighbor \$ip soft-reconfiguration inbound"
    echo "  neighbor \$ip route-map ALLOW-ALL in"
    echo "  neighbor \$ip route-map ALLOW-ALL out"
    echo " exit-address-family"
    echo "exit"
    echo "!"
done)
!
route-map ALLOW-ALL permit 10
exit
!
ip nht resolve-via-default
!
line vty
!
FRR_EOF

# Add static route for on-prem VPC CIDR
sudo ip route add $ONPREM_VPC_CIDR dev lo 2>/dev/null || true

# Enable FRR daemons
sudo sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
sudo sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons

# Start FRR
sudo systemctl enable frr
sudo systemctl restart frr

echo "✅ Configuration complete"
ENDSSH

echo ""
echo "========================================="
echo "✅ On-Prem Router Configured"
echo "========================================="
echo ""
echo "Verifying configuration..."
echo ""

# Check IPsec status
echo "IPsec Status:"
ssh -i ~/.ssh/$SSH_KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$ONPREM_PUBLIC_IP \
    "sudo strongswan statusall | grep -E 'Security|ESTABLISHED|INSTALLED' | head -5" || true

echo ""
echo "BGP Status:"
ssh -i ~/.ssh/$SSH_KEY_NAME.pem \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ec2-user@$ONPREM_PUBLIC_IP \
    "sudo vtysh -c 'show bgp summary' 2>/dev/null | tail -10" || true

echo ""
echo "Next steps:"
echo "1. Deploy BGP configuration to ROSA: ./hack/deploy-bgp-config.sh"
echo "2. Verify BGP: ./hack/verify-bgp.sh"
echo ""
