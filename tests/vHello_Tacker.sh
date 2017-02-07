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
# Newton.
#
# Pre-State: 
# This test can be run in either an OPNFV environment, or a plain OpenStack
# environment (e.g. Devstack). 
# For Devstack running in a VM on the host, you must first enable the host to 
#   access the VMs running under Devstack:
#   1) In devstack VM: 
#      $ sudo iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
#      Sub the primary interface of your devstack VM for ens3, as needed.
#   2) On the host (e.g linux): 
#      $ sudo route add -net 172.24.0.0/16 gw 192.168.122.112
#      Sub your devstack Public network subnet for 172.24.0.0/16, and 
#      your devstack VM IP address on the host for 192.168.122.112
# For OPNFV-based tests, pre-requisites are
#   1) models-joid-001 | models-apex-001 (installation of OPNFV system)
#
# Test Steps and Assertions:
# 1) bash vHello_Tacker.sh setup <openrc> [branch]
#   models-tacker-001 (Tacker installation in a docker container on the jumphost)
#   models-nova-001 (Keypair creation)
# 2) bash vHello_Tacker.sh start
#   models-tacker-002 (VNFD creation)
#   models-tacker-003 (VNF creation)
#   models-tacker-vnfd-001 (config_drive creation)
#   models-tacker-vnfd-002 (artifacts creation)
#   models-tacker-vnfd-003 (user_data creation)
#   models-vhello-001 (vHello VNF creation)
# 3) bash vHello_Tacker.sh stop
#   models-tacker-004 (VNF deletion)
#   models-tacker-005 (VNFD deletion)
#   models-tacker-vnfd-004 (artifacts deletion)
# 4) bash vHello_Tacker.sh clean
#   TODO: add assertions
#
# Post-State: 
# After step 1, Tacker is installed and active in a docker container, and the 
# test blueprint etc are prepared in a shared virtual folder /opt/tacker.
# After step 2, the VNF is running and verified.
# After step 3, the VNF is deleted and the system returned to step 1 post-state.
# After step 4, the system returned to test pre-state.
#
# Cleanup: bash vHello_Tacker.sh clean
#
# How to use:
#   $ git clone https://gerrit.opnfv.org/gerrit/models
#   $ cd models/tests
#   $ bash vHello_Tacker.sh [setup|run] [<openrc>] [branch]
#     setup: setup test environment
#     <openrc>: location of OpenStack openrc file
#     branch: OpenStack branch to install (default: master)
#   $ bash vHello_Tacker.sh [start|stop|clean]
#     run: setup test environment and run test
#     start: install blueprint and run test
#     stop: stop test and uninstall blueprint
#     clean: cleanup after test

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
    FLOATING_NETWORK_NAME=$(neutron net-show $FLOATING_NETWORK_ID | awk "/ name / { print \$4 }")
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
  echo "$0: $(date) Setup temp test folder /opt/tacker and copy this script there"
  if [ -d /opt/tacker ]; then sudo rm -rf /opt/tacker; fi 
  sudo mkdir -p /opt/tacker
  sudo chown $USER /opt/tacker
  chmod 777 /opt/tacker/
  cp $0 /opt/tacker/.
  cp $1 /opt/tacker/admin-openrc.sh

  source /opt/tacker/admin-openrc.sh
  chmod 755 /opt/tacker/*.sh

  echo "$0: $(date) tacker-setup part 1"
  bash utils/tacker-setup.sh init
  if [ $? -eq 1 ]; then fail; fi

  echo "$0: $(date) tacker-setup part 2"
# TODO: find a generic way to set extension_drivers = port_security in ml2_conf.ini
  # On the neutron service host, update ml2_conf.ini and and restart neutron service
  # sed -i -- 's~#extension_drivers =~extension_drivers = port_security~' /etc/neutron/plugins/ml2/ml2_conf.ini
  # For devstack, set in local.conf per http://docs.openstack.org/developer/devstack/guides/neutron.html
  # Q_ML2_PLUGIN_EXT_DRIVERS=port_security

  dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
  if [ "$dist" == "Ubuntu" ]; then
    dpkg -l juju
    if [[ $? -eq 0 ]]; then
      echo "$0: $(date) JOID workaround for Colorado - enable ML2 port security"
      juju set neutron-api enable-ml2-port-security=true
    fi

    echo "$0: $(date) Execute tacker-setup.sh in the container"
    sudo docker exec -it tacker /bin/bash /opt/tacker/tacker-setup.sh setup $2
    if [ $? -eq 1 ]; then fail; fi
  else
    echo "$0: $(date) Execute tacker-setup.sh in the container"
    sudo docker exec -i -t tacker /bin/bash /opt/tacker/tacker-setup.sh setup $2
    if [ $? -eq 1 ]; then fail; fi
  fi

  assert "models-tacker-001 (Tacker installation in a docker container on the jumphost)" true 

  echo "$0: $(date) reset blueprints folder"
  if [[ -d /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker ]]; then rm -rf /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker; fi
  mkdir -p /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker

  echo "$0: $(date) copy tosca-vnfd-hello-world-tacker to blueprints folder"
  cp -r blueprints/tosca-vnfd-hello-world-tacker /opt/tacker/blueprints
}

start() {
  echo "$0: $(date) setup OpenStack CLI environment"
  source /opt/tacker/admin-openrc.sh

  echo "$0: $(date) Create Nova key pair"
  if [[ -f /opt/tacker/vHello ]]; then rm /opt/tacker/vHello; fi
  ssh-keygen -t rsa -N "" -f /opt/tacker/vHello -C ubuntu@vHello
  chmod 600 /opt/tacker/vHello
  openstack keypair create --public-key /opt/tacker/vHello.pub vHello
  assert "models-nova-001 (Keypair creation)" true 

  echo "$0: $(date) Inject public key into blueprint"
  pubkey=$(cat /opt/tacker/vHello.pub)
  sed -i -- "s~<pubkey>~$pubkey~" /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker/blueprint.yaml

  echo "$0: $(date) Get external network for Floating IP allocations"
  get_floating_net

  echo "$0: $(date) create VNFD"
  cd /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker
  # newton: NAME (was "--name") is now a positional parameter
  tacker vnfd-create --vnfd-file blueprint.yaml hello-world-tacker
  assert "models-tacker-002 (VNFD creation)" [[ $? -eq 0 ]]

  echo "$0: $(date) create VNF"
  # newton: NAME (was "--name") is now a positional parameter
  tacker vnf-create --vnfd-name hello-world-tacker hello-world-tacker
  if [ $? -eq 1 ]; then fail; fi

  echo "$0: $(date) wait for hello-world-tacker to go ACTIVE"
  active=""
  while [[ -z $active ]]
  do
    active=$(tacker vnf-show hello-world-tacker | grep ACTIVE)
    if [[ $(tacker vnf-show hello-world-tacker | grep -c ERROR) > 0 ]]; then 
      echo "$0: $(date) hello-world-tacker VNF creation failed with state ERROR"
      assert "models-tacker-002 (VNF creation)" false
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
  if [[ $(neutron security-group-list | awk "/ vHello / { print \$2 }") ]]; then neutron security-group-delete vHello; fi
  neutron security-group-create vHello
  neutron security-group-rule-create --direction ingress --protocol TCP --port-range-min 22 --port-range-max 22 vHello
  neutron security-group-rule-create --direction ingress --protocol TCP --port-range-min 80 --port-range-max 80 vHello
  openstack server add security group $SERVER_ID vHello
  openstack server add security group $SERVER_ID default

  echo "$0: $(date) associate floating IP"
  get_floating_net
  FIP=$(nova floating-ip-create $FLOATING_NETWORK_NAME | awk "/public/ { print \$4 }")
  nova floating-ip-associate $SERVER_ID $FIP
  # End setup for workarounds

  echo "$0: $(date) get vHello server address"
  SERVER_IP=$(openstack server show $SERVER_ID | awk "/ addresses / { print \$6 }")
  SERVER_URL="http://$SERVER_IP"

  echo "$0: $(date) wait 30 seconds for vHello server to startup"
  sleep 30

  echo "$0: $(date) verify vHello server is running"
  apt-get install -y curl
  count=12
  while [[ $(curl $SERVER_URL | grep -c "Hello World") == 0 ]] 
  do 
    sleep 10
    let count=$count-1
  done
  if [[ $(curl $SERVER_URL | grep -c "Hello World") == 0 ]]; then fail; fi
  assert "models-vhello-001 (vHello VNF creation)" true 
  assert "models-vhello-001 (vHello VNF creation)" [[ $(curl $SERVER_URL | grep -c "Hello World") > 0 ]] 
  assert "models-tacker-003 (VNF creation)" true
  assert "models-tacker-vnfd-002 (artifacts creation)" true
  assert "models-tacker-vnfd-003 (user_data creation)" true

  echo "$0: $(date) verify contents of config drive are included in web page"
  id=$(curl $SERVER_URL | awk "/uuid/ { print \$2 }")
  assert "models-tacker-vnfd-001 (config_drive creation)" [[ -z "$id" ]]
}

stop() {
  echo "$0: $(date) setup OpenStack CLI environment"
  source /opt/tacker/admin-openrc.sh

  echo "$0: $(date) uninstall vHello blueprint via CLI"
  vid=($(tacker vnf-list|grep hello-world-tacker|awk '{print $2}')); for id in ${vid[@]}; do tacker vnf-delete ${id}; done
  assert "models-tacker-004 (VNF deletion)" [[ -z "$(tacker vnf-list|grep hello-world-tacker|awk '{print $2}')" ]]

  vid=($(tacker vnfd-list|grep hello-world-tacker|awk '{print $2}')); for id in ${vid[@]}; do try 10 10 "tacker vnfd-delete ${id}";  done
  assert "models-tacker-005 (VNFD deletion)" [[ -z "$(tacker vnfd-list|grep hello-world-tacker|awk '{print $2}')" ]]

  for id in ${sg[@]}; do try 5 5 "openstack security group delete ${id}";  done

  iid=($(openstack image list|grep VNFImage|awk '{print $2}')); for id in ${iid[@]}; do openstack image delete ${id};  done
  assert "models-tacker-vnfd-004 (artifacts deletion)" [[ -z "$(openstack image list|grep VNFImage|awk '{print $2}')" ]]

  # Cleanup for workarounds
  fip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${fip[@]}; do neutron floatingip-delete ${id};  done
  sg=($(openstack security group list|grep vHello|awk '{print $2}'))
  for id in ${sg[@]}; do try 5 5 "openstack security group delete ${id}";  done
  kid=($(openstack keypair list|grep vHello|awk '{print $2}')); for id in ${kid[@]}; do openstack keypair delete ${id};  done
}

forward_to_container () {
  echo "$0: $(date) pass $1 command to vHello.sh in tacker container"
  CONTAINER=$(sudo docker ps -a | awk "/tacker/ { print \$1 }")
  sudo docker exec $CONTAINER /bin/bash /opt/tacker/vHello_Tacker.sh $1
  if [ $? -eq 1 ]; then fail; fi
}

test_start=`date +%s`
dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

case "$1" in
  setup)
    setup $2 $3
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  run)
    setup $2 $3
    forward_to_container start
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  start|stop)
    if [[ -f /.dockerenv ]]; then
      $1
    else
      forward_to_container $1
    fi
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  clean)
    echo "$0: $(date) Uninstall Tacker and test environment"
    forward_to_container stop
    sudo docker exec -it tacker /bin/bash /opt/tacker/tacker-setup.sh clean
    sudo docker stop tacker
    sudo docker rm -v tacker
    sudo rm -rf /opt/tacker
    pass
    ;;
  *)
    echo "usage: bash vHello_Tacker.sh [setup|start|run|stop|clean]"
    echo "setup: setup test environment"
    echo "start: install blueprint and run test"
    echo "run: setup test environment and run test"
    echo "stop: stop test and uninstall blueprint"
    echo "clean: cleanup after test"
    fail
esac
