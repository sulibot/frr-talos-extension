# Stage 1: Build the FRR container with custom scripts
FROM quay.io/frrouting/frr:10.4.1 AS frr-build

# Install dependencies for config loader
RUN apk add --no-cache --update-cache python3 py3-yaml py3-jinja2 util-linux

# Copy custom scripts
COPY config_loader.py /usr/local/bin/config_loader.py
COPY render_template.py /usr/local/bin/render_template.py
COPY dump-bgp-state.sh /usr/local/bin/dump-bgp-state.sh
RUN chmod +x /usr/local/bin/config_loader.py /usr/local/bin/render_template.py /usr/local/bin/dump-bgp-state.sh

# Copy configuration templates
COPY examples/config-bfd.yaml /etc/frr/config.default.yaml
COPY frr.conf.j2 /etc/frr/frr.conf.j2

# Copy startup script
COPY docker-start.sh /usr/lib/frr/docker-start
RUN chmod 755 /usr/lib/frr/docker-start

# Copy daemons config
COPY daemons /etc/frr/daemons

# Create config directory
RUN mkdir -p /etc/frr/config.d

# Backup /etc/frr for initialization
RUN cp -r /etc/frr /etc/frr.defaults

# Stage 2: Prepare the extension rootfs
FROM alpine:3.19 AS builder

WORKDIR /rootfs

# Create directory structure
RUN mkdir -p usr/local/etc/containers \
             usr/local/share/talos/extensions/frr \
             usr/local/lib/containers/frr

# Copy the FRR container image (from Stage 1) to the extension location
# This effectively "packages" the container inside the extension
COPY --from=frr-build / /rootfs/usr/local/lib/containers/frr/

# Copy Talos configuration files
COPY frr.yaml /rootfs/usr/local/etc/containers/frr.yaml
COPY manifest.yaml /rootfs/usr/local/share/talos/extensions/frr/manifest.yaml

# Stage 3: Create the final extension image
FROM scratch

# Copy the prepared rootfs to the root of the scratch image
COPY --from=builder /rootfs /rootfs

# CRITICAL: Manifest must be at root level for Talos validation
COPY manifest.yaml /manifest.yaml
