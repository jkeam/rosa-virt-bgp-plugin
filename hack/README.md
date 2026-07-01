# Automation Scripts

This directory contains scripts for setting up and managing the ROSA Virtualization BGP Plugin.

## Core Setup Scripts

### `install-prereqs.sh`
Installs FRR-K8s on the cluster and configures permissions.

```bash
./hack/install-prereqs.sh
```

**What it does:**
- Installs FRR-K8s v0.0.23
- Grants privileged SCC to FRR service accounts
- Removes webhook validation (avoids TLS issues)

**Prerequisites:** `oc` CLI logged into cluster

**Time:** ~2 minutes

## Demo VPN Scripts (Two-VPC Setup)

### `setup-demo-vpn.sh`
Creates complete two-VPC demo environment with Site-to-Site VPN.

```bash
./hack/setup-demo-vpn.sh
```

**What it creates:**
- Second VPC (172.16.0.0/16) as simulated "on-premises"
- EC2 t4g.micro instance for FRR router
- VPN Gateway attached to ROSA VPC
- Customer Gateway and Site-to-Site VPN
- Full networking infrastructure

**Prerequisites:**
- ROSA cluster running
- AWS CLI configured
- `oc` CLI logged into cluster

**Time:** ~15 minutes (mostly waiting for VPN provisioning)

**Cost:** ~$0.06/hour while running

**Output:** Saves configuration to `~/.rosa-demo-vpn/config.sh`

### `configure-onprem-router.sh`
Configures the EC2 "on-prem" router with strongSwan and FRR.

```bash
./hack/configure-onprem-router.sh
```

**What it does:**
- Installs strongSwan (IPsec VPN)
- Configures IPsec tunnels to AWS VPN Gateway
- Configures FRR with BGP peering (AS 65000 ↔ AS 65100)
- Starts services and verifies connectivity

**Prerequisites:** Must run `setup-demo-vpn.sh` first

**Time:** ~3 minutes

### `cleanup-demo-vpn.sh`
Tears down all demo VPN infrastructure.

```bash
./hack/cleanup-demo-vpn.sh
```

**What it deletes:**
- VPN Connection
- VPN Gateway
- Customer Gateway  
- EC2 instance
- On-prem VPC and all resources
- SSH key pair
- Local configuration files

**Time:** ~3 minutes

## Legacy Demo Scripts

### `demo-laptop-router.sh`
**[DEPRECATED]** Runs FRR in podman container on laptop.

Not recommended - use two-VPC setup instead. Kept for reference.

## Usage Examples

### Quick Demo Setup

```bash
# 1. Install cluster prerequisites
./hack/install-prereqs.sh

# 2. Create demo VPN infrastructure
./hack/setup-demo-vpn.sh

# 3. Wait 2 minutes for EC2 to install FRR, then:
./hack/configure-onprem-router.sh

# 4. Deploy VMs
oc apply -f manifests/05-examples/demo-vms.yaml

# 5. SSH to on-prem router and check BGP
source ~/.rosa-demo-vpn/config.sh
ssh -i ~/.ssh/demo-onprem-router-key.pem ec2-user@$ONPREM_PUBLIC_IP
sudo vtysh -c 'show ip bgp'

# 6. Cleanup when done
./hack/cleanup-demo-vpn.sh
```

### Just Cluster Setup (No External BGP)

```bash
# Install prerequisites
./hack/install-prereqs.sh

# Deploy controller
make deploy

# Deploy manifests
oc apply -f manifests/02-networking/
oc apply -f manifests/03-frr/frr-config-base.yaml

# Deploy VMs
oc apply -f manifests/05-examples/demo-vms.yaml

# Test VM-to-VM connectivity
virtctl console test-vm1 -n vm-demo
```

## Troubleshooting

### Script fails with "AWS CLI not found"
```bash
brew install awscli
aws configure
```

### "Not connected to OpenShift cluster"
```bash
oc login <cluster-url>
```

### VPN setup hangs
Most common: Waiting for VPN to be available (can take 5-10 minutes). The script shows progress.

### EC2 instance won't connect
Check your SSH key exists:
```bash
ls -la ~/.ssh/demo-onprem-router-key.pem
chmod 600 ~/.ssh/demo-onprem-router-key.pem
```

### Cleanup fails
Safe to run multiple times. If resources already deleted, it will skip them.

## Configuration Files

Scripts save state to:
- `~/.rosa-demo-vpn/config.sh` - Environment variables for demo VPN
- `~/.ssh/demo-onprem-router-key.pem` - SSH key for EC2 instance

These are automatically deleted by `cleanup-demo-vpn.sh`

## Cost Information

**Two-VPC Demo:**
- EC2 t4g.micro: $0.0084/hour
- S2S VPN connection: $0.05/hour
- **Total: ~$0.06/hour or ~$1.50/day**

Always run cleanup when done to avoid charges!

## Related Documentation

- [Complete Demo Walkthrough](../docs/DEMO-WALKTHROUGH.md) - Step-by-step guide
- [Networking Setup](../docs/networking-setup.md) - Architecture and options
- [DEMO.md](../DEMO.md) - Quick demo overview
