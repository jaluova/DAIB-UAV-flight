# 局域网 Docker Registry

更新日期：2026-08-09

## 当前状态

- Registry 运行在构建 Mac：`http://192.168.126.119:5050`。
- 容器名：`daib-registry`，镜像：`registry:2`。
- 持久化卷：`daib-registry-data`。
- 重启策略：`unless-stopped`。
- `5000` 被 macOS ControlCenter/AirPlay 占用，因此使用 `5050`。
- `daib-algorithm:openeuler-arm64` 已首次推送成功。
- 当前 manifest digest：
  `sha256:d6063d42dc656da29bd5156ce826f934c2c6aba75a10632fb987097f66e161bc`。
- Registry 数据当前约 788.7 MiB。
- 板卡创建 Registry 时不在线，板卡端 pull 尚未验证。

## 日常更新

Mac 构建后执行：

```bash
docker tag \
  daib-algorithm:openeuler-arm64 \
  localhost:5050/daib-algorithm:openeuler-arm64
docker push localhost:5050/daib-algorithm:openeuler-arm64
```

板卡的 `/etc/docker/daemon.json` 必须合并以下配置，不能覆盖已有
`data-root`：

```json
{
  "insecure-registries": ["192.168.126.119:5050"]
}
```

板卡更新：

```bash
sudo systemctl restart docker
docker pull 192.168.126.119:5050/daib-algorithm:openeuler-arm64
```

`deploy/.env`：

```dotenv
ALGORITHM_IMAGE=192.168.126.119:5050/daib-algorithm:openeuler-arm64
```

## 检查与恢复

```bash
docker ps --filter name=daib-registry
curl http://127.0.0.1:5050/v2/
curl http://127.0.0.1:5050/v2/_catalog
curl http://127.0.0.1:5050/v2/daib-algorithm/tags/list
docker start daib-registry
```

Mac 必须运行 Docker Desktop 和 `daib-registry`，板卡才能拉取。Mac 的
`192.168.126.119` 应设置 DHCP 地址保留。局域网可以完全离线传输；只有
首次获取 `registry:2` 或基础镜像时需要外网。

## 代理经验

- 本机代理：`127.0.0.1:7897`。
- 只设置终端 `https_proxy` 不会影响 Docker daemon。
- 首次 pull 超时的原因是 macOS 系统 HTTP/HTTPS 代理地址存在但未启用。
- 启用系统代理后 Docker pull 成功。
- `docker info` 显示的 `http.docker.internal:3128` 是 Docker Desktop
  内部代理端点。
- 构建容器不能使用 `127.0.0.1:7897`，应使用
  `http://host.docker.internal:7897`。

Registry 使用 HTTP，只适用于可信局域网，不应映射到公网。
