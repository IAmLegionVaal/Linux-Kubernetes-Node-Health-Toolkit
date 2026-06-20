# Linux Kubernetes Node Health Toolkit

A read-only Bash toolkit for collecting kubelet, container-runtime, node-condition, pod, certificate, pressure, and cluster-connectivity evidence.

## Usage

```bash
chmod +x src/kubernetes_node_health.sh
sudo ./src/kubernetes_node_health.sh
```

Use a specific kubeconfig and node:

```bash
sudo ./src/kubernetes_node_health.sh --kubeconfig ~/.kube/config --node worker-01
```

## Checks performed

- Kubelet and container runtime service health
- Node conditions, capacity, allocatable resources, taints, and events
- Pods scheduled on the node and restart counts
- Disk, memory, PID, and inode pressure indicators
- Kubernetes and kubelet certificate expiry
- CNI configuration and network interfaces
- Text, CSV, and JSON reports

## Safety

The script never drains, cordons, deletes, restarts, scales, patches, or changes Kubernetes resources.

## Author

Dewald Pretorius — L2 IT Support Engineer
