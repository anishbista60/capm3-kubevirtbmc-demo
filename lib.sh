# Shared helpers for the CAPM3 + KubeVirtBMC demo scripts. Sourced, not run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$ROOT/manifests"
OUT="$ROOT/out"
mkdir -p "$OUT"

# shellcheck source=versions.env
source "$ROOT/versions.env"

# --- Knobs -------------------------------------------------------------------
: "${KIND_CLUSTER_NAME:=capm3-kubevirtbmc}"
: "${CONTAINER_RUNTIME:=docker}"
KIND_NODE="${KIND_CLUSTER_NAME}-control-plane"

: "${SPARE_HOSTS:=1}"                       # free BMHs kept around for scale-out / rolling upgrades

# Fixed by the plain manifests in manifests/: change them there as well.
CLUSTER_NAME=kvbmc-cluster                 # the CAPI workload cluster (manifests/cluster/)
NAMESPACE=default                          # every namespaced manifest uses it
CP_REPLICAS=1                              # initial KubeadmControlPlane replicas
WORKER_REPLICAS=1                          # initial MachineDeployment replicas
HOST_PREFIX=kvbmc-node                     # one directory per host in manifests/hosts/
HOST_LABEL="capm3-demo.metal3.io/host"
VIP=192.168.100.100                        # kube-vip VIP on baremetal-net (manifests/platform/01-baremetal-net.yaml)

# true  = Ironic serves virtual media over HTTPS; KubeVirtBMC/CDI trust Ironic's CA
#         through VirtualMachineBMC.spec.redfish.virtualMedia.tls (KubeVirtBMC >= v0.11.0)
# false = virtual media over plain HTTP, the configuration used in Part 2 of the series
: "${VIRTUAL_MEDIA_TLS:=true}"

# --- Output ------------------------------------------------------------------
BOLD=$'\033[1m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'

section() { printf '\n%s%s== %s ==%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
info()    { printf '%s -> %s%s\n' "$GREEN" "$1" "$RESET"; }
warn()    { printf '%s !! %s%s\n' "$YELLOW" "$1" "$RESET"; }
die()     { printf '%s xx %s%s\n' "$RED" "$1" "$RESET" >&2; exit 1; }

on_error() {
  echo
  warn "Failed at $(basename "$0"):$1. Fix the cause and re-run — steps are idempotent."
  exit 1
}

# --- Stage timings (collected into out/timings.tsv for the blog) ---------------
STAGE_NAME=""; STAGE_START=0
stage_start() { STAGE_NAME=$1; STAGE_START=$(date +%s); section "$1"; }
stage_end() {
  local secs=$(( $(date +%s) - STAGE_START ))
  printf '%s\t%s\t%ds\n' "$(date -u +%FT%TZ)" "$STAGE_NAME" "$secs" >> "$OUT/timings.tsv"
  info "$STAGE_NAME took $(fmt_secs "$secs")"
}
fmt_secs() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# --- Polling -------------------------------------------------------------------
# wait_until <description> <timeout-seconds> <check-cmd> [status-cmd]
# Re-runs check-cmd every 10s until it succeeds. status-cmd, if given, prints a
# one-line progress update on each iteration.
wait_until() {
  local desc=$1 timeout=$2 check=$3 status=${4:-}
  local start; start=$(date +%s)
  info "waiting for $desc (timeout $(fmt_secs "$timeout"))"
  while true; do
    if eval "$check" >/dev/null 2>&1; then
      info "$desc: done after $(fmt_secs $(( $(date +%s) - start )))"
      return 0
    fi
    if (( $(date +%s) - start > timeout )); then
      warn "timed out waiting for $desc"
      return 1
    fi
    [[ -n "$status" ]] && printf '    [%5s] %s\n' "$(fmt_secs $(( $(date +%s) - start )))" "$(eval "$status" 2>/dev/null | tr '\n' ' ')"
    sleep 10
  done
}

# --- "Bare metal" host pool ------------------------------------------------------
host_name() { printf '%s-%d' "$HOST_PREFIX" "$1"; }
# Number of hosts that have manifests (manifests/hosts/<prefix>-<i>/).
host_pool_size() { find "$MANIFESTS/hosts" -mindepth 1 -maxdepth 1 -type d -name "$HOST_PREFIX-*" | wc -l | tr -d ' '; }

# Lines of "<name> <provisioning-state> <consumer-or-dash>"
bmh_table() {
  kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.provisioning.state}{" "}{.spec.consumerRef.name}{"\n"}{end}' 2>/dev/null \
    | awk '{ print $1, ($2 == "" ? "-" : $2), ($3 == "" ? "-" : $3) }'
}
hosts_total()   { bmh_table | wc -l | tr -d ' '; }
hosts_free()    { bmh_table | awk '$2 == "available" && $3 == "-"' | wc -l | tr -d ' '; }
# registering/inspecting/preparing hosts will become free without any action
hosts_pending() { bmh_table | awk '$3 == "-" && $2 ~ /^(-|registering|inspecting|preparing|deprovisioning|powering off before delete)$/' | wc -l | tr -d ' '; }
bmh_summary()   { bmh_table | awk '{ s[$2]++ } END { for (k in s) printf "%s=%d ", k, s[k] }'; }

