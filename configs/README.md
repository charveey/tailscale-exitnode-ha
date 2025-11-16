# Configuration Files

This directory contains WireGuard configuration templates for both nodes.

## Files

- `oracle-wg-exit.conf` - WireGuard configuration for Oracle (gateway node)
- `akwaba-wg-exit.conf` - WireGuard configuration for Akwaba (director node)

## Usage

1. Copy the appropriate config to `/etc/wireguard/wg-exit.conf`
2. Replace placeholder values (marked with `<>`)
3. Ensure proper file permissions: `chmod 600 /etc/wireguard/wg-exit.conf`

## Important Security Notes

⚠️ **Never commit private keys to version control!**

- Private keys should only exist on their respective servers
- Use `.gitignore` to prevent accidental commits
- Rotate keys periodically for security
