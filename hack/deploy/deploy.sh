#!/bin/bash
set -euo pipefail

TT_ROOT=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

source "$TT_ROOT/utils.sh"



namespace="${1:-train-evolution}"
args="${2:-}"
imageRepository="${3:-codewisdom}"
imageTag="${4:-log-evolution-v1}"

if [ "$namespace" != "train-evolution" ]; then
  echo "Refusing to deploy the evolution build to namespace '$namespace'. Use train-evolution." >&2
  exit 2
fi

if [[ -z "$imageRepository" || -z "$imageTag" || "$imageTag" == "latest" || "$imageRepository" == *"|"* || "$imageRepository" == *"&"* || "$imageTag" == *"|"* || "$imageTag" == *"&"* ]]; then
  echo "Image repository and tag must be non-empty Docker references without '|' or '&'; the evolution tag cannot be 'latest'." >&2
  exit 2
fi

kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"

argNone=1
argDB=0
argMonitoring=0
argTracing=0
argAll=0

function quick_start {
  echo "quick start"
  deploy_infrastructures "$namespace"
  deploy_tt_mysql_all_in_one "$namespace"
  deploy_tt_secret "$namespace"
  deploy_tt_svc "$namespace"
  deploy_tt_dp "$namespace" "$imageRepository" "$imageTag"
}

function deploy_all {
  deploy_infrastructures "$namespace"
  deploy_tt_mysql_each_service "$namespace"
  deploy_tt_secret "$namespace"
  deploy_tt_svc "$namespace"
  deploy_tt_dp_sw "$namespace" "$imageRepository" "$imageTag"
  deploy_tracing "$namespace"
  deploy_monitoring
}


function deploy {
    if [ $argNone == 1 ]; then
      quick_start
      exit $?
    fi

    if [ $argAll == 1 ]; then
      deploy_all
      exit $?
    fi

    deploy_infrastructures "$namespace"

    if [ $argDB == 1 ]; then
      deploy_tt_mysql_each_service "$namespace"
    else
      deploy_tt_mysql_all_in_one "$namespace"
    fi

    deploy_tt_secret "$namespace"
    deploy_tt_svc "$namespace"

    if [ $argTracing == 1 ]; then
      deploy_tt_dp_sw "$namespace" "$imageRepository" "$imageTag"
      deploy_tracing "$namespace"
    else
      deploy_tt_dp "$namespace" "$imageRepository" "$imageTag"
    fi

    if [ $argMonitoring == 1 ]; then
      deploy_monitoring
    fi
}

#deploy
function parse_args {
    echo "Parse DeployArgs"
    for arg in $args
    do
      echo $arg
      case $arg in
      "--all")
        argAll=1
        ;;
      "--independent-db")
        argDB=1
        ;;
      "--with-monitoring")
        argMonitoring=1
        ;;
      "--with-tracing")
        argTracing=1
        ;;
      esac
    done
}

echo "Deploying evolution images $imageRepository/*:$imageTag to namespace $namespace"
if [ -n "$args" ]; then
  argNone=0
  parse_args
fi
deploy
