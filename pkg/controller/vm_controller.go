package controller

import (
	"context"
	"fmt"

	frrk8sv1beta1 "github.com/metallb/frr-k8s/api/v1beta1"
	kubevirtv1 "kubevirt.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	"github.com/jkeam/rosa-virt-bgp-plugin/pkg/config"
)

const (
	AdvertisedIPAnnotation     = "rosa-virt-bgp.io/advertised-ip"
	BGPStatusAnnotation        = "rosa-virt-bgp.io/bgp-status"
	FRRConfigFinalizerName     = "rosa-virt-bgp.io/frr-config-cleanup"
)

type VMReconciler struct {
	client.Client
	Scheme       *runtime.Scheme
	Config       *config.Config
	frrGenerator *FRRGenerator
	ipExtractor  *IPExtractor
}

func NewVMReconciler(c client.Client, scheme *runtime.Scheme, cfg *config.Config) *VMReconciler {
	ipExtractor, _ := NewIPExtractor(c, cfg.NetworkName, cfg.CUDNSubnet)
	frrGenerator := NewFRRGenerator(c, cfg.FRRNamespace, cfg.BGPASN, ipExtractor)

	return &VMReconciler{
		Client:       c,
		Scheme:       scheme,
		Config:       cfg,
		frrGenerator: frrGenerator,
		ipExtractor:  ipExtractor,
	}
}

