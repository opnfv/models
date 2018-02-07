#!/bin/bash
# Copyright 2018 AT&T Intellectual Property, Inc
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
# What this is: test script for the OPNFV Anteater toolset to test patches
# for Anteater exceptions as described at
# https://wiki.opnfv.org/pages/viewpage.action?pageId=11700198
#
#. Usage:
#.   $ git clone https://gerrit.opnfv.org/gerrit/models
#.   $ bash models/tools/anteater.sh [exceptions]
#.   exceptions: exceptions file to test (in Anteater format - see URL above)
#.               if not provided, test exceptions file in the anteater repo
#.  

sudo docker stop anteater
sudo docker rm -v anteater
if [[ ! -d ~/releng-anteater ]]; then
  git clone https://gerrit.opnfv.org/gerrit/releng-anteater ~/releng-anteater
fi
cd ~/releng-anteater/docker
sudo docker build -t anteater .
sudo docker run -d --name anteater anteater sleep 60
if [[ "$1" != "" ]]; then
  sudo docker cp $1 anteater:/home/opnfv/anteater/exceptions/models.yaml
fi
sudo docker exec -it anteater /bin/bash -c \
'cat exceptions/models.yaml; \
git clone https://gerrit.opnfv.org/gerrit/models ~/models; \
~/venv/bin/anteater -p models --path ~/models' | tee ~/anteater-models.log
