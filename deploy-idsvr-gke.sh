#!/bin/bash
set -eo pipefail

display_help() {
    echo -e "Usage: $(basename "$0") [-h | --help] [-i | --install]  [-d | --delete]  \n" >&2
    echo "** DESCRIPTION **"
    echo -e "This script can be used to deploy a gke cluster, curity identity server, kong gateway and phantom token plugin. \n"
    echo -e "OPTIONS \n"
    echo " --help      show this help message and exit                                                                  "
    echo " --install   creates a private gke cluster & deploys curity identity server along with other components       "
    echo " --start     start up the environment                                                                         "
    echo " --stop      shuts down the environment                                                                       "
    echo " --delete    deletes the gke k8s cluster & identity server deployment                                         "
}


greeting_message() {
  echo "|----------------------------------------------------------------------------|"
  echo "|  Google Kubernetes Engine based Curity Identity Server Installation        |"
  echo "|----------------------------------------------------------------------------|"
  echo "|  Following components are going to be installed :                          |"
  echo "|----------------------------------------------------------------------------|"
  echo "| [1] GKE PRIVATE KUBERNETES CLUSTER                                         |"
  echo "| [2] CURITY IDENTITY SERVER ADMIN NODE                                      |"
  echo "| [3] CURITY IDENTITY SERVER RUNTIME NODE                                    |"
  echo "| [4] KONG INGRESS CONTROLLER OR NGINX INGRESS CONTROLLER                   |"
  echo "| [5] GCP HTTPS LOAD BALANCER                                                |"
  echo "| [6] PHANTOM TOKEN PLUGIN                                                   |"
  echo "| [7] SIMPLE NODEJS API                                                      |"
  echo "|----------------------------------------------------------------------------|" 
  echo -e "\n"
}


pre_requisites_check() {
  # Check if gcloud, kubectl, helm & jq are installed
  if ! [[ $(gcloud --version) && $(helm version) && $(jq --version) && $(kubectl version ) ]]; then
      echo "Please install gcloud, kubectl, helm & jq to continue with the deployment .."
      exit 1 
  fi

  # Check for license file
  if [ ! -f 'idsvr-config/license.json' ]; then
    echo "Please copy a license.json file in the idsvr-config directory to continue with the deployment. License could be downloaded from https://developer.curity.io/"
    exit 1
  fi

  # To avoid accidentally commit of sensitive data to repositories
  cp ./hooks/pre-commit ./.git/hooks

  echo -e "\n"
}


read_cluster_config_file() {
  echo "Reading the configuration from cluster-config/gke-cluster-config.json .."
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  while read -r NAME; read -r VALUE; do
    if [ -z "$NAME" ]; then break; fi

  export "$NAME"="$VALUE" 

  done <<< "$(jq -rc '.[] | .[] | "\(.Name)\n\(.Value)"' "cluster-config/gke-cluster-config.json")"
}


create_vpc_network() {
  echo -e "Creating custom VPC network [NAT, SUBNET, ROUTER, FW RULES] for deployment, it will take a few minutes .... : \n"
  gcloud compute networks create curity-network --subnet-mode custom
  gcloud compute networks subnets create curity-subnet --network curity-network --region "${region}" --range 192.168.1.0/24
  gcloud compute routers create curity-nat-router --network curity-network --region "${region}"
  gcloud compute routers nats create nat-config --router-region "${region}" --router curity-nat-router --nat-all-subnet-ip-ranges --auto-allocate-nat-external-ips
  gcloud compute firewall-rules create curity-ingress-webhook --description="Allow ingress validation web-hook calls" --direction=INGRESS --priority=1000 --network=curity-network --action=ALLOW --rules=tcp:8443 --source-ranges=172.16.0.32/28
  echo -e "VPC Network configuration is completed ... \n"
}


create_gke_cluster() {
  read -p "Do you want to create a new private GKE cluster for deploying Curity Identity server ? [Y/y N/n] :" -n 1 -r
  echo -e "\n"

  if [[ ! $REPLY =~ ^[YyNn]$ ]] 
  then 
      echo 'Please choose either of [Y/y N/n]' 
      exit 1
  fi 

  read -p "Do you want to deploy Kong Ingress controller or Nginx Ingress controller ? [type kong or nginx] :" -r ingress_controller_type 
  echo -e "\n"

  if [ "$ingress_controller_type" != "kong" ] && [ "$ingress_controller_type" != "nginx" ]
  then 
      echo 'Please choose either kong or nginx as the ingress controller' 
      exit 1
  fi 

  if [[ $REPLY =~ ^[Yy]$ ]]
  then
    generate_self_signed_certificates
    create_vpc_network
    gcloud container clusters create "${cluster_name}" --num-nodes "${number_of_nodes_in_each_zone}" --machine-type  "${worker_nodes_machine_type}" \
    --disk-size "${worker_nodes_disk_size_in_gigabytes}" --no-enable-master-authorized-networks --network curity-network --subnetwork curity-subnet --enable-ip-alias --enable-private-nodes --master-ipv4-cidr 172.16.0.32/28 --enable-autoscaling \
    --min-nodes 1 --max-nodes 6 --node-locations "${worker_nodes_zones}" --region "${region}"  
  else
    echo "Not creating a new k8s cluster, assuming that an existing cluster is already available for deployment ..."
  fi
 
  echo -e "\n"
}


