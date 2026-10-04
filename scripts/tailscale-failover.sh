#!/bin/bash
set -u

# Akwaba is the director behind the client-facing Oracle gateway.
# "local" means: do NOT use a Tailscale exit node; send traffic directly
# from Akwaba's own WAN connection.
#
# Priority is evaluated left-to-right. With the default below:
#   1. Akwaba local Internet
#   2. Stray
#   3. Add future Tailscale exit-node IPs after Stray
#
# IMPORTANT: "local" must never be replaced by Akwaba's own 100.x address.
# Doing that would create a Tailscale exit-node loop.

# Edit These Variables
###########################################################
inettestip=8.8.8.8

# "local" = Akwaba itself; everything else is a Tailscale exit-node IP/name.
exitnodes=("local" "100.85.214.5" "100.95.202.15")

# If false, keep the last working upstream when all candidates fail.
# If true, fall back to Akwaba local Internet when all Tailscale candidates fail.
failopen=true

# Other Tailscale flags
flags="--accept-routes"
logfile="/var/log/tailscale-failover.log"
############################################################

exec > >(tee -a "$logfile")
exec 2>&1

function set_local_exit () {
    echo "Setting Akwaba to local Internet egress (no Tailscale exit node)..."
    sudo tailscale set --exit-node=
    sleep 2
    check_current_exit_node

    if [ "$curexitnode" == "local" ]; then
        test_icmp "$inettestip"
        if $icmp; then
            echo "✓ Akwaba local Internet egress is working."
            return 0
        fi
    fi

    echo "✗ Akwaba local Internet egress is not working."
    return 1
}

function set_exit_node () {
    local target="$1"
    check_current_exit_node

    if [ "$target" == "local" ]; then
        if [ "$curexitnode" == "local" ]; then
            echo "Already using Akwaba local Internet egress."
            return 0
        fi
        set_local_exit
        return $?
    fi

    if [ "$curexitnode" == "$target" ]; then
        echo "Already using exit node $target."
        return 0
    fi

    echo "Setting upstream exit node to $target..."
    sudo tailscale set --exit-node="$target" --exit-node-allow-lan-access=true $flags
    sleep 3
    check_current_exit_node

    if [ "$curexitnode" == "$target" ]; then
        echo "Current upstream exit node successfully changed to $curexitnode."
        test_icmp "$inettestip"
        if $icmp; then
            echo "✓ ICMP to $inettestip is working via upstream exit node $curexitnode."
            return 0
        fi
        echo "✗ ERROR: ICMP to $inettestip is failing via exit node $curexitnode."
        return 1
    fi

    echo "✗ ERROR: Unable to change exit node. Current exit node is $curexitnode."
    return 1
}

function test_icmp () {
    local test_ip="$1"
    local ping_output
    ping_output=$(mktemp)

    ping "$test_ip" -c 4 -W 2 > "$ping_output" 2>&1
    local count
    count=$(grep -c "bytes from $test_ip" "$ping_output" || true)

    if [ "$count" -gt 0 ]; then
        echo "  → $test_ip is ICMP reachable ($count/4 packets received)."
        icmp=true
    else
        echo "  → $test_ip is ICMP unreachable."
        icmp=false
    fi

    rm -f "$ping_output"
}

