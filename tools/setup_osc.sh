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
# What this is: Script to install OpenStack clients on host
#
# How to use:
#   $ source setup_osc.sh [branch]
#     branch: version to use e.g. "ocata" (default: master)

trap 'fail' ERR

function fail() {
  log $1
  exit 1
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo; echo "$f:$l ($(date)) $1"
}

install_client () {
  log "Install $1"
  git clone https://github.com/openstack/$1.git
  cd $1
  if [ $# -eq 2 ]; then git checkout $2; fi
  pip install .
  cd ..
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
if [ "$dist" == "Ubuntu" ]; then
  sudo apt-get update
  sudo apt-get install -y gcc python-pip python-dev git
else
  sudo yum update -y
  sudo yum install -y gcc python-pip python-devel git
fi

sudo pip install --upgrade pip virtualenv setuptools pbr tox

echo "Create virtualenv"
virtualenv ~/venv
source ~/venv/bin/activate
# to stop virtualenv, enter the command "deactivate"

log "Install OpenStack clients"
if [[ -d ~/venv/git ]]; then rm -rf ~/venv/git; fi 
mkdir ~/venv/git
cd ~/venv/git
install_client python-openstackclient $1
install_client python-heatclient $1
install_client python-neutronclient $1
