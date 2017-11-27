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
#. - Ubuntu xenial server for master and worker nodes
#. - key-based auth setup for ssh/scp between master and worker nodes
#. - 192.168.0.0/16 should not be used on your server network interface subnets
#. Usage:
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ cd ~/models/tools/kubernetes
#. $ bash k8s-cluster.sh master
#. $ bash k8s-cluster.sh workers "<nodes>"
#.     nodes: space-separated list of ceph node IPs
#. $ bash k8s-cluster.sh helm
#.     Setup helm as kubernetes app management tool. Note this is a
#.     prerequisite for selecting "helm" ceph-mode as described below.
#. $ bash k8s-cluster.sh ceph "<nodes>" <cluster-net> <public-net> <ceph-mode> [ceph_dev]
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph-mode: "helm" or "baremetal"
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.               if not provided, ceph data will be stored on osd nodes in /ceph
#. $ bash k8s-cluster.sh all "<nodes>" <cluster-net> <public-net> <ceph-mode> [ceph_dev]
#.     Runs all the steps above, including starting dokuwiki demo app.
#. $ bash k8s-cluster.sh demo <start|stop> <chart>
#.     Start or stop demo helm charts. See helm-tools.sh for chart options.
#.
#. When deployment is complete, the k8s API will be available at the master
#. node, e.g. via: curl -k https://<master-ip>:6443/api/v1
#.
#. Status: work in progress, incomplete
#

function fail() {
  log $1
  exit 1
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo; echo "$f:$l ($(date)) $1"
}

function setup_prereqs() {
  log "Create prerequisite setup script"
  cat <<'EOG' >/tmp/prereqs.sh
#!/bin/bash
# Basic server pre-reqs
echo; echo "prereqs.sh: ($(date)) Basic prerequisites"
sudo apt-get update
sudo apt-get upgrade -y
if [[ $(grep -c $HOSTNAME /etc/hosts) -eq 0 ]]; then
  echo; echo "prereqs.sh: ($(date)) Add $HOSTNAME to /etc/hosts"
  echo "$(ip route get 8.8.8.8 | awk '{print $NF; exit}') $HOSTNAME" \
    | sudo tee -a /etc/hosts
fi
echo; echo "prereqs.sh: ($(date)) Install latest docker"
sudo apt-get install -y docker.io
# Alternate for 1.12.6
#sudo apt-get install -y libltdl7
#wget https://packages.docker.com/1.12/apt/repo/pool/main/d/docker-engine/docker-engine_1.12.6~cs8-0~ubuntu-xenial_amd64.deb
#sudo dpkg -i docker-engine_1.12.6~cs8-0~ubuntu-xenial_amd64.deb
sudo service docker restart
echo; echo "prereqs.sh: ($(date)) Get k8s packages"
export KUBE_VERSION=1.7.5
# per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
# Install kubelet, kubeadm, kubectl per https://kubernetes.io/docs/setup/independent/install-kubeadm/
sudo apt-get update && sudo apt-get install -y apt-transport-https
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
echo; echo "prereqs.sh: ($(date)) Install kubectl, kubelet, kubeadm"
sudo apt-get -y install --allow-downgrades kubectl=${KUBE_VERSION}-00 \
  kubelet=${KUBE_VERSION}-00 kubeadm=${KUBE_VERSION}-00
echo; echo "prereqs.sh: ($(date)) Install jq for API output parsing"
sudo apt-get -y install jq
echo; echo "prereqs.sh: ($(date)) Set firewall rules"
# Per https://kubernetes.io/docs/setup/independent/install-kubeadm/
if [[ "$(sudo ufw status)" == "Status: active" ]]; then
  if [[ "$1" == "master" ]]; then
    sudo ufw allow 6443/tcp
    sudo ufw allow 2379:2380/tcp
    sudo ufw allow 10250/tcp
    sudo ufw allow 10251/tcp
    sudo ufw allow 10252/tcp
    sudo ufw allow 10255/tcp
  else
    sudo ufw allow 10250/tcp
    sudo ufw allow 10255/tcp
    sudo ufw allow 30000:32767/tcp
  fi
fi
# TODO: fix need for this workaround: disable firewall since the commands 
# above do not appear to open the needed ports, even if ufw is inactive
# (symptom: nodeport requests fail unless sent from within the cluster or
# to the node IP where the pod is assigned) issue discovered ~11/16/17
sudo ufw disable
EOG
}

function setup_k8s_master() {
  log "Setting up kubernetes master"
  setup_prereqs

  # Install master
  bash /tmp/prereqs.sh master
  # per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
  # If the following command fails, run "kubeadm reset" before trying again
  # --pod-network-cidr=192.168.0.0/16 is required for calico; this should not 
  # conflict with your server network interface subnets
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
  # Updated to deploy Calico 2.6 per the create-cluster-kubeadm guide above
  #  sudo kubectl apply -f http://docs.projectcalico.org/v2.4/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml
  sudo kubectl apply -f https://docs.projectcalico.org/v2.6/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml
}

function setup_k8s_workers() {
  workers="$1"
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  log "Installing workers at $1 with joincmd: $k8s_joincmd"

  setup_prereqs

  kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
  while [[ "$kubedns" != "Running" ]]; do
    log "kube-dns status is $kubedns. Waiting 60 seconds for it to be 'Running'"
    sleep 60
    kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
  done
  log "kube-dns status is $kubedns"

  for worker in $workers; do
    log "Install worker at $worker"
    if ! scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      /tmp/prereqs.sh ubuntu@$worker:/tmp/prereqs.sh ; then
      fail "Failed copying setup files to $worker"
    fi
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ~/k8s_env.sh \
      ubuntu@$worker:/home/ubuntu/.
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$worker bash /tmp/prereqs.sh worker
    # Workaround for "[preflight] Some fatal errors occurred: /var/lib/kubelet
    # is not empty" per https://github.com/kubernetes/kubeadm/issues/1
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$worker sudo kubeadm reset
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$worker sudo $k8s_joincmd
  done

  log "Cluster is ready when all nodes in 'kubectl get nodes' show as 'Ready'."
}

function setup_ceph() {
  if [[ "$4" == "helm" ]]; then
    source ./ceph-helm.sh "$1" $2 $3 $5
  else
    source ./ceph-baremetal.sh "$1" $2 $3 $5
  fi
}

workers="$2"
privnet=$3
pubnet=$4
ceph_mode=$5
ceph_dev=$6

export WORK_DIR=$(pwd)
case "$1" in
  master)
    setup_k8s_master
    ;;
  workers)
    setup_k8s_workers "$2"
    ;;
  ceph)
    setup_ceph "$2" $3 $4 $5 $6
    ;;
  helm)
    bash ./helm-tools.sh setup
    ;;
  demo)
    if [[ "$2" == "start" ]]; then
      bash ./helm-tools.sh start $3
    else
      bash ./helm-tools.sh stop $3
    fi
    ;;
  all)
    setup_k8s_master
    setup_k8s_workers "$2"
    bash ./helm-tools.sh setup
    bash ./helm-tools.sh start nginx
    bash ./helm-tools.sh stop nginx
    setup_ceph "$2" $3 $4 $5 $6
    bash ./helm-tools.sh start dokuwiki
    ;;
  clean)
    # TODO
    ;;
  *)
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then grep '#. ' $0; fi
esac
