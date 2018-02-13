#!/bin/bash
# Copyright 2017-2018 AT&T Intellectual Property, Inc
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
#. - MAAS server as cluster admin for k8s master/worker nodes.
#. - Password-less ssh key provided for node setup
#. - hostname of kubernetes master setup in DNS or /etc/hosts
#. Usage: on the MAAS server
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ bash ~/models/tools/kubernetes/demo_deploy.sh "<hosts>" <os> <key>
#.   <master> "<workers>" <pub-net> <priv-net> <ceph-mode> "<ceph-dev>" [<extras>]
#. <hosts>: space separated list of hostnames managed by MAAS
#. <os>: OS to deploy, one of "ubuntu" (Xenial) or "centos" (Centos 7)
#. <key>: name of private key for cluster node ssh (in current folder)
#. <master>: IP of cluster master node
#. <workers>: space separated list of worker node IPs; OR for a single-node
#.            (all-in-one) cluster, provide the master IP as the single worker.
#. <pub-net>: CID formatted public network
#. <priv-net>: CIDR formatted private network (may be same as pub-net)
#. <ceph-mode>: "helm" or "baremetal"
#. <ceph-dev>: space-separated list of disks (e.g. sda, sdb) to use on each
#.             worker, or folder (e.g. "/ceph")
#. <extras>: optional name of script for extra setup functions as needed
#.
#. See tools/demo_deploy.sh in the OPNFV VES repo for additional environment
#. variables (mandatory/optional) for VES

function run() {
  start=$((`date +%s`/60))
  $1
  step_end "$1"
}

function step_end() {
  end=$((`date +%s`/60))
  runtime=$((end-start))
  log "step \"$1\" duration = $runtime minutes"
}

function run_master() {
  start=$((`date +%s`/60))
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $k8s_user@$k8s_master <<EOF
exec ssh-agent bash
ssh-add $k8s_key
$1
EOF
  step_end "$1"
}

deploy_start=$((`date +%s`/60))

extras=${10}

if [[ "$4" != "$5" ]]; then
  k8s_master_hostname=$(echo $1 | cut -d ' ' -f 1)
else
  k8s_master_hostname=$1
fi
cat <<EOF >~/k8s_env.sh
k8s_nodes="$1"
k8s_user=$2
k8s_key=$3
k8s_master=$4
k8s_master_hostname=$k8s_master_hostname
k8s_workers="$5"
k8s_priv_net=$6
k8s_pub_net=$7
k8s_ceph_mode=$8
k8s_ceph_dev="$9"
export k8s_nodes
export k8s_user
export k8s_key
export k8s_master
export k8s_master_hostname
export k8s_workers
export k8s_priv_net
export k8s_pub_net
export k8s_ceph_mode
export k8s_ceph_dev
EOF
source ~/k8s_env.sh
env | grep k8s_

echo; echo "$0 $(date): Deploying base OS for master and worker nodes..."
start=$((`date +%s`/60))
source ~/models/tools/maas/deploy.sh $k8s_user $k8s_key "$k8s_nodes" $extras
step_end "source ~/models/tools/maas/deploy.sh $k8s_user $k8s_key \"$k8s_nodes\" $extras"

eval `ssh-agent`
ssh-add $k8s_key
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $k8s_key \
  $k8s_user@$k8s_master:/home/$k8s_user/$k8s_key
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
  ~/k8s_env_$k8s_master_hostname.sh $k8s_user@$k8s_master:/home/$k8s_user/k8s_env.sh

