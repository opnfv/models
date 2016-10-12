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
# What this is: Setup script for the OpenStack Tacker VNF Manager starting from 
# an Unbuntu Xenial docker container.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ bash tacker-setup.sh [tacker-cli|tacker-api] [init|setup|clean]
#   tacker-cli: use Tacker CLI
#   tacker-api: use Tacker RESTful API
#   init: Initialize docker container
#   setup: Setup of Tacker in the docker container
#   clean: Clean

pass() {
  echo "$0: Hooray!"
  set +x #echo off
  exit 0
}

fail() {
  echo "$0: Failed!"
  set +x
  exit 1
}

function setenv () {
  echo "$0: Setup shared virtual folders and save this script there"
  mkdir /tmp/tacker
  cp $0 /tmp/tacker/.
  chmod 755 /tmp/tacker/*.sh

  echo "$0: Setup admin-openrc.sh"

  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: Ubuntu-based install"
    echo "$0: Create the environment file"
    KEYSTONE_HOST=$(juju status --format=short | awk "/keystone\/0/ { print \$3 }")
    cat <<EOF >/tmp/tacker/admin-openrc.sh
export CONGRESS_HOST=$(juju status --format=short | awk "/openstack-dashboard/ { print \$3 }")
export HORIZON_HOST=$(juju status --format=short | awk "/openstack-dashboard/ { print \$3 }")
export KEYSTONE_HOST=$KEYSTONE_HOST
export CEILOMETER_HOST=$(juju status --format=short | awk "/ceilometer\/0/ { print \$3 }")
export CINDER_HOST=$(juju status --format=short | awk "/cinder\/0/ { print \$3 }")
export GLANCE_HOST=$(juju status --format=short | awk "/glance\/0/ { print \$3 }")
export NEUTRON_HOST=$(juju status --format=short | awk "/neutron-api\/0/ { print \$3 }")
export NOVA_HOST=$(juju status --format=short | awk "/nova-cloud-controller\/0/ { print \$3 }")
export HEAT_HOST=$(juju status --format=short | awk "/heat\/0/ { print \$3 }")
export OS_USERNAME=admin
export OS_PASSWORD=openstack
export OS_TENANT_NAME=admin
export OS_AUTH_URL=http://$KEYSTONE_HOST:5000/v2.0
export OS_REGION_NAME=RegionOne
EOF
 else
    # Centos
    echo "$0: Centos-based install"
    echo "$0: Setup undercloud environment so we can get overcloud Controller server address"
    source ~/stackrc
    echo "$0: Get address of Controller node"
    export CONTROLLER_HOST1=$(openstack server list | awk "/overcloud-controller-0/ { print \$8 }" | sed 's/ctlplane=//g')
    echo "$0: Create the environment file"
    cat <<EOF >/tmp/tacker/admin-openrc.sh
export CONGRESS_HOST=$CONTROLLER_HOST1
export KEYSTONE_HOST=$CONTROLLER_HOST1
export CEILOMETER_HOST=$CONTROLLER_HOST1
export CINDER_HOST=$CONTROLLER_HOST1
export GLANCE_HOST=$CONTROLLER_HOST1
export NEUTRON_HOST=$CONTROLLER_HOST1
export NOVA_HOST=$CONTROLLER_HOST1
export HEAT_HOST=$CONTROLLER_HOST1
EOF
    cat ~/overcloudrc >>/tmp/tacker/admin-openrc.sh
    source ~/overcloudrc
    export OS_REGION_NAME=$(openstack endpoint list | awk "/ nova / { print \$4 }")
    # sed command below is a workaound for a bug - region shows up twice for some reason
    cat <<EOF | sed '$d' >>/tmp/tacker/admin-openrc.sh
export OS_REGION_NAME=$OS_REGION_NAME
EOF
  fi
source /tmp/tacker/admin-openrc.sh
}

function get_external_net () {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${network_ids[@]}; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && ext_net_id=${id}
  done
  if [[ $ext_net_id ]]; then 
    EXTERNAL_NETWORK_NAME=$(openstack network show $ext_net_id | awk "/ name / { print \$4 }")
    EXTERNAL_SUBNET_ID=$(openstack network show $EXTERNAL_NETWORK_NAME | awk "/ subnets / { print \$4 }")
  else
    echo "$0: External network not found"
    exit 1
  fi
}

function create_container () {
  echo "$0: Creating docker container for Tacker installation"
  # STEP 1: Create the Tacker container and launch it
  echo "$0: Setup container"
  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: Ubuntu-based install"
    # xenial is needed for python 3.5
    sudo docker pull ubuntu:xenial
    sudo service docker start
    sudo docker run -it -d -v /tmp/tacker/:/tmp/tacker --name tacker ubuntu:xenial /bin/bash
  else 
    # Centos
    echo "Centos-based install"
    sudo tee /etc/yum.repos.d/docker.repo <<-'EOF'
[dockerrepo]
name=Docker Repository--parents 
baseurl=https://yum.dockerproject.org/repo/main/centos/7/
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg 
EOF
    sudo yum install -y docker-engine
    # xenial is needed for python 3.5
    sudo service docker start
    sudo docker pull ubuntu:xenial
    sudo docker run -i -t -d -v /tmp/tacker/:/tmp/tacker --name tacker ubuntu:xenial /bin/bash
  fi
}

function setup () {
  echo "$0: Installing Tacker"
  # STEP 2: Install Tacker in the container
  # Per http://docs.openstack.org/developer/tacker/install/manual_installation.html
  echo "$0: Install dependencies - OS specific"
  if [ "$dist" == "Ubuntu" ]; then
    apt-get update
    apt-get install -y python
    apt-get install -y python-dev
    apt-get install -y python-pip
    apt-get install -y wget
    apt-get install -y openssh-server
    apt-get install -y git
    apt-get install -y apg
    apt-get install -y libffi-dev
    apt-get install -y libssl-dev
    export MYSQL_PASSWORD=$(/usr/bin/apg -n 1 -m 16 -c cl_seed)
    echo $MYSQL_PASSWORD >~/mysql
    debconf-set-selections <<< 'mysql-server mysql-server/root_password password '$MYSQL_PASSWORD
    debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password '$MYSQL_PASSWORD
    apt-get -q -y install mysql-server python-mysqldb
    service mysql restart 
  fi

  cd /tmp/tacker

  echo "$0: create Tacker database"
  mysql --user=root --password=$MYSQL_PASSWORD -e "CREATE DATABASE tacker; GRANT ALL PRIVILEGES ON tacker.* TO 'root@localhost' IDENTIFIED BY '"$MYSQL_PASSWORD"'; GRANT ALL PRIVILEGES ON tacker.* TO 'root'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"';"

  echo "$0: Upgrage pip again - needs to be the latest version due to errors found in earlier testing"
  pip install --upgrade pip

  echo "$0: install python-openstackclient python-glanceclient"
  pip install --upgrade python-openstackclient python-glanceclient python-neutronclient keystonemiddleware

  echo "$0: Setup admin-openrc.sh"
  source /tmp/tacker/admin-openrc.sh

  echo "$0: Setup Tacker user in OpenStack"
  service_project=$(openstack project list | awk "/service/ { print \$4 }")
  openstack user create --project $service_project --password tacker tacker
  openstack role add --project $service_project --user tacker admin

  echo "$0: Create Tacker service in OpenStack"
  sid=$(openstack service list | awk "/ tacker / { print \$2 }")
  openstack service create --name tacker --description "Tacker Project" nfv-orchestration
  sid=$(openstack service list | awk "/ tacker / { print \$2 }")

  echo "$0: Create Tacker service endpoint in OpenStack"
  ip=$(ip addr | awk "/ global eth0/ { print \$2 }" | sed -- 's/\/16//')
  region=$(openstack endpoint list | awk "/ nova / { print \$4 }")
  openstack endpoint create --region $region \
      --publicurl "http://$ip:9890/" \
      --adminurl "http://$ip:9890/" \
      --internalurl "http://$ip:9890/" $sid

  echo "$0: Clone Tacker"
  if [[ -d /tmp/tacker/tacker ]]; then rm -rf /tmp/tacker/tacker; fi
  git clone git://git.openstack.org/openstack/tacker
  cd tacker
  git checkout stable/mitaka

  echo "$0: Setup Tacker"
  pip install -r requirements.txt
  pip install tosca-parser
  python setup.py install
  mkdir /var/log/tacker

  # Following lines apply to master and not stable/mitaka
  #echo "$0: install tox"
  #pip install tox
  #echo "$0: generate tacker.conf.sample"
  #tox -e config-gen

  echo "$0: Update tacker.conf values"
  mkdir /usr/local/etc/tacker
  cp etc/tacker/tacker.conf /usr/local/etc/tacker/tacker.conf
  sed -i -- 's/# auth_strategy = keystone/auth_strategy = keystone/' /usr/local/etc/tacker/tacker.conf
  sed -i -- 's/# debug = False/debug = True/' /usr/local/etc/tacker/tacker.conf
  sed -i -- 's/# use_syslog = False/use_syslog = False/' /usr/local/etc/tacker/tacker.conf
  sed -i -- 's~# state_path = /var/lib/tacker~state_path = /var/lib/tacker~' /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/project_name = service/project_name = $service_project/g" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/password = service-password/password = tacker/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/username = tacker/username = tacker/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s~auth_url = http://127.0.0.1:35357~auth_url = http://$KEYSTONE_HOST:35357~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s~identity_uri = http://127.0.0.1:5000~# identity_uri = http://127.0.0.1:5000~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s~auth_uri = http://127.0.0.1:5000~auth_uri = http://$KEYSTONE_HOST:5000~" /usr/local/etc/tacker/tacker.conf
  # Not sure what the effect of the next line is, given that we are running as root
  #sed -i -- "s~# root_helper = sudo~root_helper = sudo /usr/local/bin/tacker-rootwrap /usr/local/etc/tacker/rootwrap.conf~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s~# connection = mysql://root:pass@127.0.0.1:3306/tacker~connection = mysql://root:$MYSQL_PASSWORD@localhost:3306/tacker?charset=utf8~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s~heat_uri = http://localhost:8004/v1~heat_uri = http://$HEAT_HOST:8004/v1~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s~# api_paste_config = api-paste.ini~api_paste_config = /tmp/tacker/tacker/etc/tacker/api-paste.ini~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/# bind_host = 0.0.0.0/bind_host = $ip/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/# bind_port = 8888/bind_port = 9890/" /usr/local/etc/tacker/tacker.conf

  echo "$0: Populate Tacker database"
  /usr/local/bin/tacker-db-manage --config-file /usr/local/etc/tacker/tacker.conf upgrade head

  echo "$0: Install Tacker Client"
  cd /tmp/tacker
  if [[ -d /tmp/tacker/python-tackerclient ]]; then rm -rf /tmp/tacker/python-tackerclient; fi
  git clone https://github.com/openstack/python-tackerclient
  cd python-tackerclient
  git checkout stable/mitaka
  python setup.py install

  # deferred until its determined how to get this to Horizon
  #echo "$0: Install Tacker Horizon plugin"
  #cd /tmp/tacker
  #git clone https://github.com/openstack/tacker-horizon
  #cd tacker-horizon
  #python setup.py install
  # The next two commands must affect the Horizon server
  #cp openstack_dashboard_extensions/* /usr/share/openstack-dashboard/openstack_dashboard/enabled/
  #service apache2 restart

  echo "$0: Start the Tacker Server"
  nohup python /usr/local/bin/tacker-server --config-file /usr/local/etc/tacker/tacker.conf --log-file /var/log/tacker/tacker.log & disown

  echo "$0: Wait 30 seconds for Tacker server to come online"
  sleep 30

  echo "$0: Register default VIM"
  cd /tmp/tacker
  cat <<EOF >vim-config.yaml 
auth_url: $OS_AUTH_URL
username: $OS_USERNAME
password: $OS_PASSWORD
project_name: admin
EOF

  tacker vim-register --config-file vim-config.yaml --description OpenStack --name VIM0

  setup_test_environment
}

function setup_test_environment () {
  echo "Create management network"
  if [ $(neutron net-list | awk "/ vnf_mgmt / { print \$2 }") ]; then
    echo "$0: vnf_mgmt network exists"
  else
    neutron net-create vnf_mgmt		
    echo "$0: Create management subnet"
    neutron subnet-create vnf_mgmt 192.168.200.0/24 --name vnf_mgmt --gateway 192.168.200.1 --enable-dhcp --allocation-pool start=192.168.200.2,end=192.168.200.254 --dns-nameserver 8.8.8.8
  fi

  echo "$0: Create router for vnf_mgmt network"
  if [ $(neutron router-list | awk "/ vnf_mgmt / { print \$2 }") ]; then
    echo "$0: vnf_mgmt router exists"
  else
    neutron router-create vnf_mgmt_router
    echo "$0: Create router gateway for vnf_mgmt network"
    get_external_net
    neutron router-gateway-set vnf_mgmt_router $EXTERNAL_NETWORK_NAME
    echo "$0: Add router interface for vnf_mgmt network"
    neutron router-interface-add vnf_mgmt_router subnet=vnf_mgmt
  fi

  echo "Create private network"
  if [ $(neutron net-list | awk "/ vnf_private / { print \$2 }") ]; then
    echo "$0: vnf_private network exists"
  else
    neutron net-create vnf_private		
    echo "$0: Create private subnet"
    neutron subnet-create vnf_private 192.168.201.0/24 --name vnf_private --gateway 192.168.201.1 --enable-dhcp --allocation-pool start=192.168.201.2,end=192.168.201.254 --dns-nameserver 8.8.8.8
  fi

  echo "$0: Create router for vnf_private network"
  if [ $(neutron router-list | awk "/ vnf_private / { print \$2 }") ]; then
    echo "$0: vnf_private router exists"
  else
    neutron router-create vnf_private_router
    echo "$0: Create router gateway for vnf_private network"
    get_external_net
    neutron router-gateway-set vnf_private_router $EXTERNAL_NETWORK_NAME
    echo "$0: Add router interface for vnf_private network"
    neutron router-interface-add vnf_private_router subnet=vnf_private
  fi
}

function clean () {
  source /tmp/tacker/admin-openrc.sh
  openstack endpoint delete $(openstack endpoint list | awk "/tacker/ { print \$2 }")
  openstack user delete $(openstack user list | awk "/tacker/ { print \$2 }")
  openstack service delete $(openstack service list | awk "/tacker/ { print \$2 }")
  pid=($(neutron port-list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${pid[@]}; do neutron port-delete ${id};  done
  sid=($(openstack stack list|grep -v "+"|grep -v id|awk '{print $2}')); for id in ${sid[@]}; do openstack stack delete ${id};  done
  sid=($(openstack security group list|grep security_group_local_security_group|awk '{print $2}')); for id in ${sid[@]}; do openstack security group delete ${id};  done
  neutron router-gateway-clear vnf_mgmt_router
  pid=($(neutron router-port-list vnf_mgmt_router|grep -v name|awk '{print $2}')); for id in ${pid[@]}; do neutron router-interface-delete vnf_mgmt_router vnf_mgmt;  done
  neutron router-delete vnf_mgmt_router
  neutron net-delete vnf_mgmt
  neutron router-gateway-clear vnf_private_router
  pid=($(neutron router-port-list vnf_private_router|grep -v name|awk '{print $2}')); for id in ${pid[@]}; do neutron router-interface-delete vnf_private_router vnf_private;  done
  neutron router-delete vnf_private_router
  neutron net-delete vnf_private
  sudo docker stop $(sudo docker ps -a | awk "/tacker/ { print \$1 }")
  sudo docker rm -v $(sudo docker ps -a | awk "/tacker/ { print \$1 }")
}

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$2" in
  "init")
    setenv
    uid=$(openstack user list | awk "/ tacker / { print \$2 }")
    if [[ $uid ]]; then
      echo "$0: Remove prior Tacker user etc"
      openstack user delete tacker
      openstack service delete tacker
      # Note: deleting the service deletes the endpoint
    fi
    create_container
    pass
    ;;
  "setup")
    setup
    pass
    ;;
  "clean")
    clean
    pass
    ;;
  *)
    echo "usage: bash tacker-setup.sh [tacker-cli|tacker-api] [init|setup|clean]"
    echo "init: Initialize docker container"
    echo "setup: Setup of Tacker in the docker container"
    echo "clean: remove Tacker service"
    fail
esac