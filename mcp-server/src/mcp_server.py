#!/usr/bin/env python3
import os
import requests
from flask import Flask, request, jsonify
from urllib3 import disable_warnings
from datetime import datetime

disable_warnings()
app = Flask(__name__)

class WazuhMCP:
    def __init__(self):
        self.api_url    = os.getenv('WAZUH_API_URL', 'https://$SIEM_HOST:55000')
        self.idx_url    = os.getenv('WAZUH_INDEXER_URL', 'https://$SIEM_HOST:9200')
        self.user       = os.getenv('WAZUH_API_USER', 'n8n-integration')
        self.password   = os.getenv('WAZUH_API_PASSWORD', '')
        self.idx_user   = os.getenv('WAZUH_INDEXER_USER', 'admin')
        self.idx_pass   = os.getenv('WAZUH_INDEXER_PASSWORD', '')
        self.token      = None
        print(f"[{datetime.now()}] MCP initialized — API: {self.api_url} | Indexer: {self.idx_url}")

    # ── JWT per API 55000 ──────────────────────────────────────────────────────
    def get_token(self):
        try:
            r = requests.post(f"{self.api_url}/security/user/authenticate",
                auth=(self.user, self.password), verify=False, timeout=10)
            if r.status_code == 200:
                self.token = r.json()['data']['token']
                print(f"[{datetime.now()}] JWT token OK")
                return True
            print(f"[{datetime.now()}] JWT failed: {r.status_code} {r.text[:100]}")
            return False
        except Exception as e:
            print(f"[{datetime.now()}] JWT error: {e}")
            return False

    def api_headers(self):
        if not self.token:
            self.get_token()
        return {"Authorization": f"Bearer {self.token}"}

    def api_get(self, endpoint, params=None):
        url = f"{self.api_url}{endpoint}"
        r = requests.get(url, headers=self.api_headers(), params=params, verify=False, timeout=10)
        if r.status_code == 401:
            self.token = None
            self.get_token()
            r = requests.get(url, headers=self.api_headers(), params=params, verify=False, timeout=10)
        return r

    # ── Indexer 9200 per gli alert ─────────────────────────────────────────────
    def idx_search(self, query, index="wazuh-alerts-*"):
        r = requests.post(
            f"{self.idx_url}/{index}/_search",
            auth=(self.idx_user, self.idx_pass),
            json=query,
            headers={"Content-Type": "application/json"},
            verify=False, timeout=10
        )
        return r

    # ── Metodi pubblici ────────────────────────────────────────────────────────
    def get_recent_alerts(self, limit=10, level=None, agent_id=None):
        try:
            must = []
            if level:
                must.append({"range": {"rule.level": {"gte": int(level)}}})
            if agent_id:
                must.append({"term": {"agent.id": agent_id}})

            query = {
                "size": limit,
                "sort": [{"timestamp": {"order": "desc"}}],
                "query": {"bool": {"must": must}} if must else {"match_all": {}}
            }
            r = self.idx_search(query)
            if r.status_code == 200:
                hits = r.json().get('hits', {}).get('hits', [])
                alerts = [h['_source'] for h in hits]
                total  = r.json().get('hits', {}).get('total', {}).get('value', len(alerts))
                return {"success": True, "alerts": alerts, "total": total}
            return {"success": False, "error": f"Indexer HTTP {r.status_code}: {r.text[:200]}"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def search_alerts_by_rule(self, rule_id, hours=24):
        try:
            query = {
                "size": 100,
                "sort": [{"timestamp": {"order": "desc"}}],
                "query": {
                    "bool": {
                        "must": [
                            {"term": {"rule.id": str(rule_id)}},
                            {"range": {"timestamp": {"gte": f"now-{hours}h"}}}
                        ]
                    }
                }
            }
            r = self.idx_search(query)
            if r.status_code == 200:
                hits  = r.json().get('hits', {}).get('hits', [])
                total = r.json().get('hits', {}).get('total', {}).get('value', len(hits))
                return {"success": True, "alerts": [h['_source'] for h in hits], "count": total}
            return {"success": False, "error": f"Indexer HTTP {r.status_code}: {r.text[:200]}"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def get_agent_info(self, agent_id):
        try:
            r = self.api_get("/agents", params={"agents_list": agent_id})
            if r.status_code == 200:
                items = r.json().get("data", {}).get("affected_items", [])
                return {"success": True, "agent": items[0] if items else None}
            return {"success": False, "error": f"HTTP {r.status_code}"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def get_rule_details(self, rule_id):
        try:
            r = self.api_get("/rules", params={"rule_ids": rule_id})
            if r.status_code == 200:
                items = r.json().get("data", {}).get("affected_items", [])
                return {"success": True, "rule": items[0] if items else None}
            return {"success": False, "error": f"HTTP {r.status_code}"}
        except Exception as e:
            return {"success": False, "error": str(e)}


wazuh = WazuhMCP()

# ── Flask routes ───────────────────────────────────────────────────────────────

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({"status": "healthy", "service": "MCP Wazuh Server",
                    "timestamp": datetime.now().isoformat()})

@app.route('/tools/get_recent_alerts', methods=['POST'])
def get_recent_alerts():
    d = request.json or {}
    return jsonify(wazuh.get_recent_alerts(
        limit=d.get('limit', 10), level=d.get('level'), agent_id=d.get('agent_id')))

@app.route('/tools/get_agent_info', methods=['POST'])
def get_agent_info():
    d = request.json or {}
    if not d.get('agent_id'):
        return jsonify({"success": False, "error": "agent_id required"}), 400
    return jsonify(wazuh.get_agent_info(d['agent_id']))

@app.route('/tools/get_rule_details', methods=['POST'])
def get_rule_details():
    d = request.json or {}
    if not d.get('rule_id'):
        return jsonify({"success": False, "error": "rule_id required"}), 400
    return jsonify(wazuh.get_rule_details(d['rule_id']))

@app.route('/tools/search_alerts_by_rule', methods=['POST'])
def search_alerts_by_rule():
    d = request.json or {}
    if not d.get('rule_id'):
        return jsonify({"success": False, "error": "rule_id required"}), 400
    return jsonify(wazuh.search_alerts_by_rule(d['rule_id'], d.get('hours', 24)))

@app.route('/analyze_alert', methods=['POST'])
def analyze_alert():
    try:
        alert_data = request.json
        rule_id  = alert_data.get('rule', {}).get('id')
        agent_id = alert_data.get('agent', {}).get('id')
        enriched = {"original_alert": alert_data, "context": {}}
        if rule_id:
            enriched["context"]["rule_details"]       = wazuh.get_rule_details(rule_id)
            enriched["context"]["recent_occurrences"] = wazuh.search_alerts_by_rule(rule_id).get("count", 0)
        if agent_id:
            enriched["context"]["agent_details"] = wazuh.get_agent_info(agent_id)
        return jsonify({"success": True, "enriched_alert": enriched, "ready_for_ai": True})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

if __name__ == '__main__':
    print(f"[{datetime.now()}] Starting MCP Server on port 3333...")
    wazuh.get_token()
    app.run(host='0.0.0.0', port=3333, debug=False)
