# 一直问"为什么"：内存泄漏 → OOM，fd 耗尽

> 讨论稿。两个故障都**还没在 rtb-lab 上做实验**：下面的现象和结论，一部分来自虚拟机上的真实输出（标了 ✅ 实测），其余是根据原理做的**预测**（标了 🔮 待验证），做完实验再改成实测数据。

---

## 0. 先搞懂：fd 是什么

**fd（file descriptor，文件描述符）就是一个整数编号。** 进程每打开一个"东西"，内核就发给它一个号码，之后进程只拿号码说话：`read(5, ...)`、`write(5, ...)`、`close(5)`。

"东西"不只是文件。Linux 的设计是"一切皆文件"，所以这些都占 fd：

| 打开的东西 | 例子 |
|---|---|
| 普通文件 | 日志文件 gc.log |
| 网络连接（socket） | 每一个 HTTP 连接 |
| 管道 | `ls \| grep` 中间那根管子 |
| epoll 等内核对象 | 高性能服务器用来同时盯住几千个连接 |

✅ **实测：rtb-bidder 进程现在打开了哪些 fd**（`sudo ls -l /proc/<pid>/fd`）

```
0 -> /dev/null                    标准输入（systemd 给服务接到了空设备）
1 -> socket:[1389424]             标准输出 → 接到 journald（所以 print 的内容进了日志）
2 -> socket:[1389424]             标准错误 → 同上
3 -> .../java-21-openjdk.../lib/modules   JVM 自己的类库文件
4 -> /var/log/rtb-bidder/gc.log   GC 日志
5 -> socket:[1390413]             本机内部的 Unix socket（JVM 内部使用）
6 -> socket:[1390420]             监听 8080 端口的 socket（用 ss -tlnpe 查到 ino:1390420）
7 -> anon_inode:[eventpoll]       epoll：HttpServer 用它等待新连接和新数据
8 -> anon_inode:[eventfd]         内核的事件通知对象，用来唤醒等待中的线程
9 -> socket:[1390421]             一条已建立的 TCP 连接：Prometheus 每 5 秒来抓 /metrics，连接一直复用
```

空闲时一共 10 个。怎么知道哪个 socket 是什么：用 `sudo ss -anpe`，按 `ino:`（socket 编号）或 `fd=` 对上。压测 5000 rps 时，每个保持着的连接都会多占一个 fd。

**和书的关系（第 3 章）**：进程的 `task_struct` 里有一个 `files_struct`，里面是一张数组，fd 就是数组下标，数组里存的是指向 `struct file` 的指针。所以 fd 很便宜（一个整数），但**数量有上限**。

---

## 例子一：内存泄漏 → OOM

### 现象（🔮 预测）

压测跑了一段时间后：先是延迟越来越高，然后要么服务卡死，要么服务"自己重启了一次"。

### 一直问为什么

**Why 1：为什么延迟越来越高？**
→ 因为 GC 越来越频繁，每次 GC 都要暂停或抢 CPU。
🔍 证据：GC 日志里 `Pause Young` 间隔越来越短，后来出现 `Pause Full`；Grafana 上 JVM 堆曲线一直往上爬，不回落。

**Why 2：为什么 GC 越来越频繁？**
→ 因为堆里"活着的对象"越来越多。GC 只能回收没人引用的对象，活对象占满了堆，每次 GC 都腾不出多少空间，只能更频繁地再来一次。

