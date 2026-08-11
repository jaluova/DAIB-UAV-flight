# Orange Pi 5 Max board profile

Updated: 2026-08-10

## Confirmed host

| Item | Value |
|---|---|
| Board | Orange Pi 5 Max, RK3588 |
| Architecture | `aarch64` |
| Host OS | Orange Pi 1.0.0, Ubuntu 22.04.4 LTS (Jammy) |
| Kernel | `6.1.43-rockchip-rk3588` |
| Memory | 7.7 GiB RAM, 3.9 GiB swap |
| Docker | 27.0.3, cgroup v2, overlay2 |
| Compose | 5.4.0 |
| SSH endpoint | `orangepi@192.168.218.200` |
| Wi-Fi | `wlan0`, `192.168.218.200/24` |
| Wired Ethernet | `enP3p49s0`, Livox host address `192.168.1.50/24` |
| Root filesystem | `/dev/mmcblk1p2`, 56 GiB, about 53 GiB free |
| NVMe | `/dev/nvme0n1p1`, 117 GiB, about 93 GiB free at `/mnt/ssd` |
| Terminal multiplexer | `tmux` installed at `/usr/bin/tmux` |

## Deployment paths

- Docker data root: `/mnt/ssd/docker`
- Container host data: `/mnt/ssd/data`
- Container data mount: `/data`
- Bag host directory: `/mnt/ssd/bags`
- Bag container mount: `/bags` (read-only)
- Compose file: `deploy/compose.orange-pi-5-max.yml`

The NVMe mount is persistent in `/etc/fstab`, and Docker currently stores data
under `/mnt/ssd/docker`. Confirm the migration with:

```bash
findmnt /mnt/ssd
docker info --format '{{.DockerRootDir}}'
systemctl show docker -p After -p RequiresMountsFor
```

The current Ubuntu Docker unit does not declare `RequiresMountsFor=/mnt/ssd`.
Add a systemd dependency before relying on automatic boot startup; otherwise
Docker may start before the `nofail` NVMe mount is ready.

## Sensor network validation

- MID-70 `192.168.1.119` was validated on `enP3p49s0` with host address
  `192.168.1.50/24` and broadcast code `3GGDLA4001V3191`.
- On kernel `6.1.43-rockchip-rk3588`, Livox broadcast reception requires
  `net.ipv4.conf.all.rp_filter=0` and
  `net.ipv4.conf.enP3p49s0.rp_filter=0`.
- D435i is not connected. Confirm it appears in `lsusb` on a USB 3.0 port.
- Confirm a stable 5 V / 5 A supply and active cooling before sustained use.

The current image implementation, validation results, artifact checksums and
board deployment procedure are recorded in
[`orange-pi-5-max-container-worklog-20260809.md`](orange-pi-5-max-container-worklog-20260809.md).
