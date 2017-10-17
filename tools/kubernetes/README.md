This folder contains scripts etc to setup a kubernetes cluster with the following type of environment and components:
* hardware
  * 2 or more bare metal servers
  * two connected networks (public and private): may work if just a single network
  * one or more disks on each server: ceph-osd can be setup on an unused disk, or a folder (/ceph) on the host OS disk
* kubernetes
  * single master (admin) node
  * other cluster nodes
* ceph: ceph-mon on admin, ceph-osd on other nodes
* helm on admin node
* demo helm charts, cloned from https://github.com/kubernetes/charts and modified/tested to work on this cluster

See comments in [setup script](k8s-cluster.sh) for more info.

This is a work in progress!

![Resulting Cluster](/docs/images/models-k8s.png?raw=true "Resulting Cluster")
