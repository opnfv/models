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
# What this is: Startup script for a simple web server as part of the 
# vHello test of the OPNFV Models project.
#
# Status: this is a work in progress, under test.
#
# How to use:
#   $ bash start.sh

set -e

sudo apt-get update
sudo apt-get install -y python3

cat <<EOF >index.html
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
<a href="http://wiki.opnfv.org"><img src="logo.png"></a>
</body></html>
EOF

wget https://www.opnfv.org/sites/all/themes/opnfv/logo.png

nohup sudo python3 -m http.server 80 > /dev/null 2>&1 &
