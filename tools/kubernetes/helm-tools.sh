#!/bin/bash
# Copyright 2017 AT&T Intellectual Property, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#. What this is: script to setup Helm as kubernetes chart manager, and to deploy
#. demo apps.
#. Prerequisites:
#. - Kubernetes cluster deployed using k8s-cluster.sh (demo charts supported
#.   leverage the ceph SDS storage classes setup by k8s-cluster.sh)
#. Usage:
#  Intended to be called from k8s-cluster.sh. To run directly:
#. $ bash ceph-tools.sh setup
#. $ bash ceph-tools.sh <start|stop> <chart>
#.     start|stop: start or stop the demo app
#.     chart: name of helm chart; currently implemented charts include nginx, 
#.       mediawiki, dokuwiki, wordpress, redmine
#.       For info see https://github.com/kubernetes/charts/tree/master/stable
#.
#. Status: work in progress, incomplete
#

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

function setup_helm() {
  log "Setup helm"
  # Install Helm
  # per https://github.com/kubernetes/helm/blob/master/docs/install.md
  cd ~
  curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh
  chmod 700 get_helm.sh
  ./get_helm.sh
  log "Initialize helm"
  helm init
#  nohup helm serve > /dev/null 2>&1 &
#  log "Run helm repo update"
#  helm repo update
  # TODO: Workaround for bug https://github.com/kubernetes/helm/issues/2224
  # For testing use only!
  kubectl create clusterrolebinding permissive-binding \
    --clusterrole=cluster-admin --user=admin --user=kubelet \
    --group=system:serviceaccounts;
  # TODO: workaround for tiller FailedScheduling (No nodes are available that 
  # match all of the following predicates:: PodToleratesNodeTaints (1).)
  # kubectl taint nodes $HOSTNAME node-role.kubernetes.io/master:NoSchedule-
  # Wait till tiller is running
  tiller_deploy=$(kubectl get pods --all-namespaces | grep tiller-deploy | awk '{print $4}')
  while [[ "$tiller_deploy" != "Running" ]]; do
    log "tiller-deploy status is $tiller_deploy. Waiting 60 seconds for it to be 'Running'"
    sleep 60
    tiller_deploy=$(kubectl get pods --all-namespaces | grep tiller-deploy | awk '{print $4}')
  done
  log "tiller-deploy status is $tiller_deploy"

  # Install services via helm charts from https://kubeapps.com/charts
  # e.g. helm install stable/dokuwiki
}

function wait_for_service() {
  log "Waiting for service $1 to be available"
  # TODO: fix 'head' workaround for more than one pod per service
  pods=$(kubectl get pods --namespace default | awk "/$1/ { print \$1 }")
  log "Service $1 is at pod(s) $pods"
  ready="false"
  while [[ "$ready" != "true" ]] ; do
    log "Waiting 10 seconds to check pod status"
    sleep 10
    for pod in $pods ; do
      ready=$(kubectl get pods --namespace default -o jsonpath='{.status.containerStatuses[0].ready}' $pod)
      if [[ "$ready" != "true" ]]; then
        log "pod $1 is $ready"
      fi
    done
  done
  log "pod $pod is ready"
  host_ip=$(kubectl get pods --namespace default -o jsonpath='{.status.hostIP}' $pod)
  port=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services $1)
  log "$pod pod is running on assigned node $host_ip"
  log "$1 service is assigned node_port $port"
  log "verify $1 service is accessible via all workers at node_port $port"
  nodes=$(kubectl get nodes | awk '/Ready/ {print $1}')
  for node in $nodes; do
    ip=$(kubectl describe nodes $node | awk '/InternalIP/ { print $2}')
    while ! curl http://$ip:$port ; do
      log "$1 service is not yet responding at worker $node IP $ip... waiting 10 seconds"
      sleep 10
    done
    log "$1 service is accessible at worker $node at http://$ip:$port"
  done
}

function mariadb_chart_update() {
  log "Set storageClass and nodeSelector in mariadb chart for $1"
  sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./$1/charts/mariadb/values.yaml
  sed -i "$ a nodeSelector:\n  role: worker" ./$1/charts/mariadb/values.yaml
}

