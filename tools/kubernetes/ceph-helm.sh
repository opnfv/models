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
#. What this is: script to setup a Ceph-based SDS (Software Defined Storage)
#. service for a kubernetes cluster, using Helm as deployment tool.
#. Prerequisites:
#. - Ubuntu xenial server for master and agent nodes
#. - key-based auth setup for ssh/scp between master and agent nodes
#. - 192.168.0.0/16 should not be used on your server network interface subnets
#. Usage:
#  Intended to be called from k8s-cluster.sh in this folder. To run directly:
#. $ bash ceph-helm.sh "<nodes>" <cluster-net> <public-net> [ceph_dev]
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network e.g. 10.0.0.1/24
#.     public-net: CIDR of public network
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.               if not provided, ceph data will be stored on osd nodes in /ceph
#.
#. Status: work in progress, incomplete
#
