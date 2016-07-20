#!/usr/bin/env bash

function cleanup_from_previous_test() {
    echo "## Cleanup ##"

    echo "Destroying juju environment"
    juju destroy-environment --force -y manual

    VMS=$( sudo uvt-kvm list )
    for VM in $VMS
    do
      echo "Destroying $VM"
      sudo uvt-kvm destroy $VM
    done

    echo "Cleaning up files"
    rm -rf ~/.juju
    rm -f ~/.ssh/known_hosts
    rm -rf ~/openstack-cluster-setup

    echo "Cleaning up libvirt/dnsmasq"
    sudo rm -f /var/lib/libvirt/dnsmasq/xos-mgmtbr.leases
    sudo killall dnsmasq
    sudo service libvirt-bin restart
}

function bootstrap() {
    cd ~
    sudo apt-get update
    sudo apt-get -y install software-properties-common curl git mosh tmux dnsutils python-netaddr
    sudo add-apt-repository -y ppa:ansible/ansible
    sudo apt-get update
    sudo apt-get install -y ansible

    [ -e ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

    git clone https://github.com/girishgc/openstack-cluster-setup.git
    cd ~/openstack-cluster-setup
    git checkout $SETUP_BRANCH

    sed -i "s/replaceme/`whoami`/" $INVENTORY
    cp vars/example_keystone.yml vars/cord_keystone.yml

    # Log into the local node once to get host key
    ssh -o StrictHostKeyChecking=no localhost "ls > /dev/null"
}

function setup_openstack() {
    cd ~/openstack-cluster-setup

    extra_vars="xos_repo_url=$XOS_REPO_URL xos_repo_branch=$XOS_BRANCH"

    # check if running on cloudlab
    if [[ -x /usr/testbed/bin/mkextrafs ]]
    then
      extra_vars="$extra_vars on_cloudlab=True"
    fi

    ansible-playbook -i $INVENTORY cord-single-playbook.yml --extra-vars="$extra_vars" --ask-sudo-pass
}

function setup_xos() {

    ssh ubuntu@xos-1 "cd service-profile/cord-pod; make cord-subscriber"

    if [[ $EXAMPLESERVICE -eq 1 ]]
    then
      ssh ubuntu@xos-1 "cd service-profile/cord-pod; make exampleservice"
    fi

    echo ""
    echo "(Temp workaround for bug in Synchronizer) Pause 60 seconds"
    sleep 60
    ssh ubuntu@xos-1 "cd service-profile/cord-pod; make vtn"
}

function setup_test_client() {
    ssh ubuntu@nova-compute-1 "sudo apt-get -y install lxc"

    # Change default bridge
    ssh ubuntu@nova-compute-1 "sudo sed -i 's/lxcbr0/databr/' /etc/lxc/default.conf"

    # Create test client
    ssh ubuntu@nova-compute-1 "sudo lxc-create -t ubuntu -n testclient"
    ssh ubuntu@nova-compute-1 "sudo lxc-start -n testclient"

    # Configure network interface inside of test client with s-tag and c-tag
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- ip link add link eth0 name eth0.222 type vlan id 222"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- ip link add link eth0.222 name eth0.222.111 type vlan id 111"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- ifconfig eth0.222 up"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- ifconfig eth0.222.111 up"
}

function run_e2e_test() {
    source ~/admin-openrc.sh

    echo "*** Wait for vSG VM to come up"
    i=0

    until nova list --all-tenants|grep 'vsg.*ACTIVE' > /dev/null
    do
      sleep 60
      (( i += 1 ))
      echo "Waited $i minutes"
    done

    # get mgmt IP address
    ID=$( nova list --all-tenants|grep mysite_vsg|awk '{print $2}' )
    MGMTIP=$( nova interface-list $ID|grep 172.27|awk '{print $8}' )

    #Add the namserver to /etc/resolv.conf. Otherwise we dont have internet connectivity to pull the vCPE docker image
    ssh -o ProxyCommand="ssh -W %h:%p ubuntu@nova-compute-1" ubuntu@$MGMTIP "sudo sh -c 'echo \"nameserver $NAMESERVER\" > /etc/resolv.conf'"

    echo ""
    echo "*** ssh into vsg VM, wait for Docker container to come up"
    i=0
    until ssh -o ProxyCommand="ssh -W %h:%p ubuntu@nova-compute-1" ubuntu@$MGMTIP "sudo docker ps|grep vcpe" > /dev/null
    do
      sleep 60
      (( i += 1 ))
      echo "Waited $i minutes"
      if [ $i -gt 4 ]
      then
	 ssh -o ProxyCommand="ssh -W %h:%p ubuntu@nova-compute-1" ubuntu@MGMTIP "sudo sh -c 'echo \"nameserver $NAMESERVER\" > /etc/resolv.conf'"
      fi
    done

    echo ""
    echo "*** Run dhclient in test client"

    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- dhclient eth0.222.111" > /dev/null

    echo ""
    echo "*** Routes in test client"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- route -n"

    echo ""
    echo "*** Test external connectivity in test client"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- sudo apt-get install curl -y"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- curl www.google.com"

    echo ""
    if [ $? -eq 0 ]
    then
      echo "*** [PASSED] End-to-end connectivity test"
    else
      echo "*** [FAILED] End-to-end connectivity test"
      exit 1
    fi
}

function run_exampleservice_test () {
    source ~/admin-openrc.sh

    echo "*** Wait for exampleservice VM to come up."
    echo "!!! NOTE that currently the VM will only be created after you login"
    echo "!!! to XOS and manually create an ExampleService tenant."
    i=0
    until nova list --all-tenants|grep exampleservice.*ACTIVE > /dev/null
    do
      sleep 60
	    (( i += 1 ))
	    echo "Waited $i minutes"
    done

    # get mgmt IP address
    ID=$( nova list --all-tenants|grep mysite_exampleservice|awk '{print $2}' )
    MGMTIP=$( nova interface-list $ID|grep 172.27|awk '{print $8}' )
    PUBLICIP=$( nova interface-list $ID|grep 10.168|awk '{print $8}' )

    echo ""
    echo "*** ssh into exampleservice VM, wait for Apache come up"
    i=0
    until ssh -o ProxyCommand="ssh -W %h:%p ubuntu@nova-compute-1" ubuntu@$MGMTIP "ls /var/run/apache2/apache2.pid"
    do
      sleep 60
      (( i += 1 ))
      echo "Waited $i minutes"
    done


    echo ""
    echo "*** Install curl in test client"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- apt-get -y install curl"

    echo ""
    echo "*** Test connectivity to ExampleService from test client"
    ssh ubuntu@nova-compute-1 "sudo lxc-attach -n testclient -- curl -s http://$PUBLICIP"
}

function run_diagnostics() {
    echo "*** COLLECTING DIAGNOSTIC INFO - check ~/diag-* on the head node"
    ansible-playbook -i $INVENTORY cord-diag-playbook.yml --ask-sudo-pass
}

# Parse options
NAMESERVER=172.24.100.50
RUN_TEST=0
EXAMPLESERVICE=0
SETUP_BRANCH="master"
INVENTORY="inventory/single-localhost"
XOS_BRANCH="master"
XOS_REPO_URL="https://gerrit.opencord.org/xos"
DIAGNOSTICS=0

while getopts "b:dehi:r:ts:" opt; do
  case ${opt} in
    b ) XOS_BRANCH=$OPTARG
      ;;
    d ) DIAGNOSTICS=0
      ;;
    e ) EXAMPLESERVICE=1
      ;;
    h ) echo "Usage:"
      echo "    $0                install OpenStack and prep XOS and ONOS VMs [default]"
      echo "    $0 -b <branch>    build XOS containers using the <branch> branch of XOS git repo"
      echo "    $0 -d             don't run diagnostic collector"
      echo "    $0 -e             add exampleservice to XOS"
      echo "    $0 -h             display this help message"
      echo "    $0 -i <inv_file>  specify an inventory file (default is inventory/single-localhost)"
      echo "    $0 -r <url>       use <url> to obtain the the XOS repo"
      echo "    $0 -t             do install, bring up cord-pod configuration, run E2E test"
      echo "    $0 -s <branch>    use branch <branch> of the openstack-cluster-setup git repo"
      exit 0
      ;;
    i ) INVENTORY=$OPTARG
      ;;
    r ) XOS_REPO_URL=$OPTARG
      ;;
    t ) RUN_TEST=1
      ;;
    s ) SETUP_BRANCH=$OPTARG
      ;;
    \? ) echo "Invalid option: -$OPTARG"
      exit 1
      ;;
  esac
done

# What to do
if [[ $RUN_TEST -eq 1 ]]
then
  cleanup_from_previous_test
  echo "cleanup done"
fi

set -e

bootstrap
setup_openstack

if [[ $RUN_TEST -eq 1 ]]
then
  setup_xos
  setup_test_client
  run_e2e_test
  if [[ $EXAMPLESERVICE -eq 1 ]]
  then
    run_exampleservice_test
  fi
fi

if [[ $DIAGNOSTICS -eq 1 ]]
then
  run_diagnostics
fi

exit 0

