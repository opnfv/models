<!---
.. This work is licensed under a Creative Commons Attribution 4.0 International License.
.. http://creativecommons.org/licenses/by/4.0
.. (c) 2017-2018 AT&T Intellectual Property, Inc
-->

This folder contains scripts etc to setup a kubernetes cluster with the following type of environment and components:
* hardware
  * 2 or more bare metal servers: may also work with VMs
  * two connected networks (public and private): may work if just a single network
  * one or more disks on each server: ceph-osd can be setup on an unused disk, or a folder (/ceph) on the host OS disk
* Kubernetes
  * single k8s master node
  * other k8s cluster worker nodes
* Ceph: backend for persistent volume claims (PVCs) for the k8s cluster, deployed using Helm charts from [netarbiter](https://github.com/att/netarbiter)
* Helm on k8s master (used for initial cluster deployment only)
  * demo helm charts for Helm install verification etc, cloned from [kubernetes charts](https://github.com/kubernetes/charts) and modified/tested to work on this cluster
* Prometheus: server on the k8s master, exporters on the k8s workers
* Cloudify CLI and Cloudify Manager with [Kubernetes plugin](https://github.com/cloudify-incubator/cloudify-kubernetes-plugin)
* OPNFV VES Collector and Agent
* OPNFV Barometer collectd plugin with libvirt and kafka support
* As many components as possible above will be deployed using k8s charts, managed either through Helm or Cloudify

A larger goal of this work is to demonstrate hybrid cloud deployment as indicated by the presence of OpenStack nodes in the diagram below.

Here is an overview of the deployment process, which if desired can be completed via a single script, in about 50 minutes for a four-node k8s cluster of production-grade servers.
* demo_deploy.sh: wrapper for the complete process
  * [/tools/maas/deploy.sh](/tools/maas/deploy.sh): deploys the bare metal host OS (Ubuntu or Centos currently)
  * k8s-cluster.sh: deploy k8s cluster
    * deploy k8s master
    * deploy k8s workers
    * deploy helm
    * verify operation with a hello world k8s chart (nginx)
    * deploy ceph (ceph-helm or on bare metal) and verify basic PVC jobs
    * verify operation with a more complex (PVC-dependent) k8s chart (dokuwiki)
  * [/tools/cloudify/k8s-cloudify.sh](/tools/cloudify/k8s-cloudify.sh): setup cloudify (cli and manager)
  * verify kubernetes+ceph+cloudify operation with a PVC-dependent k8s chart deployed thru cloudify
  * (VES repo) tools/demo_deploy.sh: deploy OPNFV VES
    * deploy VES collector
    * deploy influxdb and VES events database
    * deploy VES dashboard in grafana (reuse existing grafana above)
    * deploy VES agent (OPNFV Barometer "VES Application")
    * on each worker, deploy OPNFV Barometer collectd plugin
  * [/tools/prometheus/prometheus-tools.sh](/tools/prometheus/prometheus-tools.sh): setup prometheus server and exporters on all nodes
	* [/tests/k8s-cloudify-clearwater.sh](/tests/k8s-cloudify-clearwater.sh): deploy clearwater-docker and run clearwater-live-test
    * note: kubectl is currently used to deploy the clearwater-docker charts; use of cloudify-kubernetes for this is coming soon.
* when done, these demo elements are available, as described in the script output
  * Helm-deployed demo app dokuwiki
  * Cloudify-deployed demo app nginx
  * Prometheus UI
  * Grafana dashboards and API
  * Kubernetes API
  * Cloudify API
	* Clearwater-docker

See comments in the [overall demo deploy script](demo_deploy.sh), the [k8s setup script](k8s-cluster.sh), and the other scripts for more info.

See [readme in the folder above](/tools/README.md) for an illustration of the resulting k8s cluster in a hybrid cloud environment.
	
The flow for this demo deployment is illustrated below (note: clearwater-docker deploy/test not yet shown)

![models_demo_flow.svg](/docs/images/models_demo_flow.svg "models_demo_flow.svg")

This is a work in progress!