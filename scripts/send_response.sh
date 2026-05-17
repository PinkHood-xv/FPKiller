#!/bin/bash
# send_response.sh — POST a manual AI verdict to resume a waiting N8N execution
# ==============================================================================
# Used with workflow v5.1 (human-in-the-loop).
# Not needed for v6.1 (Ollama) or v6.2 (OpenRouter) — fully automatic.
#
# USAGE:
#   ./send_response.sh <verdict> <confidence> <action> "<reasoning>"
#
# ARGUMENTS:
#   verdict     false_positive | legitimate_threat | uncertain
#   confidence  integer 0-100
#   action      ignore | investigate | escalate
#   reasoning   free text (quote it to handle spaces)
#
# EXAMPLES:
#   ./send_response.sh false_positive 95 ignore "PAM session close is normal activity"
#   ./send_response.sh legitimate_threat 80 escalate "Repeated SSH failures from unknown IP"
#   ./send_response.sh uncertain 50 investigate "Insufficient context to classify"
#
# INSTALL:
#   Place in ~/ai-lab/scripts/
#   chmod +x scripts/send_response.sh

set -euo pipefail

VERDICT="${1:-}"
CONFIDENCE="${2:-}"
ACTION="${3:-}"
REASONING="${4:-}"

# ── Argument validation ───────────────────────────────────────────────────────
if [ -z "${VERDICT}" ] || [ -z "${CONFIDENCE}" ] || [ -z "${ACTION}" ] || [ -z "${REASONING}" ]; then
  echo "Usage: $0 <verdict> <confidence> <action> \"<reasoning>\""
  echo "  verdict:    false_positive | legitimate_threat | uncertain"
  echo "  confidence: integer 0-100"
  echo "  action:     ignore | investigate | escalate"
  exit 1
fi

if ! [[ "${CONFIDENCE}" =~ ^[0-9]+$ ]] || [ "${CONFIDENCE}" -lt 0 ] || [ "${CONFIDENCE}" -gt 100 ]; then
  echo "ERROR: confidence must be an integer 0-100, got: '${CONFIDENCE}'"
  exit 1
fi

if [[ "${VERDICT}" != "false_positive" && "${VERDICT}" != "legitimate_threat" && "${VERDICT}" != "uncertain" ]]; then
  echo "ERROR: invalid verdict: '${VERDICT}'"
  echo "       valid values: false_positive | legitimate_threat | uncertain"
  exit 1
fi

if [[ "${ACTION}" != "ignore" && "${ACTION}" != "investigate" && "${ACTION}" != "escalate" ]]; then
  echo "ERROR: invalid action: '${ACTION}'"
  echo "       valid values: ignore | investigate | escalate"
  exit 1
fi

# ── Fetch most recent pending record ─────────────────────────────────────────
RESUME_URL=$(docker exec -i postgres psql -U n8n -d n8n -t -A \
  -c "SELECT resume_url FROM pending_analysis WHERE status='pending' ORDER BY created_at DESC LIMIT 1;")

ALERT_ID=$(docker exec -i postgres psql -U n8n -d n8n -t -A \
  -c "SELECT alert_id FROM pending_analysis WHERE status='pending' ORDER BY created_at DESC LIMIT 1;")

if [ -z "${RESUME_URL}" ]; then
  echo "No pending alert found. Run ./show_pending.sh to check."
  exit 1
fi

echo "Alert ID   : ${ALERT_ID}"
echo "Resume URL : ${RESUME_URL}"
echo "Verdict    : ${VERDICT} (confidence: ${CONFIDENCE})"
echo ""

# Escape reasoning for JSON
REASONING_ESCAPED=$(echo "${REASONING}" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

# ── POST verdict to N8N resume URL ───────────────────────────────────────────
HTTP_CODE=$(curl \
  --silent \
  --output /tmp/send_response_reply.json \
  --write-out "%{http_code}" \
  --max-time 15 \
  --request POST \
  --header "Content-Type: application/json" \
  --data "{
    \"alert_id\": \"${ALERT_ID}\",
    \"verdict\": \"${VERDICT}\",
    \"confidence\": ${CONFIDENCE},
    \"reasoning\": \"${REASONING_ESCAPED}\",
    \"action\": \"${ACTION}\",
    \"context_factors\": [],
    \"rule_tuning_suggestion\": null
  }" \
  "${RESUME_URL}")

echo "HTTP response : ${HTTP_CODE}"
if [ -s /tmp/send_response_reply.json ]; then
  cat /tmp/send_response_reply.json
fi
echo ""

# ── Verify result saved to DB ─────────────────────────────────────────────────
echo "Checking DB result (3s)..."
sleep 3
docker exec -i postgres psql -U n8n -d n8n \
  -c "SELECT alert_id, verdict, confidence, action, mcp_enriched, processed_at
      FROM ai_analysis_results
      ORDER BY processed_at DESC
      LIMIT 1;"
