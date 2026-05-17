# pfSense Aliases
<!-- pfSense WebGUI → Firewall → Aliases -->

> Replace placeholder IPs with your actual lab network addresses.
> The subnet scheme used in this lab: `10.10.X.0/24` — adjust to match your VirtualBox Host-Only / Internal network plan.

---

## IP Aliases
<!-- Firewall → Aliases → IP → Add -->

| Alias Name   | Type    | IP / Network       | Description                        |
|--------------|---------|--------------------|------------------------------------|
| AI_UBUNTU    | Host    | `YOUR-AI-HOST-IP`  | Ubuntu AI VM (N8N + MCP + Docker)  |
| WAZUH_SERVER | Host    | `YOUR-WAZUH-IP`    | Wazuh SIEM all-in-one              |
| DOCKER_NET   | Network | `172.17.0.0/16`    | Docker bridge network (default)    |

> **DOCKER_NET note:** `172.17.0.0/16` is Docker's default bridge. If you customised the bridge CIDR in `/etc/docker/daemon.json`, update this alias accordingly.

---

## Port Aliases
<!-- Firewall → Aliases → Ports → Add -->

| Alias Name         | Ports                    | Description                                   |
|--------------------|--------------------------|-----------------------------------------------|
| WAZUH_QUERY_PORTS  | 55000, 443, 1515, 9200   | Wazuh API, Dashboard HTTPS, Agent reg, Indexer |
| WAZUH_LOG_PORTS    | 514, 1514, 1515          | Syslog UDP, Wazuh Agent TCP/UDP               |
| N8N_WEBHOOK_PORTS  | 5678, 5679, 5680         | N8N webhook listener ports                    |
| MCP_PORTS          | 3333                     | MCP Server API                                |
| WEB_PORTS          | 80, 443                  | HTTP / HTTPS                                  |
| DNS_PORT           | 53                       | DNS                                           |
| NTP_PORT           | 123                      | NTP                                           |

---

## Network Scheme Reference

| Interface | VirtualBox Type | Subnet          | Gateway       | Role                        |
|-----------|-----------------|-----------------|---------------|-----------------------------|
| WAN       | NAT             | (DHCP from host)| —             | Internet access             |
| LAN_AI    | Host-Only       | `10.10.10.0/24` | `10.10.10.1`  | N8N, MCP, Docker host       |
| LAN_SIEM  | Internal        | `10.10.20.0/24` | `10.10.20.1`  | Wazuh SIEM                  |
| LAN_TARGET| Internal        | `10.10.30.0/24` | `10.10.30.1`  | Target VMs with Wazuh agents|

> These subnets are examples. Choose any RFC1918 ranges that don't conflict with your host machine's existing networks.
