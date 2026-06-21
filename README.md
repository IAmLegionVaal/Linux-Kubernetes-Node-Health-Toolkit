# Linux Kubernetes Node Health Toolkit

A Linux support toolkit for diagnosing Kubernetes node problems and applying selected guarded node-service and scheduling repairs.

## Diagnostic script

```bash
chmod +x src/kubernetes_node_health.sh
sudo ./src/kubernetes_node_health.sh --kubeconfig ~/.kube/config --node worker-01
```

## Repair script

Preview a kubelet restart:

```bash
chmod +x src/kubernetes_node_repair.sh
sudo ./src/kubernetes_node_repair.sh --restart-kubelet --dry-run
```

Examples:

```bash
sudo ./src/kubernetes_node_repair.sh --reset-kubelet --restart-kubelet
sudo ./src/kubernetes_node_repair.sh --restart-runtime
./src/kubernetes_node_repair.sh --node worker-01 --cordon
./src/kubernetes_node_repair.sh --node worker-01 --uncordon
```

Use `--kubeconfig PATH` when the default kubectl context is not appropriate.

## What the repair does

- Reloads systemd and clears stale kubelet failure state when selected.
- Restarts and verifies kubelet.
- Detects and restarts containerd, CRI-O or Docker when explicitly selected.
- Cordons or uncordons one explicitly selected Kubernetes node.
- Backs up existing kubelet and container-runtime configuration files before service changes.
- Saves the selected node definition before a scheduling change.
- Captures kubelet, runtime and selected-node state before and after repair.
- Supports a selected kubeconfig, dry-run, confirmation prompts, privilege handling, action logs and clear exit codes.

## Safety

Restarting kubelet or the container runtime can briefly affect workloads. Cordoning changes scheduling but does not evict existing pods. The tool does not drain nodes, delete pods, change workloads, remove containers or edit cluster resources beyond the selected cordon state.

## Validation note

The scripts were not runtime-tested on a Kubernetes node during this repository update. Validate them in a non-production environment before operational use.

## Author

Dewald Pretorius — L2 IT Support Engineer
