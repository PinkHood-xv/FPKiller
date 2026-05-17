#!/bin/bash
# backup.sh — Dump PostgreSQL + export N8N workflows + copy .env
# ===============================================================
# USAGE:
#   ./backup.sh
#
# OUTPUT DIRECTORY:
#   ~/ai-lab/backups/YYYYMMDD/
#     postgres_backup.sql       — full DB dump (all tables and views)
#     n8n_workflows.tar.gz      — N8N workflow JSON exports
#     .env.backup               — copy of the .env file (keep secure!)
#
# AUTOMATED SCHEDULING (crontab — daily at 02:00):
#   0 2 * * * ~/ai-lab/scripts/backup.sh >> ~/ai-lab/logs/backup.log 2>&1
#
# RETENTION:
#   Backups are NOT automatically rotated by this script.
#   Add a cleanup line to crontab if disk space is a concern:
#     find ~/ai-lab/backups -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
#
# RESTORE EXAMPLES:
#   PostgreSQL:
#     docker exec -i postgres psql -U n8n -d n8n < backups/YYYYMMDD/postgres_backup.sql
#   N8N workflows:
#     tar xzf backups/YYYYMMDD/n8n_workflows.tar.gz -C /
#     (then re-import via N8N UI or restart the container)
#
# INSTALL:
#   Place in ~/ai-lab/scripts/
#   chmod +x scripts/backup.sh

set -euo pipefail

BACKUP_BASE="${HOME}/ai-lab/backups"
BACKUP_DIR="${BACKUP_BASE}/$(date +%Y%m%d_%H%M%S)"
ENV_FILE="${HOME}/ai-lab/.env"

echo "[backup] Starting — $(date)"
mkdir -p "${BACKUP_DIR}"

# ── PostgreSQL dump ───────────────────────────────────────────────────────────
echo "[backup] Dumping PostgreSQL..."
docker exec postgres pg_dump -U n8n n8n > "${BACKUP_DIR}/postgres_backup.sql"
echo "[backup] PostgreSQL OK — $(du -sh "${BACKUP_DIR}/postgres_backup.sql" | cut -f1)"

# ── N8N workflows ─────────────────────────────────────────────────────────────
echo "[backup] Exporting N8N workflows..."
docker exec n8n tar czf - /home/node/.n8n/workflows \
  > "${BACKUP_DIR}/n8n_workflows.tar.gz"
echo "[backup] N8N workflows OK — $(du -sh "${BACKUP_DIR}/n8n_workflows.tar.gz" | cut -f1)"

# ── .env (contains API keys — handle carefully) ───────────────────────────────
if [ -f "${ENV_FILE}" ]; then
  cp "${ENV_FILE}" "${BACKUP_DIR}/.env.backup"
  chmod 600 "${BACKUP_DIR}/.env.backup"
  echo "[backup] .env copied (permissions set to 600)"
else
  echo "[backup] WARNING: .env not found at ${ENV_FILE}"
fi

# ── MCP server source ─────────────────────────────────────────────────────────
MCP_SRC="${HOME}/ai-lab/mcp-server"
if [ -d "${MCP_SRC}" ]; then
  tar czf "${BACKUP_DIR}/mcp_server.tar.gz" -C "${HOME}/ai-lab" mcp-server/
  echo "[backup] MCP server source OK"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "[backup] Done — ${BACKUP_DIR}"
echo "[backup] Total size: $(du -sh "${BACKUP_DIR}" | cut -f1)"
ls -lh "${BACKUP_DIR}"
