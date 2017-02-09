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
# an Unbuntu Xenial docker container, on either an Ubuntu Xenial or Centos 7 
# host. This script is intended to be used in an OPNFV environment, or a plain
# OpenStack environment (e.g. Devstack).
# This install procedure is intended to deploy Tacker for testing purposes only.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ bash tacker-setup.sh [init|setup|clean] [branch]
#     init: Initialize docker container
#     setup: Setup of Tacker in the docker container
#     clean: Remove the Tacker service, container, and data in /opt/tacker
#     branch: OpenStack branch to install (default: master)

trap 'fail' ERR

pass() {
  echo "$0: $(date) Hooray!"
  end=`date +%s`
  runtime=$((end-start))
  echo "$0: $(date) Duration = $runtime seconds"
  exit 0
}

fail() {
  echo "$0: $(date) Test Failed!"
  end=`date +%s`
  runtime=$((end-start))
  runtime=$((runtime/60))
  echo "$0: $(date) Duration = $runtime seconds"
  exit 1
}

function setenv () {
  echo "$0: $(date) Setup shared virtual folders and save this script there"
  mkdir /opt/tacker
  cp $0 /opt/tacker/.
  cp `dirname $0`/tacker/tacker.conf.sample /opt/tacker/.
  chmod 755 /opt/tacker/*.sh

  echo "$0: $(date) Setup admin-openrc.sh"
  source /opt/tacker/admin-openrc.sh
}

function get_external_net () {
  network_ids=($(neutron net-list|grep -v "+"|grep -v name|awk '{print $2}'))
  for id in ${network_ids[@]}; do
      [[ $(neutron net-show ${id}|grep 'router:external'|grep -i "true") != "" ]] && ext_net_id=${id}
  done
  if [[ $ext_net_id ]]; then 
    EXTERNAL_NETWORK_NAME=$(neutron net-show $ext_net_id | awk "/ name / { print \$4 }")
    EXTERNAL_SUBNET_ID=$(neutron net-show $EXTERNAL_NETWORK_NAME | awk "/ subnets / { print \$4 }")
  else
    echo "$0: $(date) External network not found"
    exit 1
  fi
}

function create_container () {
  echo "$0: $(date) Creating docker container for Tacker installation"
  # STEP 1: Create the Tacker container and launch it
  echo "$0: $(date) Setup container"
  if [ "$dist" == "Ubuntu" ]; then
    echo "$0: $(date) Ubuntu-based install"
    dpkg -l docker-engine
    if [[ $? -eq 1 ]]; then
      sudo apt-get install -y apt-transport-https ca-certificates
      sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
      echo "deb https://apt.dockerproject.org/repo ubuntu-xenial main" | sudo tee /etc/apt/sources.list.d/docker.list
      sudo apt-get update
      sudo apt-get purge lxc-docker
      sudo apt-get install -y linux-image-extra-$(uname -r) linux-image-extra-virtual
      sudo apt-get install -y docker-engine
      sudo service docker start
    fi

    # xenial is needed for python 3.5
    sudo docker pull ubuntu:xenial
    sudo service docker start
    sudo docker run -it -d -v /opt/tacker/:/opt/tacker --name tacker ubuntu:xenial /bin/bash
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
    sudo docker run -i -t -d -v /opt/tacker/:/opt/tacker --name tacker ubuntu:xenial /bin/bash
  fi
}


install_client () {
  echo "$0: $(date) Install $1"
  git clone https://github.com/openstack/$1.git
  cd $1
  if [ $# -eq 2 ]; then git checkout $2; fi
  pip install -r requirements.txt
  pip install .
  cd ..
}

function setup () {
  branch=$1
  echo "$0: $(date) Installing Tacker"
  # STEP 2: Install Tacker in the container
  # Per http://docs.openstack.org/developer/tacker/install/manual_installation.html
  echo "$0: $(date) Install dependencies"
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
  # newton: tacker uses ping for monitoring VIM (not in default docker containers)
  apt-get install -y inetutils-ping
  # apt-utils is not installed in xenial container image
  apt-get install -y apt-utils
  export MYSQL_PASSWORD=$(/usr/bin/apg -n 1 -m 16 -c cl_seed)
  echo $MYSQL_PASSWORD >~/mysql
  debconf-set-selections <<< 'mysql-server mysql-server/root_password password '$MYSQL_PASSWORD
  debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password '$MYSQL_PASSWORD
  apt-get -q -y install mysql-server python-mysqldb
  service mysql restart 

  cd /opt/tacker

  echo "$0: $(date) create Tacker database"
  mysql --user=root --password=$MYSQL_PASSWORD -e "CREATE DATABASE tacker; GRANT ALL PRIVILEGES ON tacker.* TO 'root@localhost' IDENTIFIED BY '"$MYSQL_PASSWORD"'; GRANT ALL PRIVILEGES ON tacker.* TO 'tacker'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"';"

  echo "$0: $(date) Upgrage pip again - needs to be the latest version due to errors found in earlier testing"
  pip install --upgrade pip

  echo "$0: $(date) Install OpenStack clients"
  install_client python-openstackclient $branch
  install_client python-neutronclient $branch

#  pip install --upgrade python-openstackclient python-glanceclient python-neutronclient keystonemiddleware

  echo "$0: $(date) Setup admin-openrc.sh"
  source /opt/tacker/admin-openrc.sh

  uid=$(openstack user list | awk "/ tacker / { print \$2 }")
  if [[ $uid ]]; then
    echo "$0: $(date) Remove prior Tacker user etc"
    openstack user delete tacker
    openstack service delete tacker
    # Note: deleting the service deletes the endpoint
  fi

  echo "$0: $(date) Setup Tacker user in OpenStack"
  service_project=$(openstack project list | awk "/service/ { print \$4 }")
  openstack user create --project $service_project --password tacker tacker
  openstack role add --project $service_project --user tacker admin

  echo "$0: $(date) Create Tacker service in OpenStack"
  sid=$(openstack service list | awk "/ tacker / { print \$2 }")
  openstack service create --name tacker --description "Tacker Project" nfv-orchestration
  sid=$(openstack service list | awk "/ tacker / { print \$2 }")

  echo "$0: $(date) Create Tacker service endpoint in OpenStack"
  ip=$(ip addr | awk "/ global eth0/ { print \$2 }" | sed -- 's/\/16//')
  region=$(openstack endpoint list | awk "/ nova / { print \$4 }" | head -1)
  openstack endpoint create --region $region \
      --publicurl "http://$ip:9890/" \
      --adminurl "http://$ip:9890/" \
      --internalurl "http://$ip:9890/" $sid

  echo "$0: $(date) Clone Tacker"
  if [[ -d /opt/tacker/tacker ]]; then rm -rf /opt/tacker/tacker; fi
  git clone git://git.openstack.org/openstack/tacker
  cd tacker
  git checkout $branch

  echo "$0: $(date) Setup Tacker"
  pip install -r requirements.txt
  pip install tosca-parser
  python setup.py install
  mkdir /var/log/tacker

#  "tox -e config-gen" is throwing errors, disabled - see tacker.conf.sample above
#  echo "$0: $(date) install tox"
#  pip install --upgrade tox
#  echo "$0: $(date) generate tacker.conf.sample"
#  tox -e config-gen

  echo "$0: $(date) Update tacker.conf values"
  mkdir /usr/local/etc/tacker
  cp /opt/tacker/tacker.conf.sample /usr/local/etc/tacker/tacker.conf

  # [DEFAULT] section (update)    
  sed -i -- 's/#auth_strategy = keystone/auth_strategy = keystone/' /usr/local/etc/tacker/tacker.conf
  # [DEFAULT] section (add to)    
  sed -i -- "/\[DEFAULT\]/adebug = True" /usr/local/etc/tacker/tacker.conf
  sed -i -- "/\[DEFAULT\]/ause_syslog = False" /usr/local/etc/tacker/tacker.conf
  sed -i -- "/\[DEFAULT\]/alogging_context_format_string = %(asctime)s.%(msecs)03d %(levelname)s %(name)s [%(request_id)s %(user_name)s %(project_name)s] %(instance)s%(message)s" /usr/local/etc/tacker/tacker.conf
  sed -i -- 's~#policy_file = policy.json~policy_file = /usr/local/etc/tacker/policy.json~' /usr/local/etc/tacker/tacker.conf
  sed -i -- 's~#state_path = /var/lib/tacker~state_path = /var/lib/tacker~' /usr/local/etc/tacker/tacker.conf

  # Not sure what the effect of the next line is, given that we are running as root in the container
  #sed -i -- "s~# root_helper = sudo~root_helper = sudo /usr/local/bin/tacker-rootwrap /usr/local/etc/tacker/rootwrap.conf~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s~#api_paste_config = api-paste.ini~api_paste_config = /opt/tacker/tacker/etc/tacker/api-paste.ini~" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/#bind_host = 0.0.0.0/bind_host = $ip/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/#bind_port = 8888/bind_port = 9890/" /usr/local/etc/tacker/tacker.conf

# Newton changes, based upon sample newton gate test conf file provided by sridhar_ram on #tacker
  sed -i -- "s/#nova_region_name = <None>/#nova_region_name = $region/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/#nova_api_insecure = false/nova_api_insecure = False/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/#nova_ca_certificates_file = <None>/nova_ca_certificates_file =/" /usr/local/etc/tacker/tacker.conf
  keystone_adminurl=$(openstack endpoint show keystone | awk "/ adminurl / { print \$4 }")
  sed -i -- "s~#nova_admin_auth_url = http://localhost:5000/v2.0~nova_admin_auth_url = $keystone_adminurl~" /usr/local/etc/tacker/tacker.conf
  # TODO: don't hard-code service tenant ID
  sed -i -- "s/#nova_admin_tenant_id = <None>/nova_admin_tenant_id = service/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/#nova_admin_password = <None>/nova_admin_password = $OS_PASSWORD/" /usr/local/etc/tacker/tacker.conf
  # this diff seems superfluous < nova_admin_user_name = nova
    #  only one ref in tacker (setting the default value)
    # devstack/lib/tacker:    iniset $TACKER_CONF DEFAULT nova_admin_user_name nova
  # set nova_url to "/v2" (normal value is "/v2.1") due to tacker API version compatibility (?)
  nova_ipport=$(openstack endpoint show nova | awk "/ adminurl / { print \$4 }" | awk -F'[/]' '{print $3}')
  sed -i -- "s~#nova_url = http://127.0.0.1:8774/v2~nova_url = http://$nova_ipport/v2~" /usr/local/etc/tacker/tacker.conf
  mkdir /var/lib/tacker
  sed -i -- "s~#state_path = /var/lib/tacker~state_path = /var/lib/tacker~" /usr/local/etc/tacker/tacker.conf

  # [alarm_auth] section - optional (?)
  # < url = http://15.184.66.78:35357/v3
  # < project_name = service
  # < password = secretservice
  # < uername = tacker

  # [nfvo_vim] section
  sed -i -- "s/#default_vim = <None>/default_vim = VIM0/" /usr/local/etc/tacker/tacker.conf

  # [openstack_vim] section
  sed -i -- "s/#stack_retries = 60/stack_retries = 10/" /usr/local/etc/tacker/tacker.conf
  sed -i -- "s/#stack_retry_wait = 5/stack_retry_wait = 60/" /usr/local/etc/tacker/tacker.conf

  # newton: add [keystone_authtoken] missing in generated tacker.conf.sample, excluding the following
  # (not referenced) memcached_servers = 15.184.66.78:11211
  # (not referenced) signing_dir = /var/cache/tacker
  # (not referenced) cafile = /opt/stack/data/ca-bundle.pem
  # (not referenced) auth_uri = http://15.184.66.78/identity
  # auth_uri is required for keystonemiddleware.auth_token use of public identity endpoint
  cat >>/usr/local/etc/tacker/tacker.conf <<EOF
[keystone_authtoken]
auth_uri = $(openstack endpoint show keystone | awk "/ publicurl / { print \$4 }")
auth_url = $(openstack endpoint show keystone | awk "/ internalurl / { print \$4 }")
project_domain_name = Default
project_name = $service_project
user_domain_name = Default
password = tacker
username = tacker
auth_type = password
EOF

  # these diffs seem superfluous - not referenced at all:
    # < transport_url = rabbit://stackrabbit:secretrabbit@15.184.66.78:5672/
    # < heat_uri = http://15.184.66.78:8004/v1

  # newton: add [tacker_heat] missing in generated tacker.conf.sample
  heat_ipport=$(openstack endpoint show heat | awk "/ internalurl / { print \$4 }" | awk -F'[/]' '{print $3}')
  cat >>/usr/local/etc/tacker/tacker.conf <<EOF
[tacker_heat]
stack_retry_wait = 10
stack_retries = 60
heat_uri = http://$heat_ipport/v1
EOF

  # newton: add [database] missing in generated tacker.conf.sample
  cat >>/usr/local/etc/tacker/tacker.conf <<EOF
[database]
connection = mysql://tacker:$MYSQL_PASSWORD@localhost:3306/tacker?charset=utf8
EOF
 
  # newton: add [tacker_nova] missing in generated tacker.conf.sample, excluding the following
    # these diffs seem superfluous - the only ref'd field is region_name:
    # project_domain_id = default
    # project_name = service
    # user_domain_id = default
    # password = secretservice
    # username = nova
    # auth_url = http://15.184.66.78/identity_v2_admin
    # auth_plugin = password
  cat >>/usr/local/etc/tacker/tacker.conf <<EOF
[tacker_nova]
region_name = $region
EOF

  echo "$0: $(date) Populate Tacker database"
  /usr/local/bin/tacker-db-manage --config-file /usr/local/etc/tacker/tacker.conf upgrade head

  echo "$0: $(date) Install Tacker Client"
  cd /opt/tacker
  if [[ -d /opt/tacker/python-tackerclient ]]; then rm -rf /opt/tacker/python-tackerclient; fi
  git clone https://github.com/openstack/python-tackerclient
  cd python-tackerclient
  git checkout $branch
  python setup.py install

  # deferred until its determined how to get this to Horizon
  #echo "$0: $(date) Install Tacker Horizon plugin"
  #cd /opt/tacker
  #git clone https://github.com/openstack/tacker-horizon
  #cd tacker-horizon
  #python setup.py install
  # The next two commands must affect the Horizon server
  #cp openstack_dashboard_extensions/* /usr/share/openstack-dashboard/openstack_dashboard/enabled/
  #service apache2 restart

  echo "$0: $(date) Start the Tacker Server"
  nohup python /usr/local/bin/tacker-server --config-file /usr/local/etc/tacker/tacker.conf --log-file /var/log/tacker/tacker.log & disown

  echo "$0: $(date) Wait 30 seconds for Tacker server to come online"
  sleep 30

  echo "$0: $(date) Register default VIM"
  cd /opt/tacker
  # TODO: bug in https://github.com/openstack/python-tackerclient/blob/stable/newton/tackerclient/common/utils.py
  # expects that there will be a port specified in the auth_url
  # TODO: bug: user_domain_name: Default is required even for identity v2
  keystone_ipport=$(openstack endpoint show keystone | awk "/ internalurl / { print \$4 }" | awk -F'[/]' '{print $3}')
  cat <<EOF >vim-config.yaml 
auth_url: http://$keystone_ipport/identity/v2.0
username: $OS_USERNAME
password: $OS_PASSWORD
project_name: admin
project_domain_name: Default
user_domain_name: Default
user_id: $(openstack user list | awk "/ admin / { print \$2 }")
EOF

  # newton: NAME (was "--name") is now a positional parameter
  tacker vim-register --is-default --config-file vim-config.yaml --description OpenStack VIM0
  if [ $? -eq 1 ]; then fail; fi

  setup_test_environment
}

function setup_test_environment () {
  echo "Create management network"
  if [ $(neutron net-list | awk "/ vnf_mgmt / { print \$2 }") ]; then
    echo "$0: $(date) vnf_mgmt network exists"
  else
    neutron net-create vnf_mgmt		
    echo "$0: $(date) Create management subnet"
    neutron subnet-create vnf_mgmt 192.168.200.0/24 --name vnf_mgmt --gateway 192.168.200.1 --enable-dhcp --allocation-pool start=192.168.200.2,end=192.168.200.254 --dns-nameserver 8.8.8.8
  fi

  echo "$0: $(date) Create router for vnf_mgmt network"
  if [ $(neutron router-list | awk "/ vnf_mgmt / { print \$2 }") ]; then
    echo "$0: $(date) vnf_mgmt router exists"
  else
    neutron router-create vnf_mgmt_router
    echo "$0: $(date) Create router gateway for vnf_mgmt network"
    get_external_net
    neutron router-gateway-set vnf_mgmt_router $EXTERNAL_NETWORK_NAME
    echo "$0: $(date) Add router interface for vnf_mgmt network"
    neutron router-interface-add vnf_mgmt_router subnet=vnf_mgmt
  fi

  echo "Create private network"
  if [ $(neutron net-list | awk "/ vnf_private / { print \$2 }") ]; then
    echo "$0: $(date) vnf_private network exists"
  else
    neutron net-create vnf_private		
    echo "$0: $(date) Create private subnet"
    neutron subnet-create vnf_private 192.168.201.0/24 --name vnf_private --gateway 192.168.201.1 --enable-dhcp --allocation-pool start=192.168.201.2,end=192.168.201.254 --dns-nameserver 8.8.8.8
  fi

  echo "$0: $(date) Create router for vnf_private network"
  if [ $(neutron router-list | awk "/ vnf_private / { print \$2 }") ]; then
    echo "$0: $(date) vnf_private router exists"
  else
    neutron router-create vnf_private_router
    echo "$0: $(date) Create router gateway for vnf_private network"
    get_external_net
    neutron router-gateway-set vnf_private_router $EXTERNAL_NETWORK_NAME
    echo "$0: $(date) Add router interface for vnf_private network"
    neutron router-interface-add vnf_private_router subnet=vnf_private
  fi
}

function clean () {
  source /opt/tacker/admin-openrc.sh
  eid=($(openstack endpoint list | awk "/tacker/ { print \$2 }")); for id in ${eid[@]}; do openstack endpoint delete ${id}; done
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
}

start=`date +%s`
dist=`grep DISTRIB_ID /etc/*-release | awk -F '=' '{print $2}'`
case "$1" in
  "init")
    setenv
    create_container
    pass
    ;;
  "setup")
    setup $2
    pass
    ;;
  "clean")
    clean
    pass
    ;;
  *)
    echo "usage: bash tacker-setup.sh [init|setup|clean]"
    echo "init: Initialize docker container"
    echo "setup: Setup of Tacker in the docker container"
    echo "clean: remove Tacker service"
    fail
esac
