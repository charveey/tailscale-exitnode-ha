#!/bin/bash

# Edit These Variables
###########################################################
# Internet test IP
inettestip=8.8.8.8
# Prioritized list of exit node tailscale IPs (separated by spaces)
exitnodes=("100.85.214.5" "100.95.202.15")  # Add your exit nodes
# Set to false to never remove exit node even if all are down
failopen=false  
# Other tailscale flags
flags="--accept-routes"
# Log file location
logfile="/var/log/tailscale-failover.log"
############################################################

# Redirect output to log file and console
exec > >(tee -a "$logfile")
exec 2>&1

#<====== Functions ======>
function set_exit_node () {
    check_current_exit_node
    if [ "$1" == "false" ] && [ "$curexitnode" != "false" ] && [ "$failopen" == "true" ]; then
        echo "No best exit node, removing exit node..."
        sudo tailscale up $flags --reset
        test_icmp $inettestip
        if $icmp; then
            echo "ICMP to $inettestip is working with exit node removed."
        else
            echo "ICMP to $inettestip is not working with exit node removed. Local Internet issue."
        fi
    elif [ "$1" == "false" ] && [ "$curexitnode" != "false" ] && [ "$failopen" == "false" ]; then
        echo "There are no working exit nodes but fail open is false so keeping current exit node $curexitnode."
    elif [ "$1" != "false" ] && [ "$curexitnode" != "$1" ]; then
        echo "Setting exit node to $1..."
        sudo tailscale up --exit-node=$1 --exit-node-allow-lan-access $flags
        sleep 3  # Give Tailscale time to establish connection
        check_current_exit_node
        if [ "$curexitnode" == "$1" ]; then
            echo "Current exit node successfully changed to $curexitnode."
            test_icmp $inettestip
            if $icmp; then
                echo "✓ ICMP to $inettestip is working via exit node $curexitnode."
                return 0
            else
                echo "✗ ERROR: ICMP to $inettestip is failing via exit node $curexitnode."
                return 1
            fi
        else
            echo "✗ ERROR: Unable to change exit node. Current exit node is $curexitnode."
            return 1
        fi
    else
        echo "Already using best exit node $curexitnode."
        return 0
    fi
}

function test_icmp () {
    local test_ip=$1
    local ping_output=$(mktemp)
    
    ping $test_ip -c 4 -W 2 > "$ping_output" 2>&1
    count=$(grep "bytes from $test_ip" "$ping_output" | wc -l)
    
    if [ $count -gt 0 ]; then
        echo "  → $test_ip is ICMP reachable ($count/4 packets received)."
        icmp=true
    else
        echo "  → $test_ip is ICMP unreachable."
        icmp=false
    fi
    
    rm -f "$ping_output"
}

function check_exit_node () {
    local node=$1
    echo "Checking exit node $node..."
    
    # First check if this node is online in tailscale
    if ! tailscale status | grep -q "$node"; then
        echo "  → $node is not visible in tailscale network."
        goodenode=false
        return
    fi
    
    # Temporarily switch to this node to test it
    local original_exit=$curexitnode
    sudo tailscale up --exit-node=$node --exit-node-allow-lan-access $flags >/dev/null 2>&1
    sleep 3
    
    test_icmp $inettestip
    
    if $icmp; then
        echo "  → $node is working properly."
        goodenode=true
    else
        echo "  → $node is not working."
        goodenode=false
        
        # Restore original exit node if test failed
        if [ "$original_exit" != "false" ] && [ "$original_exit" != "$node" ]; then
            sudo tailscale up --exit-node=$original_exit --exit-node-allow-lan-access $flags >/dev/null 2>&1
        fi
    fi
}

function check_current_exit_node () {
    # Use Tailscale JSON status for more reliable parsing
    local status_json=$(tailscale status --json 2>/dev/null)
    
    if [ -n "$status_json" ]; then
        curexitnode=$(echo "$status_json" | jq -r '.ExitNodeStatus.TailscaleIPs[0] // "false"')
        if [ "$curexitnode" == "null" ] || [ -z "$curexitnode" ]; then
            curexitnode="false"
        fi
    else
        # Fallback to grep method
        local enode_count=$(tailscale status | grep "; exit node" | grep -oE "^([0-9]{1,3}\.){3}[0-9]{1,3}" | wc -l)
        if [ $enode_count -gt 0 ]; then
            curexitnode=$(tailscale status | grep "; exit node" | grep -oE "^([0-9]{1,3}\.){3}[0-9]{1,3}")
        else
            curexitnode="false"
        fi
    fi
    
    # Strip CIDR notation if present (e.g., 100.85.214.5/32 -> 100.85.214.5)
    curexitnode=$(echo "$curexitnode" | cut -d'/' -f1)
}

function find_best_exit_node () {
    bestexitnode="false"
    
    for node in "${exitnodes[@]}"; do
        check_exit_node $node
        if $goodenode; then
            echo "✓ Best exit node is $node."
            bestexitnode=$node
            break
        else
            echo "✗ $node is offline or not working."
        fi
    done
    
    if [ "$bestexitnode" == "false" ]; then
        echo "⚠ WARNING: No exit nodes are online and capable of relaying traffic!"
    fi
}

#<====== Main program ======>
echo ""
echo "=============================="
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="

test_icmp $inettestip
check_current_exit_node

# Main logic
if $icmp && [ "$curexitnode" != "false" ]; then
    echo "✓ Internet is up using $curexitnode as exit node."
    
    # Check if we're using the best (highest priority) exit node
    if [ "$curexitnode" == "${exitnodes[0]}" ]; then
        echo "✓ Using primary exit node. All good."
    else
        echo "⚠ Not using primary exit node. Checking if primary is available..."
        find_best_exit_node
        
        if [ "$bestexitnode" != "$curexitnode" ] && [ "$bestexitnode" != "false" ]; then
            echo "→ Switching to better exit node: $bestexitnode"
            set_exit_node $bestexitnode
        fi
    fi
    
elif $icmp && [ "$curexitnode" == "false" ]; then
    echo "⚠ Internet is up but not using an exit node. Finding exit node..."
    find_best_exit_node
    set_exit_node $bestexitnode
    
elif [ $icmp == false ] && [ "$curexitnode" != "false" ]; then
    echo "✗ Internet is down using exit node $curexitnode. Looking for alternatives..."
    find_best_exit_node
    
    if [ "$bestexitnode" != "false" ]; then
        set_exit_node $bestexitnode
    else
        echo "⚠ All exit nodes failed. Keeping current configuration."
    fi
    
elif [ $icmp == false ] && [ "$curexitnode" == "false" ]; then
    echo "✗ Internet is down and no exit node configured. Local Internet issue or finding first working exit node..."
    find_best_exit_node
    if [ "$bestexitnode" != "false" ]; then
        set_exit_node $bestexitnode
    fi
fi

# Final status check
echo ""
echo "--- Final Status ---"
check_current_exit_node
test_icmp $inettestip

if $icmp && [ "$curexitnode" != "false" ]; then
    echo "✓ System operational: Using exit node $curexitnode"
elif [ "$curexitnode" != "false" ]; then
    echo "⚠ Using exit node $curexitnode but internet check failed"
else
    echo "✗ No exit node configured"
fi

echo "=============================="
echo ""