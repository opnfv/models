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
    echo "vHello.sh: Floating network not found"
    exit 1
  fi
}

select_manager() {
  echo "vHello.sh: select manager to use"
  MANAGER_IP=$(openstack server list | awk "/ cloudify-manager-server / { print \$9 }")
  cfy use -t $MANAGER_IP
  if [ $? -eq 1 ]; then fail; fi
}

start() {
  echo "vHello.sh: reset blueprints folder"
  if [[ -d /tmp/cloudify/blueprints ]]; then rm -rf /tmp/cloudify/blueprints; fi
  mkdir -p /tmp/cloudify/blueprints
  cd /tmp/cloudify/blueprints

  echo "vHello.sh: clone cloudify-hello-world-example"
  git clone https://github.com/cloudify-cosmo/cloudify-hello-world-example.git
  cd cloudify-hello-world-example
  git checkout 3.4.1-build

  echo "vHello.sh: setup OpenStack CLI environment"
  source /tmp/cloudify/admin-openrc.sh

  echo "vHello.sh: Setup image_id"
# image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
  image=$(openstack image list | awk "/ xenial-server / { print \$2 }")
  if [ -z $image ]; then 
#   glance --os-image-api-version 1 image-create --name CentOS-7-x86_64-GenericCloud-1607 --disk-format qcow2 --location http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-1607.qcow2 --container-format bare
    glance --os-image-api-version 1 image-create --name xenial-server --disk-format qcow2 --location http://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img
  fi
# image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
  image=$(openstack image list | awk "/ xenial-server / { print \$2 }")
	
  echo "vHello.sh: create blueprint inputs file"
  # Set host image per Cloudify agent compatibility: http://docs.getcloudify.org/3.4.0/agents/overview/
  cd /tmp/cloudify/blueprints
  cat <<EOF >vHello-inputs.yaml
image: xenial-server
flavor: m1.small
agent_user: ubuntu
webserver_port: 8080
EOF

  if [[ "$1" == "cloudify-cli" ]]; then 
    # Workarounds for error in allocating floating IP 
    # Workflow failed: Task failed 'neutron_plugin.floatingip.create' -> Failed to parse request. Required attribute 'floating_network_id' not specified [status_code=400]
    get_floating_net

    echo "vHello.sh: update blueprint with parameters needed for Cloudify CLI use"
    cat <<EOF >>vHello-inputs.yaml
external_network_name: $floating_network_name
EOF

    sed -i -- 's/description: Openstack flavor name or id to use for the new server/description: Openstack flavor name or id to use for the new server\n  external_network_name:\n    description: External network name/g' cloudify-hello-world-example/blueprint.yaml

    sed -i -- 's/type: cloudify.openstack.nodes.FloatingIP/type: cloudify.openstack.nodes.FloatingIP\n    properties:\n      floatingip:\n        floating_network_name: { get_input: external_network_name }/g' cloudify-hello-world-example/blueprint.yaml

    echo "vHello.sh: Create Nova key pair"
    mkdir -p ~/.ssh
    nova keypair-delete vHello
    nova keypair-add vHello > ~/.ssh/vHello.pem
    chmod 600 ~/.ssh/vHello.pem

# Workarounds for error in allocating keypair
# Task failed 'nova_plugin.server.create' -> server must have a keypair, yet no keypair was connected to the server node, the "key_name" nested property wasn't used, and there is no agent keypair in the provider context
# Tried the following but keypair is not supported by http://www.getcloudify.org/spec/openstack-plugin/1.4/plugin.yaml
#    sed -i -- 's/target: security_group/target: security_group\n      - type: cloudify.openstack.server_connected_to_keypair\n        target: keypair/g' cloudify-hello-world-example/blueprint.yaml
#    sed -i -- 's/description: External network name/description: External network name\n  private_key_path:\n    description: Path to private key/g' cloudify-hello-world-example/blueprint.yaml
#    sed -i -- '0,/interfaces:/s//interfaces:\n      cloudify.interfaces.lifecycle:\n        start:\n          implementation: openstack.nova_plugin.server.start\n          inputs:\n            private_key_path:  { get_input: private_key_path }/' cloudify-hello-world-example/blueprint.yaml

# 'key_name' is a subproperty of 'server' per test-start-operation-retry-blueprint.yaml in the cloudify-openstack-plugin repo
    sed -i -- 's/description: External network name/description: External network name\n  key_name:\n    description: Name of private key/g' cloudify-hello-world-example/blueprint.yaml

    sed -i -- 's/flavor: { get_input: flavor }/flavor: { get_input: flavor }\n      server:\n        key_name:  { get_input: key_name }/' cloudify-hello-world-example/blueprint.yaml

    echo "vHello.sh: update blueprint with parameters needed for Cloudify CLI use"
    #private_key_path: /root/.ssh/vHello.pem
    cat <<EOF >>vHello-inputs.yaml
key_name: vHello
EOF

  echo "vHello.sh: disable cloudify agent install in blueprint"
  sed -i -- ':a;N;$!ba;s/  agent_user:\n    description: User name used when SSH-ing into the started machine\n//g' cloudify-hello-world-example/blueprint.yaml
  sed -i -- ':a;N;$!ba;s/agent_config:\n        user: { get_input: agent_user }/install_agent: false/' cloudify-hello-world-example/blueprint.yaml
  sed -i -- ':a;N;$!ba;s/agent_user: centos\n//' vHello-inputs.yaml 
  fi

  echo "vHello.sh: activate cloudify Virtualenv"
  source ~/cloudify/venv/bin/activate

  echo "vHello.sh: initialize cloudify environment"
  cd /tmp/cloudify/blueprints
  cfy init -r

  if [[ "$1" == "cloudify-manager" ]]; then 
    select_manager
    echo "vHello.sh: upload blueprint via manager"
    cfy blueprints delete -b cloudify-hello-world-example
    cfy blueprints upload -p cloudify-hello-world-example/blueprint.yaml -b cloudify-hello-world-example
    if [ $? -eq 1 ]; then fail; fi

    echo "vHello.sh: create vHello deployment via manager"
    cfy deployments create --debug -d vHello -i vHello-inputs.yaml -b cloudify-hello-world-example
    if [ $? -eq 1 ]; then fail; fi

    echo "vHello.sh: execute 'install' workflow for vHello deployment via manager"
    cfy executions start -w install -d vHello --timeout 1800
    if [ $? -eq 1 ]; then fail; fi

    echo "vHello.sh: get vHello server address"
    SERVER_URL=$(cfy deployments outputs -d vHello | awk "/ Value: / { print \$2 }")
  else 
    echo "vHello.sh: install local blueprint"
    cfy local install --install-plugins -i vHello-inputs.yaml -p cloudify-hello-world-example/blueprint.yaml --allow-custom-parameters --parameters="floating_network_name=$floating_network_name" --task-retries=10 --task-retry-interval=30
    if [ $? -eq 1 ]; then fail; fi
#    cfy local install replaces the following, per http://getcloudify.org/2016/04/07/cloudify-update-from-developers-features-improvements-open-source-python-devops.html
#    cfy local init --install-plugins -i vHello-inputs.yaml -p cloudify-hello-world-example/blueprint.yaml 
#    cfy local execute -w install
#    Not sure if needed
#    cfy local create-requirements -p cloudify-hello-world-example/blueprint.yaml
#    if [ $? -eq 1 ]; then fail; fi

    echo "vHello.sh: get vHello server address"
    SERVER_URL=$(cfy local outputs | awk "/http_endpoint/ { print \$2 }")
  fi

  echo "vHello.sh: verify vHello server is running"
  apt-get install -y curl
  if [[ $(curl $SERVER_URL | grep -c "Hello, World!") != 1 ]]; then fail; fi

  pass
}

