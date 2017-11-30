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
#. What this is: Build script for the github clearwater-docker project
#.   https://github.com/Metaswitch/clearwater-docker
#.
#. Prerequisites:
#.   Docker hub user logged on so images can be pushed to docker hub, i.e. via
#.   $ docker login -u <hub-user>
#.
#. Usage:
#.   bash clearwater-docker.sh <hub-user>
#.     hub-user: username for dockerhub
#.
#. Status: this is a work in progress, under test.

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

echo; echo "$0 $(date): Update package repos"
if [ "$dist" == "Ubuntu" ]; then
  sudo apt-get update
else
  sudo yum update -y
fi

echo; echo "$0 $(date): Starting VES agent build process"
if [[ -d /tmp/clearwater-docker ]]; then rm -rf /tmp/clearwater-docker; fi

echo; echo "$0 $(date): Cloning clearwater-docker repo to /tmp/clearwater-docker"
  git clone https://github.com/Metaswitch/clearwater-docker.git \
   /tmp/clearwater-docker

echo; echo "$0 $(date): Building the images"
cd /tmp/clearwater-docker
vnfc="base astaire cassandra chronos bono ellis homer homestead homestead-prov ralf sprout"
for i in $vnfc ; do 
  sudo docker build -t clearwater/$i $i
done

echo; echo "$0 $(date): push images to docker hub"
for i in $vnfc ; do
  echo; echo "$0 $(date): Tagging the image as $1/clearwater-$i:latest"
  id=$(sudo docker images | grep clearwater/$i | awk '{print $3}')
  id=$(echo $id | cut -d ' ' -f 1)
  sudo docker tag $id $1/clearwater-$i:latest

  echo; echo "$0 $(date): Pushing the image to dockerhub as $1/clearwater-$i"
  sudo docker push $1/clearwater-$i
done
