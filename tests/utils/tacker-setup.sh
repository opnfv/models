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
# What this is: Setup script for the OpenStack Tacker VNF Manager starting from
# an Unbuntu Xenial docker container, on either an Ubuntu Xenial or Centos 7
# host. This script is intended to be used in an OPNFV environment, or a plain
# OpenStack environment (e.g. Devstack).
# This install procedure is intended to deploy Tacker for testing purposes only.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ bash tacker-setup.sh setup|clean> <openrc> [branch]
#     setup: Start and setup Tacker container
#     clean: Remove Tacker service and container
#.    openrc: location of OpenStack openrc file
#     branch: OpenStack branch to install (default: master)

trap 'fail' ERR

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

pass() {
  log "Hooray!"
  end=`date +%s`
  runtime=$((end-start))
  log "Duration = $runtime seconds"
  exit 0
}

fail() {
  log "Test Failed!"
  end=`date +%s`
  runtime=$((end-start))
  runtime=$((runtime/60))
  log "Duration = $runtime seconds"
  exit 1
}

function create_container() {
  log "Delete any existing tacker container"
  sudo docker stop tacker
  sudo docker rm -v tacker

  log "Start tacker container"
  if [ "$dist" == "Ubuntu" ]; then
    log "Ubuntu-based install"
    dpkg -l docker-engine
    if [[ $? -eq 1 ]]; then
      sudo apt-get install -y apt-transport-https ca-certificates
      sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
      echo "deb https://apt.dockerproject.org/repo ubuntu-xenial main" | sudo tee /etc/apt/sources.list.d/docker.list
      sudo apt-get update
      sudo apt-get purge lxc-docker
      sudo apt-get install -y linux-image-extra-$(uname -r) linux-image-extra-virtual
      sudo apt-get install -y docker-engine
      sudo service docker start
    fi
    sudo service docker start
    sudo apt-get install -y wget
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
    sudo service docker start
    sudo yum install -y wget
  fi

  if [ -d /opt/tacker ]; then sudo rm -rf /opt/tacker; fi
  sudo mkdir -p /opt/tacker
  sudo chown $USER /opt/tacker
  cp $openrc /opt/tacker/admin-openrc.sh
  if [[ -f /etc/ssl/certs/mcp_os_cacert ]]; then
    cp /etc/ssl/certs/mcp_os_cacert /opt/tacker/mcp_os_cacert
  fi
 
  if [[ "$branch" == "" ]]; then branch="latest"; fi
  log "Start tacker container with image blsaws/models-tacker:$branch"
  OS_TENANT_ID=$(openstack project show admin | awk '/ id / {print $4}')
  sudo docker run -it -d -p 9890:9890 -v /opt/tacker:/opt/tacker --name tacker \
    -e OS_AUTH_URL=$OS_AUTH_URL \
    -e OS_USERNAME=$OS_USERNAME \
    -e OS_PASSWORD=$OS_PASSWORD \
    blsaws/models-tacker:$branch
}

function clean () {
  source /opt/tacker/admin-openrc.sh
  eid=($(openstack endpoint list | awk "/tacker/ { print \$2 }")); for id in "${eid[@]}"; do openstack endpoint delete ${id}; done
  openstack user delete $(openstack user list | awk "/tacker/ { print \$2 }")
  openstack service delete $(openstack service list | awk "/tacker/ { print \$2 }")
  sid=($(openstack stack list|grep -v "+"|grep -v id|awk '{print $2}')); for id in "${sid[@]}"; do openstack stack delete ${id};  done
  pass
}

start=`date +%s`
dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

openrc=$2
branch=$3

case "$1" in
  "setup")
    create_container
    pass
    ;;
  "clean")
    clean
    pass
    ;;
  *)
    echo "usage: bash tacker-setup.sh [init|setup|clean]"
    echo "init: Initialize docker container"
    echo "setup: Setup of Tacker in the docker container"
    echo "clean: remove Tacker service"
    fail
esac
