# pfSense Firewall Rules
<!-- pfSense WebGUI → Firewall → Rules -->

Rules are listed in **evaluation order** (top-down, first match wins).
All rules use aliases defined in `aliases.md`.
`!RFC1918` means "any non-private IP" — pfSense built-in negation alias.

---

## LAN_AI Rules
<!-- Firewall → Rules → LAN_AI -->
Traffic from/to the Ubuntu AI VM (N8N, MCP server, Docker).

| # | Action | Proto   | Source        | Destination   | Port(s)              | Description                        |
|---|--------|---------|---------------|---------------|----------------------|------------------------------------|
| 1 | Pass   | TCP     | LAN_AI net    | LAN_AI addr   | 443, 80              | Admin access to pfSense WebGUI     |
| 2 | Pass   | UDP     | LAN_AI net    | LAN_AI addr   | 53                   | DNS via pfSense resolver           |
| 3 | Pass   | UDP     | LAN_AI net    | any           | 123                  | NTP                                |
| 4 | Pass   | TCP     | LAN_AI net    | WAZUH_SERVER  | WAZUH_QUERY_PORTS    | N8N / MCP → Wazuh API & Indexer   |
| 5 | Pass   | TCP     | WAZUH_SERVER  | AI_UBUNTU     | N8N_WEBHOOK_PORTS    | Wazuh integratord → N8N webhook    |
| 6 | Pass   | TCP     | LAN_AI net    | AI_UBUNTU     | MCP_PORTS            | Internal MCP server access         |
| 7 | Pass   | TCP     | LAN_AI net    | !RFC1918      | 443                  | Outbound HTTPS (Claude / OpenAI / OpenRouter API) |
| 8 | Pass   | TCP     | LAN_AI net    | !RFC1918      | 80                   | Outbound HTTP (package updates)    |
| 9 | Pass   | any     | DOCKER_NET    | DOCKER_NET    | any                  | Docker inter-container traffic     |
|10 | Block  | any     | LAN_TARGET net| LAN_AI net    | any                  | **Security: block Target → AI** ⚠️ |
|11 | Pass   | any     | LAN_AI net    | any           | any                  | Allow remaining AI outbound (logged)|

> **Rule 10** is a safety net in case the Floating rule (see below) is missed.
> **Rule 7** must allow the AI API provider you use: Anthropic, OpenAI, or OpenRouter.

---

## LAN_SIEM Rules
<!-- Firewall → Rules → LAN_SIEM -->
Traffic from/to the Wazuh SIEM VM.

| # | Action | Proto   | Source        | Destination   | Port(s)           | Description                         |
|---|--------|---------|---------------|---------------|-------------------|-------------------------------------|
| 1 | Pass   | TCP/UDP | LAN_TARGET net| WAZUH_SERVER  | WAZUH_LOG_PORTS   | Receive logs from Target agents     |
| 2 | Pass   | UDP     | LAN_SIEM net  | LAN_SIEM addr | 53                | DNS                                 |
| 3 | Pass   | UDP     | LAN_SIEM net  | any           | 123               | NTP                                 |
| 4 | Pass   | TCP     | WAZUH_SERVER  | AI_UBUNTU     | N8N_WEBHOOK_PORTS | Wazuh → N8N webhook (alert push)    |
| 5 | Pass   | TCP     | WAZUH_SERVER  | !RFC1918      | 443               | Threat intel / HTTPS outbound       |
| 6 | Pass   | TCP     | LAN_SIEM net  | !RFC1918      | 80                | Package updates                     |
| 7 | Block  | any     | LAN_SIEM net  | LAN_TARGET net| any               | Block SIEM → Target (logged)        |
| 8 | Pass   | any     | LAN_SIEM net  | any           | any               | Allow remaining SIEM outbound (logged)|

---

## LAN_TARGET Rules
<!-- Firewall → Rules → LAN_TARGET -->
Traffic from/to Target VMs (running Wazuh agents).

| # | Action | Proto   | Source         | Destination   | Port(s)           | Description                        |
|---|--------|---------|----------------|---------------|-------------------|------------------------------------|
| 1 | Pass   | TCP/UDP | LAN_TARGET net | WAZUH_SERVER  | WAZUH_LOG_PORTS   | Agent log shipping to Wazuh        |
| 2 | Pass   | UDP     | LAN_TARGET net | LAN_TARGET addr| 53               | DNS                                |
| 3 | Pass   | UDP     | LAN_TARGET net | any           | 123               | NTP                                |
| 4 | Pass   | TCP     | LAN_TARGET net | !RFC1918      | 80, 443           | Internet access for test scenarios |
| 5 | Block  | any     | LAN_TARGET net | LAN_AI net    | any               | **Security: block Target → AI** ⚠️ |
| 6 | Pass   | any     | LAN_TARGET net | any           | any               | Allow remaining Target outbound (logged)|

---

## Floating Rules
<!-- Firewall → Rules → Floating -->
Floating rules are evaluated **before** interface rules.
`Quick: Yes` means the rule matches and stops further evaluation immediately.

| Action | Direction | Interface  | Source         | Destination | Quick | Description                                  |
|--------|-----------|------------|----------------|-------------|-------|----------------------------------------------|
| Block  | In        | LAN_TARGET | any            | LAN_AI net  | Yes   | **Emergency block: Target → AI (failsafe)** ⚠️ |

> This rule is the primary enforcement point for the Target → AI isolation.
> The matching rules in LAN_AI (#10) and LAN_TARGET (#5) are secondary safety nets.

---

## Security Design Summary

```
LAN_TARGET ──[logs]──→ LAN_SIEM (Wazuh)
                            │
                       [webhook]
                            │
                            ↓
                        LAN_AI (N8N → MCP → LLM)
                            │
                       [results]
                            ↓
                        PostgreSQL

LAN_TARGET ──✗──→ LAN_AI     (BLOCKED at Floating + LAN_TARGET #5 + LAN_AI #10)
LAN_SIEM   ──✗──→ LAN_TARGET (BLOCKED at LAN_SIEM #7)
```

The AI network can reach the internet for API calls (rule LAN_AI #7).
Target VMs cannot reach the AI network under any circumstances.
