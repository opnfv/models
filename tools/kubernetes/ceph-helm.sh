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
#. service for a kubernetes cluster, using Helm as deployment tool.
#. Prerequisites:
#. - Ubuntu xenial server for master and agent nodes
#. - key-based auth setup for ssh/scp between master and agent nodes
#. - 192.168.0.0/16 should not be used on your server network interface subnets
#. Usage:
#  Intended to be called from k8s-cluster.sh in this folder. To run directly:
#. $ bash ceph-helm.sh "<nodes>" <cluster-net> <public-net> [ceph_dev]
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.               if not provided, ceph data will be stored on osd nodes in /ceph
#.
#. Status: work in progress, incomplete
#

function setup_ceph() {
  nodes=$1
  private_net=$2
  public_net=$3
  dev=$4
  # per https://github.com/att/netarbiter/tree/master/sds/ceph-docker/examples/helm
  echo "${FUNCNAME[0]}: Clone netarbiter"
  git clone https://github.com/att/netarbiter.git
  
  echo "${FUNCNAME[0]}: Create a .kube/config secret so that a K8s job could run kubectl inside the container"
  cd netarbiter/sds/ceph-docker/examples/helm
  kubectl create namespace ceph
  ./create-secret-kube-config.sh ceph
  ./helm-install-ceph.sh cephtest $private_net $public_net

  kubedns=$(kubectl get service -o json --namespace kube-system kube-dns | \
    jq -r '.spec.clusterIP')

  cat <<EOF | sudo tee /etc/resolv.conf
nameserver $kubedns
search ceph.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
EOF

  for node in $nodes; do
    echo "${FUNCNAME[0]}: setup resolv.conf for $node"
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node <<EOG
cat <<EOF | sudo tee -a /etc/resolv.conf
nameserver $kubedns
search ceph.svc.cluster.local svc.cluster.local cluster.local 
options ndots:5
EOF
EOG
    echo "${FUNCNAME[0]}: Zap disk $dev at $node"
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node sudo ceph-disk zap /dev/$dev
    echo "${FUNCNAME[0]}: Run ceph-osd at $node"
    name=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node hostname)
    ./helm-install-ceph-osd.sh $name /dev/$dev
  done

  echo "${FUNCNAME[0]}: WORKAROUND take ownership of .kube"
  # TODO: find out why this is needed
  sudo chown -R ubuntu:ubuntu ~/.kube/*

  echo "${FUNCNAME[0]}: Activate Ceph for namespace 'default'"
  ./activate-namespace.sh default

  echo "${FUNCNAME[0]}: Relax access control rules"
  kubectl replace -f relax-rbac-k8s1.7.yaml

  # TODO: verification tests

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

if [[ "$1" != "" ]]; then
  setup_ceph "$1" $2 $3 $4
else
  grep '#. ' $0
fi
