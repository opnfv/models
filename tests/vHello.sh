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
# What this is: Deployment test for the Cloudify Hello World blueprint. 
#
# Status: this is a work in progress, under test.
#
# How to use:
#   Save this file and cloudify-setup.sh in ~/tmp/cloudify/
#   $ bash /tmp/cloudify/vHello.sh [setup | start | clean]
#   setup: setup Cloudify Manager
#   start: run test
#   clean: cleanup after test

pass() {
  echo "Hooray!"
  set +x #echo off
  exit 0
}

# Use this to trigger fail() at the right places
# if [ "$RESULT" == "Test Failed!" ]; then fail; fi
fail() {
  echo "Test Failed!"
  set +x
  exit 1
}

if [[ "$1" == "setup" ]]; then
  echo "vHello.sh: cloudify-setup part 1"
  bash /tmp/cloudify/cloudify-setup.sh 1

  echo "vHello.sh: cloudify-setup part 2"
  CONTAINER=$(sudo docker ps -l | awk "/ ubuntu:xenial / { print \$1 }")
  if [[ $(sudo docker exec $CONTAINER /root/cloudify-setup.sh 2) ]]; then fail; fi
  pass
fi

if [[ "$1" == "start" ]]; then
  echo "vHello.sh: run vHello test in cloudify-setup container"
  CONTAINER=$(sudo docker ps -l | awk "/ ubuntu:xenial / { print \$1 }")
  if [[ $(sudo docker exec $CONTAINER /root/vHello.sh) ]]; then fail; fi
  pass
fi

echo "vHello.sh: select manager to use"
MANAGER_IP=$(openstack server list | awk "/ cloudify-manager-server / { print \$9 }")
cfy use -t $MANAGER_IP
if [ $? -eq 1 ]; then fail; fi

if [[ "$1" == "clean" ]]; then
  echo "vHello.sh: uninstall vHello blueprint"
  cfy executions start -w uninstall -d vHello

  echo "vHello.sh: delete vHello blueprint"
  cfy deployments delete -d vHello
  if [ $? -eq 1 ]; then fail; fi
  pass
fi

echo "vHello.sh: reset blueprints folder"
cd ~
rm -rf blueprints
mkdir blueprints

echo "vHello.sh: clone cloudify-hello-world-example"
cd blueprints
git clone https://github.com/cloudify-cosmo/cloudify-hello-world-example.git
git checkout 3.4.1-build

echo "vHello.sh: create blueprint inputs file"
# Set host image per Cloudify agent compatibility: http://docs.getcloudify.org/3.4.0/agents/overview/
cat <<EOF >vHello-inputs.yaml
  image: CentOS-7-x86_64-GenericCloud-1607
  flavor: m1.small
  agent_user: centos
  webserver_port: 8080
EOF

echo "vHello.sh: create vHello deployment"
cfy deployments create --debug -d vHello -i vHello-inputs.yaml -b cloudify-hello-world-example
if [ $? -eq 1 ]; then fail; fi

echo "vHello.sh: execute 'install' workflow for vHello deployment"
cfy executions start -w install -d vHello --timeout 1800
if [ $? -eq 1 ]; then fail; fi

echo "vHello.sh: verify vHello server is running"
SERVER_IP=$(cfy deployments outputs -d vHello | awk "/ Value: / { print \$2 }")
apt-get install -y curl
if [[ $(curl $SERVER_IP | grep -c "Hello, World!") != 1 ]]; then fail; fi

pass

