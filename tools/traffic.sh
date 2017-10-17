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
# What this is: semi-random request generator for a web service 
#.
#. How to use:
#. $ git clone https://gerrit.opnfv.org/gerrit/models 
#  $ bash models/tools/traffic <url>
#   <url>: address of the web service

echo "$0: $(date) Generate some traffic, somewhat randomly"
ns="0 00 000"
while true
do
  for n in $ns; do
    sleep .$n$[ ( $RANDOM % 10 ) + 1 ]s
    curl -s $1 > /dev/null
  done
done
