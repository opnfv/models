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
#. What this is: Build script for the OpenStack Tacker project
#.   https://github.com/openstack/tacker
#.
#. Prerequisites:
#.   Docker hub user logged on so images can be pushed to docker hub, i.e. via
#.   $ docker login -u <hub-user>
#.
#. Usage:
#.   bash tacker.sh <hub-user> <branch>
#.     hub-user: username for dockerhub
#.     branch: branch to use (default: master)
#.
#. Status: this is a work in progress, under test.

trap 'fail' ERR

fail() {
  echo "Build Failed!"
  exit 1
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`

hub_user=$1
branch=$2

echo; echo "$0 $(date): Update package repos"
if [ "$dist" == "Ubuntu" ]; then
  sudo apt-get update
else
  sudo yum update -y
fi

if [[ ! -d /tmp/models ]]; then
  echo; echo "$0 $(date): Cloning models repo to /tmp/models"
  git clone https://gerrit.opnfv.org/gerrit/models /tmp/models
fi

echo; echo "$0 $(date): Starting Tacker build process"
cd /tmp/models/build/tacker
sed -i -- "s/<branch>/$branch/g" Dockerfile
sudo docker build -t tacker .

echo; echo "$0 $(date): Tagging the image as models-tacker:$branch"
if [[ "$branch" == "" ]]; then branch="latest"; fi
id=$(sudo docker images | grep tacker | awk '{print $3}')
id=$(echo $id | cut -d ' ' -f 1)
sudo docker tag $id $1/models-tacker:$branch

echo; echo "$0 $(date): Pushing the image to dockerhub as $1/models-tacker"
sudo docker push $1/models-tacker
