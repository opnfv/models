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
#. What this is: script to setup a Ceph-based SDS (Software Defined Storage)
#. service for a kubernetes cluster, directly on the master and worker nodes.
#. Prerequisites:
#. - Ubuntu xenial server for master and agent nodes
#. - key-based auth setup for ssh/scp between master and agent nodes
#. - 192.168.0.0/16 should not be used on your server network interface subnets
#. Usage:
#  Intended to be called from k8s-cluster.sh in this folder. To run directly:
#. $ bash ceph-baremetal.sh "<nodes>" <cluster-net> <public-net> [ceph_dev]
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.               if not provided, ceph data will be stored on osd nodes in /ceph
#.
#. Status: work in progress, incomplete
#

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

function setup_ceph() {
  node_ips=$1
  cluster_net=$2
  public_net=$3
  ceph_dev=$4
  log "Deploying ceph-mon on localhost $HOSTNAME"
  log "Deploying ceph-osd on nodes $node_ips"
  log "Setting cluster-network=$cluster_net and public-network=$public_net"
  mon_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
  all_nodes="$mon_ip $node_ips"
  # Also caches the server fingerprints so ceph-deploy does not prompt the user
  # Note this loop may be partially redundant with the ceph-deploy steps below
  for node_ip in $all_nodes; do
    log "Install ntp and ceph on $node_ip"
		# TODO: fix this workaround
		# Don't use ssh option UserKnownHostsFile=/dev/null as the hash needs to be 
		# cached at this point, otherwise ceph-deploy and ssh steps will fail
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
  log "Create ceph config folder ~/ceph-cluster"
  mkdir ~/ceph-cluster
  cd ~/ceph-cluster

  log "Create new cluster with $HOSTNAME as initial ceph-mon node"
  ceph-deploy new --cluster-network $cluster_net --public-network $public_net --no-ssh-copykey $HOSTNAME
  # Update conf per recommendations of http://docs.ceph.com/docs/jewel/rados/configuration/filesystem-recommendations/
  cat <<EOF >>ceph.conf
osd max object name len = 256
osd max object namespace len = 64
EOF
  cat ceph.conf

  log "Deploy ceph packages on other nodes"
  ceph-deploy install $mon_ip $node_ips

  log "Deploy the initial monitor and gather the keys"
  ceph-deploy mon create-initial

  if [[ "x$ceph_dev" == "x" ]]; then
    n=1
    for node_ip in $node_ips; do
      log "Prepare ceph OSD on node $node_ip"
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
    log "Deploy OSDs"
    for node_ip in $node_ips; do
      log "Create ceph osd on $node_ip using $ceph_dev"
      ceph-deploy osd create $node_ip:$ceph_dev
    done
  fi

  log "Copy the config file and admin key to the admin node and OSD nodes"
  ceph-deploy admin $mon_ip $node_ips

  log "Check the cluster health"
  sudo ceph health
  sudo ceph -s

  # per https://crondev.com/kubernetes-persistent-storage-ceph/ and https://github.com/kubernetes/kubernetes/issues/38923
  # rbd  is not included in default kube-controller-manager... use attcomdev version
  sudo sed -i -- 's~gcr.io/google_containers/kube-controller-manager-amd64:.*~quay.io/attcomdev/kube-controller-manager:v1.7.3~' /etc/kubernetes/manifests/kube-controller-manager.yaml
  if [[ $(sudo grep -c attcomdev/kube-controller-manager /etc/kubernetes/manifests/kube-controller-manager.yaml) == 0 ]]; then
    log "Problem patching /etc/kubernetes/manifests/kube-controller-manager.yaml... script update needed"
    exit 1
  fi
  mgr=$(kubectl get pods --all-namespaces | grep kube-controller-manager | awk '{print $4}')
  while [[ "$mgr" != "Running" ]]; do
    log "kube-controller-manager status is $mgr. Waiting 60 seconds for it to be 'Running'"
    sleep 60
    mgr=$(kubectl get pods --all-namespaces | grep kube-controller-manager | awk '{print $4}')
  done
  log "kube-controller-manager status is $mgr"

  log "Create Ceph admin secret"
  admin_key=$(sudo ceph auth get-key client.admin)
  kubectl create secret generic ceph-secret-admin --from-literal=key="$admin_key" --namespace=kube-system --type=kubernetes.io/rbd

  log "Create rdb storageClass 'general'"
  cat <<EOF >/tmp/ceph-sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
   name: general
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
  kubectl create -f ~/tmp/ceph-sc.yaml

  log "Create storage pool 'kube'"
  # https://github.com/kubernetes/examples/blob/master/staging/persistent-volume-provisioning/README.md method
  sudo ceph osd pool create kube 32 32

  log "Authorize client 'kube' access to pool 'kube'"
  sudo ceph auth get-or-create client.kube mon 'allow r' osd 'allow rwx pool=kube'

  log "Create ceph-secret-user secret in namespace 'default'"
  kube_key=$(sudo ceph auth get-key client.kube)
  kubectl create secret generic ceph-secret-user --from-literal=key="$kube_key" --namespace=default --type=kubernetes.io/rbd
  # A similar secret must be created in other namespaces that intend to access the ceph pool

  # Per https://github.com/kubernetes/examples/blob/master/staging/persistent-volume-provisioning/README.md

  log "Create andtest a persistentVolumeClaim"
  cat <<EOF >/tmp/ceph-pvc.yaml
{
  "kind": "PersistentVolumeClaim",
  "apiVersion": "v1",
  "metadata": {
    "name": "claim1",
    "annotations": {
        "volume.beta.kubernetes.io/storage-class": "general"
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
  kubectl create -f ~/tmp/ceph-pvc.yaml
  while [[ "x$(kubectl get pvc -o jsonpath='{.status.phase}' claim1)" != "xBound" ]]; do
    log "Waiting for pvc claim1 to be 'Bound'"
    kubectl describe pvc
    sleep 10
  done
  log "pvc claim1 successfully bound to $(kubectl get pvc -o jsonpath='{.spec.volumeName}' claim1)"
  kubectl get pvc
  kubectl delete pvc claim1
  kubectl describe pods
}

if [[ "$1" != "" ]]; then
  setup_ceph "$1" $2 $3 $4
else
  grep '#. ' $0
fi
