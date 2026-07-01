# Configuration Reference

## Controller Configuration

Configuration file: `manifests/04-controller/configmap.yaml`

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `networkName` | string | Yes | - | Name of the network interface in VMs (must match NAD) |
| `networkAttachmentDefinition` | string | Yes | - | Name of NetworkAttachmentDefinition |
| `cudnSubnet` | string | Yes | - | CIDR of CUDN subnet for IP validation |
| `frrNamespace` | string | No | `frr-k8s-system` | Namespace where FRRConfiguration CRs are created |
| `bgpASN` | integer | Yes | - | Local BGP AS number |
| `reconcileInterval` | duration | No | `30s` | How often to re-sync state |
| `ipDiscoveryTimeout` | duration | No | `5m` | Max wait time for VM IP assignment |
| `enableMetrics` | boolean | No | `true` | Expose Prometheus metrics |
| `enableStatusUpdates` | boolean | No | `true` | Update VM annotations with BGP status |

### Example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bgp-vm-controller-config
data:
  config.yaml: |
    networkName: "bgp-network"
    networkAttachmentDefinition: "vm-bgp-net"
    cudnSubnet: "10.10.10.0/24"
    frrNamespace: "frr-k8s-system"
    bgpASN: 65000
    reconcileInterval: "30s"
    ipDiscoveryTimeout: "5m"
    enableMetrics: true
    enableStatusUpdates: true
```

## CUDN Configuration

### Parameters

| Parameter | Description |
|-----------|-------------|
| `topology` | Network topology: `Localnet` for direct L2, `Overlay` for encapsulation |
| `subnets` | IP subnets allocated to this network (CIDR format) |
| `excludeSubnets` | IPs to exclude from IPAM (gateway, broadcast, etc.) |
| `localnetConfig.bridgeMappings` | Maps physical network to OVS bridge |
| `ipamLifecycle` | `Persistent` for stable IPs, `Ephemeral` for dynamic |

### Example

```yaml
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: vm-bgp-network
spec:
  namespaceSelector:
    matchLabels:
      bgp-enabled: "true"
  network:
    topology: Localnet
    subnets: ["10.10.10.0/24"]
    excludeSubnets: ["10.10.10.1/32", "10.10.10.254/32"]
    localnetConfig:
      bridgeMappings:
      - physicalNetworkName: vlan100
        ovsBridge: br-vlan
    ipamLifecycle: Persistent
```

## FRR BGP Configuration

### Base Configuration

```yaml
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: base-config
spec:
  bgp:
    routers:
    - asn: 65000
      routerID: 10.0.1.100
      bfd:
        enabled: true
        profile: default
```

### Neighbor Configuration

```yaml
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: bgp-peers
spec:
  bgp:
    routers:
    - asn: 65000
      neighbors:
      - asn: 65001
        address: 10.10.10.1
        ebgpMultiHop: 1
        passwordSecret:
          name: bgp-peer-secret
          key: password
        bfdProfile: default
```

### BFD Configuration

```yaml
apiVersion: frrk8s.metallb.io/v1beta1
kind: BFDProfile
metadata:
  name: default
spec:
  receiveInterval: 300      # ms
  transmitInterval: 300     # ms
  detectMultiplier: 3       # failures before down
  echoMode: false
  minimumTTL: 254
```

## Advanced Scenarios

### Multiple BGP Peers

```yaml
neighbors:
- asn: 65001
  address: 10.10.10.1
  passwordSecret:
    name: bgp-peer-secret
    key: password1
- asn: 65001
  address: 10.10.10.2
  passwordSecret:
    name: bgp-peer-secret
    key: password2
```

### Route Filtering

Add prefix lists to FRRConfiguration:

```yaml
spec:
  bgp:
    routers:
    - asn: 65000
      prefixLists:
      - name: vm-routes
        prefixes:
        - prefix: "10.10.10.0/24"
          ge: 32
          le: 32
      neighbors:
      - address: 10.10.10.1
        toAdvertise:
          allowed:
            mode: filtered
            prefixes:
            - vm-routes
```

### Multi-Namespace Support

Deploy separate NADs per namespace:

```yaml
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vm-bgp-net
  namespace: production
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vm-bgp-net
  namespace: development
```

Controller will create separate FRRConfigurations:
- `bgp-vm-routes-production`
- `bgp-vm-routes-development`

## Environment Variables

Controller supports environment variable overrides:

| Variable | Description |
|----------|-------------|
| `WATCH_NAMESPACE` | Limit controller to specific namespace (empty = all) |
| `POD_NAMESPACE` | Namespace where controller is deployed |
| `LOG_LEVEL` | Logging level: `debug`, `info`, `warn`, `error` |

Example:

```yaml
env:
- name: WATCH_NAMESPACE
  value: "vm-workloads"
- name: LOG_LEVEL
  value: "debug"
```
