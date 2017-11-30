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
#. What this is: Setup script for clearwater-docker as deployed by Cloudify 
#.   with Kubernetes. See https://github.com/Metaswitch/clearwater-docker
#.   for more info.
#.
#. Prerequisites:
#. - Kubernetes cluster installed per k8s-cluster.sh (in this repo)
#. - user (running this script) added to the "docker" group
#. - clearwater-docker images created and uploaded to docker hub under the 
#.   <hub-user> account as <hub-user>/clearwater-<vnfc> where vnfc is the name
#.   of the specific containers as built by build/clearwater-docker.sh
#.
#. Usage:
#.   From a server with access to the kubernetes master node:
#.   $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#.   $ cd ~/models/tools/cloudify/
#.   $ bash k8s-cloudify-clearwater.sh <start|stop> <hub-user> <manager>
#.
#. Status: this is a work in progress, under test.

function fail() {
  log "$1"
  exit 1
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo ""
  echo "$f:$l ($(date)) $1"
}

function build_local() {
  master=$1
  log "deploy local docker registry on k8s master"
  # Per https://docs.docker.com/registry/deploying/
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@$master sudo docker run -d -p 5000:5000 --restart=always --name \
    registry registry:2

  # per https://github.com/Metaswitch/clearwater-docker
  log "clone clearwater-docker"
  cd ~
  git clone https://github.com/Metaswitch/clearwater-docker.git

  log "build docker images"
  cd clearwater-docker
  vnfc="base astaire cassandra chronos bono ellis homer homestead homestead-prov ralf sprout"
  for i in $vnfc ; do 
    docker build -t clearwater/$i $i
  done
  
  # workaround for https://www.bountysource.com/issues/37326551-server-gave-http-response-to-https-client-error
  # May not need both...
  if [[ "$dist" == "ubuntu" ]]; then
    check=$(grep -c $master /etc/default/docker)
    if [[ $check -eq 0 ]]; then
      echo "DOCKER_OPTS=\"--insecure-registry $master:5000\"" | sudo tee -a /etc/default/docker
      sudo systemctl daemon-reload
      sudo service docker restart
    fi
  fi
  check=$(grep -c insecure-registry /lib/systemd/system/docker.service)
  if [[ $check -eq 0 ]]; then
    sudo sed -i -- "s~ExecStart=/usr/bin/dockerd -H fd://~ExecStart=/usr/bin/dockerd -H fd:// --insecure-registry $master:5000~" /lib/systemd/system/docker.service
    sudo systemctl daemon-reload
    sudo service docker restart
  fi

  log "deploy local docker registry on k8s master"
  # Per https://docs.docker.com/registry/deploying/
  # sudo docker run -d -p 5000:5000 --restart=always --name registry registry:2

  log "push images to local docker repo on k8s master"
  for i in $vnfc ; do
    docker tag clearwater/$i:latest $master:5000/clearwater/$i:latest
    docker push $master:5000/clearwater/$i:latest
  done
}


function start() {
  master=$1
}

function stop() {
  master=$1
}

dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}')
case "$1" in
  "start")
    start $2
    ;;
  "stop")
    stop $2
    ;;
  *)
    grep '#. ' $0
esac

