# Helium 

To quickly start, run

```sh
./setup.sh
```

If you need to setup step by step, follow the steps below.

## setup helm

```sh
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm repo add cilium https://helm.cilium.io/
helm repo add yugabytedb https://charts.yugabyte.com
helm repo add bitnami https://charts.bitnami.com/bitnami
```

## deploy kind clusters

```sh
sudo su #cilium does not work with rootless containers
setenforce 0
kind create cluster -n cluster1 --config ./kind-config/config-cluster1.yaml & 
kind create cluster -n cluster2 --config ./kind-config/config-cluster2.yaml &
kind create cluster -n cluster3 --config ./kind-config/config-cluster3.yaml &
wait
```

## deploy cert-manager

```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
done
```

## install cilium -- step 1

```sh
for cluster in cluster1 cluster2 cluster3; do
  cluster=${cluster} ordinal=${cluster: -1} envsubst < ./cilium/values1.yaml > /tmp/${cluster}-values.yaml
  helm --kube-context kind-${cluster} upgrade -i cilium cilium/cilium --version "1.16.0-pre.0" --namespace kube-system -f /tmp/${cluster}-values.yaml 
done
```  

wait for all the pods to be up

```sh
kubectl --context kind-cluster1 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster2 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster3 wait pod --all --for=condition=Ready -A --timeout=600s &
wait
```

## deploy cert-manager

this sort of hack is to share the CA across clusters

```sh
kubectl --context kind-cluster1 apply -f ./cert-manager/issuer-cluster1.yaml -n cert-manager
sleep 1
kubectl --context kind-cluster1 get secret root-secret -n cert-manager -o yaml > /tmp/root-secret.yaml
```


```sh
for cluster in cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f /tmp/root-secret.yaml
  kubectl --context kind-${cluster} apply -f ./cert-manager/issuer-others.yaml -n cert-manager
done
```

## deploy lb configuration

inspect kind network

```sh
podman network inspect -f '{{range .Subnets}}{{if eq (len .Subnet.IP) 4}}{{.Subnet}}{{end}}{{end}}' kind
10.89.0.0/24
```

carve three non overlapping subnets out of that CIDR starting from the end for the three clusters. /29 would give us 8 IPs , which is plenty, in this case.

```sh
export cidr_cluster1="10.89.0.224/29"
export cidr_cluster2="10.89.0.232/29"
export cidr_cluster3="10.89.0.240/29"
for cluster in cluster1 cluster2 cluster3; do
  vcidr=cidr_${cluster}
  cidr=${!vcidr} envsubst < ./cilium/ippool.yaml | kubectl --context kind-${cluster} apply -f -
done
```

patch core-dns to have headless services resolve

```sh
export cluster1_coredns_ip="10.89.0.225"
export cluster2_coredns_ip="10.89.0.233"
export cluster3_coredns_ip="10.89.0.241"
declare -A coredns_ips
coredns_ips["cluster1"]="10.89.0.225"
coredns_ips["cluster2"]="10.89.0.233"
coredns_ips["cluster3"]="10.89.0.241"
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} patch deployment coredns -n kube-system -p '{"spec":{"replicas": 1,"template":{"spec":{"containers": [{"name":"coredns","image":"quay.io/raffaelespazzoli/coredns:arm64-gathersrv-root", "imagePullPolicy": "Always", "resources": {"limits":{"memory":"512Mi"}}}]}}}}'
  envsubst < ./core-dns/corefile-configmap-${cluster}.yaml | kubectl --context kind-${cluster} apply -f -
  coredns_ip=${coredns_ips[${cluster}]} envsubst < ./core-dns/coredns-service.yaml | kubectl --context kind-${cluster} apply -f -
done
```

rollout new coredns

```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} rollout restart deployment/coredns -n kube-system
done
```

## install cilium step2

```sh
declare -A cluster_ips
export cluster1_ip="10.89.0.224"
export cluster2_ip="10.89.0.232"
export cluster3_ip="10.89.0.240"
cluster_ips["cluster1"]="10.89.0.224"
cluster_ips["cluster2"]="10.89.0.232"
cluster_ips["cluster3"]="10.89.0.240"
for cluster in cluster1 cluster2 cluster3; do
  cluster=${cluster} ordinal=${cluster: -1} apiserver_ip=${cluster_ips[${cluster}]}  envsubst < ./cilium/values2.yaml > /tmp/${cluster}-values.yaml
  helm --kube-context kind-${cluster} upgrade -i cilium cilium/cilium --version "1.16.0-pre.0" --namespace kube-system -f /tmp/${cluster}-values.yaml
done
```   

wait for all the pods to be up

```sh
kubectl --context kind-cluster1 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster2 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster3 wait pod --all --for=condition=Ready -A --timeout=600s &
wait
```

verify that clusters are successfully connected:

```sh
cilium status --context kind-cluster1
cilium status --context kind-cluster2
cilium status --context kind-cluster3
cilium clustermesh status --context kind-cluster1
cilium clustermesh status --context kind-cluster2
cilium clustermesh status --context kind-cluster3
```

## create h2 namespace

```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} create namespace h2
done
```

## Deploy h2 shared etcd and kcp

<!-- api-server
```sh
for cluster in cluster1 cluster2 cluster3; do
  cluster=${cluster} envsubst < ./shared-etcd/etcd-deployment.yaml | kubectl --context kind-${cluster} apply -f - -n h2
  kubectl --context kind-${cluster} apply -f ./shared-etcd/api-server-deployment.yaml -n h2 
done 
``` -->

kcp

