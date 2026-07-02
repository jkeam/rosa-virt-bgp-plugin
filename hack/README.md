# Setup Scripts

Automated setup scripts for ROSA Virtualization BGP Plugin demo.

## Prerequisites

- Authenticated to a ROSA cluster (`oc login`)
- AWS CLI configured with appropriate credentials  
- `jq` installed

## Quick Start

All scripts auto-detect configuration from your ROSA cluster - no manual configuration needed!

```bash
# 1. Setup VPN infrastructure (auto-detects everything)
./hack/setup-demo-vpn.sh

# 2. Configure on-prem router
./hack/configure-onprem-router.sh

# 3. Deploy BGP config to ROSA
./hack/deploy-bgp-config.sh

# 4. Deploy test VMs
oc apply -f manifests/05-examples/demo-vms.yaml

# 5. Verify BGP
./hack/verify-bgp.sh

# 6. Cleanup when done
./hack/cleanup-demo-vpn.sh
```

## What Gets Auto-Detected

- ✅ AWS Region (from cluster)
- ✅ ROSA VPC and CIDR (from cluster nodes)
- ✅ Non-overlapping network ranges
- ✅ BGP ASNs (standard private ranges)
- ✅ Secure VPN credentials (randomly generated)
- ✅ Optimal EC2 instance type

Configuration saved to: `~/.rosa-virt-bgp/config.sh`

## Cost

~$0.06/hour (~$1.50 for full day demo)

## Troubleshooting

Run verification script:
```bash
./hack/verify-bgp.sh
```

For more details, see the main README.md
