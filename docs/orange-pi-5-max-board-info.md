# Orange Pi 5 Max board profile

Updated: 2026-08-10

## Confirmed host

| Item | Value |
|---|---|
| Board | Orange Pi 5 Max, RK3588 |
| Architecture | `aarch64` |
| Host OS | Arch Linux ARM, rolling |
| Kernel | `5.10.160-1` |
| Memory | 7.8 GiB RAM, 11 GiB zram swap |
| Docker | 29.7.1, cgroup v2 |
| Compose | 5.4.0 |
| SSH endpoint | `orangepi@192.168.218.200` |
| Wi-Fi | `wlan0`, `192.168.108.42/24` |
| Wired Ethernet | `enP3p49s0` |
| NVMe | `/mnt/ssd`, about 110 GiB free |

## Deployment paths

- Docker data root: `/mnt/ssd/docker`
- Container host data: `/mnt/ssd/data`
- Container data mount: `/data`
- Bag host directory: `/mnt/ssd/bags`
- Bag container mount: `/bags` (read-only)
- Compose file: `deploy/compose.orange-pi-5-max.yml`

The NVMe mount must be persistent and available before Docker starts. Confirm
the migration with:

```bash
findmnt /mnt/ssd
docker info --format '{{.DockerRootDir}}'
systemctl show docker -p After -p RequiresMountsFor
```

## Pending hardware checks

- Livox is not connected. `enP3p49s0` is confirmed, but its host CIDR is not.
- D435i is not connected. Confirm it appears in `lsusb` on a USB 3.0 port.
- Keep `CONFIGURE_LIDAR_INTERFACE=false` until the Livox subnet is confirmed.
- Confirm a stable 5 V / 5 A supply and active cooling before sustained use.

The current image implementation, validation results, artifact checksums and
board deployment procedure are recorded in
[`orange-pi-5-max-container-worklog-20260809.md`](orange-pi-5-max-container-worklog-20260809.md).
