#!/bin/bash
# Copyright 2016 AT&T Intellectual Property, Inc
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
# What this is: Startup script for a 3-node web server composed of two server
# nodes and a load balancer.
#
# Status: this is a work in progress, under test.
#
# How to use:
# Intended to be invoked from vHello_3Node.sh
# $ bash start.sh type params
#   type: type of VNF component [webserver|lb]
#     lb params: app1_ip app2_ip
#   app1_ip app2_ip: address of the web servers

setup_webserver () {
  echo "$0: Setup website and dockerfile"
  mkdir ~/www
  mkdir ~/www/html

  # ref: https://hub.docker.com/_/nginx/
  cat > ~/www/Dockerfile <<EOM
FROM nginx
COPY html /usr/share/nginx/html
EOM

  host=$(hostname)
  cat > ~/www/html/index.html <<EOM
<!DOCTYPE html>
<html>
<head>
<title>Hello World!</title>
<meta name="viewport" content="width=device-width, minimum-scale=1.0, initial-scale=1"/>
<style>
body { width: 100%; background-color: white; color: black; padding: 0px; margin: 0px; font-family: sans-serif; font-size:100%; }
</style>
</head>
<body>
Hello World!<br>
Welcome to OPNFV @ $host!</large><br/>
<a href="http://wiki.opnfv.org"><img src="https://www.opnfv.org/sites/all/themes/opnfv/logo.png"></a>
</body></html>
EOM

  wget https://git.opnfv.org/cgit/ves/plain/tests/blueprints/tosca-vnfd-hello-ves/favicon.ico -O  ~/www/html/favicon.ico

  echo "$0: Install docker"
  # Per https://docs.docker.com/engine/installation/linux/ubuntulinux/
  # Per https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-16-04
  sudo apt-get install apt-transport-https ca-certificates
  sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
  echo "deb https://apt.dockerproject.org/repo ubuntu-xenial main" | sudo tee /etc/apt/sources.list.d/docker.list
  sudo apt-get update
  sudo apt-get purge lxc-docker
  sudo apt-get install -y linux-image-extra-$(uname -r) linux-image-extra-virtual
  sudo apt-get install -y docker-engine

  echo "$0: Get nginx container and start website in docker"
  # Per https://hub.docker.com/_/nginx/
  sudo docker pull nginx
  cd ~/www
  sudo docker build -t vhello .
  sudo docker run --name vHello -d -p 80:80 vhello

  # Debug hints
  # id=$(sudo ls /var/lib/docker/containers)
  # sudo tail -f /var/lib/docker/containers/$id/$id-json.log \
  }

setup_lb () {
  echo "$0: setup load balancer"
  echo "$0: install dependencies"
  sudo apt-get update

  echo "$0: Setup iptables rules"
  echo "1" | sudo tee /proc/sys/net/ipv4/ip_forward
  sudo sysctl net.ipv4.ip_forward=1
  sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -m state --state NEW -m statistic --mode nth --every 2 --packet 0 -j DNAT --to-destination $1:80
  sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -m state --state NEW -m statistic --mode nth --every 2 --packet 0 -j DNAT --to-destination $2:80
  sudo iptables -t nat -A POSTROUTING -j MASQUERADE
  # debug hints: list rules (sudo iptables -S -t nat), flush (sudo iptables -F -t nat)
}

setup_$1 $2 $3
exit 0
