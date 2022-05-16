#  Curity Identity Server GKE Installation

[![Quality](https://img.shields.io/badge/quality-experiment-red)](https://curity.io/resources/code-examples/status/)
[![Availability](https://img.shields.io/badge/availability-source-blue)](https://curity.io/resources/code-examples/status/)

A demo installation of Curity Identity Server and Kong gateway including phantom token plugin in Google Kubernetes Engine for PoC purposes.

This tutorial will enable any developer or an architect to quickly run the Curity Identity Server and the Phantom Token Pattern in Kubernetes, via the Google Cloud Platform. This will ensure that opaque access tokens are issued to internet clients, while APIs receive JWT access tokens.

This tutorial could be completed by using the Google Cloud Platform free tier option without incurring any cost.

## Prepare the Installation

Deployment on GKE has the following prerequisites:
* [GCP Account](https://console.cloud.google.com/home) and ensure that GKE API is enabled.
* [gcloud CLI](https://cloud.google.com/sdk/docs/install) installed and configured.
* [Helm](https://helm.sh/)
* [OpenSSL](https://www.openssl.org/)
* [jq](https://stedolan.github.io/jq/) 
* [kubectl](https://kubernetes.io/docs/tasks/tools/)

Make sure you have above prerequisites installed and then copy a license file to the `idsvr-config/license.json` location.
If needed, you can also get a free community edition license from the [Curity Developer Portal](https://developer.curity.io).


## Deployment Pattern

All of the services are running privately in the kubernetes cluster and exposed via a https load balancer.

![deployment pattern](./docs/deployment.svg "deployment pattern")

## Installation

 1. Clone the repository
    ```sh
    git clone git@github.com:curityio/curity-idsvr-gke-installation.git
    cd curity-idsvr-gke-installation
    ```

 2. Configuration
 
    Cluster options could be configured by modifying `cluster-config/gke-cluster-config.json` file.


 3. Install the environment  
     ```sh
    ./deploy-idsvr-gke.sh --install
    ```   


 4. Shutdown environment  
     ```sh
    ./deploy-idsvr-gke.sh --stop
    ```  


 5. Start the environment  
     ```sh
    ./deploy-idsvr-gke.sh --start
    ```  


 6. Free up cloud resources
    ```sh
     ./deploy-idsvr-gke.sh --delete
    ```


 7. Logs
    ```sh
     kubectl -n curity logs -f -l role=curity-idsvr-runtime
     kubectl -n curity logs -f -l role=curity-idsvr-admin  
     kubectl -n kong   logs -f -l app.kubernetes.io/name=kong
     kubectl -n api    logs -f -l app=simple-echo-api
    ```


## Environment URLs

| Service             | URL                                                           | Purpose                                                         |
| --------------------|:------------------------------------------------------------- | ----------------------------------------------------------------|
| ADMIN UI            | https://admin.example.gke/admin                                | Curity Administration console                                   |
| OIDC METADATA       | https://login.example.gke/~/.well-known/openid-configuration   | OIDC metadata discovery ednpoint                                |
| KONG ADMIN ENDPOINT | https://kong-admin.example.gke                                 | RESTful Admin API for administration & configuration purposes. Kong is configured in DBLess mode & using declarative config, so the admin api is mostly read-only.  |
| KONG PROXY ENDPOINT | https://api.example.gke                                 | Kong Proxy URL                                                  |
| API  PROXY ENDPOINT | https://api.example.gke/echo                            | Upstream API proxy endpoint                                     |


For a detailed step by step installation instructions, please refer to [Installing the Curity Identity Server with Kong API Gateway on GKE](https://curity.io/resources/learn/kubernetes-gke-idsvr-kong-phantom) article.


## More Information

Please visit [curity.io](https://curity.io/) for more information about the Curity Identity Server.