# Systemd Service Files

## Files

- `tailscale-failover.service` - Service unit for running the failover script
- `tailscale-failover.timer` - Timer unit for periodic execution

## Installation
```bash
sudo cp tailscale-failover.service /etc/systemd/system/
sudo cp tailscale-failover.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable tailscale-failover.timer
sudo systemctl start tailscale-failover.timer
```

## Configuration

### Adjusting Check Interval

Edit `tailscale-failover.timer`:
```ini
[Timer]
OnUnitActiveSec=30  # Run every 30 seconds
```

After changes:
```bash
sudo systemctl daemon-reload
sudo systemctl restart tailscale-failover.timer
```

## Monitoring
```bash
# View timer status
sudo systemctl status tailscale-failover.timer

# View service logs
sudo journalctl -u tailscale-failover.service -f

# List all timers
sudo systemctl list-timers
```