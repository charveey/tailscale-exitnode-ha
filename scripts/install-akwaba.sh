#!/bin/bash

# Akwaba (Director Node) Installation Script
# Run with: sudo ./install-akwaba.sh

set -e

echo "========================================"
echo "Akwaba (Director) Node Installation"
echo "========================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root or with sudo"
    exit 1
fi

# Install dependencies
echo "Installing dependencies..."
apt update
apt install -y wireguard wireguard-tools iptables net-tools jq curl

# Check if Tailscale is installed
if ! command -v tailscale &> /dev/null; then
    echo ""
    echo "Tailscale not found. Installing..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "✓ Tailscale already installed"
fi

# Generate WireGuard keys
echo ""
echo "Generating WireGuard keys..."
cd /etc/wireguard
umask 077

if [ -f akwaba-private.key ]; then
    echo "⚠ Keys already exist. Backing up..."
    cp akwaba-private.key akwaba-private.key.bak
    cp akwaba-public.key akwaba-public.key.bak
fi

wg genkey | tee akwaba-private.key | wg pubkey > akwaba-public.key

AKWABA_PRIVATE=$(cat akwaba-private.key)
AKWABA_PUBLIC=$(cat akwaba-public.key)

echo "✓ Keys generated"
echo ""
echo "SAVE THESE KEYS:"
echo "================"
echo "Akwaba Public Key: $AKWABA_PUBLIC"
echo "================"
echo ""
echo "⚠ You'll need to provide the Akwaba public key to Oracle!"
echo ""

read -p "Enter Oracle's public key: " ORACLE_PUBLIC

# Create WireGuard configuration
echo ""
echo "Creating WireGuard configuration..."

cat > /etc/wireguard/wg-exit.conf << EOF
[Interface]
PrivateKey = $AKWABA_PRIVATE
Address = 172.16.99.2/30
ListenPort = 51820
MTU = 1340
Table = off

PostUp = iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
PostUp = iptables -A FORWARD -i wg-exit -o tailscale0 -j ACCEPT
PostUp = iptables -A FORWARD -i tailscale0 -o wg-exit -j ACCEPT
PostUp = iptables -A INPUT -i wg-exit -j ACCEPT
PostUp = iptables -A OUTPUT -o wg-exit -j ACCEPT
PostUp = sysctl -w net.ipv4.ip_forward=1

PostDown = iptables -t nat -D POSTROUTING -o tailscale0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg-exit -o tailscale0 -j ACCEPT
PostDown = iptables -D FORWARD -i tailscale0 -o wg-exit -j ACCEPT
PostDown = iptables -D INPUT -i wg-exit -j ACCEPT
PostDown = iptables -D OUTPUT -o wg-exit -j ACCEPT

[Peer]
PublicKey = $ORACLE_PUBLIC
AllowedIPs = 172.16.99.1/32, 100.64.0.0/10
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg-exit.conf
echo "✓ WireGuard configured"

# Enable and start WireGuard
echo ""
echo "Enabling WireGuard..."
systemctl enable wg-quick@wg-exit
systemctl start wg-quick@wg-exit

# Wait a moment
sleep 2

# Check status
if systemctl is-active --quiet wg-quick@wg-exit; then
    echo "✓ WireGuard is running"
    wg show
else
    echo "❌ WireGuard failed to start"
    journalctl -u wg-quick@wg-exit -n 20
    exit 1
fi

# Get exit node IPs
echo ""
echo "Now let's configure your exit nodes."
echo "Enter the Tailscale IPs of your exit nodes in priority order."
echo "Press Enter with empty input when done."
echo ""

EXIT_NODES=()
INDEX=1
while true; do
    read -p "Exit node #$INDEX (or press Enter to finish): " EXIT_NODE
    if [ -z "$EXIT_NODE" ]; then
        break
    fi
    EXIT_NODES+=("$EXIT_NODE")
    ((INDEX++))
done

