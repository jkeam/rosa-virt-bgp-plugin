#!/bin/bash
# Auto-configuration library
# Detects ROSA cluster configuration and generates all needed parameters

# Detect ROSA cluster configuration
detect_rosa_config() {
    echo "Detecting ROSA cluster configuration..."

    # Get AWS region from cluster
    export AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null)
    if [ -z "$AWS_REGION" ]; then
        echo "❌ Error: Could not detect AWS region from cluster"
        return 1
    fi
    echo "  ✓ Region: $AWS_REGION"

    # Get ROSA VPC
    local instance_id=$(oc get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | cut -d/ -f5)
    if [ -z "$instance_id" ]; then
        echo "❌ Error: Could not get node information from cluster"
        return 1
    fi

    export ROSA_VPC_ID=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].VpcId' \
        --output text)

    if [ -z "$ROSA_VPC_ID" ] || [ "$ROSA_VPC_ID" == "None" ]; then
        echo "❌ Error: Could not detect ROSA VPC"
        return 1
    fi
    echo "  ✓ ROSA VPC: $ROSA_VPC_ID"

    # Get ROSA VPC CIDR
    export ROSA_VPC_CIDR=$(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --vpc-ids "$ROSA_VPC_ID" \
        --query 'Vpcs[0].CidrBlock' \
        --output text)
    echo "  ✓ ROSA VPC CIDR: $ROSA_VPC_CIDR"

    # Get cluster nodes for BGP peer IPs
    export ROSA_NODE_IPS=$(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
    echo "  ✓ ROSA Node IPs: $ROSA_NODE_IPS"

    return 0
}

# Generate non-overlapping network configuration
generate_network_config() {
    echo "Generating network configuration..."

    # Parse ROSA VPC CIDR to avoid overlaps
    local rosa_first_octet=$(echo "$ROSA_VPC_CIDR" | cut -d. -f1)

    # Choose non-overlapping on-prem CIDR
    # If ROSA is 10.x, use 172.16.x
    # If ROSA is 172.x, use 10.x
    # If ROSA is 192.168.x, use 10.x
    case "$rosa_first_octet" in
        10)
            export ONPREM_VPC_CIDR="172.16.0.0/16"
            export ONPREM_SUBNET_CIDR="172.16.1.0/24"
            export VM_SECONDARY_NETWORK_CIDR="192.168.100.0/24"
            ;;
        172)
            export ONPREM_VPC_CIDR="10.200.0.0/16"
            export ONPREM_SUBNET_CIDR="10.200.1.0/24"
            export VM_SECONDARY_NETWORK_CIDR="192.168.100.0/24"
            ;;
        192)
            export ONPREM_VPC_CIDR="10.200.0.0/16"
            export ONPREM_SUBNET_CIDR="10.200.1.0/24"
            export VM_SECONDARY_NETWORK_CIDR="172.16.100.0/24"
            ;;
        *)
            echo "⚠️  Warning: Unexpected ROSA CIDR. Using default on-prem CIDR"
            export ONPREM_VPC_CIDR="172.16.0.0/16"
            export ONPREM_SUBNET_CIDR="172.16.1.0/24"
            export VM_SECONDARY_NETWORK_CIDR="192.168.100.0/24"
            ;;
    esac

    echo "  ✓ On-Prem VPC: $ONPREM_VPC_CIDR"
    echo "  ✓ On-Prem Subnet: $ONPREM_SUBNET_CIDR"
    echo "  ✓ VM Secondary Network: $VM_SECONDARY_NETWORK_CIDR"
}

# Generate BGP configuration
generate_bgp_config() {
    echo "Generating BGP configuration..."

    # Use standard private ASNs
    export BGP_ASN_ROSA=65100
    export BGP_ASN_ONPREM=65000

    echo "  ✓ BGP ASN (ROSA/VGW): $BGP_ASN_ROSA"
    echo "  ✓ BGP ASN (On-Prem): $BGP_ASN_ONPREM"
}

# Generate VPN configuration
generate_vpn_config() {
    echo "Generating VPN configuration..."

    # Generate a random secure PSK
    export VPN_PSK=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

    echo "  ✓ VPN PSK: (generated securely)"
}

