# Setup Guide

This guide covers lab build to a working Wazuh + N8N + MCP stack. This guide does not cover virtual machines and pfSense configurations but provides a well documented structure. All IP addresses use variable notation — replace them with your actual values in `.env` before starting.

> **Estimated total time:** plenty of hours on a first build. Subsequent rebuilds from snapshots take ~15 minutes.

---

## Variable Reference

Define these in your `.env` before running any command. All commands in this guide reference them by name.

| Variable | What to set | Example |
|---|---|---|
| `$AI_HOST` | Static IP of Ubuntu AI VM | `10.x.x1.11` |
| `$SIEM_HOST` | Static IP of Wazuh SIEM VM | `10.x.x2.11` |
| `$TARGET_HOST` | Static IP of Target VM | `10.x.x3.100` |
| `$AI_GW` | pfSense IP on LAN_AI | `10.x.x1.1` |
| `$SIEM_GW` | pfSense IP on LAN_SIEM | `10.x.x2.1` |
| `$TARGET_GW` | pfSense IP on LAN_TARGET | `10.x.x3.1` |

---

## Phase 0 — Physical Host Preparation

### - Install VirtualBox

### Take a snapshot of the clean host state

Note the date and current system state — useful as a rollback point before adding VMs.

---

## Phase 1 — VirtualBox Networks

pfSense needs four separate network segments. Create them before creating any VM.

---

## Phase 2 — Install and configure interfaces on pfSense VM

pfSense segmentation is not mandatory for a demo but if you want to push FPKiller more and try to infect the TARGET_VM with malware, segmentation and isolation is strongly recommended.

**Checkpoint 2:** pfSense responds on console, 4 interfaces configured with IPs.

---

## Phase 3 — Ubuntu AI Docker Host

### 3.1 Post-install base packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y net-tools curl wget git vim htop jq
```

### 3.2 Test connectivity

```bash
ping -c 3 $AI_GW      # pfSense gateway — must succeed
ping -c 3 8.8.8.8     # Internet — must succeed
ping -c 3 google.com  # DNS — must succeed
```

**Checkpoint 3:** Ubuntu AI has a static IP and Internet access.

---

## Phase 4 — Docker Stack + MCP Server

### 4.1 Install Docker

```bash
# Remove any old versions
sudo apt remove docker.io docker-compose docker-compose-v2 \
  docker-doc podman-docker containerd runc 2>/dev/null

# Install dependencies
sudo apt update
sudo apt install -y ca-certificates curl

# Add Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add repository
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Install
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

### 4.2 Add current user to docker group

```bash
sudo usermod -aG docker $USER
newgrp docker
docker --version
docker compose version
```

### 4.3 Verify Docker works

```bash
docker run hello-world
# Expected: "Hello from Docker!"
```

### 4.4 Clone the repository

```bash
cd ~
git clone [https://github.com/PinkHood-xv/FPKiller.git] ai-lab
cd ai-lab
```

### 4.5 Create `.env` from the example

```bash
cp .env.example .env
nano .env
# Fill in all values — see comments in .env.example
```

Key variables to set at this stage:
```
WAZUH_API_URL=https://$SIEM_HOST:55000
WAZUH_INDEXER_URL=https://$SIEM_HOST:9200
WAZUH_API_USER=n8n-integration
WAZUH_API_PASSWORD=YOUR_WAZUH_API_PASSWORD
WAZUH_INDEXER_USER=admin
WAZUH_INDEXER_PASSWORD=YOUR_INDEXER_PASSWORD
POSTGRES_USER=n8n
POSTGRES_PASSWORD=YOUR_POSTGRES_PASSWORD
POSTGRES_DB=n8n
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=YOUR_N8N_PASSWORD
N8N_SECURE_COOKIE=false
WEBHOOK_URL=http://$AI_HOST:5678/
```

> **FIX applied:** `N8N_SECURE_COOKIE=false` is required to access N8N via HTTP from an IP address. Without it, N8N redirects to HTTPS and the session cookie is rejected. See [BUGFIX_LOG.md](BUGFIX_LOG.md).

### 4.6 Build and start core services

```bash
cd ~/ai-lab

# Build all custom images
docker compose build

# Start core services first
docker compose up -d postgres redis mcp-server

# Wait for services to initialise
sleep 30

# Verify all three are running
docker compose ps
```

### 4.7 Verify MCP server started

```bash
docker compose logs mcp-server
# Expected lines:
# MCP initialized — API: https://$SIEM_HOST:55000 | Indexer: https://$SIEM_HOST:9200
# Starting MCP Server on port 3333...
```

```bash
curl http://$AI_HOST:3333/health
# Expected: {"status":"healthy","service":"MCP Wazuh Server","timestamp":"..."}
```

