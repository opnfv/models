#!/bin/bash
# Copyright 2016-2017 AT&T Intellectual Property, Inc
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
# What this is: 3-Node Hello World blueprint deployment test for the OPNFV Models
# project, using Tacker as VNFM.
#
# Status: this is a work in progress, under test.
#
# Use Case Description: A three-node deployment with two simple python web 
# servers and a load balancer, connected to two internal networks (private and 
# admin), and accessible via a floating IP. Based upon the OpenStack Tacker 
# project's "tosca-vnfd-hello-world" blueprint, as extended for testing of more
# Tacker-supported features as of OpenStack Newton.
#
# Prerequisites: 
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
#   Also you may need to ensure that nested virtualization is enabled, e.g. in 
#   virt-manager, enable "Copy host CPU confguraton" for the devstack VM.
#
# For OPNFV-based tests, prerequisites are
#   1) models-joid-001 | models-apex-001 (installation of OPNFV system)
#      The test may work, but has not been tested for other OPNFV installers.
#
# Test Steps and Assertions:
# 1) bash vHello_3Node_Tacker.sh setup <openrc> [branch]
#   models-tacker-001 (Tacker installation in a docker container on the jumphost)
#   models-nova-001 (Keypair creation)
# 2) bash vHello_3Node_Tacker.sh start
#   models-tacker-002 (VNFD creation)
#   models-tacker-003 (VNF creation)
#   models-tacker-vnfd-001 (config_drive creation)
#   models-tacker-vnfd-002 (artifacts creation)
#   models-tacker-vnfd-003 (user_data creation)
#   models-vhello-001 (vHello VNF creation)
# 3) bash vHello_3Node_Tacker.sh stop
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
#   $ bash vHello_3Node_Tacker.sh [setup|run] [<openrc>] [branch]
#     setup: setup test environment
#     <openrc>: location of OpenStack openrc file
#     branch: OpenStack branch to install (default: master)
#   $ bash vHello_3Node_Tacker.sh [start|stop|clean]
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
  if [[ $2 == true ]]; then echo "$0 test assertion passed: $1"
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
  while [[ $? == 1 && $count > 0 ]]; do 
    sleep $2
    let count=$count-1
    $3
  done
  if [[ $count -eq 0 ]]; then echo "$0: $(date) Command \"$3\" was not successful after $1 tries"; fi
}

setup () {
  trap 'fail' ERR
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
}

say_hello() {
  echo "$0: $(date) Testing $1"
  pass=false
  count=6
  while [[ $count > 0 && $pass != true ]] 
  do 
    sleep 10
    let count=$count-1
    if [[ $(curl $1 | grep -c "Hello World") > 0 ]]; then
      echo "$0: $(date) Hello World found at $1"
      pass=true
    fi
  done
  if [[ $pass != true ]]; then fail; fi
}

copy_blueprint() {
  echo "$0: $(date) reset blueprints folder"
  if [[ -d /opt/tacker/blueprints/tosca-vnfd-3node-tacker ]]; then 
    rm -rf /opt/tacker/blueprints/tosca-vnfd-3node-tacker
  fi

  echo "$0: $(date) copy tosca-vnfd-3node-tacker to blueprints folder"
  cp -r blueprints/tosca-vnfd-3node-tacker /opt/tacker/blueprints/tosca-vnfd-3node-tacker
  cp $0 /opt/tacker/.
}


