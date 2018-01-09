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
# What this is: A Dockerfile for building an OpenStack Tacker container image.
#
# Status: this is a work in progress, under test.
#

FROM ubuntu:xenial

MAINTAINER Bryan Sullivan

# Per http://docs.openstack.org/developer/tacker/install/manual_installation.html
RUN apt-get update --fix-missing
RUN apt-get install -y apt-utils
RUN apt-get upgrade -y
RUN apt-get install -y python
RUN apt-get install -y python-dev
RUN apt-get install -y python-pip
RUN apt-get install -y wget
RUN apt-get install -y openssh-server
RUN apt-get install -y git
RUN apt-get install -y apg
RUN apt-get install -y libffi-dev
RUN apt-get install -y libssl-dev
# newton: tacker uses ping for monitoring VIM (not in default docker containers)
RUN apt-get install -y inetutils-ping
# apt-utils is not installed in xenial container image
RUN apt-get install -y apt-utils
# Upgrage pip again - needs to be the latest version due to errors found in testing
RUN pip install --upgrade pip

# Install OpenStack clients
RUN git clone https://github.com/openstack/python-openstackclient.git; \
cd python-openstackclient; \
if [[ "<branch>" != "" ]]; then git checkout <branch>; fi; \
pip install -r requirements.txt; \
pip install .

RUN git clone https://github.com/openstack/python-neutronclient.git; \
cd python-neutronclient; \
if [[ "<branch>" != "" ]]; then git checkout <branch>; fi; \
pip install -r requirements.txt; \
pip install .

RUN git clone https://github.com/openstack/python-novaclient.git; \
cd python-novaclient; \
if [[ "<branch>" != "" ]]; then git checkout <branch>; fi; \
pip install -r requirements.txt; \
pip install .

RUN git clone https://github.com/openstack/python-tackerclient; \
cd python-tackerclient; \
if [[ "<branch>" != "" ]]; then git checkout <branch>; fi; \
python setup.py install

# Setup Tacker
RUN git clone https://github.com/openstack/tacker.git; \
if [[ "<branch>" != "" ]]; then cd tacker; git checkout <branch>; fi; \
cd tacker; \
pip install -r requirements.txt; \
pip install tosca-parser; \
python setup.py install; \
mkdir /var/log/tacker; \
mkdir /var/lib/tacker

COPY tacker.conf /usr/local/etc/tacker/tacker.conf
COPY start.sh start.sh
ENTRYPOINT ["/bin/bash", "start.sh"]
