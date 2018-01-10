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
#. What this is: script to setup a kubernetes cluster with calico as cni
#. Prerequisites:
#. - Ubuntu Xenial or Centos 7 server for master and worker nodes
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
#. $ bash k8s-cluster.sh ceph "<nodes>" <cluster-net> <public-net> <ceph-mode> "<ceph_dev>"
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph-mode: "helm" or "baremetal"
#.     ceph-dev: space-separated list of disks (e.g. sda, sdb) to use on each
#.               worker, or folder (e.g. "/ceph")
#.               NOTE: ***DISK MUST NOT BE USED FOR ANY OTHER PURPOSE***
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

trap 'fail' ERR

function fail() {
  log $1
  exit 1
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo; echo "$f:$l ($(date)) $1"
  kubectl get pods --all-namespaces
}

function setup_prereqs() {
  log "Create prerequisite setup script"
  cat <<'EOG' >~/prereqs.sh
#!/bin/bash
# Basic server pre-reqs
function wait_dpkg() {
  # TODO: workaround for "E: Could not get lock /var/lib/dpkg/lock - open (11: Resource temporarily unavailable)"
  echo; echo "waiting for dpkg to be unlocked"
  while sudo fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; do
    sleep 1
  done
}
dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}' | sed 's/"//g')
if [[ $(grep -c $HOSTNAME /etc/hosts) -eq 0 ]]; then
  echo; echo "prereqs.sh: ($(date)) Add $HOSTNAME to /etc/hosts"
  # have to add "/sbin" to path of IP command for centos
  echo "$(/sbin/ip route get 8.8.8.8 | awk '{print $NF; exit}') $HOSTNAME" \
    | sudo tee -a /etc/hosts
fi
if [[ "$dist" == "ubuntu" ]]; then
  # Per https://kubernetes.io/docs/setup/independent/install-kubeadm/
  echo; echo "prereqs.sh: ($(date)) Basic prerequisites"

  wait_dpkg; sudo apt-get update
  wait_dpkg; sudo apt-get upgrade -y
  echo; echo "prereqs.sh: ($(date)) Install latest docker"
  wait_dpkg; sudo apt-get install -y docker.io
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
  sudo apt-get install -y jq
  if [[ "$(sudo ufw status)" == "Status: active" ]]; then
    echo; echo "prereqs.sh: ($(date)) Set firewall rules"
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
else
  echo; echo "prereqs.sh: ($(date)) Basic prerequisites"
  sudo yum install -y epel-release
  sudo yum update -y
  sudo yum install -y wget git
  echo; echo "prereqs.sh: ($(date)) Install latest docker"
  # per https://docs.docker.com/engine/installation/linux/docker-ce/centos/#install-from-a-package
  sudo yum install -y docker
  sudo systemctl enable docker
  sudo systemctl start docker
#  wget https://download.docker.com/linux/centos/7/x86_64/stable/Packages/docker-ce-17.09.0.ce-1.el7.centos.x86_64.rpm
#  sudo yum install -y docker-ce-17.09.0.ce-1.el7.centos.x86_64.rpm
#  sudo systemctl start docker
  echo; echo "prereqs.sh: ($(date)) Install kubectl, kubelet, kubeadm"
  cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
  sudo setenforce 0
  sudo yum install -y kubelet kubeadm kubectl
  sudo systemctl enable kubelet
  sudo systemctl start kubelet
  echo; echo "prereqs.sh: ($(date)) Install jq for API output parsing"
  sudo yum install -y jq  
  echo; echo "prereqs.sh: ($(date)) Set firewall rules"
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
  sudo sysctl --system
fi
EOG
}

