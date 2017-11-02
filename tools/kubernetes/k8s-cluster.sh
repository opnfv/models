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
#. What this is: script to setup a kubernetes cluster with calico as sni
#. Prerequisites:
#. - Ubuntu xenial server for master and agent nodes
#. - key-based auth setup for ssh/scp between master and agent nodes
#. - 192.168.0.0/16 should not be used on your server network interface subnets
#. Usage:
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ cd ~/models/tools/kubernetes
#. $ bash k8s-cluster.sh master
#. $ bash k8s-cluster.sh agents "<nodes>"
#.     nodes: space-separated list of ceph node IPs
#. $ bash k8s-cluster.sh ceph "<nodes>" <cluster-net> <public-net> <ceph-mode> [ceph_dev]
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph-mode: "helm" or "baremetal"
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.               if not provided, ceph data will be stored on osd nodes in /ceph
#. $ bash k8s-cluster.sh helm
#.     Setup helm as app kubernetes orchestration tool
#. $ bash k8s-cluster.sh demo
#.     Install helm charts for mediawiki and dokuwiki
#. $ bash k8s-cluster.sh all "<nodes>" <cluster-net> <public-net> <ceph-mode> [ceph_dev]
#.     Runs all the steps above
#.
#. When deployment is complete, the k8s API will be available at the master
#. node, e.g. via: curl -k https://<master-ip>:6443/api/v1
#.
#. Status: work in progress, incomplete
#

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

function setup_prereqs() {
  log "Create prerequisite setup script"
  cat <<'EOG' >/tmp/prereqs.sh
#!/bin/bash
# Basic server pre-reqs
sudo apt-get -y remove kubectl kubelet kubeadm
sudo apt-get update
sudo apt-get upgrade -y
# Set hostname on agent nodes
if [[ "$1" == "agent" ]]; then
  echo $(ip route get 8.8.8.8 | awk '{print $NF; exit}') $HOSTNAME | sudo tee -a /etc/hosts
fi
# Install docker 1.12 (default for xenial is 1.12.6)
sudo apt-get install -y docker.io
sudo service docker start
export KUBE_VERSION=1.7.5
# per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
# Install kubelet, kubeadm, kubectl per https://kubernetes.io/docs/setup/independent/install-kubeadm/
sudo apt-get update && sudo apt-get install -y apt-transport-https
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
# Next command is to workaround bug resulting in "PersistentVolumeClaim is not bound" for pod startup (remain in Pending)
# TODO: reverify if this is still an issue in the final working script
sudo apt-get -y install --allow-downgrades kubectl=${KUBE_VERSION}-00 kubelet=${KUBE_VERSION}-00 kubeadm=${KUBE_VERSION}-00
# Needed for API output parsing
sudo apt-get -y install jq
EOG
}

function setup_k8s_master() {
  log "Setting up kubernetes master"
  setup_prereqs

  # Install master
  bash /tmp/prereqs.sh master
  # per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
  # If the following command fails, run "kubeadm reset" before trying again
  # --pod-network-cidr=192.168.0.0/16 is required for calico; this should not conflict with your server network interface subnets
  sudo kubeadm init --pod-network-cidr=192.168.0.0/16 >>/tmp/kubeadm.out
  cat /tmp/kubeadm.out
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  log "Cluster join command for manual use if needed: $k8s_joincmd"

  # Start cluster
  log "Start the cluster"
  mkdir -p $HOME/.kube
  sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  # Deploy pod network
  log "Deploy calico as CNI"
  sudo kubectl apply -f http://docs.projectcalico.org/v2.4/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml
}

function setup_k8s_agents() {
  agents="$1"
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  log "Installing agents at $1 with joincmd: $k8s_joincmd"

  setup_prereqs

  kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
  while [[ "$kubedns" != "Running" ]]; do
    log "kube-dns status is $kubedns. Waiting 60 seconds for it to be 'Running'"
    sleep 60
    kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
  done
  log "kube-dns status is $kubedns"

  for agent in $agents; do
    log "Install agent at $agent"
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/prereqs.sh ubuntu@$agent:/tmp/prereqs.sh
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent bash /tmp/prereqs.sh agent
    # Workaround for "[preflight] Some fatal errors occurred: /var/lib/kubelet is not empty" per https://github.com/kubernetes/kubeadm/issues/1
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo kubeadm reset
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo $k8s_joincmd
  done

  log "Cluster is ready when all nodes in the output of 'kubectl get nodes' show as 'Ready'."
}

