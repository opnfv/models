#!/bin/bash
# Copyright 2015-2016 AT&T Intellectual Property, Inc
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
# What this is: A basic test to validate an OPNFV install. Creates an image,
# using the OpenWRT project and a private network over which OpenWRT will 
# allocate addresses etc.
#
# Status: this is a work in progress, under test. Automated ping test to the 
# internet and between VMs has not yet been implemented.
#
# Prequisites:
#   python-openstackclient >=3.2.0
#
# How to use:
#   $ bash ~/git/copper/tests/adhoc/OpenWRT.sh
#   After test, cleanup with
#   $ bash ~/git/copper/tests/adhoc/OpenWRT-clean.sh

trap 'fail' ERR

pass() {
  echo "$0: Hooray!"
  set +x #echo off
  exit 0
}

# Use this to trigger fail() at the right places
# if [ "$RESULT" == "Test Failed!" ]; then fail; fi
fail() {
  echo "$0: Test Failed!"
  set +x
  exit 1
}

# Find external network if any, and details
function get_external_net () {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${network_ids[@]}; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && ext_net_id=${id}
  done
  if [[ $ext_net_id ]]; then 
    EXTERNAL_NETWORK_NAME=$(openstack network show $ext_net_id | awk "/ name / { print \$4 }")
    EXTERNAL_SUBNET_ID=$(openstack network show $EXTERNAL_NETWORK_NAME | awk "/ subnets / { print \$4 }")
  else
    echo "$0: External network not found"
    echo "$0: Create external network"
    neutron net-create public --router:external
    EXTERNAL_NETWORK_NAME="public"
    echo "$0: Create external subnet"
    neutron subnet-create public 192.168.10.0/24 --name public --enable_dhcp=False --allocation_pool start=192.168.10.6,end=192.168.10.49 --gateway 192.168.10.1
    EXTERNAL_SUBNET_ID=$(openstack subnet show public | awk "/ id / { print \$4 }")
  fi
}

wget https://git.opnfv.org/cgit/copper/plain/components/congress/install/bash/setenv.sh -O ~/setenv.sh
source ~/setenv.sh

echo "$0: create OpenWRT image"
image=$(openstack image list | awk "/ OpenWRT / { print \$2 }")
if [ -z $image ]; then glance --os-image-api-version 1 image-create --name OpenWRT --disk-format qcow2 --location http://download.cirros-cloud.net/0.3.3/cirros-0.3.3-x86_64-disk.img --container-format bare
fi

get_external_net

echo "$0: Create floating IP for external subnet"
FLOATING_IP_ID=$(neutron floatingip-create $EXTERNAL_NETWORK_NAME | awk "/ id / { print \$4 }")
FLOATING_IP=$(neutron floatingip-show $FLOATING_IP_ID | awk "/ floating_ip_address / { print \$4 }" | cut -d - -f 1)
# Save ID to pass to cleanup script
echo "FLOATING_IP_ID=$FLOATING_IP_ID" >/tmp/OpenWRT_VARS.sh

INTERNAL_NET_ID=$(neutron net-list | awk "/ internal / { print \$2 }") 
if [[ -z $INTERNAL_NET_ID ]]; then 
  echo "$0: Create internal network"
  neutron net-create internal

  echo "$0: Create internal subnet"
  neutron subnet-create internal 10.0.0.0/24 --name internal --gateway 10.0.0.1 --enable-dhcp --allocation-pool start=10.0.0.2,end=10.0.0.254 --dns-nameserver 8.8.8.8
fi

if [[ -z $(neutron router-list | awk "/ public_router / { print \$2 }") ]]; then 
  echo "$0: Create public_router"
  neutron router-create public_router

  echo "$0: Create public_router gateway"
  neutron router-gateway-set public_router $EXTERNAL_NETWORK_NAME

  echo "$0: Add router interface for internal network"
  neutron router-interface-add public_router subnet=internal
fi

echo "$0: Create OpenWRT network"
neutron net-create OpenWRT
wrt_net_id=$(neutron net-list | awk "/ OpenWRT / { print \$2 }") 

echo "$0: Create OpenWRT subnet"
neutron subnet-create OpenWRT 192.168.1.0/24 --disable-dhcp --name OpenWRT --gateway 192.168.1.1

echo "$0: Create OpenWRT security group"
neutron security-group-create OpenWRT