```sh
declare -A kcp_ips
kcp_ips["cluster1"]="10.89.0.227"
kcp_ips["cluster2"]="10.89.0.235"
kcp_ips["cluster3"]="10.89.0.243"
for cluster in cluster1 cluster2 cluster3; do
  cluster=${cluster} envsubst < ./shared-etcd/etcd-deployment.yaml | kubectl --context kind-${cluster} apply -f - -n h2
  kcp_ip=${kcp_ips[${cluster}]} cluster=${cluster}  envsubst < ./kcp/values.yaml > /tmp/values.yaml
  helm --kube-context kind-${cluster} upgrade -i kcp ./kcp/charts/kcp -n h2 -f /tmp/values.yaml
done 
```
# prepare kcp kubeconfig

```sh
kubectl --context kind-cluster1 apply -f ./kcp/client-credentials.yaml -n h2
export client_ca=$(kubectl --context kind-cluster1 get secret cluster-admin-client-cert -n h2 -o yaml -o=jsonpath='{.data.ca\.crt}')
export client_key=$(kubectl --context kind-cluster1 get secret cluster-admin-client-cert -n h2 -o yaml -o=jsonpath='{.data.tls\.key}')
export client_crt=$(kubectl --context kind-cluster1 get secret cluster-admin-client-cert -n h2 -o yaml -o=jsonpath='{.data.tls\.crt}')
kubectl --context kind-cluster1 get secret cluster-admin-client-cert -n h2 -o yaml -o=jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
kubectl --context kind-cluster1 get secret cluster-admin-client-cert -n h2 -o yaml -o=jsonpath='{.data.tls\.key}' | base64 -d > /tmp/tls.key
kubectl --context kind-cluster1 get secret cluster-admin-client-cert -n h2 -o yaml -o=jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/tls.crt
kubectl --kubeconfig=/tmp/kcp.kubeconfig config set-cluster cluster1 --server https://kcp.cluster1.raffa:6443 --certificate-authority=/tmp/ca.crt --embed-certs=true
kubectl --kubeconfig=/tmp/kcp.kubeconfig config set-credentials kcp-admin --client-certificate=/tmp/tls.crt --client-key=/tmp/tls.key --embed-certs=true
kubectl --kubeconfig=/tmp/kcp.kubeconfig config set-context cluster1 --cluster=cluster1 --user=kcp-admin
kubectl --kubeconfig=/tmp/kcp.kubeconfig config use-context cluster1
```

add the shared state crd

```sh
kubectl --kubeconfig /tmp/kcp.kubeconfig apply -f ./kcp/sample-crd.yaml
```

add the api-service

```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f ./kcp/apiservice.yaml
done
```
restart statefulsets
```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} delete pod etcd-0 -n h2
done
```

## deploy yugabyte

```sh
for cluster in cluster1 cluster2 cluster3; do
  #envsubst < ./yugabyte/manifge.yaml > /tmp/values.yaml
  #helm upgrade -i yugabytedb yugabytedb/yugabyte --version 2.21.0 --namespace h2 -f /tmp/values.yaml --kube-context kind-${cluster}
  cluster=${cluster} envsubst < ./yugabyte/manifests/yugabyte.yaml | kubectl --context kind-${cluster} apply -f - -n h2
done
```

```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} scale statefulsets yb-master -n h2 --replicas=0
  kubectl --context kind-${cluster} scale statefulsets yb-tserver -n h2 --replicas=0
  kubectl --context kind-${cluster} delete pvc datadir0-yb-master-0 datadir0-yb-tserver-0 datadir1-yb-master-0 datadir1-yb-tserver-0 -n h2 
done
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} scale statefulsets yb-master -n h2 --replicas=1
  kubectl --context kind-${cluster} scale statefulsets yb-tserver -n h2 --replicas=1
done
```

## Deploy Ingress gateway contour

```sh
declare -A ingress_ips
ingress_ips["cluster1"]="10.89.0.226"
ingress_ips["cluster2"]="10.89.0.234"
ingress_ips["cluster3"]="10.89.0.242"
for cluster in cluster1 cluster2 cluster3; do
  ingress_ip=${ingress_ips[${cluster}]}  envsubst < ./contour/values.yaml > /tmp/values.yaml
  helm --kube-context kind-${cluster} upgrade -i contour bitnami/contour --namespace projectcontour --create-namespace -f /tmp/values.yaml
done
```

## Install prometheus and grafana (optional)

```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f https://raw.githubusercontent.com/cilium/cilium/1.16.0-pre.0/examples/kubernetes/addons/prometheus/monitoring-example.yaml
done
```

access grafana

```sh
kubectl --context kind-${cluster} -n cilium-monitoring port-forward service/grafana --address 0.0.0.0 --address :: 3000:3000
```

access hubble ui

```sh
cilium --context kind-${cluster} hubble ui
```

## deploy dashboard (optional)

```sh
for cluster in cluster1 cluster2 cluster3; do
  cluster=${cluster}  envsubst < ./dashboard/values.yaml > /tmp/values.yaml
  helm --kube-context kind-${cluster} upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard --create-namespace --namespace kubernetes-dashboard -f /tmp/values.yaml
  cluster=${cluster}  envsubst < ./dashboard/httpproxy.yaml | kubectl --context kind-${cluster} apply -f -
done
```

get bearer tokens:

```sh
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} -n kubernetes-dashboard create token admin-user
done
```

### uninstall cilium 
```sh
for cluster in cluster1 cluster2 cluster3; do
helm --kube-context kind-${cluster} uninstall cilium --namespace kube-system
done
``` 

## remove everything

```sh
kind delete cluster -n cluster1 & 
kind delete cluster -n cluster2 & 
kind delete cluster -n cluster3 &
wait
```
