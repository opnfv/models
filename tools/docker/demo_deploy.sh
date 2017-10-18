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
#. What this is: Complete scripted deployment of an experimental Docker-based
#. cloud-native application platform. When complete, Docker-CE and the following
#. will be installed:
#. - nginx as demo application
#. - prometheus + grafana for cluster monitoring/stats
#.   Prometheus dashboard: http://<master_public_ip>:9090
#.   Grafana dashboard: http://<master_public_ip>:3000
#.
#. Prerequisites:
#. - Ubuntu server for cluster nodes (master and worker nodes)
#. - MAAS server as cluster admin for Rancher master/worker nodes
#. - Password-less ssh key provided for node setup
#. Usage: on the MAAS server
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ bash ~/models/tools/docker/demo_deploy.sh <key> "<hosts>" <master>
#.     "<workers>" [<extras>]
#. <key>: name of private key for cluster node ssh (in current folder)
#. <hosts>: space separated list of hostnames managed by MAAS
#. <master>: IP of master node
#. <workers>: space separated list of worker node IPs
#. <extras>: optional name of script for extra setup functions as needed

key=$1
nodes="$2"
master=$3
workers="$4"
extras=$5

source ~/models/tools/maas/deploy.sh $1 "$2" $5
eval `ssh-agent`
ssh-add $key
echo "Setting up Docker..."
bash ~/models/tools/docker/docker-cluster.sh all $master "$workers"
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

echo "All done!"
echo "Demo app nginx is at http://$master:8080/ and on worker nodes port 8080"
apiversion=$(curl http://$master:4243/version | jq -r '.ApiVersion')
echo "Docker engine API is available at http://$master:4243"
echo "API docs are at https://docs.docker.com/engine/api/v$apiversion/"
echo "Prometheus UI is available at http://$master:9090"
echo "Grafana dashboards are available at http://$master:3000 (login as admin/admin)"
echo "Grafana API is available at http://admin:admin@$master:3000/api/v1/query?query=<string>"