echo "$0: Add rules to OpenWRT security group"
neutron security-group-rule-create --direction ingress --protocol=TCP --remote-ip-prefix 0.0.0.0/0 --port-range-min=22 --port-range-max=22 OpenWRT
neutron security-group-rule-create --direction ingress --protocol=TCP --remote-ip-prefix 0.0.0.0/0 --port-range-min=80 --port-range-max=80 OpenWRT
neutron security-group-rule-create --direction ingress --protocol=ICMP --remote-ip-prefix 0.0.0.0/0 OpenWRT
neutron security-group-rule-create --direction egress --protocol=TCP --remote-ip-prefix 0.0.0.0/0 --port-range-min=22 --port-range-max=22 OpenWRT
neutron security-group-rule-create --direction egress --protocol=ICMP --remote-ip-prefix 0.0.0.0/0 OpenWRT

echo "$0: Create Nova key pair"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R 192.168.1.1
nova keypair-add OpenWRT > /tmp/OpenWRT
chmod 600 /tmp/OpenWRT

echo "$0: Create OpenWRT port for LAN"
LAN_PORT_ID=$(neutron port-create OpenWRT --fixed-ip ip_address=192.168.1.1 | awk "/ id / { print \$4 }")

echo "$0: Create OpenWRT port for WAN"
WAN_PORT_ID=$(neutron port-create internal | awk "/ id / { print \$4 }")
# The following does not work with a single-NIC compute node
# EXT_PORT_ID=$(neutron port-create $EXTERNAL_NETWORK_NAME | awk "/ id / { print \$4 }")

echo "$0: Boot OpenWRT with internal net port"
openstack server create --flavor m1.tiny --image OpenWRT --nic port-id=$WAN_PORT_ID --security-group OpenWRT --security-group default --key-name OpenWRT OpenWRT

echo "$0: Add OpenWRT security group (should have been done thru the server create command but...)"
openstack server add security group OpenWRT OpenWRT

# failed with: either net-id or port-id should be specified but not both
# openstack server create --flavor m1.tiny --image OpenWRT --nic net-id=$wrt_net_id,v4-fixed-ip=192.168.1.1 --nic net-id=$INTERNAL_NET_ID --security-group OpenWRT --key-name OpenWRT OpenWRT
# openstack server create --flavor m1.tiny --image OpenWRT --nic v4-fixed-ip=192.168.1.1 --nic net-id=$INTERNAL_NET_ID --security-group OpenWRT --key-name OpenWRT OpenWRT

echo "$0: Wait for OpenWRT to go ACTIVE"
COUNTER=12
RESULT="Test Failed!"
until [[ $COUNTER -eq 0  || $RESULT == "Test Success!" ]]; do
  status=$(openstack server show OpenWRT | awk "/ status / { print \$4 }")
  if [[ "$status" == "ACTIVE" ]]; then RESULT="Test Success!"; fi
  let COUNTER-=1
  sleep 5
done
if [ "$RESULT" == "Test Failed!" ]; then fail; fi

echo "$0: Associate floating IP to OpenWRT external port"
neutron floatingip-associate $FLOATING_IP_ID $WAN_PORT_ID

echo "$0: Attach eth1 to OpenWRT internal port"
nova interface-attach --port-id $LAN_PORT_ID OpenWRT

echo "$0: Boot cirros1 with internal net port"
openstack server create --flavor m1.tiny --image cirros-0.3.3-x86_64 --nic net-id=$INTERNAL_NET_ID --security-group OpenWRT --security-group default --key-name OpenWRT cirros1

echo "$0: Wait for cirros1 to go ACTIVE"
COUNTER=12
RESULT="Test Failed!"
until [[ $COUNTER -eq 0  || $RESULT == "Test Success!" ]]; do
  status=$(openstack server show cirros1 | awk "/ status / { print \$4 }")
  if [[ "$status" == "ACTIVE" ]]; then RESULT="Test Success!"; fi
  let COUNTER-=1
  sleep 5
done
if [ "$RESULT" == "Test Failed!" ]; then fail; fi

echo "$0: Create floating IP for external subnet"
FLOATING_IP_ID=$(neutron floatingip-create $EXTERNAL_NETWORK_NAME | awk "/ id / { print \$4 }")
FLOATING_IP=$(neutron floatingip-show $FLOATING_IP_ID | awk "/ floating_ip_address / { print \$4 }" | cut -d - -f 1)

echo "$0: Associate floating IP to cirros1 internal port"
nova floating-ip-associate cirros1 $FLOATING_IP

echo "$0: Create cirros1 port for OpenWRT net"
INT_PORT_ID=$(neutron port-create OpenWRT --fixed-ip ip_address=192.168.1.2 | awk "/ id / { print \$4 }")

echo "$0: Attach eth1 to cirros1 internal port"
nova interface-attach --port-id $INT_PORT_ID cirros1



pass