// Reconcile reconciles VirtualMachineInstance resources
func (r *VMReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := log.FromContext(ctx)

	// Fetch the VirtualMachineInstance
	vmi := &kubevirtv1.VirtualMachineInstance{}
	if err := r.Get(ctx, req.NamespacedName, vmi); err != nil {
		if errors.IsNotFound(err) {
			// VMI deleted - trigger namespace reconciliation to update FRRConfiguration
			log.Info("VMI deleted, reconciling namespace", "namespace", req.Namespace)
			return r.reconcileNamespace(ctx, req.Namespace)
		}
		return ctrl.Result{}, err
	}

	// Skip if VM doesn't have CUDN interface
	if !HasCUDNInterface(vmi, r.Config.NetworkName) {
		log.V(1).Info("skipping VM without CUDN interface", "vm", vmi.Name)
		return ctrl.Result{}, nil
	}

	// Handle deletion
	if !vmi.DeletionTimestamp.IsZero() {
		return r.handleDeletion(ctx, vmi)
	}

	// Add finalizer if not present
	if !controllerutil.ContainsFinalizer(vmi, FRRConfigFinalizerName) {
		controllerutil.AddFinalizer(vmi, FRRConfigFinalizerName)
		if err := r.Update(ctx, vmi); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Skip if VM is not running
	if !IsRunning(vmi) {
		log.V(1).Info("skipping non-running VM", "vm", vmi.Name, "phase", vmi.Status.Phase)
		return ctrl.Result{}, nil
	}

	// Extract IPs
	ips, err := r.ipExtractor.ExtractIPs(ctx, vmi)
	if err != nil {
		log.Info("VM not ready, IPs not available yet", "vm", vmi.Name, "error", err)
		return ctrl.Result{RequeueAfter: r.Config.ReconcileInterval}, nil
	}

	log.Info("reconciling VM with IPs", "vm", vmi.Name, "ips", ips)

	// Reconcile FRRConfiguration for the namespace
	if result, err := r.reconcileNamespace(ctx, vmi.Namespace); err != nil {
		return result, err
	}

	// Update VM annotations if enabled
	if r.Config.EnableStatusUpdates {
		if err := r.updateVMAnnotations(ctx, vmi, ips); err != nil {
			log.Error(err, "failed to update VM annotations")
			// Non-fatal, continue
		}
	}

	return ctrl.Result{}, nil
}

func (r *VMReconciler) reconcileNamespace(ctx context.Context, namespace string) (ctrl.Result, error) {
	log := log.FromContext(ctx)

	// Generate FRRConfiguration for all VMs in the namespace
	frrConfig, err := r.frrGenerator.GenerateConfig(ctx, namespace)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to generate FRRConfiguration: %w", err)
	}

	// Check if there are any prefixes
	if len(frrConfig.Spec.BGP.Routers) == 0 || len(frrConfig.Spec.BGP.Routers[0].Prefixes) == 0 {
		// No VMs with IPs, delete the FRRConfiguration if it exists
		log.Info("no VMs with IPs, deleting FRRConfiguration", "namespace", namespace)
		existing := &frrk8sv1beta1.FRRConfiguration{}
		err := r.Get(ctx, client.ObjectKey{Name: frrConfig.Name, Namespace: frrConfig.Namespace}, existing)
		if err == nil {
			if err := r.Delete(ctx, existing); err != nil {
				return ctrl.Result{}, fmt.Errorf("failed to delete FRRConfiguration: %w", err)
			}
		} else if !errors.IsNotFound(err) {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// Create or update FRRConfiguration
	existing := &frrk8sv1beta1.FRRConfiguration{}
	err = r.Get(ctx, client.ObjectKey{Name: frrConfig.Name, Namespace: frrConfig.Namespace}, existing)
	if err != nil {
		if errors.IsNotFound(err) {
			// Create new FRRConfiguration
			log.Info("creating FRRConfiguration", "name", frrConfig.Name, "prefixes", len(frrConfig.Spec.BGP.Routers[0].Prefixes))
			if err := r.Create(ctx, frrConfig); err != nil {
				return ctrl.Result{}, fmt.Errorf("failed to create FRRConfiguration: %w", err)
			}
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Update existing FRRConfiguration
	existing.Spec = frrConfig.Spec
	existing.Labels = frrConfig.Labels
	log.Info("updating FRRConfiguration", "name", frrConfig.Name, "prefixes", len(frrConfig.Spec.BGP.Routers[0].Prefixes))
	if err := r.Update(ctx, existing); err != nil {
		return ctrl.Result{}, fmt.Errorf("failed to update FRRConfiguration: %w", err)
	}

	return ctrl.Result{}, nil
}

func (r *VMReconciler) handleDeletion(ctx context.Context, vmi *kubevirtv1.VirtualMachineInstance) (ctrl.Result, error) {
	log := log.FromContext(ctx)

	if controllerutil.ContainsFinalizer(vmi, FRRConfigFinalizerName) {
		// Reconcile namespace to remove this VM's IPs from FRRConfiguration
		log.Info("VM being deleted, updating FRRConfiguration", "vm", vmi.Name)
		if _, err := r.reconcileNamespace(ctx, vmi.Namespace); err != nil {
			return ctrl.Result{}, err
		}

		// Remove finalizer
		controllerutil.RemoveFinalizer(vmi, FRRConfigFinalizerName)
		if err := r.Update(ctx, vmi); err != nil {
			return ctrl.Result{}, err
		}
	}

	return ctrl.Result{}, nil
}

func (r *VMReconciler) updateVMAnnotations(ctx context.Context, vmi *kubevirtv1.VirtualMachineInstance, ips []string) error {
	if vmi.Annotations == nil {
		vmi.Annotations = make(map[string]string)
	}

	// Update annotations
	if len(ips) > 0 {
		vmi.Annotations[AdvertisedIPAnnotation] = ips[0]
		vmi.Annotations[BGPStatusAnnotation] = "advertised"
	} else {
		vmi.Annotations[BGPStatusAnnotation] = "pending"
	}

	return r.Update(ctx, vmi)
}

// SetupWithManager sets up the controller with the Manager
func (r *VMReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&kubevirtv1.VirtualMachineInstance{}).
		Owns(&frrk8sv1beta1.FRRConfiguration{}).
		WithEventFilter(predicate.ResourceVersionChangedPredicate{}).
		Complete(r)
}
