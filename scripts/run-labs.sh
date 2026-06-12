#!/usr/bin/env bash
set -euo pipefail

mkdir -p evidence
LOG="evidence/lab3-lab4-run.log"
: > "$LOG"

run() {
  echo "" | tee -a "$LOG"
  echo "## $*" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
}

section() {
  echo "" | tee -a "$LOG"
  echo "============================================================" | tee -a "$LOG"
  echo "$1" | tee -a "$LOG"
  echo "============================================================" | tee -a "$LOG"
}

curl_retry() {
  local url="$1"
  local tries="${2:-20}"
  for i in $(seq 1 "$tries"); do
    if curl -fsS "$url" 2>&1 | tee -a "$LOG"; then
      return 0
    fi
    echo "curl retry $i/$tries for $url" | tee -a "$LOG"
    sleep 3
  done
  return 1
}

section "Environment"
run docker --version
run kubectl version --client=true
run minikube version

section "Start Minikube"
run minikube start --driver=docker --memory=4096 --cpus=2
run kubectl cluster-info
run kubectl get nodes -o wide

section "Lab 3 - Hello Minikube"
run kubectl create deployment hello-minikube --image=registry.k8s.io/echoserver:1.10
run kubectl expose deployment hello-minikube --type=NodePort --port=8080
run kubectl wait --for=condition=available --timeout=180s deployment/hello-minikube
HELLO_URL="$(minikube service hello-minikube --url)"
echo "hello-minikube URL: $HELLO_URL" | tee -a "$LOG"
curl -fsS "$HELLO_URL" | head -40 | tee -a "$LOG"
run kubectl get deployments,pods,services -o wide

section "Lab 3 - Kubernetes Basics: Deploy and Explore"
run kubectl create deployment kubernetes-bootcamp --image=gcr.io/google-samples/kubernetes-bootcamp:v1
run kubectl wait --for=condition=available --timeout=180s deployment/kubernetes-bootcamp
run kubectl get deployments
run kubectl get pods -o wide
BOOTCAMP_POD="$(kubectl get pods -l app=kubernetes-bootcamp -o jsonpath='{.items[0].metadata.name}')"
echo "Bootcamp pod: $BOOTCAMP_POD" | tee -a "$LOG"
run kubectl describe pod "$BOOTCAMP_POD"
run kubectl logs "$BOOTCAMP_POD"
run kubectl exec "$BOOTCAMP_POD" -- env

section "Lab 3 - Expose"
run kubectl expose deployment/kubernetes-bootcamp --type=NodePort --port 8080
run kubectl get services -o wide
BOOTCAMP_URL="$(minikube service kubernetes-bootcamp --url)"
echo "kubernetes-bootcamp URL: $BOOTCAMP_URL" | tee -a "$LOG"
curl_retry "$BOOTCAMP_URL"

section "Lab 3 - Scale"
run kubectl scale deployments/kubernetes-bootcamp --replicas=4
run kubectl wait --for=condition=available --timeout=180s deployment/kubernetes-bootcamp
run kubectl get deployments
run kubectl get pods -o wide
for i in 1 2 3 4; do curl_retry "$BOOTCAMP_URL" 10; done

section "Lab 3 - Update"
run kubectl scale deployments/kubernetes-bootcamp --replicas=2
run kubectl wait --for=condition=available --timeout=180s deployment/kubernetes-bootcamp
run kubectl set image deployments/kubernetes-bootcamp kubernetes-bootcamp=nginx:1.27-alpine
run kubectl rollout status deployments/kubernetes-bootcamp --timeout=300s
run kubectl describe deployments/kubernetes-bootcamp
run kubectl rollout undo deployments/kubernetes-bootcamp
run kubectl rollout status deployments/kubernetes-bootcamp --timeout=300s
run kubectl describe deployments/kubernetes-bootcamp

section "Lab 4 - Install Istio"
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.27.1 sh - 2>&1 | tee -a "$LOG"
export PATH="$PWD/istio-1.27.1/bin:$PATH"
run istioctl version --remote=false
run istioctl install --set profile=demo -y
run kubectl get pods -n istio-system -o wide
run kubectl label namespace default istio-injection=enabled --overwrite

section "Lab 4 - Gateway API CRDs"
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || {
  kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.3.0" | kubectl apply -f - 2>&1 | tee -a "$LOG"
}
run kubectl get crd gateways.gateway.networking.k8s.io

section "Lab 4 - Bookinfo"
run kubectl apply -f istio-1.27.1/samples/bookinfo/platform/kube/bookinfo.yaml
run kubectl wait --for=condition=available --timeout=300s deployment/productpage-v1
run kubectl wait --for=condition=available --timeout=300s deployment/details-v1
run kubectl wait --for=condition=available --timeout=300s deployment/ratings-v1
run kubectl wait --for=condition=available --timeout=300s deployment/reviews-v1
run kubectl wait --for=condition=available --timeout=300s deployment/reviews-v2
run kubectl wait --for=condition=available --timeout=300s deployment/reviews-v3
run kubectl get pods,services -o wide
run kubectl apply -f istio-1.27.1/samples/bookinfo/gateway-api/bookinfo-gateway.yaml
run kubectl wait --for=condition=programmed --timeout=180s gateway/bookinfo-gateway
run kubectl get gateway,httproute -o wide

section "Lab 4 - Access Bookinfo"
kubectl port-forward svc/productpage 9080:9080 --address 0.0.0.0 >> "$LOG" 2>&1 &
PF_PID=$!
sleep 8
curl -fsS http://127.0.0.1:9080/productpage -o evidence/bookinfo-productpage.html
echo "Bookinfo productpage title:" | tee -a "$LOG"
grep -o "<title>[^<]*</title>" evidence/bookinfo-productpage.html | tee -a "$LOG"
kill "$PF_PID"

section "Lab 4 - Dashboard Add-ons"
run kubectl apply -f istio-1.27.1/samples/addons
sleep 20
run kubectl get pods -n istio-system -o wide
run kubectl rollout status deployment/kiali -n istio-system --timeout=240s
run kubectl rollout status deployment/prometheus -n istio-system --timeout=240s
run kubectl get svc -n istio-system kiali prometheus grafana jaeger -o wide

section "Final State"
run kubectl get all -A
run istioctl proxy-status
echo "Experiment completed successfully." | tee -a "$LOG"
