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
# What this is: Workaround for issues with the undercloud suppor for
# PXE booting WOL devices. The TFTP RRQ "undionly.kpxe" events (through
# which the booted host requests the PXE boot image) are not making it
# to the undercloud. So two workarounds are implemented: a tftp server
# for undionly.kpxe is installed on the jumphost, and manual invocation
# of the WOL is invoked (as the undercloud was never issuing the WOL
# packets).
#
# Status: this is a work in progress, under test.
#
# How to use:
# As root on the jumphost, start this script as soon as deploy is started.
# It will wait for the Ironic log to get created, then watch for the following
# key log entries and take action on them directly or through notifying the user
# to take action as needed (e.g. power-off the node).
# 2016-10-07 23:26:10.597 17686 INFO ironic.drivers.modules.wol [req-ec2f0a60-5f90-4706-a2b3-b7217193166d - - - - -] Reboot called for node 2baf581d-aa47-481e-a28e-304e0959b871. Wake-On-Lan does not fully support this operation. Trying to power on the node.
# 2016-10-07 23:56:29.876 17686 INFO ironic.drivers.modules.wol [req-92128326-889c-47a8-94ee-2fec77c2de44 - - - - -] Power off called for node 579967bd-1e4d-4212-bf9b-1716a1cd4cfa. Wake-On-Lan does not support this operation. Manual intervention required to perform this action.
# 2016-10-08 23:57:17.008 17691 WARNING ironic.drivers.modules.agent_base_vendor [req-44232e37-c38a-4099-8d81-871700e4dc2a - - - - -] Failed to soft power off node 165841ec-e8d2-4592-8f15-55742899fff5 in at least 30 seconds. Error: RetryError[Attempts: 7, Value: power on]
#
#   $ bash apex_wol_workaround.sh 

echo "$0: Install tftp server"
yum install tftp tftp-server xinetd
cat >/etc/xinetd.d/tftp <<EOF
# default: off
# description: The tftp server serves files using the trivial file transfer
#	protocol.  The tftp protocol is often used to boot diskless
#	workstations, download configuration files to network-aware printers,
#	and to start the installation process for some operating systems.
service tftp
{
        socket_type             = dgram
        protocol                = udp
        wait                    = yes
        user                    = root
        server                  = /usr/sbin/in.tftpd
        server_args             = -c -s /var/lib/tftpboot
        disable                 = no
        per_source              = 11
        cps                     = 100 2
        flags                   = IPv4
}
EOF
chmod 777 /var/lib/tftpboot
iptables -I INPUT -p udp --dport 69 -j ACCEPT
systemctl enable xinetd.service
systemctl restart xinetd.service
curl http://boot.ipxe.org/undionly.kpxe > /var/lib/tftpboot/undionly.kpxe

UNDERCLOUD_MAC=$(virsh domiflist undercloud | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
while [[ -z $UNDERCLOUD_MAC ]]; do
  echo "$0: Waiting 10 seconds for undercloud to be created"
  sleep 10
  UNDERCLOUD_MAC=$(virsh domiflist undercloud | grep default | grep -Eo "[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+:[0-9a-f\]+")
done

UNDERCLOUD_IP=$(/usr/sbin/arp -e | grep ${UNDERCLOUD_MAC} | awk {'print $1'})
while [[ -z $UNDERCLOUD_IP ]]; do
  echo "$0: Waiting 10 seconds for undercloud IP to be assigned"
  sleep 10
  UNDERCLOUD_IP=$(/usr/sbin/arp -e | grep ${UNDERCLOUD_MAC} | awk {'print $1'})
done

ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no stack@$UNDERCLOUD_IP <<EOF
while [[ ! -f /var/log/ironic/ironic-conductor.log ]]; do
  echo "$0: Waiting 10 seconds for ironic-conductor.log to be created"
  sleep 10
done

source stackrc
mkfifo /tmp/myfifo
tail -f /var/log/ironic/ironic-conductor.log | grep -e "Reboot called for node" -e "Failed to soft power off node" > /tmp/myfifo &
while read line
do
  if [[ $(echo "$line" | grep "Reboot called for node") ]]; then
    IRONIC_NODE_ID=$(echo "$line" | sed -e 's/^.*node //' | awk '{print $1}' | sed -e 's/.$//g')
    SERVER_ID=$(ironic node-show $IRONIC_NODE_ID  | awk "/ instance_uuid / { print \$4 }")
    SERVER_NAME=$(openstack server show $SERVER_ID  | awk "/ name / { print \$4 }")
    echo "$0: Waking $SERVER_NAME"
    if [[ $SERVER_NAME == "overcloud-controller-0" ]]; then sudo ether-wake B8:AE:ED:76:FB:C4
    else sudo ether-wake B8:AE:ED:76:F9:FF
    fi
  fi

  if [[ $(echo "$line" | grep "Failed to soft power off node") ]]; then
    IRONIC_NODE_ID=$(echo "$line" | sed -e 's/^.*node //' | awk '{print $1}' | sed -e 's/.$//g')
    SERVER_ID=$(ironic node-show $IRONIC_NODE_ID  | awk "/ instance_uuid / { print \$4 }")
    SERVER_NAME=$(openstack server show $SERVER_ID  | awk "/ name / { print \$4 }")
    echo "$0: *** POWER OFF $SERVER_NAME NOW! ***"
  fi
done </var/log/ironic/ironic-conductor.log
EOF
