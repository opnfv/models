This repo contains experimental scripts etc for setting up cloud-native stacks for application deployment and management on bare-metal servers. A lot of cloud-native focus so far has been on public cloud providers (AWS, GCE, Azure) but there aren't many tools and even fewer full-stack open source platforms for setting up bare metal servers with the same types of cloud-native stack features. This repo is thus a collection of tools in development toward that goal, useful in experimentation, demonstration, and further investigation into characteristics of cloud-native platforms in bare-metal environments, e.g. efficiency, performance, security, and resilience.

The toolset will eventually include these elements of one or more full-stack platform solutions:
* hardware prerequisite/options guidance
* container-focused application runtime environment, e.g.
  * kubernetes
  * docker-ce
  * rancher
* software-defined storage backends, e.g.
	* ceph
* runtime-native networking ("out of the box" networking features, vs some special add-on networking software)
* app orchestration, e.g. via
  * cloudify
  * ONAP
  * Helm
* applications useful for platform characterization