package controller

import (
	"context"
	"fmt"
	"net"
	"strings"

	kubevirtv1 "kubevirt.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	// Annotations for IP discovery
	OVNIPAddressAnnotation = "ovn.kubernetes.io/ip_address"
	IPAMClaimAnnotation    = "k8s.ovn.org/ipamclaim-reference"
)

type IPExtractor struct {
	client       client.Client
	networkName  string
	cudnSubnet   *net.IPNet
}

func NewIPExtractor(c client.Client, networkName, cudnSubnet string) (*IPExtractor, error) {
	_, subnet, err := net.ParseCIDR(cudnSubnet)
	if err != nil {
		return nil, fmt.Errorf("invalid CUDN subnet: %w", err)
	}

	return &IPExtractor{
		client:      c,
		networkName: networkName,
		cudnSubnet:  subnet,
	}, nil
}

// ExtractIPs extracts IP addresses from a VirtualMachineInstance using multiple sources
func (e *IPExtractor) ExtractIPs(ctx context.Context, vmi *kubevirtv1.VirtualMachineInstance) ([]string, error) {
	log := log.FromContext(ctx)

	// Try primary source: VMI status interfaces
	ips := e.extractFromVMIStatus(vmi)
	if len(ips) > 0 {
		log.V(1).Info("extracted IPs from VMI status", "ips", ips)
		return ips, nil
	}

	// Try fallback: annotations
	ips = e.extractFromAnnotations(vmi)
	if len(ips) > 0 {
		log.V(1).Info("extracted IPs from annotations", "ips", ips)
		return ips, nil
	}

	// No IPs found
	return nil, fmt.Errorf("no IPs found for VM %s/%s", vmi.Namespace, vmi.Name)
}

func (e *IPExtractor) extractFromVMIStatus(vmi *kubevirtv1.VirtualMachineInstance) []string {
	var ips []string

	// Find which interface name corresponds to our multus network
	var targetInterfaceName string
	for _, network := range vmi.Spec.Networks {
		if network.Multus != nil && network.Multus.NetworkName == e.networkName {
			targetInterfaceName = network.Name
			break
		}
	}

	if targetInterfaceName == "" {
		return ips
	}

	// Extract IPs from the matching interface
	for _, iface := range vmi.Status.Interfaces {
		if iface.Name == targetInterfaceName {
			for _, ip := range iface.IPs {
				if e.isValidIP(ip) {
					ips = append(ips, ip)
				}
			}
		}
	}

	return ips
}

func (e *IPExtractor) extractFromAnnotations(vmi *kubevirtv1.VirtualMachineInstance) []string {
	var ips []string

	if vmi.Annotations == nil {
		return ips
	}

	// Try OVN annotation
	if ipStr, ok := vmi.Annotations[OVNIPAddressAnnotation]; ok {
		// OVN annotation can contain comma-separated IPs
		for _, ip := range strings.Split(ipStr, ",") {
			ip = strings.TrimSpace(ip)
			if e.isValidIP(ip) {
				ips = append(ips, ip)
			}
		}
	}

	return ips
}

func (e *IPExtractor) isValidIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	// Verify IP is in CUDN subnet
	return e.cudnSubnet.Contains(ip)
}
