#!/bin/bash
# Copyright 2016 AT&T Intellectual Property, Inc
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
# What this is: Deployment test for the Tacker Hello World blueprint.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ git clone https://gerrit.opnfv.org/gerrit/models
#   $ cd models/tests
#   $ bash vLamp_Ansible.sh [setup|start|run|stop|clean]
#   setup: setup test environment
#   start: install blueprint and run test
#   run: setup test environment and run test
#   stop: stop test and uninstall blueprint
#   clean: cleanup after test

trap 'fail' ERR

pass() {
  echo "$0: Hooray!"
  set +x #echo off
  exit 0
}

fail() {
  echo "$0: Test Failed!"
  set +x
  exit 1
}

get_floating_net () {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${network_ids[@]}; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && FLOATING_NETWORK_ID=${id}
  done
  if [[ $FLOATING_NETWORK_ID ]]; then
    FLOATING_NETWORK_NAME=$(openstack network show $FLOATING_NETWORK_ID | awk "/ name / { print \$4 }")
  else
    echo "$0: Floating network not found"
    exit 1
  fi
}

try () {
  count=$1
  $3
  while [[ $? -eq 1 && $count -gt 0 ]] 
  do 
    sleep $2
    let count=$count-1
    $3
  done
  if [[ $count -eq 0 ]]; then echo "$0: Command \"$3\" was not successful after $1 tries"; fi
}

setup () {
  echo "$0: Setup temp test folder /tmp/ansible and copy this script there"
  if [ -d /tmp/ansible ]; then sudo rm -rf /tmp/ansible; fi 
  mkdir -p /tmp/ansible
  chmod 777 /tmp/ansible/
  cp $0 /tmp/ansible/.
  chmod 755 /tmp/ansible/*.sh

  echo "$0: ansible-setup part 1"
  bash utils/ansible-setup.sh init

  echo "$0: ansible-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/ansible/ { print \$1 }")
  dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: Execute ansible-setup.sh in the container"
    sudo docker exec -it $CONTAINER /bin/bash /tmp/ansible/ansible-setup.sh setup
  else
    echo "$0: Execute ansible-setup.sh in the container"
    sudo docker exec -i -t $CONTAINER /bin/bash /tmp/ansible/ansible-setup.sh setup
  fi

  echo "$0: reset blueprints folder"
  if [[ -d /tmp/ansible/blueprints/lampstack ]]; then rm -rf /tmp/ansible/blueprints/lampstack; fi
  mkdir -p /tmp/ansible/blueprints/

  echo "$0: copy lampstack to blueprints folder"
  cd /tmp/
  git clone https://github.com/openstack/osops-tools-contrib.git
  cp -r osops-tools-contrib/ansible/lampstack /tmp/ansible/blueprints

  echo "$0: setup OpenStack environment"
  source /tmp/ansible/admin-openrc.sh

  echo "$0: determine external (public) network as the floating ip network"
  get_floating_net

  echo "$0: create lampstack vars file for OPNFV"
cat >/tmp/ansible/blueprints/lampstack/vars/opnfv.yml <<EOF
---
horizon_url: "http://$HORIZON_HOST"

auth: {
  auth_url: "$OS_AUTH_URL",
  username: "admin",
  password: "{{ password }}",
  project_name: "admin"
}

app_env: {
  image_name: "xenial-server",
  region_name: "RegionOne",
  private_net_name: "internal",
  public_net_name: "$FLOATING_NETWORK_NAME",
  flavor_name: "m1.small",
  public_key_file: "/tmp/ansible/ansible.pub",
  stack_size: 4,
  volume_size: 2,
  block_device_name: "/dev/vdb",
  wp_theme: "https://downloads.wordpress.org/theme/iribbon.2.0.65.zip",
  wp_posts: "http://wpcandy.s3.amazonaws.com/resources/postsxml.zip"
}
EOF

  echo "$0: Setup ubuntu as ansible_user (fix for SSH connection issues?)"
  echo "ansible_user: ubuntu" >>/tmp/ansible/blueprints/lampstack/group_vars/all.yml

  echo "$0: Setup ubuntu-xenial glance image if needed"
  if [[ -z $(openstack image list | awk "/ xenial-server / { print \$2 }") ]]; then glance --os-image-api-version 1 image-create --name xenial-server --disk-format qcow2 --location https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img --container-format bare; fi 

  if [[ -z $(neutron net-list | awk "/ internal / { print \$2 }") ]]; then 
    echo "$0: Create internal network"
    neutron net-create internal

    echo "$0: Create internal subnet"
    neutron subnet-create internal 10.0.0.0/24 --name internal --gateway 10.0.0.1 --enable-dhcp --allocation-pool start=10.0.0.2,end=10.0.0.254 --dns-nameserver 8.8.8.8
  fi

  if [[ -z $(neutron router-list | awk "/ public_router / { print \$2 }") ]]; then 
    echo "$0: Create router"
    neutron router-create public_router

    echo "$0: Create router gateway"
    neutron router-gateway-set public_router $FLOATING_NETWORK_NAME

    echo "$0: Add router interface for internal network"
    neutron router-interface-add public_router subnet=internal
  fi
}

start() {
  echo "$0: Add ssh key"
  chown root /tmp/ansible/ansible.pem
  eval $(ssh-agent -s)
  ssh-add /tmp/ansible/ansible.pem

  echo "$0: setup OpenStack environment"
  source /tmp/ansible/admin-openrc.sh

  echo "$0: Clear known hosts (workaround for ssh connection issues)"
  rm ~/.ssh/known_hosts

  echo "$0: invoke blueprint install via Ansible"
  cd /tmp/ansible/blueprints/lampstack
  ansible-playbook -vvv -e "action=apply env=opnfv password=$OS_PASSWORD" -u ubuntu site.yml

  pass
}

stop() {
  echo "$0: Add ssh key"
  eval $(ssh-agent -s)
  ssh-add /tmp/ansible/ansible.pem

  echo "$0: setup OpenStack environment"
  source /tmp/ansible/admin-openrc.sh

  echo "$0: invoke blueprint destroy via Ansible"
  cd /tmp/ansible/blueprints/lampstack
  ansible-playbook -vvv -e "action=destroy env=opnfv password=$OS_PASSWORD" -u ubuntu site.yml

  pass
}

forward_to_container () {
  echo "$0: pass $1 command to vLamp_Ansible.sh in tacker container"
  CONTAINER=$(sudo docker ps -a | awk "/ansible/ { print \$1 }")
  sudo docker exec $CONTAINER /bin/bash /tmp/ansible/vLamp_Ansible.sh $1 $1
  if [ $? -eq 1 ]; then fail; fi
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$1" in
  setup)
    setup
    pass
    ;;
  run)
    setup
    forward_to_container start
    pass
    ;;
  start|stop)
    if [[ $# -eq 1 ]]; then forward_to_container $1
    else
      # running inside the tacker container, ready to go
      $1
    fi
    pass
    ;;
  clean)
    echo "$0: Uninstall Ansible and test environment"
    bash utils/ansible-setup.sh clean
    pass
    ;;
  *)
    echo "usage: bash vLamp_Ansible.sh [setup|start|run|clean]"
    echo "setup: setup test environment"
    echo "start: install blueprint and run test"
    echo "run: setup test environment and run test"
    echo "stop: stop test and uninstall blueprint"
    echo "clean: cleanup after test"
    fail
esac
