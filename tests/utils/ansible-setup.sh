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
# What this is: Setup script for Ansible in an Unbuntu Xenial docker container.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ bash ansible-setup.sh [init|setup|clean]
#   init: Initialize docker container
#   setup: Setup of Ansible in the docker container
#   clean: Clean

pass() {
  echo "$0: Hooray!"
  set +x #echo off
  exit 0
}

fail() {
  echo "$0: Failed!"
  set +x
  exit 1
}

function setenv () {
if [ "$dist" == "Ubuntu" ]; then
  echo "$0: Ubuntu-based install"
  echo "$0: Create the environment file"
  KEYSTONE_HOST=$(juju status --format=short | awk "/keystone\/0/ { print \$3 }")
  cat <<EOF >/tmp/ansible/admin-openrc.sh
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
  cat <<EOF >/tmp/ansible/admin-openrc.sh
export HORIZON_HOST=$CONTROLLER_HOST1
export CONGRESS_HOST=$CONTROLLER_HOST1
export KEYSTONE_HOST=$CONTROLLER_HOST1
export CEILOMETER_HOST=$CONTROLLER_HOST1
export CINDER_HOST=$CONTROLLER_HOST1
export GLANCE_HOST=$CONTROLLER_HOST1
export NEUTRON_HOST=$CONTROLLER_HOST1
export NOVA_HOST=$CONTROLLER_HOST1
EOF
  cat ~/overcloudrc >>/tmp/ansible/admin-openrc.sh
  source ~/overcloudrc
  export OS_REGION_NAME=$(openstack endpoint list | awk "/ nova / { print \$4 }")
  # sed command below is a workaound for a bug - region shows up twice for some reason
  cat <<EOF | sed '$d' >>/tmp/ansible/admin-openrc.sh
export OS_REGION_NAME=$OS_REGION_NAME
EOF
fi
source /tmp/ansible/admin-openrc.sh
}

function create_container () {
  echo "$0: Creating docker container for Ansible installation"
  # STEP 1: Create the Ansible container and launch it
  echo "$0: Copy this script to /tmp/ansible"
  mkdir /tmp/ansible
  cp $0 /tmp/ansible/.
  chmod 755 /tmp/ansible/*.sh

  echo "$0: Setup admin-openrc.sh"
  setenv

  echo "$0: Setup container"
  if [ "$dist" == "Ubuntu" ]; then
    # xenial is needed for python 3.5
    sudo docker pull ubuntu:xenial
    sudo service docker start
    sudo docker run -it -d -v /tmp/ansible/:/tmp/ansible --name ansible ubuntu:xenial /bin/bash
  else 
    # Centos
    echo "Centos-based install"
    sudo tee /etc/yum.repos.d/docker.repo <<-'EOF'
[dockerrepo]
name=Docker Repository--parents 
baseurl=https://yum.dockerproject.org/repo/main/centos/7/
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg 
EOF
    sudo yum install -y docker-engine
    # xenial is needed for python 3.5
    sudo service docker start
    sudo docker pull ubuntu:xenial
    sudo docker run -i -t -d -v /tmp/ansible/:/tmp/ansible --name ansible ubuntu:xenial /bin/bash
  fi
}

function setup () {
  echo "$0: Installing Ansible"
  # STEP 2: Install Ansible in the container
  # Per http://docs.ansible.com/ansible/intro_installation.html
  echo "$0: Install dependencies - OS specific"
  apt-get update
  apt-get install -y python
  apt-get install -y python-dev
  apt-get install -y python-pip
  apt-get install -y wget
  apt-get install -y openssh-server
  apt-get install -y git
  apt-get install -y apg
  apt-get install -y libffi-dev
  apt-get install -y libssl-dev

  echo "$0: Install Ansible and Shade"
  pip install --upgrade ansible
  pip install --upgrade shade

  echo "$0: Create key pair for interacting with servers via Ansible"
  ssh-keygen -t rsa -N "" -f /tmp/ansible/ansible.pem
  chmod 600 /tmp/ansible/ansible.pem
}

function clean () {
  sudo docker stop $(sudo docker ps -a | awk "/ansible/ { print \$1 }")
  sudo docker rm -v $(sudo docker ps -a | awk "/ansible/ { print \$1 }")
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$1" in
  "init")
    create_container
    pass
    ;;
  "setup")
    setup
    pass
    ;;
  "clean")
    clean
    pass
    ;;
  *)
    echo "usage: bash Ansible-setup.sh [init|setup|clean]"
    echo "init: Initialize docker container"
    echo "setup: Setup of Ansible in the docker container"
    echo "clean: remove Ansible"
    fail
esac
