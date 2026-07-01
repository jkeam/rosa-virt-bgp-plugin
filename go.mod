module github.com/jkeam/rosa-virt-bgp-plugin

go 1.22

require (
	github.com/metallb/frr-k8s v0.0.14
	gopkg.in/yaml.v3 v3.0.1
	k8s.io/apimachinery v0.29.0
	k8s.io/client-go v0.29.0
	kubevirt.io/api v1.1.1
	sigs.k8s.io/controller-runtime v0.17.0
)
