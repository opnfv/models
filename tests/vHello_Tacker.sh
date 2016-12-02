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
# Status: work in progress, planned for OPNFV Danube release.
#
# Use Case Description: A single-node simple python web server, connected to
# two internal networks (private and admin), and accessible via a floating IP.
# Based upon the OpenStack Tacker project's "tosca-vnfd-hello-world" blueprint,
# as extended for testing of more Tacker-supported features as of OpenStack 
# Mitaka.
#
# Prequisites: 
#
#
# How to use:
#   $ git clone https://gerrit.opnfv.org/gerrit/models
#   $ cd models/tests
#   $ bash vHello_Tacker.sh [tacker-cli|tacker-api] [setup|start|run|stop|clean]
#   tacker-cli: use Tacker CLI
#   tacker-api: use Tacker RESTful API (not yet implemented)
#   setup: setup test environment
#   start: install blueprint and run test
#   run: setup test environment and run test
#   stop: stop test and uninstall blueprint
#   clean: cleanup after test

trap 'fail' ERR

pass() {
  echo "$0: $(date) Hooray!"
  end=`date +%s`
  runtime=$((end-test_start))
  echo "$0: $(date) Test Duration = $runtime seconds"
  exit 0
}

fail() {
  echo "$0: $(date) Test Failed!"
  end=`date +%s`
  runtime=$((end-test_start))
  runtime=$((runtime/60))
  echo "$0: $(date) Test Duration = $runtime seconds"
  exit 1
}

assert() {
  if [[ "$2" ]]; then echo "$0 test assertion passed: $1"
  else 
    echo "$0 test assertion failed: $1"
    fail
  fi
}

get_floating_net () {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${network_ids[@]}; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && FLOATING_NETWORK_ID=${id}
  done
  if [[ $FLOATING_NETWORK_ID ]]; then
    FLOATING_NETWORK_NAME=$(openstack network show $FLOATING_NETWORK_ID | awk "/ name / { print \$4 }")
  else
    echo "$0: $(date) Floating network not found"
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
  if [[ $count -eq 0 ]]; then echo "$0: $(date) Command \"$3\" was not successful after $1 tries"; fi
}

