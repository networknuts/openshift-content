#!/bin/bash

# Usage: ./deploy_apps.sh <image>
# Example: ./deploy_apps.sh registry.ocp4.example.com:8443/ubi8/httpd-24

# Exit on any error
set -e

# Validate input
if [ -z "$1" ]; then
  echo "Usage: $0 <image-name>"
  exit 1
fi

IMAGE="$1"

# Project: alpha
oc new-project alpha
oc new-app --name app1 --image "$IMAGE"
oc scale --replicas 2 deployment/app1
oc new-app --name app2 --image "$IMAGE"

# Project: beta
oc new-project beta
oc new-app --name app3 --image "$IMAGE"
oc scale --replicas 2 deployment/app3

# Project: gamma
oc new-project gamma
oc new-app --name app4 --image "$IMAGE"
oc scale --replicas 2 deployment/app4

# Project: omega
oc new-project omega
oc new-app --name app5 --image "$IMAGE"
oc new-app --name app6 --image "$IMAGE"

# Project: sigma
oc new-project sigma
oc new-app --name app7 --image "$IMAGE"
