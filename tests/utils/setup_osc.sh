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
# What this is: Deployment test for the VES agent and collector based
# upon the Tacker Hello World blueprint, designed as a manual demo of the VES
# concept using ONAP VNFs and integrating with the Barometer project collectd
# agent.
# Typical demo procedure is to execute the following actions from the OPNFV
# jumphost or some host wth access to the OpenStack controller
# (see below for details):
#  setup: install Tacker in a Docker container. Note: only needs to be done
#         once per session and can be reused across OPNFV VES and Models tests,
#         i.e. you can start another test at the "start" step below.
#  start: install blueprint and start the VNF, including the app (load-balanced
#         web server) and VES agents running on the VMs. Installs the VES
#         monitor code but does not start the monitor (see below).
#  start_collectd: start the collectd daemon on bare metal hypervisor hosts
#  monitor: start the VES monitor, typically run in a second shell session.
#  pause: pause the app at one of the web server VDUs (VDU1 or VDU2)
#  stop: stop the VNF and uninstall the blueprint
#  start_collectd: start the collectd daemon on bare metal hypervisor hosts
#  clean: remove the tacker container and service (if desired, when done)
#
# What this is: Script to install OpenStack clients on host
#
# How to use:
#   $ source setup_osc.sh

install_client () {
  echo "$0: $(date) Install $1"
  git clone https://github.com/openstack/$1.git
  cd $1
  if [ $# -eq 2 ]; then git checkout $2; fi
  pip install .
  cd ..
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
if [ "$dist" == "Ubuntu" ]; then
  sudo apt-get update
  sudo apt-get install -y gcc python-pip python-dev
else
  sudo yum update -y
  sudo yum install -y gcc python-pip python-devel
fi

sudo pip install --upgrade pip virtualenv setuptools pbr tox

echo "Create virtualenv"
virtualenv ~/venv
source ~/venv/bin/activate
# to stop virtualenv, enter the command "deactivate"

echo "$0: $(date) Install OpenStack clients"
mkdir ~/venv/git
cd ~/venv/git
install_client python-openstackclient $1
install_client python-heatclient $1
install_client python-neutronclient $1

