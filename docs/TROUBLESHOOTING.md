# Troubleshooting Guide

## Quick Diagnostics

Run this on both nodes to get system status:
```bash
echo "=== Tailscale Status ==="
tailscale status | head -20

echo -e "\n=== WireGuard Status ==="
sudo wg show

echo -e "\n=== Network Interfaces ==="
ip addr show | grep -A 5 "tailscale0\|wg-exit"

echo -e "\n=== Routing ==="
ip route | grep -E "wg-exit|tailscale"

echo -e "\n=== Recent Logs ==="
sudo journalctl -u wg-quick@wg-exit -n 20 --no-pager
```

## Common Issues

### 1. WireGuard Tunnel Not Establishing

**Symptoms:**
- No "latest handshake" in `wg show` output
- Cannot ping between Oracle and Akwaba

**Diagnosis:**
```bash
# Check if WireGuard is running
sudo systemctl status wg-quick@wg-exit

# Check configuration
sudo wg show

# Test Tailscale connectivity
ping <other-node-tailscale-ip>
```

**Solutions:**
- Verify Tailscale IPs are correct in configs
- Check WireGuard is listening: `sudo ss -ulnp | grep 51820`
- Ensure public keys match in configs
- Restart WireGuard: `sudo systemctl restart wg-quick@wg-exit`

### 2. Clients Have No Internet

**Symptoms:**
- Client can connect to Oracle as exit node
- No internet access from client

**Diagnosis:**
```bash
# On Akwaba - check exit node
tailscale status | grep "exit node"

# Should show active exit node

# Test from Akwaba
curl ifconfig.me
```

**Solutions:**
```bash
# On Akwaba - manually set exit node
sudo tailscale up --exit-node=100.85.214.5 --exit-node-allow-lan-access --accept-routes

# Check if failover script is running
sudo systemctl status tailscale-failover.timer

# Run failover script manually
sudo /usr/local/bin/tailscale-failover.sh
```

### 3. Failover Not Working

**Symptoms:**
- Exit node fails but no automatic switch
- Script shows errors in logs

**Diagnosis:**
```bash
# Check timer is active
sudo systemctl status tailscale-failover.timer

# Check recent runs
sudo journalctl -u tailscale-failover.service -n 50

# Run manually with debug
sudo bash -x /usr/local/bin/tailscale-failover.sh
```

**Solutions:**
- Ensure jq is installed: `sudo apt install jq`
- Verify exit node IPs are correct in script
- Check script has execute permissions
- Restart timer: `sudo systemctl restart tailscale-failover.timer`

### 4. High Latency

**Symptoms:**
- Connection works but slow
- High ping times

**Diagnosis:**
```bash
# Test latency at each hop
ping -c 10 172.16.99.2  # Oracle to Akwaba
ping -c 10 <exit-node-ip>  # Akwaba to exit node
ping -c 10 8.8.8.8  # Full path

# Check WireGuard transfer stats
sudo wg show
```

**Solutions:**
- Adjust MTU in WireGuard configs (try 1280-1420)
- Check for packet loss
- Verify no CPU bottlenecks
- Consider geographic proximity of nodes

### 5. Oracle Routes Traffic Directly

**Symptoms:**
- Traffic bypasses Akwaba
- Public IP shows Oracle's IP instead of exit node

**Diagnosis:**
```bash
# On Oracle - check iptables rules
sudo iptables -L OUTPUT -n -v | grep REJECT

# Should see rules blocking direct internet
```

**Solutions:**
```bash
# Restart WireGuard to reapply rules
sudo systemctl restart wg-quick@wg-exit

# Manually verify routing
ip route get 8.8.8.8  # Should show wg-exit
```

### 6. IPv6 Errors on Startup

**Symptoms:**
Error: IPv6 is disabled on nexthop device

**Solution:**
This is normal if IPv6 is disabled. The configs in this repo are IPv4-only. You can safely ignore these errors or enable IPv6:
```bash
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
```

## Log Analysis

### Check WireGuard Logs
```bash
sudo journalctl -u wg-quick@wg-exit --since "10 minutes ago"
```

### Check Failover Logs
```bash
# Real-time
tail -f /var/log/tailscale-failover.log

# Last hour
grep "$(date '+%Y-%m-%d %H')" /var/log/tailscale-failover.log
```

### Check Tailscale Logs
```bash
sudo journalctl -u tailscaled --since "10 minutes ago"
```

## Performance Issues

### High CPU Usage

**Check:**
```bash
top -b -n 1 | grep -E "wireguard|tailscale"
```

**Solutions:**
- Update to latest Tailscale/WireGuard versions
- Check for excessive connection churn
- Monitor for DDoS or abuse

### Packet Loss

**Check:**
```bash
# Continuous ping test
mtr -r -c 100 8.8.8.8
```

**Solutions:**
- Check network quality to both nodes
- Verify MTU settings
- Look for congested links

## Recovery Procedures

### Reset WireGuard Tunnel
```bash
sudo systemctl stop wg-quick@wg-exit
sudo systemctl start wg-quick@wg-exit
sudo wg show
```

### Reset Tailscale Connection
```bash
sudo tailscale down
sudo tailscale up --exit-node=<ip> --exit-node-allow-lan-access --accept-routes
```

### Complete System Reset
```bash
# On both nodes
sudo systemctl stop wg-quick@wg-exit
sudo systemctl stop tailscaled
sudo systemctl start tailscaled
sudo tailscale up --reset
sudo systemctl start wg-quick@wg-exit

# Reconfigure as needed
```

## Getting Help

If issues persist:

1. Gather diagnostic information:
```bash
./tests/test-connectivity.sh > diagnostics.txt
```

2. Check GitHub Issues for similar problems
3. Open a new issue with diagnostic output
4. Include:
   - Error messages
   - Configuration (with private keys removed!)
   - Output of diagnostic commands
   - What you've tried so far