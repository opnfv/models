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
# See the License for the specific language governing permissions and
# limitations under the License.
#
#. What this is: Setup script for Cloudify use with Kubernetes.
#. Prerequisites:
#. - OPNFV Models repo cloned into ~/models, i.e.
#.   git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. - Kubernetes cluster installed per tools/kubernetes/demo_deploy.sh and
#.   environment setup file ~/models/tools/k8s_env.sh as setup by demo_deploy.sh
#. Usage:
#.   From a server with access to the kubernetes master node:
#.   $ cd ~/models/tools/cloudify
#.   $ scp -r ~/models/tools/* <user>@<k8s-master>:/home/<user>/.
#.     <user>: username on the target host. Also used to indicate OS name.
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ ssh -x <user>@<k8s-master> cloudify/k8s-cloudify.sh prereqs
#.     <user>: username on the target host. Also used to indicate OS name.
#.     prereqs: installs prerequisites and configures <user> user for kvm use
#.   $ ssh -x <user>@<k8s-master> bash cloudify/k8s-cloudify.sh setup
#.     <user>: username on the target host. Also used to indicate OS name.
#.     setup: installs cloudify CLI and Manager
#.   $ bash k8s-cloudify.sh demo <start|stop>
#.     demo: control demo blueprint
#.     start|stop: start or stop the demo
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ bash k8s-cloudify.sh <start|stop> <name> <blueprint>
#.     start|stop: start or stop the blueprint
#.     name: name of the service in the blueprint
#.     blueprint: name of the blueprint folder (in current directory!)
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ bash k8s-cloudify.sh port <service> <k8s-master>
#.     port: find assigned node_port for service
#.     service: name of service e.g. nginx
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ ssh -x <user>@<k8s-master> bash cloudify/k8s-cloudify.sh clean
#.     <user>: username on the target host. Also used to indicate OS name.
#.     clean: uninstalls cloudify CLI and Manager

#. Status: this is a work in progress, under test.

function fail() {
  log "$1"
  exit 1
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo; echo "$f:$l ($(date)) $1"
}

function prereqs() {
  log "Install prerequisites"
  if [[ "$USER" == "ubuntu" ]]; then
    sudo apt-get install -y virtinst qemu-kvm libguestfs-tools virtualenv git \
      python-pip
  else
    # installing libvirt is needed to ensure default network is pre-created
    sudo yum install -y libvirt 
    sudo virsh net-define /usr/share/libvirt/networks/default.xml
    sudo yum install -y virt-install
    sudo yum install -y qemu-kvm libguestfs-tools git python-pip
    sudo pip install virtualenv
  fi
  log "Setup $USER for kvm use"
  # Per http://libguestfs.org/guestfs-faq.1.html
  # workaround for virt-customize warning: libguestfs: warning: current user is not a member of the KVM group (group ID 121). This user cannot access /dev/kvm, so libguestfs may run very slowly. It is recommended that you 'chmod 0666 /dev/kvm' or add the current user to the KVM group (you might need to log out and log in again).
  # Also see: https://help.ubuntu.com/community/KVM/Installation
  # also to avoid permission denied errors in guestfish, from http://manpages.ubuntu.com/manpages/zesty/man1/guestfs-faq.1.html
  sudo usermod -a -G kvm $USER
  sudo chmod 0644 /boot/vmlinuz*
}

