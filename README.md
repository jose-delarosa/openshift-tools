# openshift-tools
Set of tools and configuration files to deploy OpenShift clusters

* bin/deploy-ocp.sh: Script to deploy an OpenShift cluster at home. Script is highly customized for my personal environment, so it won't work as-is anywhere else. However, it details the installation flow and should be helpful in understanding better all the pieces required for a 3-node master/worker cluster deployment.

* config/: This directory contains the DNS, DHCP, PXE and haproxy configuration files that I use. These are also customized for my personal environment and won't work as-is anywhere else, but they can be used to build your own.
