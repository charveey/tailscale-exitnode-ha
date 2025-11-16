# Scripts Directory

## Available Scripts

### `tailscale-failover.sh`
Main failover script that runs on Akwaba to manage exit node selection and automatic failover.

**Installation:**
```bash
sudo cp tailscale-failover.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/tailscale-failover.sh
```

**Configuration:**
Edit the variables at the top of the script:
- `exitnodes` - Array of exit node Tailscale IPs in priority order
- `inettestip` - IP address to test internet connectivity (default: 8.8.8.8)
- `failopen` - Whether to remove exit node if all fail (default: false)

### `install-oracle.sh`
Automated installation script for Oracle (gateway node).

**Usage:**
```bash
sudo ./install-oracle.sh
```

### `install-akwaba.sh`
Automated installation script for Akwaba (director node).

**Usage:**
```bash
sudo ./install-akwaba.sh
```

## Testing Scripts

See the `tests/` directory for connectivity and failover testing scripts.
