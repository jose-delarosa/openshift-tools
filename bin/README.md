# openshift-tools
Set of scripts that deploy simple OpenShift clusters and applications on top.

* `nginx/`: Deploy a simple instance of the nginx web server on OpenShift. You may have to modify the script with the location of the yaml manifests used in the script.

* `python-redis/`: Deploy simple python + redis applications that talk to each other. It uses the S2I process to build and launch the python application. Refer to https://github.com/jose-delarosa/container-images/tree/master/python-redis-k8s for more information.

* `deploy-ocp.sh`: Deploys a 3-node OpenShift cluster. This script is highly customized for my personal environment, so it won't work as-is anywhere else. However, it details the installation flow and should be helpful in understanding better all the pieces required for a 3-node master/worker cluster deployment.

* `add-htpasswd-provider.sh`: Add an HTPasswd provider so you can authenticate using other users. This script will create a `sysman` admin user with password `password` and a `user` non-admin user with password `password`.
