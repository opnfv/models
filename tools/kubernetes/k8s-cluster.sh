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
#. $ bash k8s-cluster.sh ceph "<nodes>" <cluster-net> <public-net> [ceph_dev]
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.               if not provided, ceph data will be stored on osd nodes in /ceph
#. $ bash k8s-cluster.sh helm
#.     Setup helm as app kubernetes orchestration tool
#. $ bash k8s-cluster.sh demo
#.     Install helm charts for mediawiki and dokuwiki
#. $ bash k8s-cluster.sh all "<nodes>" <cluster-net> <public-net> [ceph_dev]
#.     Runs all the steps above
#.
#. Status: work in progress, incomplete
#

function setup_prereqs() {
  echo "${FUNCNAME[0]}: Create prerequisite setup script"
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
sudo apt-get -y install ceph-common
sudo apt-get -y install --allow-downgrades kubectl=${KUBE_VERSION}-00 kubelet=${KUBE_VERSION}-00 kubeadm=${KUBE_VERSION}-00
EOG
}

function setup_k8s_master() {
  echo "${FUNCNAME[0]}: Setting up kubernetes master"
  setup_prereqs

  # Install master 
  bash /tmp/prereqs.sh master
  # per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
  # If the following command fails, run "kubeadm reset" before trying again
  # --pod-network-cidr=192.168.0.0/16 is required for calico; this should not conflict with your server network interface subnets
  sudo kubeadm init --pod-network-cidr=192.168.0.0/16 >>/tmp/kubeadm.out
  cat /tmp/kubeadm.out
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  echo "${FUNCNAME[0]}: Cluster join command for manual use if needed: $k8s_joincmd"

  # Start cluster
  echo "${FUNCNAME[0]}: Start the cluster"
  mkdir -p $HOME/.kube
  sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  # Deploy pod network
  echo "${FUNCNAME[0]}: Deploy calico as CNI"
  sudo kubectl apply -f http://docs.projectcalico.org/v2.4/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml
}

function setup_k8s_agents() {
  agents="$1"
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  echo "${FUNCNAME[0]}: Installing agents at $1 with joincmd: $k8s_joincmd"

  setup_prereqs

  kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
  while [[ "$kubedns" != "Running" ]]; do
    echo "${FUNCNAME[0]}: kube-dns status is $kubedns. Waiting 60 seconds for it to be 'Running'" 
    sleep 60
    kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
  done
  echo "${FUNCNAME[0]}: kube-dns status is $kubedns" 

  for agent in $agents; do
    echo "${FUNCNAME[0]}: Install agent at $agent"
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/prereqs.sh ubuntu@$agent:/tmp/prereqs.sh
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent bash /tmp/prereqs.sh agent
    # Workaround for "[preflight] Some fatal errors occurred: /var/lib/kubelet is not empty" per https://github.com/kubernetes/kubeadm/issues/1
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo kubeadm reset
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo $k8s_joincmd
  done

  echo "${FUNCNAME[0]}: Cluster is ready when all nodes in the output of 'kubectl get nodes' show as 'Ready'."
}