echo; echo "$0 $(date): Setting up kubernetes master..."
scp -r -o UserKnownHostsFile=/dev/null  -o StrictHostKeyChecking=no \
  ~/models/tools/kubernetes/* $k8s_user@$k8s_master:/home/$k8s_user/.
run_master "bash k8s-cluster.sh master"

if [[ "$k8s_master" != "$k8s_workers" ]]; then
  echo; echo "$0 $(date): Setting up kubernetes workers..."
  run_master "bash k8s-cluster.sh workers \"$k8s_workers\""
else
  echo; echo "Label $k8s_master_hostname for role=worker"
  run_master "kubectl label nodes $k8s_master_hostname role=worker --overwrite"
fi

echo; echo "$0 $(date): Setting up helm..."
run_master "bash k8s-cluster.sh helm"

echo; echo "$0 $(date): Verifying kubernetes+helm install..."
run_master "bash k8s-cluster.sh demo start nginx"
run_master "bash k8s-cluster.sh demo stop nginx"

if [[ "$k8s_master" != "$k8s_workers" ]]; then
  echo; echo "$0 $(date): Setting up ceph-helm"
  run_master "bash k8s-cluster.sh ceph \"$k8s_workers\" $k8s_priv_net $k8s_pub_net $k8s_ceph_mode \"$k8s_ceph_dev\""

  echo; echo "$0 $(date): Verifying kubernetes+helm+ceph install..."
  run_master "bash k8s-cluster.sh demo start dokuwiki"
else
  echo; echo "$0 $(date): Skipping ceph (not yet working for AIO deployment)"
fi

echo; echo "$0 $(date): Setting up cloudify..."
scp -r -o StrictHostKeyChecking=no ~/models/tools/cloudify \
  $k8s_user@$k8s_master:/home/$k8s_user/.
run_master "bash cloudify/k8s-cloudify.sh prereqs"
run_master "bash cloudify/k8s-cloudify.sh setup"

echo; echo "$0 $(date): Verifying kubernetes+helm+ceph+cloudify install..."
run "bash $HOME/models/tools/cloudify/k8s-cloudify.sh demo start"

echo; echo "$0 $(date): Setting up VES..."
# not re-cloned if existing - allows patch testing locally
if [[ ! -d ~/ves ]]; then
  echo; echo "$0 $(date): Cloning VES..."
  git clone https://gerrit.opnfv.org/gerrit/ves ~/ves
fi
# Can't pass quoted strings in commands
start=$((`date +%s`/60))
bash $HOME/ves/tools/demo_deploy.sh $k8s_user $k8s_master cloudify
step_end "bash $HOME/ves/tools/demo_deploy.sh $k8s_user $k8s_master cloudify"

echo; echo "Setting up Prometheus..."
scp -r -o StrictHostKeyChecking=no ~/models/tools/prometheus/* \
  $k8s_user@$k8s_master:/home/$k8s_user/.
run_master "bash prometheus-tools.sh setup prometheus helm"
run_master "bash prometheus-tools.sh setup grafana helm $k8s_master:3000"

echo; echo "Installing clearwater-docker..."
run "bash $HOME/models/tests/k8s-cloudify-clearwater.sh start $k8s_master blsaws latest"

echo; echo "Waiting 5 minutes for clearwater IMS to be fully ready..."
sleep 300

echo; echo "Run clearwater-live-test..."
run "bash $HOME/models/tests/k8s-cloudify-clearwater.sh test $k8s_master"
 
echo; echo "$0 $(date): All done!"
deploy_end=$((`date +%s`/60))
runtime=$((deploy_end-deploy_start))
log "Deploy \"$1\" duration = $runtime minutes"

source ~/ves/tools/ves_env.sh
#echo "Prometheus UI is available at http://$k8s_master:30990"
echo "InfluxDB API is available at http://$ves_influxdb_host:$ves_influxdb_port/query&db=veseventsdb&q=<string>"
echo "Grafana dashboards are available at http://$ves_grafana_host:$ves_grafana_port (login as $ves_grafana_auth)"
echo "Grafana API is available at http://$ves_grafana_auth@$ves_grafana_host:$ves_grafana_port/api/v1/query?query=<string>"
echo "Kubernetes API is available at https://$k8s_master:6443/api/v1/"
echo "Cloudify API access example: curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/status"
port=$(bash ~/models/tools/cloudify/k8s-cloudify.sh nodePort nginx)
echo "Cloudify-deployed demo app nginx is available at http://$k8s_master:$port"
if [[ "$k8s_master" != "$k8s_workers" ]]; then
  export NODE_PORT=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $k8s_user@$k8s_master kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services dw-dokuwiki)
  export NODE_IP=$(ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $k8s_user@$k8s_master kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}")
  echo "Helm chart demo app dokuwiki is available at http://$NODE_IP:$NODE_PORT/"
fi