function wait_for_service() {
  log "Waiting for service $1 to be available"
  pod=$(kubectl get pods --namespace default | awk "/$1/ { print \$1 }")
  log "Service $1 is at pod $pod"
  ready=$(kubectl get pods --namespace default -o jsonpath='{.status.containerStatuses[0].ready}' $pod)
  while [[ "$ready" != "true" ]]; do
    log "$1 container is not yet ready... waiting 10 seconds"
    sleep 10
    # TODO: figure out why transient pods sometimes mess up this logic, thus need to re-get the pods
    pod=$(kubectl get pods --namespace default | awk "/$1/ { print \$1 }")
    ready=$(kubectl get pods --namespace default -o jsonpath='{.status.containerStatuses[0].ready}' $pod)
  done
  log "pod $pod container status is $ready"
  host_ip=$(kubectl get pods --namespace default -o jsonpath='{.status.hostIP}' $pod)
  port=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services $1)
  log "pod $pod container is at host $host_ip and port $port"
  while ! curl http://$host_ip:$port ; do
    log "$1 service is not yet responding... waiting 10 seconds"
    sleep 10
  done
  log "$1 is available at http://$host_ip:$port"
}

function demo_chart() {
  cd ~
  rm -rf charts
  git clone https://github.com/kubernetes/charts.git
  cd charts/stable
  case "$1" in
    mediawiki)
      # NOT YET WORKING
      # mariadb: Readiness probe failed: mysqladmin: connect to server at 'localhost' failed
      mkdir ./mediawiki/charts
      cp -r ./mariadb ./mediawiki/charts
      # LoadBalancer is N/A for baremetal (public cloud only) - use NodePort
      sed -i -- 's/LoadBalancer/NodePort/g' ./mediawiki/values.yaml
      # Select the storageClass created in the ceph setup step
      sed -i -- 's/# storageClass:/storageClass: "general"/g' ./mediawiki/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./mediawiki/charts/mariadb/values.yaml
      helm install --name mw -f ./mediawiki/values.yaml ./mediawiki
      wait_for_service mw-mediawiki
      ;;
    dokuwiki)
      sed -i -- 's/# storageClass:/storageClass: "general"/g' ./dokuwiki/values.yaml
      sed -i -- 's/LoadBalancer/NodePort/g' ./dokuwiki/values.yaml
      helm install --name dw -f ./dokuwiki/values.yaml ./dokuwiki
      wait_for_service dw-dokuwiki
      ;;
    wordpress)
      # NOT YET WORKING
      # mariadb: Readiness probe failed: mysqladmin: connect to server at 'localhost' failed
      mkdir ./wordpress/charts
      cp -r ./mariadb ./wordpress/charts
      sed -i -- 's/LoadBalancer/NodePort/g' ./wordpress/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./wordpress/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./wordpress/charts/mariadb/values.yaml
      helm install --name wp -f ./wordpress/values.yaml ./wordpress
      wait_for_service wp-wordpress
      ;;
    redmine)
      # NOT YET WORKING
      # mariadb: Readiness probe failed: mysqladmin: connect to server at 'localhost' failed
      mkdir ./redmine/charts
      cp -r ./mariadb ./redmine/charts
      cp -r ./postgresql ./redmine/charts
      sed -i -- 's/LoadBalancer/NodePort/g' ./redmine/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./redmine/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./redmine/charts/mariadb/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./redmine/charts/postgresql/values.yaml
      helm install --name rdm -f ./redmine/values.yaml ./redmine
      wait_for_service rdm-redmine
      ;;
    owncloud)
      # NOT YET WORKING: needs resolvable hostname for service
      mkdir ./owncloud/charts
      cp -r ./mariadb ./owncloud/charts
      sed -i -- 's/LoadBalancer/NodePort/g' ./owncloud/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./owncloud/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "general"/g' ./owncloud/charts/mariadb/values.yaml
      helm install --name oc -f ./owncloud/values.yaml ./owncloud
      wait_for_service oc-owncloud
      ;;
    *)
      log "demo not implemented for $1"
  esac
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

function setup_helm() {
  log "Setup helm"
  # Install Helm
  cd ~
  curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh
  chmod 700 get_helm.sh
  ./get_helm.sh
  helm init
  nohup helm serve > /dev/null 2>&1 &
  helm repo update
  # TODO: Workaround for bug https://github.com/kubernetes/helm/issues/2224
  # For testing use only!
  kubectl create clusterrolebinding permissive-binding --clusterrole=cluster-admin --user=admin --user=kubelet --group=system:serviceaccounts;
  # TODO: workaround for tiller FailedScheduling (No nodes are available that match all of the following predicates:: PodToleratesNodeTaints (1).)
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

function setup_ceph() {
  if [[ "$4" == "helm" ]]; then
    source ./ceph-helm.sh "$1" $2 $3 $5
  else
    source ./ceph-baremetal.sh "$1" $2 $3 $5
  fi
}

export WORK_DIR=$(pwd)
case "$1" in
  master)
    setup_k8s_master
    ;;
  agents)
    setup_k8s_agents "$2"
    ;;
  ceph)
    setup_ceph "$2" $3 $4 $5 $6
    ;;
  helm)
    setup_helm
    ;;
  demo)
    demo_chart $2
    ;;
  all)
    setup_k8s_master
    setup_k8s_agents "$2"
    setup_helm
    setup_ceph "$2" $3 $4 $5 $6
    demo_chart dokuwiki
    ;;
  clean)
    # TODO
    ;;
  *)
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then grep '#. ' $0; fi
esac