function setup () {
  cd ~/cloudify
  log "Setup Cloudify-CLI"
  # Per http://docs.getcloudify.org/4.1.0/installation/bootstrapping/#installing-cloudify-manager-in-an-offline-environment
  # Installs into /opt/cfy/
  if [[ "$k8s_user" == "ubuntu" ]]; then
    wget -q http://repository.cloudifysource.org/cloudify/17.9.21/community-release/cloudify-cli-community-17.9.21.deb
    sudo dpkg -i cloudify-cli-community-17.9.21.deb
  else
    wget -q http://repository.cloudifysource.org/cloudify/17.11.12/community-release/cloudify-cli-community-17.11.12.rpm
    sudo rpm -i cloudify-cli-community-17.11.12.rpm
  fi
  export MANAGER_BLUEPRINTS_DIR=/opt/cfy/cloudify-manager-blueprints
  virtualenv ~/cloudify/env
  source ~/cloudify/env/bin/activate

  log "Setup Cloudify-Manager"
  # to start over
  # sudo virsh destroy cloudify-manager; sudo virsh undefine cloudify-manager
  # centos: putting image in /tmp ensures qemu user can access it
  wget -q http://repository.cloudifysource.org/cloudify/17.9.21/community-release/cloudify-manager-community-17.9.21.qcow2 \
    -O /tmp/cloudify-manager-community-17.9.21.qcow2
  # TODO: centos needs this, else "ERROR    Failed to connect socket to '/var/run/libvirt/libvirt-sock': No such file or directory"
  sudo systemctl start libvirtd
  # TODO: centos needs sudo, else "ERROR    authentication unavailable: no polkit agent available to authenticate action 'org.libvirt.unix.manage'"
  # TODO: nohup and redirection of output needed else virt-install never outputs anything beyond "Creating domain..." and thus not allowing the script to continue.
  nohup sudo virt-install --connect qemu:///system --virt-type kvm \
    --name cloudify-manager --vcpus 4 --memory 16192 \
    --disk /tmp/cloudify-manager-community-17.9.21.qcow2 --import \
    --network network=default --os-type=linux  \
    --os-variant=rhel7 > /dev/null 2>&1 &

  VM_IP=""
  n=0
  while [[ "x$VM_IP" == "x" ]]; do
    log "$n minutes so far; waiting 60 seconds for cloudify-manager IP to be assigned"
    sleep 60
    ((n++))
    VM_MAC=$(sudo virsh domiflist cloudify-manager | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
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
  pip install wagon
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
  log "Setip iptables to forward $HOST_IP port 80 to Cloudify Manager VM at $VM_IP"
  sudo iptables -t nat -I PREROUTING -p tcp -d $HOST_IP --dport 80 -j DNAT --to-destination $VM_IP:80
  sudo iptables -I FORWARD -m state -d $VM_IP/32 --state NEW,RELATED,ESTABLISHED -j ACCEPT
  sudo iptables -t nat -A POSTROUTING -j MASQUERADE

# Access to the API via the primary interface, from the local host, is not
# working for some reason... skip this for now
#  while ! curl -u admin:admin --header 'Tenant: default_tenant' http://$HOST_IP/api/v3.1/status ; do
#    log "Cloudify API is not yet responding, waiting 10 seconds"
#    sleep 10
#  done
  log "Cloudify CLI config is at ~/.cloudify/config.yaml"
  log "Cloudify CLI log is at ~/.cloudify/logs/cli.log"
  log "Cloudify API access example: curl -u admin:admin --header 'Tenant: default_tenant' http://$HOST_IP/api/v3.1/status"
  log "Cloudify setup is complete!"
}

function service_port() {
  name=$1
  tries=6
  port="null"
  while [[ "$port" == "null" && $tries -gt 0 ]]; do
    curl -s -u admin:admin --header 'Tenant: default_tenant' \
      -o /tmp/json http://$manager_ip/api/v3.1/node-instances
    ni=$(jq -r '.items | length' /tmp/json)
    while [[ $ni -ge 0 ]]; do
      ((ni--))
      id=$(jq -r ".items[$ni].id" /tmp/json)
      if [[ $id == $name\_service* ]]; then
        port=$(jq -r ".items[$ni].runtime_properties.kubernetes.spec.ports[0].node_port" /tmp/json)
        echo $port
      fi
    done
    sleep 10
    ((tries--))
  done
  if [[ "$port" == "null" ]]; then
    jq -r '.items' /tmp/json
    fail "node_port not found for service"
  fi
}

function start() {
  name=$1
  bp=$2
  log "start app $name with blueprint $bp"
  log "copy kube config from k8s master for insertion into blueprint"
  scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $k8s_user@$manager_ip:/home/$k8s_user/.kube/config $bp/kube.config

    log "package the blueprint"
    # CLI: cfy blueprints package -o /tmp/$bp $bp
    tar ckf /tmp/blueprint.tar $bp

    log "upload the blueprint"
    # CLI: cfy blueprints upload -t default_tenant -b $bp /tmp/$bp.tar.gz
    curl -s -X PUT -u admin:admin --header 'Tenant: default_tenant' \
      --header "Content-Type: application/octet-stream" -o /tmp/json \
      http://$manager_ip/api/v3.1/blueprints/$bp?application_file_name=blueprint.yaml \
      -T /tmp/blueprint.tar

    log "create a deployment for the blueprint"
    # CLI: cfy deployments create -t default_tenant -b $bp $bp
    curl -s -X PUT -u admin:admin --header 'Tenant: default_tenant' \
      --header "Content-Type: application/json" -o /tmp/json \
      -d "{\"blueprint_id\": \"$bp\"}" \
      http://$manager_ip/api/v3.1/deployments/$bp
    sleep 10

    # CLI: cfy workflows list -d $bp

    log "install the deployment pod and service"
    # CLI: cfy executions start install -d $bp
    curl -s -X POST -u admin:admin --header 'Tenant: default_tenant' \
      --header "Content-Type: application/json" -o /tmp/json \
      -d "{\"deployment_id\":\"$bp\", \"workflow_id\":\"install\"}" \
      http://$manager_ip/api/v3.1/executions

    log "get the service's assigned node_port"
    port=""
    service_port $name $manager_ip

    log "verify service is responding"
    while ! curl -s http://$manager_ip:$port ; do
      log "$name service is not yet responding at http://$manager_ip:$port, waiting 10 seconds"
      sleep 10
    done
    log "service is active at http://$manager_ip:$port"
}

function stop() {
  name=$1
  bp=$2

  # TODO: fix the need for this workaround
  log "try to first cancel all current executions"
  curl -s -u admin:admin --header 'Tenant: default_tenant' \
    -o /tmp/json http://$manager_ip/api/v3.1/executions
  i=0
  exs=$(jq -r '.items[].status' /tmp/json)
  for status in $exs; do
    id=$(jq -r ".items[$i].id" /tmp/json)
    log "execution $id in state $status"
    if [[ "$status" == "started" ]]; then
      id=$(curl -s -u admin:admin --header 'Tenant: default_tenant' \
        http://$manager_ip/api/v3.1/executions | jq -r ".items[$i].id")
      curl -s -X POST -u admin:admin --header 'Tenant: default_tenant' \
        --header "Content-Type: application/json" \
        -d "{\"deployment_id\": \"$bp\", \"action\": \"force-cancel\"}" \
        http://$manager_ip/api/v3.1/executions/$id
    fi
    ((i++))
  done
  tries=6
  count=1
  while [[ $count -gt 0 && $tries -gt 0 ]]; do
    sleep 10
    exs=$(curl -s -u admin:admin --header 'Tenant: default_tenant' \
      http://$manager_ip/api/v3.1/executions | jq -r '.items[].status')
    count=0
    for status in $exs; do
      if [[ "$status" != "terminated" && "$status" != "cancelled" ]]; then
        ((count++))
      fi
    done
    ((tries--))
    log "$count active executions remain"
  done
  if [[ $count -gt 0 ]]; then
    echo "$exs"
    fail "running executions remain"
  fi
  # end workaround

  log "uninstall the service"
  curl -s -X POST -u admin:admin --header 'Tenant: default_tenant' \
    --header "Content-Type: application/json" \
    -d "{\"deployment_id\":\"$bp\", \"workflow_id\":\"uninstall\"}" \
    -o /tmp/json http://$manager_ip/api/v3.1/executions
  id=$(jq -r ".id" /tmp/json)
  log "uninstall execution id = $id"
  status=""
  tries=1
  while [[ "$status" != "terminated" && $tries -lt 10 ]]; do
    sleep 30
    curl -s -u admin:admin --header 'Tenant: default_tenant' \
    -o /tmp/json http://$manager_ip/api/v3.1/executions/$id
    status=$(jq -r ".status" /tmp/json)
    log "try $tries of 10: execution $id is $status"      
    ((tries++))
  done
  if [[ $tries == 11 ]]; then
    cat /tmp/json
    fail "uninstall execution did not complete"
  fi
  curl -s -u admin:admin --header 'Tenant: default_tenant' \
    http://$manager_ip/api/v3.1/executions/$id | jq

  count=1
  state=""
  tries=6
  while [[ "$state" != "deleted" && $tries -gt 0 ]]; do
    sleep 10
    curl -s -u admin:admin --header 'Tenant: default_tenant' \
      -o /tmp/json http://$manager_ip/api/v3.1/node-instances
    state=$(jq -r '.items[0].state' /tmp/json)
    ((tries--))
  done
  if [[ "$state" != "deleted" ]]; then
    jq -r '.items' /tmp/json
    fail "node-instances delete failed"
  fi

  log "delete the deployment"
  curl -s -X DELETE -u admin:admin --header 'Tenant: default_tenant' \
    -o /tmp/json  http://$manager_ip/api/v3.1/deployments/$bp
  log "verify the deployment is deleted"
  error=$(curl -s -u admin:admin --header 'Tenant: default_tenant' \
    http://$manager_ip/api/v3.1/deployments/$bp | jq -r '.error_code')
  if [[ "$error" != "not_found_error" ]]; then
     log "force delete deployment via cfy CLI"
     ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
       $k8s_user@$manager_ip cfy deployment delete -f \
       -t default_tenant $bp
     error=$(curl -s -u admin:admin --header 'Tenant: default_tenant' \
     http://$manager_ip/api/v3.1/deployments/$bp | jq -r '.error_code')
     if [[ "$error" != "not_found_error" ]]; then
       fail "deployment delete failed"
     fi
  fi

  sleep 10
  log "delete the blueprint"
  curl -s -X DELETE -u admin:admin --header 'Tenant: default_tenant' \
    -o /tmp/json http://$manager_ip/api/v3.1/blueprints/$bp
  sleep 10
  log "verify the blueprint is deleted"
  error=$(curl -s -u admin:admin --header 'Tenant: default_tenant' \
    http://$manager_ip/api/v3.1/blueprints/$bp | jq -r '.error_code')
  if [[ "$error" != "not_found_error" ]]; then
    fail "blueprint delete failed"
  fi
  log "blueprint deleted"
}

function demo() {
  # Per http://docs.getcloudify.org/4.1.0/plugins/container-support/
  # Per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin
  # Also per guidance at https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/issues/18
#  echo "master-ip: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $1}')" >~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "master-port: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $2}')" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "file_content:" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  sed 's/^/  /' ~/.kube/config | tee -a ~/cloudify/blueprints/k8s-hello-world/inputs.yaml
  cd ~/models/tools/cloudify/blueprints

  if [[ "$1" == "start" ]]; then
    start nginx k8s-hello-world $manager_ip
  else
    stop nginx k8s-hello-world $manager_ip
  fi
}
# API examples: use '| jq' to format JSON output
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/blueprints | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/deployments | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/executions | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/deployments | jq -r '.items[0].blueprint_id'
# curl -u admin:admin --header 'Tenant: default_tenant' http://$manager_ip/api/v3.1/node-instances | jq

function clean () {
  log "Cleanup cloudify"
  # TODO
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
source ~/k8s_env.sh
manager_ip=$k8s_master

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
  "start")
    start $2 $3
    ;;
  "stop")
    stop $2 $3
    ;;
  "port")
    service_port $2
    ;;
  "clean")
    clean
    ;;
  *)
    grep '#. ' $0
esac

