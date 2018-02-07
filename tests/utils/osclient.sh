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
# What this is: Setup script for OpenStack Clients (OSC) running in
# an Unbuntu Xenial docker container. You can use this script to isolate the
# OSC from your host, so that the OSC and related install pre-reqs do not
# pollute your host environment. You can then then modify your tests scripts on
# your host and run them using the OSC container rather than moving the test
# scripts to DevStack or an OpenStack installation (see below). You can also
# attach to the OSC container. Enter "sudo docker attach osclient" then hit enter
# twice and you will be in the container as root (there are no other users).
# Once in the container, you can "source ~/tmp/osclient/admin-openrc.sh" and use
# any OSC commands you want.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   1) Obtain the credential script for your OpenStack installation by logging
#      into the OpenStack Dashboard and downloading the OpenStack RD file from
#      Project -> Access & Security -> API Access
#   2) Edit the *-openrc.sh file:
#      * remove the following lines:
#        echo "Please enter your OpenStack Password for project $OS_TENANT_NAME as user $OS_USERNAME: "
#        read -sr OS_PASSWORD_INPUT
#      * replace $OS_PASSWORD_INPUT with the password
#   3) execute this command: $ bash osclient.sh setup <path to credential script> [branch]
#      * setup: install the OpenStack CLI clients in a container on the host.
#      * <path to credential script> location of the *-openrc.sh file you edited in step 2
#      * branch: git repo branch to install (e.g. stable/newton) OPTIONAL; if you want the master branch,
#        do not include this parameter
#      * Example:
#        If the admin-openrc.sh file is in the same directory as osclient.sh and you want to use stable/newton:
#         $ bash osclient.sh setup admin-openrc.sh stable/newton
#        If the admin-openrc.sh file is in a different directory and you want to use master:
#         $ bash osclient.sh setup ~/Downloads/admin-openrc.sh
#
# Once the Docker container has been created and is running, you can run your scripts
#   $ bash osclient.sh run <command>
#     * run: run a command in the container
#     * <command>: command to run, in quotes e.g.
#         bash osclient.sh run 'openstack service list'
#         bash osclient.sh run 'bash mytest.sh'
# To run tests in the container:
#  1) Copy the tests to the shared folder for the container (/tmp/osclient)
#  2) Run your tests; for example, if you want to run Copper tests:
#     $ bash ~/git/models/tests/utils/osclient.sh run "bash ~/tmp/osclient/copper/tests/network_bridging.sh"
#     $ bash ~/git/models/tests/utils/osclient.sh run "bash ~/tmp/osclient/copper/tests/network_bridging-clean.sh"
#  3) Due to a (?) Docker quirk, you need to remove and re-copy the tests each time you change them, e.g. as you edit the tests during development
#     $ rm -rf ~/tmp/osclient/copper/tests/; cp -R ~/git/copper/tests/ ~/tmp/osclient/copper/tests/
#
# To stop and then remove the Docker container
#   $ bash osclient.sh clean
#     * clean: remove the osclient container and shared folder
#     Note: you may have to run as sudo in order to delete the files in ~/tmp/osclient


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
    sudo docker run -i -t -d -v ~/tmp/osclient/:/tmp/osclient --name osclient \
      ubuntu:xenial /bin/bash
    sudo docker exec osclient /bin/bash ~/tmp/osclient/osclient-setup.sh \
      setup ~/tmp/osclient/admin-openrc.sh $branch
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
    sudo docker run -i -t -d -v ~/tmp/osclient/:/tmp/osclient --name osclient \
      ubuntu:xenial /bin/bash
    sudo docker exec osclient /bin/bash ~/tmp/osclient/osclient-setup.sh setup \
      ~/tmp/osclient/admin-openrc.sh $branch
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

  cd ~/tmp/osclient

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
  
  echo "$0: $(date) Install nano"
  apt-get install nano
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
      if [[ ! -d ~/tmp/osclient ]]; then mkdir ~/tmp/osclient; fi
      cp $0 ~/tmp/osclient/osclient-setup.sh
      cp $openrc ~/tmp/osclient/admin-openrc.sh
      chmod 755 ~/tmp/osclient/*.sh
      create_container
    fi
    pass
    ;;
  run)
    cat >/tmp/osclient/command.sh <<EOF
source ~/tmp/osclient/admin-openrc.sh
$2
exit
EOF
    sudo docker exec osclient /bin/bash ~/tmp/osclient/command.sh "$0"
    ;;
  clean)
    sudo docker stop osclient
    sudo docker rm -v osclient
    rm -rf ~/tmp/osclient
    pass
    ;;
  *)
echo "   $ bash osclient.sh setup|run|clean (see detailed parameters below)"
echo "   setup: install the OpenStack CLI clients in a container on the host."
echo "     $ bash osclient.sh setup <path to credential script> [branch]"
echo "     <path to credential script>: OpenStack CLI env setup script (e.g."
echo "       admin-openrc.sh), obtained from the OpenStack Dashboard via"
echo "       Project->Access->Security->API. It's also recommended that you set the"
echo "       OpenStack password explicitly in that script rather than take the"
echo "       default which will prompt you on every command you pass to the container."
echo "       For example, if the admin-openrc.sh file is in the same directory as "
echo "       osclient.sh and you want to use stable/newton:"
echo "         $ bash osclient.sh setup admin-openrc.sh stable/newton"
echo "     branch: git repo branch to install (e.g. stable/newton)"
echo "   run: run a command in the container"
echo "     $ bash osclient.sh run <command>"
echo "     <command>: command to run, in quotes e.g."
echo "       bash osclient.sh run 'openstack service list'"
echo "       bash osclient.sh run 'bash mytest.sh'"
echo "   clean: remove the osclient container and shared folder"
echo "     $ bash osclient.sh clean"
fail
esac
