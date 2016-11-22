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
#   $ bash vHello_Tacker.sh [tacker-cli|tacker-api] [setup|start|run|stop|clean]
#   tacker-cli: use Tacker CLI
#   tacker-api: use Tacker RESTful API (not yet implemented)
#   setup: setup test environment
#   start: install blueprint and run test
#   run: setup test environment and run test
#   stop: stop test and uninstall blueprint
#   clean: cleanup after test

set -x

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
  echo "$0: Setup temp test folder /tmp/tacker and copy this script there"
  if [ -d /tmp/tacker ]; then sudo rm -rf /tmp/tacker; fi 
  mkdir -p /tmp/tacker
  chmod 777 /tmp/tacker/
  cp $0 /tmp/tacker/.
  chmod 755 /tmp/tacker/*.sh

  echo "$0: tacker-setup part 1"
  bash utils/tacker-setup.sh $1 init

  echo "$0: tacker-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/tacker/ { print \$1 }")
  dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: JOID workaround for Colorado - enable ML2 port security"
    juju set neutron-api enable-ml2-port-security=true

    echo "$0: Execute tacker-setup.sh in the container"
    sudo docker exec -it $CONTAINER /bin/bash /tmp/tacker/tacker-setup.sh $1 setup
  else
    echo "$0: Execute tacker-setup.sh in the container"
    sudo docker exec -i -t $CONTAINER /bin/bash /tmp/tacker/tacker-setup.sh $1 setup
  fi

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
  if [ ! -f /tmp/xenial-server-cloudimg-amd64-disk1.img ]; then 
    wget -O /tmp/xenial-server-cloudimg-amd64-disk1.img  http://artifacts.opnfv.org/models/images/xenial-server-cloudimg-amd64-disk1.img
  fi
  cp blueprints/tosca-vnfd-hello-world-tacker/vHello.pem /tmp/tacker
  chmod 600 /tmp/tacker/vHello.pem

  echo "$0: setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: Setup image_id"
  image_id=$(openstack image list | awk "/ models-xenial-server / { print \$2 }")
  if [[ -z "$image_id" ]]; then glance --os-image-api-version 1 image-create --name models-xenial-server --disk-format qcow2 --file /tmp/xenial-server-cloudimg-amd64-disk1.img --container-format bare; fi 
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

  echo "$0: wait for hello-world-tacker to go ACTIVE"
  active=""
  while [[ -z $active ]]
  do
    active=$(tacker vnf-show hello-world-tacker | grep ACTIVE)
    if [ "$(tacker vnf-show hello-world-tacker | grep -c ERROR)" == "1" ]; then 
      echo "$0: hello-world-tacker VNF creation failed with state ERROR"
      fail
    fi
    sleep 10
  done

  echo "$0: directly set port security on ports (bug/unsupported in Mitaka Tacker?)"
  HEAT_ID=$(tacker vnf-show hello-world-tacker | awk "/instance_id/ { print \$4 }")
  SERVER_ID=$(openstack stack resource list $HEAT_ID | awk "/VDU1 / { print \$4 }")
  id=($(neutron port-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${id[@]}; do
    if [[ $(neutron port-show $id|grep $SERVER_ID) ]]; then neutron port-update ${id} --port-security-enabled=True; fi
  done

  echo "$0: directly assign security group (unsupported in Mitaka Tacker)"
  if [[ $(openstack security group list | awk "/ vHello / { print \$2 }") ]]; then openstack security group vHello; fi
  openstack security group create vHello
  openstack security group rule create --ingress --protocol TCP --dst-port 22:22 vHello
  openstack security group rule create --ingress --protocol TCP --dst-port 80:80 vHello
  openstack server add security group $SERVER_ID vHello
  openstack server add security group $SERVER_ID default

  echo "$0: associate floating IP"
  get_floating_net
  FIP=$(openstack floating ip create $FLOATING_NETWORK_NAME | awk "/floating_ip_address/ { print \$4 }")
  nova floating-ip-associate $SERVER_ID $FIP

  echo "$0: get vHello server address"
  SERVER_IP=$(openstack server show $SERVER_ID | awk "/ addresses / { print \$6 }")
  SERVER_URL="http://$SERVER_IP"

  echo "$0: wait 30 seconds for vHello server to startup"
  sleep 30

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

  echo "$0: wait 10 seconds for vHello web server to startup"
  sleep 10

  echo "$0: verify vHello server is running"
  apt-get install -y curl
  if [[ $(curl $SERVER_URL | grep -c "Hello World") == 0 ]]; then fail; fi
}

stop() {
  echo "$0: setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  if [[ "$1" == "tacker-api" ]]; then
    echo "$0: Tacker API use is not yet implemented"
  else
    echo "$0: uninstall vHello blueprint via CLI"
    vid=($(tacker vnf-list|grep hello-world-tacker|awk '{print $2}')); for id in ${vid[@]}; do tacker vnf-delete ${id};  done
    vid=($(tacker vnfd-list|grep hello-world-tacker|awk '{print $2}')); for id in ${vid[@]}; do tacker vnfd-delete ${id};  done
    fip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${fip[@]}; do neutron floatingip-delete ${id};  done
    sg=($(openstack security group list|grep vHello|awk '{print $2}'))
    for id in ${sg[@]}; do try 5 5 "openstack security group delete ${id}";  done
  fi
}

forward_to_container () {
  echo "$0: pass $2 command to vHello.sh in tacker container"
  CONTAINER=$(sudo docker ps -a | awk "/tacker/ { print \$1 }")
  sudo docker exec $CONTAINER /bin/bash /tmp/tacker/vHello_Tacker.sh $1 $2 $2
  if [ $? -eq 1 ]; then fail; fi
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$2" in
  setup)
    setup $1
    pass
    ;;
  run)
    setup $1
    forward_to_container $1 start
    pass
    ;;
  start|stop)
    if [[ $# -eq 2 ]]; then forward_to_container $1 $2
    else
      # running inside the tacker container, ready to go
      $2 $1
    fi
    pass
    ;;
  clean)
    echo "$0: Uninstall Tacker and test environment"
    bash utils/tacker-setup.sh $1 clean
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
