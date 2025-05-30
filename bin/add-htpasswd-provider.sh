#!/bin/bash
#
# Script to add an HTPasswd provider to an OpenShift cluster and add a couple
# of users (admin and non-admin)

# Colors
green="\033[92m"
red="\033[91m"
end="\033[0m"

ADMIN="admin"
USER="developer"
PSWD="P@ssw0rd"
OAUTH="/tmp/oauth"
HTPASSWD="/tmp/htpasswd"
SECRET="htpasswd-secret"
VAR="spec:\n  identityProviders:\n  - name: htpasswd_provider\n    mappingMethod: claim\n    type: HTPasswd\n    htpasswd:\n      fileData:\n        name: $SECRET"

# Exit if these binaries are not found, otherwise error is ugly
bins="htpasswd"
for bin in $bins; do
    which $bin 1> /dev/null 2>&1
    if [ $? -eq 1 ] ; then
        echo "$bin not installed"
        exit 1
    fi
done

echo "Replacing OAuth resource..."
oc get oauth cluster -o yaml > $OAUTH
sed -i "s/spec: {}/$VAR/g" $OAUTH
oc replace -f $OAUTH

# Create htpasswd file
echo "Creating $HTPASSWD..."
htpasswd -c -B -b $HTPASSWD $ADMIN $PSWD
htpasswd    -B -b $HTPASSWD $USER  $PSWD
# Adding more non-admin users
htpasswd    -B -b $HTPASSWD user1 $PSWD
htpasswd    -B -b $HTPASSWD user2 $PSWD
htpasswd    -B -b $HTPASSWD user3 $PSWD

echo "Creating secret..."
oc create secret generic $SECRET \
    --from-file htpasswd=$HTPASSWD -n openshift-config

# Add roles for admin, anything for user?
echo "Adding roles to users..."
oc adm policy add-cluster-role-to-user cluster-admin $ADMIN

echo -e "${green}Done!${end} In 2 mins, check that new oauth pods were created:"
echo "  oc get pods -n openshift-authentication"

# 2024.03.04 11:27:25 - JD
