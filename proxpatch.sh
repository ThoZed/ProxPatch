#!/bin/bash

#The MIT License (MIT)
#
#Copyright (c) 2017 Thomas Zanft
#
#Permission is hereby granted, free of charge, to any person obtaining a copy
#of this software and associated documentation files (the "Software"), to deal
#in the Software without restriction, including without limitation the rights
#to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the Software is
#furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in all
#copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#SOFTWARE.

#Proxpatch.sh - Summary
# proxpatch is used to upgrade your proxmox nodes with apt-get upgrade while taking care the cluster(proxmox + ceph) stays available.
# in general folllowing sequence is applied:
# check prerequisites - cluster health, HA group assignment
# set ceph maintenance mode - patch cluster node by node and take care that the running vms are migrated to an other node

#Prerequisites
# - use a separate management machine to spin the script (dont use a proxmox clusternode!)
# - setup ssh trust between clusternodes an management machine.
# - fill in your node Information in proxpatch.cfg
#	 CLUSTER=[clustername]
#    NODES=[amount of nodes]
#    NODE1_IP=[IP Address]
#    NODE1_USER=[Proxmox admin user]
#    NODE1_NAME=[Proxmox node name]
#    NODE1_HAPRIOGRP=[name HA Prio Group]
#    NODE2_IP=[IP Address]
#    NODE2_USER=[Proxmox admin user]
#	 ....
#    NODE[n]_IP=[amount of nodes]
#    NODE[n]_USER=[Proxmox admin user]
#    NODE[n]_NAME=[Proxmox node name]
#    NODE[n]_HAPRIOGRP=[name HA Prio Group]
# - every running machine has to be assigned to an HA Group
# - there must be a ha group for each Cluster node which priorize that Node
# - priorize node1 in HA Group for node1 like this : node1:3,node2:2,node3:2
# - ceph Pool size has to be setup to tolerate a node shutdown (eg. size 2/1)

# include config file
source ./proxpatch.cfg

#build config array
function readconfig() {

echo " - read config file .\proxpatch.cfg"
declare -g -A PVE
num_rows=$NODES
num_columns=4

for ((i=1;i<=num_rows;i++)) do
        IP="NODE${i}_IP"
		USER="NODE${i}_USER"
		NAME="NODE${i}_NAME"
		HAGRP="NODE${i}_HAPRIOGRP"
		PVE[$i,1]=${!IP}
		PVE[$i,2]=${!USER}
		PVE[$i,3]=${!NAME}
		PVE[$i,4]=${!HAGRP}
done

}
#function to test config
function showconfig() {

echo "following nodes found:"

f1="%$((${#num_rows}+1))s"
f2=" %s"

for ((j=1;j<=$NODES;j++)) do
    printf "Node${j}"
    for ((i=1;i<=num_columns;i++)) do
        printf "$f2" ${PVE[$j,$i]}
    done
    echo
done

}

# get quorum from ha-manager status
function quorum() {

local nodename=$1

local PVE_State=$(ssh root@$nodename ha-manager status | grep "quorum" | awk '{print $2}')
if [[ $PVE_State -eq "OK" ]]
then
return 0
else
return 1
fi
}

#function which waits for quorum within defined timeout
function waitforquorum () {

local processednode=$1
local try=0
local interval=3
local timeout=240
local maxtries=$(($timeout / $interval))
local progress_footer=" - wait for Proxmox "



for ((m=1;m<=$NODES;m++)) do
	local node=${PVE[$m,1]}
	if ! [[ "$node" == "$processednode" ]]; then
		local runningnode=${PVE[$m,1]}
		m=$NODES+1
	fi
done

echo ""

while true; do
	
    quorum $runningnode > /dev/null
    if [ $? -eq 0 ]; then
		local progress_footer+=" ... Cluster is Quorate"
		echo -ne "$progress_footer"\\r
        return 0	
		break
	else
		local progress_footer+="."
		echo -ne "$progress_footer"\\r
	fi
	try=$((try+1))
	if [ $try = $maxtries ]; then
		echo "got timeout - break"
		return 1
		break
	fi
    sleep $interval
done
echo ""
}

