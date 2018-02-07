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
#. What this is: Functions for testing with Prometheus and Grafana. Sets up
#.   Prometheus and Grafana on a master node (e.g. for kubernetes, docker,
#.   rancher, openstack) and agent nodes (where applications run).
#. Prerequisites:
#. - Ubuntu server for master and agent nodes
#. - Docker installed
#. Usage:
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ cd ~/models/tools/prometheus
#. $ bash prometheus-tools.sh setup
#. $ bash prometheus-tools.sh clean
#

# Prometheus links
# https://prometheus.io/download/
# https://prometheus.io/docs/introduction/getting_started/
# https://github.com/prometheus/prometheus
# https://prometheus.io/docs/instrumenting/exporters/
# https://github.com/prometheus/node_exporter
# https://github.com/prometheus/haproxy_exporter
# https://github.com/prometheus/collectd_exporter

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

# Use this to trigger fail() at the right places
# if [ "$RESULT" == "Test Failed!" ]; then fail "message"; fi
function fail() {
  echo "$1"
  exit 1
}

function setup_prometheus() {
  # Prerequisites
  sudo apt install -y golang-go jq
  host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')

  # Install Prometheus server
  # TODO: add     --set server.persistentVolume.storageClass=general
  # TODO: add persistent volume support
  log "Setup prometheus via Helm"
  helm install stable/prometheus --name pm \
    --set alertmanager.enabled=false \
    --set pushgateway.enabled=false \
    --set server.service.nodePort=30990 \
    --set server.service.type=NodePort \
    --set server.persistentVolume.enabled=false

  while ! curl -o ~/tmp/up http://$host_ip:30990/api/v1/query?query=up ; do
    log "Prometheus API is not yet responding... waiting 10 seconds"
    sleep 10
  done

  exp=$(jq '.data.result|length' ~/tmp/up)
  log "$exp exporters are up"
  while [[ $exp -gt 0 ]]; do
    ((exp--))
    eip=$(jq -r ".data.result[$exp].metric.instance" ~/tmp/up)
    job=$(jq -r ".data.result[$exp].metric.job" ~/tmp/up)
    log "$job at $eip"
  done
  log "Prometheus dashboard is available at http://$host_ip:30990"
  echo "Prometheus dashboard is available at http://$host_ip:30990" >>~/tmp/summary
}

function setup_grafana() {
  # TODO: use randomly generated password
  # TODO: add persistent volume support
  log "Setup grafana via Helm"
  #TODSO: add  --set server.persistentVolume.storageClass=general
  helm install --name gf stable/grafana \
    --set server.service.nodePort=30330 \
    --set server.service.type=NodePort \
    --set server.adminPassword=admin \
    --set server.persistentVolume.enabled=false

  log "Setup Grafana datasources and dashboards"
  host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
  prometheus_ip=$host_ip
  grafana_ip=$host_ip

  while ! curl -X POST http://admin:admin@$grafana_ip:30330/api/login/ping ; do
    log "Grafana API is not yet responding... waiting 10 seconds"
    sleep 10
  done

  log "Setup Prometheus datasource for Grafana"
  cat >datasources.json <<EOF
{"name":"Prometheus", "type":"prometheus", "access":"proxy", \
"url":"http://$prometheus_ip:30990/", "basicAuth":false,"isDefault":true, \
"user":"", "password":"" }
EOF
  curl -X POST -o ~/tmp/json -u admin:admin -H "Accept: application/json" \
    -H "Content-type: application/json" \
    -d @datasources.json http://admin:admin@$grafana_ip:30330/api/datasources

  if [[ "$(jq -r '.message' ~/tmp/json)" != "Datasource added" ]]; then
    fail "Datasource creation failed"
  fi
  log "Prometheus datasource for Grafana added"

  log "Import Grafana dashboards"
  # Setup Prometheus dashboards
  # https://grafana.com/dashboards?dataSource=prometheus
  # To add additional dashboards, browse the URL above and import the dashboard via the id displayed for the dashboard
  # Select the home icon (upper left), Dashboards / Import, enter the id, select load, and select the Prometheus datasource

  cd $WORK_DIR/dashboards
  boards=$(ls)
  for board in $boards; do
    curl -X POST -u admin:admin -H "Accept: application/json" -H "Content-type: application/json" -d @${board} http://$grafana_ip:30330/api/dashboards/db
  done
  log "Grafana dashboards are available at http://$host_ip:30330 (login as admin/admin)"
  echo "Grafana dashboards are available at http://$host_ip:30330 (login as admin/admin)" >>~/tmp/summary
  log "Grafana API is available at http://admin:admin@$host_ip:30330/api/v1/query?query=<string>"
  echo "Grafana API is available at http://admin:admin@$host_ip:30330/api/v1/query?query=<string>" >>~/tmp/summary
  log "connect_grafana complete"
}

export WORK_DIR=$(pwd)

case "$1" in
  setup)
    setup_prometheus
    setup_grafana
    ;;
  clean)
    sudo kill $(ps -ef | grep "\./prometheus" | grep prometheus.yml | awk '{print $2}')
    rm -rf ~/prometheus
    sudo docker stop grafana
    sudo docker rm grafana
    for node in $nodes; do
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "sudo kill $(ps -ef | grep ./node_exporter | awk '{print $2}')"
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "rm -rf /home/ubuntu/node_exporter"
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "sudo kill $(ps -ef | grep ./haproxy_exporter | awk '{print $2}')"
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        ubuntu@$node "rm -rf /home/ubuntu/haproxy_exporter"
    done
    ;;
  *)
    grep '#. ' $0
esac
cat ~/tmp/summary
