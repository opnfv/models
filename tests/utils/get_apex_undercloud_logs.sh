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
# What this is: Undercloud debug log collector for Apex
#
# Status: this is a work in progress, under test.
#
# How to use:
#   # As root on the jumphost:
#   $ bash get_apex_undercloud_logs.sh

mac=$(virsh domiflist undercloud | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
UNDERCLOUD=$(/usr/sbin/arp -e | grep ${mac} | awk {'print $1'})
ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no stack@$UNDERCLOUD <<EOF
cd ~
mkdir logs
sudo cp -r /var/log/cinder logs
sudo cp -r /var/log/glance logs
sudo cp -r /var/log/heat logs
sudo cp -r /var/log/ironic-inspector/ logs
sudo cp -r /var/log/nova logs
sudo cp -r /var/log/keystone logs
sudo cp -r /var/log/puppet logs
sudo cp -r /var/log/ironic logs
sudo cp -r /var/log/neutron logs
sudo chown -R stack logs
tar -czf logs.tar.gz logs
EOF

scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no stack@$UNDERCLOUD:/home/stack/logs.tar.gz ~/logs.tar.gz
