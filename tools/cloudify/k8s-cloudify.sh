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
#. - Kubernetes environment variables set per the k8s_env_*.sh created by
#.   the demo_deploy.sh script (* is the hostname of the k8s master node).
#. Usage:
#.   From a server with access to the kubernetes master node:
#.   $ cd ~/models/tools/cloudify
#.   $ scp -r ~/models/tools/* <user>@<k8s-master>:/home/<user>/.
#.     <user>: username on the target host. Also used to indicate OS name.
#.     <k8s-master>: IP or hostname of kubernetes master server
#.   $ ssh -x <user>@<k8s-master> cloudify/k8s-cloudify.sh prereqs
#.     <user>: username on the target host. Also used to indicate OS name.
#.     <k8s-master>: IP or hostname of kubernetes master server
#.     prereqs: installs prerequisites and configures <user> user for kvm use
#.   $ ssh -x <user>@<k8s-master> bash cloudify/k8s-cloudify.sh setup
#.     <user>: username on the target host. Also used to indicate OS name.
#.     setup: installs cloudify CLI and Manager
#.   $ bash k8s-cloudify.sh demo <start|stop>
#.     demo: control demo blueprint
#.     start|stop: start or stop the demo
#.   $ bash k8s-cloudify.sh <start|stop> <name> <blueprint> ["inputs"]
#.     start|stop: start or stop the blueprint
#.     name: name of the service in the blueprint
#.     inputs: optional JSON string to pass to Cloudify as deployment inputs
#.     blueprint: name of the blueprint folder (in current directory!)
#.   $ bash k8s-cloudify.sh nodePort <service>
#.     port: find assigned nodePort for service
#.     service: name of service e.g. nginx
#.   $ bash k8s-cloudify.sh clusterIp <service>
#.     clusterIp: find assigned clusterIp for service
#.     service: name of service e.g. nginx
#.   $ ssh -x <user>@<k8s-master> bash cloudify/k8s-cloudify.sh clean
#.     <user>: username on the target host. Also used to indicate OS name.
#.     clean: uninstalls cloudify CLI and Manager
#.
#. If using this script to start/stop blueprints with multiple k8s environments,
#. before invoking the script copy the k8s_env.sh script from the target
#. cluster and copy to ~/k8s_env.sh, e.g.
#.   scp centos@sm-1:/home/centos/k8s_env.sh ~/k8s_env_sm-1.sh
#.   cp ~/k8s_env_sm-1.sh ~/k8s_env.sh
#.
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

function step_complete() {
  end=$((`date +%s`/60))
  runtime=$((end-start))
  log "step completed in $runtime minutes: \"$step\""
}

function step_start() {
  step="$1"
  log "step start: \"$step\""
  start=$((`date +%s`/60))
}

function prereqs() {
  step_start "Install prerequisites"
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
  sudo groupadd -g 7777 libvirt
  sudo usermod -aG libvirt $USER
  id $USER | grep libvirt
  sudo tee -a /etc/libvirt/libvirtd.conf <<EOF
unix_sock_group = "libvirt"
unix_sock_rw_perms = "0770"
EOF
  sudo usermod -a -G kvm $USER
  sudo chmod 0644 /boot/vmlinuz*
  sudo systemctl restart libvirtd
  step_complete
}

