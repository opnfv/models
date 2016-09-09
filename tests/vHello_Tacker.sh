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
#   $ bash vHello_Tacker.sh [tacker-cli|tacker-api] [setup|start|clean]
#   tacker-cli: use Tacker CLI
#   tacker-api: use Tacker RESTful API (not yet implemented)
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

start() {
  echo "$0: reset blueprints folder"
  if [[ -d /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker ]]; then rm -rf /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker; fi
  mkdir -p /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker

  echo "$0: copy tosca-vnfd-hello-world-tacker to blueprints folder"
  cp -r blueprints/tosca-vnfd-hello-world-tacker /tmp/tacker/blueprints
  cd /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker

  echo "$0: setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: Setup image_id"
  image_id=$(openstack image list | awk "/ models-xenial-server / { print \$2 }")
  if [ $image ]; then glance image-delete $image_id; fi
  glance --os-image-api-version 1 image-create --name models-xenial-server --disk-format qcow2 --location http://bkaj.net/opnfv/xenial-server-cloudimg-amd64-disk1.img --container-format bare
  
  if [[ "$1" == "tacker-api" ]]; then 
    echo "$0: Tacker API use is not yet implemented"
  else
    # Tacker CLI use
    echo "$0: Get external network for Floating IP allocations"

#    echo "$0: Create Nova key pair"
#    mkdir -p ~/.ssh
#    nova keypair-delete vHello
#    nova keypair-add vHello > ~/.ssh/vHello.pem
#    chmod 600 ~/.ssh/vHello.pem
    
    echo "$0: create VNFD"
    tacker vnfd-create --vnfd-file tosca-vnfd-hello-world-tacker.yaml --name hello-world-tacker
    if [ $? -eq 1 ]; then fail; fi

    echo "$0: create VNF"
    tacker vnf-create --vnfd-name hello-world-tacker --name hello-world-tacker
    if [ $? -eq 1 ]; then fail; fi
  fi
  
  echo "$0: directly set port security on ports (bug/unsupported in Mitaka Tacker?)"
  HEAT_ID=$(tacker vnf-show hello-world-tacker | awk "/instance_id/ { print \$4 }")
  SERVER_ID=$(openstack stack resource list $HEAT_ID | awk "/VDU1 / { print \$4 }")
  id=($(neutron port-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${id[@]}; do 
    if [[ $(neutron port-show $id|grep $SERVER_ID) ]]; then neutron port-update ${id} --port-security-enabled=True; fi
  done

  echo "$0: directly assign security group (unsupported in Mitaka Tacker)"
  if [[ $(neutron security-group-list | awk "/ vHello / { print \$2 }") ]]; then neutron security-group-delete vHello; fi
  neutron security-group-create vHello
  neutron security-group-rule-create --direction ingress --protocol=TCP --port-range-min=22 --port-range-max=22 vHello
  neutron security-group-rule-create --direction ingress --protocol=TCP --port-range-min=80 --port-range-max=80 vHello
  openstack server add security group $SERVER_ID vHello
  openstack server add security group $SERVER_ID default
 
  echo "$0: associate floating IP"
  get_floating_net
  fip=$(neutron floatingip-create $floating_network_name | awk "/floating_ip_address/ { print \$4 }")
  nova floating-ip-associate $SERVER_ID $fip
  
  echo "$0: get vHello server address"
  SERVER_IP=$(openstack server show $SERVER_ID | awk "/ addresses / { print \$6 }")
  SERVER_URL="http://$SERVER_IP"
		
  echo "$0: start vHello web server"
  scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no start.sh opnfv:opnfv@$SERVER_IP:/home/opnfv
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no opnfv:opnfv@$SERVER_IP "bash start.sh; exit"

  echo "$0: verify vHello server is running"
  if [[ $(curl $SERVER_URL | grep -c "Hello, World!") != 1 ]]; then fail; fi

  pass
}

clean() {
  echo "$0: setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

 if [[ "$1" == "tacker-api" ]]; then 
    echo "$0: Tacker API use is not yet implemented"
  else 
    echo "$0: uninstall vHello blueprint via CLI"
    tacker vnf-delete tosca-hello-world
    if [ $? -eq 1 ]; then fail; fi
    tacker vnfd-delete tosca-hello-world
    if [ $? -eq 1 ]; then fail; fi
    neutron security-group-delete vHello
    if [ $? -eq 1 ]; then fail; fi
    fip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${fip[@]}; do neutron floatingip-delete ${id};  done
    if [ $? -eq 1 ]; then fail; fi
  fi
  pass
}

if [[ "$2" == "setup" ]]; then
  echo "$0: Setup temp test folder /tmp/tacker and copy this script there"
  mkdir /tmp/tacker
  chmod 777 /tmp/tacker/
  cp $0 /tmp/tacker/.
  chmod 755 /tmp/tacker/*.sh

  echo "$0: tacker-setup part 1"
  bash utils/tacker-setup.sh $1 init

  echo "$0: tacker-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/tacker/ { print \$1 }")
  sudo docker exec $CONTAINER /tmp/tacker/tacker-setup.sh $1 setup
  if [ $? -eq 1 ]; then fail; fi
  pass
else
  if [[ $# -eq 3 ]]; then
    # running inside the tacker container, ready to go
    if [[ "$3" == "start" ]]; then start $1; fi
    if [[ "$3" == "clean" ]]; then clean $1; fi    
  else
    echo "$0: pass $2 command to vHello.sh in tacker container"
    CONTAINER=$(sudo docker ps -a | awk "/tacker/ { print \$1 }")
    sudo docker exec $CONTAINER /tmp/tacker/vHello.sh $1 $2 $2
    if [ $? -eq 1 ]; then fail; fi
    pass
  fi
fi
