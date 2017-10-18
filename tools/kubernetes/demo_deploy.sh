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
#. What this is: Complete scripted deployment of an experimental kubernetes-based
#. cloud-native application platform. When complete, kubernetes and the following
#. will be installed:
#. - helm and dokuwiki as a demo helm cart based application
#. - prometheus + grafana for cluster monitoring/stats
#. - cloudify + kubernetes plugin and a demo hello world (nginx) app installed
#.  will be setup with:
#. Prometheus dashboard: http://<admin_public_ip>:9090
#. Grafana dashboard: http://<admin_public_ip>:3000
#.
#. Prerequisites:
#. - Ubuntu server for kubernetes cluster nodes (admin/master and agent nodes)
#. - MAAS server as cluster admin for kubernetes master/agent nodes
#. - Password-less ssh key provided for node setup
#. Usage: on the MAAS server
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ bash ~/models/tools/kubernetes/demo_deploy.sh <key> "<hosts>" <admin ip>
#.     "<agent ips>" <pub-net> <priv-net> [<extras>]
#. <key>: name of private key for cluster node ssh (in current folder)
#. <hosts>: space separated list of hostnames managed by MAAS
#. <admin ip>: IP of cluster admin node
#. <agent_ips>: space separated list of agent node IPs
#. <pub-net>: CID formatted public network
#. <priv-net>: CIDR formatted private network (may be same as pub-net)
#. <extras>: optional name of script for extra setup functions as needed

key=$1
nodes="$2"
admin_ip=$3
agent_ips="$4"
priv_net=$5
pub_net=$6
extras=$7

source ~/models/tools/maas/deploy.sh $1 "$2" $5
eval `ssh-agent`
ssh-add $key
if [[ "x$extras" != "x" ]]; then source $extras; fi
scp -o StrictHostKeyChecking=no $key ubuntu@$admin_ip:/home/ubuntu/$key
echo "Setting up kubernetes..."
scp -o StrictHostKeyChecking=no ~/models/tools/kubernetes/k8s-cluster.sh \
  ubuntu@$admin_ip:/home/ubuntu/.
ssh -x -o StrictHostKeyChecking=no ubuntu@$admin_ip <<EOF
exec ssh-agent bash
ssh-add $key
bash k8s-cluster.sh all "$agent_ips" $priv_net $pub_net
EOF
# TODO: Figure this out... Have to break the setup into two steps as something
# causes the ssh session to end before the prometheus setup, if both scripts
# are in the same ssh session
echo "Setting up Prometheus..."
ssh -x -o StrictHostKeyChecking=no ubuntu@$admin_ip mkdir -p \
  /home/ubuntu/models/tools/prometheus
scp -r -o StrictHostKeyChecking=no ~/models/tools/prometheus/* \
  ubuntu@$admin_ip:/home/ubuntu/models/tools/prometheus
ssh -x -o StrictHostKeyChecking=no ubuntu@$admin_ip <<EOF
exec ssh-agent bash
ssh-add $key
cd models/tools/prometheus
bash prometheus-tools.sh all "$agent_ips"
EOF
echo "Setting up cloudify..."
scp -o StrictHostKeyChecking=no ~/models/tools/cloudify/k8s-cloudify.sh \
  ubuntu@$admin_ip:/home/ubuntu/.
ssh -x -o StrictHostKeyChecking=no ubuntu@$admin_ip bash k8s-cloudify.sh prereqs
ssh -x -o StrictHostKeyChecking=no ubuntu@$admin_ip bash k8s-cloudify.sh setup
ssh -x -o StrictHostKeyChecking=no ubuntu@$admin_ip bash k8s-cloudify.sh demo
echo "All done!"
