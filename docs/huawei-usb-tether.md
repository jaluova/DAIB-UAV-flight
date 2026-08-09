# Huawei Atlas 200I DK A2 — USB RNDIS 网络连接

## 问题
RNDIS 随机 MAC → 接口名不固定（`enx...`），NM 若绑 MAC 必死。

## 解决
固定接口名 + NM 绑接口名（不绑 MAC）。

```bash
# 1. systemd .link: 按驱动固定接口名为 usb0
sudo tee /etc/systemd/network/99-huawei-usb-tether.link <<'EOF'
[Match]
Driver=rndis_host
[Link]
Name=usb0
EOF

# 2. NM: 绑 usb0（不指定 mac-address）
nmcli con add type ethernet ifname usb0 con-name huawei-usb-tether \
  ipv4.method manual ipv4.addresses 192.168.0.101/24 \
  ipv4.gateway 192.168.0.1 ipv4.dns "192.168.0.1,223.5.5.5" \
  ipv6.method disabled autoconnect yes

# 3. 立即生效（不重插）
sudo ip link set enx* down
sudo ip link set enx* name usb0
sudo ip link set usb0 up
```

## 使用
插 USB 线即连。`ssh root@192.168.0.2`
