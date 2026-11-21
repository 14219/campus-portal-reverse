#!/bin/sh
# ==============================================================================
# 校园网 Portal 自动认证脚本（通用模板）
#
# 设计依据：docs/01-抓包与协议还原.md、docs/03-防掉线守护设计.md
#
# 核心原则：
#   1) 探测失败 ≠ 掉线。掉线的唯一判据是"门户说这个 IP 上没有会话"
#   2) 会话还活着时绝不调用 disconn —— 那会把好会话主动踢掉
#   3) 每次动作都留下判定依据，便于事后复盘
#
# 用法:
#   ./portal-login.sh              正常模式（在线就跳过）
#   ./portal-login.sh --dry-run    只探测和打印，不发任何认证请求
#   ./portal-login.sh --force      强制重认证（慎用：会踢掉活会话）
#
# 返回码: 0=在线/认证成功  1=认证失败  2=配置缺失
# ==============================================================================

CONF="${PORTAL_CONF:-/root/portal-cred.conf}"
LOG="${PORTAL_LOG:-/root/portal-login.log}"
STATE="${PORTAL_STATE:-/tmp/.portal-state}"
PJA="/tmp/.portal.json"
SKIPF="/tmp/.portal-skip"

MODE="$1"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
say() { echo "$*"; }

# ------------------------------------------------------------------ 配置
if [ -f "$CONF" ]; then
    . "$CONF"
else
    echo "缺少配置文件 $CONF（参考 scripts/portal-cred.conf.example）" >&2
    exit 2
fi

ACCOUNT="$USER_ACCOUNT"
PASSWORD="$USER_PASSWORD"
HOST="$PORTAL_HOST"
NAS_IP="${NAS_IP:-}"
AC_NAME="${AC_NAME:-}"
WAN_IF="${WAN_IF:-wan}"
DEFAULT_VLAN="${DEFAULT_VLAN:-}"
# 门户真实 IP：仅当本机 DNS 解析不到 PORTAL_HOST 时才需要填
PORTAL_IP="${PORTAL_IP:-}"

P_PATH_CONFIG="${P_PATH_CONFIG:-/PortalJsonAction.do}"
P_PATH_LOGIN="${P_PATH_LOGIN:-/quickauth.do}"
P_PATH_LOGOUT="${P_PATH_LOGOUT:-/quickauthdisconn.do}"
P_PATH_ONLINE="${P_PATH_ONLINE:-/portal/getOnlineUserName.do}"
P_PATH_REMOTE="${P_PATH_REMOTE:-/portal/getRemoteAddr.do}"

UA="${PORTAL_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36}"
HOSTNAME_LOCAL="$(cat /proc/sys/kernel/hostname 2>/dev/null)"
[ -z "$HOSTNAME_LOCAL" ] && HOSTNAME_LOCAL="DESKTOP-XXXXXXX"

[ -z "$ACCOUNT" ] && { log "缺少账号，$CONF 未配置 USER_ACCOUNT"; echo "缺少 USER_ACCOUNT" >&2; exit 2; }
[ -z "$HOST" ]    && { log "缺少 PORTAL_HOST"; echo "缺少 PORTAL_HOST" >&2; exit 2; }

# --resolve 只在配置了 PORTAL_IP 时启用；为空则走系统 DNS
RES=""
[ -n "$PORTAL_IP" ] && RES="--resolve $HOST:443:$PORTAL_IP"

# ------------------------------------------------------------------ 工具
urlenc() {
    printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/+/%2B/g' \
        -e 's/&/%26/g' -e 's/=/%3D/g' -e 's/#/%23/g' -e "s/'/%27/g"
}

# 从 URL 的 query 取值： getq "$URL" wlanuserip
getq() {
    printf '%s' "$2" | sed 's/^[^?]*?//' | tr '&' '\n' \
        | sed -n "s/^$1=\(.*\)$/\1/p" | head -1
}

