This folder contains scripts etc to setup [prometheus](https://github.com/prometheus/prometheus) on a server cluster. It installs:
* a prometheus server (on the host OS) and [grafana](https://grafana.com/) (in docker)
* prometheus exporters on a set of other nodes, to be monitored
  * [node exporter](https://github.com/prometheus/node_exporter) for node basic analytics
  * [haproxy exporter](https://github.com/prometheus/haproxy_exporter) for load-balancer stats from haproxy e.g. as use by Rancher
* several sample grafana dashboards... for more see [grafana dashboards for prometheus](https://grafana.com/dashboards?dataSource=prometheus)

See comments in [prometheus-tools.sh](prometheus-tools.sh) for more info.

This is a work in progress!
