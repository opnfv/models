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
#. What this is: Scripted deployment of servers using MAAS. Currently it deploys
#. the default host OS as configured in MAAS.
#.
#. Prerequisites:
#. - MAAS server configured to admin a set of servers
#. - Password-less ssh key provided for node setup
#. Usage: on the MAAS server
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ source ~/models/tools/maas/demo_deploy.sh <key> "<hosts>" [<extras>]
#. <key>: name of private key for cluster node ssh (in current folder)
#. <hosts>: space separated list of hostnames managed by MAAS
#. <extras>: optional name of script for extra setup functions as needed

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

function wait_node_status() {
  status=$(maas opnfv machines read hostname=$1 | jq -r ".[0].status_name")
  while [[ "x$status" != "x$2" ]]; do
    log "$1 status is $status ... waiting for it to be $2"
    sleep 30
    status=$(maas opnfv machines read hostname=$1 | jq -r ".[0].status_name")
  done
  log "$1 status is $status"
}

function release_nodes() {
  nodes=$1
  for node in $nodes; do
    log "Releasing node $node"
    id=$(maas opnfv machines read hostname=$node | jq -r '.[0].system_id')
    maas opnfv machines release machines=$id
  done
}

function deploy_nodes() {
  nodes=$1
  for node in $nodes; do
    log "Deploying node $node"
    id=$(maas opnfv machines read hostname=$node | jq -r '.[0].system_id')
    maas opnfv machines allocate system_id=$id
    maas opnfv machine deploy $id
  done
}

function wait_nodes_status() {
  nodes=$1
  for node in $nodes; do
    wait_node_status $node $2
  done
}

key=$1
nodes="$2"
extras=$3

release_nodes "$nodes"
wait_nodes_status "$nodes" Ready
deploy_nodes "$nodes"
wait_nodes_status "$nodes" Deployed
eval `ssh-agent`
ssh-add $key
if [[ "x$extras" != "x" ]]; then source $extras; fi
