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
#. Prometheus dashboard: http://<master_public_ip>:9090
#. Grafana dashboard: http://<master_public_ip>:3000
#.
#. Prerequisites:
#. - Ubuntu server for kubernetes cluster nodes (master and worker nodes)
#. - MAAS server as cluster admin for kubernetes master/worker nodes
#. - Password-less ssh key provided for node setup
#. Usage: on the MAAS server
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ bash ~/models/tools/kubernetes/demo_deploy.sh <key> "<hosts>" <master>
#.     "<workers>" <pub-net> <priv-net> [<extras>]
#. <key>: name of private key for cluster node ssh (in current folder)
#. <hosts>: space separated list of hostnames managed by MAAS
#. <master>: IP of cluster master node
#. <workers>: space separated list of agent node IPs
#. <pub-net>: CID formatted public network
#. <priv-net>: CIDR formatted private network (may be same as pub-net)
#. <extras>: optional name of script for extra setup functions as needed

key=$1
nodes="$2"
master=$3
workers="$4"
priv_net=$5
pub_net=$6
extras=$7

source ~/models/tools/maas/deploy.sh $1 "$2" $5
eval `ssh-agent`
ssh-add $key
if [[ "x$extras" != "x" ]]; then source $extras; fi
scp -o StrictHostKeyChecking=no $key ubuntu@$master:/home/ubuntu/$key
echo "Setting up kubernetes..."
scp -o StrictHostKeyChecking=no ~/models/tools/kubernetes/k8s-cluster.sh \
  ubuntu@$master:/home/ubuntu/.
ssh -x -o StrictHostKeyChecking=no ubuntu@$master <<EOF
exec ssh-agent bash
ssh-add $key
bash k8s-cluster.sh all "$workers" $priv_net $pub_net
EOF
# TODO: Figure this out... Have to break the setup into two steps as something
# causes the ssh session to end before the prometheus setup, if both scripts
# are in the same ssh session
echo "Setting up Prometheus..."
ssh -x -o StrictHostKeyChecking=no ubuntu@$master mkdir -p \
  /home/ubuntu/models/tools/prometheus
scp -r -o StrictHostKeyChecking=no ~/models/tools/prometheus/* \
  ubuntu@$master:/home/ubuntu/models/tools/prometheus
ssh -x -o StrictHostKeyChecking=no ubuntu@$master <<EOF
exec ssh-agent bash
ssh-add $key
cd models/tools/prometheus
bash prometheus-tools.sh all "$workers"
EOF
echo "Setting up cloudify..."
scp -r -o StrictHostKeyChecking=no ~/models/tools/cloudify \
  ubuntu@$master:/home/ubuntu/.
ssh -x -o StrictHostKeyChecking=no ubuntu@$master \
  bash cloudify/k8s-cloudify.sh prereqs
ssh -x -o StrictHostKeyChecking=no ubuntu@$master \
  bash cloudify/k8s-cloudify.sh setup
ssh -x -o StrictHostKeyChecking=no ubuntu@$master \
  bash cloudify/k8s-cloudify.sh demo

echo "All done!"
export NODE_PORT=$(ssh -x -o StrictHostKeyChecking=no ubuntu@$master kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services dw-dokuwiki)
export NODE_IP=$(ssh -x -o StrictHostKeyChecking=no ubuntu@$master  kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}")
echo "Helm chart demo app dokuwiki is available at http://$NODE_IP:$NODE_PORT/"
# TODO update Cloudify demo app to have public exposed service address
echo "Cloudify-deployed demo app nginx is available at TBD"
echo "Prometheus UI is available at http://$master:9090"
echo "Grafana dashboards are available at http://$master:3000 (login as admin/admin)"
echo "Grafana API is available at http://admin:admin@$master:3000/api/v1/query?query=<string>"
