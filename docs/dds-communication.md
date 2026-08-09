# FastDDS / ROS2 通信配置

## 拓扑

```
本机 (192.168.0.101)  ←──FastDDS peer-to-peer──→  Atlas 200I DK A2 (192.168.0.2)
                                                       └── 容器: ros2_dev
```

## 通信参数

| 项目 | 本机 | 容器 ros2_dev | 位置 |
|------|------|--------------|------|
| RMW_IMPLEMENTATION | rmw_fastrtps_cpp | rmw_fastrtps_cpp | `.bashrc` |
| ROS_DOMAIN_ID | 1 | 1 | `.bashrc` |
| Discovery | peer-to-peer (无 server) | peer-to-peer (无 server) | `fastdds_peer.xml` |
| 端口 | 7400 | 7400 | `fastdds_peer.xml` |
| 代理 | — | http://192.168.0.101:7897 | 容器 Env |

## 本机 fastdds_peer.xml

路径: `~/fastdds_peer.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<dds>
  <profiles xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
    <participant profile_name="default_profile" is_default_profile="true">
      <rtps>
        <builtin>
          <initialPeersList>
            <locator><udpv4><address>127.0.0.1</address><port>7400</port></udpv4></locator>
            <locator><udpv4><address>192.168.0.101</address><port>7400</port></udpv4></locator>
            <locator><udpv4><address>192.168.0.2</address><port>7400</port></udpv4></locator>
          </initialPeersList>
        </builtin>
      </rtps>
    </participant>
  </profiles>
</dds>
```

## 容器 fastdds_peer.xml

路径: `/root/fastdds_peer.xml`（容器内）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<profiles xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
  <participant profile_name="atlas_peer" is_default_profile="true">
    <rtps>
      <builtin>
        <initialPeersList>
          <locator><udpv4><address>127.0.0.1</address><port>7400</port></udpv4></locator>
          <locator><udpv4><address>192.168.0.101</address><port>7400</port></udpv4></locator>
          <locator><udpv4><address>192.168.0.2</address><port>7400</port></udpv4></locator>
        </initialPeersList>
      </builtin>
    </rtps>
  </participant>
</profiles>
```

## 容器 .bashrc DDS 段

```bash
source /opt/ros/humble/setup.bash
export FASTRTPS_DEFAULT_PROFILES_FILE=$HOME/fastdds_peer.xml
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_DOMAIN_ID=1
unset ROS_DISCOVERY_SERVER
```

## 修复记录

- **2026-07-21**: 容器 `fastdds_peer.xml` 中 peer 地址原本是 `172.21.100.48`（错误），改为 `192.168.0.101` 和 `192.168.0.2`；`ROS_DOMAIN_ID` 从 0 改为 1
