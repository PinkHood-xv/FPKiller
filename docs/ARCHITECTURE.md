# Architecture — FPKiller

## Table of Contents

- [Variable Reference](#variable-reference)
- [Network Topology](#network-topology)
- [Virtual Machines](#virtual-machines)
- [Docker Stack](#docker-stack)
- [Port Reference](#port-reference)
- [Data Flow](#data-flow)
- [Firewall Segmentation](#firewall-segmentation)
- [MCP Server Internals](#mcp-server-internals)
- [Database Schema](#database-schema)

---

## Variable Reference

All IP addresses in this document use these placeholders. Set actual values in `.env`.

| Variable | Role | Example subnet |
|---|---|---|
| `$AI_HOST` | Ubuntu AI VM — Docker host | LAN_AI |
| `$SIEM_HOST` | Wazuh SIEM VM | LAN_SIEM |
| `$TARGET_HOST` | Target VM with Wazuh agent | LAN_TARGET |
| `$AI_GW` | pfSense interface — LAN_AI | LAN_AI |
| `$SIEM_GW` | pfSense interface — LAN_SIEM | LAN_SIEM |
| `$TARGET_GW` | pfSense interface — LAN_TARGET | LAN_TARGET |
| `LAN_AI_NET` | Subnet for AI zone | e.g. 10.x.x1.0/24 |
| `LAN_SIEM_NET` | Subnet for SIEM zone | e.g. 10.x.x2.0/24 |
| `LAN_TARGET_NET` | Subnet for Target zone | e.g. 10.x.x3.0/24 |

---

## Network Topology

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  PHYSICAL HOST — Ubuntu Desktop                                              │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐   │
│  │                        pfSense Firewall                               │   │
│  │                                                                       │   │
│  │  em0 / Adapter 1     em1 / Adapter 2     em2 / Adapter 3              │   │
│  │  NAT (WAN)           LAN_AI_NET          LAN_SIEM_NET                 │   │
│  │       ↕              $AI_GW              $SIEM_GW                     │   │
│  │                                                                       │   │
│  │                      em3 / Adapter 4                                  │   │
│  │                      LAN_TARGET_NET                                   │   │
│  │                      $TARGET_GW                                       │   │
│  └──────┬───────────────────┬───────────────────┬────────────────────────┘   │
│         │ WAN               │ LAN_AI            │ LAN_SIEM    │ LAN_TARGET   │
│         │                   │                   │             │              │
│    ┌────▼────┐         ┌────▼──────────────┐  ┌─▼──────────┐ ┌▼──────────┐   │
│    │Internet │         │  Ubuntu AI Docker │  │ Wazuh SIEM │ │Target VM  │   │
│    │         │         │  $AI_HOST         │  │ $SIEM_HOST │ │$TARGET_   │   │
│    └─────────┘         │                   │  │            │ │HOST       │   │
│                        │  ┌─────────────┐  │  │ Manager    │ │           │   │
│                        │  │    N8N      │  │  │ Indexer    │ │ Wazuh     │   │
│                        │  │   :5678     │  │◄─│ Dashboard  │ │ Agent     │   │
│                        │  └──────┬──────┘  │  │ :55000     │ │           │   │
│                        │         │         │  │ :9200      │ │ Generates │   │
│                        │  ┌──────▼──────┐  │  │ :443       │ │ events    │   │
│                        │  │ MCP Server  │──┼─►│            │ │           │   │
│                        │  │   :3333     │  │  └────────────┘ └───────────┘   │
│                        │  └─────────────┘  │                                 │
│                        │  ┌─────────────┐  │                                 │
│                        │  │  PostgreSQL │  │                                 │
│                        │  │   :5432     │  │                                 │
│                        │  └─────────────┘  │                                 │
│                        │  ┌─────────────┐  │                                 │
│                        │  │   Redis     │  │                                 │
│                        │  │   :6379     │  │                                 │
│                        │  └─────────────┘  │                                 │
│                        │  ┌─────────────┐  │                                 │
│                        │  │   Ollama    │  │                                 │
│                        │  │  :11434     │  │                                 │
│                        │  └─────────────┘  │                                 │
│                        └───────────────────┘                                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

### VirtualBox Network Types

| VirtualBox network | pfSense adapter | Zone | Notes |
|---|---|---|---|
| NAT | Adapter 1 — em0 | WAN | Internet access for all zones via pfSense NAT |
| Host-Only (vboxnet0) | Adapter 2 — em1 | LAN_AI | Physical host can reach $AI_HOST directly |
| Internal (intnet_siem) | Adapter 3 — em2 | LAN_SIEM | Isolated — no physical host access |
| Internal (intnet_target) | Adapter 4 — em3 | LAN_TARGET | Isolated — no physical host access |

The Host-Only network on LAN_AI means the browser on the physical host can reach the N8N WebUI at `http://$AI_HOST:5678` directly without going through pfSense. This is intentional for lab usability.

---

## Virtual Machines

| VM Name | Zone | OS | RAM | CPU | HDD | Role |
|---|---|---|---|---|---|---|
| `pfSense-Firewall` | All | pfSense CE (FreeBSD) | Central firewall, DHCP, routing |
| `Ubuntu-AI-Docker` | LAN_AI | Ubuntu Desktop 22.04 | Docker host: N8N, MCP, PostgreSQL, Redis, Ollama |
| `Ubuntu-SIEM-Wazuh` | LAN_SIEM | Ubuntu Server 22.04 | Wazuh all-in-one (Manager + Indexer + Dashboard) |
| `Target-Linux-01` | LAN_TARGET | Ubuntu Server 22.04 | Wazuh agent, generates test security events |

---

## Docker Stack

All containers run on a single `ai_network` bridge network. Internal DNS resolution uses container names (e.g. N8N calls `http://mcp-server:3333` — not `http://$AI_HOST:3333`).

```
ai_network (bridge)
│
├── postgres        :5432   — N8N backend DB + ai_analysis_results
│     depends_on: (none)
│     healthcheck: pg_isready
│
├── redis           :6379   — N8N queue / session store
│     depends_on: (none)
│
├── mcp-server      :3333   — Flask API, Wazuh enrichment
│     depends_on: (none — connects to $SIEM_HOST outside Docker)
│     healthcheck: GET /health
│
├── n8n             :5678   — Workflow automation
│     depends_on: postgres (healthy), redis, mcp-server (healthy)
│
├── ollama          :11434  — Local LLM inference (optional)
│     depends_on: (none)
│     volume: ollama-data
│
└── ai-agent        (no port) — Placeholder for future automation
      depends_on: postgres, redis
```

**Container networking note:** only N8N and MCP server have ports published to the host (`5678` and `3333`). Postgres, Redis and Ollama are reachable from other containers by name but not from outside the Docker host unless you explicitly add port bindings.

---

## Data Flow

### Full pipeline — alert to verdict

```
1. EVENT GENERATION
   Target VM ($TARGET_HOST)
     └─ logger / SSH / syscheck / custom events
           │
           │ Wazuh agent TCP :1514
           ▼

2. SIEM INGESTION
   Wazuh Manager ($SIEM_HOST)
     └─ processes event → matches rule → generates alert
     └─ wazuh-integratord calls custom-webhook.sh
           │
           │ HTTP POST :5678/webhook/<uuid>
           ▼

3. WORKFLOW TRIGGER
   N8N — Webhook node
     └─ Extract Alert (Code node)
           normalises $json.body envelope
           │
           │ HTTP POST :3333/analyze_alert
           ▼

4. CONTEXT ENRICHMENT
   MCP Server (:3333)
     ├─ POST /security/user/authenticate → JWT token  (:55000)
     ├─ GET  /rules?rule_ids=<id>                     (:55000)
     ├─ GET  /agents?agents_list=<id>                 (:55000)
     └─ POST /<index>/_search (rule history 24h)      (:9200)
           │
           │ enriched JSON → N8N
           ▼

5. PROMPT CONSTRUCTION
   N8N — Prepare AI Prompt (Code node)
     └─ builds structured prompt:
           rule details + agent status + log + occurrences
           │
           ├─────────────────────────────────────────┐
           │ v5.1 manual                             │ v6.x automatic
           ▼                                         ▼

6a. MANUAL PATH (v5.1)               6b. AUTOMATIC PATH (v6.x)
    Save Pending to DB                   HTTP POST :11434/api/generate  (Ollama)
    Wait node (execution suspends)    OR HTTP POST openrouter.ai/...    (OpenRouter)
    operator: show_pending.sh            │
    operator: copy prompt → AI web       │ LLM JSON response
    operator: send_response.sh           ▼
    POST to resume URL               Parse LLM Response (Code node)
           │                             │
           └──────────────┬──────────────┘
                          ▼

7. PERSISTENCE
   N8N — Postgres node
     └─ INSERT INTO ai_analysis_results
           (alert_id, rule_id, agent_name, verdict,
            confidence, reasoning, action, rule_tuning, mcp_enriched)
```

### custom-webhook.sh call chain

```
wazuh-integratord
  └─ reads <integration> block in ossec.conf
  └─ writes alert JSON to temp file
  └─ calls custom-webhook.sh $TEMPFILE
        └─ cat $TEMPFILE | curl -X POST $N8N_WEBHOOK_URL
```

> **Known issue:** wazuh-integratord 4.9 calls the script twice per alert. The `pending_analysis` table has a `UNIQUE` constraint on `alert_id` + `ON CONFLICT DO NOTHING` to deduplicate. See [BUGFIX_LOG.md](BUGFIX_LOG.md).

---

## Firewall Segmentation

### Design principles

1. **LAN_TARGET is isolated from LAN_AI** — a compromised Target VM cannot reach N8N, the MCP server, or any AI credentials.
2. **LAN_SIEM can push to N8N** — Wazuh needs to call the N8N webhook on LAN_AI.
3. **LAN_AI can query LAN_SIEM** — MCP server queries Wazuh API and OpenSearch.
4. **All zones have Internet access** — for updates, Wazuh threat intel, and cloud LLM APIs.

---

## MCP Server Internals

The MCP server is a Flask application that acts as an authenticated proxy between N8N and Wazuh. It handles the JWT lifecycle so N8N nodes never need to manage tokens.

```
N8N HTTP Request node
  │
  │ POST /analyze_alert  {original_alert_json}
  ▼
mcp_server.py — analyze_alert()
  │
  ├─ extract rule_id, agent_id from payload
  │
  ├─► get_rule_details(rule_id)
  │     POST /security/user/authenticate → JWT (cached, retry on 401)
  │     GET  /rules?rule_ids=<rule_id>
  │     returns: rule description, level, groups
  │
  ├─► search_alerts_by_rule(rule_id, hours=24)
  │     POST /<wazuh-alerts-index>/_search  (OpenSearch :9200)
  │     query: term rule.id + range timestamp ≥ now-24h
  │     returns: count of recent occurrences
  │
  └─► get_agent_info(agent_id)
        GET  /agents?agents_list=<agent_id>
        returns: agent name, IP, OS, status, last keepalive
  │
  ▼
returns enriched JSON:
{
  "success": true,
  "enriched_alert": {
    "original_alert": {...},
    "context": {
      "rule_details":        {...},
      "recent_occurrences":  42,
      "agent_details":       {...}
    }
  }
}
```

**Why OpenSearch for alerts, not the Wazuh REST API?**
The `/alerts` endpoint was removed in Wazuh 4.9+. Alert queries must go to the OpenSearch Indexer on port 9200. See [BUGFIX_LOG.md](BUGFIX_LOG.md) FIX 4.

**Why JWT instead of Basic Auth?**
Wazuh 4.9+ requires JWT on all API endpoints except `/security/user/authenticate`. The MCP server calls `authenticate` once, caches the token, and automatically retries with a fresh token on HTTP 401. See [BUGFIX_LOG.md](BUGFIX_LOG.md) FIX 3.

---

## Database Schema

```
PostgreSQL database: n8n
│
├── TABLE pending_analysis          — v5.1 manual workflow only
│     id            SERIAL PK
│     alert_id      VARCHAR(255) UNIQUE   ← UNIQUE prevents double-insert
│     rule_id       VARCHAR(50)
│     agent_name    VARCHAR(100)
│     prompt_for_ai TEXT
│     resume_url    TEXT
│     mcp_error     BOOLEAN DEFAULT FALSE
│     status        VARCHAR(20) DEFAULT 'pending'   (pending|completed|cancelled)
│     created_at    TIMESTAMP DEFAULT NOW()
│     completed_at  TIMESTAMP
│
├── TABLE ai_analysis_results       — all workflow versions write here
│     id            SERIAL PK
│     alert_id      VARCHAR(255) NOT NULL
│     rule_id       VARCHAR(50)
│     agent_name    VARCHAR(100)
│     verdict       VARCHAR(50)           (false_positive|legitimate_threat|uncertain)
│     confidence    INTEGER CHECK 0-100
│     reasoning     TEXT
│     action        VARCHAR(50)           (ignore|investigate|escalate)
│     rule_tuning   TEXT
│     processed_at  TIMESTAMP DEFAULT NOW()
│     mcp_enriched  BOOLEAN DEFAULT FALSE
│
├── VIEW daily_fp_stats
│     date, total_alerts, false_positives, legitimate_threats,
│     mcp_enriched_count, avg_confidence
│     GROUP BY DATE(processed_at)
│
├── VIEW top_fp_rules
│     rule_id, occurrences, avg_confidence, suggested_tuning
│     WHERE verdict = 'false_positive'
│     ORDER BY occurrences DESC LIMIT 10
│
└── VIEW mcp_enrichment_stats
      mcp_enriched, count, avg_confidence, percentage
      GROUP BY mcp_enriched
```

Full DDL is in [database/init.sql](../database/init.sql).

---

*Part of the FPKiller project — see [README.md](../README.md) for setup and workflow documentation.*
