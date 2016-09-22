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

# What this is: Cleanup script for a basic test to validate an OPNFV install. 
#
# Status: this is a work in progress, under test. 
#
# How to use:
#   $ source ~/git/copper/tests/adhoc/OpenWRT-clean.sh [OpenWRT]
#   OpenWRT: clean OpenWRT resources only (leave public and internal networks)

wget https://git.opnfv.org/cgit/copper/plain/components/congress/install/bash/setenv.sh -O ~/setenv.sh
source ~/setenv.sh

echo "$0: Delete OpenWRT instance"
instance=$(nova list | awk "/ OpenWRT / { print \$2 }")
if [ "$instance" != "" ]; then nova delete $instance; fi

echo "$0: Wait for OpenWRT to terminate"
COUNTER=5
RESULT="Wait!"
until [[ $COUNTER -eq 0  || $RESULT == "Go!" ]]; do
  OpenWRT_id=$(openstack server list | awk "/ cirros1 / { print \$4 }")
  if [[ -z "$OpenWRT_id" ]]; then RESULT="Go!"; fi
  let COUNTER-=1
  sleep 5
done

echo "$0: Delete 'OpenWRT' security group"
sg=$(neutron security-group-list | awk "/ OpenWRT / { print \$2 }")
neutron security-group-delete $sg

echo "$0: Delete floating ip"
# FLOATING_IP_ID was saved by OpenWRT.sh
source /tmp/OpenWRT_VARS.sh
rm /tmp/OpenWRT_VARS.sh
neutron floatingip-delete $FLOATING_IP_ID

echo "$0: Delete OpenWRT key pair"
nova keypair-delete OpenWRT
rm /tmp/OpenWRT

echo "$0: Delete neutron port with fixed_ip 192.168.1.1"
port=$(neutron port-list | awk "/192.168.1.1/ { print \$2 }")
if [ "$port" != "" ]; then neutron port-delete $port; fi

echo "$0: Delete OpenWRT subnet"
neutron subnet-delete OpenWRT

echo "$0: Delete OpenWRT network"
neutron net-delete OpenWRT

if [[ "$1" == "OpenWRT" ]]; then exit 0; fi

echo "$0: Get 'public_router' ID"
router=$(neutron router-list | awk "/ public_router / { print \$2 }")

echo "$0: Get internal port ID with subnet 10.0.0.1 on 'public_router'"
internal_interface=$(neutron router-port-list $router | grep 10.0.0.1 | awk '{print $2}')

echo "$0: If found, delete the port with subnet 10.0.0.1 on 'public_router'"
if [ "$internal_interface" != "" ]; then neutron router-interface-delete $router port=$internal_interface; fi

echo "$0: Delete remaining neutron ports on subnet 10.0.0.0"
pid=($(neutron port-list | grep 10.0.0 | awk "/10.0.0/ { print \$2 }")); for id in ${pid[@]}; do neutron port-delete ${id};  done

echo "$0: Clear the router gateway"
neutron router-gateway-clear public_router

echo "$0: Delete the router"
neutron router-delete public_router

echo "$0: Delete internal subnet"
neutron subnet-delete internal

echo "$0: Delete internal network"
neutron net-delete internal