# Detect optimal instance configuration
detect_instance_config() {
    echo "Detecting optimal instance configuration..."

    # Default to x86_64 for maximum compatibility
    export ONPREM_INSTANCE_TYPE="t3a.micro"
    export ONPREM_INSTANCE_ARCH="x86_64"
    export ONPREM_OS="centos-stream-10"

    # Check if ARM instances are available in the region (optional optimization)
    # For now, stick with x86 for reliability

    echo "  ✓ Instance Type: $ONPREM_INSTANCE_TYPE"
    echo "  ✓ Architecture: $ONPREM_INSTANCE_ARCH"
    echo "  ✓ OS: $ONPREM_OS"
}

# Generate SSH key configuration
generate_ssh_config() {
    echo "Configuring SSH key..."

    # Generate unique key name based on cluster
    local cluster_name=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null | cut -d- -f1-2)
    export SSH_KEY_NAME="rosa-virt-bgp-${cluster_name}"

    echo "  ✓ SSH Key Name: $SSH_KEY_NAME"
}

# Save configuration to state file
save_config() {
    local config_dir="$HOME/.rosa-virt-bgp"
    mkdir -p "$config_dir"

    local config_file="$config_dir/config.sh"

    cat > "$config_file" <<EOF
# Auto-generated configuration for ROSA Virtualization BGP Demo
# Generated: $(date)
# Cluster: $(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)

# AWS Configuration
export AWS_REGION=$AWS_REGION
export ROSA_VPC_ID=$ROSA_VPC_ID
export ROSA_VPC_CIDR=$ROSA_VPC_CIDR

# Network Configuration
export ONPREM_VPC_CIDR=$ONPREM_VPC_CIDR
export ONPREM_SUBNET_CIDR=$ONPREM_SUBNET_CIDR
export VM_SECONDARY_NETWORK_CIDR=$VM_SECONDARY_NETWORK_CIDR

# BGP Configuration
export BGP_ASN_ROSA=$BGP_ASN_ROSA
export BGP_ASN_ONPREM=$BGP_ASN_ONPREM

# VPN Configuration
export VPN_PSK='$VPN_PSK'

# Instance Configuration
export ONPREM_INSTANCE_TYPE=$ONPREM_INSTANCE_TYPE
export ONPREM_INSTANCE_ARCH=$ONPREM_INSTANCE_ARCH
export ONPREM_OS=$ONPREM_OS

# SSH Configuration
export SSH_KEY_NAME=$SSH_KEY_NAME

# ROSA Node IPs (for BGP peering)
export ROSA_NODE_IPS="$ROSA_NODE_IPS"
EOF

    echo "✅ Configuration saved to: $config_file"
    return 0
}

# Load existing configuration
load_config() {
    local config_file="$HOME/.rosa-virt-bgp/config.sh"

    if [ -f "$config_file" ]; then
        source "$config_file"
        return 0
    fi
    return 1
}

# Main auto-configuration function
auto_configure() {
    echo "========================================="
    echo "Auto-Detecting Configuration"
    echo "========================================="
    echo ""

    # Try to load existing config first
    if load_config; then
        echo "✅ Loaded existing configuration from ~/.rosa-virt-bgp/config.sh"
        echo ""
        return 0
    fi

    # Detect and generate configuration
    detect_rosa_config || return 1
    generate_network_config
    generate_bgp_config
    generate_vpn_config
    detect_instance_config
    generate_ssh_config

    # Save configuration
    echo ""
    save_config

    echo ""
    echo "========================================="
    echo "✅ Auto-Configuration Complete"
    echo "========================================="
    echo ""

    return 0
}

# Print configuration summary
print_config() {
    echo "Current Configuration:"
    echo "====================="
    echo ""
    echo "AWS:"
    echo "  Region:              $AWS_REGION"
    echo "  ROSA VPC:            $ROSA_VPC_ID ($ROSA_VPC_CIDR)"
    echo ""
    echo "Networks:"
    echo "  On-Prem VPC:         $ONPREM_VPC_CIDR"
    echo "  On-Prem Subnet:      $ONPREM_SUBNET_CIDR"
    echo "  VM Secondary:        $VM_SECONDARY_NETWORK_CIDR"
    echo ""
    echo "BGP:"
    echo "  ROSA ASN:            $BGP_ASN_ROSA"
    echo "  On-Prem ASN:         $BGP_ASN_ONPREM"
    echo ""
    echo "Instance:"
    echo "  Type:                $ONPREM_INSTANCE_TYPE ($ONPREM_INSTANCE_ARCH)"
    echo "  OS:                  $ONPREM_OS"
    echo "  SSH Key:             $SSH_KEY_NAME"
    echo ""
}
