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
# What this is: Deployment test for the Cloudify Hello World blueprint. 
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ wget https://git.opnfv.org/cgit/models/plain/tests/vHello.sh
#   $ bash vHello.sh [cloudify-cli|cloudify-manager] [setup|start|clean]
#   cloudify-cli: use Cloudify CLI
#   cloudify-manager: use Cloudify Manager
#   setup: setup test environment
#   start: run test
#   clean: cleanup after test

set -x

pass() {
  echo "Hooray!"
  set +x #echo off
  exit 0
}

# Use this to trigger fail() at the right places
# if [ "$RESULT" == "Test Failed!" ]; then fail; fi
fail() {
  echo "Test Failed!"
  set +x
  exit 1
}

function get_floating_net () {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${network_ids[@]}; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && floating_network_id=${id}
  done
  if [[ $floating_network_id ]]; then 
    floating_network_name=$(openstack network show $floating_network_id | awk "/ name / { print \$4 }")
  else
    echo "$0: Floating network not found"
    exit 1
  fi
}

select_manager() {
  echo "$0: select manager to use"
  MANAGER_IP=$(openstack server list | awk "/ cloudify-manager-server / { print \$9 }")
  cfy use -t $MANAGER_IP
  if [ $? -eq 1 ]; then fail; fi
}

start() {
  echo "$0: reset blueprints folder"
  if [[ -d /tmp/cloudify/blueprints ]]; then rm -rf /tmp/cloudify/blueprints; fi
  mkdir -p /tmp/cloudify/blueprints
  cd /tmp/cloudify/blueprints

  echo "$0: clone cloudify-hello-world-example"
  if [[ "$1" == "cloudify-manager" ]]; then 
    git clone https://github.com/cloudify-cosmo/cloudify-hello-world-example.git
    cd cloudify-hello-world-example
    git checkout 3.4.1-build
  else
    git clone https://github.com/blsaws/cloudify-cli-hello-world-example.git
    cd cloudify-cli-hello-world-example
  fi

  cd /tmp/cloudify/blueprints

  echo "$0: setup OpenStack CLI environment"
  source /tmp/cloudify/admin-openrc.sh

  echo "$0: Setup image_id"
# image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
  image=$(openstack image list | awk "/ xenial-server / { print \$2 }")
  if [ -z $image ]; then 
#   glance --os-image-api-version 1 image-create --name CentOS-7-x86_64-GenericCloud-1607 --disk-format qcow2 --location http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-1607.qcow2 --container-format bare
    glance --os-image-api-version 1 image-create --name xenial-server --disk-format qcow2 --location http://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img --container-format bare
  fi
# image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
  image=$(openstack image list | awk "/ xenial-server / { print \$2 }")
	
  if [[ "$1" == "cloudify-manager" ]]; then 
    echo "$0: create Cloudify Manager blueprint inputs file"
    # Set host image per Cloudify agent compatibility: http://docs.getcloudify.org/3.4.0/agents/overview/
    cd /tmp/cloudify/blueprints
    cat <<EOF >vHello-inputs.yaml
image: xenial-server
flavor: m1.small
agent_user: ubuntu
webserver_port: 8080
EOF
  else
    # Cloudify CLI use
    echo "$0: Get external network for Floating IP allocations"
    get_floating_net

    echo "$0: Create Nova key pair"
    mkdir -p ~/.ssh
    nova keypair-delete vHello
    nova keypair-add vHello > ~/.ssh/vHello.pem
    chmod 600 ~/.ssh/vHello.pem

    echo "$0: create Cloudify CLI blueprint inputs file"
    cat <<EOF >vHello-inputs.yaml
image: xenial-server
flavor: m1.small
external_network_name: $floating_network_name
webserver_port: 8080
key_name: vHello
ssh_key_filename: /root/.ssh/vHello.pem
ssh_user: ubuntu
ssh_port: 22
EOF
  fi

  echo "$0: initialize cloudify environment"
  cd /tmp/cloudify/blueprints
  cfy init -r

  if [[ "$1" == "cloudify-manager" ]]; then 
    select_manager
    echo "$0: upload blueprint via manager"
    cfy blueprints delete -b cloudify-hello-world-example
    cfy blueprints upload -p cloudify-hello-world-example/blueprint.yaml -b cloudify-hello-world-example
    if [ $? -eq 1 ]; then fail; fi

    echo "$0: create vHello deployment via manager"
    cfy deployments create --debug -d vHello -i vHello-inputs.yaml -b cloudify-hello-world-example
    if [ $? -eq 1 ]; then fail; fi

    echo "$0: execute 'install' workflow for vHello deployment via manager"
    cfy executions start -w install -d vHello --timeout 1800
    if [ $? -eq 1 ]; then fail; fi

    echo "$0: get vHello server address"
    SERVER_URL=$(cfy deployments outputs -d vHello | awk "/ Value: / { print \$2 }")
  else 
    echo "$0: install local blueprint"
    # don't use --install-plugins, causes openstack plugin 1.4.1 to be rolled back to 1.4 and then an error
    cfy local install -i vHello-inputs.yaml -p cloudify-cli-hello-world-example/blueprint.yaml --allow-custom-parameters --parameters="floating_network_name=$floating_network_name" --task-retries=10 --task-retry-interval=30
   if [ $? -eq 1 ]; then fail; fi

    echo "$0: get vHello server address"
    SERVER_URL=$(cfy local outputs | awk "/http_endpoint/ { print \$2 }" | sed -- 's/"//g')
  fi

  echo "$0: verify vHello server is running"
  apt-get install -y curl
  if [[ $(curl $SERVER_URL | grep -c "Hello, World!") != 1 ]]; then fail; fi

  pass
}

