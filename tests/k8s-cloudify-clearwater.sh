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
#. What this is: Setup script for clearwater-docker as deployed by Cloudify 
#.   with Kubernetes. See https://github.com/Metaswitch/clearwater-docker
#.   for more info.
#.
#. Prerequisites:
#. - Kubernetes cluster installed per k8s-cluster.sh (in this repo)
#. - user (running this script) added to the "docker" group
#. - clearwater-docker images created and uploaded to docker hub under the 
#.   <hub-user> account as <hub-user>/clearwater-<vnfc> where vnfc is the name
#.   of the specific containers as built by build/clearwater-docker.sh
#.
#. Usage:
#.   From a server with access to the kubernetes master node:
#.   $ git clone https://gerrit.opnfv.org/gerrit/models ~/models
#.   $ cd ~/models/tools/cloudify/
#.   $ bash k8s-cloudify-clearwater.sh start <k8s_master_hostname> <image_path> <image_tag>
#.     k8s_master_hostname: hostname of the k8s master node
#.     image_path: "image path" for images (e.g. user on docker hub) 
#.     image_tag: "image tag" for images e.g. latest, test, stable
#.   $ bash k8s-cloudify-clearwater.sh stop> <k8s_master_hostname>
#.     k8s_master_hostname: hostname of the k8s master node
#.
#. Status: this is a work in progress, under test.

function fail() {
  log "$1"
  exit 1
}

function log() {
  f=$(caller 0 | awk '{print $2}')
  l=$(caller 0 | awk '{print $1}')
  echo ""
  echo "$f:$l ($(date)) $1"
}

function build_local() {
  log "deploy local docker registry on k8s master"
  # Per https://docs.docker.com/registry/deploying/
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@$k8s_master sudo docker run -d -p 5000:5000 --restart=always --name \
    registry registry:2

  # per https://github.com/Metaswitch/clearwater-docker
  log "clone clearwater-docker"
  cd ~
  if [[ ! -d ~/clearwater-docker ]]; then
    git clone --recursive https://github.com/Metaswitch/clearwater-docker.git
  fi

  log "build docker images"
  cd clearwater-docker
  vnfc="base astaire cassandra chronos bono ellis homer homestead homestead-prov ralf sprout"
  for i in $vnfc ; do 
    docker build -t clearwater/$i $i
  done
  
  # workaround for https://www.bountysource.com/issues/37326551-server-gave-http-response-to-https-client-error
  # May not need both...
  if [[ "$dist" == "ubuntu" ]]; then
    check=$(grep -c $k8s_master /etc/default/docker)
    if [[ $check -eq 0 ]]; then
      echo "DOCKER_OPTS=\"--insecure-registry $k8s_master:5000\"" | sudo tee -a /etc/default/docker
      sudo systemctl daemon-reload
      sudo service docker restart
    fi
  fi
  check=$(grep -c insecure-registry /lib/systemd/system/docker.service)
  if [[ $check -eq 0 ]]; then
    sudo sed -i -- "s~ExecStart=/usr/bin/dockerd -H fd://~ExecStart=/usr/bin/dockerd -H fd:// --insecure-registry $k8s_master:5000~" /lib/systemd/system/docker.service
    sudo systemctl daemon-reload
    sudo service docker restart
  fi

  log "deploy local docker registry on k8s master"
  # Per https://docs.docker.com/registry/deploying/
  # sudo docker run -d -p 5000:5000 --restart=always --name registry registry:2

  log "push images to local docker repo on k8s master"
  for i in $vnfc ; do
    docker tag clearwater/$i:latest $k8s_master:5000/clearwater/$i:latest
    docker push $k8s_master:5000/clearwater/$i:latest
  done
}

