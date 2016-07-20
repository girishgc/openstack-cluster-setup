#!/bin/bash
filename=/var/lib/libvirt/dnsmasq/xos-mgmtbr.hostsfile

sudo echo "127.0.0.1       localhost" > /etc/hosts
sudo echo "::1     localhost ip6-localhost ip6-loopback" >> /etc/hosts
sudo echo "ff02::1 ip6-allnodes" >> /etc/hosts
sudo echo "ff02::2 ip6-allrouters" >> /etc/hosts

while read -r line
do
    name="$line"
    IFS=',' read -r -a hosts <<< $name
    echo "${hosts[1]} ${hosts[0]} ${hosts[0]::-2}.cord.lab" >> /etc/hosts
done < "$filename"
