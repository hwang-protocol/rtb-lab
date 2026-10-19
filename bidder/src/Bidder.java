import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;

/**
 * 迷你实时竞价（RTB）服务。
 *
 * 流程：广告交易平台发来竞价请求（简化版 OpenRTB JSON）
 *   → 按 国家+网站类别 找到候选广告活动（campaign）
 *   → 检查预算、用户频次上限
 *   → 计算出价，返回最高的一个；没有合适的就返回 204（不出价）
 *
 * 接口：
 *   POST /bid      竞价
 *   GET  /health   健康检查
 *   GET  /metrics  Prometheus 格式的指标（请求数、出价数、服务端延迟分布）
 *
 * 配置（环境变量）：
 *   BIDDER_PORT      监听端口，默认 8080
 *   BIDDER_THREADS   工作线程数，默认 CPU 核数 × 2
 *   BIDDER_CAMPAIGNS 广告活动数量，默认 2000
 */
public class Bidder {

    // ---------- 广告活动 ----------
    static final class Campaign {
        final String id;
        final String country;
        final String category;
        final long maxBidMicros;          // 最高出价（微元，1 元 = 1,000,000 微元，避免浮点误差）
        final AtomicLong budgetMicros;    // 剩余预算
        final int freqCap;                // 同一用户最多看到几次

        Campaign(String id, String country, String category, long maxBidMicros, long budgetMicros, int freqCap) {
            this.id = id;
            this.country = country;
            this.category = category;
            this.maxBidMicros = maxBidMicros;
            this.budgetMicros = new AtomicLong(budgetMicros);
            this.freqCap = freqCap;
        }
    }

    static final String[] COUNTRIES = {"USA", "CAN", "GBR", "DEU", "JPN", "CHN", "IND", "BRA"};
    static final String[] CATEGORIES = {"IAB1", "IAB2", "IAB3", "IAB12", "IAB17", "IAB19", "IAB20", "IAB22"};

    // 索引：key = 国家|类别，value = 候选广告活动
    static final Map<String, List<Campaign>> INDEX = new HashMap<>();

    // 频次计数：key = campaignId|userId。
    // 注意：这里故意没有过期清理，用户越多占用内存越多——后面可以拿来做"内存泄漏"排查练习。
    static final ConcurrentHashMap<String, AtomicInteger> FREQ = new ConcurrentHashMap<>();

    // ---------- 指标 ----------
    static final LongAdder REQUESTS = new LongAdder();
    static final LongAdder BIDS = new LongAdder();
    static final LongAdder NO_BIDS = new LongAdder();
    static final LongAdder ERRORS = new LongAdder();
    // 服务端处理耗时的分布（单位：毫秒），桶的上界
    static final double[] BUCKETS_MS = {0.1, 0.25, 0.5, 1, 2, 5, 10, 25, 50, 100};
    static final LongAdder[] BUCKET_COUNTS = new LongAdder[BUCKETS_MS.length + 1];
    static final LongAdder LATENCY_SUM_NANOS = new LongAdder();

    static {
        for (int i = 0; i < BUCKET_COUNTS.length; i++) BUCKET_COUNTS[i] = new LongAdder();
    }