start() {
  trap 'fail' ERR

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
  sed -i -- "s~<pubkey>~$pubkey~g" /opt/tacker/blueprints/tosca-vnfd-3node-tacker/blueprint.yaml

  vdus="VDU1 VDU2 VDU3"
  vdui="1 2 3"
  declare -a vdu_id=()
  declare -a vdu_ip=()
  declare -a vdu_url=()

  # Setup for workarounds
  echo "$0: $(date) allocate floating IPs"
  get_floating_net
  for i in $vdui; do
    vdu_ip[$i]=$(nova floating-ip-create $FLOATING_NETWORK_NAME | awk "/$FLOATING_NETWORK_NAME/ { print \$4 }")
    echo "$0: $(date) Pre-allocated ${vdu_ip[$i]} to VDU$i"
  done

  echo "$0: $(date) Inject web server floating IPs into LB code in blueprint"
  sed -i -- "s/<vdu1_ip>/${vdu_ip[1]}/" /opt/tacker/blueprints/tosca-vnfd-3node-tacker/blueprint.yaml
  sed -i -- "s/<vdu2_ip>/${vdu_ip[2]}/" /opt/tacker/blueprints/tosca-vnfd-3node-tacker/blueprint.yaml
  # End setup for workarounds

  echo "$0: $(date) create VNFD"
  cd /opt/tacker/blueprints/tosca-vnfd-3node-tacker
  # newton: NAME (was "--name") is now a positional parameter
  tacker vnfd-create --vnfd-file blueprint.yaml hello-3node
  if [[ $? -eq 0 ]]; then 
    assert "models-tacker-002 (VNFD creation)" true
  else
    assert "models-tacker-002 (VNFD creation)" false
  fi

  echo "$0: $(date) create VNF"
  # newton: NAME (was "--name") is now a positional parameter
  tacker vnf-create --vnfd-name hello-3node hello-3node
  if [ $? -eq 1 ]; then fail; fi

  echo "$0: $(date) wait for hello-3node to go ACTIVE"
  active=""
  count=48
  while [[ -z $active && $count -gt 0 ]]
  do
    active=$(tacker vnf-show hello-3node | grep ACTIVE)
    if [ "$(tacker vnf-show hello-3node | grep -c ERROR)" == "1" ]; then 
      echo "$0: $(date) hello-3node VNF creation failed with state ERROR"
      fail
    fi
    let count=$count-1
    sleep 30
    echo "$0: $(date) wait for hello-3node to go ACTIVE"
  done
  if [[ $count == 0 ]]; then 
    echo "$0: $(date) hello-world-tacker VNF creation failed - timed out"
    assert "models-tacker-002 (VNF creation)" false
  fi
  assert "models-tacker-002 (VNF creation)" true

  # Workarounds
  echo "$0: $(date) directly set port security on ports (bug/unsupported in Mitaka Tacker?)"
  for vdu in $vdus; do
    echo "$0: $(date) Setting port security on $vdu"  
    SERVER_ID=$(openstack server list | awk "/$vdu/ { print \$2 }")
    id=($(neutron port-list|grep -v "+"|grep -v name|awk '{print $2}'))
    for id in ${id[@]}; do
      if [[ $(neutron port-show $id|grep $SERVER_ID) ]]; then neutron port-update ${id} --port-security-enabled=True; fi
    done
  done

  echo "$0: $(date) directly assign security group (unsupported in Mitaka Tacker)"
  if [[ $(neutron security-group-list | awk "/ vHello / { print \$2 }") ]]; then neutron security-group-delete vHello; fi
  neutron security-group-create vHello
  neutron security-group-rule-create --direction ingress --protocol TCP --port-range-min 22 --port-range-max 22 vHello
  neutron security-group-rule-create --direction ingress --protocol TCP --port-range-min 80 --port-range-max 80 vHello
  for i in $vdui; do
    vdu_id[$i]=$(openstack server list | awk "/VDU$i/ { print \$2 }")
    echo "$0: $(date) Assigning security groups to VDU$i (${vdu_id[$i]})"    
    openstack server add security group ${vdu_id[$i]} vHello
    openstack server add security group ${vdu_id[$i]} default
  done

  echo "$0: $(date) associate floating IPs"
  for i in $vdui; do
    nova floating-ip-associate ${vdu_id[$i]} ${vdu_ip[$i]}
  done

  echo "$0: $(date) get web server internal and LB addresses"
  vdu_url[1]="http://${vdu_ip[1]}"
  vdu_url[2]="http://${vdu_ip[2]}"
  vdu_url[3]="http://${vdu_ip[2]}"

  echo "$0: $(date) verify vHello server is running at each web server and via the LB"
  apt-get install -y curl
  say_hello http://${vdu_ip[1]}
  say_hello http://${vdu_ip[2]}
  say_hello http://${vdu_ip[3]}
}

