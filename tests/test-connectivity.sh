#!/bin/bash

# Connectivity Test Script
# Run this on both Oracle and Akwaba to diagnose issues

set -e

echo "========================================"
echo "Tailscale HA Exit Node - Connectivity Test"
echo "========================================"
echo "Running on: $(hostname)"
echo "Date: $(date)"
echo ""

# Detect which node we're on
if ip addr show wg-exit 2>/dev/null | grep -q "172.16.99.1"; then
    NODE="oracle"
    REMOTE_IP="172.16.99.2"
    REMOTE_NAME="Akwaba"
elif ip addr show wg-exit 2>/dev/null | grep -q "172.16.99.2"; then
    NODE="akwaba"
    REMOTE_IP="172.16.99.1"
    REMOTE_NAME="Oracle"
else
    NODE="unknown"
    echo "⚠ WARNING: Could not determine node type (WireGuard not configured?)"
fi

echo "Detected Node: $NODE"
echo ""

# Test 1: Tailscale Status
echo "========== Tailscale Status =========="
if command -v tailscale &> /dev/null; then
    tailscale status | head -20
    echo ""
    echo "Tailscale IP: $(tailscale ip -4)"
    if [ "$NODE" == "akwaba" ]; then
        echo "Exit Node: $(tailscale status --json | jq -r '.ExitNodeStatus.TailscaleIPs[0] // "none"')"
    fi
else
    echo "✗ Tailscale not found"
fi
echo ""

# Test 2: WireGuard Status
echo "========== WireGuard Status =========="
if [ -f /etc/wireguard/wg-exit.conf ]; then
    echo "✓ Configuration file exists"
    if systemctl is-active --quiet wg-quick@wg-exit; then
        echo "✓ Service is active"
        echo ""
        sudo wg show
    else
        echo "✗ Service is not active"
        echo "Status: $(systemctl status wg-quick@wg-exit --no-pager -l)"
    fi
else
    echo "✗ Configuration file not found"
fi
echo ""

# Test 3: Network Interfaces
echo "========== Network Interfaces =========="
echo "--- Tailscale Interface ---"
ip addr show tailscale0 2>/dev/null || echo "✗ tailscale0 not found"
echo ""
echo "--- WireGuard Interface ---"
ip addr show wg-exit 2>/dev/null || echo "✗ wg-exit not found"
echo ""

# Test 4: Routing
echo "========== Routing =========="
echo "--- Main routing table ---"
ip route | grep -E "wg-exit|tailscale|default" || echo "No relevant routes"
echo ""
if [ "$NODE" == "oracle" ]; then
    echo "--- Custom routing table 100 ---"
    ip route show table 100 || echo "Table 100 not found"
    echo ""
    echo "--- Policy routing rules ---"
    ip rule show | grep -E "100|99" || echo "No custom rules"
fi
echo ""

# Test 5: Firewall Rules
echo "========== iptables Rules =========="
echo "--- NAT table ---"
sudo iptables -t nat -L -n -v | grep -E "wg-exit|tailscale" || echo "No relevant NAT rules"
echo ""
echo "--- FORWARD chain ---"
sudo iptables -L FORWARD -n -v | grep -E "wg-exit|tailscale" || echo "No relevant FORWARD rules"
echo ""

if [ "$NODE" == "oracle" ]; then
    echo "--- Mangle table (packet marking) ---"
    sudo iptables -t mangle -L -n -v | grep -E "MARK|tailscale" || echo "No packet marking rules"
    echo ""
fi

# Test 6: Connectivity Tests
echo "========== Connectivity Tests =========="

if [ "$NODE" != "unknown" ]; then
    echo "Testing connectivity to $REMOTE_NAME ($REMOTE_IP)..."
    if ping -c 3 -W 2 $REMOTE_IP > /dev/null 2>&1; then
        echo "✓ Ping to $REMOTE_NAME successful"
    else
        echo "✗ Ping to $REMOTE_NAME failed"
    fi
    echo ""
fi

echo "Testing internet connectivity..."
if ping -c 3 -W 2 8.8.8.8 > /dev/null 2>&1; then
    echo "✓ Ping to 8.8.8.8 successful"
else
    echo "✗ Ping to 8.8.8.8 failed"
fi
echo ""

if command -v curl &> /dev/null; then
    echo "Testing HTTP connectivity..."
    PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "failed")
    if [ "$PUBLIC_IP" != "failed" ]; then
        echo "✓ HTTP working - Public IP: $PUBLIC_IP"
    else
        echo "✗ HTTP request failed"
    fi
else
    echo "⚠ curl not installed, skipping HTTP test"
fi
echo ""

# Test 7: Service Status
echo "========== Service Status =========="
echo "--- WireGuard Service ---"
systemctl status wg-quick@wg-exit --no-pager -l || true
echo ""

if [ "$NODE" == "akwaba" ]; then
    echo "--- Failover Timer ---"
    systemctl status tailscale-failover.timer --no-pager -l 2>/dev/null || echo "✗ Failover timer not configured"
    echo ""
fi

# Test 8: Recent Logs
echo "========== Recent Logs (last 20 lines) =========="
echo "--- WireGuard Logs ---"
sudo journalctl -u wg-quick@wg-exit -n 20 --no-pager || true
echo ""

if [ "$NODE" == "akwaba" ]; then
    echo "--- Failover Logs ---"
    if [ -f /var/log/tailscale-failover.log ]; then
        tail -20 /var/log/tailscale-failover.log
    else
        sudo journalctl -u tailscale-failover.service -n 20 --no-pager 2>/dev/null || echo "✗ No failover logs found"
    fi
fi
echo ""

# Summary
echo "========================================="
echo "Test Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "--------"

ISSUES=0

# Check critical components
if ! systemctl is-active --quiet wg-quick@wg-exit; then
    echo "✗ WireGuard is not running"
    ((ISSUES++))
fi

if ! systemctl is-active --quiet tailscaled; then
    echo "✗ Tailscale is not running"
    ((ISSUES++))
fi

if [ "$NODE" == "akwaba" ] && ! systemctl is-active --quiet tailscale-failover.timer 2>/dev/null; then
    echo "⚠ Failover timer is not running (on Akwaba)"
    ((ISSUES++))
fi

if [ "$NODE" != "unknown" ] && ! ping -c 1 -W 2 $REMOTE_IP > /dev/null 2>&1; then
    echo "✗ Cannot reach $REMOTE_NAME"
    ((ISSUES++))
fi

if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
    echo "✗ No internet connectivity"
    ((ISSUES++))
fi

if [ $ISSUES -eq 0 ]; then
    echo "✓ All checks passed!"
else
    echo ""
    echo "Found $ISSUES issue(s). Review output above for details."
fi

echo ""
echo "Save this output and share it when asking for help."