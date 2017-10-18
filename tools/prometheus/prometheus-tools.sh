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
#. $ bash prometheus-tools.sh setup "<list of agent nodes>"
#. <list of agent nodes>: space separated IP of agent nodes
#. $ bash prometheus-tools.sh grafana
#.   Runs grafana in a docker container and connects to prometheus as datasource
#. $ bash prometheus-tools.sh all "<list of agent nodes>"
#.   Does all of the above
#. $ bash prometheus-tools.sh clean "<list of agent nodes>"
#

# Prometheus links
# https://prometheus.io/download/
# https://prometheus.io/docs/introduction/getting_started/
# https://github.com/prometheus/prometheus
# https://prometheus.io/docs/instrumenting/exporters/
# https://github.com/prometheus/node_exporter
# https://github.com/prometheus/haproxy_exporter
# https://github.com/prometheus/collectd_exporter

# Use this to trigger fail() at the right places
# if [ "$RESULT" == "Test Failed!" ]; then fail "message"; fi
function fail() {
  echo "$1"
  exit 1
}

function setup_prometheus() {
  # Prerequisites
  echo "${FUNCNAME[0]}: Setting up prometheus master and agents"
  sudo apt install -y golang-go jq

  # Install Prometheus server
  echo "${FUNCNAME[0]}: Setting up prometheus master"
  if [[ -d ~/prometheus ]]; then rm -rf ~/prometheus; fi
  mkdir ~/prometheus
  cd  ~/prometheus
  wget https://github.com/prometheus/prometheus/releases/download/v2.0.0-beta.2/prometheus-2.0.0-beta.2.linux-amd64.tar.gz
  tar xvfz prometheus-*.tar.gz
  cd prometheus-*
  # Customize prometheus.yml below for your server IPs
  # This example assumes the node_exporter and haproxy_exporter will be installed on each node
  cat <<'EOF' >prometheus.yml
global:
  scrape_interval:     15s # By default, scrape targets every 15 seconds.

  # Attach these labels to any time series or alerts when communicating with
  # external systems (federation, remote storage, Alertmanager).
  external_labels:
    monitor: 'codelab-monitor'

# A scrape configuration containing exactly one endpoint to scrape:
# Here it's Prometheus itself.
scrape_configs:
  # The job name is added as a label `job=<job_name>` to any timeseries scraped from this config.
  - job_name: 'prometheus'

    # Override the global default and scrape targets from this job every 5 seconds.
    scrape_interval: 5s

    static_configs:
EOF

  for node in $nodes; do
    echo "      - targets: ['${node}:9100']" >>prometheus.yml
    echo "      - targets: ['${node}:9101']" >>prometheus.yml
  done

  # Start Prometheus
  nohup ./prometheus --config.file=prometheus.yml > /dev/null 2>&1 &
  # Browse to http://host_ip:9090

  echo "${FUNCNAME[0]}: Installing exporters"
  # Install exporters
  # https://github.com/prometheus/node_exporter
  cd ~/prometheus
  wget https://github.com/prometheus/node_exporter/releases/download/v0.14.0/node_exporter-0.14.0.linux-amd64.tar.gz
  tar xvfz node*.tar.gz
  # https://github.com/prometheus/haproxy_exporter
  wget https://github.com/prometheus/haproxy_exporter/releases/download/v0.7.1/haproxy_exporter-0.7.1.linux-amd64.tar.gz
  tar xvfz haproxy*.tar.gz

  # The scp and ssh actions below assume you have key-based access enabled to the nodes
  for node in $nodes; do
    echo "${FUNCNAME[0]}: Setup agent at $node"
    scp -r -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      node_exporter-0.14.0.linux-amd64/node_exporter ubuntu@$node:/home/ubuntu/node_exporter
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node "nohup ./node_exporter > /dev/null 2>&1 &"
    scp -r -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      haproxy_exporter-0.7.1.linux-amd64/haproxy_exporter ubuntu@$node:/home/ubuntu/haproxy_exporter
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      ubuntu@$node "nohup ./haproxy_exporter > /dev/null 2>&1 &"
  done

  host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
  while ! curl -o /tmp/up http://$host_ip:9090/api/v1/query?query=up ; do
    echo "${FUNCNAME[0]}: Prometheus API is not yet responding... waiting 10 seconds"
    sleep 10
  done

  exp=$(jq '.data.result|length' /tmp/up)
  echo "${FUNCNAME[0]}: $exp exporters are up"
  while [[ $exp > 0 ]]; do
    ((exp--))
    eip=$(jq -r ".data.result[$exp].metric.instance" /tmp/up)
    job=$(jq -r ".data.result[$exp].metric.job" /tmp/up)
    echo "${FUNCNAME[0]}: $job at $eip"
  done
  echo "${FUNCNAME[0]}: Prometheus dashboard is available at http://$host_ip:9090"
  echo "Prometheus dashboard is available at http://$host_ip:9090" >>/tmp/summary
}

