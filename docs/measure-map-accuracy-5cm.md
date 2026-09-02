# 5 cm 建图精度测量流程（香橙派录包 → 本机 PCD 选点测量）

目标：验证 FAST-LIVO 建出的地图里，两点间距离与实物卷尺量的一致性能到 ~5 cm。
测量工具：`tools/measure_pcd_distances.py`（Open3D 打开 PCD，Shift+点击选点，输出米/厘米与预期误差）。

> `/cloud_registered` 就是 `sensor_msgs/PointCloud2`，可以直接导出 PCD。它是"单帧注册点云"
> （不是累积地图），每帧都在同一个地图坐标系（camera_init），所以可以多帧合并成一个更密的
> 点云，见下文 `--accumulate`。

## 0. 外场标定物（测量前提）

场景里放置已知长度的实物，长度要量准（游标卡尺/硬尺）：

- 一个 20~50 cm 短参照（测局部几何保真）：如标定板边、硬制直尺；
- 一个 ≥1 m 长参照（测地图尺度）：如两个相距 1~2 m 的固定标记（瓷砖缝、铁杆两端）。

原因：脚本是"点选最近点"，稀疏地图下点击本身有 1~3 cm 抖动；参照太短时误差占比大，
测不出 5 cm 级的尺度偏差。建议多点几次取均值。

## 1. 香橙派录制

FAST-LIVO 正常运行期间，在 OP 上执行：

    ./scripts/record_map_accuracy.sh 90      # 90 s 后自动停止；不带参数则 Ctrl+C 停止

- 默认只录 `/cloud_registered`（够用、包小）；
- 若该 build 发布全局累积地图 `/Laser_map`，取消脚本中对应行的注释再录，后面直接用
  它的最后一帧更省事；
- 建议动作：静止起飞 → 缓慢把标定物完整扫两遍（保证目标区域点云密、好选点）→ 降落。
- 停止后确认 `/mnt/ssd/bags/map_acc_*.bag.active` 已消失（索引写完）再断电。

## 2. 传输到本机

包在 OP 的 `/mnt/ssd/bags/`：

    rsync -avP --partial <OP用户>@<OP_IP>:/mnt/ssd/bags/map_acc_*.bag ~/DAIB-UAV-flight/bags/

## 3. 本机导出 PCD（无需安装 ROS）

依赖已就绪：`/tmp/o3d-venv`（Python 3.10 + open3d 0.19.0 + rosbags 0.11.5，默认
python3.14 没有 open3d wheel，所以固定用这个 venv）。

    cd ~/DAIB-UAV-flight/tools
    /tmp/o3d-venv/bin/python bag_to_pcd.py ../bags/map_acc_xxx.bag /cloud_registered acc.pcd --accumulate   # 合并所有帧（推荐）
    # 或取最后一帧 / 抽帧：
    # /tmp/o3d-venv/bin/python bag_to_pcd.py ../bags/map_acc_xxx.bag /cloud_registered last.pcd
    # /tmp/o3d-venv/bin/python bag_to_pcd.py ../bags/map_acc_xxx.bag /cloud_registered f.pcd --every-n 30

如果录了 `/Laser_map`，取它最后一帧即为累积地图：

    /tmp/o3d-venv/bin/python bag_to_pcd.py ../bags/map_acc_xxx.bag /Laser_map map.pcd

## 4. 测量

    /tmp/o3d-venv/bin/python measure_pcd_distances.py acc.pcd --expected 0.20 1.00 ...

- 打开窗口后按住 Shift 点击：先点短参照两端，再点长参照两端，然后关窗口；
- `--expected` 顺序与点击顺序一致，单位米（20 cm 填 0.20，1 m 填 1.00）；
- 不要用 `--voxel-size` 降采样（降采样会改变可选点，影响测量）；
- 每组参照点 3~5 次，取中间值。

## 5. 判定

| 现象 | 结论 |
|---|---|
| 各项误差 ≤ 5 cm，符号不随参照长度持续同号 | 通过（局部几何 + 尺度 OK） |
| 误差随参照长度近似线性增长（如 1 m 差 1 cm、2 m 差 2 cm） | 地图尺度偏差，报告百分比（误差/长度） |
| 短参照误差大、长参照误差小 | 局部点云抖动/密度问题，非尺度问题 |

## 复用与回归

- 没有真实 bag 时可用合成数据回归整条链路（本机已验证通过）：
      /tmp/o3d-venv/bin/python make_test_bag.py test_board.bag 20
      /tmp/o3d-venv/bin/python bag_to_pcd.py test_board.bag /cloud_registered acc.pcd --accumulate
      python3 measure_pcd_distances.py acc.pcd --points 0,0,0 0.5,0,0 0.25,0.25,0 0.45,0.25,0 --expected 0.50 0.3536 0.20
- 合成标定板 `tools/test_board.pcd`（50 cm 方框 + 20 cm 横杆）可单独用来练习 GUI 选点。
