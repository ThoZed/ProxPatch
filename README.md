![proxpatch - proxmox](https://user-images.githubusercontent.com/1869080/28519913-b1429d2a-706d-11e7-83cf-e1369b5e923f.gif)


# Proxpatch
## Proxmox-/Ceph Clusterupdater

### Proxpatch.sh - Summary
- proxpatch is used to upgrade your proxmox nodes with apt-get upgrade while taking care the cluster(proxmox + ceph) stays available.
- in general folllowing sequence is applied:
  - check prerequisites - cluster health, HA group assignment
  - set ceph maintenance mode - patch cluster node by node and take care that the running vms are migrated to an other node

### Prerequisites
- [x] use a separate management machine to spin the script (dont use a proxmox clusternode!)
- [x] setup ssh trust between clusternodes an management machine.
- [x] fill in your node Information in proxbatch.cfg
    - CLUSTER=[clustername]
    - NODES=[amount of nodes]
    - NODE1_IP=[IP Address]
    - NODE1_USER=[Proxmox admin user]
    - NODE1_NAME=[Proxmox node name]
    - NODE1_HAPRIOGRP=[name HA Prio Group]
    - NODE2_IP=[IP Address]
    - NODE2_USER=[Proxmox admin user]
	 ....
    - NODE[n]_IP=[amount of nodes]
    - NODE[n]_USER=[Proxmox admin user]
    - NODE[n]_NAME=[Proxmox node name]
    - NODE[n]_HAPRIOGRP=[name HA Prio Group]
- [x] every running machine has to be assigned to an HA Group
- [x] there must be a ha group for each Cluster node which priorize that Node
- [x] priorize node1 in HA Group for node1 like this : node1:3,node2:2,node3:2
- [x] ceph Pool size has to be setup to tolerate a node shutdown (eg. size 2/1)