clean() {
  echo "vHello.sh: activate cloudify Virtualenv"
  source ~/cloudify/venv/bin/activate

  echo "vHello.sh: setup OpenStack CLI environment"
  source /tmp/cloudify/admin-openrc.sh

  echo "vHello.sh: initialize cloudify environment"
  cd /tmp/cloudify/blueprints

 if [[ "$1" == "cloudify-manager" ]]; then 
    select_manager
    echo "vHello.sh: uninstall vHello blueprint via manager"
    cfy executions start -w uninstall -d vHello
    if [ $? -eq 1 ]; then fail; fi

    echo "vHello.sh: delete vHello blueprint"
    cfy deployments delete -d vHello
    if [ $? -eq 1 ]; then fail; fi
  else 
    echo "vHello.sh: uninstall vHello blueprint via CLI"
    cfy local uninstall
    if [ $? -eq 1 ]; then fail; fi
  fi
  pass
}

if [[ "$2" == "setup" ]]; then
  echo "vHello.sh: Setup temp test folder /tmp/cloudify and copy this script there"
  mkdir /tmp/cloudify
  chmod 777 /tmp/cloudify/
  cp $0 /tmp/cloudify/.
  chmod 755 /tmp/cloudify/*.sh

  echo "vHello.sh: cloudify-setup part 1"
  bash utils/cloudify-setup.sh $1 1

  echo "vHello.sh: cloudify-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/ ubuntu:xenial / { print \$1 }")
  sudo docker exec $CONTAINER /tmp/cloudify/cloudify-setup.sh $1 2
  if [ $? -eq 1 ]; then fail; fi
  pass
else
  if [[ $# -eq 3 ]]; then
    # running inside the cloudify container, ready to go
    if [[ "$3" == "start" ]]; then start $1; fi
    if [[ "$3" == "clean" ]]; then clean $1; fi    
  else
    echo "vHello.sh: pass $2 command to vHello.sh in cloudify container"
    CONTAINER=$(sudo docker ps -l | awk "/ ubuntu:xenial / { print \$1 }")
    sudo docker exec $CONTAINER /tmp/cloudify/vHello.sh $1 $2 $2
    if [ $? -eq 1 ]; then fail; fi
    pass
  fi
fi