is_pki_already_available() {
  echo -e "Verifying whether the certificates are already available .."
  if [[ -f certs/example.gke.ssl.key && -f certs/example.gke.ssl.pem ]] ; then
    echo -e "example.gke.ssl.key & example.gke.ssl.pem certificates already exist.., skipping regeneration of certificates\n"
    true
  else
    echo -e "Generating example.gke.ssl.key,example.gke.ssl.pem certificates using local domain names from cluster-config/gke-cluster-config.json..\n"
    false
  fi
}


generate_self_signed_certificates() { 
  if ! is_pki_already_available ; then
      bash ./create-self-signed-certs.sh
    echo -e "\n"
  fi
}



deploy_idsvr() {
  echo "Fetching Curity Idsvr helm chart ..."
  helm repo add curity https://curityio.github.io/idsvr-helm || true
  helm repo update

  envsubst < idsvr-config/helm-values.yaml.template > idsvr-config/helm-values.yaml

  echo -e "Deploying Curity Identity Server in the k8s cluster ...\n"
  helm install curity curity/idsvr --values idsvr-config/helm-values.yaml --namespace "${idsvr_namespace}" --create-namespace

  kubectl create secret generic idsvr-config --from-file=idsvr-config/idsvr-cluster-config.xml --from-file=idsvr-config/license.json -n "${idsvr_namespace}" || true
  
  # create secrets for TLS termination at ingress layer
  kubectl create secret tls example-gke-tls --cert=certs/example.gke.ssl.pem --key=certs/example.gke.ssl.key -n "$idsvr_namespace"
  
  if [ "$ingress_controller_type" == "kong" ]; then
    # Patch ingress to add kong ingress class and remove nginx
    kubectl patch ingress curity-idsvr-ingress -p '{"spec":{"ingressClassName":"kong"}}}' --namespace "${idsvr_namespace}"
    kubectl patch ingress curity-idsvr-ingress -p '{"metadata":{"annotations":{"kubernetes.io/ingress.class":null }}}' --namespace "${idsvr_namespace}"  
  fi
  
  # Copy the deployed artifacts to idsvr-config/template directory for reviewing 
  mkdir -p idsvr-config/templates
  helm template curity curity/idsvr --values idsvr-config/helm-values.yaml > idsvr-config/templates/deployed-idsvr-helm.yaml
  echo -e "\n"
}


deploy_ingress_controller_and_sample_api() {
  echo "Deploying $ingress_controller_type ingress controller & sample API"
  if [ "$ingress_controller_type" == "kong" ]; then
      deploy_kong_ingress_controller
      deploy_simple_echo_api
  else
      deploy_simple_echo_api
      deploy_nginx_ingress_controller 
  fi

}


deploy_kong_ingress_controller() {
  echo -e "Deploying kong ingress controller & adding phantom token plugin in the k8s cluster ...\n"
  helm repo add kong https://charts.konghq.com
  helm repo update

  # Deploy kong ingress controller
  envsubst < kong-config/kong-phantom-token-plugin-crd.yaml.template > kong-config/kong-phantom-token-plugin-crd.yaml
  helm install kong  kong/kong --values kong-config/helm-values.yaml --namespace "${kong_ingress_namespace}" --create-namespace
  echo -e "\n"
}


deploy_nginx_ingress_controller() {
  echo -e "Deploying Nginx ingress controller & adding phantom token plugin in the k8s cluster ...\n"
    
  # Deploy nginx ingress controller  
  helm upgrade --install ingress-nginx ingress-nginx \
     --values nginx-config/helm-values.yaml \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace "${nginx_ingress_namespace}" --create-namespace
  echo -e "\n"
}


