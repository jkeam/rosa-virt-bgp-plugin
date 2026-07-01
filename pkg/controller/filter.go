package controller

import (
	kubevirtv1 "kubevirt.io/api/core/v1"
)

// HasCUDNInterface checks if a VMI has a network interface matching the configured CUDN
func HasCUDNInterface(vmi *kubevirtv1.VirtualMachineInstance, networkName string) bool {
	if vmi.Spec.Networks == nil {
		return false
	}

	for _, network := range vmi.Spec.Networks {
		if network.Name == networkName && network.Multus != nil {
			return true
		}
	}

	return false
}

// IsRunning checks if a VMI is in Running phase
func IsRunning(vmi *kubevirtv1.VirtualMachineInstance) bool {
	return vmi.Status.Phase == kubevirtv1.Running
}
