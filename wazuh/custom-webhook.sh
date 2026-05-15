#!/bin/bash
# custom-webhook — Wazuh custom integration script
# =================================================
# Called by wazuh-integratord when an alert matches the <integration> block
# in ossec.conf.
#
# INSTALLATION:
#   sudo cp custom-webhook.sh /var/ossec/integrations/custom-webhook
#   sudo chmod 750 /var/ossec/integrations/custom-webhook
#   sudo chown root:wazuh /var/ossec/integrations/custom-webhook
#   sudo systemctl restart wazuh-manager
#
# WAZUH INTEGRATORD CALL SIGNATURE:
#   $1 = path to the alert JSON file  (e.g. /tmp/ossec-alert-XXXX.json)
#   $2 = API key                      (from <api_key> in ossec.conf, empty if not set)
#   $3 = hook_url                     (from <hook_url> in ossec.conf)
#
# KNOWN ISSUE — DOUBLE INVOCATION (Wazuh 4.9):
#   wazuh-integratord may call this script TWICE per alert.
#   Mitigation options:
#     1. Add ON CONFLICT (alert_id) DO NOTHING in the N8N DB node (recommended).
#     2. Use a lock file (see DEDUP_LOCK section below — disabled by default).
#   The double-call does NOT indicate a configuration error.
#
# LOGGING:
#   Output is captured by integratord and written to:
#   /var/ossec/logs/integrations.log
#   Tail it during testing:
#     sudo tail -f /var/ossec/logs/integrations.log
#
# TESTING (without restarting wazuh-manager):
#   sudo -u wazuh bash /var/ossec/integrations/custom-webhook \
#     /tmp/test-alert.json "" "http://YOUR-N8N-HOST-IP:5678/webhook/wazuh-alerts"

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────────────────────
ALERT_FILE="${1}"
# API_KEY="${2}"     # not used in this integration
HOOK_URL="${3}"

# ── Validate input ───────────────────────────────────────────────────────────
if [[ -z "${ALERT_FILE}" ]]; then
  echo "[custom-webhook] ERROR: no alert file path provided (arg \$1 is empty)" >&2
  exit 1
fi

if [[ ! -f "${ALERT_FILE}" ]]; then
  echo "[custom-webhook] ERROR: alert file not found: ${ALERT_FILE}" >&2
  exit 1
fi

if [[ -z "${HOOK_URL}" ]]; then
  echo "[custom-webhook] ERROR: no hook_url provided (arg \$3 is empty)" >&2
  exit 1
fi

# ── Optional: deduplication lock (disabled by default) ───────────────────────
# Uncomment if you experience duplicate DB entries and prefer to handle them
# here rather than in the N8N workflow.
#
# ALERT_ID=$(python3 -c "
# import json, sys
# try:
#   d = json.load(open('${ALERT_FILE}'))
#   print(d.get('id', d.get('_id', '')))
# except:
#   print('')
# " 2>/dev/null)
#
# if [[ -n "${ALERT_ID}" ]]; then
#   LOCK_FILE="/tmp/wazuh-webhook-${ALERT_ID}.lock"
#   if [[ -f "${LOCK_FILE}" ]]; then
#     echo "[custom-webhook] SKIP duplicate alert_id=${ALERT_ID}"
#     exit 0
#   fi
#   touch "${LOCK_FILE}"
#   # Clean up lock after 10 seconds (background)
#   (sleep 10 && rm -f "${LOCK_FILE}") &
# fi

# ── Read alert JSON ───────────────────────────────────────────────────────────
ALERT_JSON=$(cat "${ALERT_FILE}")

if [[ -z "${ALERT_JSON}" ]]; then
  echo "[custom-webhook] ERROR: alert file is empty: ${ALERT_FILE}" >&2
  exit 1
fi

# ── POST to N8N webhook ───────────────────────────────────────────────────────
HTTP_CODE=$(curl \
  --silent \
  --output /dev/null \
  --write-out "%{http_code}" \
  --max-time 10 \
  --retry 2 \
  --retry-delay 2 \
  --request POST \
  --header "Content-Type: application/json" \
  --data "${ALERT_JSON}" \
  "${HOOK_URL}")

# ── Result logging ────────────────────────────────────────────────────────────
if [[ "${HTTP_CODE}" =~ ^2 ]]; then
  echo "[custom-webhook] OK http=${HTTP_CODE} file=${ALERT_FILE}"
  exit 0
else
  echo "[custom-webhook] WARN unexpected http=${HTTP_CODE} url=${HOOK_URL} file=${ALERT_FILE}" >&2
  # Exit 0 to prevent integratord from marking the integration as failed
  # and triggering its internal retry loop (which would worsen the double-call issue).
  exit 0
fi
