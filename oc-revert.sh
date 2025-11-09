#!/usr/bin/env bash
set -euo pipefail

# oc-revert.sh
# Snapshot & revert:
# - Namespaces
# - OAuth config (oauth.config.openshift.io/cluster)
# - Self-provisioner binding (ClusterRole self-provisioner -> system:authenticated:oauth)
# - Secrets in openshift-config (new ones deleted on revert)
# - Project config reset to "default" (clears projectRequestTemplate)
# - Templates in openshift-config (new ones deleted on revert)
#
# Usage:
#   ./oc-revert.sh snapshot [--kubeconfig PATH]
#   ./oc-revert.sh revert   [--kubeconfig PATH] [--dry-run]

### Config & args ###
KUBECONFIG_PATH="./.kube/config"
ACTION="${1:-}"
DRY_RUN="false"

parse_args() {
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) KUBECONFIG_PATH="${2:?Missing value for --kubeconfig}"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift ;;
      *) shift ;;
    esac
  done
}
parse_args "$@"
export KUBECONFIG="$KUBECONFIG_PATH"

BASE_DIR=".oc-baseline"
NS_FILE="$BASE_DIR/namespaces.txt"
OAUTH_FILE="$BASE_DIR/oauth.yaml"
SECRETS_FILE="$BASE_DIR/openshift-config.secrets.txt"
TEMPLATES_FILE="$BASE_DIR/openshift-config.templates.txt"

SYSTEM_NS_REGEX='^(kube-|openshift-|openshift$|default$|redhat-operators$|openshift.*)'

### Helpers ###
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR ] $*" >&2; }

require_oc() {
  command -v oc >/dev/null 2>&1 || { err "oc not found in PATH"; exit 1; }
  oc whoami >/dev/null 2>&1 || { err "Not logged in or invalid KUBECONFIG: $KUBECONFIG"; exit 1; }
}
ensure_baseline_dir() { mkdir -p "$BASE_DIR"; }

### SNAPSHOT ###
take_snapshot() {
  require_oc
  ensure_baseline_dir

  info "Saving current namespaces -> $NS_FILE"
  oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort -u > "$NS_FILE"

  info "Saving OAuth config -> $OAUTH_FILE"
  if oc get oauth cluster >/dev/null 2>&1; then
    oc get oauth cluster -o yaml > "$OAUTH_FILE"
  else
    warn "No oauth/cluster found; writing placeholder."
    echo "# No oauth/cluster at snapshot time" > "$OAUTH_FILE"
  fi

  info "Saving Secret names from openshift-config -> $SECRETS_FILE"
  if oc get ns openshift-config >/dev/null 2>&1; then
    oc -n openshift-config get secret -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | sort -u > "$SECRETS_FILE"
  else
    : > "$SECRETS_FILE"
  fi

  info "Saving Template names from openshift-config -> $TEMPLATES_FILE"
  if oc get ns openshift-config >/dev/null 2>&1; then
    oc -n openshift-config get template -o name 2>/dev/null | sed 's@.*/@@' | sort -u > "$TEMPLATES_FILE" || : > "$TEMPLATES_FILE"
  else
    : > "$TEMPLATES_FILE"
  fi

  info "Snapshot complete. Files in $BASE_DIR"
}

### RBAC: ensure self-provisioner binding ###
ensure_self_provisioner_binding() {
  local binding="self-provisioners"
  local want_group="system:authenticated:oauth"
  local want_role="self-provisioner"

  if ! oc get clusterrolebinding "$binding" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "[DRY-RUN] Would create CRB '$binding' ($want_role -> $want_group)"
    else
      info "Restoring CRB '$binding' ($want_role -> $want_group)…"
      oc adm policy add-cluster-role-to-group "$want_role" "$want_group"
    fi
    return
  fi

  # Validate roleRef and subjects contain the group
  local roleRef subjects
  roleRef="$(oc get clusterrolebinding "$binding" -o jsonpath='{.roleRef.name}')"
  subjects="$(oc get clusterrolebinding "$binding" -o jsonpath='{range .subjects[*]}{.kind}:{.name}{"\n"}{end}')"

  if [[ "$roleRef" != "$want_role" ]] || ! echo "$subjects" | grep -q "^Group:$want_group$"; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "[DRY-RUN] Would (re)bind $want_role to group $want_group on CRB '$binding'"
    else
      info "Updating CRB '$binding' to include group $want_group and role $want_role…"
      oc adm policy add-cluster-role-to-group "$want_role" "$want_group"
    fi
  else
    info "CRB '$binding' already grants $want_role to $want_group."
  fi
}