function check_exit_node () {
    local node="$1"
    echo "Checking candidate $node..."

    if [ "$node" == "local" ]; then
        # If already local, simply test it.
        if [ "$curexitnode" == "local" ]; then
            test_icmp "$inettestip"
            goodenode=$icmp
            return
        fi

        # Temporarily move from the current Tailscale exit to local Internet.
        # If local fails, restore the original upstream exit.
        local original_exit="$curexitnode"
        sudo tailscale set --exit-node= >/dev/null 2>&1
        sleep 2
        check_current_exit_node
        test_icmp "$inettestip"

        if $icmp; then
            echo "  → Akwaba local Internet is working."
            goodenode=true
            return
        fi

        echo "  → Akwaba local Internet is not working."
        goodenode=false

        if [ "$original_exit" != "local" ] && [ "$original_exit" != "false" ]; then
            sudo tailscale set --exit-node="$original_exit" --exit-node-allow-lan-access=true $flags >/dev/null 2>&1
            sleep 2
        fi
        return
    fi

    # Check that the upstream node is visible in the tailnet.
    if ! tailscale status | grep -q "$node"; then
        echo "  → $node is not visible in the Tailscale network."
        goodenode=false
        return
    fi

    local original_exit="$curexitnode"
    sudo tailscale set --exit-node="$node" --exit-node-allow-lan-access=true $flags >/dev/null 2>&1
    sleep 3

    test_icmp "$inettestip"

    if $icmp; then
        echo "  → $node is working properly."
        goodenode=true
    else
        echo "  → $node is not working."
        goodenode=false

        if [ "$original_exit" == "local" ]; then
            sudo tailscale set --exit-node= >/dev/null 2>&1
        elif [ "$original_exit" != "false" ] && [ "$original_exit" != "$node" ]; then
            sudo tailscale set --exit-node="$original_exit" --exit-node-allow-lan-access=true $flags >/dev/null 2>&1
        fi
        sleep 2
    fi
}

function check_current_exit_node () {
    local status_json
    status_json=$(tailscale status --json 2>/dev/null || true)

    if [ -n "$status_json" ]; then
        curexitnode=$(echo "$status_json" | jq -r '.ExitNodeStatus.TailscaleIPs[0] // "local"')
        if [ "$curexitnode" == "null" ] || [ -z "$curexitnode" ]; then
            curexitnode="local"
        fi
    else
        local enode_count
        enode_count=$(tailscale status | grep "; exit node" | grep -oE "^([0-9]{1,3}\.){3}[0-9]{1,3}" | wc -l)
        if [ "$enode_count" -gt 0 ]; then
            curexitnode=$(tailscale status | grep "; exit node" | grep -oE "^([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
        else
            curexitnode="local"
        fi
    fi

    curexitnode=$(echo "$curexitnode" | cut -d'/' -f1)
}

function find_best_exit_node () {
    bestexitnode="false"

    for node in "${exitnodes[@]}"; do
        check_current_exit_node
        check_exit_node "$node"

        if $goodenode; then
            echo "✓ Best exit candidate is $node."
            bestexitnode="$node"
            break
        else
            echo "✗ $node is offline or not working."
        fi
    done

    if [ "$bestexitnode" == "false" ]; then
        echo "⚠ WARNING: No working egress candidate was found!"
    fi
}

# Main
echo ""
echo "=============================="
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="

check_current_exit_node
test_icmp "$inettestip"

if $icmp; then
    echo "✓ Internet is currently up using $curexitnode."

    if [ "$curexitnode" == "${exitnodes[0]}" ]; then
        echo "✓ Using highest-priority egress candidate. All good."
    else
        echo "⚠ Not using the highest-priority egress candidate. Checking candidates..."
        find_best_exit_node

        if [ "$bestexitnode" != "false" ] && [ "$bestexitnode" != "$curexitnode" ]; then
            echo "→ Switching to better egress candidate: $bestexitnode"
            set_exit_node "$bestexitnode"
        fi
    fi
else
    echo "✗ Internet is down using $curexitnode. Looking for alternatives..."
    find_best_exit_node

    if [ "$bestexitnode" != "false" ]; then
        if [ "$bestexitnode" != "$curexitnode" ]; then
            echo "→ Switching to working egress candidate: $bestexitnode"
            set_exit_node "$bestexitnode"
        else
            echo "→ Current candidate is still selected but health check failed."
        fi
    elif [ "$failopen" == "true" ] && [ "$curexitnode" != "local" ]; then
        echo "→ failopen=true: falling back to Akwaba local Internet."
        set_exit_node local
    else
        echo "⚠ All egress candidates failed. Keeping current configuration."
    fi
fi

echo ""
echo "--- Final Status ---"
check_current_exit_node
test_icmp "$inettestip"

if $icmp; then
    echo "✓ System operational: egress=$curexitnode"
else
    echo "✗ Internet check failed: egress=$curexitnode"
fi

echo "=============================="
echo ""