> **Note:** MCP will log connection errors to Wazuh at this stage — that is expected. Wazuh is not installed yet. The server itself must be running and healthy.

### 4.8 Verify PostgreSQL

```bash
docker exec -it postgres psql -U n8n -d n8n -c "\l"
# Expected: database 'n8n' listed
```

**Checkpoint 4:** Docker working, PostgreSQL and Redis running, MCP server healthy on :3333.

---

## Phase 5 — pfSense WebGUI & Firewall Rules 

### 5.1 Access pfSense WebGUI

Change password from default

### 5.2 Rename interfaces

**Interfaces > Assignments:**
- OPT1 → rename to `LAN_SIEM`, enable
- OPT2 → rename to `LAN_TARGET`, enable


### 5.3 Create Aliases

**Firewall > Aliases > IP — Add:**

**Firewall > Aliases > Ports — Add:**


### 5.4 Configure DHCP static mappings

**Services > DHCP Server > LAN_AI:**
- Add Static Mapping: MAC of Ubuntu AI → `$AI_HOST`

**Services > DHCP Server > LAN_SIEM** *(configure after Wazuh VM is created):*
- Add Static Mapping: MAC of Wazuh VM → `$SIEM_HOST`


### 5.5 LAN_AI firewall rules

**Firewall > Rules > LAN_AI:**


### 5.6 LAN_SIEM firewall rules

**Firewall > Rules > LAN_SIEM:**


### 5.7 LAN_TARGET firewall rules

**Firewall > Rules > LAN_TARGET:**


### 5.8 Add Floating rule (critical safety net)

**Checkpoint 5:** All firewall rules active. Ubuntu AI can browse the Internet. pfSense WebGUI accessible from LAN_AI.

---

## Phase 6 — Wazuh SIEM VM

### 6.1 Install Ubuntu Server 22.04

### 6.2 Test connectivity

```bash
ping -c 3 $SIEM_GW   # pfSense — must succeed
ping -c 3 $AI_HOST   # Ubuntu AI — must succeed
ping -c 3 8.8.8.8    # Internet — must succeed
ping -c 3 google.com # DNS — must succeed
```

### 6.3 Update and install prerequisites

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git vim net-tools \
  apt-transport-https lsb-release gnupg
```

### 6.4 Install Wazuh all-in-one

```bash
curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh
sudo chmod +x wazuh-install.sh
sudo bash ./wazuh-install.sh -a
```

Installation takes 10–20 minutes. At the end it prints credentials — **save them now**:

```
User: admin
Password: <generated — save this>
```

### 6.5 Verify Wazuh services

```bash
sudo systemctl status wazuh-manager
sudo systemctl status wazuh-indexer
sudo systemctl status wazuh-dashboard

# Verify ports
sudo ss -tulpn | grep -E '1514|1515|55000|443|9200'
```

All three services must be `active (running)`. Port 9200 and 55000 must be listed.

### 6.6 Fix: expose Indexer on all interfaces

> **FIX applied (BUGFIX_LOG FIX 2):** By default, `wazuh-indexer` binds only to `127.0.0.1`. The MCP server cannot reach it from the Docker network. Fix:

```bash
sudo nano /etc/wazuh-indexer/opensearch.yml
```

Find and change:
```yaml
network.host: "127.0.0.1"
```
to:
```yaml
network.host: "0.0.0.0"
```

```bash
sudo systemctl restart wazuh-indexer
sudo ss -tulpn | grep 9200
# Must now show 0.0.0.0:9200
```

### 6.7 Configure UFW

```bash
sudo ufw enable

sudo ufw allow from LAN_AI_NET to any port 55000 proto tcp comment "N8N/MCP to API"
sudo ufw allow from LAN_AI_NET to any port 443 proto tcp  comment "N8N to Dashboard"
sudo ufw allow from LAN_AI_NET to any port 9200 proto tcp comment "MCP to Indexer"
sudo ufw allow from LAN_TARGET_NET to any port 1514 proto udp comment "Agents UDP"
sudo ufw allow from LAN_TARGET_NET to any port 1515 proto tcp comment "Agents TCP"
sudo ufw allow 22/tcp comment "SSH"

sudo ufw status verbose
```

Replace `LAN_AI_NET` and `LAN_TARGET_NET` with the actual subnet CIDRs from your `.env`.

### 6.8 Test access from Ubuntu AI

```bash
# Run these from Ubuntu AI ($AI_HOST)
curl -k https://$SIEM_HOST:443
# Expected: Wazuh Dashboard HTML

curl -k -u admin:YOUR_WAZUH_ADMIN_PASSWORD \
  https://$SIEM_HOST:55000/
