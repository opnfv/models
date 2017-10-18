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
#. What this is: Setup script for Cloudify use with Kubernetes.
#. Prerequisites: 
#. - Kubernetes cluster installed per k8s-cluster.sh (in this repo)
#. Usage:
#.   From a server with access to the kubernetes master node:
#.   $ wget https://raw.githubusercontent.com/blsaws/nancy/master/kubernetes/k8s-cloudify.sh
#.   $ scp k8s-cloudify.sh ubuntu@<k8s-master>:/home/ubuntu/k8s-cloudify.sh 
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ ssh -x ubuntu@<k8s-master> k8s-cloudify.sh prereqs
#.     prereqs: installs prerequisites and configures ubuntu user for kvm use
#.   $ ssh -x ubuntu@<k8s-master> bash k8s-cloudify.sh [setup|clean]
#. Status: this is a work in progress, under test.

function prereqs() {
  echo "${FUNCNAME[0]}: Install prerequisites"
  sudo apt-get install -y virtinst qemu-kvm libguestfs-tools virtualenv git python-pip
  echo "${FUNCNAME[0]}: Setup $USER for kvm use"
  # Per http://libguestfs.org/guestfs-faq.1.html
  # workaround for virt-customize warning: libguestfs: warning: current user is not a member of the KVM group (group ID 121). This user cannot access /dev/kvm, so libguestfs may run very slowly. It is recommended that you 'chmod 0666 /dev/kvm' or add the current user to the KVM group (you might need to log out and log in again). 
  # Also see: https://help.ubuntu.com/community/KVM/Installation
  # also to avoid permission denied errors in guestfish, from http://manpages.ubuntu.com/manpages/zesty/man1/guestfs-faq.1.html
  sudo usermod -a -G kvm $USER
  sudo chmod 0644 /boot/vmlinuz*
  echo "${FUNCNAME[0]}: Clone repo"
}

function setup () {
  rm -r ~/cloudify
  mkdir -p ~/cloudify
  cd ~/cloudify
  echo "${FUNCNAME[0]}: Setup Cloudify-CLI"
  # Per http://docs.getcloudify.org/4.1.0/installation/bootstrapping/#installing-cloudify-manager-in-an-offline-environment
  wget -q http://repository.cloudifysource.org/cloudify/17.9.21/community-release/cloudify-cli-community-17.9.21.deb
  # Installs into /opt/cfy/
  sudo dpkg -i cloudify-cli-community-17.9.21.deb
  export MANAGER_BLUEPRINTS_DIR=/opt/cfy/cloudify-manager-blueprints
  virtualenv ~/cloudify/env
  source ~/cloudify/env/bin/activate

  echo "${FUNCNAME[0]}: Setup Cloudify-Manager"
  # to start over
  # sudo virsh destroy cloudify-manager; sudo virsh undefine cloudify-manager
  wget -q http://repository.cloudifysource.org/cloudify/17.9.21/community-release/cloudify-manager-community-17.9.21.qcow2
  # nohup and redirection of output is a workaround for some issue with virt-install never outputting anything beyond "Creadint domain..." and thus not allowing the script to continue.
  nohup virt-install --connect qemu:///system --virt-type kvm --name cloudify-manager --vcpus 4 --memory 16192 --disk cloudify-manager-community-17.9.21.qcow2 --import --network network=default --os-type=linux --os-variant=rhel7 > /dev/null 2>&1 &

  VM_IP=""
  n=0
  while [[ "x$VM_IP" == "x" ]]; do
    echo "${FUNCNAME[0]}: $n minutes so far; waiting 60 seconds for cloudify-manager IP to be assigned"
    sleep 60
    ((n++))
    VM_MAC=$(virsh domiflist cloudify-manager | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
    VM_IP=$(/usr/sbin/arp -e | grep ${VM_MAC} | awk {'print $1'})
  done
  echo "${FUNCNAME[0]}: cloudify-manager IP=$VM_IP"
  while ! cfy profiles use $VM_IP -u admin -p admin -t default_tenant ; do
    echo "${FUNCNAME[0]}: waiting 60 seconds for cloudify-manager API to be active"
    sleep 60
  done
  cfy status
  
  echo "${FUNCNAME[0]}: Install Cloudify Kubernetes Plugin"
  # Per http://docs.getcloudify.org/4.1.0/plugins/container-support/
  # Per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin
  pip install kubernetes wagon
  # From https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/releases
  wget -q https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/releases/download/1.2.1/cloudify_kubernetes_plugin-1.2.1-py27-none-linux_x86_64-centos-Core.wgn
  # For Cloudify-CLI per http://docs.getcloudify.org/4.1.0/plugins/using-plugins/
  wagon install cloudify_kubernetes_plugin-1.2.1-py27-none-linux_x86_64-centos-Core.wgn
  # For Cloudify-Manager per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/blob/master/examples/persistent-volumes-blueprint.yaml
  cfy plugins upload cloudify_kubernetes_plugin-1.2.1-py27-none-linux_x86_64-centos-Core.wgn

  mkdir ~/cloudify/blueprints

  echo "${FUNCNAME[0]}: Create secrets for kubernetes as referenced in blueprints"  
  cfy secrets create -s $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $1}') kubernetes_master_ip
  cfy secrets create -s $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $2}') kubernetes_master_port
  cfy secrets create -s $(grep 'certificate-authority-data: ' ~/.kube/config | awk -F ' ' '{print $2}') kubernetes_certificate_authority_data
  cfy secrets create -s $(grep 'client-certificate-data: ' ~/.kube/config | awk -F ' ' '{print $2}') kubernetes-admin_client_certificate_data
  cfy secrets create -s $(grep 'client-key-data: ' ~/.kube/config | awk -F ' ' '{print $2}') kubernetes-admin_client_key_data
  cfy secrets list

  echo "${FUNCNAME[0]}: Cloudify CLI config is at ~/.cloudify/config.yaml"
  echo "${FUNCNAME[0]}: Cloudify CLI log is at ~/.cloudify/logs/cli.log"
}

