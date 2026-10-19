#!/usr/bin/env python3
"""本地告警接收器：接收 Alertmanager 的 webhook 通知，打印成易读的一行行日志（写进 journald）。

真实环境里，这个位置是 Slack / 邮件 / PagerDuty 等通知渠道；实验环境用它来观察告警的触发与恢复。
查看：journalctl -u alert-receiver -f
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length) or b"{}")
        for a in payload.get("alerts", []):
            status = "🔥 触发" if a.get("status") == "firing" else "✅ 恢复"
            labels, ann = a.get("labels", {}), a.get("annotations", {})
            print(f"[{status}] {labels.get('severity', '-'):8} {labels.get('alertname', '?'):26} "
                  f"{ann.get('summary', '')} | 排查: {ann.get('hint', '-')} | 开始于 {a.get('startsAt', '')[:19]}",
                  flush=True)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):   # 不打印默认的访问日志
        pass


if __name__ == "__main__":
    print("alert-receiver listening on 127.0.0.1:9095", flush=True)
    HTTPServer(("127.0.0.1", 9095), Handler).serve_forever()
