package config

import (
	"fmt"
	"net"
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	// Network configuration
	NetworkName                 string `yaml:"networkName"`
	NetworkAttachmentDefinition string `yaml:"networkAttachmentDefinition"`
	CUDNSubnet                  string `yaml:"cudnSubnet"`

	// FRR configuration
	FRRNamespace string `yaml:"frrNamespace"`
	BGPASN       uint32 `yaml:"bgpASN"`

	// Controller behavior
	ReconcileInterval   time.Duration `yaml:"reconcileInterval"`
	IPDiscoveryTimeout  time.Duration `yaml:"ipDiscoveryTimeout"`

	// Feature flags
	EnableMetrics       bool `yaml:"enableMetrics"`
	EnableStatusUpdates bool `yaml:"enableStatusUpdates"`
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	// Set defaults
	if cfg.FRRNamespace == "" {
		cfg.FRRNamespace = "frr-k8s-system"
	}
	if cfg.ReconcileInterval == 0 {
		cfg.ReconcileInterval = 30 * time.Second
	}
	if cfg.IPDiscoveryTimeout == 0 {
		cfg.IPDiscoveryTimeout = 5 * time.Minute
	}

	return &cfg, nil
}

func (c *Config) Validate() error {
	if c.NetworkName == "" {
		return fmt.Errorf("networkName is required")
	}
	if c.NetworkAttachmentDefinition == "" {
		return fmt.Errorf("networkAttachmentDefinition is required")
	}
	if c.CUDNSubnet == "" {
		return fmt.Errorf("cudnSubnet is required")
	}

	// Validate CIDR
	_, _, err := net.ParseCIDR(c.CUDNSubnet)
	if err != nil {
		return fmt.Errorf("invalid cudnSubnet CIDR: %w", err)
	}

	if c.BGPASN == 0 {
		return fmt.Errorf("bgpASN is required")
	}

	return nil
}
