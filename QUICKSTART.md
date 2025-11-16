# Quick Start Guide

Get up and running in 15 minutes!

## Prerequisites Checklist

- [ ] Two servers with Ubuntu 20.04+ (or Debian-based distro)
- [ ] Both servers on same network or cloud provider
- [ ] Root/sudo access on both servers
- [ ] At least one Tailscale exit node available
- [ ] Tailscale account and admin access

## Installation Steps

### 1. Prepare Both Servers

```bash
# On both Oracle and Akwaba
sudo apt update
sudo apt install -y git curl

# Clone this repository
git clone https://github.com/charveey/tailscale-exitnode-ha.git
cd tailscale-ha-exit-node
```

### 2. Install Oracle (Gateway Node)

```bash
# On Oracle server
cd tailscale-ha-exit-node
sudo chmod +x scripts/install-oracle.sh
sudo ./scripts/install-oracle.sh
```

The script will ask you for:
- Network interface name (usually auto-detected)
- Akwaba's Tailscale IP (get from step 3)
- Akwaba's public key (get from step 3)

**Save the Oracle public key** displayed at the end!

### 3. Install Akwaba (Director Node)

```bash
# On Akwaba server
cd tailscale-ha-exit-node
sudo chmod +x scripts/install-akwaba.sh
sudo ./scripts/install-akwaba.sh
```

The script will ask you for:
- Oracle's public key (from step 2)
- Your exit node Tailscale IPs (in priority order)

**Save the Akwaba public key** and provide it to Oracle setup!

### 4. Approve Exit Node in Tailscale

1. Go to https://login.tailscale.com/admin/machines
2. Find Oracle in the machine list
3. Click "..." → "Edit route settings"
4. Enable "Use as exit node"
5. Click "Save"

### 5. Test the Setup

```bash
# On Oracle - test tunnel
ping -c 3 172.16.99.2

# On Akwaba - test tunnel  
ping -c 3 172.16.99.1

# Check WireGuard on both
sudo wg show

# From client device
tailscale up --exit-node=<oracle-tailscale-ip>
curl ifconfig.me  # Should show exit node's IP
```

### 6. Monitor

```bash
# On Akwaba - watch failover logs
tail -f /var/log/tailscale-failover.log

# Or with systemd
sudo journalctl -u tailscale-failover.service -f
```

## Quick Commands

### Check Status
```bash
# WireGuard tunnel
sudo wg show

# Tailscale
tailscale status

# Akwaba current exit node
tailscale status | grep "exit node"
```

### Restart Services
```bash
# WireGuard
sudo systemctl restart wg-quick@wg-exit

# Failover (Akwaba only)
sudo systemctl restart tailscale-failover.timer
```

### View Logs
```bash
# WireGuard
sudo journalctl -u wg-quick@wg-exit -f

# Failover
sudo journalctl -u tailscale-failover.service -f
```

## Troubleshooting

If something doesn't work:

1. Run connectivity test:
```bash
cd tailscale-ha-exit-node
chmod +x tests/test-connectivity.sh
sudo ./tests/test-connectivity.sh
```

2. Check the [full troubleshooting guide](docs/TROUBLESHOOTING.md)

3. Open an issue with the test output

## Common Issues

### "Cannot ping 172.16.99.2 from Oracle"

**Solution:**
```bash
# On Akwaba - check WireGuard is running
sudo systemctl status wg-quick@wg-exit

# Check Tailscale IP is correct
tailscale ip -4

# On Oracle - verify endpoint in config
sudo cat /etc/wireguard/wg-exit.conf | grep Endpoint
```

### "Clients have no internet"

**Solution:**
```bash
# On Akwaba - check exit node is configured
tailscale status | grep "exit node"

# Manually set if needed
sudo tailscale up --exit-node=100.85.214.5 --exit-node-allow-lan-access --accept-routes

# Check failover is running
sudo systemctl status tailscale-failover.timer
```

### "Failover not switching"

**Solution:**
```bash
# Check timer is active
sudo systemctl status tailscale-failover.timer

# Run manually to test
sudo /usr/local/bin/tailscale-failover.sh

# Check logs
tail -50 /var/log/tailscale-failover.log
```

## What's Next?

- Read the [Architecture Guide](docs/ARCHITECTURE.md) to understand how it works
- Customize failover behavior in `/usr/local/bin/tailscale-failover.sh`
- Add more exit nodes to your configuration
- Set up monitoring and alerts
- Deploy multiple Oracle nodes for high availability

## Need Help?

- 📖 [Full Documentation](README.md)
- 🐛 [Report Issues](https://github.com/charveey/tailscale-exitnode-ha/issues)
- 💬 [Discussions](https://github.com/charveey/tailscale-exitnode-ha/discussions)

---

**Congratulations! Your transparent HA exit node system is ready!** 🎉