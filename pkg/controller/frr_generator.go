package controller

import (
	"context"
	"fmt"

	frrk8sv1beta1 "github.com/metallb/frr-k8s/api/v1beta1"
	kubevirtv1 "kubevirt.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	ManagedByLabel = "app.kubernetes.io/managed-by"
	ComponentLabel = "app.kubernetes.io/component"
	ControllerName = "rosa-virt-bgp-controller"
)

type FRRGenerator struct {
	client       client.Client
	frrNamespace string
	bgpASN       uint32
	ipExtractor  *IPExtractor
}

func NewFRRGenerator(c client.Client, frrNamespace string, bgpASN uint32, extractor *IPExtractor) *FRRGenerator {
	return &FRRGenerator{
		client:       c,
		frrNamespace: frrNamespace,
		bgpASN:       bgpASN,
		ipExtractor:  extractor,
	}
}

// GenerateConfig creates or updates an FRRConfiguration for a namespace
func (g *FRRGenerator) GenerateConfig(ctx context.Context, namespace string) (*frrk8sv1beta1.FRRConfiguration, error) {
	log := log.FromContext(ctx)

	// List all VMIs in the namespace
	vmiList := &kubevirtv1.VirtualMachineInstanceList{}
	if err := g.client.List(ctx, vmiList, client.InNamespace(namespace)); err != nil {
		return nil, fmt.Errorf("failed to list VMIs: %w", err)
	}

	// Extract IPs from all running VMs
	var prefixes []string
	for i := range vmiList.Items {
		vmi := &vmiList.Items[i]

		// Only process running VMs
		if vmi.Status.Phase != kubevirtv1.Running {
			continue
		}

		ips, err := g.ipExtractor.ExtractIPs(ctx, vmi)
		if err != nil {
			log.V(1).Info("skipping VM without IPs", "vm", vmi.Name, "error", err)
			continue
		}

		for _, ip := range ips {
			prefix := fmt.Sprintf("%s/32", ip)
			prefixes = append(prefixes, prefix)
			log.V(1).Info("added prefix", "vm", vmi.Name, "prefix", prefix)
		}
	}

	// Generate FRRConfiguration name
	configName := fmt.Sprintf("bgp-vm-routes-%s", namespace)

	config := &frrk8sv1beta1.FRRConfiguration{
		ObjectMeta: metav1.ObjectMeta{
			Name:      configName,
			Namespace: g.frrNamespace,
			Labels: map[string]string{
				ManagedByLabel: ControllerName,
				ComponentLabel: "bgp-route-advertisement",
				"namespace":    namespace,
			},
		},
		Spec: frrk8sv1beta1.FRRConfigurationSpec{
			BGP: frrk8sv1beta1.BGPConfig{
				Routers: []frrk8sv1beta1.Router{
					{
						ASN:      g.bgpASN,
						Prefixes: prefixes,
					},
				},
			},
		},
	}

	return config, nil
}
