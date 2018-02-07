<!---
.. This work is licensed under a Creative Commons Attribution 4.0 International License.
.. http://creativecommons.org/licenses/by/4.0
.. (c) 2017-2018 AT&T Intellectual Property, Inc
-->

This repo contains experimental scripts etc for setting up cloud-native and hybrid-cloud stacks for application deployment and management on bare-metal servers. The goal of these tools is to support the OPNFV Models project with various implementations of cloud-native and OpenStack-based clouds, as well as hybrid clouds. This will serve as a platform for testing modeled VNF lifecycle management in any one of these cloud types, or in a hybrid cloud environment. 

In the process, this is intended to help developers automate setup of full-featured stacks, to overcome the sometimes complex, out-of-date, incomplete, or unclear directions provided for manual stack setup by the upstream projects.

The tools in this repo are thus intended to help provide a comprehensive, easily deployed set of cloud-native stacks that can be further used for analysis and experimentation on converged app modeling and lifecycle management methods, as well as other purposes, e.g. assessments of efficiency, performance, security, and resilience.

The toolset will eventually include these elements of one or more full-stack platform solutions:
* bare-metal server deployment
  * [MAAS](https://maas.io)
  * [Bifrost](https://docs.openstack.org/bifrost/latest/)
* application runtime environments, also referred to as Virtual Infrastructure Managers (VIM) using the ETSI NFV terminology
  * container-focused (often referred to as "cloud-native", although that term really refers to broader concepts)
    * [Kubernetes](https://github.com/kubernetes/kubernetes)
    * [Docker-CE (Moby)](https://mobyproject.org/)
    * [Rancher](https://rancher.com/)
  * VM-focused
    * [OpenStack Helm](https://wiki.openstack.org/wiki/Openstack-helm)
* software-defined storage backends, e.g.
  * [Ceph](https://ceph.com/)
* cluster internal networking
  * [Calico CNI](https://github.com/projectcalico/cni-plugin)
* app orchestration, e.g. via
  * [Cloudify](https://cloudify.co/)
  * [ONAP](https://www.onap.org/)
  * [Helm](https://github.com/kubernetes/helm)
  * [OpenShift Origin](https://www.openshift.org/)
* monitoring and telemetry
  * [OPNFV VES](https://github.com/opnfv/ves)
  * [Prometheus](https://prometheus.io/)
* applications useful for platform characterization
  * [Clearwater IMS](http://www.projectclearwater.org/)

An overall concept for how cloud-native and OpenStack cloud platforms will be deployable as a hybrid cloud environment, with additional OPNFV features such as VES, is shown below.

![Hybrid Cloud Cluster](/docs/images/models-k8s.png?raw=true "Resulting Cluster")