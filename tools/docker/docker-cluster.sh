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
#. What this is: Deployment script for a mult-node docker-ce cluster.
#. Prerequisites:
#. - Ubuntu server for master and worker nodes
#. Usage:
#. $ git clone https://gerrit.opnfv.org/gerrit/models  ~/models
#. $ cd ~/models/tools/docker
#.
#. Usage:
#. $ bash docker_cluster.sh all <master> "<workers>"
#.   Automate setup and start demo services.
#.   <master>: master node IPs
#.   <workers>: space-separated list of worker node IPs
#. $ bash docker_cluster.sh setup <master> "<workers>"
#.   Installs and starts master and worker nodes.
#. $ bash docker_cluster.sh create <service>
#.   <service>: Demo service name to start.
#.     Currently supported: nginx
#. $ bash docker_cluster.sh delete <service>
#.   <service>: Service name to delete.
#. $ bash docker_cluster.sh clean [<node>]
#.   <node>: optional IP address of node to clean.
#.   By default, cleans the entire cluster.
#.

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

# Setup master and worker hosts
function setup() {
  # Per https://docs.docker.com/engine/swarm/swarm-tutorial/
  cat >/tmp/env.sh <<EOF
master=$1
workers="$2"
EOF
  source ~/tmp/env.sh
  cat >/tmp/prereqs.sh <<'EOF'
#!/bin/bash
# Per https://docs.docker.com/engine/installation/linux/docker-ce/ubuntu/
sudo apt-get remove -y docker docker-engine docker.io docker-ce
sudo apt-get update
sudo apt-get install -y \
  linux-image-extra-$(uname -r) \
  linux-image-extra-virtual
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"
sudo apt-get update
sudo apt-get install -y docker-ce
EOF

  # jq is used for parsing API reponses
  sudo apt-get install -y jq
  scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ~/tmp/prereqs.sh ubuntu@$master:/home/ubuntu/prereqs.sh
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$master bash /home/ubuntu/prereqs.sh
  # activate docker API
  # Per https://www.ivankrizsan.se/2016/05/18/enabling-docker-remote-api-on-ubuntu-16-04/
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$master <<EOF
sudo sed -i -- 's~fd://~fd:// -H tcp://0.0.0.0:4243~' /lib/systemd/system/docker.service
sudo systemctl daemon-reload
sudo service docker restart
# Activate swarm mode
# Per https://docs.docker.com/engine/swarm/swarm-tutorial/create-swarm/
sudo docker swarm init --advertise-addr $master
EOF

  if ! curl http://$master:4243/version ; then
    log "docker API failed to initialize"
    exit 1
  fi

  # Per https://docs.docker.com/engine/swarm/swarm-tutorial/add-nodes/
  token=$(ssh -o StrictHostKeyChecking=no -x ubuntu@$master sudo docker swarm join-token worker | grep docker)
  for worker in $workers; do
    log "setting up worker at $worker"
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ~/tmp/prereqs.sh ubuntu@$worker:/home/ubuntu/.
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$worker bash /home/ubuntu/prereqs.sh
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$worker sudo $token
  done

  log "testing service creation"
  reps=1; for a in $workers; do ((reps++)); done
  create_service nginx $reps
}


function create_service() {
  log "creating service $1 with $2 replicas"
  # sudo docker service create -p 80:80 --replicas $reps --name nginx nginx
  # per https://docs.docker.com/engine/api/v1.27/
  source ~/tmp/env.sh
  case "$1" in
    nginx)
      match="Welcome to nginx!"
      ;;
    *)
      log "service $1 not setup for use with this script"
  esac

  if ! curl -X POST http://$master:4243/services/create -d @$1.json ; then
    log "service creation failed"
    exit 1
  fi

  check_service $1 $match
}

function check_service() {
  log "checking service state for $1 with match string $2"
  source ~/tmp/env.sh
  service=$1
  match="$2"
  services=$(curl http://$master:4243/services)
  n=$(echo $services | jq '. | length')
  ((n--))
  while [[ $n -ge 0 ]]; do
    if [[ $(echo $services | jq -r ".[$n].Spec.Name") == $service ]]; then
      id=$(echo $services | jq -r ".[$n].ID")
      port=$(echo $services | jq -r ".[$n].Endpoint.Ports[0].PublishedPort")
      nodes="$master $workers"
      for node in $nodes; do
        not=""
        while ! curl -s -o ~/tmp/resp http://$node:$port ; do
          log "service is not yet active, waiting 10 seconds"
          sleep 10
        done
        curl -s -o ~/tmp/resp http://$node:$port
        if [[ $(grep -c "$match" ~/tmp/resp) == 0 ]]; then
          not="NOT"
        fi
        echo "$service service is $not active at address http://$node:$port"
      done
      break
    fi
    ((n--))
  done
}

function delete_service() {
  log "deleting service $1"
  source ~/tmp/env.sh
  service=$1
  services=$(curl http://$master:4243/services)
  n=$(echo $services | jq '. | length')
  ((n--))
  while [[ $n -ge 0 ]]; do
    if [[ $(echo $services | jq -r ".[$n].Spec.Name") == $service ]]; then
      id=$(echo $services | jq -r ".[$n].ID")
      if ! curl -X DELETE http://$master:4243/services/$id ; then
        log "failed to delete service $1"
      else
        log "deleted service $1"
      fi
      break
    fi
    ((n--))
  done
}

# Clean the installation
function clean() {
  source ~/tmp/env.sh
  nodes="$master $workers"
  for node in $nodes; do
    ssh -o StrictHostKeyChecking=no -x ubuntu@$node <<EOF
sudo docker swarm leave --force
sudo systemctl stop docker
sudo apt-get remove -y docker-ce
EOF
  done
}

export WORK_DIR=$(pwd)
case "$1" in
  setup)
    setup $2 "$3"
    ;;
  ceph)
    # TODO Ceph support for docker, e.g. re
    # http://docker.com/docs/docker/latest/en/docker-services/storage-service/
    # https://github.com/docker/docker/issues/8722
    # setup_ceph "$2" $3 $4 $5
    ;;
  all)
    start=`date +%s`
    setup $2 "$3"
    end=`date +%s`
    runtime=$((end-start))
    runtime=$((runtime/60))
    log "Demo duration = $runtime minutes"
    ;;
  create)
    create_service "$2" $3
    ;;
  delete)
    delete_service "$2"
    ;;
  clean)
    clean $2
    ;;
  *)
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then grep '#. ' $0; fi
esac
