#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
load_env
require_cmd helm oc
require_env KUBECONFIG RHEM_CHART_VERSION

helm repo add openshift-charts https://charts.openshift.io 2>/dev/null || true
helm repo update openshift-charts

oc create namespace flightctl --dry-run=client -o yaml | oc apply -f -
oc label namespace flightctl io.flightctl/instance=flightctl --overwrite

helm upgrade --install flightctl openshift-charts/redhat-rhem \
  --version "$RHEM_CHART_VERSION" \
  --namespace flightctl \
  --values "$ROOT/hub/rhem-values.yaml" \
  --wait --timeout 20m

oc -n flightctl get pods,route
echo "API:  $FLIGHTCTL_API"
echo "Agent:$FLIGHTCTL_AGENT_API"
