# Linux Kubernetes Node Health Toolkit

A Linux support toolkit for diagnosing Kubernetes node problems and applying selected guarded node-service repairs.

## Diagnostic script

```bash
chmod +x src/kubernetes_node_health.sh
sudo ./src/kubernetes_node_health.sh --kubeconfig ~/.kube/config --node worker-01
```

## Repair script

```bash
chmod +x src/kubernetes_node_repair.sh
sudo ./src/kubernetes_node_repair.sh --restart-kubelet --dry-run
```

Examples:

```bash
sudo ./src/kubernetes_node_repair.sh --reset-kubelet --restart-kubelet
sudo ./src/kubernetes_node_repair.sh --restart-runtime
sudo ./src/kubernetes_node_repair.sh --node worker-01 --uncordon
```

## What the repair does

- Reloads systemd and clears stale kubelet failure state.
- Restarts and verifies kubelet.
- Detects and restarts containerd, CRI-O or Docker when explicitly selected.
- Marks one selected Kubernetes node schedulable with `kubectl uncordon`.
- Captures kubelet, runtime and selected-node state before and after repair.
- Supports a selected kubeconfig, dry-run, confirmation prompts, logs and clear exit codes.

## Safety

Restarting kubelet or the container runtime can briefly affect workloads. The tool does not drain nodes, delete pods, change workloads, patch resources or modify cluster configuration automatically.

## Author

Dewald Pretorius — L2 IT Support Engineer
