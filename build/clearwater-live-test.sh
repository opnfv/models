#!/bin/bash
# Copyright 2018 AT&T Intellectual Property, Inc
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
#. What this is: Build script for the github clearwater-live-test project
#.   https://github.com/Metaswitch/clearwater-live-test
#.
#. Prerequisites:
#.   Docker hub user logged on so images can be pushed to docker hub, i.e. via
#.   $ docker login -u <hub_user>
#.
#. Usage:
#.   bash clearwater-live-test.sh <hub_user> <tag> [--no-cache]
#.     hub_user: username for dockerhub
#.     tag: tag to apply to the built images
#.     --no-cache: build clean
#.
#. Status: this is a work in progress, under test.

trap 'fail' ERR

fail() {
  log "Build Failed!"
  exit 1
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo ""
  echo "$f:$l ($(date)) $1"
}

hub_user=$1
tag=$2
cache="$3"
dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
export WORK_DIR=$(pwd)

log "Update package repos"
if [ "$dist" == "Ubuntu" ]; then
  sudo apt-get update
else
  sudo yum update -y
fi

log "Starting clearwater-live-test build process"
if [[ -d ~/tmp/clearwater-live-test ]]; then rm -rf ~/tmp/clearwater-live-test; fi

log "Cloning clearwater-live-test repo to ~/tmp/clearwater-live-test"
git clone --recursive https://github.com/Metaswitch/clearwater-live-test.git \
  ~/tmp/clearwater-live-test
cd ~/tmp/clearwater-live-test

log "Building the image"
sudo docker build $cache -t clearwater/clearwater-live-test .

log "Tagging the image as $hub_user/clearwater-live-test:$tag"
id=$(sudo docker images | grep "clearwater-live-test " | awk '{print $3}')
id=$(echo $id | cut -d ' ' -f 1)
sudo docker tag $id $hub_user/clearwater-live-test:$tag

log "Pushing the image to dockerhub as $hub_user/clearwater-live-test"
sudo docker push $hub_user/clearwater-live-test