# get all vms from cluster and put them into an array
function getvmlist () {

echo " - get vmlist from nodes"
declare -g -A VMS
declare -g VMCOUNT=0

for ((n=1;n<=$NODES;n++)); do
	local nodename=${PVE[$n,1]}
	local name=${PVE[$n,3]}
	local targets=($(ssh root@$nodename pvesh get /nodes/$name/qemu/ 2>/dev/null | grep "status\|vmid" | awk '{print $3}' ) );
	local length=${#targets[@]}
	local newvmmax=$(($VMCOUNT + $(($length / 2))))
	i=0
	for ((j=$VMCOUNT;j!=$newvmmax;j++)); do
		for ((k=0;k<=1;k++)); do
			pat="\"[a-z]*\","
			if [[ ${targets[$i]} =~ $pat ]]; then
					VMS[$j,$k]="$( echo "${targets[$i]}" | sed -e 's#^"##; s#",$##' )"
				else
					VMS[$j,$k]=${targets[$i]}
			fi	
			i=$((i+1))
		done
		VMCOUNT=$((VMCOUNT+1))
	done
done
}

# function which waits till an given amount of vms in reached on a Node 
function waitforvmamount () {

local nodename=$1
local name=$2
local desiredamount=$3

local try=0
local interval=3
local timeout=300
local maxtries=$(($timeout / $interval))

echo " - wait until Node $nodename has $desiredamount vms"

while true; do
	local amount=$(countrunningvmsonnode $nodename $name)
	local progress_footer=" - vms: amount/desired $amount/$desiredamount "
    if [ $amount -eq $desiredamount ]; then
		local progress="$progress finished"
		progress_footer=$(echo -ne "$progress_footer $progress" )
		echo -ne "$progress_footer" \\r
        break
		return 0
    else
	local progress="$progress."
	progress_footer=$(echo -ne "$progress_footer $progress" )
	echo -ne "$progress_footer" \\r
	fi
	try=$((try+1))
	if [ $try = $maxtries ]; then
		echo "got timeout - break"
		return 1
		break
	fi
    sleep $interval
done

}

# test if every running vm is assigned to an ha group
function runningvmshagroupmember(){

local nodename=$1

local resources=$(ssh root@$nodename "cat /etc/pve/ha/resources.cfg")

for ((j=0;j!=$VMCOUNT;j++)); do
	if [ ${VMS[$j,0]} == "running" ]; then
		local vm=${VMS[$j,1]}
		if [[ "$resources" =~ "$vm" ]]; then
			VMS[$j,2]=$(echo "$resources" | grep -F -A 1 "$vm" | grep "group" | awk '{print $2}')
			else
			echo "at least one running vm without ha group found - exit - vm: $vm"
			local haerror="TRUE"
		fi
	fi
done

if [[ "$haerror" == "TRUE" ]]; then
	return 1
	echo "ha error found"
else
	return 0
	echo "ha okay"
fi
			#VMS[$j,2]="$(ssh root@${PVE[1,3]} grep -F -A 1 "vm: ${VMS[$j,1]}" /etc/pve/ha/resources.cfg | grep "group" | awk \'{print $2}\')"
}

#show vmslist from array
function showvms() {

echo "show vmlist"

echo "vmcount: $VMCOUNT"

f1="%$((${#num_rows}+1))s"
f2=" %s"

for ((j=0;j!=$VMCOUNT;j++)) do
    printf "vm${j}"
    for ((i=0;i!=3;i++)) do
        printf "$f2" ${VMS[$j,$i]}
    done
	echo " "
done

}

#count vms on specific node
function countrunningvmsonnode() {

local nodename=$1
local name=$2
local vmsonnode=($(ssh root@$nodename pvesh get /nodes/$name/qemu/ 2>/dev/null | grep "status\|vmid" | awk '{print $3}' ) );

local count=0

length=${#vmsonnode[@]}
pat="\"running\","

for ((j=0;j!=$length;j++)); do
	if [[ ${vmsonnode[$j]} =~ $pat ]]; then
		(( count++ ))
	fi	
done
echo $count
}

#unpriorize Node to initiate the migration
function unpriorizegroup() {

local nodename=$1
local name=$2
local groupsetnodes=""
local targetnodehagrp=""

for ((j=1;j<=$NODES;j++)) do
	if [ ${PVE[$j,3]} == $name ]; then
		targetnodehagrp=${PVE[$j,4]}
		groupsetnodes+="${PVE[$j,3]}:1,"
		else
		groupsetnodes+="${PVE[$j,3]}:2,"
    fi
done

groupsetnodes=${groupsetnodes%?}

ssh root@$nodename ha-manager groupset $targetnodehagrp -nodes "\"$groupsetnodes\""

# ha-manager groupset grp_prio_prox03 -nodes "ag-prox03:1,ag-prox01:2,ag-prox02:2"
# ha-manager groupset grp_prio_prox02 -nodes "ag-prox03:2,ag-prox01:2,ag-prox02:1"
# ha-manager groupset grp_prio_prox01 -nodes "ag-prox03:2,ag-prox01:1,ag-prox02:2"
}

#restore priority on ha group 
function repriorizegroup() {

local nodename=$1
local name=$2
local groupsetnodes=""
local targetnodehagrp=""

for ((j=1;j<=$NODES;j++)) do
	if [ ${PVE[$j,3]} == $name ]; then
		targetnodehagrp=${PVE[$j,4]}
		groupsetnodes+="${PVE[$j,3]}:3,"
		else
		groupsetnodes+="${PVE[$j,3]}:2,"
    fi
done

groupsetnodes=${groupsetnodes%?}


ssh root@$nodename ha-manager groupset $targetnodehagrp -nodes "\"$groupsetnodes\""

# ha-manager groupset grp_prio_prox03 -nodes "ag-prox03:3,ag-prox01:2,ag-prox02:2"
# ha-manager groupset grp_prio_prox02 -nodes "ag-prox03:2,ag-prox01:2,ag-prox02:3"
# ha-manager groupset grp_prio_prox01 -nodes "ag-prox03:2,ag-prox01:3,ag-prox02:2"
}

#get ceph status from ceph health
function ceph_status() {

local nodename=$1
local cephstatus=$(ssh root@$nodename ceph health)
echo "$cephstatus"
if [[ $cephstatus == "HEALTH_OK" ]]; then
	return 0
else
	if [[ $cephstatus == "HEALTH_WARN noout flag(s) set" ]]; then
		echo "Ceph in Maintenance Mode - $cephstatus"
		return 2
	else
		echo "Ceph Problem - please fix it first - $cephstatus"
		return 1
	fi
fi	
	
#HEALTH_OK		
		
#HEALTH_WARN noout flag(s) set

#HEALTH_WARN 348 pgs degraded; 77 pgs stuck unclean; 348 pgs undersized; recovery 197859/581020 objects degraded (34.054%); 4/12 in osds are down; noout flag(s) set; 1 mons down, quorum 0,2 0,2

}

#wait till ceph is in maintenance mode
function ceph_waitformaintenance () {

local processednode=$1
local try=0
local interval=3
local timeout=120
local maxtries=$(($timeout / $interval))
local progress_footer=" - wait for Ceph "

for ((m=1;m<=$NODES;m++)) do
	local node=${PVE[$m,3]}
	if ! [[ "$node" == "$processednode" ]]; then
		local runningnode=${PVE[$m,3]}
		m=$NODES+1
	fi
done
echo ""

while true; do
    ceph_status $runningnode > /dev/null
	if [ $? -eq 2 ]; then
		local progress_footer+="... Ceph is in Maintenance Mode"
		echo -ne "$progress_footer"\\r
		echo ""
        return 0	
		break
	else
		local progress_footer+="."
		echo -ne "$progress_footer"\\r
	fi
	try=$((try+1))
	if [ $try = $maxtries ]; then
		echo "got timeout - break"
		return 1
		break
	fi
    sleep $interval
done
echo ""
}

#wait till ceph is in ok mode
function ceph_waitforok () {

local processednode=$1
local try=0
local interval=3
local timeout=120
local maxtries=$(($timeout / $interval))
local progress_footer=" - wait for Ceph "

for ((m=1;m<=$NODES;m++)) do
	local node=${PVE[$m,3]}
	if ! [[ "$node" == "$processednode" ]]; then
		local runningnode=${PVE[$m,3]}
		m=$NODES+1
	fi
done

echo ""

while true; do
    ceph_status $runningnode > /dev/null
	if [ $? -eq 0 ]; then
		local progress_footer+="... Ceph is in Maintenance Mode"
		echo -ne "$progress_footer"\\r
        return 0	
		break
	else
		local progress_footer+="."
		echo -ne "$progress_footer"\\r
	fi
	try=$((try+1))
	if [ $try = $maxtries ]; then
		echo "got timeout - break"
		return 1
		break
	fi
    sleep $interval
done

}

#set noout
function ceph_setnoout() {
# ssh root@$HOST ls

local nodename=$1

ssh root@$nodename ceph osd set noout

}

#unset noout
function ceph_unsetnoout() {

#ceph osd unset noout
local nodename=$1

ssh root@$nodename ceph osd unset noout

}

# apt-get update on specific node
function updatenode() {

local nodename=$1

echo " - update node $nodename" 
if ! { ssh root@$nodename apt-get update 2>&1 > /dev/null  || echo E: update failed; } | grep -q '^[WE]:'; then
	return 0
else
	return 1
fi

}

#apt-get upgrade on specific node check apt-get process to determine when upgrade job is done
function upgradenode() {

local try=0
local interval=10
local timeout=300
local maxtries=$(($timeout / $interval))
local progress_footer=" - wait for apt-get upgrade "

local nodename=$1
local upgrade_pid=""

upgrade_pid=$(ssh root@$nodename -t -t ' apt-get upgrade -y --force-yes -qq ; echo $$ ')

while true; do

ssh root@$nodename test -e "/proc/$upgrade_pid" > /dev/null
#   ssh root@$nodename "bash -c 'kill -0 $upgrade_pid'" < /dev/null
	if [ $? -eq 1 ]; then
		local progress_footer+="... finished"
		echo -ne "$progress_footer"\\r
		break
	else
		local progress_footer+="."
		echo -ne "$progress_footer"\\r
	fi
	try=$((try+1))
	if [ $try = $maxtries ]; then
		echo "got timeout - break"
		return 1
		break
	fi
    sleep $interval
done
}

#reboot node - wait until it is online again
function rebootnode() {

local try=0
local interval=3
local timeout=240
local maxtries=$(($timeout / $interval))

local nodename=$1

echo ""
echo " - reboot Node"
local progress_footer=" - wait for Node online "

ssh -o "ServerAliveInterval 1" root@$nodename -t -t 'shutdown -r now' > /dev/null 2>&1

while true; do
	ping -c 3 $nodename > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		echo " - Node is down"
		try=0
		while true; do
			ping -c 3 $nodename > /dev/null 2>&1
			if [ $? -ne 1 ]; then
				local progress_footer+="... finished"
				echo -ne "$progress_footer"\\r
				return 0
				break
			else
				local progress_footer+="."
				echo -ne "$progress_footer"\\r
			fi
			try=$((try+1))
			if [ $try = $maxtries ]; then
				echo "got offline timeout - break"
				return 1
				break
			fi
			sleep $interval
		done
	
	fi
	try=$((try+1))
	if [ $try = $maxtries ]; then
		echo "got shutdown timeout - break"
		return 1
		break
	fi
    sleep $interval
done


}

# put all functions together to upgrade the whole cluster node by node
function upgradecluster() {

echo "Ceph - set noout for maintenance"
ceph_setnoout ${PVE[1,1]}

for ((n=1;n<=$NODES;n++)) do
	echo "starting with Node: ${PVE[$n,3]}"
	PVE[$n,5]=$(countrunningvmsonnode ${PVE[$n,1]} ${PVE[$n,3]})
	echo " - running vms on Node: ${PVE[$n,5]}"
	unpriorizegroup ${PVE[$n,1]} ${PVE[$n,3]}
	echo " - change Prio for HA Group: ${PVE[$n,4]}"
	if ! waitforvmamount ${PVE[$n,1]} ${PVE[$n,3]} "0" ; then
		exit 1
	fi
	echo ""
	if [[ $(countrunningvmsonnode ${PVE[$n,1]} ${PVE[$n,3]}) == "0" ]]; then
		echo " - upgrade and reboot Node"
		if ! updatenode ${PVE[$n,1]} ; then
			echo "update failed"
			exit 1
		fi
		if ! upgradenode ${PVE[$n,1]} ; then
			echo "upgrade failed"
			exit 1
		fi
		if ! rebootnode ${PVE[$n,1]} ; then
			echo "reboot failed"
			exit 1
		fi
	else
		echo " - migration failed"
		exit 1
	fi
	if ! waitforquorum	${PVE[$n,1]} ; then
		exit 1
	fi
	if ! ceph_waitformaintenance ${PVE[$n,1]} ; then
		exit 1
	fi
	repriorizegroup ${PVE[$n,1]} ${PVE[$n,3]}
	echo " - change Prio for HA Group: ${PVE[$n,4]}"
	if ! waitforvmamount ${PVE[$n,1]} ${PVE[$n,3]} ${PVE[$n,5]} ; then
		exit 1
	fi
	echo ""
	echo "Node ${PVE[$n,3]} finished"
done
ceph_unsetnoout ${PVE[1,1]}
ceph_waitforok ${PVE[1,1]}
echo ""
echo "Proxpatch - Proxmox/Ceph Cluster up to date!"
echo ""
}

#do pre checks

echo ""
echo "Proxpatch - Proxmox/Ceph Clusterupdater"
echo ""
# read config file from ./proxpatch.cfg
# maybe verify it with a new function
readconfig

# check proxmox cluster
if quorum ${PVE[1,3]} >/dev/null ; then
	echo " - proxmox okay"
	else
	echo " - proxmox not ready for upgrade"
	exit 1
fi

#check ceph status
if ceph_status ${PVE[1,3]} >/dev/null ; then 
	echo " - ceph status okay"
	else
	echo " - ceph not ready for upgrade"
	exit 1
fi

# get running vms
getvmlist

# check ha group membership of vms
if runningvmshagroupmember ${PVE[1,1]} >/dev/null ; then
	echo " - every running vm is assigned to an HA Group"
	else
	hastatus=$(runningvmshagroupmember)
	echo " - check for HA assignment failed - $hastatus"
	exit 1
fi

echo ""
echo "......... Prerequisit check passed ........."
echo ""
echo ""
echo "Proxpatch - Proxmox/Ceph Clusterupdater"
echo ""

# Show menue
PS3='Please enter your choice: '
options=("show config" "show vmlist" "start cluster upgrade" "Quit")
select opt in "${options[@]}"
do
    case $opt in
        "show config")
			showconfig
            ;;
        "show vmlist")
            showvms
            ;;
        "start cluster upgrade")
            upgradecluster
            ;;
		"Quit")
            break
            ;;
        *) echo invalid option;;
    esac
done