clean() {
  echo "$0: activate cloudify Virtualenv"
  source ~/cloudify/venv/bin/activate

  echo "$0: setup OpenStack CLI environment"
  source /tmp/cloudify/admin-openrc.sh

  echo "$0: initialize cloudify environment"
  cd /tmp/cloudify/blueprints

 if [[ "$1" == "cloudify-manager" ]]; then 
    select_manager
    echo "$0: uninstall vHello blueprint via manager"
    cfy executions start -w uninstall -d vHello
    if [ $? -eq 1 ]; then fail; fi

    echo "$0: delete vHello blueprint"
    cfy deployments delete -d vHello
    if [ $? -eq 1 ]; then fail; fi
  else 
    echo "$0: uninstall vHello blueprint via CLI"
    cfy local uninstall
    if [ $? -eq 1 ]; then fail; fi
  fi
  pass
}

if [[ "$2" == "setup" ]]; then
  echo "$0: Setup temp test folder /tmp/cloudify and copy this script there"
  mkdir /tmp/cloudify
  chmod 777 /tmp/cloudify/
  cp $0 /tmp/cloudify/.
  chmod 755 /tmp/cloudify/*.sh

  echo "$0: cloudify-setup part 1"
  bash utils/cloudify-setup.sh $1 init

  echo "$0: cloudify-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/cloudify/ { print \$1 }")
  sudo docker exec $CONTAINER /tmp/cloudify/cloudify-setup.sh $1 setup
  if [ $? -eq 1 ]; then fail; fi
  pass
else
  if [[ $# -eq 3 ]]; then
    # running inside the cloudify container, ready to go
    if [[ "$3" == "start" ]]; then start $1; fi
    if [[ "$3" == "clean" ]]; then clean $1; fi    
  else
    echo "$0: pass $2 command to vHello.sh in cloudify container"
    CONTAINER=$(sudo docker ps -a | awk "/cloudify/ { print \$1 }")
    sudo docker exec $CONTAINER /tmp/cloudify/vHello.sh $1 $2 $2
    if [ $? -eq 1 ]; then fail; fi
    pass
  fi
fi