stop() {
  trap 'fail' ERR

  echo "$0: $(date) setup OpenStack CLI environment"
  source /opt/tacker/admin-openrc.sh

  echo "$0: $(date) uninstall vHello blueprint via CLI"
  vdus="VDU1 VDU2 VDU3"
  for vdu in $vdus; do
    get_vdu_info $vdu
    if [[ ! -z $id ]]; then
      echo "$0: $(date) disassociate floating ip for $vdu"
      nova floating-ip-disassociate $id $ip
    else
      echo "$0: $(date) No instance for $vdu found"
    fi
  done

  if [[ "$(tacker vnf-list|grep hello-3node|awk '{print $2}')" != '' ]]; then
    echo "$0: $(date) uninstall vHello blueprint via CLI"
    try 12 10 "tacker vnf-delete hello-3node"
    # It can take some time to delete a VNF - thus wait 2 minutes
    count=12
    while [[ $count > 0 && "$(tacker vnf-list|grep hello-3node|awk '{print $2}')" != '' ]]; do 
      sleep 10
      let count=$count-1
    done 
    if [[ "$(tacker vnf-list|grep hello-3node|awk '{print $2}')" == '' ]]; then
      assert "models-tacker-004 (VNF deletion)" true
    else
      assert "models-tacker-004 (VNF deletion)" false
    fi
  else echo "$0: $(date) No hello-3node VNF instance found"
  fi

  # It can take some time to delete a VNFD - thus wait 2 minutes
  if [[ "$(tacker vnfd-list|grep hello-3node|awk '{print $2}')" != '' ]]; then
    try 12 10 "tacker vnfd-delete hello-3node"
    if [[ "$(tacker vnfd-list|grep hello-3node|awk '{print $2}')" == '' ]]; then
      assert "models-tacker-005 (VNFD deletion)" true
    else
      assert "models-tacker-005 (VNFD deletion)" false
    fi
  else echo "$0: $(date) No hello-3node VNFD found"
  fi

  if [[ ! -z $(openstack image list|grep VNFImage|awk '{print $2}') ]]; then
    iid=($(openstack image list|grep VNFImage|awk '{print $2}')); for id in ${iid[@]}; do openstack image delete ${id};  done
    if [[ "$(openstack image list|grep VNFImage|awk '{print $2}')" == '' ]]; then
      assert "models-tacker-vnfd-004 (artifacts deletion)" true
    else
      assert "models-tacker-vnfd-004 (artifacts deletion)" false
    fi
  else echo "$0: $(date) No VNFImage found"
  fi

  # Cleanup for workarounds
  fip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${fip[@]}; do neutron floatingip-delete ${id};  done
  sg=($(openstack security group list|grep vHello|awk '{print $2}'))
  for id in ${sg[@]}; do try 5 5 "openstack security group delete ${id}";  done
}

#
# Test tools and scenarios
#

get_vdu_info () {
  id=$(openstack server list | awk "/$1/ { print \$2 }")
  ip=$(openstack server list | awk "/$1/ { print \$10 }")
}

forward_to_container () {
  echo "$0: $(date) pass $1 command to this script in the tacker container"
  CONTAINER=$(sudo docker ps -a | awk "/tacker/ { print \$1 }")
  sudo docker exec $CONTAINER /bin/bash /opt/tacker/vHello_3Node_Tacker.sh $1
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
    copy_blueprint
    forward_to_container start
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  start)
    if [[ -f /.dockerenv ]]; then
      start
    else
      copy_blueprint
      forward_to_container start
    fi
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  stop)
    if [[ -f /.dockerenv ]]; then
      stop
    else
      forward_to_container stop		
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
    echo "usage: "
    echo "$ bash vHello_3Node_Tacker.sh [setup|run] [<openrc>] [branch]"
    echo "  setup: setup test environment"
    echo "  <openrc>: location of OpenStack openrc file"
    echo "  branch: OpenStack branch to install (default: master)"
    echo "$ bash vHello_3Node_Tacker.sh [start|stop|clean]"
    echo "  run: setup test environment and run test"
    echo "  start: install blueprint and run test"
    echo "  stop: stop test and uninstall blueprint"
    echo "  clean: cleanup after test"
    fail
esac
