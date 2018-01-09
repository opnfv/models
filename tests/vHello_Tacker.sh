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
# What this is: Deployment test for the Tacker Hello World blueprint.
#
# Status: this is a work in progress, under test.
#
# Use Case Description: A single-node simple python web server, connected to
# two internal networks (private and admin), and accessible via a floating IP.
# Based upon the OpenStack Tacker project's "tosca-vnfd-hello-world" blueprint,
# as extended for testing of more Tacker-supported features as of OpenStack
# Newton.
#
# Prerequisites:
# This test can be run in either an OPNFV environment or a plain OpenStack
# environment (e.g. DevStack).
# For Devstack running in a VM on the host, you must first enable the host to
#   access the VMs running under DevStack:
#   1) In Devstack VM:
#      $ sudo iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
#      Sub the primary interface of your devstack VM for ens3, as needed.
#   2) On the host (e.g linux):
#      $ sudo route add -net 172.24.0.0/16 gw 192.168.122.112
#      Sub your devstack Public network subnet for 172.24.0.0/16, and
#      your Devstack VM IP address on the host for 192.168.122.112
#   Also you may need to ensure that nested virtualization is enabled, e.g. in
#   virt-manager, enable "Copy host CPU confguraton" for the Devstack VM.
#
# For OPNFV-based tests, prerequisites are
#   1) models-joid-001 | models-apex-001 (installation of OPNFV system)
#      The test may work, but has not been tested for other OPNFV installers.
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
#.How to use:
#.  $ git clone https://gerrit.opnfv.org/gerrit/models
#.  $ cd models/tests
#.  $ bash vHello_Tacker.sh <setup|run> <openrc> [branch]
#.    setup: setup test environment
#.    openrc: location of OpenStack openrc file
#.    branch: OpenStack branch to install (default: master)
#.  $ source ~/venv/bin/activate
#.    This is needed to use the OpenStack clients in the following steps.
#.  $ bash vHello_Tacker.sh <start|stop|clean>
#.    run: setup test environment and run test
#.    start: install blueprint and run test
#.    stop: stop test and uninstall blueprint
#.    clean: cleanup after test

trap 'fail' ERR