    public static void main(String[] args) throws IOException {
        int port = intEnv("BIDDER_PORT", 8080);
        int threads = intEnv("BIDDER_THREADS", Runtime.getRuntime().availableProcessors() * 2);
        int campaigns = intEnv("BIDDER_CAMPAIGNS", 2000);

        loadCampaigns(campaigns);

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 1024);
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        server.setExecutor(pool);
        server.createContext("/bid", Bidder::handleBid);
        server.createContext("/health", ex -> reply(ex, 200, "ok\n", "text/plain; charset=utf-8"));
        // Prometheus 3.x 要求指标接口返回它的文本格式类型，否则拒绝抓取
        server.createContext("/metrics", ex -> reply(ex, 200, metrics(), "text/plain; version=0.0.4; charset=utf-8"));
        server.start();
        System.out.printf("bidder started: port=%d threads=%d campaigns=%d pid=%d%n",
                port, threads, campaigns, ProcessHandle.current().pid());
    }

    // 随机生成广告活动（固定随机种子，保证每次启动数据一样，实验可复现）
    static void loadCampaigns(int n) {
        Random r = new Random(42);
        for (int i = 0; i < n; i++) {
            Campaign c = new Campaign("c-" + i,
                    COUNTRIES[r.nextInt(COUNTRIES.length)],
                    CATEGORIES[r.nextInt(CATEGORIES.length)],
                    500_000 + r.nextInt(4_500_000),        // 最高出价 0.5 ~ 5 元
                    1_000_000_000_000L,                    // 预算给得很大，避免实验中途用完
                    3 + r.nextInt(8));                     // 频次上限 3 ~ 10
            INDEX.computeIfAbsent(c.country + "|" + c.category, k -> new ArrayList<>()).add(c);
        }
    }

    static void handleBid(HttpExchange ex) throws IOException {
        long start = System.nanoTime();
        REQUESTS.increment();
        try {
            if (!"POST".equals(ex.getRequestMethod())) {
                reply(ex, 405, "");
                return;
            }
            String body = readBody(ex.getRequestBody());

            String reqId = str(body, "\"id\":\"");
            String impId = str(body, "\"imp\":[{\"id\":\"");
            double floor = num(body, "\"bidfloor\":");
            String category = str(body, "\"cat\":[\"");
            String country = str(body, "\"country\":\"");
            String userId = str(body, "\"user\":{\"id\":\"");

            long floorMicros = (long) (floor * 1_000_000);
            List<Campaign> candidates = INDEX.getOrDefault(country + "|" + category, List.of());

            Campaign best = null;
            long bestPrice = 0;
            for (Campaign c : candidates) {
                long price = score(c, userId, floorMicros);
                if (price <= bestPrice || price < floorMicros) continue;
                if (c.budgetMicros.get() < price) continue;
                AtomicInteger seen = FREQ.get(c.id + "|" + userId);
                if (seen != null && seen.get() >= c.freqCap) continue;
                best = c;
                bestPrice = price;
            }

            if (best == null) {
                NO_BIDS.increment();
                reply(ex, 204, null);
            } else {
                best.budgetMicros.addAndGet(-bestPrice);
                FREQ.computeIfAbsent(best.id + "|" + userId, k -> new AtomicInteger()).incrementAndGet();
                BIDS.increment();
                String resp = "{\"id\":\"" + reqId + "\",\"seatbid\":[{\"bid\":[{\"id\":\"b-" + reqId
                        + "\",\"impid\":\"" + impId + "\",\"price\":" + (bestPrice / 1_000_000.0)
                        + ",\"crid\":\"" + best.id + "\"}]}]}";
                reply(ex, 200, resp);
            }
        } catch (Exception e) {
            ERRORS.increment();
            reply(ex, 500, "");
        } finally {
            record(System.nanoTime() - start);
        }
    }

    // "出价模型"：用 用户×活动 的哈希模拟一个预测分数（真实系统这里是机器学习模型）
    static long score(Campaign c, String userId, long floorMicros) {
        int h = (c.id.hashCode() * 31 + userId.hashCode()) & 0x7fffffff;
        double ctr = (h % 1000) / 1000.0;            // 0 ~ 1 的"预测点击率"
        long price = (long) (floorMicros * (1.0 + ctr));
        return Math.min(price, c.maxBidMicros);
    }

    // ---------- 极简 JSON 取值（实验用；生产系统应使用 JSON 库）----------
    static String str(String s, String key) {
        int i = s.indexOf(key);
        if (i < 0) return "";
        int from = i + key.length();
        int to = s.indexOf('"', from);
        return to < 0 ? "" : s.substring(from, to);
    }

    static double num(String s, String key) {
        int i = s.indexOf(key);
        if (i < 0) return 0;
        int from = i + key.length();
        int to = from;
        while (to < s.length() && "0123456789.".indexOf(s.charAt(to)) >= 0) to++;
        return to == from ? 0 : Double.parseDouble(s.substring(from, to));
    }

    static String readBody(InputStream in) throws IOException {
        byte[] b = in.readAllBytes();
        return new String(b, StandardCharsets.UTF_8);
    }

    static void reply(HttpExchange ex, int code, String body) throws IOException {
        reply(ex, code, body, "application/json");
    }

    static void reply(HttpExchange ex, int code, String body, String contentType) throws IOException {
        if (body == null) {
            ex.sendResponseHeaders(code, -1);   // 204：没有响应体
        } else {
            byte[] b = body.getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().set("Content-Type", contentType);
            ex.sendResponseHeaders(code, b.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(b);
            }
        }
        ex.close();
    }

    static void record(long nanos) {
        LATENCY_SUM_NANOS.add(nanos);
        double ms = nanos / 1_000_000.0;
        for (int i = 0; i < BUCKETS_MS.length; i++) {
            if (ms <= BUCKETS_MS[i]) {
                BUCKET_COUNTS[i].increment();
                return;
            }
        }
        BUCKET_COUNTS[BUCKETS_MS.length].increment();
    }

    static String metrics() {
        StringBuilder sb = new StringBuilder();
        // 每个指标先写 HELP（说明）和 TYPE（类型：counter 只增不减 / gauge 可增可减 / histogram 分布）
        sb.append("# HELP bidder_requests_total 收到的竞价请求总数\n# TYPE bidder_requests_total counter\n");
        sb.append("bidder_requests_total ").append(REQUESTS.sum()).append('\n');
        sb.append("# HELP bidder_bids_total 出价（HTTP 200）次数\n# TYPE bidder_bids_total counter\n");
        sb.append("bidder_bids_total ").append(BIDS.sum()).append('\n');
        sb.append("# HELP bidder_nobids_total 不出价（HTTP 204）次数\n# TYPE bidder_nobids_total counter\n");
        sb.append("bidder_nobids_total ").append(NO_BIDS.sum()).append('\n');
        sb.append("# HELP bidder_errors_total 处理出错次数\n# TYPE bidder_errors_total counter\n");
        sb.append("bidder_errors_total ").append(ERRORS.sum()).append('\n');
        sb.append("# HELP bidder_freq_entries 频次计数表的条目数（没有过期清理，会一直增长）\n# TYPE bidder_freq_entries gauge\n");
        sb.append("bidder_freq_entries ").append(FREQ.size()).append('\n');
        sb.append("# HELP bidder_latency_seconds 服务端处理一次竞价请求的耗时\n# TYPE bidder_latency_seconds histogram\n");
        long cumulative = 0;
        for (int i = 0; i < BUCKETS_MS.length; i++) {
            cumulative += BUCKET_COUNTS[i].sum();
            sb.append("bidder_latency_seconds_bucket{le=\"").append(BUCKETS_MS[i] / 1000.0).append("\"} ")
              .append(cumulative).append('\n');
        }
        cumulative += BUCKET_COUNTS[BUCKETS_MS.length].sum();
        sb.append("bidder_latency_seconds_bucket{le=\"+Inf\"} ").append(cumulative).append('\n');
        sb.append("bidder_latency_seconds_sum ").append(LATENCY_SUM_NANOS.sum() / 1e9).append('\n');
        sb.append("bidder_latency_seconds_count ").append(cumulative).append('\n');
        Runtime rt = Runtime.getRuntime();
        sb.append("# HELP jvm_heap_used_bytes JVM 堆内存已使用字节数\n# TYPE jvm_heap_used_bytes gauge\n");
        sb.append("jvm_heap_used_bytes ").append(rt.totalMemory() - rt.freeMemory()).append('\n');
        return sb.toString();
    }

    static int intEnv(String name, int def) {
        String v = System.getenv(name);
        return v == null || v.isBlank() ? def : Integer.parseInt(v.trim());
    }
}