setup () {
  echo "$0: $(date) Setup temp test folder /tmp/tacker and copy this script there"
  if [ -d /tmp/tacker ]; then sudo rm -rf /tmp/tacker; fi 
  mkdir -p /tmp/tacker
  chmod 777 /tmp/tacker/
  cp $0 /tmp/tacker/.
  chmod 755 /tmp/tacker/*.sh

  echo "$0: $(date) tacker-setup part 1"
  bash utils/tacker-setup.sh $1 init

  echo "$0: $(date) tacker-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/tacker/ { print \$1 }")
  dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: $(date) JOID workaround for Colorado - enable ML2 port security"
    juju set neutron-api enable-ml2-port-security=true

    echo "$0: $(date) Execute tacker-setup.sh in the container"
    sudo docker exec -it $CONTAINER /bin/bash /tmp/tacker/tacker-setup.sh $1 setup
  else
    echo "$0: $(date) Execute tacker-setup.sh in the container"
    sudo docker exec -i -t $CONTAINER /bin/bash /tmp/tacker/tacker-setup.sh $1 setup
  fi

  assert "models-tacker-001 (Tacker installation in a docker container on the jumphost)" true 

  echo "$0: $(date) reset blueprints folder"
  if [[ -d /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker ]]; then rm -rf /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker; fi
  mkdir -p /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker

  echo "$0: $(date) copy tosca-vnfd-hello-world-tacker to blueprints folder"
  cp -r blueprints/tosca-vnfd-hello-world-tacker /tmp/tacker/blueprints

  echo "$0: $(date) setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: $(date) Create Nova key pair"
  if [[ -f /tmp/tacker/vHello ]]; then rm /tmp/tacker/vHello; fi
  ssh-keygen -t rsa -N "" -f /tmp/tacker/vHello -C ubuntu@vHello
  chmod 600 /tmp/tacker/vHello
  openstack keypair create --public-key /tmp/tacker/vHello.pub vHello
  assert "models-nova-001 (Keypair creation)" true 

  echo "$0: $(date) Inject public key into blueprint"
  pubkey=$(cat /tmp/tacker/vHello.pub)
  sed -i -- "s~<pubkey>~$pubkey~" /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker/blueprint.yaml
}

start() {
  echo "$0: $(date) setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: $(date) Get external network for Floating IP allocations"

  echo "$0: $(date) create VNFD"
  cd /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker
  tacker vnfd-create --vnfd-file blueprint.yaml --name hello-world-tacker
  if [ $? -eq 1 ]; then fail; fi
  assert "models-tacker-002 (VNFD creation)" true 

  echo "$0: $(date) create VNF"
  tacker vnf-create --vnfd-name hello-world-tacker --name hello-world-tacker
  if [ $? -eq 1 ]; then fail; fi

  echo "$0: $(date) wait for hello-world-tacker to go ACTIVE"
  active=""
  while [[ -z $active ]]
  do
    active=$(tacker vnf-show hello-world-tacker | grep ACTIVE)
    if [ "$(tacker vnf-show hello-world-tacker | grep -c ERROR)" == "1" ]; then 
      echo "$0: $(date) hello-world-tacker VNF creation failed with state ERROR"
      fail
    fi
    sleep 10
    echo "$0: $(date) wait for hello-world-tacker to go ACTIVE"
  done
  assert "models-tacker-002 (VNF creation)" true 

  # Setup for workarounds
  echo "$0: $(date) directly set port security on ports (unsupported in Mitaka Tacker)"
  # Alternate method
  #  HEAT_ID=$(tacker vnf-show hello-world-tacker | awk "/instance_id/ { print \$4 }")
  #  SERVER_ID=$(openstack stack resource list $HEAT_ID | awk "/VDU1 / { print \$4 }")
  SERVER_ID=$(openstack server list | awk "/VDU1/ { print \$2 }")
  id=($(neutron port-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${id[@]}; do
    if [[ $(neutron port-show $id|grep $SERVER_ID) ]]; then neutron port-update ${id} --port-security-enabled=True; fi
  done

  echo "$0: $(date) directly assign security group (unsupported in Mitaka Tacker)"
  if [[ $(openstack security group list | awk "/ vHello / { print \$2 }") ]]; then openstack security group vHello; fi
  openstack security group create vHello
  openstack security group rule create --ingress --protocol TCP --dst-port 22:22 vHello
  openstack security group rule create --ingress --protocol TCP --dst-port 80:80 vHello
  openstack server add security group $SERVER_ID vHello
  openstack server add security group $SERVER_ID default

  echo "$0: $(date) associate floating IP"
  get_floating_net
  FIP=$(openstack floating ip create $FLOATING_NETWORK_NAME | awk "/floating_ip_address/ { print \$4 }")
  nova floating-ip-associate $SERVER_ID $FIP
  # End setup for workarounds

  echo "$0: $(date) get vHello server address"
  SERVER_IP=$(openstack server show $SERVER_ID | awk "/ addresses / { print \$6 }")
  SERVER_URL="http://$SERVER_IP"

  echo "$0: $(date) wait 30 seconds for vHello server to startup"
  sleep 30

  echo "$0: $(date) verify vHello server is running"
  apt-get install -y curl
  if [[ $(curl $SERVER_URL | grep -c "Hello World") == 0 ]]; then fail; fi
  assert "models-vhello-001 (vHello VNF creation)" true 
  assert "models-tacker-003 (VNF creation)" true
  assert "models-tacker-vnfd-002 (artifacts creation)" true
  assert "models-tacker-vnfd-003 (user_data creation)" true

  echo "$0: $(date) verify contents of config drive are included in web page"
  id=$(curl $SERVER_URL | awk "/uuid/ { print \$2 }")
  if [[ -z "$id" ]]; then fail; fi
  assert "models-tacker-vnfd-001 (config_drive creation)" true 
}

stop() {
  echo "$0: $(date) setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: $(date) uninstall vHello blueprint via CLI"
  vid=($(tacker vnf-list|grep hello-world-tacker|awk '{print $2}')); for id in ${vid[@]}; do tacker vnf-delete ${id}; done
  assert "models-tacker-004 (VNF deletion)" [[ -z "$(tacker vnf-list|grep hello-world-tacker|awk '{print $2}'))" ]]

  vid=($(tacker vnfd-list|grep hello-world-tacker|awk '{print $2}')); for id in ${vid[@]}; do tacker vnfd-delete ${id};  done
  assert "models-tacker-005 (VNFD deletion)" [[ -z "$(tacker vnfd-list|grep hello-world-tacker|awk '{print $2}'))" ]]

  iid=($(openstack image list|grep VNFImage|awk '{print $2}')); for id in ${iid[@]}; do openstack image delete ${id};  done
  assert "models-tacker-vnfd-004 (artifacts deletion)" [[ -z "$(openstack image list|grep VNFImage|awk '{print $2}'))" ]]

  # Cleanup for workarounds
  fip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${fip[@]}; do neutron floatingip-delete ${id};  done
  sg=($(openstack security group list|grep vHello|awk '{print $2}'))
  for id in ${sg[@]}; do try 5 5 "openstack security group delete ${id}";  done
  kid=($(openstack keypair list|grep vHello|awk '{print $2}')); for id in ${kid[@]}; do openstack keypair delete ${id};  done
}

forward_to_container () {
  echo "$0: $(date) pass $2 command to vHello.sh in tacker container"
  CONTAINER=$(sudo docker ps -a | awk "/tacker/ { print \$1 }")
  sudo docker exec $CONTAINER /bin/bash /tmp/tacker/vHello_Tacker.sh $1 $2 $2
  if [ $? -eq 1 ]; then fail; fi
}

test_start=`date +%s`
dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

if [[ "$1" == "tacker-api" ]]; then
  echo "$0: $(date) Tacker API use is not yet implemented"
  fail
fi

case "$2" in
  setup)
    setup $1
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  run)
    setup $1
    forward_to_container $1 start
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  start|stop)
    if [[ $# -eq 2 ]]; then forward_to_container $1 $2
    else
      # running inside the tacker container, ready to go
      $2 $1
    fi
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  clean)
    forward_to_container stop $2
    echo "$0: $(date) Uninstall Tacker and test environment"
    bash utils/tacker-setup.sh $1 clean
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  *)
    echo "usage: bash vHello_Tacker.sh [tacker-cli|tacker-api] [setup|start|run|clean]"
    echo "tacker-cli: use Tacker CLI"
    echo "tacker-api: use Tacker RESTful API (not yet implemented)"
    echo "setup: setup test environment"
    echo "start: install blueprint and run test"
    echo "run: setup test environment and run test"
    echo "stop: stop test and uninstall blueprint"
    echo "clean: cleanup after test"
    fail
esac