deploy_simple_echo_api() {
  echo -e "Deploying simple echo api in the k8s cluster ...\n"
  kubectl create namespace "$api_namespace" || true

 # create secrets for TLS termination at ingress layer
  kubectl create secret tls example-gke-tls --cert=certs/example.gke.ssl.pem --key=certs/example.gke.ssl.key -n "$api_namespace"
  
  if [ "$ingress_controller_type" == "kong" ]; then
    # Deploy phantom token plugin in api namespace
    kubectl apply -f kong-config/kong-phantom-token-plugin-crd.yaml -n "${api_namespace}"
    kubectl apply -f simple-echo-api-config/echo-api-ingress-kong.yaml -n "${api_namespace}"   
  else
      kubectl apply -f simple-echo-api-config/echo-api-ingress-nginx.yaml -n "${api_namespace}"
  fi
    
  kubectl apply -f simple-echo-api-config/simple-echo-api-k8s-deployment.yaml -n "${api_namespace}"
  echo -e "\n"
}


startup_environment() {
  echo "Starting up the environment .."
  gcloud container clusters resize "${cluster_name}" --num-nodes "$number_of_nodes_in_each_zone" --node-pool default-pool --region "${region}"
}


shutdown_environment() {
  echo "Shutting down the environment .."
  gcloud container clusters resize "${cluster_name}" --num-nodes 0 --node-pool default-pool --region "${region}"
}


delete_vpc_network() {
  echo "Deleting VPC network resources .."
  echo -e "\n"
  gcloud compute networks subnets delete curity-subnet --region "${region}" || true
  gcloud compute routers delete curity-nat-router --region="${region}" || true
  gcloud compute firewall-rules delete curity-ingress-webhook || true
  gcloud compute networks delete curity-network || true
  echo "Clean up completed .."
}


tear_down_environment() {
  read -p "Identity server deployment and k8s cluster would be deleted, Are you sure? [Y/y N/n] :" -n 1 -r
  echo -e "\n"

  if [[ $REPLY =~ ^[Yy]$ ]]
  then
    helm uninstall curity -n "${idsvr_namespace}" || true
    helm uninstall kong -n "${kong_ingress_namespace}" || true
    helm uninstall ingress-nginx -n "${nginx_ingress_namespace}" || true

    kubectl delete -f simple-echo-api-config/simple-echo-api-k8s-deployment.yaml -n "${api_namespace}" || true

    gcloud container clusters delete "${cluster_name}" --region "${region}" || true
    echo -e "\n" 
    delete_vpc_network
  else
    echo "Aborting the operation .."
    exit 1
  fi
}


environment_info() {
  echo "Waiting for LoadBalancer's External IP, sleeping for 60 seconds ..."
  sleep 60

  if [ "$ingress_controller_type" == "kong" ]; then
    LB_IP=$(kubectl -n kong get svc kong-kong-proxy -o jsonpath="{.status.loadBalancer.ingress[0].ip}") || true 
  else
    LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath="{.status.loadBalancer.ingress[0].ip}") || true  
  fi
  
  if [ -z "$LB_IP" ]; then LB_IP="<LoadBalancer-IP>"; fi
  
  echo -e "\n"
  
  echo "|--------------------------------------------------------------------------------------------------------------------------------------------------|"
  echo "|                                Environment URLS & Endpoints                                                                                      |"
  echo "|--------------------------------------------------------------------------------------------------------------------------------------------------|"
  echo "|                                                                                                                                                  |"
  echo "| [ADMIN UI]        https://admin.example.gke/admin                                                                                                |"
  echo "| [OIDC METADATA]   https://login.example.gke/~/.well-known/openid-configuration                                                                   |"
  echo "| [SIMPLE ECHO API] https://api.example.gke/echo                                                                                                   |"
  echo "|                                                                                                                                                  |"
  echo "|                                                                                                                                                  |"
  echo "| * Curity administrator username is admin and password is $idsvr_admin_password                                                                    "
  echo "| * Remember to add certs/example.gke.ca.pem to operating system's certificate trust store &                                                       |"
  echo "|   $LB_IP  admin.example.gke login.example.gke api.example.gke entry to /etc/hosts                                          "
  echo "|--------------------------------------------------------------------------------------------------------------------------------------------------|" 
}


# ==========
# entrypoint
# ==========

case $1 in
  -i | --install)
    greeting_message
    pre_requisites_check
    read_cluster_config_file
    create_gke_cluster
    deploy_idsvr
    deploy_ingress_controller_and_sample_api
    environment_info
    ;;
  --start)
    read_cluster_config_file
    startup_environment
    ;;
  --stop)
    read_cluster_config_file
    shutdown_environment
    ;;
  -d | --delete)
    read_cluster_config_file
    tear_down_environment
    ;;
  -h | --help)
    display_help
    ;;
  *)
    echo "[ERROR] Unsupported options"
    display_help
    exit 1
    ;;
esac