# Expected: {"data":{"title":"Wazuh API",...},"error":0}
```

** Checkpoint 6:** Wazuh installed, all three services running, reachable from Ubuntu AI on ports 443, 55000, and 9200.

---

## Phase 7 — Wazuh API Configuration & Webhook

### 7.1 Create API user for N8N/MCP

Open the Wazuh Dashboard from the Ubuntu AI browser:
```
URL:  https://$SIEM_HOST
User: admin
Pass: <password saved at step 6.4>
```

Navigate to **☰ → Security → Users → Create user**:

| Field | Value |
|---|---|
| Username | `n8n-integration` |
| Password | `YOUR_WAZUH_API_PASSWORD` (same as in `.env`) |
| Roles | `administrator` |
| Enabled | ✅ |

### 7.2 Test the new API user

```bash
# From Ubuntu AI
curl -k -u n8n-integration:YOUR_WAZUH_API_PASSWORD \
  https://$SIEM_HOST:55000/security/user/authenticate | jq
# Expected: {"data":{"token":"eyJ..."},"error":0}
```

### 7.3 Configure custom webhook integration

```bash

# Backup current config
sudo cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.backup

# Edit ossec.conf
sudo nano /var/ossec/etc/ossec.conf
```

Add the following block **before the closing `</ossec_config>` tag**:

```xml
<integration>
  <name>custom-webhook</name>
  <hook_url>http://$AI_HOST:5678/webhook/YOUR_N8N_WEBHOOK_UUID</hook_url>
  <level>1</level>
  <alert_format>json</alert_format>
</integration>
```

> Replace `YOUR_N8N_WEBHOOK_UUID` with the UUID shown in the N8N webhook node after you import the workflow in Phase 8.

```bash
sudo systemctl restart wazuh-manager
sudo systemctl status wazuh-manager   # must be active (running)
```

### 7.4 Install custom-webhook.sh

```bash
# Copy from the repository
sudo cp ~/FPKiller/wazuh/custom-webhook.sh \
  /var/ossec/integrations/custom-webhook
sudo chmod +x /var/ossec/integrations/custom-webhook
sudo chown root:wazuh /var/ossec/integrations/custom-webhook
```

### 7.5 Add custom test rules

```bash
sudo cp /var/ossec/etc/rules/local_rules.xml \
  /var/ossec/etc/rules/local_rules.xml.bak

sudo cp ~/FPKiller/wazuh/local_rules.xml \
  /var/ossec/etc/rules/local_rules.xml

sudo systemctl restart wazuh-manager
```

**Checkpoint 7:** Wazuh API user created, authentication tested, webhook integration configured.

---

## Phase 8 — N8N + Workflow Import

### 8.1 Start N8N

```bash
cd ~/ai-lab
docker compose up -d n8n
docker compose logs -f n8n
# Wait for: "Editor is now accessible via: http://0.0.0.0:5678/"
# Ctrl+C to exit log tail
```

### 8.2 Access N8N WebUI

```
URL:  http://$AI_HOST:5678
```

At first launch, N8N asks you to create an account:
- Email: `admin@lab.local`
- First name: `SOC`
- Last name: `Admin`
- Password: choose a strong password (different from Basic Auth)


### 8.3 Configure credentials

**Settings > Credentials > Add credential** for each:

**HTTP Basic Auth (Wazuh API):**
- Name: `Wazuh API Auth`
- Username: `n8n-integration`
- Password: `YOUR_WAZUH_API_PASSWORD`

**PostgreSQL:**
- Name: `Lab PostgreSQL`
- Host: `postgres` ← Docker container name, not an IP
- Database: `n8n`
- User: `n8n`
- Password: `YOUR_POSTGRES_PASSWORD`
- Port: `5432`
- Click **Test connection** — must succeed

**Anthropic (optional — future use):**
- Name: `Claude API`
- API Key: `YOUR_ANTHROPIC_API_KEY`

**OpenAI (optional — future use):**
- Name: `OpenAI API`
- API Key: `YOUR_OPENAI_API_KEY`


### 8.4 Initialise the database schema

```bash
docker exec -it postgres psql -U n8n -d n8n \
  -f /docker-entrypoint-initdb.d/init.sql
