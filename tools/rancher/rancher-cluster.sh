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
#. What this is: Functions for testing with rancher.
#. Prerequisites:
#. - Ubuntu server for master and agent nodes
#. Usage:
#. $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#. $ cd ~/models/tools/rancher
#.
#. Usage:
#. $ bash rancher_cluster.sh all "<agents>"
#.   Automate setup and start demo blueprints.
#.   <agents>: space-separated list of agent node IPs
#. $ bash rancher_cluster.sh setup "<agents>"
#.   Installs and starts master and agent nodes.
#. $ bash rancher_cluster.sh master
#.   Setup the Rancher master node.
#. $ bash rancher_cluster.sh agents "<agents>"
#.   Installs and starts agent nodes.
#. $ bash rancher_cluster.sh demo
#.   Start demo blueprints.
#. $ bash rancher_cluster.sh clean "<agents>"
#.   Removes Rancher and installed blueprints from the master and agent nodes.
#.
#. To call the procedures, directly, e.g. public_endpoint nginx/lb
#. $ source rancher-cluster.sh
#. See below for function-specific usage
#.

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo "$f:$l ($(date)) $1"
}

# Install master
function setup_master() {
  docker_installed=$(dpkg-query -W --showformat='${Status}\n' docker-ce | grep -c "install ok")
  if [[ $docker_installed == 0 ]]; then
    log "installing and starting docker"
    # Per https://docs.docker.com/engine/installation/linux/docker-ce/ubuntu/
    sudo apt-get remove -y docker docker-engine docker.io
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

    log "installing jq"
    sudo apt-get install -y jq
  fi

  log "installing rancher server (master)"
  sudo docker run -d --restart=unless-stopped -p 8080:8080 --name rancher rancher/server

  log "wait until server is up at http://$1:8080"
  delay=0
  id=$(wget -qO- http://$1:8080/v2-beta/projects/ | jq -r '.data[0].id')
  while [[ "$id" == "" ]]; do
    log "rancher server is not yet up, checking again in 10 seconds"
    sleep 10
    let delay=$delay+10
    id=$(wget -qO- http://$1:8080/v2-beta/projects/ | jq -r '.data[0].id')
  done
  log "rancher server is up after $delay seconds"

  rm -rf ~/rancher
  mkdir ~/rancher
}

# Install rancher CLI tools
# Usage example: install_cli_tools 172.16.0.2
function install_cli_tools() {
  log "installing rancher CLI tools for master $1"
  cd ~
  log "install Rancher CLI"
  rm -rf rancher-v0.6.3
  wget -q https://releases.rancher.com/cli/v0.6.3/rancher-linux-amd64-v0.6.3.tar.gz
  gzip -d -f rancher-linux-amd64-v0.6.3.tar.gz
  tar -xvf rancher-linux-amd64-v0.6.3.tar
  sudo mv rancher-v0.6.3/rancher /usr/bin/rancher
  log "install Rancher Compose"
  rm -rf rancher-compose-v0.12.5
  wget -q https://releases.rancher.com/compose/v0.12.5/rancher-compose-linux-amd64-v0.12.5.tar.gz
  gzip -d -f rancher-compose-linux-amd64-v0.12.5.tar.gz
  tar -xvf rancher-compose-linux-amd64-v0.12.5.tar
  sudo mv rancher-compose-v0.12.5/rancher-compose /usr/bin/rancher-compose
  log "setup Rancher CLI environment"
  # CLI setup http://rancher.com/docs/rancher/v1.6/en/cli/
  # Under the UI "API" select "Add account API key" and name it. Export the keys:
  # The following scripted approach assumes you have 1 project/environment (Default)
  # Set the url that Rancher is on
  export RANCHER_URL=http://$1:8080/v1
  id=$(wget -qO- http://$1:8080/v2-beta/projects/ | jq -r '.data[0].id')
  export RANCHER_ENVIRONMENT=$id
  curl -s -o /tmp/keys -X POST -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{"accountId":"reference[account]", "description":"string", "name":"string", "publicValue":"string", "secretValue":"password"}' http://$1:8080/v2-beta/projects/$id/apikeys
#  curl -s -o /tmp/keys -X POST -H 'Accept: application/json' -H 'Content-Type: application/json' -d {"type":"apikey","accountId":"1a1","name":"admin","description":null,"created":null,"kind":null,"removed":null,"uuid":null} http://$1:8080/v2-beta/projects/$id/apikey
  export RANCHER_ACCESS_KEY=$(jq -r '.publicValue' /tmp/keys)
  export RANCHER_SECRET_KEY=$(jq -r '.secretValue' /tmp/keys)
  # create the env file ~/.rancher/cli.json
  rancher config <<EOF
$RANCHER_URL
$RANCHER_ACCESS_KEY
$RANCHER_SECRET_KEY
EOF

  master=$(rancher config --print | jq -r '.url' | cut -d '/' -f 3)
  log "Create registration token"
  # added sleep to allow server time to be ready to create registration tokens (otherwise error is returned)
  sleep 5
  curl -s -o /tmp/token -X POST -u "${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{"name":"master"}' http://$master/v1/registrationtokens
  while [[ $(jq -r ".type" /tmp/token) != "registrationToken" ]]; do
    sleep 5
    curl -s -o /tmp/token -X POST -u "${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{"name":"master"}' http://$master/v1/registrationtokens
  done
  id=$(jq -r ".id" /tmp/token)
  log "registration token id=$id"

  log "wait until registration command is created"
  command=$(curl -s -u "${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" -H 'Accept: application/json' http://$master/v1/registrationtokens/$id | jq -r '.command')
  while [[ "$command" == "null" ]]; do
    log "registration command is not yet created, checking again in 10 seconds"
    sleep 10
    command=$(curl -s -u "${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" -H 'Accept: application/json' http://$master/v1/registrationtokens/$id | jq -r '.command')
  done

  export RANCHER_REGISTER_COMMAND="$command"

#  log "activate rancher debug"
#  export RANCHER_CLIENT_DEBUG=true

  log "Install docker-compose for syntax checks"
  sudo apt install -y docker-compose

  cd ~/rancher
}

# Start an agent host
# Usage example: start_host Default 172.16.0.7
function setup_agent() {
  log "SSH to host $2 in env $1 and execute registration command"

  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$2 "sudo apt-get install -y docker.io; sudo service docker start"
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$2 $RANCHER_REGISTER_COMMAND

  log "wait until agent $2 is active"
  delay=0
  id=$(rancher hosts | awk "/$2/{print \$1}")
  while [[ "$id" == "" ]]; do
    log "agent $2 is not yet created, checking again in 10 seconds"
    sleep 10
    let delay=$delay+10
    id=$(rancher hosts | awk "/$2/{print \$1}")
  done

  log "agent $2 id=$id"
  state=$(rancher inspect $id | jq -r '.state')
  while [[ "$state" != "active" ]]; do
    log "host $2 state is $state, checking again in 10 seconds"
    sleep 10
    let delay=$delay+10
    state=$(rancher inspect $id | jq -r '.state')
  done
  log "agent $2 state is $state after $delay seconds"
}

# Delete an agent host
# Usage example: delete_host 172.16.0.7
function stop_agent() {
  log "deleting host $1"
  rancher rm --stop $(rancher hosts | awk "/$1/{print \$1}")
}

# Test service at access points
# Usage example: check_service nginx/nginx http "Welcome to nginx!"
function check_service() {
  log "checking service state for $1 over $2 with match string $3"
  service=$1
  scheme=$2
  match="$3"
  id=$(rancher ps | grep " $service " | awk "{print \$1}")
  n=0
  while [[ "$(rancher inspect $id | jq -r ".publicEndpoints[$n].ipAddress")" != "null" ]]; do
    ip=$(rancher inspect $id | jq -r ".publicEndpoints[$n].ipAddress")
    port=$(rancher inspect $id | jq -r ".publicEndpoints[$n].port")
    while [[ $(wget -qO- $scheme://$ip:$port | grep -c "$match") == 0 ]]; do
      echo "$service service is NOT active at address $scheme://$ip:$port, waiting 10 seconds"
      sleep 10
    done
    echo "$service service is active at address $scheme://$ip:$port"
    let n=$n+1
  done
}

# Wait n 10-second tries for service to be active
# Usage example: wait_till_healthy nginx/nginx 6
function wait_till_healthy() {
  service=$1
  tries=$2

  let delay=$tries*10
  log "waiting for service $service to be ready in $delay seconds"
  id=$(rancher ps | grep " $service " | awk "{print \$1}")
  health=$(rancher inspect $id | jq -r ".healthState")
  state=$(rancher inspect $id | jq -r ".state")
  while [[ $tries > 0 && "$health" != "healthy" ]]; do
    health=$(rancher inspect $id | jq -r ".healthState")
    echo $service is $health
    sleep 10
  done
  echo $service state is $(rancher inspect $id | jq -r ".state")
}

# Start service based upon docker image and simple templates
# Usage example: start_simple_service nginx nginx:latest 8081:80 3
# Usage example: start_simple_service dokuwiki ununseptium/dokuwiki-docker 8082:80 2
function start_simple_service() {
  log "starting service $1 with image $2, ports $3, and scale $4"
  service=$1
  image=$2
  # port is either a single (unexposed) port, or an source:target pair (source
  # is the external port)
  ports=$3
  scale=$4

  log "creating service folder ~/rancher/$service"
  mkdir ~/rancher/$service
  cd  ~/rancher/$service
  log "creating docker-compose.yml"
  # Define service via docker-compose.yml
  cat <<EOF >docker-compose.yml
version: '2'
services:
  $service:
    image: $image
    ports:
      - "$ports"
EOF

  log "syntax checking docker-compose.yml"
  docker-compose -f docker-compose.yml config

  log "creating rancher-compose.yml"
  cat <<EOF >rancher-compose.yml
version: '2'
services:
  # Reference the service that you want to extend
  $service:
    scale: $scale
EOF

  log "starting service $service"
  rancher up -s $service -d

  wait_till_healthy "$service/$service" 6
  cd  ~/rancher
}

# Add load balancer to a service
# Usage example: lb_service nginx 8000 8081
# Usage example: lb_service dokuwiki 8001 8082
function lb_service() {
  log "adding load balancer port $2 to service $1, port $3"
  service=$1
  lbport=$2
  port=$3

  cd  ~/rancher/$service
  log "creating docker-compose-lb.yml"
  # Define lb service via docker-compose.yml
  cat <<EOF >docker-compose-lb.yml
version: '2'
services:
  lb:
    ports:
    - $lbport
    image: rancher/lb-service-haproxy:latest
EOF

  log "syntax checking docker-compose-lb.yml"
  docker-compose -f docker-compose-lb.yml config

  log "creating rancher-compose-lb.yml"
  cat <<EOF >rancher-compose-lb.yml
version: '2'
services:
  lb:
    scale: 1
    lb_config:
      port_rules:
      - source_port: $lbport
        target_port: $port
        service: $service/$service
    health_check:
      port: 42
      interval: 2000
      unhealthy_threshold: 3
      healthy_threshold: 2
      response_timeout: 2000
EOF

  log "starting service lb"
  rancher up -s $service -d --file docker-compose-lb.yml --rancher-file rancher-compose-lb.yml

  wait_till_healthy "$service/lb" 6
  cd  ~/rancher
}

# Change scale of a service
# Usage example: scale_service nginx 1
function scale_service() {
  log "scaling service $1 to $2 instances"
  id=$(rancher ps | grep " $1 " | awk '{print $1}')
  rancher scale $id=$2

  scale=$(rancher inspect $id | jq -r '.currentScale')
  health=$(rancher inspect $id | jq -r '.healthState')
  while [[ $scale != $2 || "$health" != "healthy" ]]; do
    echo $service is scaled at $scale and is $health
    scale=$(rancher inspect $id | jq -r '.currentScale')
    health=$(rancher inspect $id | jq -r '.healthState')
    sleep 10
  done
  echo $service is scaled at $scale and is $health
}

# Get public endpoint for a service
# Usage example public_endpoint nginx/lb
function public_endpoint() {
    id=$(rancher ps | grep " $1 " | awk "{print \$1}")
    ip=$(rancher inspect $id | jq -r ".publicEndpoints[0].ipAddress")
    port=$(rancher inspect $id | jq -r ".publicEndpoints[0].port")
    log "$1 is accessible at http://$ip:$port"
}

# Stop a stack
# Usage example: stop_stack nginx
function stop_stack() {
  log "stopping stack $1"
  rancher stop $(rancher stacks | awk "/$1/{print \$1}")
}

# Start a stopped stack
# Usage example: start_stack nginx
function start_stack() {
  log "starting stack $1"
  rancher start $(rancher stacks | awk "/$1/{print \$1}")
  wait_till_healthy $1 6
}

# Delete a stack
# Usage example: delete_stack dokuwiki
function delete_stack() {
  id=$(rancher stacks | grep "$1" | awk "{print \$1}")
  log "deleting stack $1 with id $id"
  rancher rm --stop $id
}

# Delete a service
# Usage example: delete_service nginx/lb
function delete_service() {
  id=$(rancher ps | grep "$1" | awk "{print \$1}")
  log "deleting service $1 with id $id"
  rancher rm --stop $id
}

# Start a complex service, i.e. with yaml file customizations
# Usage example: start_complex_service grafana 3000:3000 1
function start_complex_service() {
  log "starting service $1 at ports $2, and scale $3"
  service=$1
  # port is either a single (unexposed) port, or an source:target pair (source
  # is the external port)
  ports=$2
  scale=$3

  log "creating service folder ~/rancher/$service"
  mkdir ~/rancher/$service
  cd  ~/rancher/$service
  log "creating docker-compose.yml"
  # Define service via docker-compose.yml
  case "$service" in
    grafana)
      cat <<EOF >docker-compose.yml
grafana:
    image: grafana/grafana:latest
    ports:
        - $ports
    environment:
        GF_SECURITY_ADMIN_USER: "admin"
        GF_SECURITY_ADMIN_PASSWORD: "password"
        GF_SECURITY_SECRET_KEY: $(uuidgen)
EOF
    ;;

    *)
  esac

  log "starting service $service"
  rancher up -s $service -d

  wait_till_healthy "$service/$service" 6
  cd  ~/rancher
}

# Automated demo
# Usage example: rancher_demo start "172.16.0.7 172.16.0.8 172.16.0.9"
# Usage example: rancher_demo clean "172.16.0.7 172.16.0.8 172.16.0.9"
function demo() {
  # Deploy apps
  # Nginx web server, accessible on each machine port 8081, and via load
  # balancer port 8001
  start=`date +%s`
  setup "$1"
  start_simple_service nginx nginx:latest 8081:80 3
  check_service nginx/nginx http "Welcome to nginx!"
  lb_service nginx 8001 80
  check_service nginx/lb http "Welcome to nginx!"
  # Dokuwiki server, accessible on each machine port 8082, and via load
  # balancer port 8002
  start_simple_service dokuwiki ununseptium/dokuwiki-docker 8082:80 2
  check_service dokuwiki/dokuwiki http "This topic does not exist yet"
  lb_service dokuwiki 8002 80
  check_service dokuwiki/lb http "This topic does not exist yet"
  # Grafana server, accessible on one machine at port 3000
  # Grafana is setup via prometheus-toold.sh for now
#  start_complex_service grafana 3000:3000 1
#  id=$(rancher ps | grep " grafana/grafana " | awk "{print \$1}")
#  source ~/models/tools/prometheus/prometheus-tools.sh setup "$agents"
#  grafana_ip=$(rancher inspect $id | jq -r ".publicEndpoints[0].ipAddress")
#  prometheus_ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
#  connect_grafana $prometheus_ip $grafana_ip
  public_endpoint nginx/lb
  public_endpoint dokuwiki/lb
#  public_endpoint grafana/grafana

  end=`date +%s`
  runtime=$((end-start))
  runtime=$((runtime/60))
  log "Demo duration = $runtime minutes"
}

# Automate the installation
function setup() {
  # Installation: http://rancher.com/docs/rancher/v1.6/en/
  # Install rancher server (master) at primary interface of host
  # Account control is disabled (open access to API), and Default env created
  ip=$(ip route get 1 | awk '{print $NF;exit}')
  setup_master $ip
  # Install rancher CLI tools (rancher, rancher-compose), register with master
  # and setup CLI environment (e.g. API access/secret keys)
  install_cli_tools $ip

  # Add agent hosts per http://rancher.com/docs/rancher/v1.6/en/hosts/custom/
  agents="$1"
  for agent in $agents; do
    setup_agent Default $agent
  done
}

# Clean the installation
function clean() {
  delete_service nginx/lb
  delete_stack nginx
  delete_service dokuwiki/lb
  delete_stack dokuwiki
  agents="$1"
  for agent in $agents; do
    stop_agent $agent
  done
  sudo docker stop rancher
  sudo docker rm -v rancher
  sudo apt-get remove -y docker-ce
}

export WORK_DIR=$(pwd)
case "$1" in
  master)
    ip=$(ip route get 1 | awk '{print $NF;exit}')
    setup_master $ip
    ;;
  agents)
    agents="$2"
    for agent in $agents; do
      setup_agent Default $agent
    done
    ;;
  ceph)
    # TODO Ceph support for rancher, e.g. re
    # http://rancher.com/docs/rancher/latest/en/rancher-services/storage-service/
    # https://github.com/rancher/rancher/issues/8722
    # setup_ceph "$2" $3 $4 $5
    ;;
  demo)
    demo "$2"
    ;;
  setup)
    setup "$2"
    ;;
  all)
    setup "$2"
    demo "$2"
    check_service nginx/lb http "Welcome to nginx!"
    check_service dokuwiki/lb http "This topic does not exist yet"
# Grafana is setup via prometheus-toold.sh for now
#    check_service grafana/grafana
    ;;
  clean)
    clean "$2"
    ;;
  *)
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then grep '#. ' $0; fi
esac
