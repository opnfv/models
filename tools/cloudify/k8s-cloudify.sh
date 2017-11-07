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
#.   $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#.   $ scp -r ~/models/tools/cloudify ubuntu@<k8s-master>:/home/ubuntu/.
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ ssh -x ubuntu@<k8s-master> cloudify/k8s-cloudify.sh prereqs
#.     prereqs: installs prerequisites and configures ubuntu user for kvm use
#.   $ ssh -x ubuntu@<k8s-master> bash cloudify/k8s-cloudify.sh setup
#.     setup: installs cloudify CLI and Manager
#.   $ source ~/models/tools/cloudify/k8s-cloudify.sh demo <start|stop> <k8s-master>
#.     demo: control demo blueprint
#.     start|stop: start or stop the demo
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ ssh -x ubuntu@<k8s-master> bash cloudify/k8s-cloudify.sh clean
#.     clean: uninstalls cloudify CLI and Manager

#. Status: this is a work in progress, under test.

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo ""
  echo "$f:$l ($(date)) $1"
}

function prereqs() {
  log "Install prerequisites"
  sudo apt-get install -y virtinst qemu-kvm libguestfs-tools virtualenv git \
    python-pip
  log "Setup $USER for kvm use"
  # Per http://libguestfs.org/guestfs-faq.1.html
  # workaround for virt-customize warning: libguestfs: warning: current user is not a member of the KVM group (group ID 121). This user cannot access /dev/kvm, so libguestfs may run very slowly. It is recommended that you 'chmod 0666 /dev/kvm' or add the current user to the KVM group (you might need to log out and log in again).
  # Also see: https://help.ubuntu.com/community/KVM/Installation
  # also to avoid permission denied errors in guestfish, from http://manpages.ubuntu.com/manpages/zesty/man1/guestfs-faq.1.html
  sudo usermod -a -G kvm $USER
  sudo chmod 0644 /boot/vmlinuz*
  log "Clone repo"
}

