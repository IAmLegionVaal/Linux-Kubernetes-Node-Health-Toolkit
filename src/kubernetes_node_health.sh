#!/usr/bin/env bash
set -u

KUBECONFIG_PATH=""
NODE_NAME=""
HOURS=24
OUTPUT_DIR=""

usage() {
  echo "Usage: kubernetes_node_health.sh [--kubeconfig PATH] [--node NAME] [--hours N] [--output DIR]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="${2:-}"; shift 2 ;;
    --node) NODE_NAME="${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$HOURS" =~ ^[0-9]+$ ]] || { echo "--hours must be numeric" >&2; exit 2; }
STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./kubernetes-node-health-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/kubernetes-node-report.txt"
CSV="$OUTPUT_DIR/pods.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
: > "$REPORT"
: > "$ERRORS"
echo 'namespace,pod,node,phase,restarts,ready' > "$CSV"

section() {
  local title="$1"
  shift
  {
    printf '\n===== %s =====\n' "$title"
    "$@"
  } >> "$REPORT" 2>> "$ERRORS" || true
}

KUBECTL=(kubectl)
[[ -n "$KUBECONFIG_PATH" ]] && KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH")

section "Metadata" bash -c 'date -Is; hostname -f 2>/dev/null || hostname; cat /etc/os-release 2>/dev/null || true; id; uname -a'
section "Kubelet service" bash -c 'systemctl status kubelet --no-pager -l 2>/dev/null || true'
section "Container runtime services" bash -c 'systemctl status containerd crio docker --no-pager -l 2>/dev/null || true'
section "Kubelet recent events" bash -c "journalctl -u kubelet --since '$HOURS hours ago' --no-pager -n 2000 2>/dev/null || true"
section "Disk and inode capacity" bash -c 'df -hT; echo; df -hi'
section "Memory and PID pressure" bash -c 'free -h; cat /proc/pressure/memory /proc/pressure/io /proc/pressure/cpu 2>/dev/null || true; ps -e --no-headers | wc -l'
section "CNI inventory" bash -c 'find /etc/cni/net.d /opt/cni/bin -maxdepth 2 -type f -printf "%M %u:%g %p\n" 2>/dev/null | head -n 1000 || true'
section "Network interfaces" ip -brief address

CLUSTER_AVAILABLE=false
if command -v kubectl >/dev/null 2>&1 && "${KUBECTL[@]}" cluster-info >/dev/null 2>&1; then
  CLUSTER_AVAILABLE=true
  [[ -z "$NODE_NAME" ]] && NODE_NAME="$(hostname -s)"
  section "Cluster information" "${KUBECTL[@]}" cluster-info
  section "Node overview" "${KUBECTL[@]}" get nodes -o wide
  section "Selected node description" "${KUBECTL[@]}" describe node "$NODE_NAME"
  section "Selected node YAML" "${KUBECTL[@]}" get node "$NODE_NAME" -o yaml
  section "Recent node events" bash -c "${KUBECTL[*]} get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -n 1000"
  section "Pods on selected node" "${KUBECTL[@]}" get pods -A --field-selector "spec.nodeName=$NODE_NAME" -o wide
  "${KUBECTL[@]}" get pods -A --field-selector "spec.nodeName=$NODE_NAME" -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\t"}{range .status.containerStatuses[*]}{.ready}{","}{end}{"\n"}{end}' 2>>"$ERRORS" | while IFS=$'\t' read -r ns pod node phase restarts ready; do
    printf '"%s","%s","%s","%s","%s","%s"\n' "$ns" "$pod" "$node" "$phase" "$restarts" "$ready" >> "$CSV"
  done
fi

section "Kubernetes certificate files" bash -c 'for f in /var/lib/kubelet/pki/*.pem /etc/kubernetes/pki/*.crt; do [[ -f "$f" ]] || continue; echo "--- $f"; openssl x509 -in "$f" -noout -subject -issuer -dates 2>/dev/null || true; done'

KUBELET_ACTIVE=false
systemctl is-active --quiet kubelet 2>/dev/null && KUBELET_ACTIVE=true
PODS="$(awk 'END {print NR-1}' "$CSV")"
NON_RUNNING="$(awk -F, 'NR>1 && $4 !~ /Running|Succeeded/ {c++} END {print c+0}' "$CSV")"
HIGH_RESTARTS="$(awk -F, 'NR>1 {gsub(/"/,"",$5); split($5,a,","); total=0; for(i in a) total+=a[i]; if(total>=5)c++} END {print c+0}' "$CSV")"
OVERALL="Healthy"
if ! $KUBELET_ACTIVE || [[ "$NON_RUNNING" -gt 0 || "$HIGH_RESTARTS" -gt 0 ]]; then OVERALL="Attention required"; fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -Is)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "selected_node": "$NODE_NAME",
  "kubelet_active": $KUBELET_ACTIVE,
  "cluster_available": $CLUSTER_AVAILABLE,
  "pods_on_node": $PODS,
  "non_running_pods": $NON_RUNNING,
  "pods_with_high_restart_counts": $HIGH_RESTARTS,
  "overall_status": "$OVERALL"
}
EOF

printf '\nKubernetes node health collection completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
