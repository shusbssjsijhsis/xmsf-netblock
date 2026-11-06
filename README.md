# XMSF Netblock

一个 KernelSU / Magisk 模块，做两件事：

1. **定向屏蔽**：只拦**小米服务框架**（`com.xiaomi.xmsf`）连指定的域名，默认是 `hyperos.developer.xiaomi.com`。
   推送（5222 长连接、`resolver.msg.xiaomi.net`）、通知图片下载和别的应用都不受影响。
2. **整个断网**：把指定应用的所有连接一律拒绝，默认是**安全守护**（`com.miui.guardprovider`）。

不改 hosts、不改 Clash 等代理的配置，只在内核防火墙（iptables）里按应用 UID 加几条规则。

[English](#english)

## 为什么拦这些

小米服务框架承载小米推送，所以不能整个断网；但它的一部分连接和推送无关：

- **`hyperos.developer.xiaomi.com`**：静态分析里只有两个模块用它，都不在推送链路上。
  - `com.xiaomi.xms.captain`：读取已安装应用（包名、安装时间、安装来源）和行为记录，组装加密的
    `UploadRequest` 上传；
  - `com.xiaomi.xms.game_popup`：按包名查询游戏预约弹窗（`/xms/xmsf/popup/reservation/status?packageName=`）。

  按应用抓包实测：每次开机后，主用户和应用双开里的小米服务框架各往这个域名上传一块固定大小的数据（几十 KB），
  多次开机大小一致；手机在用时每隔几分钟还有一批请求。
- **`tracking.miui.com`**（可选，默认不拦）：小米服务框架里 OneTrack 统计的上报地址（`/track/v4`）。代码里
  `eventtracking` 模块在亮灭屏、打开最近任务时收集最近任务的包名和当前界面（事件 `collect_running_tasks`），
  交给 OneTrack 上报。这项收集受配置开关控制，不一定每台机器都开着。

安全守护是「手机管家」病毒扫描的引擎宿主，云端查杀会把已装应用的信息发往查杀引擎的云端。它不联网也能工作：
断网后本地查杀照常，只是病毒库不再在线更新。

## 原理

```
定向屏蔽
filter OUTPUT:  -p tcp -m owner --uid-owner <xmsf 在各用户下的 UID> -j xnb_out
xnb_out:        -p tcp -m string --algo bm --icase --string "<域名>" -j REJECT --reject-with tcp-reset

整个断网
filter OUTPUT:  -m owner --uid-owner <应用在各用户下的 UID> -j xnb_all          （不限协议）
xnb_all:        -p tcp -j REJECT --reject-with tcp-reset                       TCP：连接立即被重置
                -j REJECT                                                      其它协议：回“端口不可达”
```

- 主机名在两处是明文：直连 HTTPS 时 TLS ClientHello 里的 SNI，以及经系统 HTTP 代理（比如 Clash Meta 的
  「附加 HTTP 代理」）时隧道开头的 `CONNECT 主机名:443`。命中的那个包不会发出去，应用立刻收到连接重置，
  不会挂着等超时。两条路都拦，IPv4、IPv6 都拦，不区分大小写，子域名也算。
- UID = 用户号 × 100000 + appId。用户列表读 `/data/system/users`（主用户 0、应用双开 999、分身……），
  appId 读 `/data/system/packages.list`。某个用户里没装这个应用也没关系：那个 UID 没有进程，规则什么也不拦。
- 系统共享 UID（appId < 10000，例如 1000 由 system_server 和一堆系统组件共用）的包不做，否则会连系统一起拦；
  整个断网不接受 `com.xiaomi.xmsf`（会断推送）。
- DNS 查询由系统（netd）代发，不受影响：被断网的应用还能解析域名，只是连不上。

## 安装与使用

1. 从 [Releases](../../releases) 下载 zip（或者运行 `./build.sh` 自己打包），在 KernelSU / Magisk 里安装，重启。
   安装时会先探测内核是否支持所需的匹配（owner、string、REJECT），不支持就中止安装。
2. 看状态和拦截次数：

   ```
   su -c 'sh /data/adb/modules/xmsf_netblock/xnb.sh status'
   ```

3. 停用 / 启用：点模块的「操作」按钮（每点一次切换），或 `xnb.sh off` / `xnb.sh on`。停用会立即删除全部规则，
   重启后仍保持停用。
4. 卸载模块会删除全部规则。配置和计数留在 `/data/adb/xmsf_netblock`，不要了可手动删除。

## 配置

`/data/adb/xmsf_netblock/config.conf`，改完执行 `su -c 'sh /data/adb/modules/xmsf_netblock/xnb.sh apply'`
（不执行也行，后台核对 10 分钟内会按新配置部署）。

| 键 | 默认 | 说明 |
|---|---|---|
| `PACKAGES` | `com.xiaomi.xmsf` | 定向屏蔽对哪些应用生效，逗号分隔 |
| `HOSTS` | `hyperos.developer.xiaomi.com` | 要拦的域名，空格分隔。例如再加上 `tracking.miui.com` |
| `BLOCK_ALL` | `com.miui.guardprovider` | 整个断网的应用，逗号分隔；写成 `BLOCK_ALL=""` 就不断 |

**不要**把推送用的 `resolver.msg.xiaomi.net` 或泛域名 `xiaomi.com` 写进 `HOSTS`，那会断推送。

## 可靠性

- 规则在开机早期（service 阶段，不等开机完成）就部署。开机后头 10 分钟每 10 秒核对一次，之后每 10 分钟一次：
  netd 初始化时会清掉 OUTPUT 里的规则，丢了马上补回。
- 算不出目标 UID 时（比如一时读不到 `packages.list`）沿用上次部署的 UID，不会因此删规则；只有「停用」、卸载，
  或者配置里把目标换成了别的应用，才会删旧规则。
- 重新部署时先加新规则、再删旧规则，已经在拦的不会有空档。
- `status` 列出的是**规则里实际生效**的 UID（直接读 iptables），在 Termux、adb shell 里执行结果一样。
  （Termux 里的 `su` 默认继承 Termux 的挂载命名空间，应用数据隔离让 `/data/user_de` 只剩 Termux 自己，
  所以用户列表不从那里读。）
- 后台核对循环如果是从 Termux 或 root 管理器里拉起的，会把自己移出那个应用的 cgroup，应用被冻结或被杀
  不会连累它。

## 局限

- 定向屏蔽时，直连那一路的 TCP 握手仍会完成（SNI 在握手之后的第一个数据包里），服务器能看到一次没有数据的
  连接；被拦的是 TLS 握手和之后的一切数据。被重置后应用往往会立刻重试，所以拦截次数会比原本的请求数多。
- 如果应用复用一条已经连到其它域名、证书又恰好覆盖目标域名的 HTTP/2 连接（连接合并），主机名只出现在加密的头里，
  拦不到。
- 整个断网只管该应用自己发出的连接；如果别的应用（尤其是用系统共享 UID 的系统组件）替它把数据发出去，按 UID 拦不到。
- 被拒的连接在内核里很早就被拦下，按应用抓包的工具（在 POSTROUTING 记录的）看不到它们；拦截次数以 `status` 为准。

## 测试

`tests/` 里是在 Linux 主机上跑的测试，用真实的 iptables / ip6tables 规则和真实的 socket：

```
bash tests/static.sh                    # 语法检查（dash / mksh / busybox ash）与变量作用域检查，不需要 root
sudo bash tests/run.sh dash             # 端到端：UID 解析、SNI 与 CONNECT 拦截、整个断网、核对循环、停用、卸载
sudo bash tests/run.sh mksh             # Android 的 /system/bin/sh 是 mksh
sudo bash tests/run.sh "busybox ash"    # root 管理器用 busybox ash 跑模块脚本
sudo bash tests/install.sh mksh         # 安装脚本：全新安装、升级、重复安装
```

`run.sh` 会往本机的 filter OUTPUT 链里加删规则，并为了模拟 netd 清空这条链，请在一次性的虚拟机或容器里跑；
OUTPUT 里已有规则时它会拒绝运行。

## 许可

MIT

---

## English

A KernelSU / Magisk module for HyperOS that blocks part of Xiaomi Service Framework's (`com.xiaomi.xmsf`)
traffic without touching push notifications, and can cut chosen apps off the network entirely.

- **Host blocking**: for the target app's UIDs (every user, including the dual-app user 999), TCP packets whose
  payload contains a listed host name - the TLS SNI of a direct HTTPS connection, or the `CONNECT host:443` line
  sent to a system HTTP proxy - are rejected with a TCP reset. The default host is
  `hyperos.developer.xiaomi.com`, which static analysis shows is used only by the `captain` module (reads the
  installed-app list and uploads it encrypted) and `game_popup`; push (port 5222, `resolver.msg.xiaomi.net`)
  keeps working. `tracking.miui.com` (OneTrack telemetry) can be added in the config.
- **Whole-app blocking**: every connection of the apps in `BLOCK_ALL` is rejected (TCP reset, ICMP unreachable
  otherwise), IPv4 and IPv6. The default is `com.miui.guardprovider`, the security scanner's engine host, whose
  cloud scan sends installed-app information off the device; local scanning keeps working. Shared system UIDs
  (appId < 10000) and `com.xiaomi.xmsf` are refused.
- No hosts file or proxy changes. Rules are deployed early in boot, checked every 10 s for the first 10 minutes
  and every 10 minutes after; they are kept when the target cannot be resolved, and replaced add-then-remove so
  there is no gap. `xnb.sh status` shows the UIDs actually enforced and the block counters.

Install the zip from Releases (or build it with `./build.sh`), reboot, and check
`su -c 'sh /data/adb/modules/xmsf_netblock/xnb.sh status'`. Configuration lives in
`/data/adb/xmsf_netblock/config.conf` (`PACKAGES`, `HOSTS`, `BLOCK_ALL`). Tests in `tests/` run on a Linux
host against real iptables rules; run them in a throwaway VM or container.
