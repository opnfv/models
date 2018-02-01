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
#. What this is: Build script for the github clearwater-docker project
#.   https://github.com/Metaswitch/clearwater-docker
#.
#. Prerequisites:
#.   Docker hub user logged on so images can be pushed to docker hub, i.e. via
#.   $ docker login -u <hub_user>
#.
#. Usage:
#.   bash clearwater-docker.sh <hub_user> <tag> [--no-cache]
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

if [[ "$cache" == "--no-cache" ]]; then
  log "Purge old images"
  images=$(sudo docker images clearwater-* | awk '/clearwater/ {print $1}')
  for image in $images ; do sudo docker image rm $image; done
fi

log "Starting clearwater-docker build process"
if [[ -d /tmp/clearwater-docker ]]; then rm -rf /tmp/clearwater-docker; fi

log "Cloning clearwater-docker repo to /tmp/clearwater-docker"
git clone --recursive https://github.com/Metaswitch/clearwater-docker.git \
  /tmp/clearwater-docker

log "Building the images"
cd /tmp/clearwater-docker
vnfc="base astaire cassandra chronos bono ellis homer homestead homestead-prov ralf sprout"
for i in $vnfc ; do 
  log "Building $i"
  if [[ "$i" != "base" ]]; then
    log "Reference $hub_user/clearwater-base:$tag"
    sed -i -- "s~FROM clearwater/base~FROM $hub_user/clearwater-base:$tag~" \
      $i/Dockerfile
  fi
  sudo docker build $cache -t clearwater-$i $i
  log "Tagging the image as $hub_user/clearwater-$i:$tag"
  id=$(sudo docker images | grep "clearwater-$i " | awk '{print $3}')
  id=$(echo $id | cut -d ' ' -f 1)
  sudo docker tag $id $hub_user/clearwater-$i:$tag
  log "Pushing the image to dockerhub as $hub_user/clearwater-$i"
  sudo docker push $hub_user/clearwater-$i
done

cd $WORK_DIR