# Creates the PVC + KubeVirt VM + VirtualMachineBMC + BareMetalHost for host <i>
# from manifests/hosts/<prefix>-<i>/.
create_host() {
  local name; name=$(host_name "$1")
  local dir="$MANIFESTS/hosts/$name"
  [[ -d "$dir" ]] || die "no manifests for $name: the pool has $(host_pool_size) hosts (add $dir/ to grow it)"

  if kubectl -n "$NAMESPACE" get vm "$name" >/dev/null 2>&1; then
    info "$name already exists"
  else
    info "creating $name"
    kubectl apply -f "$dir/vm.yaml"
  fi
  kubectl -n "$NAMESPACE" wait --for=condition=ServiceReady --timeout=180s "virtualmachinebmc/$name-bmc" >/dev/null
  kubectl apply -f "$dir/bmh.yaml"
}

# ensure_hosts <n>: make sure at least n hosts exist (indices 0..n-1).
ensure_hosts() {
  local want=$1 i
  for (( i = 0; i < want; i++ )); do create_host "$i"; done
}

# ensure_free_hosts <n>: make sure n BMHs are available and unclaimed, adding
# hosts to the pool if needed, then wait for them to finish inspection.
ensure_free_hosts() {
  local want=$1 free pending i
  free=$(hosts_free); pending=$(hosts_pending)
  if (( free + pending < want )); then
    local add=$(( want - free - pending ))
    info "pool has $free free + $pending pending host(s); adding $add"
    i=0
    while (( add > 0 )); do
      if ! kubectl -n "$NAMESPACE" get vm "$(host_name "$i")" >/dev/null 2>&1; then
        create_host "$i"; add=$(( add - 1 ))
      fi
      i=$(( i + 1 ))
    done
  fi
  # registering -> inspecting -> available boots the IPA ramdisk over Redfish
  # virtual media on each new host: a few minutes with KVM.
  wait_until "$want free BareMetalHost(s)" 2400 "(( \$(hosts_free) >= $want ))" bmh_summary
}

# --- Workload cluster access -------------------------------------------------------
# The API VIP lives on baremetal-net, which is reachable from the kind node's
# root network namespace but not from your workstation, so workload-cluster
# kubectl calls run inside the kind node (which ships kubectl).
WL_KUBECONFIG_IN_NODE=/root/${CLUSTER_NAME}.kubeconfig

wl_sync_kubeconfig() {
  kubectl -n "$NAMESPACE" get secret "$CLUSTER_NAME-kubeconfig" -o jsonpath='{.data.value}' 2>/dev/null \
    | base64 -d > "$OUT/$CLUSTER_NAME.kubeconfig" || return 1
  [[ -s "$OUT/$CLUSTER_NAME.kubeconfig" ]] || return 1
  $CONTAINER_RUNTIME exec -i "$KIND_NODE" sh -c "cat > $WL_KUBECONFIG_IN_NODE" < "$OUT/$CLUSTER_NAME.kubeconfig"
}

wl() {
  $CONTAINER_RUNTIME exec "$KIND_NODE" kubectl --kubeconfig "$WL_KUBECONFIG_IN_NODE" --request-timeout="${WL_TIMEOUT:-5s}" "$@"
}

wl_ready_nodes() {
  wl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' '
}

# --- CAPI object status ------------------------------------------------------------
kcp_status() {
  kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" \
    -o jsonpath='replicas={.status.replicas} ready={.status.readyReplicas} upToDate={.status.upToDateReplicas} version={.spec.version}' 2>/dev/null
}
kcp_settled() { # kcp_settled <replicas> <version>
  local s; s=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" \
    -o jsonpath='{.status.replicas}/{.status.readyReplicas}/{.status.upToDateReplicas}/{.spec.version}' 2>/dev/null)
  [[ "$s" == "$1/$1/$1/$2" ]]
}
md_status() {
  kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" \
    -o jsonpath='replicas={.status.replicas} ready={.status.readyReplicas} upToDate={.status.upToDateReplicas} version={.spec.template.spec.version}' 2>/dev/null
}
md_settled() { # md_settled <replicas> <version>
  local s; s=$(kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" \
    -o jsonpath='{.status.replicas}/{.status.readyReplicas}/{.status.upToDateReplicas}/{.spec.template.spec.version}' 2>/dev/null)
  [[ "$s" == "$1/$1/$1/$2" ]]
}

# Resolves a workload node name to its BareMetalHost: CAPM3 labels each node
# with metal3.io/uuid=<BMH UID> (see kubeletExtraArgs in manifests/cluster/).
node_to_bmh() {
  local uuid
  uuid=$(wl get node "$1" -o jsonpath='{.metadata.labels.metal3\.io/uuid}')
  kubectl -n "$NAMESPACE" get bmh -o jsonpath="{range .items[?(@.metadata.uid==\"$uuid\")]}{.metadata.name}{end}"
}

require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "missing required tools: ${missing[*]}"
}

require_kind_context() {
  local ctx; ctx=$(kubectl config current-context 2>/dev/null || true)
  [[ "$ctx" == "kind-$KIND_CLUSTER_NAME" ]] \
    || die "kubectl context is '$ctx', expected 'kind-$KIND_CLUSTER_NAME' (create it with: kind create cluster --config kind-config.yaml)"
}
