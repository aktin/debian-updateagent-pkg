#!/bin/bash

server_user="root"
server_ip="192.168.122.50"
host="$server_user@$server_ip"
ctl="$HOME/.ssh/cm-%r@%h:%p"

ssh_start() {
  lifespan=${1:-"5m"}
  ssh -o ControlMaster=auto -o ControlPersist="$lifespan" -o ControlPath="$ctl" -Nf "$host"
}

ssh_end() {
  ssh -O exit -o ControlPath="$ctl" "$host"
}

ssh_copy() {
  scp -o ControlPath="$ctl" "$1" "$host:/tmp/"
}

ssh_command() {
  ssh -o ControlPath="$ctl" "$host" "$1"
}


# build debian package
./src/debian/build.sh --cleanup

# get last created debian package
deb=$(find . -name "aktin-notaufnahme-updateagent*.deb" -printf "%T@ %p\n" | sort -nr | head -n1 | cut -d' ' -f2-)

# execution pipeline
ssh_start
ssh_copy "$deb"
ssh_command "sudo apt remove -y aktin-notaufnahme-updateagent || true"
ssh_command "sudo apt purge -y aktin-notaufnahme-updateagent || true"
ssh_command "sudo dpkg -i /tmp/$(basename $deb)"
ssh_end