function setup_ceph() {
  node_ips=$1
  cluster_net=$2
  public_net=$3
  ceph_dev=$4
  echo "${FUNCNAME[0]}: Deploying ceph-mon on localhost $HOSTNAME"
  echo "${FUNCNAME[0]}: Deploying ceph-osd on nodes $node_ips"
  echo "${FUNCNAME[0]}: Setting cluster-network=$cluster_net and public-network=$public_net"
  mon_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
  all_nodes="$mon_ip $node_ips"
  # Also caches the server fingerprints so ceph-deploy does not prompt the user
  # Note this loop may be partially redundant with the ceph-deploy steps below
  for node_ip in $all_nodes; do
    echo "${FUNCNAME[0]}: Install ntp and ceph on $node_ip"
    ssh -x -o StrictHostKeyChecking=no ubuntu@$node_ip <<EOF
sudo timedatectl set-ntp no
wget -q -O- 'https://download.ceph.com/keys/release.asc' | sudo apt-key add -
echo deb https://download.ceph.com/debian/ $(lsb_release -sc) main | sudo tee /etc/apt/sources.list.d/ceph.list
sudo apt update
sudo apt-get install -y ntp ceph ceph-deploy
EOF
  done
  
  # per http://docs.ceph.com/docs/master/start/quick-ceph-deploy/
  # also https://upcommons.upc.edu/bitstream/handle/2117/101816/Degree_Thesis_Nabil_El_Alami.pdf#vote +1
  echo "${FUNCNAME[0]}: Create ceph config folder ~/ceph-cluster"
  mkdir ~/ceph-cluster
  cd ~/ceph-cluster
  
  echo "${FUNCNAME[0]}: Create new cluster with $HOSTNAME as initial ceph-mon node"
  ceph-deploy new --cluster-network $cluster_net --public-network $public_net --no-ssh-copykey $HOSTNAME
  # Update conf per recommendations of http://docs.ceph.com/docs/jewel/rados/configuration/filesystem-recommendations/
  cat <<EOF >>ceph.conf
osd max object name len = 256
osd max object namespace len = 64
EOF
  cat ceph.conf

  echo "${FUNCNAME[0]}: Deploy ceph packages on other nodes"
  ceph-deploy install $mon_ip $node_ips

  echo "${FUNCNAME[0]}: Deploy the initial monitor and gather the keys"
  ceph-deploy mon create-initial

  if [[ "x$ceph_dev" == "x" ]]; then
    n=1
    for node_ip in $node_ips; do
      echo "${FUNCNAME[0]}: Prepare ceph OSD on node $node_ip"
      echo "$node_ip ceph-osd$n" | sudo tee -a /etc/hosts
      # Using ceph-osd$n here avoids need for manual acceptance of the new server hash
      ssh -x -o StrictHostKeyChecking=no ubuntu@ceph-osd$n <<EOF
echo "$node_ip ceph-osd$n" | sudo tee -a /etc/hosts
sudo mkdir /ceph && sudo chown -R ceph:ceph /ceph
EOF
      ceph-deploy osd prepare ceph-osd$n:/ceph
      ceph-deploy osd activate ceph-osd$n:/ceph
      ((n++))
    done
  else 
    echo "${FUNCNAME[0]}: Deploy OSDs"
    for node_ip in $node_ips; do
      echo "${FUNCNAME[0]}: Create ceph osd on $node_ip using $ceph_dev"
      ceph-deploy osd create $node_ip:$ceph_dev
    done
  fi

  echo "${FUNCNAME[0]}: Copy the config file and admin key to the admin node and OSD nodes"
  ceph-deploy admin $mon_ip $node_ips

  echo "${FUNCNAME[0]}: Check the cluster health"
  sudo ceph health
  sudo ceph -s

  # per https://crondev.com/kubernetes-persistent-storage-ceph/ and https://github.com/kubernetes/kubernetes/issues/38923
  # rbd  is not included in default kube-controller-manager... use attcomdev version
  sudo sed -i -- 's~gcr.io/google_containers/kube-controller-manager-amd64:.*~quay.io/attcomdev/kube-controller-manager:v1.7.3~' /etc/kubernetes/manifests/kube-controller-manager.yaml
  if [[ $(sudo grep -c attcomdev/kube-controller-manager /etc/kubernetes/manifests/kube-controller-manager.yaml) == 0 ]]; then
    echo "${FUNCNAME[0]}: Problem patching /etc/kubernetes/manifests/kube-controller-manager.yaml... script update needed"
    exit 1
  fi
  mgr=$(kubectl get pods --all-namespaces | grep kube-controller-manager | awk '{print $4}')
  while [[ "$mgr" != "Running" ]]; do
    echo "${FUNCNAME[0]}: kube-controller-manager status is $mgr. Waiting 60 seconds for it to be 'Running'" 
    sleep 60
    mgr=$(kubectl get pods --all-namespaces | grep kube-controller-manager | awk '{print $4}')
  done
  echo "${FUNCNAME[0]}: kube-controller-manager status is $mgr"

  echo "${FUNCNAME[0]}: Create Ceph admin secret"
  admin_key=$(sudo ceph auth get-key client.admin)
  kubectl create secret generic ceph-secret-admin --from-literal=key="$admin_key" --namespace=kube-system --type=kubernetes.io/rbd

  echo "${FUNCNAME[0]}: Create rdb storageClass 'slow'"
  cat <<EOF >/tmp/ceph-sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
   name: slow
provisioner: kubernetes.io/rbd
parameters:
    monitors: $mon_ip:6789
    adminId: admin
    adminSecretName: ceph-secret-admin
    adminSecretNamespace: "kube-system"
    pool: kube
    userId: kube
    userSecretName: ceph-secret-user
EOF
  # TODO: find out where in the above ~/.kube folders became owned by root
  sudo chown -R ubuntu:ubuntu ~/.kube/*
  kubectl create -f /tmp/ceph-sc.yaml

  echo "${FUNCNAME[0]}: Create storage pool 'kube'"
  # https://github.com/kubernetes/examples/blob/master/staging/persistent-volume-provisioning/README.md method
  sudo ceph osd pool create kube 32 32

  echo "${FUNCNAME[0]}: Authorize client 'kube' access to pool 'kube'"
  sudo ceph auth get-or-create client.kube mon 'allow r' osd 'allow rwx pool=kube'

  echo "${FUNCNAME[0]}: Create ceph-secret-user secret in namespace 'default'"
  kube_key=$(sudo ceph auth get-key client.kube)
  kubectl create secret generic ceph-secret-user --from-literal=key="$kube_key" --namespace=default --type=kubernetes.io/rbd
  # A similar secret must be created in other namespaces that intend to access the ceph pool

  # Per https://github.com/kubernetes/examples/blob/master/staging/persistent-volume-provisioning/README.md

  echo "${FUNCNAME[0]}: Create andtest a persistentVolumeClaim"
  cat <<EOF >/tmp/ceph-pvc.yaml
{
  "kind": "PersistentVolumeClaim",
  "apiVersion": "v1",
  "metadata": {
    "name": "claim1",
    "annotations": {
        "volume.beta.kubernetes.io/storage-class": "slow"
    }
  },
  "spec": {
    "accessModes": [
      "ReadWriteOnce"
    ],
    "resources": {
      "requests": {
        "storage": "3Gi"
      }
    }
  }
}
EOF
  kubectl create -f /tmp/ceph-pvc.yaml
  while [[ "x$(kubectl get pvc -o jsonpath='{.status.phase}' claim1)" != "xBound" ]]; do
    echo "${FUNCNAME[0]}: Waiting for pvc claim1 to be 'Bound'"
    kubectl describe pvc 
    sleep 10
  done
  echo "${FUNCNAME[0]}: pvc claim1 successfully bound to $(kubectl get pvc -o jsonpath='{.spec.volumeName}' claim1)"
  kubectl get pvc
  kubectl delete pvc claim1
  kubectl describe pods
}

function wait_for_service() {
  echo "${FUNCNAME[0]}: Waiting for service $1 to be available"
  pod=$(kubectl get pods --namespace default | awk "/$1/ { print \$1 }")
  echo "${FUNCNAME[0]}: Service $1 is at pod $pod"
  ready=$(kubectl get pods --namespace default -o jsonpath='{.status.containerStatuses[0].ready}' $pod)
  while [[ "$ready" != "true" ]]; do
    echo "${FUNCNAME[0]}: $1 container is not yet ready... waiting 10 seconds"
    sleep 10
    # TODO: figure out why transient pods sometimes mess up this logic, thus need to re-get the pods
    pod=$(kubectl get pods --namespace default | awk "/$1/ { print \$1 }")
    ready=$(kubectl get pods --namespace default -o jsonpath='{.status.containerStatuses[0].ready}' $pod)
  done
  echo "${FUNCNAME[0]}: pod $pod container status is $ready"
  host_ip=$(kubectl get pods --namespace default -o jsonpath='{.status.hostIP}' $pod)
  port=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services $1)
  echo "${FUNCNAME[0]}: pod $pod container is at host $host_ip and port $port"
  while ! curl http://$host_ip:$port ; do
    echo "${FUNCNAME[0]}: $1 service is not yet responding... waiting 10 seconds"
    sleep 10
  done
  echo "${FUNCNAME[0]}: $1 is available at http://$host_ip:$port"
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
      sed -i -- 's/# storageClass:/storageClass: "slow"/g' ./mediawiki/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./mediawiki/charts/mariadb/values.yaml
      helm install --name mw -f ./mediawiki/values.yaml ./mediawiki
      wait_for_service mw-mediawiki
      ;;
    dokuwiki)
      sed -i -- 's/# storageClass:/storageClass: "slow"/g' ./dokuwiki/values.yaml
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
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./wordpress/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./wordpress/charts/mariadb/values.yaml
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
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./redmine/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./redmine/charts/mariadb/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./redmine/charts/postgresql/values.yaml
      helm install --name rdm -f ./redmine/values.yaml ./redmine
      wait_for_service rdm-redmine
      ;;
    owncloud)
      # NOT YET WORKING: needs resolvable hostname for service
      mkdir ./owncloud/charts
      cp -r ./mariadb ./owncloud/charts
      sed -i -- 's/LoadBalancer/NodePort/g' ./owncloud/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./owncloud/values.yaml
      sed -i -- 's/# storageClass: "-"/storageClass: "slow"/g' ./owncloud/charts/mariadb/values.yaml
      helm install --name oc -f ./owncloud/values.yaml ./owncloud
      wait_for_service oc-owncloud
      ;;
    *)
      echo "${FUNCNAME[0]}: demo not implemented for $1"
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
  echo "${FUNCNAME[0]}: Setup helm"
  # Install Helm
  cd ~
  curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh
  chmod 700 get_helm.sh
  ./get_helm.sh
  helm init
  helm repo update
  # TODO: Workaround for bug https://github.com/kubernetes/helm/issues/2224
  # For testing use only!
  kubectl create clusterrolebinding permissive-binding --clusterrole=cluster-admin --user=admin --user=kubelet --group=system:serviceaccounts;
  # TODO: workaround for tiller FailedScheduling (No nodes are available that match all of the following predicates:: PodToleratesNodeTaints (1).)
  # kubectl taint nodes $HOSTNAME node-role.kubernetes.io/master:NoSchedule-
  # Wait till tiller is running
  tiller_deploy=$(kubectl get pods --all-namespaces | grep tiller-deploy | awk '{print $4}')
  while [[ "$tiller_deploy" != "Running" ]]; do
    echo "${FUNCNAME[0]}: tiller-deploy status is $tiller_deploy. Waiting 60 seconds for it to be 'Running'" 
    sleep 60
    tiller_deploy=$(kubectl get pods --all-namespaces | grep tiller-deploy | awk '{print $4}')
  done
  echo "${FUNCNAME[0]}: tiller-deploy status is $tiller_deploy"

  # Install services via helm charts from https://kubeapps.com/charts
  # e.g. helm install stable/dokuwiki
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
    setup_ceph "$2" $3 $4 $5
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
    setup_ceph "$2" $3 $4 $5
    setup_helm
    demo_chart dokuwiki
    ;;
  clean)
    # TODO
    ;;
  *)
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then grep '#. ' $0; fi
esac
