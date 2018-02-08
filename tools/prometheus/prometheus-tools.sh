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
#. What this is: Functions for testing with Prometheus and Grafana. Sets up
#.   Prometheus and Grafana on a master node (e.g. for kubernetes, docker,
#.   rancher, openstack) and agent nodes (where applications run).
#. Prerequisites:
#. - Ubuntu server for master and agent nodes
#. - Docker installed
#. - For helm-based install, k8s+helm installed
#. Usage:
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ cd ~/models/tools/prometheus
#. $ bash prometheus-tools.sh <setup|clean> prometheus <docker|helm> <"agents">
#.   prometheus: setup/clean prometheus
#.   docker: setup/clean via docker
#.   helm: setup/clean via helm
#.   agents: for docker-based setup, a quoted, space-separated list agent nodes
#.     note: node running this script must have ssh-key enabled access to agents
#. $ bash prometheus-tools.sh <setup|clean> grafana <docker|helm> [URI] [creds]
#.   grafana: setup/clean grafana
#.   docker: setup/clean via docker
#.   helm: setup/clean via helm
#.   URI: optional URI of grafana server to use
#.   creds: optional grafana credentials (default: admin:admin)
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
  log "Setup prometheus"
	log "Setup prerequisites"
  if [[ "$dist" == "ubuntu" ]]; then
    sudo apt-get install -y golang-go jq
  else
    sudo yum install -y golang-go jq
  fi

  if [[ "$how" == "docker" ]]; then
    log "Deploy prometheus node exporter on each agent node"
    for agent in $agents ; do
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        $dist@$agent sudo docker run -d --restart=always -p 9101:9101 \
        -p 9100:9100 --name prometheus-node-exporter prom/node-exporter
    done
    log "Create prometheus config file prometheus.yml"
    cat <<'EOF' >prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    scrape_interval: 5s
    static_configs:
EOF
    for agent in $agents; do
      echo "      - targets: ['${agent}:9100']" >>prometheus.yml
      echo "      - targets: ['${agent}:9101']" >>prometheus.yml
    done
    log "prometheus.yaml:"
    cat prometheus.yml
    log "Start prometheus server"
	  sudo docker run -d --restart=unless-stopped -p 9090:9090 -p 30990:9090 \
      -v /home/$USER/prometheus.yml:/etc/prometheus/prometheus.yml \
      --name prometheus prom/prometheus
  fi
  if [[ "$how" == "helm" ]]; then
    # Install Prometheus server
    # TODO: add     --set server.persistentVolume.storageClass=general
    # TODO: add persistent volume support
    log "Setup prometheus server and agents via Helm"
    helm install stable/prometheus --name pm \
      --set alertmanager.enabled=false \
      --set pushgateway.enabled=false \
      --set server.service.nodePort=30990 \
      --set server.service.type=NodePort \
      --set server.persistentVolume.enabled=false
  fi
  
  host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
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
}

function setup_grafana() {
  host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
  if [[ "$grafana" == "" ]]; then
    if [[ "$how" == "docker" ]]; then
      log "Setup grafana via docker"
      docker run -d --name=grafana -p 30330:3000 grafana/grafana
    fi
    if [[ "$how" == "helm" ]]; then
      # TODO: use randomly generated password
      # TODO: add persistent volume support
      log "Setup grafana via Helm"
      #TODO: add  --set server.persistentVolume.storageClass=general
      helm install --name gf stable/grafana \
        --set server.service.nodePort=30330 \
        --set server.service.type=NodePort \
        --set server.adminPassword=admin \
        --set server.persistentVolume.enabled=false
    fi
    grafana=$host_ip:30330
  fi

  log "Setup Grafana datasources and dashboards"
  prometheus_ip=$host_ip
  if [[ "$creds" == "" ]]; then
    creds="admin:admin"
  fi
  while ! curl -X POST http://$creds@$grafana/api/login/ping ; do
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
    -d @datasources.json http://$creds@$grafana/api/datasources

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
    curl -X POST -u admin:admin \
      -H "Accept: application/json" -H "Content-type: application/json" \
      -d @${board} http://$creds@$grafana/api/dashboards/db
  done
  log "Grafana dashboards are available at http://$host_ip:30330 (login as admin/admin)"
  log "Grafana API is available at http://admin:admin@$host_ip:30330/api/v1/query?query=<string>"
  log "connect_grafana complete"
}

function clean_prometheus() {
  if [[ "$how" == "docker" ]]; then
    log "Clean prometheus via docker"
    sudo docker stop prometheus
    sudo docker rm -v prometheus
    for agent in $agents ; do
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        $dist@$agent sudo docker stop prometheus-node-exporter
      ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        $dist@$agent sudo docker rm -v prometheus-node-exporter
    done
  fi
  if [[ "$how" == "helm" ]]; then
    log "Clean prometheus via Helm"
    helm delete --purge pm
  fi
}

function clean_grafana() {
  if [[ "$grafana" == "" ]]; then
    log "Delete grafana server"
    host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
    grafana=$host_ip:30330
    if [[ "$how" == "docker" ]]; then
      sudo docker stop grafana
      sudo docker rm grafana
    fi
    if [[ "$how" == "helm" ]]; then		
      helm delete gf
    fi
  else
    if [[ "$creds" == "" ]]; then
      creds="admin:admin"
    fi
    log "Delete prometheus datasource at grafana server"
    curl -X DELETE http://$creds@$grafana/api/datasources/name/Prometheus
    log "Delete prometheus dashboards at grafana server"
    boards="docker-dashboard docker-host-and-container-overview node-exporter-server-metrics node-exporter-single-server"
    for board in $boards; do
      curl -X DELETE http://$creds@$grafana/api/dashboards/db/$board
    done
  fi
}

export WORK_DIR=$(pwd)
dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}')

what=$2
how=$3

case "$1" in
  setup)
    if [[ "$what" == "prometheus" ]]; then
      agents="$4"
      setup_prometheus
    fi
	  if [[ "$what" == "grafana" ]]; then
      grafana="$4"
      creds="$5"
      setup_grafana
    fi
    ;;
  clean)
    if [[ "$what" == "prometheus" ]]; then
      agents="$4"
      clean_prometheus
    fi
	  if [[ "$what" == "grafana" ]]; then
      grafana="$4"
      creds="$5"
      clean_grafana
    fi
    ;;
  *)
    grep '#. ' $0
esac