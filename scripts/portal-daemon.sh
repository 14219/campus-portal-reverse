#!/bin/sh
# ==============================================================================
# 校园网 Portal 自动认证 · 常驻守护（通用模板）
#
# 设计目标：
#   1) 不依赖 cron —— cron 任务可能丢失，且最小粒度只有 60 秒
#   2) 秒级检测 —— 默认每 15 秒探测，真掉线后 < 30 秒恢复
#   3) procd 托管 —— 本进程崩溃会被拉起；开机自启
#   4) 认证逻辑复用 portal-login.sh，不重复实现
#
# 关键设计（见 docs/03-防掉线守护设计.md）：
#   调用 portal-login.sh 时**绝不带 --force**。
#   --force 会跳过"在线就跳过"的判断，导致探测偶发失败时
#   脚本直接 disconn + login，把还活着的会话主动踢掉。
#
# 用法:
#   ./portal-daemon.sh            前台运行（procd 用）
#   ./portal-daemon.sh --once     只跑一轮就退出（调试）
#
# 环境变量:
#   PORTAL_INTERVAL=15            探测间隔（秒）
#   PORTAL_LOGIN=/root/portal-login.sh
#   PORTAL_LOG=/root/portal-daemon.log
# ==============================================================================

LOG="${PORTAL_LOG:-/root/portal-daemon.log}"
LOGIN="${PORTAL_LOGIN:-/root/portal-login.sh}"
INTERVAL="${PORTAL_INTERVAL:-15}"

# 多个 204 地址，避免单点误判
PROBES="http://connect.rom.miui.com/generate_204
http://www.gstatic.com/generate_204
http://connectivitycheck.gstatic.com/generate_204"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 日志轮转：超过 2000 行截断到 1000 行（嵌入式 flash 空间有限）
rotate_log() {
    [ -f "$LOG" ] || return 0
    n=$(wc -l < "$LOG" 2>/dev/null)
    [ -n "$n" ] && [ "$n" -gt 2000 ] && tail -1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

probe_online() {
    for u in $PROBES; do
        c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)
        [ "$c" = "204" ] && return 0
    done
    return 1
}

trap 'log "收到 TERM，守护退出"; exit 0' TERM INT

ONCE=0
[ "$1" = "--once" ] && ONCE=1

log "===== 守护启动 (间隔 ${INTERVAL}s, pid $$, once=${ONCE}) ====="

FAILS=0
while :; do
    if probe_online; then
        [ "$FAILS" -gt 0 ] && log "恢复在线（此前连续失败 ${FAILS} 次）"
        FAILS=0
    else
        FAILS=$((FAILS + 1))
        log "探测失败第 ${FAILS} 次"
        # 连续失败才触发；是否真的认证由 portal-login.sh 的门户复核决定
        if [ "$FAILS" -ge 2 ]; then
            # 注意：不带 --force
            OUT=$(sh "$LOGIN" 2>&1 | tail -3)
            log "认证输出: $(echo "$OUT" | tr '\n' ' ' | cut -c1-300)"
            FAILS=0
            sleep 5
        fi
    fi
    rotate_log
    [ "$ONCE" -eq 1 ] && { log "(--once 模式) 单轮结束"; exit 0; }
    sleep "$INTERVAL"
done
