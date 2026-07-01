# Makefile for ROSA Virt BGP Plugin

# Image URL to use for building/pushing image targets
IMG ?= quay.io/andy_krohg/rosa-virt-bgp-controller:v0.1.0

# Go parameters
GOCMD=go
GOBUILD=$(GOCMD) build
GOCLEAN=$(GOCMD) clean
GOTEST=$(GOCMD) test
GOGET=$(GOCMD) get
GOMOD=$(GOCMD) mod

# Binary name
BINARY_NAME=rosa-virt-bgp-controller

# Build directory
BUILD_DIR=bin

.PHONY: all build clean test help install-deps docker-build docker-push deploy undeploy manifests fmt vet tidy

all: test build

## help: Show this help message
help:
	@echo 'Usage:'
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' |  sed -e 's/^/ /'

## build: Build the controller binary for linux/amd64
build:
	mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GOBUILD) -o $(BUILD_DIR)/controller -v ./cmd/controller

## clean: Clean build artifacts
clean:
	$(GOCLEAN)
	rm -rf $(BUILD_DIR)

## test: Run unit tests
test:
	$(GOTEST) -v ./pkg/... ./cmd/...

## test-e2e: Run end-to-end tests
test-e2e:
	$(GOTEST) -v ./test/e2e/...

## fmt: Run go fmt
fmt:
	$(GOCMD) fmt ./...

## vet: Run go vet
vet:
	$(GOCMD) vet ./...

## tidy: Tidy go modules
tidy:
	$(GOMOD) tidy

## install-deps: Install Go dependencies
install-deps:
	$(GOGET) -v ./...
	$(GOMOD) tidy

## docker-build: Build docker image
docker-build: build
	podman build --platform linux/amd64 -t ${IMG} .

## vendor: Download dependencies to vendor directory
vendor:
	go mod vendor

## docker-push: Push docker image
docker-push:
	podman push ${IMG}

## deploy: Deploy all manifests to cluster
deploy:
	kubectl apply -f manifests/01-prerequisites/
	kubectl apply -f manifests/02-networking/
	kubectl apply -f manifests/03-frr/
	kubectl apply -f manifests/04-controller/

## deploy-examples: Deploy example VMs
deploy-examples:
	kubectl apply -f manifests/05-examples/

## undeploy: Remove all manifests from cluster
undeploy:
	kubectl delete -f manifests/04-controller/ --ignore-not-found=true
	kubectl delete -f manifests/03-frr/ --ignore-not-found=true
	kubectl delete -f manifests/02-networking/ --ignore-not-found=true
	kubectl delete -f manifests/01-prerequisites/ --ignore-not-found=true

## verify-bgp: Verify BGP peering status
verify-bgp:
	@./hack/verify-bgp.sh

## debug-vm: Debug VM networking
debug-vm:
	@./hack/debug-vm-networking.sh

## install-prereqs: Install prerequisites (FRR-K8s CRDs, etc.)
install-prereqs:
	@./hack/install-prereqs.sh

## setup-vlan: Helper to setup VLAN trunk (requires customization)
setup-vlan:
	@./hack/setup-vlan.sh