function ignore() {
  log "last command failed, but continuing anyway (fail on err is disabled...)"
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

pass() {
  log "Hooray!"
  end=`date +%s`
  runtime=$((end-test_start))
  log "Test Duration = $runtime seconds"
  exit 0
}

fail() {
  log "Test Failed!"
  end=`date +%s`
  runtime=$((end-test_start))
  runtime=$((runtime/60))
  log "Test Duration = $runtime seconds"
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
  for id in "${network_ids[@]}"; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && FLOATING_NETWORK_ID=${id}
  done
  if [[ $FLOATING_NETWORK_ID ]]; then
    FLOATING_NETWORK_NAME=$(neutron net-show $FLOATING_NETWORK_ID | awk "/ name / { print \$4 }")
  else
    log "Floating network not found"
    exit 1
  fi
}

function get_external_net() {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in "${network_ids[@]}"; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && ext_net_id=${id}
  done
  if [[ $ext_net_id ]]; then
    EXTERNAL_NETWORK_NAME=$(neutron net-show $ext_net_id | awk "/ name / { print \$4 }")
    EXTERNAL_SUBNET_ID=$(neutron net-show $EXTERNAL_NETWORK_NAME | awk "/ subnets / { print \$4 }")
  else
    log "External network not found"
    exit 1
  fi
}

try () {
  count=$1
  $3
  while [[ $? == 1 && $count -gt 0 ]]; do
    sleep $2
    let count=$count-1
    $3
  done
  if [[ $count -eq 0 ]]; then log "Command \"$3\" was not successful after $1 tries"; fi
}

setup () {
  trap 'fail' ERR

  log "run tacker-setup.sh"
  bash utils/tacker-setup.sh setup $openrc $branch
  if [ $? -eq 1 ]; then fail; fi
  assert "models-tacker-001 (Tacker installation in a docker container on the jumphost)" true

  log "Install OpenStack clients"
  source ../tools/setup_osc.sh $branch
  source ~/venv/bin/activate

  log "Install python-tackerclient"
  cd ~/venv/git
  git clone https://github.com/openstack/python-tackerclient.git
  cd python-tackerclient
  pip install .
  cd ..

  log "Setup OpenStack CLI environment"
  source $openrc

  log "Create image models-xenial-server"
  image_id=$(openstack image list | awk "/ models-xenial-server / { print \$2 }")
  if [[ -z "$image_id" ]]; then
    wget http://cloud-images.ubuntu.com/releases/xenial/release/ubuntu-16.04-server-cloudimg-amd64-disk1.img \
      -O ~/ubuntu-16.04-server-cloudimg-amd64-disk1.img
    glance image-create --name models-xenial-server --disk-format qcow2 --container-format bare
    image_id=$(openstack image list | awk "/ models-xenial-server / { print \$2 }")
    glance image-upload --file ~/ubuntu-16.04-server-cloudimg-amd64-disk1.img $image_id
   fi

  log "Create management network"
  if [ $(neutron net-list | awk "/ vnf_mgmt / { print \$2 }") ]; then
    log "vnf_mgmt network exists"
  else
    neutron net-create vnf_mgmt
    log "Create management subnet"
    neutron subnet-create vnf_mgmt 192.168.200.0/24 --name vnf_mgmt --gateway 192.168.200.1 --enable-dhcp --allocation-pool start=192.168.200.2,end=192.168.200.254 --dns-nameserver 8.8.8.8
  fi

  log "Create router for vnf_mgmt network"
  if [ $(neutron router-list | awk "/ vnf_mgmt / { print \$2 }") ]; then
    log "vnf_mgmt router exists"
  else
    neutron router-create vnf_mgmt_router
    log "Create router gateway for vnf_mgmt network"
    get_external_net
    neutron router-gateway-set vnf_mgmt_router $EXTERNAL_NETWORK_NAME
    log "Add router interface for vnf_mgmt network"
    neutron router-interface-add vnf_mgmt_router subnet=vnf_mgmt
  fi

  echo "Create private network"
  if [ $(neutron net-list | awk "/ vnf_private / { print \$2 }") ]; then
    log "vnf_private network exists"
  else
    neutron net-create vnf_private
    log "Create private subnet"
    neutron subnet-create vnf_private 192.168.201.0/24 --name vnf_private --gateway 192.168.201.1 --enable-dhcp --allocation-pool start=192.168.201.2,end=192.168.201.254 --dns-nameserver 8.8.8.8
  fi

  log "Create router for vnf_private network"
  if [ $(neutron router-list | awk "/ vnf_private / { print \$2 }") ]; then
    log "vnf_private router exists"
  else
    neutron router-create vnf_private_router
    log "Create router gateway for vnf_private network"
    get_external_net
    neutron router-gateway-set vnf_private_router $EXTERNAL_NETWORK_NAME
    log "Add router interface for vnf_private network"
    neutron router-interface-add vnf_private_router subnet=vnf_private
  fi
}

copy_blueprint() {
  log "copy test script to /opt/tacker"
  cp $0 /opt/tacker/.

  log "reset blueprints folder"
  if [[ -d /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker ]]; then
    rm -rf /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker
  fi
  mkdir -p /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker

  log "copy tosca-vnfd-hello-world-tacker to blueprints folder"
  cp -r blueprints/tosca-vnfd-hello-world-tacker /opt/tacker/blueprints
}

start() {
#  Disable trap for now, need to test to ensure premature fail does not occur
#  trap 'fail' ERR

  log "setup OpenStack CLI environment"
  source /opt/tacker/admin-openrc.sh

  log "Create Nova key pair"
  if [[ -f /opt/tacker/vHello ]]; then rm /opt/tacker/vHello; fi
  ssh-keygen -t rsa -N "" -f /opt/tacker/vHello -C ubuntu@vHello
  chmod 600 /opt/tacker/vHello
  openstack keypair create --public-key /opt/tacker/vHello.pub vHello
  assert "models-nova-001 (Keypair creation)" true

  log "Inject public key into blueprint"
  pubkey=$(cat /opt/tacker/vHello.pub)
  sed -i -- "s~<pubkey>~$pubkey~" /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker/blueprint.yaml

  log "Get external network for Floating IP allocations"
  get_floating_net

  log "create VNFD"
  cd /opt/tacker/blueprints/tosca-vnfd-hello-world-tacker
  # newton: NAME (was "--name") is now a positional parameter
  tacker vnfd-create --vnfd-file blueprint.yaml hello-world-tacker
  if [[ $? -eq 0 ]]; then
    assert "models-tacker-002 (VNFD creation)" true
  else
    assert "models-tacker-002 (VNFD creation)" false
  fi

  log "create VNF"
  # newton: NAME (was "--name") is now a positional parameter
  tacker vnf-create --vnfd-name hello-world-tacker hello-world-tacker
  if [ $? -eq 1 ]; then fail; fi

  log "wait for hello-world-tacker to go ACTIVE"
  active=""
  count=24
  while [[ -z $active && $count -gt 0 ]]
  do
    active=$(tacker vnf-show hello-world-tacker | grep ACTIVE)
    if [[ $(tacker vnf-show hello-world-tacker | grep -c ERROR) -gt 0 ]]; then
      log "hello-world-tacker VNF creation failed with state ERROR"
      assert "models-tacker-002 (VNF creation)" false
    fi
    let count=$count-1
    sleep 30
    log "wait for hello-world-tacker to go ACTIVE"
  done
  if [[ $count == 0 ]]; then
    log "hello-world-tacker VNF creation failed - timed out"
    assert "models-tacker-002 (VNF creation)" false
  fi
  assert "models-tacker-002 (VNF creation)" true

  # Setup for workarounds
  log "directly set port security on ports (unsupported in Mitaka Tacker)"
  # Alternate method
  #  HEAT_ID=$(tacker vnf-show hello-world-tacker | awk "/instance_id/ { print \$4 }")
  #  SERVER_ID=$(openstack stack resource list $HEAT_ID | awk "/VDU1 / { print \$4 }")
  SERVER_ID=$(openstack server list | awk "/VDU1/ { print \$2 }")
  id=($(neutron port-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in "${id[@]}"; do
    if [[ $(neutron port-show $id|grep $SERVER_ID) ]]; then neutron port-update ${id} --port-security-enabled=True; fi
  done

  log "directly assign security group (unsupported in Mitaka Tacker)"
  if [[ $(neutron security-group-list | awk "/ vHello / { print \$2 }") ]]; then neutron security-group-delete vHello; fi
  neutron security-group-create vHello
  neutron security-group-rule-create --direction ingress --protocol TCP --port-range-min 22 --port-range-max 22 vHello
  neutron security-group-rule-create --direction ingress --protocol TCP --port-range-min 80 --port-range-max 80 vHello
  openstack server add security group $SERVER_ID vHello
  openstack server add security group $SERVER_ID default

  log "create floating IP"
  get_floating_net
  FIP=$(openstack floating ip create $FLOATING_NETWORK_NAME | awk "/floating_ip_address/ { print \$4 }")

  log "associate floating IP \"$FIP\" to server \"$SERVER_ID\""
  nova floating-ip-associate $SERVER_ID $FIP
  # End setup for workarounds

  log "get vHello server address"
  SERVER_IP=$(openstack server show $SERVER_ID | awk "/ addresses / { print \$6 }")
  SERVER_URL="http://$SERVER_IP"

  log "wait 30 seconds for vHello server to startup at $SERVER_URL"
  sleep 30

  log "verify vHello server is running"
  apt-get install -y curl
  count=12
  while [[ $(curl $SERVER_URL | grep -c "Hello World") == 0 ]]
  do
    sleep 10
    let count=$count-1
  done
  if [[ $(curl $SERVER_URL | grep -c "Hello World") == 0 ]]; then fail; fi
  assert "models-vhello-001 (vHello VNF creation)" true
  assert "models-tacker-003 (VNF creation)" true
  assert "models-tacker-vnfd-002 (artifacts creation)" true
  assert "models-tacker-vnfd-003 (user_data creation)" true

  log "verify contents of config drive are included in web page"
  id=$(curl $SERVER_URL | awk "/uuid/ { print \$2 }")
  if [[ ! -z $id ]]; then
    assert "models-tacker-vnfd-001 (config_drive creation)" true
  else
    assert "models-tacker-vnfd-001 (config_drive creation)" false
  fi
}

stop() {
  trap 'fail' ERR

  log "setup OpenStack CLI environment"
  source /opt/tacker/admin-openrc.sh

  if [[ "$(tacker vnf-list|grep hello-world-tacker|awk '{print $2}')" != '' ]]; then
    log "uninstall vHello blueprint via CLI"
    try 12 10 "tacker vnf-delete hello-world-tacker"
    # It can take some time to delete a VNF - thus wait 2 minutes
    count=12
    while [[ $count -gt 0 && "$(tacker vnf-list|grep hello-world-tacker|awk '{print $2}')" != '' ]]; do
      log "waiting for hello-world-tacker VNF delete to complete"
      sleep 10
      let count=$count-1
    done
    if [[ "$(tacker vnf-list|grep hello-world-tacker|awk '{print $2}')" == '' ]]; then
      assert "models-tacker-004 (VNF deletion)" true
    else
      assert "models-tacker-004 (VNF deletion)" false
    fi
  fi

  # It can take some time to delete a VNFD - thus wait 2 minutes
  if [[ "$(tacker vnfd-list|grep hello-world-tacker|awk '{print $2}')" != '' ]]; then
    log "trying to delete the hello-world-tacker VNFD"
    try 12 10 "tacker vnfd-delete hello-world-tacker"
    if [[ "$(tacker vnfd-list|grep hello-world-tacker|awk '{print $2}')" == '' ]]; then
      assert "models-tacker-005 (VNFD deletion)" true
    else
      assert "models-tacker-005 (VNFD deletion)" false
    fi
  fi

# This part will apply for tests that dynamically create the VDU base image
#  iid=($(openstack image list|grep VNFImage|awk '{print $2}')); for id in ${iid[@]}; do openstack image delete ${id};  done
#  if [[ "$(openstack image list|grep VNFImage|awk '{print $2}')" == '' ]]; then
#    assert "models-tacker-vnfd-004 (artifacts deletion)" true
#  else
#    assert "models-tacker-vnfd-004 (artifacts deletion)" false
#  fi

  # Cleanup for workarounds
  fip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in "${fip[@]}"; do neutron floatingip-delete ${id};  done
  sg=($(openstack security group list|grep vHello|awk '{print $2}'))
  for id in "${sg[@]}"; do try 5 5 "openstack security group delete ${id}";  done
  kid=($(openstack keypair list|grep vHello|awk '{print $2}')); for id in "${kid[@]}"; do openstack keypair delete ${id};  done
}

function clean() {
  trap 'ignore' ERR
  log "Uninstall Tacker"
  bash utils/tacker-setup.sh clean
  sudo docker stop tacker
  sudo docker rm -v tacker
  sudo rm -rf /opt/tacker

  log "Uninstall test environment"
  pid=($(neutron port-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in "${pid[@]}"; do neutron port-delete ${id};  done
  sid=($(openstack security group list|grep security_group_local_security_group|awk '{print $2}')); for id in "${sid[@]}"; do openstack security group delete ${id};  done
  neutron router-gateway-clear vnf_mgmt_router
  pid=($(neutron router-port-list vnf_mgmt_router|grep -v name|awk '{print $2}')); for id in "${pid[@]}"; do neutron router-interface-delete vnf_mgmt_router vnf_mgmt;  done
  neutron router-delete vnf_mgmt_router
  neutron net-delete vnf_mgmt
  neutron router-gateway-clear vnf_private_router
  pid=($(neutron router-port-list vnf_private_router|grep -v name|awk '{print $2}')); for id in "${pid[@]}"; do neutron router-interface-delete vnf_private_router vnf_private;  done
  neutron router-delete vnf_private_router
  neutron net-delete vnf_private
}

test_start=`date +%s`
dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

openrc=$2
branch=$3

case "$1" in
  setup)
    setup $2 $3
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  run)
    setup $2 $3
    copy_blueprint
    start
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  start)
    copy_blueprint
    start
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  stop)
    stop
    if [ $? -eq 1 ]; then fail; fi
    pass
    ;;
  clean)
    clean
    pass
    ;;
  *)
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then grep '#. ' $0; fi
esac
