---
name: atlas-board-ssd
description: Development board has an NVMe SSD mounted at /data
metadata: 
  node_type: memory
  type: reference
  originSessionId: 150bd7cd-6801-4c0f-8300-f9c90c8e8a4f
---

The Atlas 200I DK A2 board is equipped with an NVMe SSD (117G total, 22G used, ~90G available) mounted at `/data`.

**Why:** Provides significant storage capacity beyond the root filesystem (57G on `/dev/root`). Docker images, containers, and large data should be stored on /data.

**How to apply:** When allocating storage for large files (Docker images, datasets, build artifacts), always target `/data` rather than root filesystem.
