# define needed helm charts

helm repo add cilium https://helm.cilium.io/
helm repo add yugabytedb https://charts.yugabyte.com

# create kind clusters

go install sigs.k8s.io/kind@v0.27.0
#setenforce 0
kind create cluster -n cluster1 --config ./kind-config/config-cluster1.yaml & 
kind create cluster -n cluster2 --config ./kind-config/config-cluster2.yaml &
kind create cluster -n cluster3 --config ./kind-config/config-cluster3.yaml &
wait

# deploy cert-manager CRDs

for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.crds.yaml
done

## deploy ingress API CRDs

for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
  kubectl --context kind-${cluster} apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
done

## deploy mcp apis

for cluster in cluster1 cluster2 cluster3; do
kubectl --context kind-${cluster} apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceexports.yaml
kubectl --context kind-${cluster} apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceimports.yaml
done

#patch core-dns to have headless services resolve

export cluster1_coredns_ip="10.89.0.225"
export cluster2_coredns_ip="10.89.0.233"
export cluster3_coredns_ip="10.89.0.241"
declare -A coredns_ips
coredns_ips["cluster1"]="10.89.0.225"
coredns_ips["cluster2"]="10.89.0.233"
coredns_ips["cluster3"]="10.89.0.241"
for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} patch deployment coredns -n kube-system -p '{"spec":{"replicas": 1,"template":{"spec":{"containers": [{"name":"coredns","image":"quay.io/raffaelespazzoli/coredns:v1.12.0-master-multicluster-gathersrv", "imagePullPolicy": "Always", "resources": {"limits":{"memory":"512Mi"}}}]}}}}'
  envsubst < ./core-dns/corefile-configmap-${cluster}.yaml | kubectl --context kind-${cluster} apply -f -
  coredns_ip=${coredns_ips[${cluster}]} envsubst < ./core-dns/coredns-service.yaml | kubectl --context kind-${cluster} apply -f -
  kubectl --context kind-${cluster} patch clusterrole system:coredns --type=json \
   -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["multicluster.x-k8s.io"],"resources":["serviceimports"],"verbs":["list","watch"]}}]'
done


# install cilium

declare -A cluster_ips
export cluster1_ip="10.89.0.224"
export cluster2_ip="10.89.0.232"
export cluster3_ip="10.89.0.240"
cluster_ips["cluster1"]="10.89.0.224"
cluster_ips["cluster2"]="10.89.0.232"
cluster_ips["cluster3"]="10.89.0.240"
export cidr_cluster1="10.89.0.224/29"
export cidr_cluster2="10.89.0.232/29"
export cidr_cluster3="10.89.0.240/29"
declare -A ingress_ips
ingress_ips["cluster1"]="10.89.0.226"
ingress_ips["cluster2"]="10.89.0.234"
ingress_ips["cluster3"]="10.89.0.242"
for cluster in cluster1 cluster2 cluster3; do
  cluster=${cluster} ordinal=${cluster: -1} apiserver_ip=${cluster_ips[${cluster}]}  envsubst < ./cilium/values.yaml > /tmp/${cluster}-values.yaml
  helm --kube-context kind-${cluster} upgrade -i cilium cilium/cilium --version "1.17.2" --namespace kube-system -f /tmp/${cluster}-values.yaml
  ingress_ip=${ingress_ips[${cluster}]}  cluster=${cluster} envsubst < ./cilium/gateway.yaml | kubectl --context kind-${cluster} apply -f - -n kube-system
  cluster=${cluster} envsubst < ./cilium/httproute.yaml | kubectl --context kind-${cluster} apply -f - -n kube-system
done

# wait for cilium-operator to come up

kubectl --context kind-cluster1 wait pod -l app.kubernetes.io/name=cilium-operator -n kube-system --for=condition=Ready --timeout=600s & 
kubectl --context kind-cluster2 wait pod -l app.kubernetes.io/name=cilium-operator -n kube-system --for=condition=Ready --timeout=600s & 
kubectl --context kind-cluster3 wait pod -l app.kubernetes.io/name=cilium-operator -n kube-system --for=condition=Ready --timeout=600s &
wait

# complete cilium configuration

export cidr_cluster1="10.89.0.224/29"
export cidr_cluster2="10.89.0.232/29"
export cidr_cluster3="10.89.0.240/29"
for cluster in cluster1 cluster2 cluster3; do
  vcidr=cidr_${cluster}
  cidr=${!vcidr} envsubst < ./cilium/ippool.yaml | kubectl --context kind-${cluster} apply -f -
done

# deploy cert-manager 

for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.yaml
done

# wait for cert-manager pods to be up

kubectl --context kind-cluster1 wait pod --all -n cert-manager --for=condition=Ready --timeout=600s & 
kubectl --context kind-cluster2 wait pod --all -n cert-manager --for=condition=Ready --timeout=600s & 
kubectl --context kind-cluster3 wait pod --all -n cert-manager --for=condition=Ready --timeout=600s &
wait

# create root ca

kubectl --context kind-cluster1 apply -f ./cert-manager/self-signed-issuer.yaml -n cert-manager
sleep 1
kubectl --context kind-cluster1 get secret root-secret -n cert-manager -o yaml > /tmp/root-secret.yaml


# share root ca with other clusters

for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f /tmp/root-secret.yaml
  kubectl --context kind-${cluster} apply -f ./cert-manager/cluster-issuer.yaml -n cert-manager
done

# wait for all the pods to be up

kubectl --context kind-cluster1 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster2 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster3 wait pod --all --for=condition=Ready -A --timeout=600s &
wait




# configure coredns for statefulsets

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

# create h2 namespace

for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} create namespace h2
done

## deploy yugabyte

for cluster in cluster1 cluster2 cluster3; do
  cluster=${cluster} envsubst < ./yugabyte/manifests/yugabyte.yaml | kubectl --context kind-${cluster} apply -f - -n h2
done

## deploy kine

for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f ./kine/deployment.yaml -n h2
done

## deploy api-server

for cluster in cluster1 cluster2 cluster3; do
  kubectl --context kind-${cluster} apply -f ./api-server/aggregated-apiserver.yaml -n h2
  kubectl --context kind-${cluster} apply -f ./api-server/apiservice.yaml -n h2
  kubectl --context kind-${cluster} apply -f ./api-server/controller-manager.yaml -n h2
  kubectl --context kind-${cluster} apply -f ./api-server/rbac.yaml -n h2
  kubectl --context kind-${cluster} apply -f ./api-server/crd -n h2
done

# wait for all pods to be up

kubectl --context kind-cluster1 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster2 wait pod --all --for=condition=Ready -A --timeout=600s & 
kubectl --context kind-cluster3 wait pod --all --for=condition=Ready -A --timeout=600s &
wait
  