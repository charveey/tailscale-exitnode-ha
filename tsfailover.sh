#!/bin/bash

# Edit These Variables
###########################################################
#internet test IP
inettestip=8.8.8.8
#prioritized list of exit node tailscale IPs (seperated by spaces)
exitnodes=("100.100.100.1" "100.100.100.2")
#set to false to never remove exit node even if all are down
failopen=true
#other tailscale flags, ie. "--advertise-routes=192.169.1.0/24"
flags=""
############################################################

#<====== Functions ======>
function set_exit_node () { #pass string with IP of desired exit node #return true/false for internet working on that exit node.
check_current_exit_node
if [ $1 == false ] && [ $curexitnode != false ] && [ $failopen == true ]; then
	echo "No best exit node, removing exit node..."
	sudo tailscale up  $flags --reset
	test_icmp $inettestip
	if $icmp; then
		echo "ICMP to $inettestip is working with exit node removed."
	else
		echo "ICMP to $inettestip is not working with exit node removed. Local Internet issue."
	fi
elif [ $1 == false ] && [ $curexitnode != false ] && [ $failopen == false ]; then
	echo "There are no working exit nodes but fail open is false so keeping bad exit node."
elif [ $1 != false ] && [ $curexitnode != $1 ]; then
	echo "Setting exit node to $1."
	sudo tailscale up --exit-node $1 --exit-node-allow-lan-access $flags
	check_current_exit_node
	if [ $curexitnode == $1 ]; then
		echo "Current exit node sucesfully changed to $curexitnode."
		test_icmp $inettestip
		if $icmp; then
			echo "ICMP to $inettestip is working via exit node $curexitnode."
		else
			echo "ERROR, ICMP to $inettestip is failing via exit node $curexitnode."
		fi
	else
		echo "ERROR, unable to change exit node. Current exit node is $curexitnode."
	fi
fi
}

function test_icmp () { #pass string with ip to test icmp #updates icmp variable with true/false
ping $1 -c 4 > ping.test
count=$(cat ping.test | grep "bytes from $1" --count)
#echo $count
if  [ $count -gt 0 ]; then
	echo "$1 is ICMP reachable."
	icmp=true
else
	echo "$1 is ICMP unreachable."
	icmp=false
fi
}

function check_exit_node () { #pass string with IP of exit node. #updates goodenode with true/false
echo "Checking $1 ..."
test_icmp $1
testenode=$(tailscale status | grep "exit node" | grep $1 --count)
if [ $testenode -gt 0 ] && $icmp ; then
    goodenode=true
else
    goodenode=false
fi
}

function check_current_exit_node () { #no input #returns ip of current exit node
														# ^ added to only get first IP on the line
enodeb=$(tailscale status | grep "; exit node" | grep -E "^(\b25[0-5]|\b2[0-4][0-9]|\b[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}" --count )
if [ $enodeb -gt 0 ]; then
	curexitnode=$(tailscale status | grep "; exit node" | grep -E "^(\b25[0-5]|\b2[0-4][0-9]|\b[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}" -o )
else
	curexitnode=false
fi
}

function find_best_exit_node () { #no input #returns ip of best working exit node
bestexitnode=false
for node in "${exitnodes[@]}"
do
check_exit_node $node
if $goodenode; then
	echo "the best exit node is $node."
	bestexitnode=$node
	break
else
	echo "$node is offline, or not configured to be an exit node."
fi
done
if [ $bestexitnode == false ]; then
	echo "No exit nodes are online and capable of relaying traffic."
fi
}



#<====== Main program ======>
test_icmp $inettestip
check_current_exit_node

#if block for internet ICMP working
if $icmp && [ $curexitnode != false ]; then
	echo "Internet is up using $curexitnode as an exit node."
	find_best_exit_node
	if [ $bestexitnode == $curexitnode ]; then
		echo "The current exit node is the best exit node."
	elif [ $bestexitnode != false ]; then
		echo "The current exit node is not the best exit node. Switch to best exit node $bestexitnode."
		set_exit_node $bestexitnode
	else 
		echo "all exit nodes are down."
	fi
elif $icmp && [ $curexitnode == false ]; then
	echo "Internet is up but not using an exit node."
	find_best_exit_node
	set_exit_node $bestexitnode
fi

#check again to see if anything changed after first if block
check_current_exit_node
test_icmp $inettestip
#if block for ICMP not working
if [ $icmp == false ] && [ $curexitnode == false ]; then
	echo "Internet is down and there is not an exit node. Local Internet issue."
elif [ $icmp == false ] && [ $curexitnode != false ]; then
	echo "Internet is down using exit node $curexitnode. Looking for other exit nodes..."
	find_best_exit_node
	set_exit_node $bestexitnode
elif [ $icmp == true ] && [ $curexitnode == false ]; then
	echo "Internet is working without an exit node."
fi
