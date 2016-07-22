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
#   $ bash cloudify-setup.sh [ 1 || 2 ]
#   1: Initial setup of the docker container
#   2: Setup of the Cloudify Manager in the docker container

# Find external network name

function get_external_net () {
  LINE=4
  ID=$(openstack network list | awk "NR==$LINE{print \$2}")
  while [[ $ID ]]
    do
    if [[ $(openstack network show $ID | awk "/ router:external / { print \$4 }") == "True" ]]; then break; fi
    ((ID+=1))
  done 
  if [[ $ID ]]; then 
    EXTERNAL_NETWORK_NAME=$(openstack network show $ID | awk "/ name / { print \$4 }")  
  else
    echo "External network not found"
    return 1
  fi
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

if [ "$1" == "1" ]; then
  # Setup container 
  if [ "$dist" == "Ubuntu" ]; then
    sudo docker pull ubuntu:trusty
    sudo service docker start
    sudo docker run -it  -v ~/git/joid/ci/cloud/admin-openrc:/root/admin-openrc -v ~/cloudify/cloudify-setup.sh:/root/cloudify-setup.sh ubuntu /bin/bash
    exit 0
  fi
else
  # Install dependencies - OS specific
  if [ "$dist" == "Ubuntu" ]; then
    apt-get update
    apt-get install -y python python-dev python-pip wget 
#    apt-get install -y apg git gcc python-dev libxml2 libxslt1-dev libzip-dev 
#    pip install --upgrade pip virtualenv setuptools pbr tox
  fi
fi

cd ~

# Install dependencies - generic
pip install --upgrade pip virtualenv
# Upgrage pip again - needs to be the latest version due to errors found in earlier testing
pip install --upgrade pip
pip install python-openstackclient python-glanceclient  

# Create virtualenv
virtualenv ~/cloudify/venv
source ~/cloudify/venv/bin/activate

# Get Cloudify
wget http://gigaspaces-repository-eu.s3.amazonaws.com/org/cloudify3/get-cloudify.py
python get-cloudify.py --upgrade

# Initialize Cloudify
cfy init

# Prepare the Cloudify Manager data
mkdir -p ~/cloudify-manager
cd ~/cloudify-manager
wget https://github.com/cloudify-cosmo/cloudify-manager-blueprints/archive/3.4.tar.gz 
mv 3.4.tar.gz cloudify-manager-blueprints.tar.gz
tar -xzvf cloudify-manager-blueprints.tar.gz
cd cloudify-manager-blueprints-3.4
source ~/admin-openrc
sed -i -- "s/keystone_username: ''/keystone_username: '$OS_USERNAME'/g" openstack-manager-blueprint-inputs.yaml
sed -i -- "s/keystone_password: ''/keystone_password: '$OS_PASSWORD'/g" openstack-manager-blueprint-inputs.yaml
sed -i -- "s/keystone_tenant_name: ''/keystone_tenant_name: '$OS_TENANT_NAME'/g" openstack-manager-blueprint-inputs.yaml
sed -i -- "s/keystone_url: ''/keystone_url: '$OS_AUTH_URL'/g" openstack-manager-blueprint-inputs.yaml
sed -i -- "s/region: ''/region: '$OS_REGION_NAME'/g" openstack-manager-blueprint-inputs.yaml
sed -i -- "s/#manager_public_key_name: ''/manager_public_key_name: 'manager-key'/g" openstack-manager-blueprint-inputs.yaml
sed -i -- "s/#agent_public_key_name: ''/agent_public_key_name: 'manager-key'/g" openstack-manager-blueprint-inputs.yaml
image=$(openstack image list | awk "/ CentOS-7-x86_64-GenericCloud / { print \$2 }")
if [ -z $image ]; then glance --os-image-api-version 1 image-create --name CentOS-7-x86_64-GenericCloud --disk-format qcow2 --location http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2 --container-format bare
fi
sed -i -- "s/image_id: ''/image_id: '$image'/g" openstack-manager-blueprint-inputs.yaml
flavor=$(nova flavor-show m1.tiny | awk "/ id / { print \$4 }")
sed -i -- "s/flavor_id: ''/flavor_id: 'm1.tiny'/g" openstack-manager-blueprint-inputs.yaml
get_external_net
sed -i -- "s/external_network_name: ''/external_network_name: '$EXTERNAL_NETWORK_NAME'/g" openstack-manager-blueprint-inputs.yaml

# Bootstrap the manager
cfy bootstrap --install-plugins -p openstack-manager-blueprint.yaml -i openstack-manager-blueprint-inputs.yaml