function setup () {
  step_start "setup"
  cd ~/cloudify
  source ~/k8s_env.sh
  k8s_master=$k8s_master
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
  # virsh destroy cloudify-manager; virsh undefine cloudify-manager
  # centos: putting image in /tmp ensures qemu user can access it
  log "Download Cloudify-Manager image cloudify-manager-community-17.9.21.qcow2"
  wget -q http://repository.cloudifysource.org/cloudify/17.9.21/community-release/cloudify-manager-community-17.9.21.qcow2
  # TODO: centos needs this, else "ERROR    Failed to connect socket to '/var/run/libvirt/libvirt-sock': No such file or directory"
  sudo systemctl start libvirtd
  if [[ "$USER" == "centos" ]]; then
    # copy image to folder that qemu has access to, to avoid: ERROR    Cannot access storage file '/home/centos/cloudify/cloudify-manager-community-17.9.21.qcow2' (as uid:107, gid:107): Permission denied
    cp cloudify-manager-community-17.9.21.qcow2 /tmp/.
    img="/tmp/cloudify-manager-community-17.9.21.qcow2"
  else
    img="cloudify-manager-community-17.9.21.qcow2"
  fi
  # --noautoconsole is needed to avoid virt-install hanging
  virt-install --connect qemu:///system --virt-type kvm \
    --name cloudify-manager --vcpus 4 --memory 16192 \
    --disk $img --import \
    --network network=default --os-type=linux  \
    --os-variant=rhel7 --noautoconsole

  # TODO: centos requires sudo for some reason
  if [[ "$USER" == "centos" ]]; then dosudo=sudo; fi
  VM_IP=""
  n=0
  while [[ "x$VM_IP" == "x" ]]; do
    log "$n minutes so far; waiting 10 seconds for cloudify-manager IP to be assigned"
    sleep 10
    ((n++))
    VM_MAC=$($dosudo virsh domiflist cloudify-manager | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
    VM_IP=$(/usr/sbin/arp -e | grep ${VM_MAC} | awk {'print $1'})
  done
  log "cloudify-manager IP=$VM_IP"
  while ! cfy profiles use $VM_IP -u admin -p admin -t default_tenant ; do
    log "waiting 60 seconds for cloudify-manager API to be active"
    sleep 60
  done
  cfy status

  log "Set iptables to forward $HOST_IP port 80 to Cloudify Manager VM at $VM_IP"
  HOST_IP=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
  sudo iptables -t nat -I PREROUTING -p tcp -d $HOST_IP --dport 80 -j DNAT --to-destination $VM_IP:80
  sudo iptables -I FORWARD -m state -d $VM_IP/32 --state NEW,RELATED,ESTABLISHED -j ACCEPT
  sudo iptables -t nat -A POSTROUTING -j MASQUERADE

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
  step_complete
}

function cluster_ip() {
  name=$1
  log "getting clusterIp for service $name at manager $k8s_master"

  tries=6
  svcId="null"
  clusterIp="null"
  while [[ "$clusterIp" == "null" && $tries -gt 0 ]]; do
    curl -s -u admin:admin --header 'Tenant: default_tenant' \
      -o /tmp/json http://$k8s_master/api/v3.1/node-instances
    ni=$(jq -r '.items | length' /tmp/json)
    while [[ $ni -ge 0 ]]; do
      ((ni--))
      depid=$(jq -r ".items[$ni].deployment_id" /tmp/json)
      type=$(jq -r ".items[$ni].runtime_properties.kubernetes.kind" /tmp/json)
      if [[ "$depid" == "$name" && "$type" == "Service" ]]; then
        svcId=$ni
        clusterIp=$(jq -r ".items[$ni].runtime_properties.kubernetes.spec.cluster_ip" /tmp/json)
        if [[ "$clusterIp" != "null" ]]; then
          echo "clusterIp=$clusterIp"
          export clusterIp
        fi
      fi
    done
    sleep 10
    ((tries--))
  done
  if [[ "$clusterIp" == "null" ]]; then
    log "node-instance resource for $name"
    jq -r ".items[$svcId]" /tmp/json
    log "clusterIp not found for service"
  fi
}

function node_port() {
  name=$1
  log "getting nodePort for service $name at manager $k8s_master"

  tries=6
  svcId="null"
  nodePort="null"
  while [[ "$nodePort" == "null" && $tries -gt 0 ]]; do
    curl -s -u admin:admin --header 'Tenant: default_tenant' \
      -o /tmp/json http://$k8s_master/api/v3.1/node-instances
    ni=$(jq -r '.items | length' /tmp/json)
    while [[ $ni -ge 0 ]]; do
      ((ni--))
      depid=$(jq -r ".items[$ni].deployment_id" /tmp/json)
      type=$(jq -r ".items[$ni].runtime_properties.kubernetes.kind" /tmp/json)
      if [[ "$depid" == "$name" && "$type" == "Service" ]]; then
        svcId=$ni
        nodePort=$(jq -r ".items[$ni].runtime_properties.kubernetes.spec.ports[0].node_port" /tmp/json)
        if [[ "$nodePort" != "null" ]]; then
          echo "nodePort=$nodePort"
          export nodePort
        fi
      fi
    done
    sleep 10
    ((tries--))
  done
  if [[ "$nodePort" == "null" ]]; then
    log "node-instance resource for $name"
    jq -r ".items[$svcId]" /tmp/json
    log "nodePort not found for service"
  fi
}

function wait_terminated() {
  name=$1
  workflow=$2
  log "waiting for $name execution $workflow to be completed ('terminated')"
  status=""
  while [[ "$status" != "terminated" ]]; do
    curl -s -u admin:admin --header 'Tenant: default_tenant' \
      -o /tmp/json http://$k8s_master/api/v3.1/executions
    ni=$(jq -r '.items | length' /tmp/json)
    while [[ $ni -ge 0 ]]; do
      ((ni--))
      depid=$(jq -r ".items[$ni].deployment_id" /tmp/json)
      wflid=$(jq -r ".items[$ni].workflow_id" /tmp/json)
      status=$(jq -r ".items[$ni].status" /tmp/json)
      if [[  "$depid" == "$name" && "$wflid" == "$workflow" ]]; then
        id=$(jq -r ".items[$ni].id" /tmp/json)
#        curl -u admin:admin --header 'Tenant: default_tenant' \
#          http://$k8s_master/api/v3.1/executions/$id | jq
        if [[ "$status" == "failed" ]]; then fail "execution failed"; fi
        if [[ "$status" == "terminated" ]]; then break; fi
        log "$name execution $workflow is $status... waiting 30 seconds"
      fi
    done
    sleep 30
  done
  if [[ "$status" == "terminated" ]]; then
    log "$name execution $workflow is $status"
  else
    fail "timeout waiting for $name execution $workflow: status = $status"
  fi
}

function start() {
  name=$1
  bp=$2
  inputs="$3"
  start=$((`date +%s`/60))

  step_start "start app $name with blueprint $bp and inputs: $inputs"
  log "copy kube config from k8s master for insertion into blueprint"
  scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $k8s_user@$k8s_master:/home/$k8s_user/.kube/config $bp/kube.config

  log "package the blueprint"
  # CLI: cfy blueprints package -o /tmp/$bp $bp
  tar ckf /tmp/blueprint.tar $bp

  log "upload the blueprint"
  # CLI: cfy blueprints upload -t default_tenant -b $bp /tmp/$bp.tar.gz
  resp=$(curl -X PUT -s -w "%{http_code}" -o /tmp/json \
    -u admin:admin --header 'Tenant: default_tenant' \
    --header "Content-Type: application/octet-stream" \
    http://$k8s_master/api/v3.1/blueprints/$bp?application_file_name=blueprint.yaml \
    -T /tmp/blueprint.tar)
  if [[ "$resp" != "201" ]]; then
    log "Response: $resp"
    cat /tmp/json
    fail "upload failed, response $resp"
  fi

  log "create a deployment for the blueprint"
  # CLI: cfy deployments create -t default_tenant -b $bp $bp
  if [[ "z$inputs" != "z" ]]; then
    resp=$(curl -X PUT -s -w "%{http_code}" -o /tmp/json \
      -u admin:admin --header 'Tenant: default_tenant' \
      -w "\nResponse: %{http_code}\n" \
      --header "Content-Type: application/json" \
      -d "{\"blueprint_id\": \"$bp\", \"inputs\": $inputs}" \
      http://$k8s_master/api/v3.1/deployments/$bp)
  else
    resp=$(curl -X PUT -s -w "%{http_code}" -o /tmp/json \
      -u admin:admin --header 'Tenant: default_tenant' \
      -w "\nResponse: %{http_code}\n" \
      --header "Content-Type: application/json" \
      -d "{\"blueprint_id\": \"$bp\"}" \
      http://$k8s_master/api/v3.1/deployments/$bp)
  fi
  # response code comes back as "\nResponse: <code>"
  resp=$(echo $resp | awk '/Response/ {print $2}')
  if [[ "$resp" != "201" ]]; then
    log "Response: $resp"
    cat /tmp/json
    fail "deployment failed, response $resp"
  fi
  sleep 10

  # CLI: cfy workflows list -d $bp

  log "install the deployment pod and service"
  # CLI: cfy executions start install -d $bp
  resp=$(curl -X POST -s -w "%{http_code}" -o /tmp/json \
    -u admin:admin --header 'Tenant: default_tenant' \
    -w "\nResponse: %{http_code}\n" \
    --header "Content-Type: application/json" \
    -d "{\"deployment_id\":\"$bp\", \"workflow_id\":\"install\"}" \
    http://$k8s_master/api/v3.1/executions)
  # response code comes back as "\nResponse: <code>"
  resp=$(echo $resp | awk '/Response/ {print $2}')
  if [[ "$resp" != "201" ]]; then
    log "Response: $resp"
    cat /tmp/json
    fail "install failed, response $resp"
  fi

  wait_terminated $name create_deployment_environment
  wait_terminated $name install
  log "install actions completed"
  step_complete
}

function cancel_executions() {
  log "workaround: cancelling all active executions prior to new execution"
  curl -s -u admin:admin --header 'Tenant: default_tenant' \
    -o /tmp/json http://$k8s_master/api/v3.1/executions
  i=0
  exs=$(jq -r '.items[].status' /tmp/json)
  for status in $exs; do
    id=$(jq -r ".items[$i].id" /tmp/json)
    if [[ "$status" == "started" ]]; then
      log "force cancelling execution $id in state $status"
      id=$(curl -s -u admin:admin --header 'Tenant: default_tenant' \
        http://$k8s_master/api/v3.1/executions | jq -r ".items[$i].id")
      curl -s -X POST -u admin:admin --header 'Tenant: default_tenant' \
        --header "Content-Type: application/json" \
        -d "{\"deployment_id\": \"$bp\", \"action\": \"force-cancel\"}" \
        http://$k8s_master/api/v3.1/executions/$id
    fi
    ((i++))
  done
  tries=6
  count=1
  while [[ $count -gt 0 && $tries -gt 0 ]]; do
    sleep 10
    exs=$(curl -s -u admin:admin --header 'Tenant: default_tenant' \
      http://$k8s_master/api/v3.1/executions | jq -r '.items[].status')
    count=0
    for status in $exs; do
      if [[ "$status" != "terminated" && "$status" != "cancelled" && "$status" != "failed" ]]; then
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
}

function check_resource() {
  log "checking for presence of resource: $1"
  status=""
  if [[ -f /tmp/vfy ]]; then rm /tmp/vfy; fi
  r=$(curl -s -o /tmp/vfy -u admin:admin --header 'Tenant: default_tenant' $1)
  log "Response: $r"
#  cat /tmp/vfy
  status=$(cat /tmp/vfy | jq -r '.error_code')
}

function stop() {
  name=$1
  bp=$2

  step_start "stopping $name with blueprint $bp"
  # TODO: fix the need for this workaround
  log "workaround: try to first cancel all current executions"
  cancel_executions
  # end workaround

  log "verify $name deployment is present"
  check_resource http://$k8s_master/api/v3.1/deployments/$bp
  if [[ "$status" != "not_found_error" ]]; then
    log "initiate uninstall action for $name deployment"
    resp=$(curl -X POST -s -w "%{http_code}" -o /tmp/json \
      -u admin:admin --header 'Tenant: default_tenant' \
      --header "Content-Type: application/json" \
      -d "{\"deployment_id\":\"$bp\", \"workflow_id\":\"uninstall\"}" \
      http://$k8s_master/api/v3.1/executions)
    log "Response: $resp"
    if [[ "$resp" != "201" ]]; then
      log "uninstall action was not accepted"
      cat /tmp/json
    fi

    id=$(jq -r ".id" /tmp/json)
    if [[ "$id" != "null" ]]; then
      log "wait for uninstall execution $id to be completed ('terminated')"
      status=""
      tries=10
      while [[ "$status" != "terminated" && $tries -gt 0 ]]; do
        if [[ "$status" == "failed" ]]; then break; fi
        sleep 30
        curl -s -u admin:admin --header 'Tenant: default_tenant' \
        -o /tmp/json http://$k8s_master/api/v3.1/executions/$id
        status=$(jq -r ".status" /tmp/json)
        log "execution $id is $status"      
        ((tries--))
      done
      if [[ "$status" == "failed" || $tries == 0 ]]; then
        cat /tmp/json
        log "uninstall execution did not complete"
      else
        log "wait for node instances to be deleted"
        state=""
        tries=18
        while [[ "$state" != "deleted" && $tries -gt 0 ]]; do
          sleep 10
          curl -s -u admin:admin --header 'Tenant: default_tenant' \
            -o /tmp/json http://$k8s_master/api/v3.1/node-instances
          ni=$(jq -r '.items | length' /tmp/json)
          state="deleted"
          while [[ $ni -ge 0 ]]; do
            state=$(jq -r ".items[$ni].state" /tmp/json)
            depid=$(jq -r ".items[$ni].deployment_id" /tmp/json)
            if [[ "$depid" == "$name" && "$state" != "deleted" ]]; then 
              state=""
              id=$(jq -r ".items[$ni].id" /tmp/json)
              log "waiting on deletion of node instance $id for $name"
            fi
            ((ni--))
          done
          ((tries--))
        done
        if [[ "$state" != "deleted" ]]; then
#          jq -r '.items' /tmp/json
          log "node-instances delete did not complete"
        fi
      fi
#      curl -s -u admin:admin --header 'Tenant: default_tenant' \
#        http://$k8s_master/api/v3.1/executions/$id | jq

      log "delete the $name deployment"
      resp=$(curl -X DELETE -s -w "%{http_code}" -o /tmp/json \
        -u admin:admin --header 'Tenant: default_tenant' \
        -o /tmp/json  http://$k8s_master/api/v3.1/deployments/$bp)
      log "Response: $resp"
#      cat /tmp/json
      log "verify the $name deployment is deleted"
      check_resource http://$k8s_master/api/v3.1/deployments/$bp
      if [[ "$status" != "not_found_error" ]]; then
        log "force delete $name deployment via cfy CLI over ssh to $k8s_user@$k8s_master"
        cancel_executions
        ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
          $k8s_user@$k8s_master cfy deployment delete -f -t default_tenant $bp
        sleep 10
        check_resource http://$k8s_master/api/v3.1/deployments/$bp
        if [[ "$status" != "not_found_error" ]]; then
         fail "deployment $name delete failed"
        fi
      fi
    else
      log "uninstall execution id = $id"
      cat /tmp/json
    fi
  else
    log "$name deployment not found"
  fi

  log "verify $bp blueprint is present"
  check_resource http://$k8s_master/api/v3.1/blueprints/$bp
  if [[ "$status" != "not_found_error" ]]; then
    log "delete the $bp blueprint"
    resp=$(curl -X DELETE -s -w "%{http_code}" -o /tmp/json \
      -u admin:admin --header 'Tenant: default_tenant' \
      -o /tmp/json http://$k8s_master/api/v3.1/blueprints/$bp)
    log "Response: $resp"

    if [[ "$response" != "404" ]]; then
      sleep 10
      log "verify the blueprint is deleted"
      check_resource http://$k8s_master/api/v3.1/blueprints/$bp
      if [[ "$status" != "not_found_error" ]]; then
        cat /tmp/json
        fail "blueprint delete failed"
      fi
    fi
    log "blueprint $bp deleted"
  else
    log "$bp blueprint not found"
  fi
  step_complete
}

function demo() {
  step_start "$1 nginx app demo via Cloudyify Manager at $k8s_master"

  # Per http://docs.getcloudify.org/4.1.0/plugins/container-support/
  # Per https://github.com/cloudify-incubator/cloudify-kubernetes-plugin
  # Also per guidance at https://github.com/cloudify-incubator/cloudify-kubernetes-plugin/issues/18
#  echo "master-ip: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $1}')" >~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "master-port: $(grep server ~/.kube/config | awk -F '/' '{print $3}' | awk -F ':' '{print $2}')" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  echo "file_content:" >>~/cloudify/blueprints/k8s-hello-world/inputs.yaml
#  sed 's/^/  /' ~/.kube/config | tee -a ~/cloudify/blueprints/k8s-hello-world/inputs.yaml
  cd ~/models/tools/cloudify/blueprints

  if [[ "$1" == "start" ]]; then
    start nginx k8s-hello-world
  else
    stop nginx k8s-hello-world
  fi
  step_complete
}
# API examples: use '| jq' to format JSON output
# curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/blueprints | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/deployments | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/executions | jq
# curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/deployments | jq -r '.items[0].blueprint_id'
# curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/node-instances | jq

function clean () {
  log "Cleanup cloudify"
  # TODO
}

export WORK_DIR=$(pwd)
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
  "start")
    cd ~/models/tools/cloudify/blueprints
    start $2 $3 "$4"
    cd $WORK_DIR
    ;;
  "stop")
    stop $2 $3
    ;;
  "nodePort")
    node_port $2
    ;;
  "clusterIp")
    cluster_ip $2
    ;;
  "clean")
    clean
    ;;
  *)
    grep '#. ' $0
esac

