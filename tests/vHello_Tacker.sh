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

trap 'fail' ERR

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
  echo "$0: setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  if [[ "$1" == "tacker-api" ]]; then
    echo "$0: Tacker API use is not yet implemented"
  else
    # Tacker CLI use
    echo "$0: Get external network for Floating IP allocations"

    echo "$0: create VNFD"
    cd /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker
    tacker vnfd-create --vnfd-file blueprint.yaml --name hello-world-tacker
    if [ $? -eq 1 ]; then fail; fi

    echo "$0: create VNF"
    tacker vnf-create --vnfd-name hello-world-tacker --name hello-world-tacker
    if [ $? -eq 1 ]; then fail; fi
  fi

  echo "$0: directly set port security on ports (bug/unsupported in Mitaka Tacker?)"
  active=""
  while [[ -z $active ]]
  do
    active=$(tacker vnf-show hello-world-tacker | grep ACTIVE)
    sleep 10
  done
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
  chown root /tmp/tacker/vHello.pem
  ssh -i /tmp/tacker/vHello.pem -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$SERVER_IP <<EOF
cat << EOM | sudo tee /home/ubuntu/index.html
<!DOCTYPE html>
<html>
<head>
<title>Hello World!</title>
<meta name="viewport" content="width=device-width, minimum-scale=1.0, initial-scale=1"/>
<style>
body { width: 100%; background-color: white; color: black; padding: 0px; margin: 0px; font-family: sans-serif; font-size:100%; }
</style>
</head>
<body>
Hello World!<br>
<a href="http://wiki.opnfv.org"><img src="https://www.opnfv.org/sites/all/themes/opnfv/logo.png"></a>
</body></html>
EOM
nohup sudo python3 -m http.server 80 > /dev/null 2>&1 &
exit
EOF

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
    tacker vnf-delete hello-world-tacker
    tacker vnfd-delete hello-world-tacker
    sg=($(openstack security group list|grep vHello|awk '{print $2}')); for id in ${sg[@]}; do openstack security group delete ${id};  done
    fip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${fip[@]}; do neutron floatingip-delete ${id};  done
  fi
  pass
}

if [[ "$2" == "setup" ]]; then
  echo "$0: Setup temp test folder /tmp/tacker and copy this script there"
  mkdir -p /tmp/tacker
  chmod 777 /tmp/tacker/
  cp $0 /tmp/tacker/.
  chmod 755 /tmp/tacker/*.sh

  echo "$0: tacker-setup part 1"
  bash utils/tacker-setup.sh $1 init

  echo "$0: tacker-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/tacker/ { print \$1 }")
  sudo docker exec $CONTAINER /tmp/tacker/tacker-setup.sh $1 setup

  echo "$0: reset blueprints folder"
  if [[ -d /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker ]]; then rm -rf /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker; fi
  mkdir -p /tmp/tacker/blueprints/tosca-vnfd-hello-world-tacker

  echo "$0: copy tosca-vnfd-hello-world-tacker to blueprints folder"
  cp -r blueprints/tosca-vnfd-hello-world-tacker /tmp/tacker/blueprints

# Following two steps are in testing still. The guestfish step needs work.

#  echo "$0: Create Nova key pair"
#  mkdir -p ~/.ssh
#  nova keypair-delete vHello
#  nova keypair-add vHello > /tmp/tacker/vHello.pem
#  chmod 600 /tmp/tacker/vHello.pem
#  pubkey=$(nova keypair-show vHello | grep "Public key:" | sed -- 's/Public key: //g')
#  nova keypair-show vHello | grep "Public key:" | sed -- 's/Public key: //g' >/tmp/tacker/vHello.pub

  echo "$0: Inject key into xenial server image"
#  wget http://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img
#  sudo yum install -y libguestfs-tools
#  guestfish <<EOF
#add xenial-server-cloudimg-amd64-disk1.img
#run
#mount /dev/sda1 /
#mkdir /home/ubuntu
#mkdir /home/ubuntu/.ssh
#cat <<EOM >/home/ubuntu/.ssh/authorized_keys
#$pubkey
#EOM
#exit
#chown -R ubuntu /home/ubuntu
#EOF

  # Using pre-key-injected image for now, vHello.pem as provided in the blueprint
  wget http://bkaj.net/opnfv/xenial-server-cloudimg-amd64-disk1.img
  cp blueprints/tosca-vnfd-hello-world-tacker/vHello.pem /tmp/tacker

  echo "$0: Setup image_id"
  image_id=$(openstack image list | awk "/ models-xenial-server / { print \$2 }" | tr -dc \n)
  if [[ -z "$image_id" ]]; then glance --os-image-api-version 1 image-create --name models-xenial-server --disk-format qcow2 --file xenial-server-cloudimg-amd64-disk1.img --container-format bare; fi 

  pass
else
  if [[ $# -eq 3 ]]; then
    # running inside the tacker container, ready to go
    if [[ "$3" == "start" ]]; then start $1; fi
    if [[ "$3" == "clean" ]]; then clean $1; fi
  else
    echo "$0: pass $2 command to vHello.sh in tacker container"
    CONTAINER=$(sudo docker ps -a | awk "/tacker/ { print \$1 }")
    sudo docker exec $CONTAINER /tmp/tacker/vHello_Tacker.sh $1 $2 $2
    if [ $? -eq 1 ]; then fail; fi
    pass
  fi
fi

