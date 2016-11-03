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
# What this is: 3-Node Hello World blueprint deployment test for the OPNFV Models
# project, using Tacker as VNFM.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ git clone https://gerrit.opnfv.org/gerrit/ves
#   $ cd ves/tests
#   $ bash vHello_3Node_Tacker.sh [setup|start|run|stop|clean]
#        [monitor|traffic|pause|nic]
#   setup: setup test environment
#   start: install blueprint and run test
#   run: setup test environment and run test
#   stop: stop test and uninstall blueprint
#   clean: cleanup after test

trap 'fail' ERR

pass() {
  echo "$0: $(date) Hooray!"
  exit 0
}

fail() {
  echo "$0: $(date) Test Failed!"
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
  echo "$0: $(date) Started"
  echo "$0: $(date) Setup temp test folder /tmp/tacker and copy this script there"
  mkdir -p /tmp/tacker
  chmod 777 /tmp/tacker/
  cp $0 /tmp/tacker/.
  chmod 755 /tmp/tacker/*.sh

  echo "$0: $(date) tacker-setup part 1"
  wget https://git.opnfv.org/cgit/models/plain/tests/utils/tacker-setup.sh -O /tmp/tacker/tacker-setup.sh
  bash /tmp/tacker/tacker-setup.sh tacker-cli init

  echo "$0: $(date) tacker-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/tacker/ { print \$1 }")
  dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: $(date) JOID workaround for Colorado - enable ML2 port security"
    juju set neutron-api enable-ml2-port-security=true

    echo "$0: $(date) Execute tacker-setup.sh in the container"
    sudo docker exec -it $CONTAINER /bin/bash /tmp/tacker/tacker-setup.sh tacker-cli setup
  else
    echo "$0: $(date) Copy private key to the container (needed for later install steps)"
    cp ~/.ssh/id_rsa /tmp/tacker/id_rsa
    echo "$0: $(date) Execute tacker-setup.sh in the container"
    sudo docker exec -i -t $CONTAINER /bin/bash /tmp/tacker/tacker-setup.sh tacker-cli setup
  fi

  echo "$0: $(date) reset blueprints folder"
  if [[ -d /tmp/tacker/blueprints/tosca-vnfd-3node-tacker ]]; then rm -rf /tmp/tacker/blueprints/tosca-vnfd-3node-tacker; fi
  mkdir -p /tmp/tacker/blueprints/tosca-vnfd-3node-tacker

  echo "$0: $(date) copy tosca-vnfd-3node-tacker to blueprints folder"
  cp -r blueprints/tosca-vnfd-3node-tacker /tmp/tacker/blueprints

  # Following two steps are in testing still. The guestfish step needs work.

  #  echo "$0: $(date) Create Nova key pair"
  #  mkdir -p ~/.ssh
  #  nova keypair-delete vHello
  #  nova keypair-add vHello > /tmp/tacker/vHello.pem
  #  chmod 600 /tmp/tacker/vHello.pem
  #  pubkey=$(nova keypair-show vHello | grep "Public key:" | sed -- 's/Public key: //g')
  #  nova keypair-show vHello | grep "Public key:" | sed -- 's/Public key: //g' >/tmp/tacker/vHello.pub

  echo "$0: $(date) Inject key into xenial server image"
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
  cp blueprints/tosca-vnfd-3node-tacker/vHello.pem /tmp/tacker
  chmod 600 /tmp/tacker/vHello.pem

  echo "$0: $(date) setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: $(date) Setup image_id"
  image_id=$(openstack image list | awk "/ models-xenial-server / { print \$2 }")
  if [[ -z "$image_id" ]]; then glance --os-image-api-version 1 image-create --name models-xenial-server --disk-format qcow2 --file /tmp/xenial-server-cloudimg-amd64-disk1.img --container-format bare; fi

  echo "$0: $(date) Completed"
}

say_hello() {
  pass=false
  count=6
  while [[ $count -gt 0 && ! $pass ]] 
  do 
    sleep 10
    let count=$count-1
    if [[ $(curl $1} | grep -c "Hello World") > 0 ]]; then
      echo "$0: $(date) Hello World found at $1"
      pass=true
    fi
  done
  if [[ ! $pass ]]; then fail; fi
}

start() {
  echo "$0: $(date) Started"
  echo "$0: $(date) setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: $(date) create VNFD"
  cd /tmp/tacker/blueprints/tosca-vnfd-3node-tacker
  tacker vnfd-create --vnfd-file blueprint.yaml --name hello-3node
  if [ $? -eq 1 ]; then fail; fi

  echo "$0: $(date) create VNF"
  tacker vnf-create --vnfd-name hello-3node --name hello-3node
  if [ $? -eq 1 ]; then fail; fi

  echo "$0: $(date) wait for hello-3node to go ACTIVE"
  active=""
  while [[ -z $active ]]
  do
    active=$(tacker vnf-show hello-3node | grep ACTIVE)
    if [ "$(tacker vnf-show hello-3node | grep -c ERROR)" == "1" ]; then 
      echo "$0: $(date) hello-3node VNF creation failed with state ERROR"
      fail
    fi
    sleep 10
  done

  echo "$0: $(date) directly set port security on ports (bug/unsupported in Mitaka Tacker?)"
  vdus="VDU1 VDU2 VDU3"
  vdui="1 2 3"
  declare -a vdu_id=()
  declare -a vdu_ip=()
  declare -a vdu_url=()
  HEAT_ID=$(tacker vnf-show hello-3node | awk "/instance_id/ { print \$4 }")
  vdu_id[1]=$(openstack stack resource list $HEAT_ID | awk "/VDU1 / { print \$4 }")
  vdu_id[2]=$(openstack stack resource list $HEAT_ID | awk "/VDU2 / { print \$4 }")
  vdu_id[3]=$(openstack stack resource list $HEAT_ID | awk "/VDU3 / { print \$4 }")

cat >/tmp/grep <<EOF
${vdu_id[1]}
${vdu_id[2]}
${vdu_id[3]}
EOF
  id=($(neutron port-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${id[@]}; do
    if [[ $(neutron port-show $id | grep -f /tmp/grep) ]]; then 
      neutron port-update ${id} --port-security-enabled=True
    fi
  done

  echo "$0: $(date) directly assign security group (unsupported in Mitaka Tacker)"
  if [[ $(openstack security group list | awk "/ vHello / { print \$2 }") ]]; then openstack security group delete vHello; fi
  openstack security group create vHello
  openstack security group rule create --ingress --protocol TCP --dst-port 22:22 vHello
  openstack security group rule create --ingress --protocol TCP --dst-port 80:80 vHello
  for i in $vdui; do
    openstack server add security group ${vdu_id[$i]} vHello
    openstack server add security group ${vdu_id[$i]} default
  done

  echo "$0: $(date) associate floating IPs"
  get_floating_net
  for i in $vdui; do
    vdu_ip[$i]=$(openstack floating ip create $FLOATING_NETWORK_NAME | awk "/floating_ip_address/ { print \$4 }")
    nova floating-ip-associate ${vdu_id[$i]} ${vdu_ip[$i]}
  done

  echo "$0: $(date) get web server addresses"
  vdu_url[1]="http://${vdu_ip[1]}"
  vdu_url[2]="http://${vdu_ip[2]}"
  vdu_url[3]="http://${vdu_ip[3]}"

  if [[ -f /tmp/tacker/id_rsa ]]; then
    echo "$0: $(date) setup private key for ssh to hypervisors"
    cp -p /tmp/tacker/id_rsa ~/.ssh/id_rsa
    chown root ~/.ssh/id_rsa
    chmod 600 ~/.ssh/id_rsa
  fi

  echo "$0: $(date) wait 30 seconds for server SSH to be available"
  sleep 30

  echo "$0: $(date) Copy startup script to the VMs"
  for i in $vdui; do
    ssh -i /tmp/tacker/vHello.pem -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@${vdu_ip[$i]} "sudo chown ubuntu /home/ubuntu"
    scp -i /tmp/tacker/vHello.pem -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/tacker/blueprints/tosca-vnfd-3node-tacker/start.sh ubuntu@${vdu_ip[$i]}:/home/ubuntu/start.sh
  done

  echo "$0: $(date) start vHello webserver in VDU1 at ${vdu_ip[1]}"
  ssh -i /tmp/tacker/vHello.pem -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@${vdu_ip[1]} "nohup bash /home/ubuntu/start.sh webserver > /dev/null 2>&1 &"

  echo "$0: $(date) start vHello webserver in VDU2 at ${vdu_ip[2]}"
  ssh -i /tmp/tacker/vHello.pem -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@${vdu_ip[2]} "nohup bash /home/ubuntu/start.sh webserver > /dev/null 2>&1 &"

  echo "$0: $(date) start LB in VDU3 at ${vdu_ip[3]}"
  ssh -i /tmp/tacker/vHello.pem -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@${vdu_ip[3]} "nohup bash /home/ubuntu/start.sh lb ${vdu_ip[1]} ${vdu_ip[2]} > /dev/null 2>&1 &"

  echo "$0: $(date) verify vHello server is running at each web server and via the LB"
  apt-get install -y curl
  say_hello http://${vdu_ip[1]}
  say_hello http://${vdu_ip[2]}
  say_hello http://${vdu_ip[3]}
}

stop() {
  echo "$0: $(date) setup OpenStack CLI environment"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: $(date) uninstall vHello blueprint via CLI"
  vdus="VDU1 VDU2 VDU3"
  for vdu in $vdus; do
    get_vdu_info $vdu
    echo "$0: $(date) disassociate floating ip for $vdu"
    nova floating-ip-disassociate $id $ip
  done
  vid=($(tacker vnf-list|grep hello-3node|awk '{print $2}')); for id in ${vid[@]}; do tacker vnf-delete ${id};  done
  vid=($(tacker vnfd-list|grep hello-3node|awk '{print $2}')); for id in ${vid[@]}; do tacker vnfd-delete ${id};  done
  sg=($(openstack security group list|grep vHello|awk '{print $2}'))
  for id in ${sg[@]}; do try 10 5 "openstack security group delete ${id}";  done
}

#
# Test tools and scenarios
#

get_vdu_info () {
  source /tmp/tacker/admin-openrc.sh

  echo "$0: $(date) find VM IP for $1"
  id=$(openstack server list | awk "/$1/ { print \$2 }")
  ip=$(openstack server list | awk "/$1/ { print \$10 }")
}

forward_to_container () {
  echo "$0: $(date) pass $1 command to this script in the tacker container"
  CONTAINER=$(sudo docker ps -a | awk "/tacker/ { print \$1 }")
  sudo docker exec $CONTAINER /bin/bash /tmp/tacker/vHello_3Node_Tacker.sh $1 $1
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
    echo "$0: $(date) Uninstall Tacker and test environment"
    bash /tmp/tacker/tacker-setup.sh $1 clean
    pass
    ;;
  *)
    echo "usage: bash vHello_3Node_Tacker.sh [setup|start|run|clean]"
    echo "setup: setup test environment"
    echo "start: install blueprint and run test"
    echo "run: setup test environment and run test"
    echo "stop: stop test and uninstall blueprint"
    echo "clean: cleanup after test"
    fail
esac