function connect_grafana() {
  echo "${FUNCNAME[0]}: Setup Grafana datasources and dashboards"
  prometheus_ip=$1
  grafana_ip=$2

  while ! curl -X POST http://admin:admin@$grafana_ip:3000/api/login/ping ; do
    echo "${FUNCNAME[0]}: Grafana API is not yet responding... waiting 10 seconds"
    sleep 10
  done

  echo "${FUNCNAME[0]}: Setup Prometheus datasource for Grafana"
  cd ~/prometheus/
  cat >datasources.json <<EOF
{"name":"Prometheus", "type":"prometheus", "access":"proxy", \
"url":"http://$prometheus_ip:9090/", "basicAuth":false,"isDefault":true, \
"user":"", "password":"" }
EOF
  curl -X POST -o /tmp/json -u admin:admin -H "Accept: application/json" \
    -H "Content-type: application/json" \
    -d @datasources.json http://admin:admin@$grafana_ip:3000/api/datasources

  if [[ "$(jq -r '.message' /tmp/json)" != "Datasource added" ]]; then
    fail "Datasource creation failed"
  fi
  echo "${FUNCNAME[0]}: Prometheus datasource for Grafana added"

  echo "${FUNCNAME[0]}: Import Grafana dashboards"
  # Setup Prometheus dashboards
  # https://grafana.com/dashboards?dataSource=prometheus
  # To add additional dashboards, browse the URL above and import the dashboard via the id displayed for the dashboard
  # Select the home icon (upper left), Dashboards / Import, enter the id, select load, and select the Prometheus datasource

  cd ~/models/tools/prometheus/dashboards
  boards=$(ls)
  for board in $boards; do
    curl -X POST -u admin:admin -H "Accept: application/json" -H "Content-type: application/json" -d @${board} http://$grafana_ip:3000/api/dashboards/db
  done
  echo "${FUNCNAME[0]}: Grafana dashboards are available at http://$host_ip:3000 (login as admin/admin)"
  echo "Grafana dashboards are available at http://$host_ip:3000 (login as admin/admin)" >>/tmp/summary
  echo "${FUNCNAME[0]}: Grafana API is available at http://admin:admin@$host_ip:3000/api/v1/query?query=<string>"
  echo "Grafana API is available at http://admin:admin@$host_ip:3000/api/v1/query?query=<string>" >>/tmp/summary
}

function run_and_connect_grafana() {
  # Per http://docs.grafana.org/installation/docker/
  host_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
  sudo docker run -d -p 3000:3000 --name grafana grafana/grafana
  status=$(sudo docker inspect grafana | jq -r '.[0].State.Status')
  while [[ "x$status" != "xrunning" ]]; do
    echo "${FUNCNAME[0]}: Grafana container state is ($status)"
    sleep 10
    status=$(sudo docker inspect grafana | jq -r '.[0].State.Status')
  done
  echo "${FUNCNAME[0]}: Grafana container state is $status"

  connect_grafana $host_ip $host_ip
  echo "${FUNCNAME[0]}: connect_grafana complete"
}

nodes=$2
case "$1" in
  setup)
    setup_prometheus "$2"
    ;;
  grafana)
    run_and_connect_grafana
    ;;
  all)
    setup_prometheus "$2"
    run_and_connect_grafana
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
cat /tmp/summary
