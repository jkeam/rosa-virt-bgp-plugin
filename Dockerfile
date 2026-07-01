# Runtime stage only - binary is built locally
FROM registry.access.redhat.com/ubi9/ubi-micro:latest

WORKDIR /

# Copy pre-built binary
COPY bin/controller .

# OpenShift uses arbitrary UIDs in the root group (GID 0)
USER 1001:0

ENTRYPOINT ["/controller"]
