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
# What this is: Cleanup script for the Cloudify Manager running in an
# Unbuntu Xenial docker container.
#
# Status: this is a work in progress, under test.#
#
# Prerequisites:
#   $ bash /tmp/cloudify/cloudify-setup.sh
#
# How to use:
#   $ bash cloudify-clean.sh
#
# Extra commands useful in debugging:
# Delete all security groups created by Cloudify
# sg=($(openstack security group list|awk "/ security_group_local_security_group_/ { print \$2 }")); for id in ${sg[@]}; do openstack security group delete ${id}; done
# Delete all floating IPs
# flip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${flip[@]}; do neutron floatingip-delete ${id}; done

function setenv () {
mkdir /tmp/cloudify
if [ "$dist" == "Ubuntu" ]; then
  echo "cloudify-clean.sh: Ubuntu-based install"
  echo "cloudify-clean.sh: Create the environment file"
  KEYSTONE_HOST=$(juju status --format=short | awk "/keystone\/0/ { print \$3 }")
  cat <<EOF >/tmp/cloudify/admin-openrc
export CONGRESS_HOST=$(juju status --format=short | awk "/openstack-dashboard/ { print \$3 }")
export HORIZON_HOST=$(juju status --format=short | awk "/openstack-dashboard/ { print \$3 }")
export KEYSTONE_HOST=$KEYSTONE_HOST
export CEILOMETER_HOST=$(juju status --format=short | awk "/ceilometer\/0/ { print \$3 }")
export CINDER_HOST=$(juju status --format=short | awk "/cinder\/0/ { print \$3 }")
export GLANCE_HOST=$(juju status --format=short | awk "/glance\/0/ { print \$3 }")
export NEUTRON_HOST=$(juju status --format=short | awk "/neutron-api\/0/ { print \$3 }")
export NOVA_HOST=$(juju status --format=short | awk "/nova-cloud-controller\/0/ { print \$3 }")
export OS_USERNAME=admin
export OS_PASSWORD=openstack
export OS_TENANT_NAME=admin
export OS_AUTH_URL=http://$KEYSTONE_HOST:5000/v2.0
export OS_REGION_NAME=RegionOne
EOF
else
  # Centos
  echo "cloudify-clean.sh: Centos-based install"
  echo "cloudify-clean.sh: Setup undercloud environment so we can get overcloud Controller server address"
  source ~/stackrc
  echo "cloudify-clean.sh: Get address of Controller node"
  export CONTROLLER_HOST1=$(openstack server list | awk "/overcloud-controller-0/ { print \$8 }" | sed 's/ctlplane=//g')
  echo "cloudify-clean.sh: Create the environment file"
  cat <<EOF >/tmp/cloudify/admin-openrc
export CONGRESS_HOST=$CONTROLLER_HOST1
export KEYSTONE_HOST=$CONTROLLER_HOST1
export CEILOMETER_HOST=$CONTROLLER_HOST1
export CINDER_HOST=$CONTROLLER_HOST1
export GLANCE_HOST=$CONTROLLER_HOST1
export NEUTRON_HOST=$CONTROLLER_HOST1
export NOVA_HOST=$CONTROLLER_HOST1
EOF
  cat ~/overcloudrc >>/tmp/cloudify/admin-openrc
  source ~/overcloudrc
  export OS_REGION_NAME=$(openstack endpoint list | awk "/ nova / { print \$4 }")
  # sed command below is a workaound for a bug - region shows up twice for some reason
  cat <<EOF | sed '$d' >>/tmp/cloudify/admin-openrc
export OS_REGION_NAME=$OS_REGION_NAME
EOF
fi
source /tmp/cloudify/admin-openrc
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
setenv

echo "cloudify-clean.sh: delete Manager server"
openstack server delete cloudify-manager-server

echo "cloudify-clean.sh: delete floating IPs"
flip=($(neutron floatingip-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${flip[@]}; do neutron floatingip-delete ${id}; done

echo "cloudify-clean.sh: clear cloudify-management-router gateway"
neutron router-gateway-clear cloudify-management-router

echo "cloudify-clean.sh: delete cloudify-manager-port"
neutron port-delete cloudify-manager-port

echo "cloudify-clean.sh: delete other ports"
port=($(neutron port-list|grep -v "+"|grep -v name|awk '{print $2}')); for id in ${port[@]}; do neutron port-delete ${id}; done

echo "cloudify-clean.sh: delete cloudify security groups"
openstack security group delete cloudify-sg-manager 
openstack security group delete cloudify-sg-agents 

echo "cloudify-clean.sh: delete cloudify-management-router on cloudify-management-network-subnet"
neutron router-interface-delete cloudify-management-router cloudify-management-network-subnet

echo "cloudify-clean.sh: delete cloudify-management-router"
neutron router-delete cloudify-management-router 

echo "cloudify-clean.sh: delete cloudify-management-network-subnet"
neutron subnet-delete cloudify-management-network-subnet

echo "cloudify-clean.sh: delete cloudify-management-network"
neutron net-delete cloudify-management-network

echo "cloudify-clean.sh: delete cloudify-manager keypair"
openstack keypair delete cloudify-manager 

echo "cloudify-clean.sh: delete cloudify-agent keypair"
openstack keypair delete cloudify-agent

echo "cloudify-clean.sh: delete cloudify container"
CONTAINER=$(sudo docker ps -l | awk "/ ubuntu:xenial / { print \$1 }")
sudo docker stop $CONTAINER
sudo docker rm -v $CONTAINER