if [ ${#EXIT_NODES[@]} -eq 0 ]; then
    echo "⚠ No exit nodes configured. You'll need to edit the failover script manually."
    EXIT_NODES_STR='("100.85.214.5")'
else
    # Format as bash array
    EXIT_NODES_STR="("
    for node in "${EXIT_NODES[@]}"; do
        EXIT_NODES_STR+="\"$node\" "
    done
    EXIT_NODES_STR="${EXIT_NODES_STR% })"
fi

# Install failover script
echo ""
echo "Installing failover script..."

cat > /usr/local/bin/tailscale-failover.sh << 'EOFSCRIPT'
#!/bin/bash

# Edit These Variables
###########################################################
inettestip=8.8.8.8
exitnodes=EXIT_NODES_PLACEHOLDER
failopen=false
flags="--accept-routes"
logfile="/var/log/tailscale-failover.log"
############################################################

exec > >(tee -a "$logfile")
exec 2>&1

function set_exit_node () {
    check_current_exit_node
    if [ "$1" == "false" ] && [ "$curexitnode" != "false" ] && [ "$failopen" == "true" ]; then
        echo "No best exit node, removing exit node..."
        sudo tailscale up $flags --reset
        test_icmp $inettestip
    elif [ "$1" == "false" ] && [ "$curexitnode" != "false" ] && [ "$failopen" == "false" ]; then
        echo "There are no working exit nodes but fail open is false so keeping current exit node $curexitnode."
    elif [ "$1" != "false" ] && [ "$curexitnode" != "$1" ]; then
        echo "Setting exit node to $1..."
        sudo tailscale up --exit-node="$1" --exit-node-allow-lan-access $flags
        sleep 3
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
            echo "✗ ERROR: Unable to change exit node. Current exit node is $curexitnode (wanted $1)."
            return 1
        fi
    else
        echo "Already using desired exit node $curexitnode."
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
        if [ "$original_exit" != "false" ] && [ "$original_exit" != "$node" ]; then
            sudo tailscale up --exit-node=$original_exit --exit-node-allow-lan-access $flags >/dev/null 2>&1
        fi
    fi
}

function check_current_exit_node () {
    curexitnode="false"
    if command -v jq &> /dev/null; then
        local status_json=$(tailscale status --json 2>/dev/null)
        if [ -n "$status_json" ]; then
            local json_exit=$(echo "$status_json" | jq -r '.ExitNodeStatus.TailscaleIPs[0] // empty' 2>/dev/null)
            if [ -n "$json_exit" ] && [ "$json_exit" != "null" ]; then
                curexitnode="$json_exit"
            fi
        fi
    fi
    if [ "$curexitnode" == "false" ]; then
        local status_line=$(tailscale status 2>/dev/null | grep "; exit node" | head -1)
        if [ -n "$status_line" ]; then
            curexitnode=$(echo "$status_line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
        fi
    fi
    curexitnode=$(echo "$curexitnode" | sed 's|/[0-9]*||' | xargs)
    if [[ ! "$curexitnode" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        curexitnode="false"
    fi
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

echo ""
echo "=============================="
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================="

test_icmp $inettestip
check_current_exit_node

if $icmp && [ "$curexitnode" != "false" ]; then
    echo "✓ Internet is up using $curexitnode as exit node."
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
    echo "✗ Internet is down and no exit node configured. Finding first working exit node..."
    find_best_exit_node
    if [ "$bestexitnode" != "false" ]; then
        set_exit_node $bestexitnode
    fi
fi

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
EOFSCRIPT

# Replace placeholder with actual exit nodes
sed -i "s/exitnodes=EXIT_NODES_PLACEHOLDER/exitnodes=$EXIT_NODES_STR/" /usr/local/bin/tailscale-failover.sh

chmod +x /usr/local/bin/tailscale-failover.sh
mkdir -p /var/log
touch /var/log/tailscale-failover.log

echo "✓ Failover script installed"

# Install systemd service and timer
echo ""
echo "Installing systemd service and timer..."

cat > /etc/systemd/system/tailscale-failover.service << 'EOFSERVICE'
[Unit]
Description=Tailscale Exit Node Failover
After=network-online.target tailscaled.service wg-quick@wg-exit.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale-failover.sh
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSERVICE

cat > /etc/systemd/system/tailscale-failover.timer << 'EOFTIMER'
[Unit]
Description=Run Tailscale Exit Node Failover Check
After=network-online.target

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=1s

[Install]
WantedBy=timers.target
EOFTIMER

systemctl daemon-reload
systemctl enable tailscale-failover.timer
systemctl start tailscale-failover.timer

echo "✓ Systemd timer configured and started"

# Run failover script once to configure initial exit node
echo ""
echo "Running initial failover configuration..."
/usr/local/bin/tailscale-failover.sh

echo ""
echo "========================================="
echo "Akwaba Installation Complete!"
echo "========================================="
echo ""
echo "Your Akwaba public key (share with Oracle setup):"
echo "$AKWABA_PUBLIC"
echo ""
echo "Configured exit nodes:"
for node in "${EXIT_NODES[@]}"; do
    echo "  - $node"
done
echo ""
echo "Next steps:"
echo "1. Verify WireGuard tunnel: ping 172.16.99.1"
echo "2. Check failover logs: tail -f /var/log/tailscale-failover.log"
echo "3. Monitor failover: sudo journalctl -u tailscale-failover.service -f"
echo ""