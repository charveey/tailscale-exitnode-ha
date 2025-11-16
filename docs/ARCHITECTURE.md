# Architecture Deep Dive

## Overview

This system creates a transparent proxy layer for Tailscale exit nodes using a WireGuard tunnel.

## Components

### 1. Oracle (Gateway Node)
**Responsibilities:**
- Advertise as Tailscale exit node
- Accept connections from clients
- Forward all exit-bound traffic to Akwaba via WireGuard tunnel
- Block direct internet routing (safety)

**Key Technologies:**
- Tailscale (mesh networking)
- WireGuard (tunneling)
- iptables (routing and filtering)
- Policy-based routing

### 2. Akwaba (Director Node)
**Responsibilities:**
- Receive traffic from Oracle
- Select appropriate exit node
- Automatically failover between exit nodes
- Monitor exit node health

**Key Technologies:**

- Tailscale (exit node client)
- WireGuard (tunnel endpoint)
- Bash scripting (failover logic)
- systemd timers (periodic health checks)

### 3. WireGuard Tunnel

**Purpose:**
Create a private, encrypted tunnel between Oracle and Akwaba that runs over the Tailscale mesh network.

**Benefits:**

- Low overhead
- Automatic reconnection
- Efficient encapsulation
- Clear separation of concerns

## Traffic Flow

### Outbound Traffic (Client → Internet)

Client Device
↓ (Tailscale encrypted)
Oracle Node (100.70.225.33)
↓ (WireGuard tunnel over Tailscale)
Akwaba Node (100.115.73.94)
↓ (Tailscale to exit node)
Real Exit Node (100.85.214.5)
↓ (unencrypted to destination)
Internet

### Return Traffic (Internet → Client)

Internet
↓
Real Exit Node
↓ (via Tailscale)
Akwaba Node
↓ (WireGuard tunnel)
Oracle Node
↓ (Tailscale)
Client Device

## Routing Details

### Oracle Routing
1. Client traffic arrives on `tailscale0` interface
2. Traffic destined for internet (not Tailscale network) is marked
3. Marked traffic is routed through `wg-exit` interface
4. NAT masquerading applies on `wg-exit`
5. Direct internet routing blocked via iptables

### Akwaba Routing
1. Traffic arrives on `wg-exit` interface from Oracle
2. NAT masquerading applies for `tailscale0`
3. Traffic forwards to Tailscale exit node
4. Return traffic follows reverse path

## Failover Mechanism

### Health Check Process
1. Script runs every 30 seconds (configurable)
2. Tests current exit node connectivity
3. If primary is not active, attempts to switch
4. If current exit node fails, tries next in priority list
5. Logs all actions for audit trail

### Exit Node Selection
Priority-based selection:
1. Always prefer first exit node in list (primary)
2. If primary fails, use second exit node (backup)
3. Continue through list until working node found
4. If all fail, keep last working node (fail-safe mode)

### Automatic Failback
- Periodically tests primary exit node
- Switches back to primary when it recovers
- Ensures optimal routing path

## Security Model

### Encryption Layers
1. **Tailscale**: End-to-end encryption for all mesh traffic
2. **WireGuard**: Additional tunnel encryption between Oracle and Akwaba
3. **Exit Node Connection**: Tailscale encryption to real exit node

### Access Control
- Tailscale ACLs control who can use Oracle as exit node
- WireGuard keys authenticate tunnel endpoints
- iptables rules prevent unauthorized routing

### Isolation
- Oracle cannot route traffic directly to internet
- All traffic must go through Akwaba
- Fail-safe: if tunnel fails, Oracle cannot route

## Scalability Considerations

### Single Gateway Limitations
- Oracle becomes single point of failure
- All client traffic flows through one node
- Bandwidth limited by Oracle's capacity

### Solutions
- Deploy multiple Oracle nodes (load balancing)
- Use DNS round-robin for client distribution
- Monitor Oracle health and remove if failed

### Performance Tuning
- Adjust WireGuard MTU for optimal throughput
- Monitor CPU usage on both nodes
- Consider dedicated hardware for high traffic

## Monitoring Points

### Critical Metrics
- WireGuard tunnel status (handshake age)
- Current active exit node
- Internet connectivity from Akwaba
- Packet loss and latency
- CPU and memory usage

### Log Locations
- WireGuard: `journalctl -u wg-quick@wg-exit`
- Failover: `/var/log/tailscale-failover.log`
- Tailscale: `journalctl -u tailscaled`

## Failure Modes

### Oracle Failure
- Clients lose connectivity
- Need backup Oracle nodes for HA
- Clients must manually switch to backup

### Akwaba Failure
- Oracle cannot route traffic
- All clients affected simultaneously
- Critical: deploy backup Akwaba

### Exit Node Failure
- Automatic failover to backup exit node
- Brief interruption during switch (~3-5 seconds)
- Transparent to clients

### Tunnel Failure
- WireGuard automatically attempts reconnection
- If persistent, requires manual intervention
- Check Tailscale connectivity first