**Why 3：为什么活对象越来越多？**
→ 因为频次表 `FREQ` 只加不删。每个"广告 × 用户"组合都会存一条记录，用户 ID 无穷无尽，表就无限长大。
🔍 证据：Grafana 上 `bidder_freq_entries` 一直涨，形状和堆内存曲线一样。
📍 代码：[Bidder.java:68](../bidder/src/Bidder.java#L68)（定义）、[Bidder.java:154](../bidder/src/Bidder.java#L154)（只有 put，没有删除）

**Why 4：为什么代码不删？**
→ 这里是故意埋的。真实世界里的常见原因：频次控制本来就需要"按时间窗口过期"（比如"每个用户每天最多看 3 次"），但写代码时用了普通 HashMap，忘了过期。
✅ 正确做法：带过期时间的缓存（如 Caffeine），或者把频次放到 Redis 并设置 TTL。

**到这里根因找到了（代码 bug）。但 Linux 工程师还要继续问：堆满了以后，进程到底会怎样？答案取决于配置。**

**Why 5：为什么有时候是"卡死"，有时候是"进程消失"？**
→ 因为有**两道内存上限**，谁先撞到，结局就不一样：

| 先撞到的上限 | 谁出手 | 结局 | 日志里看到什么 |
|---|---|---|---|
| Java 堆上限 `-Xmx512m` | JVM 自己 | 抛出 `OutOfMemoryError`，**进程往往还活着**，但已经处理不了请求 | GC 日志、journald 里的 Java 报错 |
| cgroup 内存上限 `MemoryMax`（systemd 设置） | **Linux 内核的 OOM killer** | 进程被 `SIGKILL` 直接杀掉，**一句 Java 报错都没有** | `journalctl -k` 里 `Memory cgroup out of memory: Killed process ...`；systemd 显示 `Failed with result 'oom-kill'` |
| 整台机器的物理内存（4 GB，无 swap） | 内核的全局 OOM killer | 内核挑一个"最该杀"的进程杀掉，**可能误杀别的服务**（比如 Prometheus） | `journalctl -k` 里 `Out of memory: Killed process ...` |

✅ 实测：现在 rtb-bidder 的 cgroup 上限是 `memory.max = max`（**没有限制**），只有 `-Xmx512m` 这一道。

**Why 6：为什么"进程还活着但不干活"反而更糟？**
→ 因为 systemd 的 `Restart=on-failure` 只在**进程退出**时才重启。JVM 抛 OOM 后进程不退出，systemd 认为它一切正常，监控上 `up` 也可能还是 1，服务就一直半死不活。
✅ 解决：加 `-XX:+ExitOnOutOfMemoryError`，让 JVM 遇到 OOM 直接退出，再交给 systemd 重启（"快速失败"）。

**Why 7：那为什么不干脆把 `MemoryMax` 设成和 `-Xmx` 一样，比如都是 512 MB？**
→ 因为 **Java 进程用的内存 > 堆**。除了堆，还有元空间（类信息）、每个线程的栈、JIT 编译后的代码、GC 自己的数据结构、直接内存。
✅ 实测：空闲时进程实际占用 RSS 约 62 MB，cgroup 统计 `memory.current` 约 42 MB，这时候堆还几乎是空的。
所以 `MemoryMax` 必须比 `-Xmx` 留出余量（比如 `-Xmx512m` 配 `MemoryMax=768M`），否则堆还没满，内核就先把进程杀了。

### 实验计划

1. 让压测使用大量不同的用户 ID，加快泄漏速度。
2. **实验 A**：只有 `-Xmx`，观察 `OutOfMemoryError` 和"假活着"的现象。
3. **实验 B**：加 `MemoryMax`，并故意设得比 `-Xmx` 小，观察内核 OOM killer、`memory.events` 里的 `oom_kill` 计数、systemd 的 `oom-kill` 结果。
4. **修复**：代码加过期机制；配置加 `ExitOnOutOfMemoryError` 和合理的 `MemoryMax`；告警加上"堆使用率持续 > 85%"。
5. 写成记录 #03（格式同 #01）。

---

## 例子二：fd 耗尽（Too many open files）

### 现象（🔮 预测）

压测流量一大，新请求开始失败。客户端看到"连接错误"，服务端日志出现 `java.io.IOException: Too many open files`。

### 一直问为什么

**Why 1：为什么新请求失败？**
→ 因为服务器要接受一个新连接，就得调用 `accept()` 拿到一个新的 fd。fd 用光了，`accept()` 失败，连接进不来。
🔍 证据：journald 里的 `Too many open files`；这对应的错误码是 `EMFILE`（这个进程的 fd 达到上限）。

**Why 2：为什么 fd 会用光？** 这里出现分叉，要靠数据判断：

| 观察 `ls /proc/<pid>/fd \| wc -l` 的变化 | 说明 | 根因在 |
|---|---|---|
| 一直涨，流量停了也不回落 | 打开了却没关闭：**fd 泄漏** | 代码 |
| 跟着流量涨跌，只是高峰时碰到上限 | 正常使用，但**上限太低** | 配置 |

**Why 3（泄漏这条路）：为什么会忘记关闭？**
→ 典型写法错误：出了异常就提前 return，跳过了 `close()`；或者每个请求都新建一个连接去调下游服务（比如 Redis），却没有用连接池。
✅ 正确做法：Java 里用 `try-with-resources` 保证关闭；下游连接用连接池复用。

**Why 3'（上限这条路）：为什么上限这么低？**
→ ✅ 实测发现一个很好的例子：

```
我（lab 用户）登录后的 shell：ulimit -n           → 1024
rtb-bidder 服务（/proc/<pid>/limits 里 Max open files）→ 65536
```

同一台机器，两个数差了 64 倍。

**Why 4：为什么同一台机器上限不一样？**
→ 因为 fd 上限是**每个进程自己的属性**（内核里叫 `RLIMIT_NOFILE`），由启动它的父进程传下来：
- 我 SSH 登录时，登录流程（PAM）按 `/etc/security/limits.conf` 给 shell 设成 1024，之后从这个 shell 启动的程序都继承 1024；
- rtb-bidder 是 systemd 启动的，用的是 unit 文件里的 `LimitNOFILE=65536`（[deploy/rtb-bidder.service](../deploy/rtb-bidder.service)）。

**Why 5：为什么改了 `/etc/security/limits.conf`，服务的上限还是不变？**（经典面试坑）
→ 因为 `limits.conf` 只对**登录会话**生效（它是 PAM 读取的），**systemd 启动的服务根本不经过 PAM**。服务的上限只能在 unit 文件里用 `LimitNOFILE=` 改。
所以"我已经调大 ulimit 了，为什么服务还报 Too many open files"，答案往往就是这个。

**Why 6：那为什么不直接把上限设成无限大？**
→ 因为 fd 背后是内核内存（每个 `struct file`、每个 socket 都有缓冲区）。上限的作用就是**保护机器**：一个进程泄漏 fd，只会把自己搞挂，而不会把整台机器的内核内存耗光。
另外还有一层全系统的上限 `fs.file-max`（✅ 实测：这台机器是一个极大的数，基本不会先撞到它）。

### 和 #01 的联系

#01 里的 TIME_WAIT 连接**不占 fd**：程序调用 `close()` 后 fd 就还回去了，TIME_WAIT 是内核自己保留的连接状态。所以 #01 的问题是"端口和连接重建开销"，不是 fd。这两个概念很容易混，面试时能分清是加分项。

### 实验计划

1. **实验 A（上限太低）**：用 systemd drop-in 把 `LimitNOFILE` 临时改成 256，压 5000 rps，看客户端错误和 journald 报错；同时让 node_exporter 或自己的指标导出进程 fd 数，在 Grafana 上画出"fd 数撞到上限"。
2. **实验 B（泄漏）**：在 bidder 里加一个故障开关，比如每个请求打开一个文件但不关闭，观察 fd 数一直涨不回落。
3. 对比两种情况下的曲线形状，这就是区分"代码问题"还是"配置问题"的证据。
4. 加告警：进程 fd 使用率 > 80%。
5. 写成记录 #04。

---

## 一起讨论的问题

1. 例子一里，你觉得"进程消失"和"进程假活着"，哪种对线上更危险？为什么？
2. 如果 OOM killer 杀进程时一句应用日志都没有，你会先去哪里找证据？
3. 你在 Amazon 用的 Lambda 也有内存上限。Lambda 函数内存超限时，你觉得底层发生的事和例子一里的哪一行最像？
4. fd 耗尽时，为什么 `/health` 检查也可能失败？这对告警意味着什么？
5. 为什么说"根因是代码"之后，Linux 工程师的工作还没结束？