### Namespaces: delete new since snapshot ###
delete_new_namespaces_since_snapshot() {
  [[ -f "$NS_FILE" ]] || { err "Missing $NS_FILE. Run snapshot first."; exit 1; }

  info "Finding namespaces created after snapshot…"
  mapfile -t baseline_ns < <(sort -u "$NS_FILE")
  mapfile -t current_ns  < <(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort -u)

  local tmp_b tmp_c; tmp_b="$(mktemp)"; tmp_c="$(mktemp)"
  printf "%s\n" "${baseline_ns[@]}" > "$tmp_b"
  printf "%s\n" "${current_ns[@]}"  > "$tmp_c"
  mapfile -t new_ns < <(comm -13 "$tmp_b" "$tmp_c" || true)
  rm -f "$tmp_b" "$tmp_c"

  [[ ${#new_ns[@]} -gt 0 ]] || { info "No new namespaces."; return; }

  info "New namespaces:"
  printf "  - %s\n" "${new_ns[@]}"

  local to_delete=()
  for ns in "${new_ns[@]}"; do
    if [[ "$ns" =~ $SYSTEM_NS_REGEX ]]; then
      warn "Skipping system namespace: $ns"
    else
      to_delete+=("$ns")
    fi
  done

  [[ ${#to_delete[@]} -gt 0 ]] || { info "Nothing eligible for deletion."; return; }

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would delete namespaces:"
    printf "  - %s\n" "${to_delete[@]}"
    return
  fi

  for ns in "${to_delete[@]}"; do
    info "Deleting ns: $ns"
    oc delete ns "$ns" --ignore-not-found=true
  done
  for ns in "${to_delete[@]}"; do
    oc wait ns/"$ns" --for=delete --timeout=180s >/dev/null 2>&1 || warn "$ns not fully deleted yet."
  done
}

### openshift-config: delete new Secrets ###
delete_new_openshift_config_secrets() {
  [[ -f "$SECRETS_FILE" ]] || { err "Missing $SECRETS_FILE. Run snapshot first."; exit 1; }
  oc get ns openshift-config >/dev/null 2>&1 || { warn "No openshift-config; skipping secrets."; return; }

  info "Finding new Secrets in openshift-config…"
  mapfile -t base < <(sort -u "$SECRETS_FILE")
  mapfile -t curr < <(oc -n openshift-config get secret -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort -u)

  local tb tc; tb="$(mktemp)"; tc="$(mktemp)"
  printf "%s\n" "${base[@]}" > "$tb"; printf "%s\n" "${curr[@]}" > "$tc"
  mapfile -t new_secs < <(comm -13 "$tb" "$tc" || true)
  rm -f "$tb" "$tc"

  [[ ${#new_secs[@]} -gt 0 ]] || { info "No new Secrets."; return; }

  info "New Secrets detected:"
  printf "  - %s\n" "${new_secs[@]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would delete above Secrets."
    return
  fi
  for s in "${new_secs[@]}"; do
    info "Deleting Secret: $s"
    oc -n openshift-config delete secret "$s" --ignore-not-found=true
  done
}

### Project config: reset to defaults ###
reset_project_config_to_default() {
  # Default = clear projectRequestTemplate (lets the platform use its built-in bootstrap)
  if ! oc get project.config.openshift.io cluster >/dev/null 2>&1; then
    warn "project.config.openshift.io/cluster not found; skipping project defaults."
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would reset project.config.openshift.io/cluster projectRequestTemplate to default (empty)."
    return
  fi

  info "Resetting project.config.openshift.io/cluster to defaults (clear projectRequestTemplate)…"
  oc patch project.config.openshift.io/cluster --type=merge -p '{"spec":{"projectRequestTemplate":{"name":""}}}' || \
    warn "Patch failed; attempting apply of minimal default manifest…" && \
cat <<'EOF' | oc apply -f - >/dev/null 2>&1 || true
apiVersion: config.openshift.io/v1
kind: Project
metadata:
  name: cluster
spec:
  projectRequestTemplate:
    name: ""
EOF
  info "Project config reset attempted."
}

### openshift-config: delete new Templates (project request bootstrap) ###
delete_new_openshift_config_templates() {
  [[ -f "$TEMPLATES_FILE" ]] || { err "Missing $TEMPLATES_FILE. Run snapshot first."; exit 1; }
  oc get ns openshift-config >/dev/null 2>&1 || { warn "No openshift-config; skipping templates."; return; }

  info "Finding new Templates in openshift-config…"
  mapfile -t base < <(sort -u "$TEMPLATES_FILE")
  mapfile -t curr < <(oc -n openshift-config get template -o name 2>/dev/null | sed 's@.*/@@' | sort -u || true)

  # If the cluster has no Template objects, nothing to do.
  [[ ${#curr[@]} -gt 0 ]] || { info "No Templates present."; return; }

  local tb tc; tb="$(mktemp)"; tc="$(mktemp)"
  printf "%s\n" "${base[@]}" > "$tb"; printf "%s\n" "${curr[@]}" > "$tc"
  mapfile -t new_tmpls < <(comm -13 "$tb" "$tc" || true)
  rm -f "$tb" "$tc"

  [[ ${#new_tmpls[@]} -gt 0 ]] || { info "No new Templates."; return; }

  info "New Templates detected in openshift-config:"
  printf "  - %s\n" "${new_tmpls[@]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would delete above Templates from openshift-config."
    return
  fi
  for t in "${new_tmpls[@]}"; do
    info "Deleting Template: $t"
    oc -n openshift-config delete template "$t" --ignore-not-found=true
  done
}

### OAuth restore ###
restore_oauth_from_baseline() {
  [[ -f "$OAUTH_FILE" ]] || { err "Missing $OAUTH_FILE. Run snapshot first."; exit 1; }
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would restore OAuth from $OAUTH_FILE"
    return
  fi
  if grep -q 'kind: OAuth' "$OAUTH_FILE" 2>/dev/null; then
    info "Restoring OAuth configuration from baseline…"
    oc apply -f "$OAUTH_FILE"
  else
    warn "Baseline OAuth file missing OAuth resource; skipping."
  fi
}

### REVERT orchestration ###
revert_changes() {
  require_oc
  ensure_self_provisioner_binding
  restore_oauth_from_baseline
  reset_project_config_to_default
  delete_new_namespaces_since_snapshot
  delete_new_openshift_config_secrets
  delete_new_openshift_config_templates
  info "Revert complete."
}

### Dispatch ###
case "$ACTION" in
  snapshot) take_snapshot ;;
  revert)   revert_changes ;;
  ""|help|-h|--help)
    cat <<EOF
Usage:
  $0 snapshot [--kubeconfig PATH]
  $0 revert   [--kubeconfig PATH] [--dry-run]

Snapshot stores:
  - Namespaces -> $NS_FILE
  - OAuth CR   -> $OAUTH_FILE
  - openshift-config Secret names   -> $SECRETS_FILE
  - openshift-config Template names -> $TEMPLATES_FILE

Revert does:
  - Ensure self-provisioner bound to system:authenticated:oauth
  - Restore OAuth from baseline
  - Reset Project config to defaults (clears projectRequestTemplate)
  - Delete namespaces created after snapshot (skips kube-/openshift-* and default)
  - Delete new Secrets in openshift-config since snapshot
  - Delete new Templates in openshift-config since snapshot
  - Use --dry-run to preview actions

Notes:
  - Uses KUBECONFIG at '$KUBECONFIG_PATH' by default (override with --kubeconfig)
  - Requires cluster-admin for full effect
EOF
    ;;
  *) err "Unknown action: $ACTION (use snapshot|revert)"; exit 1 ;;
esac