function start() {
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $k8s_user@$k8s_master <<EOF
echo "create configmap"
kubectl create configmap env-vars --from-literal=ZONE=default.svc.cluster.local --from-literal=ADDITIONAL_SHARED_CONFIG=log_level=5

echo "clone clearwater-docker"
git clone --recursive https://github.com/Metaswitch/clearwater-docker.git
cd clearwater-docker/kubernetes

echo "generate k8s config with --image_path=$1 --image_tag=$2"
./k8s-gencfg --image_path=$1 --image_tag=$2

echo "prefix clearwater- to image names"
sed -i -- "s~$1/~$1/clearwater-~" *.yaml

echo "change ellis-svc to NodePort"
sed -i -- "s/clusterIP: None/type: NodePort/" ellis-svc.yaml
sed -i -- "/port: 80/a\ \ \ \ nodePort: 30880"  ellis-svc.yaml

echo "deploying"
kubectl apply -f ../kubernetes
EOF

  log "workaround bug in homestead-prov"
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $k8s_user@$k8s_master <<'EOF'
hpod=$(kubectl get pods --namespace default | grep -v homestead-prov | awk '/homestead/ {print $1}')
status=$(kubectl get pods -o json --namespace default $hpod | jq -r '.status.phase')
while [[ "$status" != "Running" ]]; do
  echo "homestead is $status ... waiting 10 seconds"
  sleep 10
  status=$(kubectl get pods -o json --namespace default $hpod | jq -r '.status.phase')
done
kubectl cp $hpod:/usr/share/clearwater/bin/clearwater-socket-factory-sig-wrapper ~/tmp/clearwater-socket-factory-sig-wrapper -c homestead
kubectl cp $hpod:/usr/share/clearwater/bin/clearwater-socket-factory-mgmt-wrapper ~/tmp/clearwater-socket-factory-mgmt-wrapper -c homestead
kubectl delete deployment --namespace default homestead-prov
kubectl delete service --namespace default homestead-prov
cd clearwater-docker/kubernetes
kubectl apply -f homestead-prov-depl.yaml
kubectl apply -f homestead-prov-svc.yaml

hppod="null"
while [[ "$hppod" == "null" ]] ; do
  echo "homestead-prov pod is not yet created... waiting 10 seconds"
  sleep 10
  hppod=$(kubectl get pods --namespace default | awk '/homestead-prov/ {print $1}')
done
status=$(kubectl get pods -o json --namespace default $hppod | jq -r '.status.phase')
while [[ "$status" != "Running" ]]; do
  echo; echo "$hppod is $status ... waiting 10 seconds"
  sleep 10
  status=$(kubectl get pods -o json --namespace default $hppod | jq -r '.status.phase')
done

kubectl cp ~/tmp/clearwater-socket-factory-sig-wrapper $hppod:/usr/share/clearwater/bin/clearwater-socket-factory-sig-wrapper  -c homestead-prov
kubectl cp ~/tmp/clearwater-socket-factory-mgmt-wrapper $hppod://usr/share/clearwater/bin/clearwater-socket-factory-mgmt-wrapper -c homestead-prov
EOF
}

function run_test() {
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $k8s_user@$k8s_master <<'EOG'
cat <<EOF >~/clearwater-live-test.yaml
apiVersion: v1
kind: Pod
metadata:
  name: clearwater-live-test
  namespace: default
spec:
  containers:
  - name: clearwater-live-test
    image: blsaws/clearwater-live-test:stable
    command:
      - sleep
      - "3600"
    imagePullPolicy: IfNotPresent
    volumeMounts:
    - mountPath: /tmp
      name: tmp
  volumes:
  - name: tmp
    hostPath:
      path: /tmp
  restartPolicy: Always
EOF
kubectl create -f ~/clearwater-live-test.yaml
status=$(kubectl get pods -o json --namespace default clearwater-live-test | jq -r '.status.phase')
while [[ "$status" != "Running" ]]; do
  echo; echo "clearwater-live-test is $status ... waiting 10 seconds"
  sleep 10
  status=$(kubectl get pods -o json --namespace default clearwater-live-test | jq -r '.status.phase')
done
kubectl exec -t --namespace default clearwater-live-test rake test[default.svc.cluster.local] SIGNUP_CODE=secret  PROXY=bono.default.svc.cluster.local
kubectl delete pods --namespace default clearwater-live-test
EOG
}

function stop() {
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    $k8s_user@$k8s_master <<'EOF'
deps="astaire bono chronos ellis etcd homer homestead homestead-prov ralf sprout cassandra"
for dep in $deps ; do
  echo "deleting deployment $dep"
  kubectl delete deployment --namespace default $dep
  kubectl delete service --namespace default $dep
done
kubectl delete configmap env-vars
rm -rf clearwater-docker
EOF
}

dist=$(grep --m 1 ID /etc/os-release | awk -F '=' '{print $2}')
source ~/k8s_env_$2.sh

case "$1" in
  "start")
    start $3 $4
    ;;
  "test")
    run_test
    ;;
  "stop")
    stop
    ;;
  *)
    grep '#. ' $0
esac

