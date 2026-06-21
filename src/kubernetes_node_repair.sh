#!/usr/bin/env bash
set -u

NODE=""
KUBECONFIG_PATH=""
RESTART_KUBELET=false
RESTART_RUNTIME=false
RESET_KUBELET=false
UNCORDON=false
DRY_RUN=false
ASSUME_YES=false
OUTPUT_DIR=""
FAILURES=0
ACTIONS=0

usage(){ cat <<'EOF'
Usage: kubernetes_node_repair.sh [options]

  --node NAME             Select the Kubernetes node for verification or uncordon.
  --kubeconfig PATH       Use a specific kubeconfig.
  --restart-kubelet       Restart and verify kubelet.
  --restart-runtime       Restart detected containerd, CRI-O or Docker runtime.
  --reset-kubelet         Clear kubelet failed state and reload systemd.
  --uncordon              Mark the selected node schedulable.
  --dry-run               Show commands without changing the node.
  --yes                   Skip confirmation prompts.
  --output DIR            Save logs and before/after evidence in DIR.
EOF
}
while [ "$#" -gt 0 ]; do case "$1" in
  --node) NODE="${2:-}"; shift 2;; --kubeconfig) KUBECONFIG_PATH="${2:-}"; shift 2;;
  --restart-kubelet) RESTART_KUBELET=true; shift;; --restart-runtime) RESTART_RUNTIME=true; shift;;
  --reset-kubelet) RESET_KUBELET=true; shift;; --uncordon) UNCORDON=true; shift;;
  --dry-run) DRY_RUN=true; shift;; --yes) ASSUME_YES=true; shift;;
  --output) OUTPUT_DIR="${2:-}"; shift 2;; -h|--help) usage; exit 0;;
  *) echo "Unknown argument: $1" >&2; usage; exit 2;; esac; done
if ! $RESTART_KUBELET && ! $RESTART_RUNTIME && ! $RESET_KUBELET && ! $UNCORDON; then echo "Choose at least one repair action." >&2; exit 2; fi
if $UNCORDON; then command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required." >&2; exit 3; }; [ -n "$NODE" ] || { echo "--node is required." >&2; exit 2; }; fi
KUBECTL=(kubectl); [ -z "$KUBECONFIG_PATH" ] || { [ -f "$KUBECONFIG_PATH" ] || { echo "Kubeconfig not found." >&2; exit 2; }; KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH"); }
if [ -n "$NODE" ] && command -v kubectl >/dev/null 2>&1; then "${KUBECTL[@]}" get node "$NODE" >/dev/null 2>&1 || { echo "Node not found or inaccessible: $NODE" >&2; exit 2; }; fi
STAMP=$(date +%Y%m%d_%H%M%S); OUTPUT_DIR="${OUTPUT_DIR:-./kubernetes-node-repair-$STAMP}"; mkdir -p "$OUTPUT_DIR"; LOG="$OUTPUT_DIR/repair.log"; BEFORE="$OUTPUT_DIR/before.txt"; AFTER="$OUTPUT_DIR/after.txt"; : >"$LOG"
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
confirm(){ $ASSUME_YES && return 0; read -r -p "$1 [y/N]: " a; case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
run(){ local d="$1"; shift; ACTIONS=$((ACTIONS+1)); log "$d"; if $DRY_RUN; then printf 'DRY-RUN:' >>"$LOG"; printf ' %q' "$@" >>"$LOG"; printf '\n' >>"$LOG"; return 0; fi; if "$@" >>"$LOG" 2>&1; then log "SUCCESS: $d"; else FAILURES=$((FAILURES+1)); log "WARNING: $d failed"; return 1; fi; }
root(){ local d="$1"; shift; if [ "$(id -u)" -eq 0 ]; then run "$d" "$@"; else run "$d" sudo "$@"; fi; }
runtime_unit(){ for u in containerd.service crio.service docker.service; do systemctl list-unit-files "$u" >/dev/null 2>&1 && { echo "$u"; return; }; done; echo none; }
collect(){ local f="$1"; { echo "Collected: $(date -Is)"; systemctl status kubelet --no-pager -l 2>&1 || true; R=$(runtime_unit); [ "$R" = none ] || systemctl status "$R" --no-pager -l 2>&1 || true; if [ -n "$NODE" ] && command -v kubectl >/dev/null 2>&1; then echo; "${KUBECTL[@]}" get node "$NODE" -o wide 2>&1 || true; "${KUBECTL[@]}" describe node "$NODE" 2>&1 || true; fi; } >"$f"; }
collect "$BEFORE"; confirm "Apply the selected Kubernetes node service repairs? Workloads may be briefly affected." || { log "Repair cancelled."; exit 10; }
if $RESET_KUBELET; then root "Reloading systemd" systemctl daemon-reload || true; root "Clearing kubelet failed state" systemctl reset-failed kubelet || true; fi
$RESTART_KUBELET && root "Restarting kubelet" systemctl restart kubelet || true
if $RESTART_RUNTIME; then RUNTIME=$(runtime_unit); [ "$RUNTIME" != none ] && root "Restarting $RUNTIME" systemctl restart "$RUNTIME" || { FAILURES=$((FAILURES+1)); log "WARNING: container runtime service not found."; }; fi
$UNCORDON && run "Marking node $NODE schedulable" "${KUBECTL[@]}" uncordon "$NODE" || true
$DRY_RUN || sleep 5; collect "$AFTER"; if $RESTART_KUBELET || $RESET_KUBELET; then systemctl is-active --quiet kubelet || { FAILURES=$((FAILURES+1)); log "WARNING: kubelet is not active."; }; fi; [ "$FAILURES" -eq 0 ] || exit 20; log "Kubernetes node repair completed successfully. Actions performed: $ACTIONS"
