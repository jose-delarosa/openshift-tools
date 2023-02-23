#!/bin/bash
# Deployment of python + redis application on OpenShift

# Exit if binaries are not found, otherwise error is ugly
bins="oc"
for bin in $bins; do
    which $bin 1> /dev/null 2>&1
    if [ $? -eq 1 ] ; then
        echo "$bin not installed"
        exit 1
    fi
done

echo "Creating project..."
oc new-project counter --display-name="Counter Application"
oc project counter

echo "Creating applications..."
oc new-app redis --name redis-master -l app=redis
oc new-app https://github.com/jose-delarosa/container-images \
    --name frontend --context-dir=python-redis-k8s/app -l app=frontend

echo "Sleeping for 10 seconds to let Deployments catch up..."
sleep 10

echo "Creating service and route..."
oc create service clusterip frontend --tcp 5000:5000
oc expose service frontend --name frontend --port=5000 -l app=frontend

echo "Sleeping for 10 seconds to let Deployment catch up..."
sleep 10

oc get all

echo "Once the pods are up, the application can be reached at the route below:"
oc get route

# 2023.01.05 17:11:59 - JD
