# 脚本使用说明

两个脚本，一个配置文件。逻辑说明见 [第 3 篇](../docs/03-防掉线守护设计.md)。

| 文件 | 作用 |
|---|---|
| `portal-login.sh` | 认证主脚本：探测 → 门户复核 → 取配置 → 登录 → 复验 |
| `portal-daemon.sh` | 常驻守护：每 15 秒探测，掉线时调用主脚本 |
| `portal-cred.conf.example` | 凭证与参数模板，复制为 `/root/portal-cred.conf` 后使用 |

依赖：`curl`（OpenWrt 一般已装）、`sh`（busybox ash 即可）。不需要 python。

---

## 一、三步部署

```sh
# 1) 传上去
scp portal-login.sh portal-daemon.sh portal-cred.conf.example root@192.168.1.1:/root/

# 2) 配置凭证（必改 USER_ACCOUNT / USER_PASSWORD / PORTAL_HOST / NAS_IP / AC_NAME）
ssh root@192.168.1.1
cp /root/portal-cred.conf.example /root/portal-cred.conf
vi /root/portal-cred.conf
chmod 600 /root/portal-cred.conf
chmod 700 /root/portal-login.sh /root/portal-daemon.sh

# 3) 试跑（不会发认证请求）
sh /root/portal-login.sh --dry-run
sh /root/portal-daemon.sh --once
tail -20 /root/portal-login.log
```

`--dry-run` 输出里要能看到正确的 `ip=`、`ac=`、`vlan=`，再往下走。

---

## 二、怎么填那几个参数

这一段对应 [第 1 篇](../docs/01-抓包与协议还原.md) 的流程，简述对照：

| 配置项 | 从哪来 |
|---|---|
| `USER_ACCOUNT` | 你登录门户时输入的那个账号 |
| `PORTAL_HOST` | 浏览器地址栏里的门户域名 |
| `NAS_IP` | 跳转 URL 的 `wlanacIp`，或配置 JSON 的 `serverForm.serverip` |
| `AC_NAME` | 跳转 URL 的 `wlanacname`，或 `serverForm.servername` |
| `WAN_IF` | `ip route \| grep default` 看默认路由走哪个口 |
| `PORTAL_IP` | 只在本机解析不到门户域名时填。可从别的网络 `dig +short` 拿到 |
| `DEFAULT_VLAN` | 一般留空，脚本会从跳转 URL 自动解析 |
| `P_PATH_*` | 默认是深澜 Portal 的路径。抓包看实际请求路径，不同则改 |

**不确定路径对不对**，用错密码测一次（见第 1 篇第 6 节）：

```sh
# 临时把 USER_PASSWORD 改成 wrongpw123，跑一次
sh /root/portal-login.sh --force
# 返回 {"code":"7", ...} → 说明地址、路径、参数结构都对，只是密码错
# 返回 404 / 其它 → 路径或域名不对
```

验证完记得改回真密码。

---

## 三、交给 procd 托管

```sh
cat > /etc/init.d/portal-daemon <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /root/portal-daemon.sh
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall -q portal-daemon.sh
}
EOF

chmod +x /etc/init.d/portal-daemon
/etc/init.d/portal-daemon enable
/etc/init.d/portal-daemon start
```

`respawn 3600 5 0` = 崩溃后 5 秒拉起，每小时最多 5 次，防止疯狂重启。

---

## 四、WAN up 立刻认证（可选，推荐）

```sh
cat > /etc/hotplug.d/iface/99-portal-autologin <<'EOF'
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0
logger -t portal "WAN up，触发认证"
sleep 3
sh /root/portal-login.sh >> /root/portal-hotplug.log 2>&1 &
EOF
```

末尾的 `&` 不能省：hotplug 脚本串行执行，认证里的 curl 最坏要 20 秒，会阻塞其它 hotplug。

---

## 五、看门狗（可选）

procd 之外再加一层，防止守护进程以非崩溃方式消失：

```cron
*/5 * * * * pgrep -f portal-daemon.sh >/dev/null || /etc/init.d/portal-daemon start
```

写入 `/etc/crontabs/root` 后 `/etc/init.d/cron restart`。

注意这里只判断"进程在不在"，不做网络探测——否则会和守护抢着触发认证。

---

## 六、验证：最重要的是第 3 条

```sh
# 1) 语法
sh -n /root/portal-login.sh && sh -n /root/portal-daemon.sh

# 2) 在线时应"什么都不做"
grep "在线，跳过" /root/portal-login.log | tail -3

# 3) 【关键】模拟探测全失败，验证不会误踢
#    把三个 204 域名在 /etc/hosts 里指向不可达地址后跑一次
sh /root/portal-login.sh
#    期望日志：⚠ 探测失败但门户权威复核=在线 —— 疑似本机误判，跳过认证
#    期望行为：不发认证请求，会话保持在线
grep "疑似本机误判" /root/portal-login.log

# 4) 真掉线恢复：门户上手动下线，观察 30 秒内是否自动登回
```

第 3 条验证的正是这套脚本与"探测失败就重连"那类写法的本质区别。

---

## 七、排障

| 现象 | 排查 |
|---|---|
| 全部 `000` / `502` | 是不是走了本机代理？诊断时加 `--noproxy '*'` |
| `Could not resolve host` | 填 `PORTAL_IP` 走 `--resolve` |
| 认证返回 `code:7` | 账号密码错 |
| 认证返回 `code:0` 但上不了网 | 看复验那行；可能是 BRAS 侧未生效，或 VLAN/MAC 不对 |
| 认证成功但 30~60 秒又掉 | 注销与登录的竞态，或设备数超限（看 `dropLogCheck`） |
| 反复"探测失败但门户在线" | 本机 DNS/上游抖动，脚本行为正确，检查 DNS 与链路质量 |
| 日志不增长 | 守护没起来。`pgrep -f portal-daemon` / `logread \| grep portal` |

---

## 八、卸载

```sh
/etc/init.d/portal-daemon stop
/etc/init.d/portal-daemon disable
rm -f /etc/init.d/portal-daemon /etc/hotplug.d/iface/99-portal-autologin
rm -f /root/portal-login.sh /root/portal-daemon.sh /root/portal-cred.conf
# 顺手清掉 cron 里的看门狗行
```

---

## 九、安全提醒

- `portal-cred.conf` 里是**明文密码**，权限必须是 `600`；
- 不要把它提交到 git（`.gitignore` 已排除 `portal-cred.conf` 和 `*.cred`）；
- 不要在 issue / 截图 / 日志里贴出真实账号、密码、MAC、公网 IP；
- 这套脚本只用于**你自己的账号**。
