#!/usr/bin/env bash
set -euo pipefail

# Requires: oc, jq
# Usage:
#   ./restart-failing-clusteroperators.sh               # restart only degraded/unavailable operators
#   ./restart-failing-clusteroperators.sh --all         # include Progressing=True as well
#   ./restart-failing-clusteroperators.sh --only authentication ingress  # target specific operators
#   ./restart-failing-clusteroperators.sh --dry-run     # show actions only

DRY_RUN="false"
ONLY=()
INCLUDE_PROGRESSING="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift;;
    --all) INCLUDE_PROGRESSING="true"; shift;;
    --only) shift; while [[ $# -gt 0 && "$1" != --* ]]; do ONLY+=("$1"); shift; done;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

command -v oc >/dev/null || { echo "oc not found in PATH"; exit 1; }
command -v jq >/dev/null || { echo "jq not found in PATH"; exit 1; }

echo "🔎 Collecting ClusterOperator status..."
CO_JSON="$(oc get clusteroperators -o json)"

# Select failing operators
JQ_FILTER='.items[]
  | {name: .metadata.name,
     available: (.status.conditions[] | select(.type=="Available") | .status),
     degraded: (.status.conditions[] | select(.type=="Degraded") | .status),
     progressing: (.status.conditions[] | select(.type=="Progressing") | .status),
     related: (.status.relatedObjects // [])
    }'
FAILED_FILTER='
  select(
    (.available != "True")
    or (.degraded == "True")
    '"${INCLUDE_PROGRESSING}"' and (.progressing == "True")
  )'

# Restrict to --only if provided
if (( ${#ONLY[@]} )); then
  NAME_FILTER="select([\""$(printf '%s","' "${ONLY[@]}" | sed 's/,"$//')"\" ] | index(.name))"
else
  NAME_FILTER="."
fi

mapfile -t TARGETS < <(echo "$CO_JSON" \
  | jq -r "$JQ_FILTER | $NAME_FILTER | $FAILED_FILTER | .name" 2>/dev/null)

if (( ${#TARGETS[@]} == 0 )); then
  echo "✅ No matching failing ClusterOperators found."
  exit 0
fi

echo "🧩 Targeting operators: ${TARGETS[*]}"
echo

# Build a unique list of referenced workloads to restart
declare -A WORK
for co in "${TARGETS[@]}"; do
  echo "➡️  Inspecting related objects for operator: $co"
  RELATED_JSON="$(echo "$CO_JSON" | jq -r ".items[] | select(.metadata.name==\"$co\") | .status.relatedObjects // []")"

  # Extract (kind,namespace,name) records we know how to restart
  while IFS=$'\t' read -r kind ns name; do
    key="${kind}/${ns}/${name}"
    WORK["$key"]=1
  done < <(echo "$RELATED_JSON" \
      | jq -r '.[] | select(.kind | IN("Deployment","DaemonSet","StatefulSet","Pod")) | [.kind, (.namespace//""), .name] | @tsv')
done

if (( ${#WORK[@]} == 0 )); then
  echo "⚠️  No restartable related objects found via status.relatedObjects."
  echo "   You may need to manually restart pods in the corresponding openshift-* namespaces."
  exit 1
fi

echo "🛠  Planned actions:"
for key in "${!WORK[@]}"; do
  IFS='/' read -r kind ns name <<< "$key"
  case "$kind" in
    Deployment)  echo "  - rollout restart deployment/${name} -n ${ns}";;
    DaemonSet)   echo "  - rollout restart ds/${name} -n ${ns}";;
    StatefulSet) echo "  - rollout restart sts/${name} -n ${ns}";;
    Pod)         echo "  - delete pod/${name} -n ${ns}";;
  esac
done
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "🧪 Dry run: no changes made."
  exit 0
fi

echo "🚀 Executing restarts..."
for key in "${!WORK[@]}"; do
  IFS='/' read -r kind ns name <<< "$key"
  case "$kind" in
    Deployment)
      oc rollout restart "deployment/${name}" -n "${ns}" || true
      ;;
    DaemonSet)
      oc rollout restart "ds/${name}" -n "${ns}" || true
      ;;
    StatefulSet)
      oc rollout restart "sts/${name}" -n "${ns}" || true
      ;;
    Pod)
      oc delete "pod/${name}" -n "${ns}" --grace-period=0 --force || true
      ;;
  esac
done

echo
echo "⏳ Waiting for operators to recover (120s)..."
sleep 120

echo "📊 Current ClusterOperator status:"
oc get clusteroperators
echo
echo "🔁 If any remain Degraded/Unavailable, check details with:"
echo "   oc describe clusteroperator <name>"
