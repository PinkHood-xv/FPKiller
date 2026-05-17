#!/bin/bash
# show_pending.sh — Display pending alerts waiting for manual AI analysis
# ========================================================================
# Used with workflow v5.1 (human-in-the-loop).
# Not needed for v6.1 (Ollama) or v6.2 (OpenRouter) — fully automatic.
#
# USAGE:
#   ./show_pending.sh
#
# OUTPUT:
#   1. Table of all pending alerts (id, alert_id, rule_id, agent_name, created_at)
#   2. Full AI prompt for the most recent pending alert  ← paste into Claude / ChatGPT
#   3. Reminder to run send_response.sh after getting the AI verdict
#
# INSTALL:
#   Place in ~/ai-lab/scripts/
#   chmod +x scripts/show_pending.sh

set -euo pipefail

echo "========================================"
echo "  PENDING ALERTS — WAITING FOR AI"
echo "========================================"
docker exec -i postgres psql -U n8n -d n8n \
  -c "SELECT id, alert_id, rule_id, agent_name, resume_url, created_at
      FROM pending_analysis
      WHERE status = 'pending'
      ORDER BY created_at DESC;"

# Fetch the most recent pending record
RESUME_URL=$(docker exec -i postgres psql -U n8n -d n8n -t -A \
  -c "SELECT resume_url FROM pending_analysis WHERE status='pending' ORDER BY created_at DESC LIMIT 1;")

ALERT_ID=$(docker exec -i postgres psql -U n8n -d n8n -t -A \
  -c "SELECT alert_id FROM pending_analysis WHERE status='pending' ORDER BY created_at DESC LIMIT 1;")

if [ -z "${RESUME_URL}" ]; then
  echo "No pending alerts found."
  exit 0
fi

echo ""
echo "========================================"
echo "  AI PROMPT (most recent pending)"
echo "========================================"
docker exec -i postgres psql -U n8n -d n8n -t -A \
  -c "SELECT prompt_for_ai FROM pending_analysis WHERE status='pending' ORDER BY created_at DESC LIMIT 1;"

echo ""
echo "========================================"
echo "  NEXT STEP"
echo "========================================"
echo "1. Copy the prompt above → paste into Claude Pro or ChatGPT"
echo "2. Get the AI JSON verdict"
echo "3. Run:"
echo "   ./send_response.sh <verdict> <confidence> <action> \"<reasoning>\""
echo ""
echo "Resume URL : ${RESUME_URL}"
echo "Alert ID   : ${ALERT_ID}"