function setup_k8s_master() {
  log "Setting up kubernetes master"
  setup_prereqs

  # Install master
  bash ~/prereqs.sh master
  # per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
  # If the following command fails, run "kubeadm reset" before trying again
  # --pod-network-cidr=192.168.0.0/16 is required for calico; this should not 
  # conflict with your server network interface subnets
  log "Reset kubeadm in case pre-existing cluster"
  sudo kubeadm reset
  # Start cluster
  log "Start the cluster"
  sudo kubeadm init --pod-network-cidr=192.168.0.0/16 >>/tmp/kubeadm.out
  cat /tmp/kubeadm.out
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  log "Cluster join command for manual use if needed: $k8s_joincmd"
  mkdir -p $HOME/.kube
  sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  # Deploy pod network
  log "Deploy calico as CNI"
  # Updated to deploy Calico 2.6 per the create-cluster-kubeadm guide above
  #  kubectl apply -f http://docs.projectcalico.org/v2.4/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml
  kubectl apply -f https://docs.projectcalico.org/v2.6/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml

  # TODO: document process dependency
  # Failure to wait for all calico pods to be running can cause the first worker
  # to be incompletely setup. Symptom is that node_ports cannot be routed
  # via that node (no response - incoming SYN packets are dropped). 
  log "Wait for calico pods to be Running"
  # calico-etcd, calico-kube-controllers, calico-node
  pods=$(kubectl get pods --namespace kube-system | grep -c calico)
  while [[ $pods -lt 3 ]]; do
    log "all calico pods are not yet created. Waiting 10 seconds"
    sleep 10
    pods=$(kubectl get pods --namespace kube-system | grep -c calico)
  done
  
  pods=$(kubectl get pods --all-namespaces | awk '/calico/ {print $2}')
  for pod in $pods; do
    status=$(kubectl get pods --all-namespaces | awk "/$pod/ {print \$4}")
    while [[ "$status" != "Running" ]]; do
      log "$pod status is $status. Waiting 10 seconds"
      sleep 10
      status=$(kubectl get pods --all-namespaces | awk "/$pod/ {print \$4}")
    done
    log "$pod status is $status"
  done

  log "Wait for kubedns to be Running"
  kubedns=$(kubectl get pods --all-namespaces | awk '/kube-dns/ {print $4}')
  while [[ "$kubedns" != "Running" ]]; do
    log "kube-dns status is $kubedns. Waiting 60 seconds"
    sleep 60
    kubedns=$(kubectl get pods --all-namespaces | awk '/kube-dns/ {print $4}')
  done
  log "kube-dns status is $kubedns"

  log "Allow pod scheduling on master (nodeSelector will be used to limit them)"
  kubectl taint node $HOSTNAME node-role.kubernetes.io/master:NoSchedule-

  log "Label node $HOSTNAME as 'role=master'"
  kubectl label nodes $HOSTNAME role=master
}

function setup_k8s_workers() {
  workers="$1"
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  log "Installing workers at $1 with joincmd: $k8s_joincmd"

# TODO: kubeadm reset below is workaround for 
# Ubuntu: "[preflight] Some fatal errors occurred: /var/lib/kubelet is not empty"
# per https://github.com/kubernetes/kubeadm/issues/1
# Centos: "Failed to start ContainerManager failed to initialize top
# level QOS containers: root container /kubepods doesn't exist"
  tee start_worker.sh <<EOF
sudo kubeadm reset
sudo $k8s_joincmd
EOF

# process below is serial for now; when workers are deployed in parallel,
# sometimes calico seems to be incompletely setup at some workers. symptoms
# similar to as noted for the "wait for calico" steps above.
  for worker in $workers; do
    host=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $USER@$worker hostname)
    log "Install worker at $worker hostname $host"
    if ! scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ~/prereqs.sh $USER@$worker:/home/$USER/. ; then
      fail "Failed copying setup files to $worker"
    fi
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      $USER@$worker bash prereqs.sh
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ~/k8s_env.sh \
      $USER@$worker:/home/$USER/.
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      start_worker.sh $USER@$worker:/home/$USER/.
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      $USER@$worker bash start_worker.sh

    log "checking that node $host is 'Ready'"
    status=$(kubectl get nodes | awk "/$host/ {print \$2}")
    while [[ "$status" != "Ready" ]]; do
      log "node $host is \"$status\", waiting 10 seconds"
      status=$(kubectl get nodes | awk "/$host/ {print \$2}")
      ((tries++))
      if [[ tries -gt 18 ]]; then
        log "node $host is \"$status\" after 3 minutes; resetting kubeadm"
        ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
          $USER@$worker bash start_worker.sh
        tries=1
      fi
      sleep 10
    done
    log "node $host is 'Ready'."
    log "Label node $host as 'worker'"
    kubectl label nodes $host role=worker
  done

  log "***** kube proxy pods *****"
  pods=$(kubectl get pods --all-namespaces | awk '/kube-proxy/ {print $2}')
  for pod in $pods; do
    echo; echo "**** $pod ****"
    kubectl describe pods --namespace kube-system $pod
    echo; echo "**** $pod logs ****"
    kubectl logs --namespace kube-system $pod
  done

  log "Cluster is ready (all nodes in 'kubectl get nodes' show as 'Ready')."
}

function setup_ceph() {
  # TODO: use labels to target ceph nodes
  if [[ "$4" == "helm" ]]; then
    source ./ceph-helm.sh "$1" $2 $3 "$5"
  else
    source ./ceph-baremetal.sh "$1" $2 $3 "$5"
  fi
}

dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}' | sed 's/"//g')

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
    setup_ceph "$2" $3 $4 $5 "$6"
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