function setup () {
  cd ~/cloudify
  log "Setup Cloudify-CLI"
  # Per http://docs.getcloudify.org/4.1.0/installation/bootstrapping/#installing-cloudify-manager-in-an-offline-environment
  wget -q http://repository.cloudifysource.org/cloudify/17.9.21/community-release/cloudify-cli-community-17.9.21.deb
  # Installs into /opt/cfy/
  sudo dpkg -i cloudify-cli-community-17.9.21.deb
  export MANAGER_BLUEPRINTS_DIR=/opt/cfy/cloudify-manager-blueprints
  virtualenv ~/cloudify/env
  source ~/cloudify/env/bin/activate

  log "Setup Cloudify-Manager"
  # to start over
  # sudo virsh destroy cloudify-manager; sudo virsh undefine cloudify-manager
  wget -q http://repository.cloudifysource.org/cloudify/17.9.21/community-release/cloudify-manager-community-17.9.21.qcow2
  # nohup and redirection of output is a workaround for some issue with virt-install never outputting anything beyond "Creadint domain..." and thus not allowing the script to continue.
  nohup virt-install --connect qemu:///system --virt-type kvm \
    --name cloudify-manager --vcpus 4 --memory 16192 \
    --disk cloudify-manager-community-17.9.21.qcow2 --import \
    --network network=default --os-type=linux  \
    --os-variant=rhel7 > /dev/null 2>&1 &

  VM_IP=""
  n=0
  while [[ "x$VM_IP" == "x" ]]; do
    log "$n minutes so far; waiting 60 seconds for cloudify-manager IP to be assigned"
    sleep 60
    ((n++))
    VM_MAC=$(virsh domiflist cloudify-manager | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
    VM_IP=$(/usr/sbin/arp -e | grep ${VM_MAC} | awk {'print $1'})
  done
  log "cloudify-manager IP=$VM_IP"
  while ! cfy profiles use $VM_IP -u admin -p admin -t default_tenant ; do
    log "waiting 60 seconds for cloudify-manager API to be active"
    sleep 60
  done
  cfy status

  log "Install Cloudify Kubernetes Plugin"
  # Per http://docs.getcloudify.org/4.1.0/plugins/container-support/
  # Per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin
  pip install kubernetes wagon
  # From https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/releases
  wget -q https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/releases/download/1.2.1/cloudify_kubernetes_plugin-1.2.1-py27-none-linux_x86_64-centos-Core.wgn
  # For Cloudify-CLI per http://docs.getcloudify.org/4.1.0/plugins/using-plugins/
  wagon install  \
    cloudify_kubernetes_plugin-1.2.1-py27-none-linux_x86_64-centos-Core.wgn
  # For Cloudify-Manager per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/blob/master/examples/persistent-volumes-blueprint.yaml
  cfy plugins upload cloudify_kubernetes_plugin-1.2.1-py27-none-linux_x86_64-centos-Core.wgn

  log "Create secrets for kubernetes as referenced in blueprints"
  cfy secrets create -s $(grep server ~/.kube/config | awk -F '/' '{print $3}' \
    | awk -F ':' '{print $1}') kubernetes_master_ip
  cfy secrets create -s $(grep server ~/.kube/config | awk -F '/' '{print $3}' \
    | awk -F ':' '{print $2}') kubernetes_master_port
  cfy secrets create -s  \
    $(grep 'certificate-authority-data: ' ~/.kube/config |  \
    awk -F ' ' '{print $2}') kubernetes_certificate_authority_data
  cfy secrets create -s $(grep 'client-certificate-data: ' ~/.kube/config \
    | awk -F ' ' '{print $2}') kubernetes-admin_client_certificate_data
  cfy secrets create -s $(grep 'client-key-data: ' ~/.kube/config \
    | awk -F ' ' '{print $2}') kubernetes-admin_client_key_data
  cfy secrets list

  # get manager VM IP
  VM_MAC=$(sudo virsh domiflist cloudify-manager | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
  VM_IP=$(/usr/sbin/arp -e | grep ${VM_MAC} | awk {'print $1'})

  # get host IP
  HOST_IP=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')

  # Forward host port 80 to VM
  sudo iptables -t nat -I PREROUTING -p tcp -d $HOST_IP --dport 80 -j DNAT --to-destination $VM_IP:80
  sudo iptables -I FORWARD -m state -d $VM_IP/32 --state NEW,RELATED,ESTABLISHED -j ACCEPT
  sudo iptables -t nat -A POSTROUTING -j MASQUERADE

  while ! curl -u admin:admin --header 'Tenant: default_tenant' http://$HOST_IP/api/v3.1/status ; do
    log "Cloudify API is not yet responding, waiting 10 seconds"
    sleep 10
  done
  log "Cloudify CLI config is at ~/.cloudify/config.yaml"
  log "Cloudify CLI log is at ~/.cloudify/logs/cli.log"
  log "Cloudify API access example: curl -u admin:admin --header 'Tenant: default_tenant' http://$HOST_IP/api/v3.1/status"
  log "Cloudify setup is complete!"
}

function demo() {
  # Per http://docs.getcloudify.org/4.1.0/plugins/container-support/
  # Per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin
  # Also per guidance at https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/issues/18
#  echo "master-ip: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $1}')" >~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "master-port: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $2}')" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "file_content:" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  sed 's/^/  /' ~/.kube/config | tee -a ~/cloudify/blueprints/k8s-hello-world/inputs.yaml
  manager_ip=$2
  cd ~/models/tools/cloudify/blueprints

  if [[ "$1" == "start" ]]; then
    log "copy kube config from k8s master for insertion into blueprint"
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  \
      ubuntu@$manager_ip:/home/ubuntu/.kube/config k8s-hello-world/kube.config

    log "package the blueprint"
    # CLI: cfy blueprints package -o ~/cloudify/blueprints/k8s-hello-world ~/cloudify/blueprints/k8s-hello-world
    tar ckf /tmp/blueprint.tar k8s-hello-world

    log "upload the blueprint"
    # CLI: cfy blueprints upload -t default_tenant -b k8s-hello-world ~/cloudify/blueprints/k8s-hello-world.tar.gz
    curl -X PUT -u admin:admin --header 'Tenant: default_tenant'  \
      --header "Content-Type: application/octet-stream"  \
      http://$manager_ip/api/v3.1/blueprints/k8s-hello-world?application_file_name=blueprint.yaml  \
      -T /tmp/blueprint.tar | jq

    log "create a deployment for the blueprint"
    # CLI: cfy deployments create -t default_tenant -b k8s-hello-world k8s-hello-world
    curl -X PUT -u admin:admin --header 'Tenant: default_tenant'  \
      --header "Content-Type: application/json"  \
      -d '{"blueprint_id": "k8s-hello-world", "inputs": {}}'  \
      http://$manager_ip/api/v3.1/deployments/k8s-hello-world
    sleep 10

    # CLI: cfy workflows list -d k8s-hello-world

    log "install the deployment pod and service"
    # CLI: cfy executions start install -d k8s-hello-world
    curl -X POST -u admin:admin --header 'Tenant: default_tenant'  \
      --header "Content-Type: application/json"  \
      -d '{"deployment_id":"k8s-hello-world", "workflow_id":"install"}'  \
      http://$manager_ip/api/v3.1/executions | jq

    log "get the service's assigned node_port"
    port=$(curl -u admin:admin --header 'Tenant: default_tenant'  \
      http://$manager_ip/api/v3.1/node-instances |  \
      jq -r '.items[0].runtime_properties.kubernetes.spec.ports[0].node_port')
    while [[ "$port" == "null" ]]; do
      sleep 10
      port=$(curl -u admin:admin --header 'Tenant: default_tenant'  \
        http://$manager_ip/api/v3.1/node-instances |  \
        jq -r '.items[0].runtime_properties.kubernetes.spec.ports[0].node_port')
    done
    log "node_port = $port"

    log "verify service is responding"
    while ! curl http://$manager_ip:$port ; do
      log "nginx service is not yet responding at http://$manager_ip:$port, waiting 10 seconds"
      sleep 10
    done
    log "service is active at http://$manager_ip:$port"
  else
    log "uninstall the service"
    curl -X POST -u admin:admin --header 'Tenant: default_tenant' \
      --header "Content-Type: application/json" \
      -d '{"deployment_id":"k8s-hello-world", "workflow_id":"uninstall", "force": "true"}' \
      http://$manager_ip/api/v3.1/executions
    count=1
    state=$(curl -u admin:admin --header 'Tenant: default_tenant' \
      http://$manager_ip/api/v3.1/node-instances | jq -r '.items[0].state')
    while [[ "$state" == "deleting" ]]; do
      if [[ $count > 10 ]]; then
        log "try to cancel all current executions"
        exs=$(curl -u admin:admin --header 'Tenant: default_tenant' \
          http://$manager_ip/api/v3.1/executions | jq -r '.items[].status')
        i=0
        for status in $exs; do
          log "checking execution $i in state $status"
          if [[ "$status" == "started" ]]; then
            id=$(curl -u admin:admin --header 'Tenant: default_tenant' \
              http://$manager_ip/api/v3.1/executions | jq -r ".items[$i].id")
            curl -X POST -u admin:admin --header 'Tenant: default_tenant' \
              --header "Content-Type: application/json" \
              -d '{"deployment_id": "k8s-hello-world", "action": "cancel"}' \
              http://$manager_ip/api/v3.1/executions/$id
          fi
          ((i++))
        done
        log "force delete deployment via cfy CLI"
        ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
          ubuntu@$manager_ip cfy deployment delete -f \
          -t default_tenant k8s-hello-world
      fi
      ((count ++))
      state=$(curl -u admin:admin --header 'Tenant: default_tenant' \
        http://$manager_ip/api/v3.1/node-instances | jq -r '.items[0].state')
    done

    log "delete the deployment"
    curl -X DELETE -u admin:admin --header 'Tenant: default_tenant' \
      http://$manager_ip/api/v3.1/deployments/k8s-hello-world
    sleep 10
    log "delete the blueprint"
    curl -X DELETE -u admin:admin --header 'Tenant: default_tenant' \
      http://$manager_ip/api/v3.1/blueprints/k8s-hello-world
    sleep 10
    log "verify the blueprint is deleted"
    curl -u admin:admin --header 'Tenant: default_tenant' \
      http://$manager_ip/api/v3.1/blueprints | jq
  fi

# API examples: use '| jq' to format JSON output
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/blueprints | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/deployments | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/executions | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/deployments | jq -r '.items[0].blueprint_id'
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/node-instances | jq
}

function clean () {
  log "Cleanup cloudify"
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
    demo $2 $3
    ;;
  "clean")
    clean
    ;;
  *)
    grep '#. ' $0
esac