# ------------------------------------------------------------------ 1. 在线探测
#   未认证时门户会把域名劫持到假地址并返回 200（不是 204），
#   所以"非 204"依然等价于"未认证/掉线"。
probe() {
    for u in "http://connect.rom.miui.com/generate_204" \
             "http://www.gstatic.com/generate_204" \
             "http://connectivitycheck.gstatic.com/generate_204"; do
        c=$(curl -s -m 6 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)
        [ "$c" = "204" ] && return 0
    done
    return 1
}

# ---------------------------------------- 1b. 门户权威复核（只读，不改状态）
#   return 0 且 PORTAL_ON=<账号>  → 该 IP 上确实还有会话
#   return 1                      → 门户说没账号 / 门户不可达 / 无 WAN IP
#
#   注意：判据是 code:0 且 data 非空。只认 code:0 会在
#   "会话被清空但接口可达"时误判为在线，导致永不重认证。
portal_online() {
    PORTAL_ON=""
    [ -z "$W_IP" ] && return 1
    r=$(curl -s -k -m 8 $RES -A "$UA" -e "https://$HOST/portal.do" \
         "https://$HOST$P_PATH_ONLINE?wlanuserip=$W_IP&wlanacname=$AC_NAME&mac=$W_MAC&wlanacip=$NAS_IP" 2>/dev/null)
    case "$r" in
        *'"code":"0"'*'"data":"'*)
            d=$(printf '%s' "$r" | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$d" ] && { PORTAL_ON="$d"; return 0; } ;;
    esac
    return 1
}

# 抓劫持跳转，拿到门户 URL（内含 wlanuserip / wlanacname / mac / vlan）
capture_redirect() {
    curl -s -k -m 10 -A "$UA" -L -o /dev/null -w '%{url_effective}' \
         "http://connect.rom.miui.com/generate_204" 2>/dev/null
    printf '\n'
    curl -s -k -m 10 -A "$UA" -D - -o /dev/null "http://223.5.5.5/" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[Ll]ocation: *//p' | head -1
}

