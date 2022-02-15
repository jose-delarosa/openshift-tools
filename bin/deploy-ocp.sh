#!/bin/bash
#
# Copyright 2022 Jose Delarosa
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
# This is an opinionated script to deploy an OpenShift cluster using virtual
# machines. A virtual network should already exist, including a properly
# configured DNS and DHCP server.
#
# This script was developed for my custom environment at home, though it could
# be used elsewhere with a fair amount of modifications.
#
# Note about specifying worker (compute) nodes: I removed the option to pass
# number of worker nodes (1-2) since according to the official documents this
# option is not supported in UPI deployments. Compute nodes can be added after
# the cluster is deployed. - JD 2022.01.06
#
# Requirements:
# - Internet connection to download binaries, images and other files
# - Virtual environment with LVM storage volumes
# - DHCP server that will allocate IPs based on MAC address
# - DNS entries for all OCP nodes, APIs and load balancer
# - Load balancer
# - Pull secret
# - Public SSH key
# - ~/.ssh/config setup with passwordless access to bastion node
#
# Inputs:
# - Required: Cluster name
# - Required: Domain name
# - Required: OCP version
# - Optional: RHCOS version
# - Optional: Number of workers to deploy (0-2)
#
# Wishlist:
# - Add interactive menu and list all OCP versions available:
#   URL=https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/
#     OCP 4.7: $URL/latest-4.7/release.txt
#     OCP 4.8: $URL/latest-4.8/release.txt
#     OCP 4.9: $URL/latest-4.9/release.txt
# - Verify sha256sum of downloaded files
# - Pass option to specify CPUs and RAM
# - If a given OCP version does not exist, make more obvious
# - Check if disk volumes already exist before creating

# Default values
cluster=
domain=
ocp_vers=
rhcos_vers=
workers=0

# This var is currently not used, leaving here as part of future improvements
valid_domains="dlr131.com dlr132.com dlr133.com dlr134.com"
vmlist_exist=""

# Variables 
BASE_URL=https://mirror.openshift.com/pub/openshift-v4/x86_64
BASE_DIR=/var/ftp/pub/ocp
INSTALL_DIR=$BASE_DIR/rhcos-install
PULLSECRET_FILE=$BASE_DIR/files/pull-secret-gmail.txt
SSHKEY_FILE=$BASE_DIR/files/id_rsa.pub

# Colors
green="\033[92m"
red="\033[91m"
end="\033[0m"

usage() {
    echo "Usage: `basename $0` <options>"
    echo "Options:"
    echo "  -c --cluster <name>       Cluster name ('labX')"
    echo "  -d --domain <name>        Domain name ('dlr13X.com')"
    echo "  -v --ocp-vers <vers>      OCP version ('4.8.12', '4.9.5')"
    echo "  -r --rhcos-vers <vers>    Optional: RHCOS version (def: latest)"
#   echo "  -w --workers <0|1|2>      Optional: Number of workers (def: 0)"
    echo "  -h --help                 Display this menu"
    exit
}

