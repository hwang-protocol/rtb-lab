#!/usr/bin/env python3
"""生成 Grafana 大盘 JSON：python3 make_dashboard.py > rtb-overview.json"""
import json

# 压测程序 60 秒内有上报才显示它的数据（否则 textfile 里残留的旧数值会一直挂在图上）
LOADGEN_ALIVE = "and on() (time() - loadgen_last_report_timestamp_seconds < 10)"
CPU_COUNT = "scalar(count(count by (cpu)(node_cpu_seconds_total)))"

panels_spec = [
    ("row", "⓪ 告警（Prometheus 规则 → Alertmanager）"),
    ("正在触发的告警（firing）", "short", True, [
        ('sum by (alertname)(ALERTS{alertstate="firing"})', "{{alertname}}"),
    ]),
    ("即将触发的告警（pending：条件已满足，还在等 for 的时间）", "short", True, [
        ('sum by (alertname)(ALERTS{alertstate="pending"})', "{{alertname}}"),
    ]),
    ("row", "① 用户体验：延迟与流量"),
    ("客户端延迟（压测程序看到的，含建连、排队）", "ms", False, [
        (f"loadgen_latency_seconds{{quantile=\"0.5\"}} * 1000 {LOADGEN_ALIVE}", "P50"),
        (f"loadgen_latency_seconds{{quantile=\"0.99\"}} * 1000 {LOADGEN_ALIVE}", "P99"),
        (f"loadgen_latency_seconds{{quantile=\"0.999\"}} * 1000 {LOADGEN_ALIVE}", "P99.9"),
    ]),
    ("服务端处理耗时（竞价服务自己统计的）", "ms", False, [
        ("histogram_quantile(0.5, sum by (le)(rate(bidder_latency_seconds_bucket[30s]))) * 1000", "P50"),
        ("histogram_quantile(0.99, sum by (le)(rate(bidder_latency_seconds_bucket[30s]))) * 1000", "P99"),
        ("histogram_quantile(0.999, sum by (le)(rate(bidder_latency_seconds_bucket[30s]))) * 1000", "P99.9"),
    ]),
    ("请求速率（每秒）", "reqps", False, [
        ("rate(bidder_requests_total[30s])", "收到的请求"),
        ("rate(bidder_bids_total[30s])", "出价 200"),
        ("rate(bidder_nobids_total[30s])", "不出价 204"),
        (f"loadgen_target_rps {LOADGEN_ALIVE}", "压测目标速率"),
    ]),
    ("错误（每秒）", "reqps", False, [
        ("rate(bidder_errors_total[30s])", "服务端 500"),
        ("rate(loadgen_errors_total[30s])", "客户端：超时 / 连接错误"),
    ]),
    ("row", "② 系统资源（node_exporter）"),
    ("CPU 使用率（按类型堆叠，100% = 全部核）", "percent", True, [
        (f"sum by (mode)(rate(node_cpu_seconds_total{{mode=~\"user|system|softirq|irq|iowait|steal|nice\"}}[30s])) / {CPU_COUNT} * 100", "{{mode}}"),
    ]),
    ("负载（load average）", "short", False, [
        ("node_load1", "1 分钟"),
        ("node_load5", "5 分钟"),
        (CPU_COUNT.replace("scalar(", "(", 1), "CPU 核数"),
    ]),
    ("TCP 连接", "short", False, [
        ("node_netstat_Tcp_CurrEstab", "ESTABLISHED"),
        ("node_sockstat_TCP_tw", "TIME-WAIT"),
        ("rate(node_netstat_Tcp_ActiveOpens[30s])", "每秒新建连接（主动）"),
        ("rate(node_netstat_Tcp_PassiveOpens[30s])", "每秒新建连接（被动/服务端）"),
    ]),
    ("上下文切换（每秒）", "short", False, [
        ("rate(node_context_switches_total[30s])", "全系统"),
    ]),
    ("row", "③ JVM 与应用内部状态"),
    ("JVM 堆内存使用", "bytes", False, [
        ("jvm_heap_used_bytes", "已用堆"),
    ]),
    ("频次计数表条目数（无过期清理，会一直增长）", "short", False, [
        ("bidder_freq_entries", "条目数"),
    ]),
]


def timeseries(pid, title, unit, stacked, targets, x, y):
    return {
        "id": pid, "type": "timeseries", "title": title,
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "gridPos": {"h": 8, "w": 12, "x": x, "y": y},
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {
                    "lineWidth": 2, "fillOpacity": 25 if stacked else 8, "showPoints": "never",
                    "stacking": {"mode": "normal" if stacked else "none", "group": "A"},
                },
            },
            "overrides": [],
        },
        "options": {
            "legend": {"displayMode": "table", "placement": "bottom", "calcs": ["mean", "max", "lastNotNull"]},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "targets": [
            {"refId": chr(65 + i), "expr": expr, "legendFormat": legend,
             "datasource": {"type": "prometheus", "uid": "prometheus"}}
            for i, (expr, legend) in enumerate(targets)
        ],
    }


def build():
    panels, pid, y, col = [], 1, 0, 0
    for spec in panels_spec:
        if spec[0] == "row":
            if col:  # 换行
                y += 8
                col = 0
            panels.append({"id": pid, "type": "row", "title": spec[1], "collapsed": False,
                           "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})
            pid += 1
            y += 1
            continue
        title, unit, stacked, targets = spec
        panels.append(timeseries(pid, title, unit, stacked, targets, col * 12, y))
        pid += 1
        col += 1
        if col == 2:
            col = 0
            y += 8
    return {
        "uid": "rtb-overview", "title": "RTB Lab 总览", "schemaVersion": 39, "version": 1,
        "editable": True, "refresh": "5s", "time": {"from": "now-15m", "to": "now"},
        "tags": ["rtb-lab"], "timezone": "browser", "panels": panels,
    }


if __name__ == "__main__":
    print(json.dumps(build(), ensure_ascii=False, indent=2))
