---
name: docker-data-root
description: Docker data root is configured to /data/docker on the NVMe SSD
metadata: 
  node_type: memory
  type: reference
  originSessionId: 150bd7cd-6801-4c0f-8300-f9c90c8e8a4f
---

Docker's data root directory is `/data/docker` (on the NVMe SSD, mounted at `/data`).

**Why:** This means Docker images and container data are stored on the 117G NVMe SSD rather than the 57G root filesystem, giving more room for large images like the 21.8GB fastlivo2-arm64 image.

**How to apply:** Docker image pulls, builds, and container storage will automatically use this path. No special configuration needed. Monitor disk space with `df -h /data`.
