#!/bin/bash
set -euo pipefail

TT_ROOT=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

source "$TT_ROOT/utils.sh"

namespace="${1:-train-evolution}"

if [ "$namespace" != "train-evolution" ]; then
  echo "Refusing to reset namespace '$namespace'. This repository only manages train-evolution." >&2
  exit 2
fi

kubectl delete -f deployment/kubernetes-manifests/quickstart-k8s/yamls -n "$namespace" --ignore-not-found=true

while IFS= read -r release; do
  if [ -n "$release" ]; then
    helm uninstall "$release" -n "$namespace"
  fi
done < <(helm list -q -n "$namespace" --filter '^ts-')

for release in "$rabbitmqRelease" "$nacosRelease" "$nacosDBRelease"; do
  if helm status "$release" -n "$namespace" >/dev/null 2>&1; then
    helm uninstall "$release" -n "$namespace"
  fi
done


kubectl delete -f deployment/kubernetes-manifests/skywalking -n "$namespace" --ignore-not-found=true
