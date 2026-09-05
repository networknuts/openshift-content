from pathlib import Path

script = r'''#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenShift LDAP Demo - 389 Directory Server
#
# Creates:
#   - Namespace
#   - ServiceAccount
#   - anyuid SCC grant
#   - Directory Manager Secret
#   - LDAP Deployment
#   - LDAP ClusterIP Service
#   - LDAP suffix / directory tree
#   - Demo LDAP users
#   - LDAP search and authentication verification
#
# Requirements:
#   - oc CLI
#   - Logged in to OpenShift
#   - cluster-admin privileges (required for SCC grant)
#
# NOTE:
#   This is intentionally a disposable training/demo setup.
#   LDAP data is stored in emptyDir, so deleting/recreating the pod loses the data.
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

NAMESPACE="${NAMESPACE:-ldap-demo}"
APP_NAME="${APP_NAME:-ldap}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-ldap-server}"

LDAP_IMAGE="${LDAP_IMAGE:-quay.io/389ds/dirsrv:c9s}"
LDAP_CLIENT_IMAGE="${LDAP_CLIENT_IMAGE:-quay.io/389ds/clients:latest}"

DM_PASSWORD="${DM_PASSWORD:-redhat123}"

BASE_DN="${BASE_DN:-dc=example,dc=com}"
PEOPLE_DN="${PEOPLE_DN:-ou=people,${BASE_DN}}"
BACKEND_NAME="${BACKEND_NAME:-userroot}"

LDAP_CONTAINER_PORT=3389
LDAP_SERVICE_PORT=389

SERVICE_FQDN="${APP_NAME}.${NAMESPACE}.svc.cluster.local"

# Demo users
STUDENT1_PASSWORD="${STUDENT1_PASSWORD:-redhat}"
STUDENT2_PASSWORD="${STUDENT2_PASSWORD:-redhat}"
ADMIN1_PASSWORD="${ADMIN1_PASSWORD:-redhat}"

# Set to false if you do not want to create the temporary LDAP client pod.
VERIFY_VIA_SERVICE="${VERIFY_VIA_SERVICE:-true}"


# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

info() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

ok() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

command -v oc >/dev/null 2>&1 || die "oc CLI was not found in PATH."
oc whoami >/dev/null 2>&1 || die "You are not logged in to an OpenShift cluster."


# ------------------------------------------------------------------------------
# 1. Namespace
# ------------------------------------------------------------------------------

info "Creating namespace: ${NAMESPACE}"

if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    ok "Namespace ${NAMESPACE} already exists."
else
    oc new-project "${NAMESPACE}" >/dev/null
    ok "Namespace ${NAMESPACE} created."
fi


# ------------------------------------------------------------------------------
# 2. ServiceAccount
# ------------------------------------------------------------------------------

info "Creating ServiceAccount: ${SERVICE_ACCOUNT}"

oc create serviceaccount "${SERVICE_ACCOUNT}" \
    -n "${NAMESPACE}" \
    --dry-run=client \
    -o yaml | oc apply -f - >/dev/null

ok "ServiceAccount ${SERVICE_ACCOUNT} is present."


# ------------------------------------------------------------------------------
# 3. SCC
# ------------------------------------------------------------------------------

info "Granting anyuid SCC to ${SERVICE_ACCOUNT}"

if ! oc adm policy add-scc-to-user anyuid \
    -z "${SERVICE_ACCOUNT}" \
    -n "${NAMESPACE}" >/dev/null; then
    die "Unable to grant anyuid SCC. Run this script as a cluster-admin."
fi

ok "ServiceAccount can use the anyuid SCC."


# ------------------------------------------------------------------------------
# 4. Directory Manager password Secret
# ------------------------------------------------------------------------------

info "Creating LDAP Directory Manager Secret"

oc create secret generic ldap-dm-password \
    -n "${NAMESPACE}" \
    --from-literal=dm-password="${DM_PASSWORD}" \
    --dry-run=client \
    -o yaml | oc apply -f - >/dev/null

ok "Secret ldap-dm-password is present."


# ------------------------------------------------------------------------------
# 5. Deployment + Service
# ------------------------------------------------------------------------------

info "Deploying 389 Directory Server"

cat <<EOF | oc apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1

  # Recreate is suitable for this single-instance training deployment.
  strategy:
    type: Recreate

  selector:
    matchLabels:
      app: ${APP_NAME}

  template:
    metadata:
      labels:
        app: ${APP_NAME}

    spec:
      serviceAccountName: ${SERVICE_ACCOUNT}

      securityContext:
        fsGroup: 389

      containers:
      - name: ldap
        image: ${LDAP_IMAGE}
        imagePullPolicy: IfNotPresent

        env:
        - name: DS_DM_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ldap-dm-password
              key: dm-password

        ports:
        - name: ldap
          containerPort: ${LDAP_CONTAINER_PORT}
          protocol: TCP

        securityContext:
          runAsUser: 389
          runAsGroup: 389
          runAsNonRoot: true
          allowPrivilegeEscalation: false

        readinessProbe:
          tcpSocket:
            port: ldap
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 12

        livenessProbe:
          tcpSocket:
            port: ldap
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 6

        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi

        volumeMounts:
        - name: ldap-data
          mountPath: /data

      volumes:
      - name: ldap-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP

  selector:
    app: ${APP_NAME}

  ports:
  - name: ldap
    protocol: TCP
    port: ${LDAP_SERVICE_PORT}
    targetPort: ${LDAP_CONTAINER_PORT}
EOF

ok "Deployment and Service applied."


# ------------------------------------------------------------------------------
# 6. Wait for LDAP
# ------------------------------------------------------------------------------

info "Waiting for LDAP pod to become Ready"

if ! oc rollout status deployment/"${APP_NAME}" \
    -n "${NAMESPACE}" \
    --timeout=180s; then

    echo
    warn "Deployment did not become Ready. Pod status:"
    oc get pods -n "${NAMESPACE}" -l app="${APP_NAME}" -o wide || true

    echo
    warn "Recent logs:"
    oc logs -n "${NAMESPACE}" deployment/"${APP_NAME}" --tail=100 || true

    exit 1
fi

POD="$(
    oc get pod \
        -n "${NAMESPACE}" \
        -l app="${APP_NAME}" \
        -o jsonpath='{.items[0].metadata.name}'
)"

ok "LDAP pod is ${POD}"


# ------------------------------------------------------------------------------
# 7. Wait for LDAP listener
# ------------------------------------------------------------------------------

info "Waiting for LDAP listener on port ${LDAP_CONTAINER_PORT}"

for attempt in $(seq 1 30); do
    if oc exec -n "${NAMESPACE}" "${POD}" -- \
        ldapsearch \
        -xLLL \
        -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
        -b "" \
        -s base \
        dn >/dev/null 2>&1; then

        ok "LDAP server is accepting connections."
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        die "LDAP did not become reachable."
    fi

    sleep 2
done


# ------------------------------------------------------------------------------
# 8. Create LDAP suffix / backend
# ------------------------------------------------------------------------------

info "Ensuring LDAP suffix exists: ${BASE_DN}"

if oc exec -n "${NAMESPACE}" "${POD}" -- \
    ldapsearch \
    -xLLL \
    -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
    -D "cn=Directory Manager" \
    -w "${DM_PASSWORD}" \
    -b "${BASE_DN}" \
    -s base \
    dn >/dev/null 2>&1; then

    ok "LDAP suffix ${BASE_DN} already exists."

else
    oc exec -n "${NAMESPACE}" "${POD}" -- \
        dsconf localhost backend create \
        --suffix "${BASE_DN}" \
        --be-name "${BACKEND_NAME}" \
        --create-suffix

    ok "Created backend ${BACKEND_NAME} with suffix ${BASE_DN}."
fi


# ------------------------------------------------------------------------------
# 9. Create ou=people
# ------------------------------------------------------------------------------

info "Ensuring LDAP people OU exists: ${PEOPLE_DN}"

if oc exec -n "${NAMESPACE}" "${POD}" -- \
    ldapsearch \
    -xLLL \
    -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
    -D "cn=Directory Manager" \
    -w "${DM_PASSWORD}" \
    -b "${PEOPLE_DN}" \
    -s base \
    dn >/dev/null 2>&1; then

    ok "${PEOPLE_DN} already exists."

else
    oc exec -i -n "${NAMESPACE}" "${POD}" -- \
        ldapadd \
        -x \
        -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
        -D "cn=Directory Manager" \
        -w "${DM_PASSWORD}" <<EOF
dn: ${PEOPLE_DN}
objectClass: top
objectClass: organizationalUnit
ou: people
EOF

    ok "Created ${PEOPLE_DN}."
fi


# ------------------------------------------------------------------------------
# 10. Create LDAP users
# ------------------------------------------------------------------------------

ensure_user() {
    local uid="$1"
    local cn="$2"
    local sn="$3"
    local email="$4"
    local password="$5"

    local user_dn="uid=${uid},${PEOPLE_DN}"

    info "Ensuring LDAP user exists: ${uid}"

    if oc exec -n "${NAMESPACE}" "${POD}" -- \
        ldapsearch \
        -xLLL \
        -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
        -D "cn=Directory Manager" \
        -w "${DM_PASSWORD}" \
        -b "${PEOPLE_DN}" \
        -s one \
        "(uid=${uid})" \
        dn 2>/dev/null | grep -q "^dn: ${user_dn}$"; then

        ok "LDAP user ${uid} already exists."

    else
        oc exec -i -n "${NAMESPACE}" "${POD}" -- \
            ldapadd \
            -x \
            -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
            -D "cn=Directory Manager" \
            -w "${DM_PASSWORD}" <<EOF
dn: ${user_dn}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: ${uid}
cn: ${cn}
sn: ${sn}
displayName: ${cn}
mail: ${email}
userPassword: ${password}
EOF

        ok "Created LDAP user ${uid}."
    fi
}


ensure_user \
    "student1" \
    "Student One" \
    "One" \
    "student1@example.com" \
    "${STUDENT1_PASSWORD}"

ensure_user \
    "student2" \
    "Student Two" \
    "Two" \
    "student2@example.com" \
    "${STUDENT2_PASSWORD}"

ensure_user \
    "admin1" \
    "Admin One" \
    "One" \
    "admin1@example.com" \
    "${ADMIN1_PASSWORD}"


# ------------------------------------------------------------------------------
# 11. Verify directory search
# ------------------------------------------------------------------------------

info "Verification 1/3 - Searching LDAP users"

oc exec -n "${NAMESPACE}" "${POD}" -- \
    ldapsearch \
    -xLLL \
    -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
    -D "cn=Directory Manager" \
    -w "${DM_PASSWORD}" \
    -b "${PEOPLE_DN}" \
    "(objectClass=inetOrgPerson)" \
    uid cn mail

ok "LDAP directory search succeeded."


# ------------------------------------------------------------------------------
# 12. Verify user authentication
# ------------------------------------------------------------------------------

verify_bind() {
    local uid="$1"
    local password="$2"

    local user_dn="uid=${uid},${PEOPLE_DN}"

    info "Testing LDAP bind for ${uid}"

    local result

    result="$(
        oc exec -n "${NAMESPACE}" "${POD}" -- \
            ldapwhoami \
            -x \
            -H "ldap://127.0.0.1:${LDAP_CONTAINER_PORT}" \
            -D "${user_dn}" \
            -w "${password}"
    )"

    echo "${result}"

    if echo "${result}" | grep -qi "^dn: *${user_dn}$"; then
        ok "${uid} authentication succeeded."
    else
        die "${uid} authentication failed."
    fi
}


verify_bind "student1" "${STUDENT1_PASSWORD}"
verify_bind "student2" "${STUDENT2_PASSWORD}"
verify_bind "admin1" "${ADMIN1_PASSWORD}"


# ------------------------------------------------------------------------------
# 13. Verify ClusterIP Service + cluster DNS
# ------------------------------------------------------------------------------

if [[ "${VERIFY_VIA_SERVICE}" == "true" ]]; then

    info "Verification 3/3 - Testing LDAP through the OpenShift Service"

    VERIFY_POD="ldap-verify-$RANDOM"

    oc run "${VERIFY_POD}" \
        -n "${NAMESPACE}" \
        --rm \
        -i \
        --restart=Never \
        --image="${LDAP_CLIENT_IMAGE}" \
        --command -- \
        ldapwhoami \
        -x \
        -H "ldap://${SERVICE_FQDN}:${LDAP_SERVICE_PORT}" \
        -D "uid=student1,${PEOPLE_DN}" \
        -w "${STUDENT1_PASSWORD}"

    ok "ClusterIP Service and cluster DNS verification succeeded."

else
    warn "Service verification skipped because VERIFY_VIA_SERVICE=${VERIFY_VIA_SERVICE}."
fi


# ------------------------------------------------------------------------------
# 14. Final status
# ------------------------------------------------------------------------------

echo
echo "=============================================================================="
echo " LDAP DEMO READY"
echo "=============================================================================="
echo
echo "Namespace:"
echo "  ${NAMESPACE}"
echo
echo "Pod:"
echo "  ${POD}"
echo
echo "LDAP Service:"
echo "  ldap://${SERVICE_FQDN}:${LDAP_SERVICE_PORT}"
echo
echo "Base DN:"
echo "  ${BASE_DN}"
echo
echo "People DN:"
echo "  ${PEOPLE_DN}"
echo
echo "Directory Manager:"
echo "  cn=Directory Manager"
echo
echo "Demo users:"
echo "  student1  / ${STUDENT1_PASSWORD}"
echo "  student2  / ${STUDENT2_PASSWORD}"
echo "  admin1    / ${ADMIN1_PASSWORD}"
echo
echo "OpenShift LDAP IdP URL:"
echo "  ldap://${SERVICE_FQDN}:${LDAP_SERVICE_PORT}/${PEOPLE_DN}?uid?sub?(objectClass=inetOrgPerson)"
echo
echo "Useful checks:"
echo "  oc get all -n ${NAMESPACE}"
echo "  oc logs -n ${NAMESPACE} deployment/${APP_NAME}"
echo
echo "=============================================================================="
'''

path = Path("/mnt/data/setup-openshift-ldap.sh")
path.write_text(script)
path.chmod(0o755)

print(f"Created: {path}")
print(f"Lines: {len(script.splitlines())}")
print("Executable mode set.")
