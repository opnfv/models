This folder contains scripts etc to setup a kubernetes cluster with the following type of environment and components:
* hardware
  * 2 or more bare metal servers: may also work with VMs
  * two connected networks (public and private): may work if just a single network
  * one or more disks on each server: ceph-osd can be setup on an unused disk, or a folder (/ceph) on the host OS disk
* Kubernetes
  * single k8s master node
  * other k8s cluster worker nodes
* Ceph: backend for persistent volume claims (PVCs) for the k8s cluster, deployed using Helm charts from https://github.com/att/netarbiter
* Helm on k8s master (used for initial cluster deployment only)
  * demo helm charts for Helm install verification etc, cloned from https://github.com/kubernetes/charts and modified/tested to work on this cluster
* Prometheus: server on the k8s master, exporters on the k8s workers
* Cloudify CLI and Cloudify Manager with Kubernetes plugin (https://github.com/cloudify-incubator/cloudify-kubernetes-plugin)
* OPNFV VES Collector and Agent
* OPNFV Barometer collectd plugin with libvirt and kafka support
* As many components as possible above will be deployed using k8s charts, managed either through Helm or Cloudify

A larger goal of this work is to demonstrate hybrid cloud deployment as indicated by the presence of OpenStack nodes in the diagram below.

Here is an overview of the deployment process, which if desired can be completed via a single script, in about 50 minutes for a four-node k8s cluster of production-grade servers.
* demo_deploy.sh: wrapper for the complete process
  * ../maas/deploy.sh: deploys the bare metal host OS (Ubuntu or Centos currently)
  * k8s-cluster.sh: deploy k8s cluster
    * deploy k8s master
    * deploy k8s workers
    * deploy helm
    * verify operation with a hello world k8s chart (nginx)
    * deploy ceph (ceph-helm or on bare metal) and verify basic PVC jobs
    * verify operation with a more complex (PVC-dependent) k8s chart (dokuwiki)
  * ../prometheus/prometheus-tools.sh: setup prometheus server, exporters on all nodes, and grafana
  * ../cloudify/k8s-cloudify.sh: setup cloudify (cli and manager)
  * verify kubernetes+ceph+cloudify operation with a PVC-dependent k8s chart deployed thru cloudify
  * (VES repo) tools/demo_deploy.sh: deploy OPNFV VES
    * deploy VES collector
    * deploy influxdb and VES events database
    * deploy VES dashboard in grafana (reuse existing grafana above)
    * deploy VES agent (OPNFV Barometer "VES Application")
    * on each worker, deploy OPNFV Barometer collectd plugin
* when done, these demo elements are available
  * Helm-deployed demo app dokuwiki, at the assigned node port on any k8s cluster node (e.g. http://$NODE_IP:$NODE_PORT)
  * Cloudify-deployed demo app nginx at http://$k8s_master:$(assigned node port)
  * Prometheus UI at http://$k8s_master:9090
  * Grafana dashboards at http://$ves_grafana_host:3000
  * Grafana API at http://$ves_grafana_auth@$ves_grafana_host:3000/api/v1/query?query=<string>
  * Kubernetes API at https://$k8s_master:6443/api/v1/
  * Cloudify API at (example): curl -u admin:admin --header 'Tenant: default_tenant' http://$k8s_master/api/v3.1/status

See comments in [setup script](k8s-cluster.sh) and the other scripts for more info.

This is a work in progress!

![Resulting Cluster](/docs/images/models-k8s.png?raw=true "Resulting Cluster")

The flow for this demo deployment is illustrated below.

![models_demo_flow.svg](/docs/images/models_demo_flow.svg "models_demo_flow.svg")

