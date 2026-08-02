#!/usr/bin/env bash
#
# Install a vnStat/systemd monthly egress guard.
#
# The installer is intentionally root-only.  It installs vnStat and jq, makes
# sure the requested interface is in vnStat's database, and installs a
# once-per-minute systemd check which powers the machine off after the current
# calendar month's transmitted bytes reach the configured limit.
#
# Defaults:
#   IFACE=ens5
#   THRESHOLD_BYTES=214748364800 (200 GiB)
# Both may be overridden in the environment when this installer is run.  A
# whitespace- or comma-separated IFACE value is accepted for multiple NICs.
#
set -Eeuo pipefail

readonly DEFAULT_IFACE="ens5"
readonly DEFAULT_THRESHOLD_BYTES="214748364800"
readonly CONFIG_FILE="/etc/default/vnstat-shutdown"
readonly CHECK_SCRIPT="/usr/local/sbin/vnstat-shutdown"
readonly SERVICE_FILE="/etc/systemd/system/vnstat-shutdown.service"
readonly TIMER_FILE="/etc/systemd/system/vnstat-shutdown.timer"
readonly TIMER_UNIT="vnstat-shutdown.timer"

log() {
    printf '[setup-vnstat-shutdown] %s\n' "$*"
}

die() {
    printf '[setup-vnstat-shutdown] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "必须直接以 root 运行此安装器。"
fi

command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get；此安装器面向 Debian 系统。"
command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl；需要 systemd。"

IFACE="${IFACE:-$DEFAULT_IFACE}"
THRESHOLD_BYTES="${THRESHOLD_BYTES:-$DEFAULT_THRESHOLD_BYTES}"

# Strip leading zeroes so values such as 000214748364800 are treated as
# decimal, not as Bash octal literals.  Keep values within signed 64-bit range,
# which is also the range used by the arithmetic in the check script.
normalize_uint() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^[0-9]+$ ]] || die "$name 必须是十进制非负整数。"
    while [[ "$value" == 0* && "$value" != "0" ]]; do
        value="${value#0}"
    done
    if (( ${#value} > 19 )) || {
        (( ${#value} == 19 )) && [[ "$value" > "9223372036854775807" ]]
    }; then
        die "$name 超出有符号 64 位整数范围。"
    fi
    printf '%s' "$value"
}

THRESHOLD_BYTES="$(normalize_uint THRESHOLD_BYTES "$THRESHOLD_BYTES")"
[[ "$THRESHOLD_BYTES" != "0" ]] || die "THRESHOLD_BYTES 必须大于 0，以免安装时配置立即关机。"

# Convert commas to spaces, reject control characters, validate every token,
# and verify that every interface currently exists.  The normalized value is
# written to the root-owned defaults file and later consumed by the checker.
normalize_interfaces() {
    local raw="$1"
    local token
    local joined=""
    local -a tokens=()

    [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || die "IFACE 不得包含换行符。"
    raw="${raw//,/ }"
    read -r -a tokens <<< "$raw"
    ((${#tokens[@]} > 0)) || die "IFACE 不能为空。"

    for token in "${tokens[@]}"; do
        [[ "$token" =~ ^[[:alnum:]_.-]+$ ]] || die "接口名不安全或无效：$token"
        [[ -e "/sys/class/net/$token" ]] || die "接口不存在：$token"
        if [[ -z "$joined" ]]; then
            joined="$token"
        else
            joined+=" $token"
        fi
    done
    printf '%s' "$joined"
}

INTERFACES="$(normalize_interfaces "$IFACE")"

log "目标接口：$INTERFACES"
log "月度出站阈值：$THRESHOLD_BYTES 字节（默认 200 GiB = 214748364800 字节）"

if [[ -e "$TIMER_FILE" || -e "$SERVICE_FILE" ]]; then
    # Stop only units managed by this installer while their files are replaced.
    # This also prevents an older copy from racing the idempotent installation.
    systemctl stop "$TIMER_UNIT" vnstat-shutdown.service >/dev/null 2>&1 || true
fi

export DEBIAN_FRONTEND=noninteractive
packages=(vnstat jq)
if ! command -v flock >/dev/null 2>&1; then
    # flock is supplied by util-linux on Debian; install it explicitly when it
    # is not already available rather than assuming a minimal image has it.
    packages+=(util-linux)
fi

log "安装依赖：${packages[*]}"
apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"

command -v vnstat >/dev/null 2>&1 || die "vnstat 安装后仍不可用。"
command -v jq >/dev/null 2>&1 || die "jq 安装后仍不可用。"
command -v flock >/dev/null 2>&1 || die "未找到 flock（应由 util-linux 提供）。"

log "启用 vnstat 服务。"
systemctl enable --now vnstat.service

vnstat_has_interface() {
    local iface="$1"
    local db_json

    db_json="$(vnstat --json 2>/dev/null || true)"
    [[ -n "$db_json" ]] || return 1
    jq -e --arg iface "$iface" \
        'any(.interfaces[]?; .id == $iface)' \
        <<< "$db_json" >/dev/null 2>&1
}

ensure_vnstat_interface() {
    local iface="$1"
    local attempt

    if vnstat_has_interface "$iface"; then
        log "vnStat 已监控接口：$iface"
        return 0
    fi

    log "将接口加入 vnStat 数据库：$iface"
    vnstat --add -i "$iface"
    vnstat_added=1

    # --add updates the database immediately on normal vnStat 2.x releases;
    # retry the read briefly so a daemon/database lock does not create a false
    # success on a busy VPS.
    for attempt in 1 2 3 4 5; do
        if vnstat_has_interface "$iface"; then
            log "已确认 vnStat 正在监控：$iface"
            return 0
        fi
        sleep 1
    done
    die "无法确认 vnStat 数据库已监控接口：$iface"
}

vnstat_added=0
for iface in $INTERFACES; do
    ensure_vnstat_interface "$iface"
done
if (( vnstat_added )); then
    # vnStat 2.6 documents that a running daemon needs a restart before it
    # notices a newly-created database entry.
    log "重启 vnstat 服务以加载新增接口。"
    systemctl restart vnstat.service
fi

# Generate the defaults file with shell-escaped values.  The two test knobs
# intentionally use parameter expansion so an environment assignment survives
# sourcing this file when the checker is run manually.
install -d -m 0755 /etc/default /usr/local/sbin /etc/systemd/system
{
    printf '%s\n' '# Managed by setup-vnstat-shutdown.sh; edit only if you understand the consequences.'
    printf '%s\n' '# IFACE/INTERFACES may contain a whitespace- or comma-separated interface list.'
    printf 'IFACE=%q\n' "$IFACE"
    printf 'INTERFACES=%q\n' "$INTERFACES"
    printf 'THRESHOLD_BYTES=%q\n' "$THRESHOLD_BYTES"
    printf '%s\n' 'VNSTAT_SHUTDOWN_DRY_RUN="${VNSTAT_SHUTDOWN_DRY_RUN:-0}"'
    printf '%s\n' 'VNSTAT_THRESHOLD_BYTES_OVERRIDE="${VNSTAT_THRESHOLD_BYTES_OVERRIDE:-}"'
} > "$CONFIG_FILE"

cat > "$CHECK_SCRIPT" <<'EOF_CHECK'
#!/usr/bin/env bash
# Check current calendar-month vnStat tx and power off at the configured limit.
set -Eeuo pipefail

readonly CONFIG_FILE="/etc/default/vnstat-shutdown"
readonly LOCK_FILE="/run/vnstat-shutdown.lock"

log() {
    printf '[vnstat-shutdown] %s\n' "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

[[ -r "$CONFIG_FILE" ]] || fail "缺少配置文件：$CONFIG_FILE"
# shellcheck disable=SC1091
. "$CONFIG_FILE"

raw_interfaces="${INTERFACES:-${IFACE:-}}"
raw_interfaces="${raw_interfaces//,/ }"
[[ "$raw_interfaces" != *$'\n'* && "$raw_interfaces" != *$'\r'* ]] || fail "接口列表包含换行符"
interfaces=()
read -r -a interfaces <<< "$raw_interfaces"
((${#interfaces[@]} > 0)) || fail "接口列表为空"

normalize_uint() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name 必须是十进制非负整数"
    while [[ "$value" == 0* && "$value" != "0" ]]; do
        value="${value#0}"
    done
    if (( ${#value} > 19 )) || {
        (( ${#value} == 19 )) && [[ "$value" > "9223372036854775807" ]]
    }; then
        fail "$name 超出有符号 64 位整数范围"
    fi
    printf '%s' "$value"
}

threshold="${THRESHOLD_BYTES:-214748364800}"
threshold="$(normalize_uint THRESHOLD_BYTES "$threshold")"
[[ "$threshold" != "0" ]] || fail "THRESHOLD_BYTES 必须大于 0"

if [[ -n "${VNSTAT_THRESHOLD_BYTES_OVERRIDE:-}" ]]; then
    threshold="$(normalize_uint VNSTAT_THRESHOLD_BYTES_OVERRIDE "$VNSTAT_THRESHOLD_BYTES_OVERRIDE")"
fi

dry_run_value="${VNSTAT_SHUTDOWN_DRY_RUN:-0}"
case "${dry_run_value,,}" in
    1|true|yes|on)
        dry_run=1
        ;;
    0|false|no|off|"")
        dry_run=0
        ;;
    *)
        fail "VNSTAT_SHUTDOWN_DRY_RUN 必须是 0/1 或 true/false"
        ;;
esac

command -v vnstat >/dev/null 2>&1 || fail "未找到 vnstat"
command -v jq >/dev/null 2>&1 || fail "未找到 jq"
command -v flock >/dev/null 2>&1 || fail "未找到 flock"
command -v systemctl >/dev/null 2>&1 || fail "未找到 systemctl"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

year="$(date +%Y)"
month="$(date +%-m)"
[[ "$year" =~ ^[0-9]+$ && "$month" =~ ^[0-9]+$ ]] || fail "无法取得当前年月"
year="$(normalize_uint current_year "$year")"
month="$(normalize_uint current_month "$month")"

vnstat_json="$(vnstat --json 2>/dev/null)" || fail "vnstat JSON 读取失败；不会关机"
[[ -n "$vnstat_json" ]] || fail "vnstat JSON 为空；不会关机"

total_tx=0
declare -A seen_interfaces=()
for iface in "${interfaces[@]}"; do
    [[ "$iface" =~ ^[[:alnum:]_.-]+$ ]] || fail "接口名不安全：$iface"
    [[ -e "/sys/class/net/$iface" ]] || fail "接口不存在：$iface；不会关机"
    [[ -z "${seen_interfaces[$iface]+present}" ]] || continue
    seen_interfaces["$iface"]=1

    tx="$(jq -er \
        --arg iface "$iface" \
        --argjson year "$year" \
        --argjson month "$month" \
        '[.interfaces[]? | select(.id == $iface) | .traffic.months[]? |
          select((.date.year | tonumber) == $year and (.date.month | tonumber) == $month) |
          .tx]
         | if length == 1 and (.[0] | type) == "number" then .[0] else empty end' \
        <<< "$vnstat_json")" || fail "无法从 vnStat 找到 $iface 的当前年月 tx；不会关机"
    tx="$(normalize_uint "${iface}_tx" "$tx")"

    if (( tx > 9223372036854775807 - total_tx )); then
        fail "接口 tx 合计超出有符号 64 位整数范围；不会关机"
    fi
    total_tx=$((total_tx + tx))
    log "$iface 当前 ${year}-${month} tx=${tx} 字节"
done

log "接口合计 tx=${total_tx} 字节，阈值=${threshold} 字节"
if (( total_tx < threshold )); then
    exit 0
fi

if (( dry_run )); then
    log "达到阈值，但 VNSTAT_SHUTDOWN_DRY_RUN 已启用；不会执行关机"
    exit 0
fi

log "达到阈值，执行 systemctl poweroff"
systemctl poweroff
EOF_CHECK

cat > "$SERVICE_FILE" <<'EOF_SERVICE'
[Unit]
Description=Power off when current calendar-month vnStat egress reaches the limit
After=vnstat.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vnstat-shutdown
EOF_SERVICE

cat > "$TIMER_FILE" <<'EOF_TIMER'
[Unit]
Description=Check vnStat egress limit every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF_TIMER

chmod 0755 "$CHECK_SCRIPT"
chmod 0644 "$CONFIG_FILE" "$SERVICE_FILE" "$TIMER_FILE"
chown root:root "$CONFIG_FILE" "$CHECK_SCRIPT" "$SERVICE_FILE" "$TIMER_FILE"

log "校验内部脚本和 systemd 单元。"
bash -n "$CHECK_SCRIPT"
systemd-analyze verify "$SERVICE_FILE" "$TIMER_FILE"
systemctl daemon-reload
systemctl enable "$TIMER_UNIT"

# This is deliberately the only check run by the installer.  The dry-run flag
# is explicit and the threshold override is 0, so even an already-over-limit
# database can never cause a real poweroff during installation.  The timer is
# enabled but intentionally not started until this check succeeds, eliminating
# an OnBootSec/startup race during installation.
log "执行安装后的安全 dry-run（threshold override=0，不会关机）。"
if ! VNSTAT_SHUTDOWN_DRY_RUN=1 VNSTAT_THRESHOLD_BYTES_OVERRIDE=0 "$CHECK_SCRIPT"; then
    systemctl disable "$TIMER_UNIT" >/dev/null 2>&1 || true
    die "dry-run 失败；timer 未启动，安装中止。"
fi
systemctl start "$TIMER_UNIT"

printf '\n安装完成。检查状态：\n'
printf '  systemctl --no-pager --full status %s\n' "$TIMER_UNIT"
printf '查看服务日志：\n'
printf '  journalctl -u vnstat-shutdown.service -f\n'
printf '查看 vnStat 原始统计：\n'
printf '  vnstat --json | jq .\n'
printf '\n说明：本机 vnStat 统计可能与云厂商计费/网络口径不同，请以供应商账单为准。\n'
printf '达到阈值后仅执行关机；关机不会在次月自动开机或自启，需由外部电源/云平台策略启动。\n'
