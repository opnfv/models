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
# What this is: Setup script for the Cloudify Manager starting from an
# Unbuntu Trusty docker container.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   Save this file in ~/cloudify/cloudify-setup.sh
#   $ bash ~/cloudify/cloudify-setup.sh [ 1 || 2 ]
#   1: Initial setup of the docker container
#   2: Setup of the Cloudify Manager in the docker container

# Find external network name

function setenv () {

if [ "$dist" == "Ubuntu" ]; then
  echo "Create the environment file"
  KEYSTONE_HOST=$(juju status --format=short | awk "/keystone\/0/ { print \$3 }")
  cat <<EOF >~/admin-openrc
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
  echo "Centos-based install"
  echo "Setup undercloud environment so we can get overcloud Controller server address"
  source ~/stackrc
  echo "Get address of Controller node"
  export CONTROLLER_HOST1=$(openstack server list | awk "/overcloud-controller-0/ { print \$8 }" | sed 's/ctlplane=//g')
  echo "Create the environment file"
  cat <<EOF >~/admin-openrc
export CONGRESS_HOST=$CONTROLLER_HOST1
export KEYSTONE_HOST=$CONTROLLER_HOST1
export CEILOMETER_HOST=$CONTROLLER_HOST1
export CINDER_HOST=$CONTROLLER_HOST1
export GLANCE_HOST=$CONTROLLER_HOST1
export NEUTRON_HOST=$CONTROLLER_HOST1
export NOVA_HOST=$CONTROLLER_HOST1
EOF
  cat ~/overcloudrc >>~/admin-openrc
  source ~/overcloudrc
  export OS_REGION_NAME=$(openstack endpoint list | awk "/ nova / { print \$4 }")
  # sed command below is a workaound for a bug - region shows up twice for some reason
  cat <<EOF | sed '$d' >>~/admin-openrc
export OS_REGION_NAME=$OS_REGION_NAME
EOF
fi
source ~/admin-openrc
}

function get_external_net () {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${network_ids[@]}; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && ext_net_id=${id}
  done
  if [[ $ext_net_id ]]; then 
    EXTERNAL_NETWORK_NAME=$(openstack network show $ext_net_id | awk "/ name / { print \$4 }")
    EXTERNAL_SUBNET_ID=$(openstack network show $EXTERNAL_NETWORK_NAME | awk "/ subnets / { print \$4 }")
  else
    echo "cloudify-setup.sh: External network not found"
    exit 1
  fi
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
if [ "$1" == "1" ]; then
  echo "cloudify-setup.sh: Setup admin-openrc"
  setenv
  echo "cloudify-setup.sh: Setup container"
  if [ "$dist" == "Ubuntu" ]; then
    # xenial is needed for python 3.5
    sudo docker pull ubuntu:xenial
    sudo service docker start
    sudo docker run -it  -v ~/git/joid/ci/cloud/admin-openrc:/root/admin-openrc -v ~/cloudify/cloudify-setup.sh:/root/cloudify-setup.sh ubuntu:xenial /bin/bash
    exit 0
  fi
else 
  if [ "$1" == "2" ]; then
    echo "cloudify-setup.sh: Install dependencies - OS specific"
    if [ "$dist" == "Ubuntu" ]; then
      apt-get update
      apt-get install -y python
      apt-get install -y python-dev
      apt-get install -y python-pip
      apt-get install -y wget
      apt-get install -y openssh-server
#    apt-get install -y apg git gcc python-dev libxml2 libxslt1-dev libzip-dev 
#    pip install --upgrade pip virtualenv setuptools pbr tox
    fi
  else 
    echo "usage: bash cloudify-setup.sh [ 1 || 2 ]"
    echo "1: Initial setup of the docker container"
    echo "2: Setup of the Cloudify Manager in the docker container"
    exit 1
  fi
fi

cd ~

echo "cloudify-setup.sh: Install dependencies - generic"
pip install --upgrade pip virtualenv

echo "cloudify-setup.sh: Upgrage pip again - needs to be the latest version due to errors found in earlier testing"
pip install --upgrade pip

echo "cloudify-setup.sh: install python-openstackclient python-glanceclient"
pip install python-openstackclient python-glanceclient  python-neutronclient

echo "cloudify-setup.sh: cleanup any previous install attempt"
rm -rf cloudify
rm -rf cloudify-manager
rm get-cloudify.py

echo "cloudify-setup.sh: Create virtualenv"
virtualenv ~/cloudify/venv
source ~/cloudify/venv/bin/activate

echo "cloudify-setup.sh: Get Cloudify"
wget http://gigaspaces-repository-eu.s3.amazonaws.com/org/cloudify3/get-cloudify.py
python get-cloudify.py --upgrade

echo "cloudify-setup.sh: Initialize Cloudify"
cfy init

echo "cloudify-setup.sh: Prepare the Cloudify Manager data"
mkdir -p ~/cloudify-manager
cd ~/cloudify-manager
wget https://github.com/cloudify-cosmo/cloudify-manager-blueprints/archive/3.4.tar.gz
mv 3.4.tar.gz cloudify-manager-blueprints.tar.gz
tar -xzvf cloudify-manager-blueprints.tar.gz
cd cloudify-manager-blueprints-3.4

echo "cloudify-setup.sh: Setup admin-openrc"
source ~/admin-openrc

echo "cloudify-setup.sh: Setup keystone_username"
sed -i -- "s/keystone_username: ''/keystone_username: '$OS_USERNAME'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup keystone_password"
sed -i -- "s/keystone_password: ''/keystone_password: '$OS_PASSWORD'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup keystone_tenant_name"
sed -i -- "s/keystone_tenant_name: ''/keystone_tenant_name: '$OS_TENANT_NAME'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup keystone_url"
# Use ~ instead of / as regex delimeter, since this variable contains slashes
sed -i -- "s~keystone_url: ''~keystone_url: '$OS_AUTH_URL'~g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup region"
sed -i -- "s/region: ''/region: '$OS_REGION_NAME'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup manager_public_key_name"
sed -i -- "s/#manager_public_key_name: ''/manager_public_key_name: 'cloudify-manager'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup agent_public_key_name"
sed -i -- "s/#agent_public_key_name: ''/agent_public_key_name: 'cloudify-agent'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup image_id"
# CentOS-7-x86_64-GenericCloud.qcow2 failed to be routable (?), so changed to 1607 version
image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
if [ -z $image ]; then glance --os-image-api-version 1 image-create --name CentOS-7-x86_64-GenericCloud-1607 --disk-format qcow2 --location http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2-1607 --container-format bare
fi
image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
sed -i -- "s/image_id: ''/image_id: '$image'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup flavor_id"
flavor=$(nova flavor-show m1.large | awk "/ id / { print \$4 }")
sed -i -- "s/flavor_id: ''/flavor_id: '$flavor'/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Setup external_network_name"
get_external_net
sed -i -- "s/external_network_name: ''/external_network_name: '$EXTERNAL_NETWORK_NAME'/g" openstack-manager-blueprint-inputs.yaml

# By default, only the cloudify-management-router is setup as DNS server, and it was failing to resolve internet domain names, which was blocking download of needed resources
echo "cloudify-setup.sh: Add nameservers"
sed -i -- "s/#management_subnet_dns_nameservers: \[\]/management_subnet_dns_nameservers: \[8.8.8.8\]/g" openstack-manager-blueprint-inputs.yaml

echo "cloudify-setup.sh: Bootstrap the manager"
cfy bootstrap --install-plugins --keep-up-on-failure -p openstack-manager-blueprint.yaml -i openstack-manager-blueprint-inputs.yaml