function chart_update() {
  log "Set type NodePort, storageClass, and nodeSelector in chart for $1"
  # LoadBalancer is N/A for baremetal (public cloud only) - use NodePort
  sed -i -- 's/LoadBalancer/NodePort/g' ./$1/values.yaml
  # Select the storageClass created in the ceph setup step
  sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./$1/values.yaml
  sed -i "$ a nodeSelector:\n  role: worker" ./$1/values.yaml
  sed -i -- "s/    spec:/    spec:\n      nodeSelector:\n{{ toYaml .Values.nodeSelector | indent 8 }}/" ./$1/templates/deployment.yaml
}

function start_chart() {
  if [[ "$1" == "nginx" ]]; then
    rm -rf ~/git/helm
    git clone https://github.com/kubernetes/helm.git ~/git/helm
    cd ~/git/helm/docs/examples
    sed -i -- 's/type: ClusterIP/type: NodePort/' ./nginx/values.yaml
    sed -i -- 's/nodeSelector: {}/nodeSelector:\n  role: worker/' ./nginx/values.yaml
    helm install --name nx -f ./nginx/values.yaml ./nginx
    wait_for_service nx-nginx
  else
    rm -rf ~/git/charts
    git clone https://github.com/kubernetes/charts.git ~/git/charts
    cd ~/git/charts/stable
    case "$1" in
      mediawiki)
        mkdir ./mediawiki/charts
        cp -r ./mariadb ./mediawiki/charts
        chart_update $1
        mariadb_chart_update $1
        helm install --name mw -f ./mediawiki/values.yaml ./mediawiki
        wait_for_service mw-mediawiki
        ;;
      dokuwiki)
        chart_update $1
        helm install --name dw -f ./dokuwiki/values.yaml ./dokuwiki
        wait_for_service dw-dokuwiki
        ;;
      wordpress)
        mkdir ./wordpress/charts
        cp -r ./mariadb ./wordpress/charts
        chart_update $1
        mariadb_chart_update $1
        helm install --name wp -f ./wordpress/values.yaml ./wordpress
        wait_for_service wp-wordpress
        ;;
      redmine)
        mkdir ./redmine/charts
        cp -r ./mariadb ./redmine/charts
        cp -r ./postgresql ./redmine/charts
        chart_update $1
        mariadb_chart_update $1
        sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./redmine/charts/postgresql/values.yaml
        sed -i "$ a nodeSelector:\n  role: worker" ./redmine/charts/postgresql/values.yaml
        helm install --name rdm -f ./redmine/values.yaml ./redmine
        wait_for_service rdm-redmine
        ;;
      owncloud)
        # NOT YET WORKING: needs resolvable hostname for service
        mkdir ./owncloud/charts
        cp -r ./mariadb ./owncloud/charts
        chart_update $1
        mariadb_chart_update $1
        helm install --name oc -f ./owncloud/values.yaml ./owncloud
        wait_for_service oc-owncloud
        ;;
      *)
        log "demo not implemented for $1"
    esac
  fi
# extra useful commands
# kubectl describe pvc
# kubectl get pvc
# kubectl describe pods
# kubectl get pods --namespace default
# kubectl get pods --all-namespaces
# kubectl get svc --namespace default dw-dokuwiki
# kubectl describe svc --namespace default dw-dokuwiki
# kubectl describe pods --namespace default dw-dokuwiki
}

function stop_chart() {
  log "stop chart $1"
  service=$(kubectl get services --namespace default | awk "/$1/ {print \$1}")
  kubectl delete services --namespace default $service
  secret=$(kubectl get secrets --namespace default | awk "/$1/ {print \$1}")
  kubectl delete secrets --namespace default $secret
  pod=$(kubectl get pods --namespace default | awk "/$1/ { print \$1 }")
  kubectl delete pods --namespace default $pod
  release=$(echo $service | cut -d '-' -f 1)
  helm del --purge $release
  job=$(kubectl get jobs --namespace default | awk "/$1/ {print \$1}")
  kubectl delete jobs --namespace default $job
}

export WORK_DIR=$(pwd)
case "$1" in
  setup)
    setup_helm
    ;;
  start)
    start_chart $2
    ;;
  stop)
    stop_chart $2
    ;;
  clean)
    # TODO
    ;;
  *)
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then grep '#. ' $0; fi
esac
