#!/bin/bash
# health_check.sh — Verify all lab services are reachable and healthy
# ====================================================================
# Checks: Docker containers, MCP server, N8N, Wazuh API, PostgreSQL,
#         local LLM (Ollama), recent AI analysis count, Wazuh agents.
#
# USAGE:
#   ./health_check.sh
#
# CONFIGURATION (edit the variables below or export before running):
#   N8N_HOST        IP of the Ubuntu AI VM   (default: reads from .env)
#   WAZUH_HOST      IP of the Wazuh VM        (default: reads from .env)
#   WAZUH_API_USER  Wazuh API username
#   WAZUH_API_PASS  Wazuh API password
#
# AUTOMATED MONITORING (crontab — every hour):
#   0 * * * * ~/ai-lab/scripts/health_check.sh >> ~/ai-lab/logs/health_$(date +\%Y\%m\%d).log 2>&1
#
# INSTALL:
#   Place in ~/ai-lab/scripts/
#   chmod +x scripts/health_check.sh

set -euo pipefail

# ── Load .env if present ──────────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
fi

# ── Configurable vars (override via env or edit here) ─────────────────────────
N8N_HOST="${N8N_HOST:-YOUR-N8N-HOST-IP}"
WAZUH_HOST="${WAZUH_HOST:-YOUR-WAZUH-HOST-IP}"
WAZUH_API_USER="${WAZUH_API_USER:-n8n-integration}"
WAZUH_API_PASS="${WAZUH_API_PASSWORD:-}"        # from .env
WAZUH_SSH_USER="${WAZUH_SSH_USER:-wazuh}"

# ── Header ────────────────────────────────────────────────────────────────────
echo "=== LAB AI-SIEM HEALTH CHECK ==="
echo "Date : $(date)"
echo ""

# ── 1. Docker containers ──────────────────────────────────────────────────────
echo "1. Docker Containers:"
if docker compose ps 2>/dev/null | grep -qE "(Up|running)"; then
  docker compose ps
  echo "  ✓ Containers running"
else
  echo "  ✗ Some containers DOWN — run: docker compose ps"
fi
echo ""

# ── 2. MCP Server ─────────────────────────────────────────────────────────────
echo "2. MCP Server:"
if curl -sf "http://${N8N_HOST}:3333/health" | grep -q "healthy"; then
  echo "  ✓ MCP Server responding"
else
  echo "  ✗ MCP Server not responding — check: docker compose logs mcp-server"
fi
echo ""

# ── 3. N8N ───────────────────────────────────────────────────────────────────
echo "3. N8N Service:"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${N8N_HOST}:5678" || echo "000")
if [[ "${HTTP_CODE}" =~ ^2|^3 ]]; then
  echo "  ✓ N8N responding (HTTP ${HTTP_CODE})"
else
  echo "  ✗ N8N not responding (HTTP ${HTTP_CODE}) — check: docker compose logs n8n"
fi
echo ""

# ── 4. Wazuh API ─────────────────────────────────────────────────────────────
echo "4. Wazuh API:"
if curl -sf -k -u "${WAZUH_API_USER}:${WAZUH_API_PASS}" \
    "https://${WAZUH_HOST}:55000/" | grep -q "Wazuh API"; then
  echo "  ✓ Wazuh API OK"
else
  echo "  ✗ Wazuh API unreachable — check UFW rules and wazuh-manager status"
fi
echo ""

# ── 5. PostgreSQL ─────────────────────────────────────────────────────────────
echo "5. PostgreSQL:"
if docker exec postgres pg_isready -U n8n > /dev/null 2>&1; then
  echo "  ✓ PostgreSQL ready"
else
  echo "  ✗ PostgreSQL error — check: docker compose logs postgres"
fi
echo ""

# ── 6. Local LLM (Ollama) — only relevant for v6.1 ───────────────────────────
echo "6. Local LLM (Ollama — v6.1 only):"
if curl -sf "http://${N8N_HOST}:11434/api/tags" | grep -q "models"; then
  MODELS=$(curl -sf "http://${N8N_HOST}:11434/api/tags" | python3 -c \
    "import sys,json; m=json.load(sys.stdin).get('models',[]); print(', '.join(x['name'] for x in m))" 2>/dev/null || echo "unknown")
  echo "  ✓ Ollama responding — models: ${MODELS}"
else
  echo "  — Ollama not running (expected if using v5.1 or v6.2)"
fi
echo ""

# ── 7. Recent AI analysis ─────────────────────────────────────────────────────
echo "7. Recent AI Analysis (last hour):"
RECENT=$(docker exec postgres psql -U n8n -d n8n -t -A \
  -c "SELECT COUNT(*) FROM ai_analysis_results WHERE processed_at > NOW() - INTERVAL '1 hour';" \
  2>/dev/null || echo "N/A")
echo "  Alerts analysed : ${RECENT}"

if command -v docker &>/dev/null; then
  PENDING=$(docker exec postgres psql -U n8n -d n8n -t -A \
    -c "SELECT COUNT(*) FROM pending_analysis WHERE status='pending';" \
    2>/dev/null || echo "N/A")
  echo "  Pending (v5.1)  : ${PENDING}"
fi
echo ""

# ── 8. Wazuh agents ──────────────────────────────────────────────────────────
echo "8. Wazuh Agents:"
ACTIVE=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  "${WAZUH_SSH_USER}@${WAZUH_HOST}" \
  "sudo /var/ossec/bin/agent_control -l 2>/dev/null | grep -c Active" 2>/dev/null || echo "SSH failed")
echo "  Active agents : ${ACTIVE}"
echo ""

echo "=== Health Check Complete ==="
