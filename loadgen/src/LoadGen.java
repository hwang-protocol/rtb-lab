import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.time.Duration;
import java.util.Arrays;
import java.util.Random;
import java.util.concurrent.CompletionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.LongAdder;
import java.util.concurrent.locks.LockSupport;

/**
 * 压测程序：模拟广告交易平台，以固定速率（开环）发送竞价请求。
 *
 * 用法：java LoadGen <url> <每秒请求数> <压测秒数> [预热秒数=5] [超时毫秒=50] [最大并发=2000]
 * 例子：java LoadGen http://127.0.0.1:8080/bid 2000 30
 *
 * 为什么用"开环 + 从计划时间计时"：
 *   普通压测工具常常是"上一个请求回来了再发下一个"（闭环）。服务一卡住，压测工具也跟着停发，
 *   卡顿期间本该到达的请求根本没被发出，统计出来的 P99 会好看得不真实（coordinated omission）。
 *   真实的广告交易平台不会等你：请求按自己的节奏不停涌来。所以这里按时间表发送，
 *   延迟 = 收到响应的时间 - 按计划应该发出的时间。
 */
public class LoadGen {

    static final String[] COUNTRIES = {"USA", "USA", "USA", "CAN", "GBR", "DEU", "JPN", "CHN", "IND", "BRA"};
    static final String[] CATEGORIES = {"IAB1", "IAB2", "IAB3", "IAB12", "IAB17", "IAB19", "IAB20", "IAB22"};
    static final String[] DOMAINS = {"news.example.com", "sports.example.com", "tech.example.org",
            "recipes.example.net", "travel.example.com", "games.example.io"};

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("用法: java LoadGen <url> <rps> <秒数> [预热秒数=5] [超时毫秒=50] [最大并发=2000]");
            System.exit(1);
        }
        URI uri = URI.create(args[0]);
        int rps = Integer.parseInt(args[1]);
        int seconds = Integer.parseInt(args[2]);
        int warmup = args.length > 3 ? Integer.parseInt(args[3]) : 5;
        int timeoutMs = args.length > 4 ? Integer.parseInt(args[4]) : 50;
        int maxInFlight = args.length > 5 ? Integer.parseInt(args[5]) : 2000;

        String[] bodies = buildBodies(20_000, 100_000);
        ExecutorService callbackPool = Executors.newFixedThreadPool(2);
        HttpClient client = HttpClient.newBuilder()
                .version(HttpClient.Version.HTTP_1_1)
                .connectTimeout(Duration.ofSeconds(2))
                .executor(callbackPool)
                .build();

        System.out.printf("预热 %d 秒 ...%n", warmup);
        run(client, uri, bodies, rps, warmup, timeoutMs, maxInFlight, null);

        System.out.printf("正式压测：%d 请求/秒 × %d 秒，超时 %d ms%n", rps, seconds, timeoutMs);
        Stats st = new Stats(rps * seconds);
        long t0 = System.nanoTime();
        run(client, uri, bodies, rps, seconds, timeoutMs, maxInFlight, st);
        double elapsed = (System.nanoTime() - t0) / 1e9;
        st.print(elapsed);
        callbackPool.shutdownNow();
        System.exit(0);
    }

    static void run(HttpClient client, URI uri, String[] bodies, int rps, int seconds,
                    int timeoutMs, int maxInFlight, Stats st) throws InterruptedException {
        long total = (long) rps * seconds;
        long intervalNanos = 1_000_000_000L / rps;
        Semaphore inFlight = new Semaphore(maxInFlight);
        AtomicInteger outstanding = new AtomicInteger();
        long start = System.nanoTime();

        for (long i = 0; i < total; i++) {
            long intended = start + i * intervalNanos;
            long wait = intended - System.nanoTime();
            if (wait > 0) LockSupport.parkNanos(wait);

            if (!inFlight.tryAcquire()) {           // 并发打满：说明服务端已经严重积压
                if (st != null) st.overload.increment();
                continue;
            }
            HttpRequest req = HttpRequest.newBuilder(uri)
                    .timeout(Duration.ofMillis(timeoutMs))
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(bodies[(int) (i % bodies.length)]))
                    .build();
            outstanding.incrementAndGet();
            client.sendAsync(req, HttpResponse.BodyHandlers.discarding()).whenComplete((resp, err) -> {
                long latency = System.nanoTime() - intended;
                if (st != null) {
                    if (err == null) {
                        st.record(latency);
                        if (resp.statusCode() == 200) st.bid.increment();
                        else if (resp.statusCode() == 204) st.noBid.increment();
                        else st.httpError.increment();
                    } else {
                        Throwable cause = err instanceof CompletionException && err.getCause() != null ? err.getCause() : err;
                        if (cause instanceof HttpTimeoutException) st.timeout.increment();
                        else st.ioError.increment();
                    }
                }
                inFlight.release();
                outstanding.decrementAndGet();
            });
        }
        // 等待剩余请求完成（最多等超时时间 + 1 秒）
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs + 1000);
        while (outstanding.get() > 0 && System.nanoTime() < deadline) Thread.sleep(5);
    }

    // 预先生成请求体（简化版 OpenRTB 2.x），避免压测过程中拼字符串影响测量
    static String[] buildBodies(int n, int users) {
        Random r = new Random(7);
        String[] out = new String[n];
        for (int i = 0; i < n; i++) {
            double floor = 0.2 + r.nextInt(180) / 100.0;   // 底价 0.2 ~ 2.0
            out[i] = "{\"id\":\"req-" + i + "\",\"imp\":[{\"id\":\"1\",\"bidfloor\":" + floor
                    + ",\"banner\":{\"w\":300,\"h\":250}}],\"site\":{\"domain\":\"" + DOMAINS[r.nextInt(DOMAINS.length)]
                    + "\",\"cat\":[\"" + CATEGORIES[r.nextInt(CATEGORIES.length)] + "\"]},\"device\":{\"geo\":{\"country\":\""
                    + COUNTRIES[r.nextInt(COUNTRIES.length)] + "\"}},\"user\":{\"id\":\"u-" + r.nextInt(users)
                    + "\"},\"tmax\":50}";
        }
        return out;
    }

    static final class Stats {
        final long[] lat;
        final AtomicInteger n = new AtomicInteger();
        final LongAdder bid = new LongAdder(), noBid = new LongAdder(), httpError = new LongAdder(),
                timeout = new LongAdder(), ioError = new LongAdder(), overload = new LongAdder();

        Stats(int capacity) { lat = new long[capacity]; }

        void record(long nanos) {
            int i = n.getAndIncrement();
            if (i < lat.length) lat[i] = nanos;
        }

        void print(double elapsedSec) {
            int cnt = Math.min(n.get(), lat.length);
            long[] a = Arrays.copyOf(lat, cnt);
            Arrays.sort(a);
            long sent = bid.sum() + noBid.sum() + httpError.sum() + timeout.sum() + ioError.sum();
            System.out.println("-------------------------------------------");
            System.out.printf("完成请求  %d（实际速率 %.0f/秒）%n", sent, sent / elapsedSec);
            System.out.printf("出价 200  %d   不出价 204  %d   HTTP 错误 %d%n", bid.sum(), noBid.sum(), httpError.sum());
            System.out.printf("超时      %d (%.3f%%)   连接错误 %d   并发打满丢弃 %d%n",
                    timeout.sum(), 100.0 * timeout.sum() / Math.max(1, sent + overload.sum()), ioError.sum(), overload.sum());
            if (cnt > 0) {
                System.out.printf("延迟 ms   P50 %.3f | P90 %.3f | P99 %.3f | P99.9 %.3f | 最大 %.3f%n",
                        p(a, 50), p(a, 90), p(a, 99), p(a, 99.9), a[cnt - 1] / 1e6);
            }
            System.out.println("-------------------------------------------");
        }

        static double p(long[] sorted, double pct) {
            int idx = (int) Math.ceil(pct / 100.0 * sorted.length) - 1;
            return sorted[Math.max(0, Math.min(idx, sorted.length - 1))] / 1e6;
        }
    }
}
