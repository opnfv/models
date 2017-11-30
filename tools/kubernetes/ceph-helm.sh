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

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

function setup_ceph() {
  nodes=$1
  private_net=$2
  public_net=$3
  dev=$4
	
  log "Install ceph prerequisites"
	sudo apt-get -y install ceph ceph-common

  # per https://github.com/att/netarbiter/tree/master/sds/ceph-docker/examples/helm
  log "Clone netarbiter"
  git clone https://github.com/att/netarbiter.git
  cd netarbiter/sds/ceph-docker/examples/helm

  log "Prepare a ceph namespace in your K8s cluster"
  ./prep-ceph-ns.sh

  log "Run ceph-mon, ceph-mgr, ceph-mon-check, and rbd-provisioner"
  # Pre-req per https://github.com/att/netarbiter/tree/master/sds/ceph-docker/examples/helm#notes
  kubedns=$(kubectl get service -o json --namespace kube-system kube-dns | \
    jq -r '.spec.clusterIP')

  cat <<EOF | sudo tee /etc/resolv.conf
nameserver $kubedns
search ceph.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
EOF

  ./helm-install-ceph.sh cephtest $public_net $private_net

  log "Check the pod status of ceph-mon, ceph-mgr, ceph-mon-check, and rbd-provisioner"
  services="rbd-provisioner ceph-mon-0 ceph-mgr ceph-mon-check"
  for service in $services; do
    pod=$(kubectl get pods --namespace ceph | awk "/$service/{print \$1}")
    status=$(kubectl get pods --namespace ceph $pod -o json | jq -r '.status.phase')
    while [[ "x$status" != "xRunning" ]]; do
      log "$pod status is \"$status\". Waiting 10 seconds for it to be 'Running'"
      sleep 10
      status=$(kubectl get pods --namespace ceph $pod -o json | jq -r '.status.phase')
    done
  done
  kubectl get pods --namespace ceph

  log "Check ceph health status"
  status=$(kubectl -n ceph exec -it ceph-mon-0 -- ceph -s | awk "/health:/{print \$2}")
  while [[ "x$status" != "xHEALTH_OK" ]]; do
    log "ceph status is \"$status\". Waiting 10 seconds for it to be 'HEALTH_OK'"
    kubectl -n ceph exec -it ceph-mon-0 -- ceph -s
    sleep 10
    status=$(kubectl -n ceph exec -it ceph-mon-0 -- ceph -s | awk "/health:/{print \$2}")
  done
  log "ceph status is 'HEALTH_OK'"
  kubectl -n ceph exec -it ceph-mon-0 -- ceph -s

  for node in $nodes; do
    log "install ceph, setup resolv.conf, zap disk for $node"
    ssh -x -o StrictHostKeyChecking=no ubuntu@$node <<EOG
cat <<EOF | sudo tee /etc/resolv.conf
nameserver $kubedns
search ceph.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
EOF
sudo apt install -y ceph ceph-common
sudo ceph-disk zap /dev/$dev
EOG
    log "Run ceph-osd at $node"
    name=$(ssh -x -o StrictHostKeyChecking=no ubuntu@$node hostname)
    ./helm-install-ceph-osd.sh $name /dev/$dev
  done

  for node in $nodes; do
    name=$(ssh -x -o StrictHostKeyChecking=no ubuntu@$node hostname)
    pod=$(kubectl get pods --namespace ceph | awk "/$name/{print \$1}")
    log "verify ceph-osd is Running at node $name"
    status=$(kubectl get pods --namespace ceph $pod | awk "/$pod/ {print \$3}")
    while [[ "x$status" != "xRunning" ]]; do
      log "$pod status is $status. Waiting 10 seconds for it to be Running."
      sleep 10
      status=$(kubectl get pods --namespace ceph $pod | awk "/$pod/ {print \$3}")
      kubectl get pods --namespace ceph
    done
  done

  log "WORKAROUND take ownership of .kube"
  # TODO: find out why this is needed
  sudo chown -R ubuntu:ubuntu ~/.kube/*

  log "Activate Ceph for namespace 'default'"
  ./activate-namespace.sh default

  log "Relax access control rules"
  kubectl replace -f relax-rbac-k8s1.7.yaml

  log "Setup complete, running smoke tests"
  log "Create a pool from a ceph-mon pod (e.g., ceph-mon-0)"

  kubectl -n ceph exec -it ceph-mon-0 -- ceph osd pool create rbd 100 100
	# TODO: Workaround for issue: "rbd: map failed exit status 110 rbd: sysfs write failed"
	kubectl -n ceph exec -it ceph-mon-0 -- ceph osd crush tunables legacy

  log "Create a pvc and check if the pvc status is Bound"

  kubectl create -f tests/ceph/pvc.yaml
  status=$(kubectl get pvc ceph-test -o json | jq -r '.status.phase')
  while [[ "$status" != "Bound" ]]; do
    log "pvc status is $status, waiting 10 seconds for it to be Bound"
    sleep 10
    status=$(kubectl get pvc ceph-test -o json | jq -r '.status.phase')
  done
  log "pvc ceph-test successfully bound to $(kubectl get pvc -o jsonpath='{.spec.volumeName}' ceph-test)"
  kubectl describe pvc

  log "Attach the pvc to a job"
  kubectl create -f tests/ceph/job.yaml

  log "Verify that the test job was successful"
  pod=$(kubectl get pods --namespace default | awk "/ceph-test/{print \$1}")
  success=$(kubectl get jobs --namespace default -o json ceph-test-job | jq -r '.status.succeeded')
  while [[ "$success" == "null" || "$success" == "0" ]]; do
    log "test job is still running, waiting 10 seconds for it to complete"
    kubectl describe pods --namespace default $pod | awk '/Events:/{y=1;next}y'
    sleep 10
    success=$(kubectl get jobs --namespace default -o json ceph-test-job | jq -r '.status.succeeded')
  done
  log "test job succeeded"

  kubectl delete jobs ceph-test-job -n default
  kubectl delete pvc ceph-test
  log "Ceph setup complete!"
}

if [[ "$1" != "" ]]; then
  setup_ceph "$1" $2 $3 $4
else
  grep '#. ' $0
fi
