# FUEL exploration integration

The `fuel_plan_env`, `fuel_path_searching`, and `fuel_active_perception`
packages are an isolated, namespaced import of the upstream FUEL exploration
stack. They use `fuel_*` package names and `fuel_planner` C++ namespaces so
they can coexist with the existing EGO planner packages.

`fuel_goal_bridge` is the device integration entry point. It consumes
`/daib_slam/odom` and `/daib_slam/planning_cloud`, builds the FUEL SDF and
frontier/viewpoint map, and publishes the first safe FUEL viewpoint as
`/daib_explorer/goal`. EGO, `psdk_velocity_adapter`, and the PSDK flight
program remain the only trajectory/control chain.

The upstream FUEL trajectory executor and LKH process are kept in the source
tree but marked `CATKIN_IGNORE` for this integration. Starting them would
create a second trajectory publisher and bypass the existing EGO/PSDK safety
limits. The bridge uses FUEL's viewpoint generation and path/yaw cost for the
first leg; full multi-frontier TSP execution is a later opt-in step after bag
validation.

FUEL is GPLv3; see `FUEL-LICENSE`.
