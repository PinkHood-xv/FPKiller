Bug Fix Log — FPKiller

All IP addresses use variable notation. See [ARCHITECTURE.md](ARCHITECTURE.md) for the variable reference table.


---
 
## Summary Table
 
| ID | Component | Symptom | Status |
|---|---|---|---|
| [FIX-01](#fix-01--wazuh-host-misconfigured-in-all-config-files) | Infrastructure | MCP cannot reach Wazuh, agent never connects | ✅ Fixed |
| [FIX-02](#fix-02--wazuh-indexer-bound-to-localhost-only) | Wazuh Indexer | Port 9200 unreachable from MCP server | ✅ Fixed |
| [FIX-03](#fix-03--mcp-server-used-basic-auth-instead-of-jwt) | MCP Server | `/rules` and `/agents` endpoints return 401 | ✅ Fixed |
| [FIX-04](#fix-04--alerts-endpoint-removed-in-wazuh-49) | MCP Server | Alert enrichment always fails with 404 | ✅ Fixed |
| [FIX-05](#fix-05--indexer-credentials-missing-from-docker-compose) | Docker | MCP cannot authenticate to OpenSearch | ✅ Fixed |
| [FIX-06](#fix-06--n8n-secure-cookie-blocks-http-access) | N8N | N8N login loop when accessed via IP | ✅ Fixed |
| [FIX-07](#fix-07--n8n-214-webhook-node-wraps-payload-in-body) | N8N 2.1.4 | `$json.rule` is undefined after webhook | ✅ Fixed |
| [FIX-08](#fix-08--n8n-214-wait-node-also-wraps-resume-payload-in-body) | N8N 2.1.4 | AI response data missing after Wait resume | ✅ Fixed |
| [FIX-09](#fix-09--n8n-214-positional-parameters-1-2-not-substituted) | N8N 2.1.4 | SQL INSERT silently writes null values | ✅ Fixed |
| [FIX-10](#fix-10--n8n-214-resumeurl-format-misunderstood) | N8N 2.1.4 | `send_response.sh` gets 404 on resume URL | ✅ Fixed |
| [FIX-11](#fix-11--n8n-214-set-node-drops-all-upstream-fields) | N8N 2.1.4 | Fields disappear between nodes | ✅ Fixed |
| [FIX-12](#fix-12--n8n-214-cross-node-reference-fails-in-code-nodes) | N8N 2.1.4 | `$('NodeName').item.json` throws read-only error | ✅ Fixed |
| [FIX-13](#fix-13--n8n-214-postgres-boolean-type-mismatch) | N8N 2.1.4 | Insert fails on `mcp_enriched` boolean column | ✅ Fixed |
| [FIX-14](#fix-14--n8n-214-postgres-update-node-overwrites-json-output) | N8N 2.1.4 | Data lost between sequential Postgres nodes | ✅ Fixed |
| [PEND-01](#pend-01--wazuh-integratord-calls-webhook-twice-per-alert) | Wazuh | Every alert creates 2 duplicate pending rows | ⏳ Pending |
 
---

## Pending Fixes
 
---
 
### PEND-01 — Wazuh integratord calls webhook twice per alert
 
**Session discovered:** 2026-03-22
 
**Symptom:**
- Every alert generates exactly 2 rows in `pending_analysis` with the same `alert_id`
- `show_pending.sh` shows 2 pending entries per event
- `send_response.sh` processes only the most recent one; the older duplicate stays in `pending` status indefinitely
**Root cause:**
`wazuh-integratord` version 4.9 calls the custom integration script twice per alert as part of its internal retry/confirmation mechanism. This behaviour is internal to the integratord process and cannot be disabled in `ossec.conf`.
 
**Fix planned — 3 steps:**
 
**Step 1 — Add UNIQUE constraint to `pending_analysis`:**
 
```sql
ALTER TABLE pending_analysis
  ADD CONSTRAINT uq_pending_alert_id UNIQUE (alert_id);
```
 
**Step 2 — Update `Save Pending to DB` node SQL with `ON CONFLICT DO NOTHING`:**
 
```sql
INSERT INTO pending_analysis
  (alert_id, rule_id, agent_name, prompt_for_ai, resume_url, mcp_error, status)
VALUES (
  '{{ $json.alert_id }}',
  '{{ $json.rule_id }}',
  '{{ $json.agent_name }}',
  '{{ $json.prompt_for_ai.replace(/\\/g, "\\\\").replace(/'/g, "''") }}',
  '{{ $json.resume_url }}',
  {{ $json.mcp_error_int }}::boolean,
  'pending'
)
ON CONFLICT (alert_id) DO NOTHING
RETURNING id, alert_id, resume_url;
```
 
When the second call arrives for the same `alert_id`, the INSERT is silently skipped and `RETURNING` produces an empty result set.
 
**Step 3 — Add IF node after `Save Pending to DB` to handle the empty RETURNING:**
 
The `Wait` node must only be reached when the INSERT actually succeeded (i.e. when `RETURNING` produced a row). A gating IF node checks for this:
 
```
Condition: {{ $json.id }} is not empty
  TRUE  → Wait for AI Response   (first call — proceed normally)
  FALSE → No Operation / End     (second call — duplicate, terminate branch)
```
 
**Current workaround:**
 
Clean up orphaned duplicates manually:
 
```bash
# Cancel all duplicate pending entries, keeping only the most recent per alert_id
docker exec -it postgres psql -U n8n -d n8n -c "
DELETE FROM pending_analysis
WHERE id NOT IN (
  SELECT MAX(id) FROM pending_analysis
  WHERE status = 'pending'
  GROUP BY alert_id
) AND status = 'pending';"
```
 
**Status:** The `init.sql` in this repository already includes the UNIQUE constraint. The `ON CONFLICT` SQL and the IF node must be applied manually to the imported workflow JSON until the next workflow version is released.
 
---
 
## Cleanup Commands Reference
 
Useful during debugging — safe to run at any time.
 
**Cancel all orphaned pending entries** (executions that were stopped or timed out):
 
```bash
docker exec -it postgres psql -U n8n -d n8n \
  -c "UPDATE pending_analysis SET status='cancelled' WHERE status='pending';"
```
 
**Delete orphaned waiting executions from N8N's internal table:**
 
```bash
docker exec -it postgres psql -U n8n -d n8n \
  -c "DELETE FROM execution_entity WHERE status='waiting';"
```
 
**Find the webhookId of the Wait node in the active workflow:**
 
```bash
docker exec -it postgres psql -U n8n -d n8n -t -A \
  -c "SELECT elem->>'webhookId', elem->>'name'
      FROM workflow_entity,
           json_array_elements(nodes) AS elem
      WHERE name LIKE '%Wazuh%'
        AND elem->>'type' = 'n8n-nodes-base.wait';"
```
 
**Test resume URL formats to find the working one:**
 
```bash
EXEC_ID=<your_execution_id>
for SUFFIX in "" "/wait-ai-response"; do
  URL="http://$AI_HOST:5678/webhook-waiting/${EXEC_ID}${SUFFIX}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$URL" \
    -H "Content-Type: application/json" -d '{"test":1}')
  echo "POST ${URL} → ${CODE}"
done
# In N8N 2.1.4: the URL without suffix returns 200
```
 
---
 
*See also: [WORKFLOW_KNOWLEDGE_BASE.md](WORKFLOW_KNOWLEDGE_BASE.md) for the full N8N 2.1.4 behaviour reference and node-by-node configuration details.*
 
*Part of the AI-SIEM False Positive Detector project — see [README.md](../README.md) for overview.*

