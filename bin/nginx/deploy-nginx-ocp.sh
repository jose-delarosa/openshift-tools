#!/bin/bash
# Quick and dirty deployment of nginx on OpenShift
# TODO: Be able to change project name via command option, will have to not
#       use yaml files or modify on the fly.

BASEDIR=`pwd`
PROJECT=nginx           # Don't change!! Applied yaml uses static values :( 

# Exit if binaries are not found, otherwise error is ugly
bins="oc"
for bin in $bins; do
    which $bin 1> /dev/null 2>&1
    if [ $? -eq 1 ] ; then
        echo "$bin not installed"
        exit 1
    fi
done

# Get OCP version - will only work if status is not in Error :(
ocp_vers=`oc get clusterversion | grep ^version | awk '{print $2}' | \
  cut -d. -f1-2`

echo "Creating project..."
oc new-project $PROJECT
oc project $PROJECT

echo "Creating ConfigMaps..."
oc create configmap $PROJECT-configmap \
  --from-file=${PROJECT}.conf=$BASEDIR/nginx.conf
oc create configmap ${PROJECT}html-configmap \
  --from-file=index.html=$BASEDIR/index.html

# This could be better. It works, but it could be way more elegant.
##if [ $ocp_vers = "4.11" -o $ocp_vers = "4.12" ] ; then
##    oc apply -f $BASEDIR/nginx-app.yaml
##else
##    oc apply -f $BASEDIR/nginx-app-old.yaml
##fi
oc apply -f $BASEDIR/nginx-app-old.yaml

echo "Sleeping for 10 seconds to let Deployment catch up..."
sleep 10

# nginx needs extra privileges, need to find out why
echo "Creating service accounts and adding anyuid scc"
oc create sa my-${PROJECT}-sa
oc adm policy add-scc-to-user anyuid -z my-${PROJECT}-sa
oc set serviceaccount deployment/my-${PROJECT} my-${PROJECT}-sa

# Reach application through NodePort - COMMENT OUT FOR NOW - Let's use LB
#echo "Create NodePort route"
#oc expose service my-${PROJECT} --type=NodePort --name=my-${PROJECT}-nodeport \
#    --generator="service/v2"

echo "Sleeping for 5 seconds..."
sleep 5

# Reach application through route
echo "Create default route"
#oc expose service/my-${PROJECT}-nodeport
oc expose service/my-${PROJECT}
oc get pods

echo "Sleeping for 10 seconds to let the pods start..."
sleep 10

oc get all

# 2023.01.18 14:05:52 - JD
