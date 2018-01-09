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
# What this is: Startup script for OpenStack Tacker running under docker.

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo; echo "$f:$l ($(date)) $1"
}

export MYSQL_PASSWORD=$(/usr/bin/apg -n 1 -m 16 -c cl_seed)
echo $MYSQL_PASSWORD >~/mysql
debconf-set-selections <<< 'mysql-server mysql-server/root_password password '$MYSQL_PASSWORD
debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password '$MYSQL_PASSWORD
apt-get -q -y install mysql-server python-mysqldb
service mysql restart

log "create Tacker database"
mysql --user=root --password=$MYSQL_PASSWORD -e "CREATE DATABASE tacker; GRANT ALL PRIVILEGES ON tacker.* TO 'root@localhost' IDENTIFIED BY '"$MYSQL_PASSWORD"'; GRANT ALL PRIVILEGES ON tacker.* TO 'tacker'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"';"

log "Setup OpenStack CLI environment"
source /opt/tacker/admin-openrc.sh

uid=$(openstack user list | awk "/ tacker / { print \$2 }")
if [[ $uid ]]; then
  log "Remove prior Tacker user etc"
  openstack user delete tacker
  openstack service delete tacker
  # Note: deleting the service deletes the endpoint
fi

log "Setup Tacker user in OpenStack"
service_project=$(openstack project list | awk "/service/ { print \$4 }")
openstack user create --project $service_project --password tacker tacker
openstack role add --project $service_project --user tacker admin

log "Create Tacker service in OpenStack"
sid=$(openstack service list | awk "/ tacker / { print \$2 }")
openstack service create --name tacker --description "Tacker Project" nfv-orchestration
sid=$(openstack service list | awk "/ tacker / { print \$2 }")

log "Create Tacker service endpoint in OpenStack"
ip=$(ip route get 8.8.8.8 | awk '{print $NF; exit}')
region=$(openstack endpoint list | awk "/ nova / { print \$4 }" | head -1)
openstack endpoint create --region $region \
  --publicurl "http://$ip:9890/" \
  --adminurl "http://$ip:9890/" \
  --internalurl "http://$ip:9890/" nfv-orchestration

# TODO: find a generic way to set extension_drivers = port_security in ml2_conf.ini
  # On the neutron service host, update ml2_conf.ini and and restart neutron service
  # sed -i -- 's~#extension_drivers =~extension_drivers = port_security~' /etc/neutron/plugins/ml2/ml2_conf.ini
  # For devstack, set in local.conf per http://docs.openstack.org/developer/devstack/guides/neutron.html
  # Q_ML2_PLUGIN_EXT_DRIVERS=port_security

log "Update tacker.conf values"

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
sed -i -- "s~#api_paste_config = api-paste.ini~api_paste_config = /usr/local/etc/tacker/api-paste.ini~" /usr/local/etc/tacker/tacker.conf
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

sed -i -- "s~#state_path = /var/lib/tacker~state_path = /var/lib/tacker~" /usr/local/etc/tacker/tacker.conf

# [alarm_auth] section - optional (?)
# < url = http://15.184.66.78:35357/v3
# < project_name = service
# < password = secretservice
# < uername = tacker

# [nfvo_vim] section
sed -i -- "s/#default_vim = <None>/default_vim = VIM0/" /usr/local/etc/tacker/tacker.conf

# [openstack_vim] section - only change this if you want to override values in models/tests/utils/tacker/tacker.conf.sample
#sed -i -- "s/#stack_retries = 60/stack_retries = 10/" /usr/local/etc/tacker/tacker.conf
#sed -i -- "s/#stack_retry_wait = 5/stack_retry_wait = 60/" /usr/local/etc/tacker/tacker.conf

# newton: add [keystone_authtoken] missing in generated tacker.conf.sample, excluding the following
# (not referenced) memcached_servers = 15.184.66.78:11211
# (not referenced) signing_dir = /var/cache/tacker
# (not referenced) cafile = /opt/stack/data/ca-bundle.pem
# (not referenced) auth_uri = http://15.184.66.78/identity
# auth_uri is required for keystonemiddleware.auth_token use of public identity endpoint
# removed due to issues with "ERROR oslo_middleware.catch_errors DiscoveryFailure: Cannot use v2 authentication with domain scope"
  # project_domain_name = Default
  # user_domain_name = Default

cat >>/usr/local/etc/tacker/tacker.conf <<EOF
[keystone_authtoken]
auth_uri = $(openstack endpoint show keystone | awk "/ publicurl / { print \$4 }")
auth_url = $(openstack endpoint show keystone | awk "/ internalurl / { print \$4 }")
project_name = $service_project
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

log "/usr/local/etc/tacker/tacker.conf"
cat /usr/local/etc/tacker/tacker.conf

log "Populate Tacker database"
/usr/local/bin/tacker-db-manage --config-file /usr/local/etc/tacker/tacker.conf upgrade head

# deferred until its determined how to get this to Horizon
## Install Tacker Horizon plugin"
#cd /opt/tacker
#git clone https://github.com/openstack/tacker-horizon
#cd tacker-horizon
#python setup.py install
# The next two commands must affect the Horizon server
#cp openstack_dashboard_extensions/* /usr/share/openstack-dashboard/openstack_dashboard/enabled/
#service apache2 restart

log "Start the Tacker Server"
nohup python /usr/local/bin/tacker-server \
  --config-file /usr/local/etc/tacker/tacker.conf \
  --log-file /var/log/tacker/tacker.log &

# Wait 30 seconds for Tacker server to come online"
sleep 30

log "Register default VIM"
cd /opt/tacker
# TODO: bug in https://github.com/openstack/python-tackerclient/blob/stable/newton/tackerclient/common/utils.py
# expects that there will be a port specified in the auth_url
# TODO: bug: user_domain_name: Default is required even for identity v2
# removed due to issues with "DiscoveryFailure" as above
  # project_domain_name: Default
  # user_domain_name: Default
cat <<EOF >vim-config.yaml
auth_url: $OS_AUTH_URL
username: $OS_USERNAME
password: $OS_PASSWORD
project_id: $(openstack project show admin | awk '/ id / {print $4}')
project_name: admin
user_id: $(openstack user list | awk "/ admin / { print \$2 }")
EOF

# newton: NAME (was "--name") is now a positional parameter
tacker vim-register --is-default --config-file vim-config.yaml --description OpenStack VIM0
tail -f /var/log/tacker/tacker.log