# ------------------------------------------------------------------ 2. 本机 WAN
wan_info() {
    W_IP=$(ip -4 addr show "$WAN_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
    W_MAC=$(cat "/sys/class/net/$WAN_IF/address" 2>/dev/null)
    [ -z "$W_IP" ]  && W_IP=""
    [ -z "$W_MAC" ] && W_MAC=""
}

# ------------------------------------------------------------------ 3. 门户配置
fetch_config() {
    QS="wlanuserip=$W_IP&wlanacname=$AC_NAME&mac=$W_MAC&vlan=$W_VLAN&hostname=$HOSTNAME_LOCAL&rand=$(date +%s)000"
    curl -s -k -m 15 $RES -A "$UA" -c /tmp/.pck \
         "https://$HOST$P_PATH_CONFIG?$QS&viewStatus=1" -o "$PJA" 2>/dev/null
    TS=$(sed -n 's/.*"timestamp"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$PJA" | head -1)
    UUID=$(sed -n 's/.*"uuid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PJA" | head -1)
    SRVIP=$(sed -n 's/.*"serverip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PJA" | head -1)
    VER=$(sed -n 's/.*"portalVer"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$PJA" | head -1)
    PAGEID=$(sed -n 's/.*"portalconfig".*"id"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$PJA" | head -1)
    [ -z "$SRVIP" ]  && SRVIP="$NAS_IP"
    [ -z "$VER" ]    && VER="4"
    [ -z "$PAGEID" ] && PAGEID="5"
}

# ------------------------------------------------------------------ 4. 只读诊断
diagnose() {
    RA=$(curl -s -k -m 10 $RES -A "$UA" "https://$HOST$P_PATH_REMOTE" 2>/dev/null \
         | sed -n 's/.*"remoteAddr"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    ON=$(curl -s -k -m 10 $RES -A "$UA" -e "https://$HOST/portal.do" \
         "https://$HOST$P_PATH_ONLINE?wlanuserip=$W_IP&wlanacname=$AC_NAME&mac=$W_MAC&wlanacip=$NAS_IP" 2>/dev/null \
         | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    log "诊断: 门户看到的源IP=$RA 本机WAN=$W_IP 该IP上的账号=${ON:-（空）}"
    [ -n "$RA" ] && [ -n "$W_IP" ] && [ "$RA" != "$W_IP" ] && \
        log "⚠ IP 漂移: 门户记的是 $RA，本机现在是 $W_IP（会话可能已失效）"
}

# ------------------------------------------------------------------ 5. 主动下线
#   仅当已确认会话失效时才应调用。接口返回 code:0 后，
#   BRAS 侧真正断开仍要数秒，紧接着 login 会踩竞态。
disconn() {
    [ -z "$W_IP" ] && return 1
    curl -s -k -m 15 $RES -A "$UA" -e "https://$HOST/portal.do" \
         -X POST \
         --data-urlencode "wlanacip=$SRVIP" \
         --data-urlencode "wlanuserip=$W_IP" \
         --data-urlencode "wlanacname=$AC_NAME" \
         --data-urlencode "version=$VER" \
         --data-urlencode "portaltype=" \
         --data-urlencode "userid=$ACCOUNT" \
         --data-urlencode "mac=$W_MAC" \
         --data-urlencode "groupId=" \
         --data-urlencode "clearOperator=0" \
         --data-urlencode "rand=$RANDOM" \
         "https://$HOST$P_PATH_LOGOUT" 2>/dev/null | head -c 200
}

# ------------------------------------------------------------------ 6. 登录
login() {
    local data="userid=$(urlenc "$ACCOUNT")&passwd=$(urlenc "$PASSWORD")"
    data="$data&wlanuserip=$W_IP&wlanuseripv6=&wlanacname=$AC_NAME&wlanacIp=$SRVIP"
    data="$data&ssid=&vlan=$W_VLAN&mac=$W_MAC&version=$VER&portalpageid=$PAGEID"
    data="$data&validateCode=&timestamp=$TS&uuid=$UUID&portaltype="
    data="$data&hostname=$HOSTNAME_LOCAL&bindCtrlId=&validateType=&bindOperatorType=2"
    curl -s -k -m 20 $RES -A "$UA" -b /tmp/.pck -e "https://$HOST/portal.do" \
         "https://$HOST$P_PATH_LOGIN?$data" 2>/dev/null | head -c 400
}

# ================================================================== 主流程
say "=== 校园网自动认证  $(date '+%F %T') ==="

wan_info    # probe 的门户兜底需要 W_IP

# 读取"探测失败但门户报在线"的连续计数
SKIP=0
[ -f "$SKIPF" ] && SKIP=$(cat "$SKIPF" 2>/dev/null)
case "$SKIP" in ''|*[!0-9]*) SKIP=0;; esac

if probe; then
    rm -f "$SKIPF"
    echo "ONLINE $(date +%s)" > "$STATE"
    say "在线，无需处理。"
    [ "$MODE" = "--force" ] || { log "在线，跳过"; exit 0; }
    say "--force 模式，强制重认证"
else
    # 关键：探测失败先请门户做权威复核，
    # 会话还在就什么都不做（连续 4 次约 60 秒仍失败才强制一次）
    if [ "$MODE" != "--force" ] && portal_online; then
        SKIP=$((SKIP + 1))
        echo "$SKIP" > "$SKIPF"
        log "⚠ 探测失败但门户权威复核=在线(账号=$PORTAL_ON) —— 疑似本机误判，跳过认证（连续第 ${SKIP} 次）"
        if [ "$SKIP" -lt 4 ]; then
            say "门户显示该 IP 在线，跳过认证。"
            echo "OK $(date +%s) ip=$W_IP" > "$STATE"
            exit 0
        fi
        log "🔁 连续 ${SKIP} 次探测失败但门户仍报在线 —— 判定数据面异常，强制重认证一次"
        rm -f "$SKIPF"
    else
        rm -f "$SKIPF"
    fi
    say "探测失败 —— 判定掉线/未认证"
fi

wan_info
say "本机 WAN: ip=$W_IP mac=$W_MAC"

# 抓跳转，解析关键标记
REDIR=$(capture_redirect)
say "跳转: $REDIR"
DROP=$(printf '%s' "$REDIR" | sed -n 's/.*dropLogCheck=\([^&]*\).*/\1/p')

W_VLAN="$DEFAULT_VLAN"
if [ -n "$REDIR" ]; then
    t=$(getq wlanuserip "$REDIR");  [ -n "$t" ] && W_IP="$t"
    t=$(getq wlanacname "$REDIR");  [ -n "$t" ] && AC_NAME="$t"
    t=$(getq mac "$REDIR");         [ -n "$t" ] && W_MAC="$t"
    t=$(getq vlan "$REDIR");        [ -n "$t" ] && W_VLAN="$t"
    t=$(getq wlanacIp "$REDIR");    [ -n "$t" ] && NAS_IP="$t"
fi
W_VLAN=$(printf '%s' "$W_VLAN" | tr -cd '0-9')

log "------- 掉线，开始认证 (dropLogCheck=${DROP:-无} mode=${MODE:-正常}) -------"
if [ "$DROP" = "1" ]; then
    log "🔻 判定：被其他设备登录顶下线（门户限制设备数）"
elif [ -n "$DROP" ]; then
    log "🔻 dropLogCheck=$DROP"
fi

if [ "$MODE" = "--dry-run" ]; then
    say "DRY-RUN：参数 ip=$W_IP ac=$AC_NAME mac=$W_MAC vlan=$W_VLAN"
    say "不下发任何认证请求。"
    exit 0
fi

fetch_config
say "门户: ver=$VER pageid=$PAGEID srvip=$SRVIP ts=$TS"
log "门户参数: ip=$W_IP ac=$AC_NAME mac=$W_MAC vlan=$W_VLAN ver=$VER pageid=$PAGEID srvip=$SRVIP"

diagnose

# 走到这里说明门户已确认无会话，此时注销旧会话是安全的
R=$(disconn)
say "disconn: $R"
log "disconn: $R"
sleep 2

for i in 1 2 3; do
    R=$(login)
    say "第 $i 次: $R"
    log "第 $i 次返回: $R"
    case "$R" in
        *'"code":"0"'*|*'"code":0'*)
            DLC=$(printf '%s' "$R" | sed -n 's/.*"dropLogCheck"[[:space:]]*:[[:space:]]*"\?\([^,"}]*\).*/\1/p')
            MCH=$(printf '%s' "$R" | sed -n 's/.*"macChange"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')
            GID=$(printf '%s' "$R" | sed -n 's/.*"groupId"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
            log "✅ 认证成功 (dropLogCheck=${DLC:-无} macChange=${MCH:-无} groupId=${GID:-无})"
            # 复验：登录返回 code:0 不等于真的通了
            VC=$(curl -s -k -m 10 $RES -A "$UA" -e "https://$HOST/portal.do" \
                 "https://$HOST$P_PATH_ONLINE?wlanuserip=$W_IP&wlanacname=$AC_NAME&wlanacip=$SRVIP" 2>/dev/null)
            case "$VC" in
                *'"code":"0"'*) log "✔ 复验通过: 门户显示该 IP 在线" ;;
                *) log "⚠ 复验异常: $VC" ;;
            esac
            echo "OK $(date +%s) ip=$W_IP" > "$STATE"
            exit 0;;
    esac
    sleep 2
done

log "❌ 三次均失败"
echo "FAIL $(date +%s)" > "$STATE"
exit 1