```

Or run it manually:

```bash
docker exec -it postgres psql -U n8n -d n8n
```

```sql
-- paste contents of database/init.sql here
-- then verify:
\dt
-- Expected: pending_analysis, ai_analysis_results listed
\dv
-- Expected: daily_fp_stats, top_fp_rules, mcp_enrichment_stats listed
\q
```


### 8.5 Import the workflow

**Workflows > Import from File** — select one of:

| File | Use case |
|---|---|
| `n8n-workflows/wazuh_fp_detector_v5.1_manual.json` | Manual review gate — zero LLM cost |
| `n8n-workflows/wazuh_fp_detector_v6.2_openrouter.json` | Fully automatic — OpenRouter free tier |

After import:
1. Open the workflow
2. Note the **Webhook node UUID** (shown in the node settings) — you need it for the Wazuh `ossec.conf` hook_url from step 7.3
3. Update your Wazuh `ossec.conf` with the correct UUID if you haven't already
4. Set the workflow to **Active**

### 8.6 Start remaining services

```bash
cd ~/ai-lab
docker compose up -d
docker compose ps
# All containers must show "Up"
```

### 8.7 Verify inter-container connectivity

```bash
docker exec -it n8n wget -qO- http://mcp-server:3333/health
# Expected: {"status":"healthy"...}

docker exec -it n8n ping -c 2 postgres
# Expected: 2 packets transmitted, 2 received
```

### 8.8 Send a test alert to the webhook

```bash
curl -X POST http://$AI_HOST:5678/webhook/YOUR_N8N_WEBHOOK_UUID \
  -H "Content-Type: application/json" \
  -d '{
    "id": "test-001",
    "timestamp": "2025-01-01T10:00:00.000Z",
    "rule": {"id": "100001", "description": "Test alert", "level": 5, "groups": []},
    "agent": {"id": "001", "name": "target-vm-01", "ip": "$TARGET_HOST"},
    "full_log": "test-alert: manual connectivity test"
  }'
```

Check **N8N > Executions** — you should see a new execution with the MCP enrichment step completed.


**Checkpoint 8:** N8N active, workflow imported and triggering, MCP enrichment working, PostgreSQL saving results.

---

## Phase 9 — Target VM + Wazuh Agent

### 9.1 Create the VM

### 9.2 Configure static IP

### 9.3 Test connectivity and verify network isolation

```bash
# Must succeed
ping -c 3 $TARGET_GW   # pfSense gateway
ping -c 3 $SIEM_HOST   # Wazuh SIEM
ping -c 3 8.8.8.8      # Internet

# Must FAIL — LAN_TARGET is blocked from LAN_AI
ping -c 3 $AI_HOST
# Expected: Network is unreachable or 100% packet loss
```

If the last ping succeeds, check the pfSense Floating rule.

### 9.4 Install Wazuh agent

```bash
curl -so wazuh-agent.deb \
  https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.9.0-1_amd64.deb

sudo WAZUH_MANAGER="$SIEM_HOST" \
     WAZUH_AGENT_NAME="target-vm-01" \
     dpkg -i wazuh-agent.deb

sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent

sudo systemctl status wazuh-agent
# Must show: active (running)
```

### 9.5 Verify agent registration on Wazuh server

```bash
# SSH to Wazuh VM
ssh wazuh@$SIEM_HOST

sudo /var/ossec/bin/agent_control -l
# Expected: target-vm-01  Active
```

### 9.6 Verify agent in Wazuh Dashboard

From Ubuntu AI browser: `https://$SIEM_HOST` → **☰ → Agents**

The agent `target-vm-01` must show status **Active**.

### 9.7 Generate a test event and verify the full pipeline

```bash
# On Target VM
logger -p local0.info "test-alert: phase 9 end-to-end pipeline test"
```

Wait 30 seconds, then check:

1. **Wazuh Dashboard → Events** — filter by `agent.name: target-vm-01` — should show the alert
2. **N8N → Executions** — should show a new execution
3. **PostgreSQL** — verify the result was saved:

```bash
# From Ubuntu AI
docker exec -it postgres psql -U n8n -d n8n \
  -c "SELECT alert_id, rule_id, verdict, confidence, processed_at
      FROM ai_analysis_results
      ORDER BY processed_at DESC LIMIT 3;"
```

**Checkpoint 9:** Full pipeline working — Target VM → Wazuh → N8N webhook → MCP enrichment → LLM → PostgreSQL.

---

## Next Steps To Do:

With all 9 phases complete the lab is operational. Continue with:

- **Phase 10** — Integration testing (generate varied alert types, measure accuracy)
- **Phase 11** — Dashboard and monitoring (PostgreSQL views, Grafana optional)
- **Phase 12** — Optimisation and tuning (Wazuh rules, N8N error handling, log rotation)
- **Phase 13** — Test dataset generation and AI accuracy benchmarking

See also:
- [BUGFIX_LOG.md](BUGFIX_LOG.md) for fixes applied during development
- [ARCHITECTURE.md](ARCHITECTURE.md) for network diagrams and data flow detail

---

*Part of theFPKiller project — see [README.md](../README.md) for overview.*