err() {
    echo -e "\e[97m\e[101m[ERROR]\e[0m ${1}"; shift; echo;
    while [[ $# -gt 0 ]]; do
        echo "    ${1}"
        shift
    done
    exit 1;
}

out() {
    echo -e "${green}[OK]${end} ${1}"; shift;
    while [[ $# -gt 0 ]]; do
        echo "    ${1}"
        shift
    done
}

ok() {
    test -z "$1" && echo " ok" || echo " ${1}"
}

ask_continue() {
    echo -n "$1 [y/N] : "
    read resp
    case $resp in
        y ) out "Starting VM creation..." ;;
        * ) echo "Exiting." ; exit 1 ;;
    esac
}

verify_env() {
    domain=$1
    workers=$2
    # Check values provided - there's probably a more elegant way
    if [ $domain = "dlr131.com" -o $domain = "dlr132.com" \
          -o $domain = "dlr133.com" -o $domain = "dlr134.com" ] ; then
        out "Domain $domain is valid"
    else
        err "Domain $domain is not valid, please try again"
    fi
    if [ $workers -gt 2 ] ; then
        err "Workers can only be 0, 1 or 2"
    else
        out "Number of workers ($workers) is valid"
    fi

    # Check if a cluster already exists in the domain before continuing
    domain_no=`echo $domain | cut -c 4-6`
    virsh dominfo master0-$domain_no 1> /dev/null 2>&1
    if [ $? -eq 0 ] ; then
        err "VM master0-$domain_no exists, please check"
    else
        out "No existing master0-$domain_no VM found, proceeding"
    fi

    # Check that loadbalancer is running
    state=`virsh dominfo haproxy-$domain_no | grep ^State | awk '{print $2}'`
    if [ $state != "running" ] ; then
        err "haproxy-$domain_no is not running, start and try again"
    else
        out "haproxy-$domain_no is running...proceeding"
    fi
}

get_proper_rhcos_vers() {
    ocp_vers=$1
    ocp_minor_vers=`echo $ocp_vers | cut -d . -f1-2`   # ocp_vers is x.y.z
    # This is probably overkill, especially since this version will not change
    # often, but I don't want to code any specific versions in this script.
    # rhcos_vers is a global variable, so no need to pass back
    rhcos_vers=`readlink $BASE_DIR/rhcos/${ocp_minor_vers}-latest`
    out "RHCOS version to use: $rhcos_vers"
}

#------------------------------------------------------------------------------
# During the installation process, the VMs shutdown but don't restart, possibly
# due to the way I am invoking virt-install. I noticed that restarting them
# manually continued the installation process, so I wrote some code to
# automatically monitor when a node is not running, and then turn it back on
# This is a one-time process only.
#------------------------------------------------------------------------------

check_nodes_exist() {
    vmlist=$1

    # Do nodes exist? Build list of existing nodes
    for vm in $vmlist; do
        virsh dominfo $vm 1> /dev/null 2>&1
        if [ $? -eq 0 ] ; then
            vmlist_exist="$vmlist_exist $vm"
        fi
    done
}

start_nodes() {
    # Don't add any echo statements here, or the return value will be messed up
    vm_list=$1
    new_list=""

    for vm in $vm_list; do
        # Check that VM is running
        state=`virsh dominfo $vm | grep ^State | awk '{print $2}'`
        if [ $state != "running" ] ; then
            virsh start $vm 1> /dev/null 2>&1
        else
            new_list="$new_list $vm"
        fi
    done
    echo $new_list
}

monitor_vms() {
    domain=$1
    sleep_interval=5
    counter=0

    i=1
    sp="/-\|"

    out "Loading RHCOS image on VMs (3-4 mins)..."
    domain_no=`echo $domain | cut -c 4-6`
    vmlist="bootstrap-$domain_no \
            master0-$domain_no master1-$domain_no master2-$domain_no \
            worker0-$domain_no worker1-$domain_no"

    check_nodes_exist "$vmlist"
    vms_to_check=$vmlist_exist
    echo -n ' '

    while true ; do
        # Nice way to get back value from function
        result=$(start_nodes "$vms_to_check")
        # echo "DEBUG remain: $result"

        vms_to_check=$result
        if [ X"$vms_to_check" = X ] ; then
            break
        fi
        printf "\b${sp:i++%${#sp}:1}"
        sleep $sleep_interval
        ((counter=counter+1))
    done
    n=`echo $counter \* $sleep_interval | bc -l`
    echo -ne "All nodes restarted\r"
    out "Done! Took $n seconds"
}

#------------------------------------------------------------------------------
# Download client binaries and RHCOS images if they don't exist locally
#------------------------------------------------------------------------------
download_images() {
    # RHCOS images
    rhcos_vers=$1
    ocp_vers=$2
    rhcos_vers_main=`echo $rhcos_vers | cut -f 1-2 -d .`
    DOWNLOAD_URL=$BASE_URL/dependencies/rhcos/$rhcos_vers_main/$rhcos_vers

    # Assumes that if dir exists, then images exist locally
    if [ ! -d $BASE_DIR/rhcos/$rhcos_vers ] ; then
        out "Downloading images for RHCOS $rhcos_vers..."
        mkdir $BASE_DIR/rhcos/$rhcos_vers
        cd $BASE_DIR/rhcos/$rhcos_vers
        # Need to capture something going wrong so we can ask later on if we
        # want to continue or not
        wget $DOWNLOAD_URL/rhcos-$rhcos_vers-x86_64-live-initramfs.x86_64.img
        wget $DOWNLOAD_URL/rhcos-$rhcos_vers-x86_64-live-kernel-x86_64
        wget $DOWNLOAD_URL/rhcos-$rhcos_vers-x86_64-live-rootfs.x86_64.img
        wget $DOWNLOAD_URL/sha256sum.txt
    else
        out "Images in $BASE_DIR/rhcos/$rhcos_vers ...skipping download..."
    fi
    # Future: Verify file integrity

    if [ ! -d $INSTALL_DIR/$rhcos_vers ] ; then
        out "Copying images to '$INSTALL_DIR/$rhcos_vers/'..."
        mkdir $INSTALL_DIR/${rhcos_vers}
        cp -p $BASE_DIR/rhcos/$rhcos_vers/rhcos-${rhcos_vers}-x86_64-live-initramfs.x86_64.img \
          $INSTALL_DIR/$rhcos_vers/rhcos-x86_64-live-initramfs.x86_64.img
        # Capture error and exit
        if [ $? -ne 0 ] ; then
            err "Error copying image" 
        fi
        cp -p $BASE_DIR/rhcos/$rhcos_vers/rhcos-${rhcos_vers}-x86_64-live-kernel-x86_64 \
          $INSTALL_DIR/$rhcos_vers/rhcos-x86_64-live-kernel-x86_64
        cp -p $BASE_DIR/rhcos/$rhcos_vers/rhcos-${rhcos_vers}-x86_64-live-rootfs.x86_64.img \
          $INSTALL_DIR/$rhcos_vers/rhcos-x86_64-live-rootfs.x86_64.img
    fi

    cat << EOF > $INSTALL_DIR/$rhcos_vers/.treeinfo
[general]
arch = x86_64
family = Red Hat CoreOS
platforms = x86_64
version = ${ocp_vers}
[images-x86_64]
initrd = rhcos-x86_64-live-initramfs.x86_64.img
kernel = rhcos-x86_64-live-kernel-x86_64
EOF

}

download_bins() {
    # Client binaries
    ocp_vers=$1
    DOWNLOAD_URL=$BASE_URL/clients/ocp/$ocp_vers

    # Assumes that if dir exists, then binaries exist locally
    if [ ! -d $BASE_DIR/clients/$ocp_vers ] ; then
        out "Downloading install binaries for OCP $ocp_vers..."
        mkdir $BASE_DIR/clients/$ocp_vers
        cd $BASE_DIR/clients/$ocp_vers
        wget $DOWNLOAD_URL/openshift-client-linux-$ocp_vers.tar.gz
        wget $DOWNLOAD_URL/openshift-install-linux-$ocp_vers.tar.gz
        wget $DOWNLOAD_URL/sha256sum.txt
    else
        out "Install binaries in $BASE_DIR/clients/$ocp_vers ...skipping download..."
    fi

    # Future: Verify file integrity
}

extract_bins() {
    ocp_vers=$1
    DOWNLOAD_URL=$BASE_URL/clients/ocp/$ocp_vers
    out "Extracting binaries in /usr/local/bin..." 
    cd /usr/local/bin
    tar zxf $BASE_DIR/clients/$ocp_vers/openshift-client-linux-$ocp_vers.tar.gz
    tar zxf $BASE_DIR/clients/$ocp_vers/openshift-install-linux-$ocp_vers.tar.gz
}

#------------------------------------------------------------------------------
# Customize install-config.yaml
# Create ignition files and move them to right location
# - Keep pull secret in a different file
# - Keep ssh key in a different file
#------------------------------------------------------------------------------

customize_install_config() {
    domain=$1
    cluster=$2
    IC_FILE=$BASE_DIR/files/out/install-config.yaml
    PULLSECRET=`cat $PULLSECRET_FILE | tr -d '\n'`
    SSHKEY=`cat $SSHKEY_FILE | tr -d '\n'`

    out "Creating install_config.yaml..."
    rm -rf $BASE_DIR/files/out
    mkdir $BASE_DIR/files/out
    # From the documentation, regarding 'replicas' in the compute section:
    # You must set this value to 0 when you install OpenShift Container Platform
    # on user-provisioned infrastructure (UPI). In installer-provisioned
    # installations (IPI), the parameter controls the number of compute machines
    # that the cluster creates and manages for you. In UPI, you must manually
    # deploy the compute machines before you finish installing the cluster.
    cat > $IC_FILE << EOF
apiVersion: v1
baseDomain: $domain
compute:
- hyperthreading: Enabled
  name: worker
  replicas: 0
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: 3
metadata:
  name: $cluster
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
fips: false
pullSecret: '$PULLSECRET'
sshKey: '$SSHKEY'
EOF

}

create_ignition_files() {
    out "Creating ignition files..."
    openshift-install create manifests --dir=$BASE_DIR/files/out
    # Make master nodes not schedulable
    # sed -i 's/mastersSchedulable: true/mastersSchedulable: false/g' \
    #     $BASE_DIR/files/out/manifests/cluster-scheduler-02-config.yml
    openshift-install create ignition-configs --dir=$BASE_DIR/files/out
}

move_ignition_files() {
    out "Moving ignition files to final destination..."
    if [ ! -d $INSTALL_DIR/ignition ] ; then
        mkdir $INSTALL_DIR/ignition
    fi
    cp -fp $BASE_DIR/files/out/*.ign $INSTALL_DIR/ignition
    chmod 644 $INSTALL_DIR/ignition/*.ign
}

#------------------------------------------------------------------------------
# Create nodes (VMs)
#------------------------------------------------------------------------------

create_volumes() {
    # Node names will depend on what domain I choose
    # I have already checked for valid domains
    domain=$1
    workers=$2
    pool="dir"
    domain_no=`echo $domain | cut -c 4-6`

    # Node disk size
    b_disk=50
    m_disk=120
    w_disk=120

    out "Creating disk volumes..."
    virsh vol-create-as $pool bootstrap-$domain_no ${b_disk}G
    virsh vol-create-as $pool master0-$domain_no ${m_disk}G
    virsh vol-create-as $pool master1-$domain_no ${m_disk}G
    virsh vol-create-as $pool master2-$domain_no ${m_disk}G
    # Up to 2 workers - there has to be a better way to do this
    if [ $workers = 1 ] ; then
        virsh vol-create-as $pool worker0-$domain_no ${w_disk}G
    elif [ $workers = 2 ] ; then
        virsh vol-create-as $pool worker0-$domain_no ${w_disk}G
        virsh vol-create-as $pool worker1-$domain_no ${w_disk}G
    fi
}

virt_install() {
    vm=$1
    ignition=$2
    mac=$3
    bridge=$4
    rhcos_vers=$5
    vcpu=$6
    vram=$7

    out "Creating node $vm..."
    virt-install --connect qemu:///system \
       --network bridge=${bridge},model=virtio \
       --name ${vm} --ram=$vram --vcpus=$vcpu --disk vol=dir/${vm} \
       --os-variant rhel7.5 \
       --noreboot --noautoconsole --mac="${mac}" \
       --location=http://solo.dlr.com/pub/ocp/rhcos-install/${rhcos_vers}/ \
       --extra-args="nomodeset rd.neednet=1 coreos.inst=yes coreos.inst=yes coreos.inst.install_dev=vda coreos.live.rootfs_url=http://solo.dlr.com/pub/ocp/rhcos-install/${rhcos_vers}/rhcos-x86_64-live-rootfs.x86_64.img coreos.inst.ignition_url=http://solo.dlr.com/pub/ocp/rhcos-install/ignition/${ignition} console=tty0 console=ttyS0,115200" \
       > /dev/null || err "Creating ${vm} failed"; ok

}

create_nodes() {
    # Bridge and other information will depend on what domain I use
    domain=$1
    workers=$2
    rhcos_vers=$3
    ocp_vers=$4
    domain_no=`echo $domain | cut -c 4-6`

    # Domains allowed
    if [ $domain = "dlr131.com" ] ; then
        bridge=virbr1
        macd=c1
    elif [ $domain = "dlr132.com" ] ; then
        bridge=virbr2
        macd=c3
    elif [ $domain = "dlr133.com" ] ; then
        bridge=virbr3
        macd=f1
    elif [ $domain = "dlr134.com" ] ; then
        bridge=virbr4
        macd=c4
    fi

    # For now, and until I can deploy separate workers, I set same resources
    #
    # Lower resources used on masters if also deploying dedicated workers
    # if [ $workers = 0 ] ; then
    #     vcpus=8
    #     vmem=32768
    # else
    #     vcpus=4
    #     vmem=16384
    # fi
    vcpus=4
    vmem=16384

    # virt_install <vm> <ignition> <mac> <bridge> <rhcos_vers> <vcpu> <vram>
    virt_install bootstrap-$domain_no bootstrap.ign 52:54:00:34:$macd:ff \
        $bridge $rhcos_vers 4 8192
    virt_install master0-$domain_no master.ign 52:54:00:34:$macd:a0 \
        $bridge $rhcos_vers $vcpus $vmem
    virt_install master2-$domain_no master.ign 52:54:00:34:$macd:a2 \
        $bridge $rhcos_vers $vcpus $vmem
    virt_install master1-$domain_no master.ign 52:54:00:34:$macd:a1 \
        $bridge $rhcos_vers $vcpus $vmem
    # Up to 2 workers - there has to be a better way to do this
    if [ $workers = 1 ] ; then
        virt_install worker0-$domain_no worker.ign 52:54:00:34:$macd:b0 \
            $bridge $rhcos_vers $vcpus $vmem
    elif [ $workers = 2 ] ; then
        virt_install worker0-$domain_no worker.ign 52:54:00:34:$macd:b0 \
            $bridge $rhcos_vers $vcpus $vmem
        virt_install worker1-$domain_no worker.ign 52:54:00:34:$macd:b1 \
            $bridge $rhcos_vers $vcpus $vmem
    fi
}

copy_auth_to_bastion() {
   cluster=$1
   # These commands assume that SSH keys are already setup
   scp -p $BASE_DIR/files/out/auth/kubeconfig bastion:~/.kube/config
   scp -p $BASE_DIR/files/out/auth/kube* bastion:~/${cluster}
   scp -p /usr/local/bin/oc bastion:/usr/local/bin
   scp -p /usr/local/bin/kubectl bastion:/usr/local/bin
}

get_status() {
    openshift-install --dir=$BASE_DIR/files/out wait-for \
        bootstrap-complete --log-level=debug
    openshift-install --dir=$BASE_DIR/files/out wait-for \
        install-complete --log-level=debug
}

# Process args
[ $# -lt 6 ] && usage          # Minimum is 2 params + value = 6
while [[ $# -gt 1 ]]
do
key="$1"
case $key in
    -h|--help)
    usage
    ;;
    -c|--cluster)
    cluster="$2"
    shift
    ;;
    -d|--domain)
    domain="$2"
    shift
    ;;
    -v|--ocp-vers)
    ocp_vers="$2"
    shift
    ;;
    -r|--rhcos-vers)
    rhcos_vers="$2"
    shift
    ;;
#   -w|--workers)
#   workers="$2"
#   shift
#   ;;
    *)

    ;;
esac
shift
done

if [ "$cluster" = "" -o "$domain" = "" -o "$ocp_vers" = "" ] ; then
    usage
fi

out "Time started: `date +%H:%M:%S`"

# Get RHCOS version from OCP version. Ex: For OCP 4.8.12, use RHCOS 4.8-latest
if [ X"$rhcos_vers" = X ] ; then
    get_proper_rhcos_vers $ocp_vers
fi

# Verify minimum requirements are met and download images & bins if needed
verify_env $domain $workers
download_images $rhcos_vers $ocp_vers
download_bins $ocp_vers
extract_bins $ocp_vers

# Create ignition files and move so PXE install process can use them
customize_install_config $domain $cluster
create_ignition_files
move_ignition_files

# Create VMs (boot from network) and monitor progress
# ask_continue "Continue with creating nodes?"
create_volumes $domain $workers
create_nodes $domain $workers $rhcos_vers $ocp_vers
monitor_vms $domain
copy_auth_to_bastion $cluster
get_status
out "Time finished: `date +%H:%M:%S`"

# 2022.02.14 22:07:54 - JD
