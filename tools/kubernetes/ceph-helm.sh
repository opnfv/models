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
#. Intended to be called from k8s-cluster.sh in this folder. To run directly:
#. $ bash ceph-helm.sh "<nodes>" <cluster-net> <public-net> "<ceph_dev>"
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph-dev: space-separated list of disks (e.g. sda, sdb) to use on each
#.               worker
#.               NOTE: ***DISK MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.
#. Status: work in progress, incomplete
#

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

function make_ceph_setup() {
  tee ~/ceph_setup.sh <<'EOG'
#!/bin/bash
# Basic server pre-reqs
dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}' | sed 's/"//g')
if [[ "$dist" == "ubuntu" ]]; then
  sudo apt-get install -y ceph ceph-common
else
  # per http://docs.ceph.com/docs/master/install/get-packages/
  sudo tee /etc/yum.repos.d/ceph.repo <<'EOF'
[ceph]
name=Ceph packages for $basearch
baseurl=https://download.ceph.com/rpm-luminous/el7/x86_64
enabled=1
priority=2
gpgcheck=1
gpgkey=https://download.ceph.com/keys/release.asc

[ceph-noarch]
name=Ceph noarch packages
baseurl=https://download.ceph.com/rpm-luminous/el7/noarch
enabled=1
priority=2
gpgcheck=1
gpgkey=https://download.ceph.com/keys/release.asc

[ceph-source]
name=Ceph source packages
baseurl=https://download.ceph.com/rpm-luminous/el7/SRPMS
enabled=0
priority=2
gpgcheck=1
gpgkey=https://download.ceph.com/keys/release.asc
EOF
  # TODO: find out why package is unsigned and thus need --nogpgcheck
  sudo rpm --import 'https://download.ceph.com/keys/release.asc'
  sudo yum install --nogpgcheck -y ceph ceph-common
fi
EOG
}

function setup_ceph() {
  nodes="$1"
  private_net=$2
  public_net=$3
  dev="$4"

  log "Install ceph and ceph-common"
  make_ceph_setup
  bash ~/ceph_setup.sh
	
  # per https://github.com/att/netarbiter/tree/master/sds/ceph-docker/examples/helm
  log "Clone netarbiter"
  git clone https://github.com/att/netarbiter.git

  if [[ "$dist" != "ubuntu" ]]; then
    log "Update ceph-helm chart to point to centos images"
    sed -i -- 's~daemon: docker.io/knowpd~#daemon: docker.io/knowpd~' \
      netarbiter/sds/ceph-docker/examples/helm/ceph/values.yaml
    sed -i -- 's~#daemon: docker.io/ceph~daemon: docker.io/ceph~' \
      netarbiter/sds/ceph-docker/examples/helm/ceph/values.yaml
    sed -i -- 's~ceph_init: docker.io/knowpd~#ceph_init: docker.io/knowpd~' \
      netarbiter/sds/ceph-docker/examples/helm/ceph/values.yaml
    sed -i -- 's~#ceph_init: docker.io/kollakube~ceph_init: docker.io/kollakube~' \
      netarbiter/sds/ceph-docker/examples/helm/ceph/values.yaml
  fi

  log "Prepare a ceph namespace in your K8s cluster"
  cd netarbiter/sds/ceph-docker/examples/helm
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

  i=1
  for node in $nodes; do
    disk=$(echo "$dev" | cut -d ' ' -f $i)
    log "install ceph, setup resolv.conf, zap disk $disk for $node"
    if [[ "$dist" == "ubuntu" ]]; then
      ssh -x -o StrictHostKeyChecking=no $USER@$node \
        sudo apt-get install -y ceph ceph-common
    else
      scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ~/ceph_setup.sh $USER@$node:/home/$USER/.
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        $USER@$node bash /home/$USER/ceph_setup.sh
    fi

    ssh -x -o StrictHostKeyChecking=no $USER@$node <<EOG
cat <<EOF | sudo tee /etc/resolv.conf
nameserver $kubedns
search ceph.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
EOF
sudo ceph-disk zap /dev/$disk
EOG
    log "Run ceph-osd at $node"
    name=$(ssh -x -o StrictHostKeyChecking=no $USER@$node hostname)
    # TODO: try sudo due to error
    # command_check_call: Running command: /usr/bin/ceph-osd --cluster ceph --mkfs -i 0 ...
    # TODO: leave out sudo... resulted in "./helm-install-ceph-osd.sh: line 40: helm: command not found"
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      $USER@$node sudo chmod 777 /var/lib/ceph/tmp
    ./helm-install-ceph-osd.sh $name /dev/$disk
  done

  for node in $nodes; do
    name=$(ssh -x -o StrictHostKeyChecking=no $USER@$node hostname)
    pod=$(kubectl get pods --namespace ceph | awk "/$name/{print \$1}")
    while [[ "$pod" == "" ]]; do
      log "ceph-osd pod not yet created at node $name, waiting 10 seconds"
      kubectl get pods --namespace ceph
      sleep 10
      pod=$(kubectl get pods --namespace ceph | awk "/$name/{print \$1}")
    done
      
    log "wait till ceph-osd pod $pod is Running at node $name"
    status=$(kubectl get pods --namespace ceph $pod | awk "/$pod/ {print \$3}")
    while [[ "x$status" != "xRunning" ]]; do
      log "$pod status is $status. Waiting 10 seconds for it to be Running."
      sleep 10
      status=$(kubectl get pods --namespace ceph $pod | awk "/$pod/ {print \$3}")
      kubectl get pods --namespace ceph
    done
    log "$pod status is $status."
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
  setup_ceph "$1" $2 $3 "$4"
else
  grep '#. ' $0
fi
