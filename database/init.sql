-- init.sql — Database schema for Wazuh False Positive Detector
-- =============================================================
-- PostgreSQL 15+
-- Database: n8n  (shared with N8N's own tables)
--
-- Run via:
--   docker exec -i postgres psql -U n8n -d n8n < database/init.sql
--
-- Or interactively:
--   docker exec -it postgres psql -U n8n -d n8n
--
-- TABLE OVERVIEW:
--   ai_analysis_results   Core results table — one row per analysed alert
--   pending_analysis      v5.1 only — alerts waiting for manual AI verdict
--   ground_truth          Optional — human verdicts for accuracy measurement
--   human_feedback        Optional — reviewer feedback loop
--
-- VIEW OVERVIEW:
--   daily_fp_stats        Daily aggregates: total alerts, FP count, avg confidence
--   top_fp_rules          Top 10 rules with most false positives
--   mcp_enrichment_stats  MCP enrichment coverage and impact
--   ai_accuracy_over_time Accuracy trend over time (requires human_feedback)

-- ─────────────────────────────────────────────────────────────────────────────
-- CORE TABLE: ai_analysis_results
-- ─────────────────────────────────────────────────────────────────────────────
-- One row per alert processed (automatically by Ollama/OpenRouter,
-- or manually via the v5.1 human-in-the-loop flow).

CREATE TABLE IF NOT EXISTS ai_analysis_results (
  id           SERIAL       PRIMARY KEY,
  alert_id     VARCHAR(255) NOT NULL,
  rule_id      VARCHAR(50),
  agent_name   VARCHAR(100),
  verdict      VARCHAR(50)  CHECK (verdict IN ('false_positive', 'legitimate_threat', 'uncertain')),
  confidence   INTEGER      CHECK (confidence >= 0 AND confidence <= 100),
  reasoning    TEXT,
  action       VARCHAR(50)  CHECK (action IN ('ignore', 'investigate', 'escalate')),
  rule_tuning  TEXT,
  processed_at TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  mcp_enriched BOOLEAN      DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_verdict      ON ai_analysis_results(verdict);
CREATE INDEX IF NOT EXISTS idx_processed_at ON ai_analysis_results(processed_at);
CREATE INDEX IF NOT EXISTS idx_rule_id      ON ai_analysis_results(rule_id);
CREATE INDEX IF NOT EXISTS idx_mcp_enriched ON ai_analysis_results(mcp_enriched);


-- ─────────────────────────────────────────────────────────────────────────────
-- v5.1 TABLE: pending_analysis
-- ─────────────────────────────────────────────────────────────────────────────
-- Stores alerts suspended mid-execution while waiting for a human
-- to paste the AI verdict via send_response.sh.
-- Not used by v6.1 (Ollama) or v6.2 (OpenRouter).

CREATE TABLE IF NOT EXISTS pending_analysis (
  id            SERIAL       PRIMARY KEY,
  alert_id      VARCHAR(255),           -- Wazuh alert ID
  rule_id       VARCHAR(50),
  agent_name    VARCHAR(100),
  prompt_for_ai TEXT,                   -- full prompt shown to the human operator
  resume_url    TEXT,                   -- N8N webhook-waiting URL to POST verdict to
  mcp_error     BOOLEAN      DEFAULT FALSE,
  status        VARCHAR(20)  DEFAULT 'pending'  -- pending | completed | cancelled
                             CHECK (status IN ('pending', 'completed', 'cancelled')),
  created_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  completed_at  TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_pending_status   ON pending_analysis(status);
CREATE INDEX IF NOT EXISTS idx_pending_alert_id ON pending_analysis(alert_id);

-- Optional: prevent duplicate rows if wazuh-integratord fires twice per alert.
-- Enable after verifying no existing duplicates:
--   ALTER TABLE pending_analysis ADD CONSTRAINT uq_pending_alert_id UNIQUE (alert_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- OPTIONAL TABLE: ground_truth
-- ─────────────────────────────────────────────────────────────────────────────
-- Human-confirmed verdicts for a subset of alerts.
-- Used to measure AI accuracy (see accuracy query at the bottom).

CREATE TABLE IF NOT EXISTS ground_truth (
  alert_id       VARCHAR(255) PRIMARY KEY,
  human_verdict  VARCHAR(50)  NOT NULL
                 CHECK (human_verdict IN ('false_positive', 'legitimate_threat', 'uncertain')),
  notes          TEXT
);

-- Example rows (replace alert_id values with real ones from your lab):
-- INSERT INTO ground_truth VALUES
--   ('wazuh-alert-id-001', 'false_positive',    'SSH from internal admin host'),
--   ('wazuh-alert-id-002', 'legitimate_threat',  'Actual brute force from external IP');


-- ─────────────────────────────────────────────────────────────────────────────
-- OPTIONAL TABLE: human_feedback
-- ─────────────────────────────────────────────────────────────────────────────
-- Reviewer corrections and notes — used to track AI accuracy over time.

CREATE TABLE IF NOT EXISTS human_feedback (
  id             SERIAL       PRIMARY KEY,
  alert_id       VARCHAR(255) REFERENCES ai_analysis_results(alert_id),
  ai_verdict     VARCHAR(50),
  human_verdict  VARCHAR(50),
  feedback_notes TEXT,
  reviewed_by    VARCHAR(100),
  reviewed_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  had_mcp_enrichment BOOLEAN
);

CREATE INDEX IF NOT EXISTS idx_feedback_alert ON human_feedback(alert_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- VIEW: daily_fp_stats
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW daily_fp_stats AS
SELECT
  DATE(processed_at)                                                          AS date,
  COUNT(*)                                                                    AS total_alerts,
  SUM(CASE WHEN verdict = 'false_positive'    THEN 1 ELSE 0 END)             AS false_positives,
  SUM(CASE WHEN verdict = 'legitimate_threat' THEN 1 ELSE 0 END)             AS legitimate_threats,
  SUM(CASE WHEN verdict = 'uncertain'         THEN 1 ELSE 0 END)             AS uncertain,
  SUM(CASE WHEN mcp_enriched = TRUE           THEN 1 ELSE 0 END)             AS mcp_enriched_count,
  ROUND(AVG(confidence), 2)                                                  AS avg_confidence
FROM ai_analysis_results
GROUP BY DATE(processed_at)
ORDER BY date DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- VIEW: top_fp_rules
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW top_fp_rules AS
SELECT
  rule_id,
  COUNT(*)                      AS occurrences,
  ROUND(AVG(confidence), 2)     AS avg_confidence,
  MAX(rule_tuning)              AS suggested_tuning
FROM ai_analysis_results
WHERE verdict = 'false_positive'
GROUP BY rule_id
ORDER BY occurrences DESC
LIMIT 10;


-- ─────────────────────────────────────────────────────────────────────────────
-- VIEW: mcp_enrichment_stats
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW mcp_enrichment_stats AS
SELECT
  mcp_enriched,
  COUNT(*)                                                                    AS count,
  ROUND(AVG(confidence), 2)                                                   AS avg_confidence,
  ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 2)              AS percentage
FROM ai_analysis_results
GROUP BY mcp_enriched;


-- ─────────────────────────────────────────────────────────────────────────────
-- VIEW: ai_accuracy_over_time  (requires human_feedback table to be populated)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW ai_accuracy_over_time AS
SELECT
  DATE(hf.reviewed_at)                                                        AS review_date,
  COUNT(*)                                                                    AS total_reviewed,
  SUM(CASE WHEN ar.verdict = hf.human_verdict THEN 1 ELSE 0 END)             AS correct,
  ROUND(
    100.0 * SUM(CASE WHEN ar.verdict = hf.human_verdict THEN 1 ELSE 0 END)
    / NULLIF(COUNT(*), 0),
    2
  )                                                                           AS accuracy_pct,
  SUM(CASE WHEN hf.had_mcp_enrichment THEN 1 ELSE 0 END)                     AS with_mcp
FROM ai_analysis_results ar
JOIN human_feedback hf ON ar.alert_id = hf.alert_id
GROUP BY DATE(hf.reviewed_at)
ORDER BY review_date;


-- ─────────────────────────────────────────────────────────────────────────────
-- USEFUL QUERIES
-- ─────────────────────────────────────────────────────────────────────────────

-- Daily overview:
--   SELECT * FROM daily_fp_stats LIMIT 7;

-- Top false-positive rules:
--   SELECT * FROM top_fp_rules;

-- MCP enrichment impact:
--   SELECT * FROM mcp_enrichment_stats;

-- Last 10 alerts:
--   SELECT alert_id, rule_id, verdict, confidence, action, mcp_enriched, processed_at
--   FROM ai_analysis_results ORDER BY processed_at DESC LIMIT 10;

-- Accuracy vs ground truth:
--   SELECT
--     COUNT(*)                                                               AS total,
--     SUM(CASE WHEN ar.verdict = gt.human_verdict THEN 1 ELSE 0 END)        AS correct,
--     ROUND(
--       100.0 * SUM(CASE WHEN ar.verdict = gt.human_verdict THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0),
--       2
--     )                                                                      AS accuracy_pct
--   FROM ai_analysis_results ar
--   JOIN ground_truth gt ON ar.alert_id = gt.alert_id;

-- Cleanup: cancel orphaned pending records (stale N8N executions):
--   UPDATE pending_analysis SET status = 'cancelled' WHERE status = 'pending';
