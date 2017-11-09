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
#. Prerequisites:
#. - Kubernetes cluster installed per k8s-cluster.sh (in this repo)
#. - user (running this script) added to the "docker" group
#. Usage:
#.   From a server with access to the kubernetes master node:
#.   $ git clone https://gerrit.opnfv.org/gerrit/models ~/models

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

function setup() {
  master=$1
  log "deploy local docker registry on k8s master"
  # Per https://docs.docker.com/registry/deploying/
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@$manager_ip sudo docker run -d -p 5000:5000 --restart=always --name \
    registry registry:2

  # per https://github.com/Metaswitch/clearwater-docker
  log "clone clearwater-docker"
  cd ~
  git clone https://github.com/Metaswitch/clearwater-docker.git

  log "build docker images"
  cd clearwater-docker
  vnfc="base astaire cassandra chronos bono ellis homer homestead \ 
    homestead-prov ralf sprout"
  for i in $vnfc ; do 
    docker build -t clearwater/$i $i
  done
  
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

function clean() {
  master=$1
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$1" in
  "setup")
    setup $2
    ;;
  "start")
    start $2
    ;;
  "stop")
    stop $2
    ;;
  "clean")
    clean
    ;;
  *)
    grep '#. ' $0
esac

