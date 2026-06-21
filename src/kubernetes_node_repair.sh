#!/usr/bin/env bash
set -u

NODE=""
KUBECONFIG_PATH=""
RESTART_KUBELET=false
RESTART_RUNTIME=false
RESET_KUBELET=false
CORDON=false
UNCORDON=false
DRY_RUN=false
ASSUME_YES=false
OUTPUT_DIR=""
FAILURES=0
ACTIONS=0

usage(){ cat <<'EOF'
Usage: kubernetes_node_repair.sh [options]

  --node NAME             Select the node for cordon, uncordon and verification.
  --kubeconfig PATH       Use a specific kubeconfig.
  --restart-kubelet       Restart and verify kubelet.
  --restart-runtime       Restart detected containerd, CRI-O or Docker runtime.
  --reset-kubelet         Reload systemd and clear kubelet failed state.
  --cordon                Mark the selected node unschedulable.
  --uncordon              Mark the selected node schedulable.
  --dry-run               Show commands without changing the node.
  --yes                   Skip confirmation prompts.
  --output DIR            Save logs, backups and before/after evidence in DIR.
EOF
}
while [ "$#" -gt 0 ]; do case "$1" in
  --node) NODE="${2:-}"; shift 2;; --kubeconfig) KUBECONFIG_PATH="${2:-}"; shift 2;;
  --restart-kubelet) RESTART_KUBELET=true; shift;; --restart-runtime) RESTART_RUNTIME=true; shift;;
  --reset-kubelet) RESET_KUBELET=true; shift;; --cordon) CORDON=true; shift;; --uncordon) UNCORDON=true; shift;;
  --dry-run) DRY_RUN=true; shift;; --yes) ASSUME_YES=true; shift;;
  --output) OUTPUT_DIR="${2:-}"; shift 2;; -h|--help) usage; exit 0;;
  *) echo "Unknown argument: $1" >&2; usage; exit 2;; esac; done

[ "$(uname -s)" = Linux ] || { echo "Linux is required." >&2; exit 3; }
if ! $RESTART_KUBELET && ! $RESTART_RUNTIME && ! $RESET_KUBELET && ! $CORDON && ! $UNCORDON; then echo "Choose at least one repair action." >&2; exit 2; fi
$CORDON && $UNCORDON && { echo "Choose either --cordon or --uncordon." >&2; exit 2; }
if $CORDON || $UNCORDON; then command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required." >&2; exit 3; }; [ -n "$NODE" ] || { echo "--node is required." >&2; exit 2; }; fi
KUBECTL=(kubectl); [ -z "$KUBECONFIG_PATH" ] || { [ -r "$KUBECONFIG_PATH" ] || { echo "Kubeconfig not readable." >&2; exit 2; }; KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH"); }
if [ -n "$NODE" ] && command -v kubectl >/dev/null 2>&1; then "${KUBECTL[@]}" get node "$NODE" >/dev/null 2>&1 || { echo "Node not found or inaccessible: $NODE" >&2; exit 2; }; fi

STAMP=$(date +%Y%m%d_%H%M%S); OUTPUT_DIR="${OUTPUT_DIR:-./kubernetes-node-repair-$STAMP}"; BACKUP_DIR="$OUTPUT_DIR/backup"; mkdir -p "$BACKUP_DIR"; chmod 700 "$OUTPUT_DIR" "$BACKUP_DIR" 2>/dev/null || true
LOG="$OUTPUT_DIR/repair.log"; BEFORE="$OUTPUT_DIR/before.txt"; AFTER="$OUTPUT_DIR/after.txt"; : >"$LOG"
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
confirm(){ $ASSUME_YES && return 0; read -r -p "$1 [y/N]: " a; case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
run(){ local d="$1"; shift; ACTIONS=$((ACTIONS+1)); log "$d"; if $DRY_RUN; then printf 'DRY-RUN:' >>"$LOG"; printf ' %q' "$@" >>"$LOG"; printf '\n' >>"$LOG"; return 0; fi; if "$@" >>"$LOG" 2>&1; then log "SUCCESS: $d"; else FAILURES=$((FAILURES+1)); log "WARNING: $d failed"; return 1; fi; }
root(){ local d="$1"; shift; if [ "$(id -u)" -eq 0 ]; then run "$d" "$@"; elif command -v sudo >/dev/null 2>&1; then run "$d" sudo "$@"; else FAILURES=$((FAILURES+1)); log "WARNING: sudo is required for $d"; return 1; fi; }
runtime_unit(){ for u in containerd.service crio.service docker.service; do systemctl cat "$u" >/dev/null 2>&1 && { echo "$u"; return; }; done; echo none; }
collect(){ local f="$1"; { echo "Collected: $(date -Is)"; systemctl status kubelet --no-pager -l 2>&1 || true; R=$(runtime_unit); echo "Runtime: $R"; [ "$R" = none ] || systemctl status "$R" --no-pager -l 2>&1 || true; if [ -n "$NODE" ] && command -v kubectl >/dev/null 2>&1; then echo; "${KUBECTL[@]}" get node "$NODE" -o wide 2>&1 || true; "${KUBECTL[@]}" get node "$NODE" -o jsonpath='{.spec.unschedulable}{"\n"}{range .status.conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}' 2>&1 || true; fi; } >"$f"; }

collect "$BEFORE"
for f in /var/lib/kubelet/config.yaml /etc/kubernetes/kubelet.conf /etc/containerd/config.toml /etc/crio/crio.conf /etc/docker/daemon.json; do [ -f "$f" ] || continue; $DRY_RUN && log "DRY-RUN: would back up $f" || root "Backing up $f" cp -a "$f" "$BACKUP_DIR/" || true; done
if [ -n "$NODE" ] && ! $DRY_RUN; then "${KUBECTL[@]}" get node "$NODE" -o yaml >"$BACKUP_DIR/node-$NODE.yaml" 2>>"$LOG" || { FAILURES=$((FAILURES+1)); log "WARNING: node YAML backup failed."; }; fi
confirm "Apply the selected Kubernetes node repairs? Workloads or scheduling may be affected." || { log "Repair cancelled."; exit 10; }
if $RESET_KUBELET; then root "Reloading systemd" systemctl daemon-reload || true; root "Clearing kubelet failed state" systemctl reset-failed kubelet || true; fi
$RESTART_KUBELET && root "Restarting kubelet" systemctl restart kubelet || true
if $RESTART_RUNTIME; then RUNTIME=$(runtime_unit); [ "$RUNTIME" != none ] && root "Restarting $RUNTIME" systemctl restart "$RUNTIME" || { FAILURES=$((FAILURES+1)); log "WARNING: container runtime service not found."; }; fi
$CORDON && run "Cordoning node $NODE" "${KUBECTL[@]}" cordon "$NODE" || true
$UNCORDON && run "Uncordoning node $NODE" "${KUBECTL[@]}" uncordon "$NODE" || true
$DRY_RUN || sleep 5
collect "$AFTER"
if $RESTART_KUBELET || $RESET_KUBELET; then $DRY_RUN || systemctl is-active --quiet kubelet || { FAILURES=$((FAILURES+1)); log "WARNING: kubelet is not active."; }; fi
[ "$FAILURES" -eq 0 ] || { log "Repair completed with warnings or failures."; exit 20; }
log "Kubernetes node repair completed successfully. Actions performed: $ACTIONS"
exit 0
