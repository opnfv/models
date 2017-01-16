#!/bin/bash
# Copyright 2017 AT&T Intellectual Property, Inc
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
# What this is: Setup script for OpenStack Clients running in  
# an Unbuntu Xenial docker container.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ bash osclient.sh setup|run 
#   init: create container and pass this script there with setup arg
#   setup: install the OpenStack CLI clients in the container
#     bash osclient.sh setup credential_script [branch]
#     credential_script: OpenStack CLI env setup script (e.g. admin-openrc.sh)
#     branch: git repo branch to install (e.g. stable/newton)
#   run: run a command in the container
#     bash osclient.sh run command
#     command: command to run, in quotes

trap 'fail' ERR

pass() {
  echo "$0: $(date) Install success!"
  end=`date +%s`
  runtime=$((end-start))
  echo "$0: $(date) Duration = $runtime seconds"
  exit 0
}

fail() {
  echo "$0: $(date) Install Failed!"
  end=`date +%s`
  runtime=$((end-start))
  runtime=$((runtime/60))
  echo "$0: $(date) Duration = $runtime seconds"
  exit 1
}

function create_container() {
  echo "$0: $(date) Creating docker container for osclient"
  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: $(date) Ubuntu-based install"
    sudo apt-get update
    sudo apt-get install apt-transport-https ca-certificates
    sudo apt-key adv \
               --keyserver hkp://ha.pool.sks-keyservers.net:80 \
               --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
    repo="deb https://apt.dockerproject.org/repo ubuntu-xenial main"
    echo "$repo" | sudo tee /etc/apt/sources.list.d/docker.list
    sudo apt-get update
    sudo apt-get install -y linux-image-extra-$(uname -r) linux-image-extra-virtual
    sudo apt-get install -y docker-engine
    sudo service docker start
    # xenial is needed for python 3.5
    sudo docker pull ubuntu:xenial
    sudo service docker start
    sudo docker run -i -t -d -v /tmp/osclient/:/tmp/osclient --name osclient \
      ubuntu:xenial /bin/bash
    sudo docker exec osclient /bin/bash /tmp/osclient/osclient-setup.sh \
      setup /tmp/osclient/admin-openrc.sh $branch
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
    sudo docker run -i -t -d -v /tmp/osclient/:/tmp/osclient --name osclient \
      ubuntu:xenial /bin/bash
    sudo docker exec osclient /bin/bash /tmp/osclient/osclient-setup.sh setup \
      /tmp/osclient/admin-openrc.sh $branch
  fi
}

install_client () {
  echo "$0: $(date) Install $1"
  git clone https://github.com/openstack/$1.git
  cd $1
  if [ $# -eq 2 ]; then git checkout $2; fi
  pip install -r requirements.txt
  pip install .
  cd ..
}

function setup () {
  apt-get update
  apt-get install -y python
  apt-get install -y python-dev
  apt-get install -y python-pip
  apt-get install -y wget
  apt-get install -y git
  apt-get install -y apg
  apt-get install -y libffi-dev
  apt-get install -y libssl-dev

  cd /tmp/osclient

  echo "$0: $(date) Upgrage pip"
  pip install --upgrade pip

  echo "$0: $(date) Install OpenStack clients"
  install_client python-openstackclient $branch
  install_client python-neutronclient $branch
  install_client python-heatclient $branch
  install_client python-congressclient $branch

  echo "$0: $(date) Setup shell environment variables"
  echo "source $openrc" >>~/.bashrc
  source ~/.bashrc
}

start=`date +%s`
dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

case "$1" in
  setup)
    openrc=$2
    branch=$3
    if [[ -f /.dockerenv ]]; then
      echo "$0: $(date) Running inside docker - finish setup"
      setup $openrc $branch
    else
      echo "$0: $(date) Setup shared virtual folder and save $1 script there"
      if [[ ! -d /tmp/osclient ]]; then mkdir /tmp/osclient; fi
      cp $0 /tmp/osclient/osclient-setup.sh
      cp $openrc /tmp/osclient/admin-openrc.sh
      chmod 755 /tmp/osclient/*.sh
      create_container
    fi
    pass
    ;;
  run)
    cat >/tmp/osclient/command.sh <<EOF
source /tmp/osclient/admin-openrc.sh
$2
exit
EOF
    sudo docker exec osclient /bin/bash /tmp/osclient/command.sh "$0"
    ;;
  clean)
    sudo docker stop osclient
    sudo docker rm -v osclient
    rm -rf /tmp/osclient
    pass
    ;;
  *)
    echo "usage: bash osclient-setup.sh init|setup credential_script [branch]"
    echo "init: create container and pass this script there with setup arg"
    echo "setup: install the OpenStack CLI clients in the container"
    echo "credential_script: OpenStack CLI env setup script (e.g. admin-openrc.sh)"
    echo "branch: git repo branch to install (e.g. stable/newton)"
    fail
esac
