#!/bin/bash

# Oracle (Gateway Node) Installation Script
# Run with: sudo ./install-oracle.sh

set -e

echo "========================================"
echo "Oracle (Gateway) Node Installation"
echo "========================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root or with sudo"
    exit 1
fi

# Detect network interface
echo "Detecting network interface..."
DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Detected interface: $DEFAULT_INTERFACE"
echo ""

read -p "Is '$DEFAULT_INTERFACE' your main network interface? (y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter your network interface name: " DEFAULT_INTERFACE
fi

# Install dependencies
echo "Installing dependencies..."
apt update
apt install -y wireguard wireguard-tools iptables net-tools

# Check if Tailscale is installed
if ! command -v tailscale &> /dev/null; then
    echo ""
    echo "Tailscale not found. Installing..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "✓ Tailscale already installed"
fi

# Get Akwaba's Tailscale IP
echo ""
echo "You need Akwaba's Tailscale IP address."
echo "On Akwaba, run: tailscale ip -4"
read -p "Enter Akwaba's Tailscale IP: " AKWABA_TS_IP

# Generate WireGuard keys
echo ""
echo "Generating WireGuard keys..."
cd /etc/wireguard
umask 077

if [ -f oracle-private.key ]; then
    echo "⚠ Keys already exist. Backing up..."
    cp oracle-private.key oracle-private.key.bak
    cp oracle-public.key oracle-public.key.bak
fi

wg genkey | tee oracle-private.key | wg pubkey > oracle-public.key

ORACLE_PRIVATE=$(cat oracle-private.key)
ORACLE_PUBLIC=$(cat oracle-public.key)

echo "✓ Keys generated"
echo ""
echo "SAVE THESE KEYS:"
echo "================"
echo "Oracle Public Key: $ORACLE_PUBLIC"
echo "================"
echo ""
echo "⚠ You'll need to provide the Oracle public key when configuring Akwaba!"
echo ""

read -p "Enter Akwaba's public key: " AKWABA_PUBLIC

# Create WireGuard configuration
echo ""
echo "Creating WireGuard configuration..."

cat > /etc/wireguard/wg-exit.conf << EOF
[Interface]
PrivateKey = $ORACLE_PRIVATE
Address = 172.16.99.1/30
ListenPort = 51820
MTU = 1340
Table = off

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t mangle -A PREROUTING -i tailscale0 ! -d 100.64.0.0/10 -j MARK --set-mark 99
PostUp = iptables -t mangle -A PREROUTING -i tailscale0 ! -d 10.0.0.0/8 -j MARK --set-mark 99
PostUp = ip route add default dev wg-exit table 100
PostUp = ip rule add fwmark 99 table 100 priority 100
PostUp = iptables -t nat -A POSTROUTING -o wg-exit -j MASQUERADE
PostUp = iptables -A FORWARD -i tailscale0 -o wg-exit -j ACCEPT
PostUp = iptables -A FORWARD -i wg-exit -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -A INPUT -i wg-exit -j ACCEPT
PostUp = iptables -A OUTPUT -o wg-exit -j ACCEPT
PostUp = iptables -A OUTPUT -o $DEFAULT_INTERFACE -m state --state NEW -j REJECT
PostUp = iptables -I OUTPUT 1 -o tailscale0 -j ACCEPT
PostUp = iptables -I OUTPUT 1 -o wg-exit -j ACCEPT
PostUp = iptables -I OUTPUT 1 -o lo -j ACCEPT
PostUp = iptables -I OUTPUT 1 -d 10.0.0.0/24 -j ACCEPT

PostDown = iptables -t mangle -D PREROUTING -i tailscale0 ! -d 100.64.0.0/10 -j MARK --set-mark 99
PostDown = iptables -t mangle -D PREROUTING -i tailscale0 ! -d 10.0.0.0/8 -j MARK --set-mark 99
PostDown = ip rule del fwmark 99 table 100 priority 100
PostDown = ip route del default dev wg-exit table 100
PostDown = iptables -t nat -D POSTROUTING -o wg-exit -j MASQUERADE
PostDown = iptables -D FORWARD -i tailscale0 -o wg-exit -j ACCEPT
PostDown = iptables -D FORWARD -i wg-exit -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D INPUT -i wg-exit -j ACCEPT
PostDown = iptables -D OUTPUT -o wg-exit -j ACCEPT
PostDown = iptables -D OUTPUT -o $DEFAULT_INTERFACE -m state --state NEW -j REJECT
PostDown = iptables -D OUTPUT -o tailscale0 -j ACCEPT
PostDown = iptables -D OUTPUT -o wg-exit -j ACCEPT
PostDown = iptables -D OUTPUT -o lo -j ACCEPT
PostDown = iptables -D OUTPUT -d 10.0.0.0/24 -j ACCEPT

[Peer]
PublicKey = $AKWABA_PUBLIC
Endpoint = $AKWABA_TS_IP:51820
AllowedIPs = 0.0.0.0/0
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

# Configure Tailscale
echo ""
echo "Configuring Tailscale as exit node..."
tailscale up --advertise-exit-node --accept-routes --snat-subnet-routes=false

echo ""
echo "========================================="
echo "Oracle Installation Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Go to Tailscale admin console and approve Oracle as an exit node"
echo "2. Complete Akwaba installation"
echo "3. Test connectivity: ping 172.16.99.2"
echo ""
echo "Your Oracle public key (share with Akwaba setup):"
echo "$ORACLE_PUBLIC"
echo ""