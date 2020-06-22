#!/bin/bash

set -e
set -o pipefail

KUBECTL="${KUBECTL:-./kubectl}"
NAMESPACE="observatorium"
OS_TYPE=$(echo `uname -s` | tr '[:upper:]' '[:lower:]')

kind() {
    curl -LO https://storage.googleapis.com/kubernetes-release/release/"$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)"/bin/$OS_TYPE/amd64/kubectl
    curl -Lo kind https://github.com/kubernetes-sigs/kind/releases/download/v0.7.0/kind-$OS_TYPE-amd64
    chmod +x kind kubectl
    ./kind create cluster
}

deploy() {
    # $KUBECTL apply -f https://raw.githubusercontent.com/coreos/kube-prometheus/master/manifests/setup/prometheus-operator-0servicemonitorCustomResourceDefinition.yaml
    # $KUBECTL apply -f https://raw.githubusercontent.com/coreos/kube-prometheus/master/manifests/setup/prometheus-operator-0prometheusruleCustomResourceDefinition.yaml
    # $KUBECTL create ns dex || true
    # $KUBECTL create ns observatorium-minio || true
    # $KUBECTL create ns observatorium || true
    $KUBECTL apply --namespace $NAMESPACE -f environments/dev/manifests/
}

wait_for_cr() {
    observatorium_cr_status=""
    target_status="Finished"
    timeout=$true
    interval=0
    intervals=600
    while [ $interval -ne $intervals ]; do
      echo "Waiting for" $1 "currentStatus="$observatorium_cr_status
      observatorium_cr_status=$($KUBECTL -n observatorium get observatoria.core.observatorium.io $1 -o=jsonpath='{.status.conditions[*].currentStatus}')
      if [ "$observatorium_cr_status" = "$target_status" ]; then
        echo $1 CR status is now: $observatorium_cr_status
	    timeout=$false
	    break
	  fi
	  sleep 5
	  interval=$((interval+5))
    done

    if [ $timeout ]; then
      echo "Timeout waiting for" $1 "CR status to be " $target_status
      exit 1
    fi
}

deploy_operator() {
    docker build -t quay.io/observatorium/observatorium-operator:latest .
    ./kind load docker-image quay.io/observatorium/observatorium-operator:latest
    $KUBECTL apply -f https://raw.githubusercontent.com/coreos/kube-prometheus/master/manifests/setup/prometheus-operator-0servicemonitorCustomResourceDefinition.yaml
    $KUBECTL apply -f https://raw.githubusercontent.com/coreos/kube-prometheus/master/manifests/setup/prometheus-operator-0prometheusruleCustomResourceDefinition.yaml
    $KUBECTL create ns dex || true
    $KUBECTL create ns observatorium-minio || true
    $KUBECTL create ns observatorium || true
    $KUBECTL apply -f environments/dev/manifests/minio-secret.yaml
    $KUBECTL apply -f environments/dev/manifests/minio-pvc.yaml
    $KUBECTL apply -f environments/dev/manifests/minio-deployment.yaml
    $KUBECTL apply -f environments/dev/manifests/minio-service.yaml
    $KUBECTL apply -f environments/dev/manifests/dex-secret.yaml
    $KUBECTL apply -f environments/dev/manifests/dex-pvc.yaml
    $KUBECTL apply -f environments/dev/manifests/dex-deployment.yaml
    $KUBECTL apply -f environments/dev/manifests/dex-service.yaml
    $KUBECTL apply -f operator/manifests/crds
    $KUBECTL apply -f operator/manifests/
    $KUBECTL apply -n observatorium -f example/manifests
    wait_for_cr observatorium-xyz
}

delete_cr() {
    $KUBECTL delete -n observatorium -f example/manifests
    target_count="0"
    timeout=$true
    interval=0
    intervals=600
    while [ $interval -ne $intervals ]; do
      echo "Waiting for cleaning"
      count=$($KUBECTL -n observatorium get all | wc -l)
      if [ "$count" = "$target_count" ]; then
        echo NS count is now: $count
	    timeout=$false
	    break
	  fi
	  sleep 5
	  interval=$((interval+5))
    done

    if [ $timeout ]; then
      echo "Timeout waiting for namespace to be empty"
      exit 1
    fi
}

run_test() {
    $KUBECTL wait --for=condition=available --timeout=10m -n observatorium-minio deploy/minio || ($KUBECTL get pods --all-namespaces && exit 1)
    $KUBECTL wait --for=condition=available --timeout=10m -n observatorium deploy/observatorium-xyz-thanos-query || ($KUBECTL get pods --all-namespaces && exit 1)

    $KUBECTL apply -f tests/manifests/observatorium-up.yaml

    sleep 5

    # This should wait for ~2min for the job to finish.
    $KUBECTL wait --for=condition=complete --timeout=5m -n default job/observatorium-up || ($KUBECTL get pods --all-namespaces && exit 1)
}

case $1 in
kind)
    kind
    ;;

deploy)
    deploy
    ;;

test)
    run_test
    ;;

deploy-operator)
    deploy_operator
    ;;

delete-cr)
    delete_cr
    ;;

*)
    echo "usage: $(basename "$0") { kind | deploy | test | deploy-operator | delete-cr}"
    ;;
esac
