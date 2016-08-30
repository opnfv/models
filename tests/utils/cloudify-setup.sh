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
# What this is: Setup script for the Cloudify Manager starting from an
# Unbuntu Xenial docker container.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ bash cloudify-setup.sh [cloudify-cli|cloudify-manager] [ 1 || 2 ]
#   cloudify-cli: use Cloudify CLI
#   cloudify-manager: use Cloudify Manager
#   1: Initial setup of the docker container
#   2: Setup of the Cloudify Manager in the docker container

function setenv () {
if [ "$dist" == "Ubuntu" ]; then
  echo "$0: Ubuntu-based install"
  echo "$0: Create the environment file"
  KEYSTONE_HOST=$(juju status --format=short | awk "/keystone\/0/ { print \$3 }")
  cat <<EOF >/tmp/cloudify/admin-openrc.sh
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
  echo "$0: Centos-based install"
  echo "$0: Setup undercloud environment so we can get overcloud Controller server address"
  source ~/stackrc
  echo "$0: Get address of Controller node"
  export CONTROLLER_HOST1=$(openstack server list | awk "/overcloud-controller-0/ { print \$8 }" | sed 's/ctlplane=//g')
  echo "$0: Create the environment file"
  cat <<EOF >/tmp/cloudify/admin-openrc.sh
export CONGRESS_HOST=$CONTROLLER_HOST1
export KEYSTONE_HOST=$CONTROLLER_HOST1
export CEILOMETER_HOST=$CONTROLLER_HOST1
export CINDER_HOST=$CONTROLLER_HOST1
export GLANCE_HOST=$CONTROLLER_HOST1
export NEUTRON_HOST=$CONTROLLER_HOST1
export NOVA_HOST=$CONTROLLER_HOST1
EOF
  cat ~/overcloudrc >>/tmp/cloudify/admin-openrc.sh
  source ~/overcloudrc
  export OS_REGION_NAME=$(openstack endpoint list | awk "/ nova / { print \$4 }")
  # sed command below is a workaound for a bug - region shows up twice for some reason
  cat <<EOF | sed '$d' >>/tmp/cloudify/admin-openrc.sh
export OS_REGION_NAME=$OS_REGION_NAME
EOF
fi
source /tmp/cloudify/admin-openrc.sh
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
    echo "$0: External network not found"
    exit 1
  fi
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
if [ "$2" == "1" ]; then
  echo "$0: Copy this script to /tmp/cloudify"
	mkdir /tmp/cloudify
  cp $0 /tmp/cloudify/.
  chmod 755 /tmp/cloudify/*.sh

  echo "$0: Setup admin-openrc.sh"
  setenv
  echo "$0: Setup container"
  if [ "$dist" == "Ubuntu" ]; then
    # xenial is needed for python 3.5
    sudo docker pull ubuntu:xenial
    sudo service docker start
#    sudo docker run -it  -v ~/git/joid/ci/cloud/admin-openrc.sh:/root/admin-openrc.sh -v ~/cloudify/cloudify-setup.sh:/root/cloudify-setup.sh ubuntu:xenial /bin/bash
    sudo docker run -it -d -v /tmp/cloudify/:/tmp/cloudify ubuntu:xenial /bin/bash
    exit 0
	else 
    # Centos
    echo "Centos-based install"
    sudo tee /etc/yum.repos.d/docker.repo <<-'EOF'
[dockerrepo]
name=Docker Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7/
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg 
EOF
    sudo yum install -y docker-engine
    # xenial is needed for python 3.5
    sudo docker pull ubuntu:xenial
    sudo service docker start
#    sudo docker run -it  -v ~/git/joid/ci/cloud/admin-openrc.sh:/root/admin-openrc.sh -v ~/cloudify/cloudify-setup.sh:/root/cloudify-setup.sh ubuntu:xenial /bin/bash
    sudo docker run -i -t -d -v /tmp/cloudify/:/tmp/cloudify ubuntu:xenial /bin/bash
    exit 0
  fi
else 
  if [ "$2" == "2" ]; then
    echo "$0: Install dependencies - OS specific"
    if [ "$dist" == "Ubuntu" ]; then
      apt-get update
      apt-get install -y python
      apt-get install -y python-dev
      apt-get install -y python-pip
      apt-get install -y wget
      apt-get install -y openssh-server
      apt-get install -y git
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

echo "$0: Install dependencies - generic"
pip install --upgrade pip virtualenv

echo "$0: Upgrage pip again - needs to be the latest version due to errors found in earlier testing"
pip install --upgrade pip

echo "$0: install python-openstackclient python-glanceclient"
pip install --upgrade python-openstackclient python-glanceclient  python-neutronclient

echo "$0: cleanup any previous install attempt"
if [ -d "~/cloudify" ]; then rm -rf ~/cloudify; fi  
if [ -d "~/cloudify-manager" ]; then rm -rf ~/cloudify-manager; fi  
rm ~/get-cloudify.py

echo "$0: Create virtualenv"
virtualenv ~/cloudify/venv
source ~/cloudify/venv/bin/activate

echo "$0: Get Cloudify"
wget http://gigaspaces-repository-eu.s3.amazonaws.com/org/cloudify3/get-cloudify.py
python get-cloudify.py --upgrade

echo "$0: Initialize Cloudify"
cfy init

echo "$0: Setup admin-openrc.sh"
source /tmp/cloudify/admin-openrc.sh

if [ "$1" == "cloudify-manager" ]; then
  echo "$0: Prepare the Cloudify Manager prerequisites and data"
  mkdir -p ~/cloudify-manager
  cd ~/cloudify-manager
  wget https://github.com/cloudify-cosmo/cloudify-manager-blueprints/archive/3.4.tar.gz
  mv 3.4.tar.gz cloudify-manager-blueprints.tar.gz
  tar -xzvf cloudify-manager-blueprints.tar.gz
  cd cloudify-manager-blueprints-3.4

  echo "$0: Setup keystone_username"
  sed -i -- "s/keystone_username: ''/keystone_username: '$OS_USERNAME'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup keystone_password"
  sed -i -- "s/keystone_password: ''/keystone_password: '$OS_PASSWORD'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup keystone_tenant_name"
  sed -i -- "s/keystone_tenant_name: ''/keystone_tenant_name: '$OS_TENANT_NAME'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup keystone_url"
  # Use ~ instead of / as regex delimeter, since this variable contains slashes
  sed -i -- "s~keystone_url: ''~keystone_url: '$OS_AUTH_URL'~g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup region"
  sed -i -- "s/region: ''/region: '$OS_REGION_NAME'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup manager_public_key_name"
  sed -i -- "s/#manager_public_key_name: ''/manager_public_key_name: 'cloudify-manager'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup agent_public_key_name"
  sed -i -- "s/#agent_public_key_name: ''/agent_public_key_name: 'cloudify-agent'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup image_id"
  # CentOS-7-x86_64-GenericCloud.qcow2 failed to be routable (?), so changed to 1607 version
  image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
  if [ -z $image ]; then 
    glance --os-image-api-version 1 image-create --name CentOS-7-x86_64-GenericCloud-1607 --disk-format qcow2 --location http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-1607.qcow2 --container-format bare
  fi
  image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud-1607 / { print \$2 }")
  sed -i -- "s/image_id: ''/image_id: '$image'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup flavor_id"
  flavor=$(nova flavor-show m1.large | awk "/ id / { print \$4 }")
  sed -i -- "s/flavor_id: ''/flavor_id: '$flavor'/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Setup external_network_name"
  get_external_net
  sed -i -- "s/external_network_name: ''/external_network_name: '$EXTERNAL_NETWORK_NAME'/g" openstack-manager-blueprint-inputs.yaml

  # By default, only the cloudify-management-router is setup as DNS server, and it was failing to resolve internet domain names, which was blocking download of needed resources
  echo "$0: Add nameservers"
  sed -i -- "s/#management_subnet_dns_nameservers: \[\]/management_subnet_dns_nameservers: \[8.8.8.8\]/g" openstack-manager-blueprint-inputs.yaml

  echo "$0: Bootstrap the manager"
  cfy bootstrap --install-plugins --keep-up-on-failure --task-retries=10 -p openstack-manager-blueprint.yaml -i openstack-manager-blueprint-inputs.yaml

  echo "$0: install needed packages to support blueprints 'not using managed plugins'"
  # See https://cloudifysource.atlassian.net/browse/CFY-5050
  cfy ssh -c "sudo yum install -y gcc gcc-c++ python-devel"
else
  echo "$0: Prepare the Cloudify CLI prerequisites and data"
  cd /tmp/cloudify
  git clone https://github.com/cloudify-cosmo/cloudify-openstack-plugin.git		
  cd cloudify-openstack-plugin

  echo "Create management network"
  if [ $(neutron net-list | awk "/ cloudify_mgmt / { print \$2 }") ]; then
    echo "$0: cloudify_mgmt network exists"
  else
    neutron net-create cloudify_mgmt		
    echo "$0: Create management subnet"
    neutron subnet-create cloudify_mgmt 10.0.0.0/24 --name cloudify_mgmt --gateway 10.0.0.1 --enable-dhcp --allocation-pool start=10.0.0.2,end=10.0.0.254 --dns-nameserver 8.8.8.8
  fi

  echo "$0: Create router for cloudify_mgmt network"
  neutron router-create cloudify_mgmt_router

  echo "$0: Create router gateway for cloudify_mgmt network"
  neutron router-gateway-set cloudify_mgmt_router $EXTERNAL_NETWORK_NAME

  echo "$0: Add router interface for cloudify_mgmt network"
  neutron router-interface-add cloudify_mgmt_router subnet=cloudify_mgmt
		
  echo "$0: Patch plugin.yaml to reference management network"
  sed -i -- "s/management_network_name:\n        default: ''/management_network_name:\n        default: 'cloudify_mgmt'/" /tmp/cloudify/cloudify-openstack-plugin/plugin.yaml
    		
  python setup.py build
  python setup.py install
fi
