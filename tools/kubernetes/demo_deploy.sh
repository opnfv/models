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
#. - helm and dokuwiki as a demo helm chart based application
#. - prometheus + grafana for cluster monitoring/stats
#. - cloudify + kubernetes plugin and a demo hello world (nginx) app installed
#. - OPNFV VES as an ONAP-compatible monitoring platform
#.
#. Prerequisites:
#. - Ubuntu server for kubernetes cluster nodes (master and worker nodes)
#. - MAAS server as cluster admin for kubernetes master/worker nodes
#. - Password-less ssh key provided for node setup
#. Usage: on the MAAS server
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ bash ~/models/tools/kubernetes/demo_deploy.sh <key> "<hosts>" <master>
#.     "<workers>" <pub-net> <priv-net> <ceph-mode> <ceph-dev> [<extras>]
#. <key>: name of private key for cluster node ssh (in current folder)
#. <hosts>: space separated list of hostnames managed by MAAS
#. <master>: IP of cluster master node
#. <workers>: space separated list of worker node IPs
#. <pub-net>: CID formatted public network
#. <priv-net>: CIDR formatted private network (may be same as pub-net)
#. <ceph-mode>: "helm" or "baremetal"
#. <ceph-dev>: disk (e.g. sda, sdb) or folder (e.g. "/ceph")
#. <extras>: optional name of script for extra setup functions as needed

function run_master() {
  start=$((`date +%s`/60))
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@$k8s_master <<EOF
exec ssh-agent bash
ssh-add $k8s_key
$1
EOF
  end=$((`date +%s`/60))
  runtime=$((end-start))
  log "step \"$1\" duration = $runtime minutes"
}

extras=$9

cat <<EOF >~/k8s_env.sh
k8s_key=$1
k8s_nodes="$2"
k8s_master=$3
k8s_workers="$4"
k8s_priv_net=$5
k8s_pub_net=$6
k8s_ceph_mode=$7
k8s_ceph_dev=$8
export k8s_key
export k8s_nodes
export k8s_master
export k8s_workers
export k8s_priv_net
export k8s_pub_net
export k8s_ceph_mode
export k8s_ceph_dev
EOF
source ~/k8s_env.sh
env | grep k8s_

source ~/models/tools/maas/deploy.sh $k8s_key "$k8s_nodes" $extras
eval `ssh-agent`
ssh-add $k8s_key
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $k8s_key \
  ubuntu@$k8s_master:/home/ubuntu/$k8s_key
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ~/k8s_env.sh \
  ubuntu@$k8s_master:/home/ubuntu/.

echo; echo "$0 $(date): Setting up kubernetes master..."
scp -r -o UserKnownHostsFile=/dev/null  -o StrictHostKeyChecking=no \
  ~/models/tools/kubernetes/* ubuntu@$k8s_master:/home/ubuntu/.
run_master "bash k8s-cluster.sh master"

echo; echo "$0 $(date): Setting up kubernetes workers..."
run_master "bash k8s-cluster.sh workers \"$k8s_workers\""

echo; echo "$0 $(date): Setting up helm..."
run_master "bash k8s-cluster.sh helm"

echo; echo "$0 $(date): Verifying kubernetes+helm install..."
run_master "bash k8s-cluster.sh demo start nginx"
run_master "bash k8s-cluster.sh demo stop nginx"

echo; echo "$0 $(date): Setting up ceph-helm"
run_master "bash k8s-cluster.sh ceph \"$k8s_workers\" $k8s_priv_net $k8s_pub_net $k8s_ceph_mode $k8s_ceph_dev"

echo; echo "$0 $(date): Verifying kubernetes+helm+ceph install..."
run_master "bash k8s-cluster.sh demo start dokuwiki"

echo; echo "Setting up Prometheus..."
scp -r -o StrictHostKeyChecking=no ~/models/tools/prometheus/* \
  ubuntu@$k8s_master:/home/ubuntu/.
run_master "bash prometheus-tools.sh all \"$k8s_workers\""

echo; echo "$0 $(date): Setting up cloudify..."
scp -r -o StrictHostKeyChecking=no ~/models/tools/cloudify \
  ubuntu@$k8s_master:/home/ubuntu/.
run_master "bash cloudify/k8s-cloudify.sh prereqs"
run_master "bash cloudify/k8s-cloudify.sh setup"

echo; echo "$0 $(date): Verifying kubernetes+helm+ceph+cloudify install..."
bash ~/models/tools/cloudify/k8s-cloudify.sh demo start

echo; echo "$0 $(date): Setting up VES"
# not re-cloned if existing - allows patch testing locally
if [[ ! -d ~/ves ]]; then
  git clone https://gerrit.opnfv.org/gerrit/ves ~/ves
fi
ves_influxdb_host=$k8s_master:8086
export ves_influxdb_host
ves_grafana_host=$k8s_master:3000
export ves_grafana_host
ves_grafana_auth=admin:admin
export ves_grafana_auth
ves_kafka_hostname=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$k8s_master hostname)
export ves_kafka_hostname
bash ~/ves/tools/demo_deploy.sh $k8s_key $k8s_master "$k8s_workers" cloudify

echo; echo "$0 $(date): All done!"
export NODE_PORT=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$k8s_master kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services dw-dokuwiki)
export NODE_IP=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$k8s_master  kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}")
echo "Helm chart demo app dokuwiki is available at http://$NODE_IP:$NODE_PORT/"
# TODO update Cloudify demo app to have public exposed service address
port=$( bash ~/models/tools/cloudify/k8s-cloudify.sh port nginx $k8s_master)
echo "Cloudify-deployed demo app nginx is available at http://$k8s_master:$port"
echo "Prometheus UI is available at http://$k8s_master:9090"
echo "Grafana dashboards are available at http://$ves_grafana_host (login as $ves_grafana_auth)"
echo "Grafana API is available at http://$ves_grafana_auth@$ves_influx_host/api/v1/query?query=<string>"
echo "Kubernetes API is available at https://$k8s_master:6443/api/v1/"
echo "Cloudify API access example: curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/status"
