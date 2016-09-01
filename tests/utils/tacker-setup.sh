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
#   $ bash tacker-setup.sh [tacker-cli|tacker-api] [ 1 || 2 ]
#   tacker-cli: use Tacker CLI
#   tacker-api: use Tacker RESTful API
#   1: Initial setup of the docker container
#   2: Setup of Tacker in the docker container

function setenv () {
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

dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$2" in
  "1")
    # STEP 1: Create the Tacker container and launch it
    echo "$0: Copy this script to /tmp/tacker"
    mkdir /tmp/tacker
    cp $0 /tmp/tacker/.
    chmod 755 /tmp/tacker/*.sh

    echo "$0: Setup admin-openrc.sh"
    setenv

    echo "$0: Setup container"
    if [ "$dist" == "Ubuntu" ]; then
      # xenial is needed for python 3.5
      sudo docker pull ubuntu:xenial
      sudo service docker start
      sudo docker run -it -d -v /tmp/tacker/:/tmp/tacker ubuntu:xenial /bin/bash
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
      sudo docker pull ubuntu:xenial
      sudo service docker start
      sudo docker run -i -t -d -v /tmp/tacker/:/tmp/tacker ubuntu:xenial /bin/bash
    fi
    exit 0
    ;;
  "2")
    ;;
  *)
    echo "usage: bash tacker-setup.sh [tacker-cli|tacker-api] [ 1 || 2 ]"
    echo "1: Initial setup of the docker container"
    echo "2: Setup of Tacker in the docker container"
    exit 1
esac

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
  export MYSQL_PASSWORD=$(/usr/bin/apg -n 1 -m 16 -c cl_seed)
  debconf-set-selections <<< 'mysql-server mysql-server/root_password password '$MYSQL_PASSWORD
  debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password '$MYSQL_PASSWORD
  apt-get -q -y install mysql-server python-mysqldb
fi

cd /tmp/tacker

echo "$0: create Tacker database"
mysql --user=root --password=$MYSQL_PASSWORD -e "CREATE DATABASE tacker; GRANT ALL PRIVILEGES ON tacker.* TO 'root@localhost' IDENTIFIED BY '"$MYSQL_PASSWORD"'; GRANT ALL PRIVILEGES ON tacker.* TO 'root'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"';"

echo "$0: Install dependencies - generic"
pip install --upgrade pip virtualenv

echo "$0: Upgrage pip again - needs to be the latest version due to errors found in earlier testing"
pip install --upgrade

echo "$0: install python-openstackclient python-glanceclient"
pip install --upgrade python-openstackclient python-glanceclient python-neutronclient keystonemiddleware

echo "$0: Create virtualenv"
virtualenv /tmp/tacker/venv
source /tmp/tacker/venv/bin/activate

echo "$0: Setup admin-openrc.sh"
source /tmp/tacker/admin-openrc.sh

echo "$0: Setup Tacker user in OpenStack"
openstack user create --password tacker tacker
openstack role add --project services --user tacker admin

echo "$0: Create Tacker service in OpenStack"
openstack service create --name tacker --description "Tacker Project" nfv-orchestration
sid=$(openstack service list | awk "/ tacker / { print \$2 }")

echo "$0: Create Tacker service endpoint in OpenStack"
ip=$(ip addr | awk "/ global eth0/ { print \$2 }" | sed -- 's/\/16//')
openstack endpoint create --region RegionOne \
    --publicurl "http://$ip:9890/" \
    --adminurl "http://$ip:9890/" \
    --internalurl "http://$ip:9890/" $sid

echo "$0: Clone Tacker"
if [[ -d /tmp/tacker/tacker ]]; then rm -rf /tmp/tacker/tacker; fi
git clone git://git.openstack.org/openstack/tacker
cd tacker
git checkout stable/mitaka

echo "$0: Install Tacker"
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
sed -i -- 's/password = service-password/password=tacker/' /usr/local/etc/tacker/tacker.conf
sed -i -- "s~auth_url = http://<KEYSTONE_IP>:35357~auth_url = http://$KEYSTONE_HOST:35357~" /usr/local/etc/tacker/tacker.conf
sed -i -- "s~identity_uri = http://127.0.0.1:5000~# identity_uri = http://127.0.0.1:5000~" /usr/local/etc/tacker/tacker.conf
sed -i -- "s~auth_uri = http://<KEYSTONE_IP>:5000~auth_uri = http://$KEYSTONE_HOST:5000~" /usr/local/etc/tacker/tacker.conf
# Not sure what the effect of the next line is, given that we are running as root
#sed -i -- "s~# root_helper = sudo~root_helper = sudo /usr/local/bin/tacker-rootwrap /usr/local/etc/tacker/rootwrap.conf~" /usr/local/etc/tacker/tacker.conf
sed -i -- "s~# connection = mysql://root:pass@127.0.0.1:3306/tacker~connection = mysql://root:$MYSQL_PASSWORD@$ip:3306/tacker?charset=utf8~" /usr/local/etc/tacker/tacker.conf
sed -i -- ":a;N;$!ba;s~password = service-password\nusername = nova\nauth_url = http://127.0.0.1:35357~password = $OS_PASSWORD\nauth_url = http://$NOVA_HOST:35357~g" /usr/local/etc/tacker/tacker.conf
sed -i -- "s~heat_uri = http://localhost:8004/v1~heat_uri = http://$HEAT_HOST:8004/v1~" /usr/local/etc/tacker/tacker.conf
sed -i -- "s~# api_paste_config = api-paste.ini~api_paste_config = /tmp/tacker/tacker/etc/tacker/api-paste.ini~" /usr/local/etc/tacker/tacker.conf

echo "$0: Populate Tacker database"
/tmp/tacker/venv/bin/tacker-db-manage --config-file /etc/tacker/tacker.conf upgrade head

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
python /tmp/tacker/venv/bin/tacker-server --config-file /usr/local/etc/tacker/tacker.conf --log-file /var/log/tacker/tacker.log

# Registering default VIM: deferrred
