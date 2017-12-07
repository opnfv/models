This repo contains experimental scripts etc for setting up cloud-native stacks for application deployment and management on bare-metal servers. A lot of cloud-native focus so far has been on public cloud providers (AWS, GCE, Azure) but there aren't many tools and even fewer full-stack open source platforms for setting up bare metal servers with the same types of cloud-native stack features. Further, app modeling methods supported by cloud-native stacks differ substantially. The tools in this repo are intended to help provide a comprehensive, easily deployed set of cloud-native stacks that can be further used for analysis and experimentation on converged app modeling and lifecycle management methods, as well as other purposes, e.g. assessments of efficiency, performance, security, and resilience.

The toolset will eventually include these elements of one or more full-stack platform solutions:
* hardware prerequisite/options guidance
* container-focused application runtime environment, e.g.
  * kubernetes
  * docker-ce
  * rancher
* software-defined storage backends, e.g.
	* ceph
* container networking (CNI)
* app orchestration, e.g. via
  * cloudify
  * ONAP
  * helm
* applications useful for platform characterization