function demo() {
  # Per http://docs.getcloudify.org/4.1.0/plugins/container-support/
  # Per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin
  # Also per guidance at https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/issues/18
  mkdir -p ~/cloudify/blueprints/k8s-hello-world
  cp ~/nancy/cloudify/blueprints/k8s-hello-world.yaml ~/cloudify/blueprints/k8s-hello-world/blueprint.yaml
#  echo "master-ip: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $1}')" >~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "master-port: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $2}')" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "file_content:" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  sed 's/^/  /' ~/.kube/config | tee -a ~/cloudify/blueprints/k8s-hello-world/inputs.yaml
  cp ~/.kube/config ~/cloudify/blueprints/k8s-hello-world/kube.config

  cfy blueprints package -o ~/cloudify/blueprints/k8s-hello-world ~/cloudify/blueprints/k8s-hello-world
  cfy blueprints upload -t default_tenant -b k8s-hello-world ~/cloudify/blueprints/k8s-hello-world.tar.gz
  cfy deployments create -t default_tenant -b k8s-hello-world k8s-hello-world
  cfy workflows list -d k8s-hello-world
  cfy executions start install -d k8s-hello-world
  pod_ip=$(kubectl get pods --namespace default -o jsonpath='{.status.podIP}' nginx)
  while [[ "x$pod_ip" == "x" ]]; do
    echo "${FUNCNAME[0]}: nginx pod IP is not yet assigned, waiting 10 seconds"
    sleep 10
    pod_ip=$(kubectl get pods --namespace default -o jsonpath='{.status.podIP}' nginx)
  done
  while ! curl http://$pod_ip ; do
    echo "${FUNCNAME[0]}: nginx pod is not yet responding at http://$pod_ip, waiting 10 seconds"
    sleep 10
  done
  echo "${FUNCNAME[0]}: nginx pod is active at http://$pod_ip"
  curl http://$pod_ip
}

function clean () {
  echo "${FUNCNAME[0]}: Cleanup cloudify"
  # TODO
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$1" in
  "prereqs")
    prereqs
    ;;
  "setup")
    setup
    ;;
  "demo")
    demo
    ;;
  "clean")
    clean
    ;;
  *)
    grep '#. ' $0
esac

