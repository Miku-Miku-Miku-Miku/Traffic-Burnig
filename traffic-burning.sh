#!/usr/bin/env bash
# Traffic-Burnig — 使用 Ookla 官方 Speedtest CLI 消耗本机流量。
# Copyright (C) 2026 Miku
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本程序是自由软件：你可以根据自由软件基金会发布的 GNU 通用公共许可证
# 第 3 版，或（由你选择）任何更高版本，重新分发和/或修改它。

set -euo pipefail

PATH="/usr/sbin:/sbin:/usr/local/sbin:${PATH:-/usr/bin:/bin}"

VERSION="2.0.0"
OOKLA_VERSION="1.2.0"
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
NFT_TABLE="traffic_burn"
CG_NAME="traffic-burn"
MIN_PACKET=200
MAX_CONSECUTIVE_FAILURES=30

# ---------------------------------------------------------------------------
# 日志与退出
# ---------------------------------------------------------------------------

log() {
  local level=$1
  shift
  local line
  line="[$(date '+%F %T')] [${level}] $*"
  if [[ $level == ERROR ]]; then
    printf '%s\n' "$line" >&2
  else
    printf '%s\n' "$line"
  fi
  if [[ -n ${LOG_FILE-} ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

die() {
  log ERROR "$*"
  exit 1
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "此操作需要 root 权限，请使用 sudo 或 root 运行"
  fi
}

now_epoch() {
  if [[ ${TRAFFIC_BURN_TEST_MODE:-0} == 1 && -n ${TRAFFIC_BURN_NOW_EPOCH:-} ]]; then
    printf '%s\n' "$TRAFFIC_BURN_NOW_EPOCH"
    return 0
  fi
  date +%s
}

# ---------------------------------------------------------------------------
# 解析：容量、速度、时长、时段
# ---------------------------------------------------------------------------

parse_size_to_bytes() {
  local input
  input=$(trim "${1:-}")
  input=${input//[[:space:]]/}
  if [[ -z $input || $input == 0 ]]; then
    printf '0\n'
    return 0
  fi
  if [[ ! $input =~ ^([0-9]+([.][0-9]+)?)([A-Za-z]+)?$ ]]; then
    return 1
  fi
  awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[3]}" 'BEGIN {
    lu = tolower(u)
    if (lu == "" || lu == "b") m = 1
    else if (lu == "k" || lu == "kb") m = 1000
    else if (lu == "m" || lu == "mb") m = 1000 ^ 2
    else if (lu == "g" || lu == "gb") m = 1000 ^ 3
    else if (lu == "t" || lu == "tb") m = 1000 ^ 4
    else if (lu == "kib") m = 1024
    else if (lu == "mib") m = 1024 ^ 2
    else if (lu == "gib") m = 1024 ^ 3
    else if (lu == "tib") m = 1024 ^ 4
    else exit 1
    printf "%.0f\n", n * m
  }'
}

format_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b !~ /^[0-9]+$/) b = 0
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1000 && i < 6) { b /= 1000; i++ }
    if (i == 1) printf "%d %s\n", b, u[i]
    else printf "%.2f %s\n", b, u[i]
  }'
}

parse_mbps() {
  local raw
  raw=$(trim "${1:-}")
  raw=${raw//[[:space:]]/}
  if [[ -z $raw || $raw == 0 || $raw == 0.0 ]]; then
    printf '0\n'
    return 0
  fi
  if [[ ! $raw =~ ^([0-9]+([.][0-9]+)?)([A-Za-z/]+)?$ ]]; then
    return 1
  fi
  local num=${BASH_REMATCH[1]}
  local unit=${BASH_REMATCH[3]}
  case $unit in
    "" | Mbps | mbps | Mb/s | Mbit | mbit | Mb)
      awk -v n="$num" 'BEGIN { printf "%.6f\n", n }'
      ;;
    Kbps | kbps | Kbit | kbit | Kb/s)
      awk -v n="$num" 'BEGIN { printf "%.6f\n", n / 1000 }'
      ;;
    Gbps | gbps | Gbit | gbit | Gb/s)
      awk -v n="$num" 'BEGIN { printf "%.6f\n", n * 1000 }'
      ;;
    *)
      return 1
      ;;
  esac
}

mbps_to_bps() {
  awk -v m="$1" 'BEGIN { printf "%.0f\n", (m * 1000000) / 8 }'
}

format_mbps() {
  awk -v m="$1" 'BEGIN {
    if (m == 0) { printf "不限制\n"; exit }
    if (m >= 10) printf "%.0f Mbps\n", m
    else printf "%.2f Mbps\n", m
  }'
}

parse_duration() {
  local raw
  raw=$(trim "${1:-}")
  raw=${raw//[[:space:]]/}
  if [[ -z $raw || $raw == 0 ]]; then
    printf '0\n'
    return 0
  fi
  if [[ ! $raw =~ ^([0-9]+)([smhdSMHD])?$ ]]; then
    return 1
  fi
  local num=${BASH_REMATCH[1]}
  local unit=${BASH_REMATCH[2]}
  case $unit in
    "" | s | S) printf '%s\n' "$num" ;;
    m | M) printf '%s\n' $((num * 60)) ;;
    h | H) printf '%s\n' $((num * 3600)) ;;
    d | D) printf '%s\n' $((num * 86400)) ;;
    *) return 1 ;;
  esac
}

format_duration() {
  local seconds=${1:-0}
  if ((seconds <= 0)); then
    printf '不限制\n'
    return 0
  fi
  if ((seconds % 86400 == 0)); then
    printf '%d 天\n' $((seconds / 86400))
  elif ((seconds % 3600 == 0)); then
    printf '%d 小时\n' $((seconds / 3600))
  elif ((seconds % 60 == 0)); then
    printf '%d 分钟\n' $((seconds / 60))
  else
    printf '%d 秒\n' "$seconds"
  fi
}

normalize_period() {
  local p=${1:-}
  p=${p,,}
  case $p in
    run | once | session | 本次) printf 'run\n' ;;
    daily | day | 日 | 每天) printf 'daily\n' ;;
    monthly | month | 月 | 每月) printf 'monthly\n' ;;
    *) return 1 ;;
  esac
}

period_label() {
  case ${1:-} in
    run) printf '本次运行\n' ;;
    daily) printf '每个自然日\n' ;;
    monthly) printf '每个自然月\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

validate_schedule() {
  local schedule
  schedule=$(trim "${1:-}")
  if [[ -z $schedule ]]; then
    return 0
  fi
  local raw=()
  local part found=0
  IFS=',' read -ra raw <<<"$schedule"
  if ((${#raw[@]} == 0)); then
    return 1
  fi
  for part in "${raw[@]}"; do
    part=$(trim "$part")
    [[ -z $part ]] && continue
    if [[ ! $part =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])-([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
      return 1
    fi
    local sh=${BASH_REMATCH[1]} sm=${BASH_REMATCH[2]}
    local eh=${BASH_REMATCH[3]} em=${BASH_REMATCH[4]}
    if ((10#$sh * 60 + 10#$sm == 10#$eh * 60 + 10#$em)); then
      return 1
    fi
    found=1
  done
  ((found == 1))
}

schedule_windows() {
  local schedule
  schedule=$(trim "${1:-}")
  local raw=()
  local part
  [[ -z $schedule ]] && return 0
  IFS=',' read -ra raw <<<"$schedule"
  for part in "${raw[@]}"; do
    part=$(trim "$part")
    [[ -z $part ]] && continue
    printf '%s\n' "$part"
  done
}

schedule_active() {
  local schedule=$1
  local epoch=$2
  schedule=$(trim "$schedule")
  if [[ -z $schedule ]]; then
    return 0
  fi
  local hour minute minutes
  hour=$(date -d "@${epoch}" +%H)
  minute=$(date -d "@${epoch}" +%M)
  minutes=$((10#$hour * 60 + 10#$minute))
  local part sh sm eh em start end
  while IFS= read -r part; do
    [[ $part =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])-([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] || return 1
    sh=${BASH_REMATCH[1]}
    sm=${BASH_REMATCH[2]}
    eh=${BASH_REMATCH[3]}
    em=${BASH_REMATCH[4]}
    start=$((10#$sh * 60 + 10#$sm))
    end=$((10#$eh * 60 + 10#$em))
    if ((start < end)); then
      if ((minutes >= start && minutes < end)); then
        return 0
      fi
    else
      if ((minutes >= start || minutes < end)); then
        return 0
      fi
    fi
  done < <(schedule_windows "$schedule")
  return 1
}

seconds_until_schedule() {
  local schedule=$1
  local epoch=$2
  if schedule_active "$schedule" "$epoch"; then
    printf '0\n'
    return 0
  fi
  local best=999999999
  local part sh sm day start_epoch delta
  day=$(date -d "@${epoch}" +%F)
  while IFS= read -r part; do
    [[ $part =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])- ]] || continue
    sh=${BASH_REMATCH[1]}
    sm=${BASH_REMATCH[2]}
    printf -v sh '%02d' "$((10#$sh))"
    printf -v sm '%02d' "$((10#$sm))"
    start_epoch=$(date -d "${day} ${sh}:${sm}:00" +%s)
    if ((start_epoch <= epoch)); then
      start_epoch=$(date -d "${day} ${sh}:${sm}:00 + 1 day" +%s)
    fi
    delta=$((start_epoch - epoch))
    if ((delta < best)); then
      best=$delta
    fi
  done < <(schedule_windows "$schedule")
  if ((best > 86400)); then
    best=86400
  fi
  printf '%s\n' "$best"
}

current_period_key() {
  local epoch
  epoch=$(now_epoch)
  case ${QUOTA_PERIOD:-run} in
    run) printf 'run\n' ;;
    daily) date -d "@${epoch}" +%F ;;
    monthly) date -d "@${epoch}" +%Y-%m ;;
    *) printf 'run\n' ;;
  esac
}

seconds_until_next_period() {
  local now next
  now=$(date +%s)
  case ${QUOTA_PERIOD:-run} in
    daily)
      next=$(date -d 'tomorrow 00:00:00' +%s)
      ;;
    monthly)
      next=$(date -d "$(date +%Y-%m-01) + 1 month" +%s)
      ;;
    *)
      printf '60\n'
      return 0
      ;;
  esac
  if ((next <= now)); then
    printf '1\n'
  else
    printf '%s\n' $((next - now))
  fi
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

set_defaults() {
  QUOTA=""
  QUOTA_PERIOD="run"
  SCHEDULE=""
  DURATION="0"
  MAX_DOWNLOAD_MBPS="0"
  MAX_UPLOAD_MBPS="0"
  INTERVAL="5"
  SERVER_ID=""
  INTERFACE=""
  SPEEDTEST_BIN=""
  if [[ ${EUID} -eq 0 ]]; then
    LOG_FILE="/var/log/traffic-burn.log"
    STATE_FILE="/var/lib/traffic-burn/state"
    CONFIG_FILE="/etc/traffic-burn.conf"
    PREFIX="/usr/local"
  else
    local state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
    local config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
    LOG_FILE="${state_home}/traffic-burn/traffic-burn.log"
    STATE_FILE="${state_home}/traffic-burn/state"
    CONFIG_FILE="${config_home}/traffic-burn/traffic-burn.conf"
    PREFIX="${HOME}/.local"
  fi
  QUOTA_BYTES=0
  DURATION_SECONDS=0
  MAX_DOWNLOAD_BPS=0
  MAX_UPLOAD_BPS=0
  MAX_DOWNLOAD_MBPS_NUM=0
  MAX_UPLOAD_MBPS_NUM=0
  ONCE=0
  DRY_RUN=0
  DOWN_BYTES=0
  UP_BYTES=0
  LIFETIME_BYTES=0
  ROUNDS=0
  PERIOD_KEY=""
  LAST_TIME=""
  LAST_SERVER=""
  LAST_URL=""
  LAST_DOWN_BYTES=0
  LAST_UP_BYTES=0
  SHAPER_BACKEND=""
  CHILD_PID=""
  FAIL_STREAK=0
  START_EPOCH=0
  NS_NAME=""
  HOST_IF=""
  NS_IF=""
  NS_CIDR=""
  HOST_IP=""
  NS_IP=""
  ROUTE_TABLE=""
  RESTORE_FORWARD=0
  IPT_ADDED=()
  LOCK_HELD=0
  PID_FILE=""
  CG_PATH="${TRAFFIC_BURN_CG_PATH:-/sys/fs/cgroup/${CG_NAME}}"
  CONFIG_EXPLICIT=0
  CLI_QUOTA_SET=0
  CLI_PERIOD_SET=0
  CLI_SCHEDULE_SET=0
  CLI_DURATION_SET=0
  CLI_MAX_DOWN_SET=0
  CLI_MAX_UP_SET=0
  CLI_INTERVAL_SET=0
  CLI_SERVER_SET=0
  CLI_INTERFACE_SET=0
  CLI_BIN_SET=0
  CLI_LOG_SET=0
  CLI_STATE_SET=0
  TBF_SUPPORTED_CACHE=""
}

load_config_file() {
  local file=$1
  [[ -f $file ]] || die "找不到配置文件: ${file}"
  local line key val
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    line=${line%%#*}
    line=$(trim "$line")
    [[ -z $line ]] && continue
    if [[ ! $line =~ ^([A-Z_]+)=(.*)$ ]]; then
      die "无法解析配置行: ${line}"
    fi
    key=${BASH_REMATCH[1]}
    val=$(trim "${BASH_REMATCH[2]}")
    if [[ $val == \"*\" && ${#val} -ge 2 ]]; then
      val=${val:1:${#val}-2}
    elif [[ $val == \'*\' && ${#val} -ge 2 ]]; then
      val=${val:1:${#val}-2}
    fi
    case $key in
      QUOTA) QUOTA=$val ;;
      QUOTA_PERIOD) QUOTA_PERIOD=$val ;;
      SCHEDULE) SCHEDULE=$val ;;
      DURATION) DURATION=$val ;;
      MAX_DOWNLOAD_MBPS) MAX_DOWNLOAD_MBPS=$val ;;
      MAX_UPLOAD_MBPS) MAX_UPLOAD_MBPS=$val ;;
      INTERVAL) INTERVAL=$val ;;
      SERVER_ID) SERVER_ID=$val ;;
      INTERFACE) INTERFACE=$val ;;
      SPEEDTEST_BIN) SPEEDTEST_BIN=$val ;;
      LOG_FILE) LOG_FILE=$val ;;
      STATE_FILE) STATE_FILE=$val ;;
      *) die "未知配置项: ${key}" ;;
    esac
  done <"$file"
}

reject_unsafe_value() {
  local name=$1
  local val=$2
  if [[ $val == *$'\n'* || $val == *$'\r'* || $val == *'"'* ]]; then
    die "${name} 含有换行或双引号，请去掉后再写配置"
  fi
}

validate_settings() {
  local period bytes down_num up_num
  if [[ -z ${QUOTA} || ${QUOTA} == 0 ]]; then
    QUOTA_BYTES=0
    QUOTA=""
  else
    if ! bytes=$(parse_size_to_bytes "$QUOTA"); then
      die "无法识别配额 QUOTA=${QUOTA}。示例: 10GB、500MB、1.5GiB"
    fi
    QUOTA_BYTES=$bytes
  fi
  if ! period=$(normalize_period "$QUOTA_PERIOD"); then
    die "无法识别 QUOTA_PERIOD=${QUOTA_PERIOD}。可用 run、daily、monthly"
  fi
  QUOTA_PERIOD=$period
  if ! validate_schedule "$SCHEDULE"; then
    die "无法识别 SCHEDULE=${SCHEDULE}。示例: 01:00-07:00,22:00-23:30"
  fi
  if ! DURATION_SECONDS=$(parse_duration "$DURATION"); then
    die "无法识别 DURATION=${DURATION}。示例: 90m、2h、1d、0"
  fi
  if ! down_num=$(parse_mbps "$MAX_DOWNLOAD_MBPS"); then
    die "无法识别 MAX_DOWNLOAD_MBPS=${MAX_DOWNLOAD_MBPS}"
  fi
  if ! up_num=$(parse_mbps "$MAX_UPLOAD_MBPS"); then
    die "无法识别 MAX_UPLOAD_MBPS=${MAX_UPLOAD_MBPS}"
  fi
  MAX_DOWNLOAD_MBPS_NUM=$down_num
  MAX_UPLOAD_MBPS_NUM=$up_num
  MAX_DOWNLOAD_BPS=$(mbps_to_bps "$down_num")
  MAX_UPLOAD_BPS=$(mbps_to_bps "$up_num")
  if [[ ! ${INTERVAL} =~ ^[0-9]+$ ]]; then
    die "INTERVAL 必须是非负整数秒，当前为 ${INTERVAL}"
  fi
  if ((INTERVAL > 86400)); then
    die "INTERVAL 不能超过 86400 秒"
  fi
  if [[ -n $SERVER_ID && ! $SERVER_ID =~ ^[0-9]+$ ]]; then
    die "SERVER_ID 必须是数字，当前为 ${SERVER_ID}"
  fi
  if [[ -n $INTERFACE && ! $INTERFACE =~ ^[A-Za-z0-9._:-]+$ ]]; then
    die "INTERFACE 含有非法字符: ${INTERFACE}"
  fi
  if [[ -n $SPEEDTEST_BIN && ! -x $SPEEDTEST_BIN ]]; then
    die "SPEEDTEST_BIN 不存在或不可执行: ${SPEEDTEST_BIN}"
  fi
}

apply_cli_overrides() {
  if ((CLI_QUOTA_SET)); then QUOTA=$CLI_QUOTA; fi
  if ((CLI_PERIOD_SET)); then QUOTA_PERIOD=$CLI_PERIOD; fi
  if ((CLI_SCHEDULE_SET)); then SCHEDULE=$CLI_SCHEDULE; fi
  if ((CLI_DURATION_SET)); then DURATION=$CLI_DURATION; fi
  if ((CLI_MAX_DOWN_SET)); then MAX_DOWNLOAD_MBPS=$CLI_MAX_DOWN; fi
  if ((CLI_MAX_UP_SET)); then MAX_UPLOAD_MBPS=$CLI_MAX_UP; fi
  if ((CLI_INTERVAL_SET)); then INTERVAL=$CLI_INTERVAL; fi
  if ((CLI_SERVER_SET)); then SERVER_ID=$CLI_SERVER; fi
  if ((CLI_INTERFACE_SET)); then INTERFACE=$CLI_INTERFACE; fi
  if ((CLI_BIN_SET)); then SPEEDTEST_BIN=$CLI_BIN; fi
  if ((CLI_LOG_SET)); then LOG_FILE=$CLI_LOG; fi
  if ((CLI_STATE_SET)); then STATE_FILE=$CLI_STATE; fi
}

prepare_dirs() {
  mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
  rotate_log
}

rotate_log() {
  [[ -f ${LOG_FILE} ]] || return 0
  local size
  size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')
  if ((size > 5242880)); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
  fi
}

write_config() {
  local dest=$1
  reject_unsafe_value QUOTA "$QUOTA"
  reject_unsafe_value QUOTA_PERIOD "$QUOTA_PERIOD"
  reject_unsafe_value SCHEDULE "$SCHEDULE"
  reject_unsafe_value DURATION "$DURATION"
  reject_unsafe_value MAX_DOWNLOAD_MBPS "$MAX_DOWNLOAD_MBPS"
  reject_unsafe_value MAX_UPLOAD_MBPS "$MAX_UPLOAD_MBPS"
  reject_unsafe_value INTERVAL "$INTERVAL"
  reject_unsafe_value SERVER_ID "$SERVER_ID"
  reject_unsafe_value INTERFACE "$INTERFACE"
  reject_unsafe_value SPEEDTEST_BIN "$SPEEDTEST_BIN"
  reject_unsafe_value LOG_FILE "$LOG_FILE"
  reject_unsafe_value STATE_FILE "$STATE_FILE"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<EOF
# Traffic-Burnig 配置
# 配额按十进制计算：1 GB = 1000 MB。也可用 GiB（1024 进制）。
# 留空或 0 表示不限制。
QUOTA="${QUOTA}"
# run=本次进程；daily=每个自然日；monthly=每个自然月
QUOTA_PERIOD="${QUOTA_PERIOD}"
# 允许燃烧的本地时间段，逗号分隔，支持跨夜。留空表示全天。
SCHEDULE="${SCHEDULE}"
# 单次启动最长运行时间。0 表示直到配额完成或手动停止。示例: 90m、2h、1d
DURATION="${DURATION}"
# 最大下行 / 上行速度，单位 Mbps。0 表示不限制。
MAX_DOWNLOAD_MBPS="${MAX_DOWNLOAD_MBPS}"
MAX_UPLOAD_MBPS="${MAX_UPLOAD_MBPS}"
# 两轮官方测速之间的间隔秒数
INTERVAL="${INTERVAL}"
# Ookla 服务器 ID，留空则自动选择
SERVER_ID="${SERVER_ID}"
# 绑定网卡，留空则走系统默认路由
INTERFACE="${INTERFACE}"
# 官方 speedtest 可执行文件，留空则自动查找或安装
SPEEDTEST_BIN="${SPEEDTEST_BIN}"
LOG_FILE="${LOG_FILE}"
STATE_FILE="${STATE_FILE}"
EOF
  chmod 644 "$dest"
}

# ---------------------------------------------------------------------------
# 状态文件
# ---------------------------------------------------------------------------

save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  STATE_PERIOD_KEY="$PERIOD_KEY" \
    STATE_DOWN="$DOWN_BYTES" \
    STATE_UP="$UP_BYTES" \
    STATE_LIFE="$LIFETIME_BYTES" \
    STATE_ROUNDS="$ROUNDS" \
    STATE_LAST_TIME="$LAST_TIME" \
    STATE_LAST_SERVER="$LAST_SERVER" \
    STATE_LAST_URL="$LAST_URL" \
    STATE_LAST_DOWN="$LAST_DOWN_BYTES" \
    STATE_LAST_UP="$LAST_UP_BYTES" \
    python3 - "$STATE_FILE" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
data = {
    "period_key": os.environ.get("STATE_PERIOD_KEY", ""),
    "down_bytes": int(os.environ.get("STATE_DOWN", "0")),
    "up_bytes": int(os.environ.get("STATE_UP", "0")),
    "lifetime_bytes": int(os.environ.get("STATE_LIFE", "0")),
    "rounds": int(os.environ.get("STATE_ROUNDS", "0")),
    "last_time": os.environ.get("STATE_LAST_TIME", ""),
    "last_server": os.environ.get("STATE_LAST_SERVER", ""),
    "last_url": os.environ.get("STATE_LAST_URL", ""),
    "last_down_bytes": int(os.environ.get("STATE_LAST_DOWN", "0")),
    "last_up_bytes": int(os.environ.get("STATE_LAST_UP", "0")),
}
directory = os.path.dirname(path) or "."
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".state.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False)
        handle.write("\n")
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

load_state() {
  local parsed
  parsed=$(python3 - "$STATE_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {
    "period_key": "",
    "down_bytes": 0,
    "up_bytes": 0,
    "lifetime_bytes": 0,
    "rounds": 0,
    "last_time": "",
    "last_server": "",
    "last_url": "",
    "last_down_bytes": 0,
    "last_up_bytes": 0,
}
if os.path.exists(path):
    try:
        loaded = json.load(open(path, encoding="utf-8"))
        if isinstance(loaded, dict):
            data.update(loaded)
    except Exception:
        pass

def num(key):
    try:
        value = int(data.get(key) or 0)
    except (TypeError, ValueError):
        value = 0
    if value < 0:
        value = 0
    return value

def text(key):
    value = data.get(key) or ""
    return str(value).replace("\n", " ").replace("\r", " ")

print(text("period_key"))
print(num("down_bytes"))
print(num("up_bytes"))
print(num("lifetime_bytes"))
print(num("rounds"))
print(text("last_time"))
print(text("last_server"))
print(text("last_url"))
print(num("last_down_bytes"))
print(num("last_up_bytes"))
PY
)
  local line_no=0
  local line
  while IFS= read -r line; do
    line_no=$((line_no + 1))
    case $line_no in
      1) PERIOD_KEY=$line ;;
      2) DOWN_BYTES=$line ;;
      3) UP_BYTES=$line ;;
      4) LIFETIME_BYTES=$line ;;
      5) ROUNDS=$line ;;
      6) LAST_TIME=$line ;;
      7) LAST_SERVER=$line ;;
      8) LAST_URL=$line ;;
      9) LAST_DOWN_BYTES=$line ;;
      10) LAST_UP_BYTES=$line ;;
    esac
  done <<<"$parsed"
  local key
  key=$(current_period_key)
  if [[ $PERIOD_KEY != "$key" ]]; then
    DOWN_BYTES=0
    UP_BYTES=0
    ROUNDS=0
    PERIOD_KEY=$key
    save_state
  fi
}

quota_reached() {
  if ((QUOTA_BYTES == 0)); then
    return 1
  fi
  if ((DOWN_BYTES + UP_BYTES >= QUOTA_BYTES)); then
    return 0
  fi
  return 1
}

record_transfer() {
  local down=$1
  local up=$2
  local server=$3
  local url=$4
  DOWN_BYTES=$((DOWN_BYTES + down))
  UP_BYTES=$((UP_BYTES + up))
  LIFETIME_BYTES=$((LIFETIME_BYTES + down + up))
  ROUNDS=$((ROUNDS + 1))
  LAST_DOWN_BYTES=$down
  LAST_UP_BYTES=$up
  LAST_SERVER=$server
  LAST_URL=$url
  LAST_TIME=$(date '+%F %T')
  PERIOD_KEY=$(current_period_key)
  save_state
}

# ---------------------------------------------------------------------------
# Ookla 官方客户端
# ---------------------------------------------------------------------------

ookla_arch_from() {
  case $1 in
    x86_64 | amd64) printf 'x86_64\n' ;;
    aarch64 | arm64) printf 'aarch64\n' ;;
    armv7l | armhf) printf 'armhf\n' ;;
    armv6l | armel) printf 'armel\n' ;;
    i386 | i686) printf 'i386\n' ;;
    *) return 1 ;;
  esac
}

ookla_sha256() {
  case $1 in
    x86_64) printf '%s\n' '5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7' ;;
    aarch64) printf '%s\n' '3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3' ;;
    armhf) printf '%s\n' 'e45fcdebbd8a185553535533dd032d6b10bc8c64eee4139b1147b9c09835d08d' ;;
    armel) printf '%s\n' '629a455a2879224bd0dbd4b36d8c721dda540717937e4660b4d2c966029466bf' ;;
    i386) printf '%s\n' '9ff7e18dbae7ee0e03c66108445a2fb6ceea6c86f66482e1392f55881b772fe8' ;;
    *) return 1 ;;
  esac
}

is_ookla_binary() {
  local bin=$1
  [[ -n $bin && -x $bin ]] || return 1
  "$bin" --version 2>&1 | grep -qi 'Speedtest by Ookla'
}

is_legacy_speedtest_script() {
  local bin=$1
  [[ -f $bin ]] || return 1
  local head
  head=$(head -n 1 "$bin" 2>/dev/null || true)
  [[ $head == *python* || $head == *speedtest-cli* ]]
}

resolve_speedtest_bin() {
  if [[ -n $SPEEDTEST_BIN ]]; then
    if [[ ${TRAFFIC_BURN_TEST_MODE:-0} == 1 ]]; then
      printf '%s\n' "$SPEEDTEST_BIN"
      return 0
    fi
    if is_ookla_binary "$SPEEDTEST_BIN"; then
      printf '%s\n' "$SPEEDTEST_BIN"
      return 0
    fi
    die "SPEEDTEST_BIN 不是 Ookla 官方客户端: ${SPEEDTEST_BIN}"
  fi
  local candidate
  for candidate in "$(command -v speedtest 2>/dev/null || true)" /usr/local/bin/speedtest /usr/bin/speedtest; do
    [[ -n $candidate && -x $candidate ]] || continue
    if is_ookla_binary "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_packages() {
  local -a packages=("$@")
  ((${#packages[@]})) || return 0
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}"
  else
    die "无法自动安装: ${packages[*]}。请手动安装后重试"
  fi
}

package_for() {
  local tool=$1
  local family=$2
  case "${family}:${tool}" in
    deb:curl) printf 'curl\n' ;;
    deb:tar) printf 'tar\n' ;;
    deb:sha256sum) printf 'coreutils\n' ;;
    deb:python3) printf 'python3\n' ;;
    deb:ip | deb:tc) printf 'iproute2\n' ;;
    deb:nft) printf 'nftables\n' ;;
    deb:iptables) printf 'iptables\n' ;;
    deb:flock) printf 'util-linux\n' ;;
    rpm:curl) printf 'curl\n' ;;
    rpm:tar) printf 'tar\n' ;;
    rpm:sha256sum) printf 'coreutils\n' ;;
    rpm:python3) printf 'python3\n' ;;
    rpm:ip | rpm:tc) printf 'iproute\n' ;;
    rpm:nft) printf 'nftables\n' ;;
    rpm:iptables) printf 'iptables\n' ;;
    rpm:flock) printf 'util-linux\n' ;;
    *) return 1 ;;
  esac
}

ensure_commands() {
  local -a needed=("$@")
  local -a missing=()
  local cmd family pkg
  if [[ -f /etc/os-release ]] && grep -Eqi 'debian|ubuntu' /etc/os-release; then
    family=deb
  else
    family=rpm
  fi
  for cmd in "${needed[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      if pkg=$(package_for "$cmd" "$family"); then
        missing+=("$pkg")
      else
        missing+=("$cmd")
      fi
    fi
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  local -a unique=()
  local item seen
  for item in "${missing[@]}"; do
    seen=0
    if ((${#unique[@]})); then
      local have
      for have in "${unique[@]}"; do
        if [[ $have == "$item" ]]; then
          seen=1
          break
        fi
      done
    fi
    if ((seen == 0)); then
      unique+=("$item")
    fi
  done
  require_root
  log INFO "安装缺少的依赖: ${unique[*]}"
  install_packages "${unique[@]}"
}

install_self_to() {
  local dest=$1
  mkdir -p "$(dirname "$dest")"
  if [[ -f $SCRIPT_PATH && -r $SCRIPT_PATH ]]; then
    cp -f "$SCRIPT_PATH" "$dest"
  else
    local url=${TRAFFIC_BURN_SOURCE_URL:-https://raw.githubusercontent.com/Miku-Miku-Miku-Miku/Traffic-Burnig/main/traffic-burning.sh}
    log INFO "当前脚本来自管道，改为下载 ${url}"
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
  fi
  chmod 0755 "$dest"
  if ! grep -q 'Traffic-Burnig' "$dest"; then
    rm -f "$dest"
    die "安装到 ${dest} 的脚本内容不完整"
  fi
}

install_official_speedtest() {
  local arch dest url sha tmp
  if ! arch=$(ookla_arch_from "$(uname -m)"); then
    die "不支持的 CPU 架构: $(uname -m)"
  fi
  sha=$(ookla_sha256 "$arch")
  dest="${PREFIX}/bin/speedtest"
  mkdir -p "$(dirname "$dest")"
  if [[ -e $dest ]] && is_legacy_speedtest_script "$dest"; then
    mv -f "$dest" "${dest}.legacy"
    log INFO "已将旧版 speedtest-cli 重命名为 ${dest}.legacy"
  fi
  url="https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VERSION}-linux-${arch}.tgz"
  tmp=$(mktemp -d)
  log INFO "下载 Ookla Speedtest CLI ${OOKLA_VERSION} (${arch})"
  curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/speedtest.tgz" "$url"
  if ! printf '%s  %s\n' "$sha" "${tmp}/speedtest.tgz" | sha256sum -c - >/dev/null; then
    rm -rf "$tmp"
    die "官方客户端校验失败，已中止安装"
  fi
  tar -xzf "${tmp}/speedtest.tgz" -C "$tmp"
  [[ -f ${tmp}/speedtest ]] || {
    rm -rf "$tmp"
    die "压缩包中没有 speedtest 可执行文件"
  }
  install -m 0755 "${tmp}/speedtest" "$dest"
  rm -rf "$tmp"
  if ! is_ookla_binary "$dest"; then
    die "安装后的程序不是 Ookla 官方客户端"
  fi
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n' "$dest" >"$(dirname "$STATE_FILE")/managed-speedtest"
  SPEEDTEST_BIN=$dest
  local ver
  ver=$("$dest" --version 2>&1 || true)
  ver=${ver%%$'\n'*}
  log INFO "官方客户端已安装: ${ver}"
}

# ---------------------------------------------------------------------------
# 限速：优先 tc tbf，不可用时用 nftables 对大包限速（ACK 不计入）
# ---------------------------------------------------------------------------

burst_bytes_for() {
  local bps=$1
  local burst=$((bps / 10))
  if ((burst < 32768)); then
    burst=32768
  fi
  if ((burst > 2000000)); then
    burst=2000000
  fi
  printf '%s\n' "$burst"
}

tbf_supported() {
  if [[ ${TBF_SUPPORTED_CACHE} == yes ]]; then
    return 0
  fi
  if [[ ${TBF_SUPPORTED_CACHE} == no ]]; then
    return 1
  fi
  if [[ ${EUID} -ne 0 ]] || ! command -v tc >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1; then
    TBF_SUPPORTED_CACHE=no
    return 1
  fi
  local probe_a probe_b
  probe_a=$(printf 'tba%04d' $((RANDOM % 10000)))
  probe_b=$(printf 'tbb%04d' $((RANDOM % 10000)))
  if ! ip link add "$probe_a" type veth peer name "$probe_b" >/dev/null 2>&1; then
    TBF_SUPPORTED_CACHE=no
    return 1
  fi
  ip link set "$probe_a" up >/dev/null 2>&1 || true
  if tc qdisc replace dev "$probe_a" root tbf rate 1mbit burst 32kb latency 50ms >/dev/null 2>&1; then
    TBF_SUPPORTED_CACHE=yes
    ip link del "$probe_a" >/dev/null 2>&1 || true
    return 0
  fi
  ip link del "$probe_a" >/dev/null 2>&1 || true
  TBF_SUPPORTED_CACHE=no
  return 1
}

write_netns_resolv() {
  local dest=$1
  python3 - "$dest" <<'PY'
import os, sys
dest = sys.argv[1]
candidates = []
for path in ("/run/systemd/resolve/resolv.conf", "/etc/resolv.conf"):
    if os.path.exists(path):
        candidates.append(path)
servers = []
for path in candidates:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "nameserver":
            ip = parts[1]
            if ip.startswith("127.") or ip == "::1":
                continue
            if ip not in servers:
                servers.append(ip)
if not servers:
    servers = ["1.1.1.1", "8.8.8.8"]
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest, "w", encoding="utf-8") as handle:
    for ip in servers:
        handle.write(f"nameserver {ip}\n")
PY
}

add_iptables_rule() {
  local table=$1
  shift
  iptables -t "$table" -A "$@" || return 1
  IPT_ADDED+=("${table}|-D $*")
}

cleanup_iptables() {
  local item table args
  local i
  if ((${#IPT_ADDED[@]} == 0)); then
    return 0
  fi
  for ((i = ${#IPT_ADDED[@]} - 1; i >= 0; i--)); do
    item=${IPT_ADDED[$i]}
    table=${item%%|*}
    args=${item#*|}
    # shellcheck disable=SC2086
    iptables -t "$table" $args >/dev/null 2>&1 || true
  done
  IPT_ADDED=()
}

cleanup_tbf() {
  cleanup_iptables
  if [[ -n $NS_IP && -n $ROUTE_TABLE ]]; then
    ip rule del from "$NS_IP" lookup "$ROUTE_TABLE" >/dev/null 2>&1 || true
    ip route flush table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  fi
  if [[ -n $HOST_IF ]]; then
    ip link del "$HOST_IF" >/dev/null 2>&1 || true
  fi
  if [[ -n $NS_NAME ]]; then
    ip netns del "$NS_NAME" >/dev/null 2>&1 || true
    rm -rf "/etc/netns/${NS_NAME}"
  fi
  if [[ ${RESTORE_FORWARD} == 1 ]]; then
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    RESTORE_FORWARD=0
  fi
  NS_NAME=""
  HOST_IF=""
  NS_IF=""
}

setup_tbf_network() {
  local suffix
  suffix=$(printf '%04d' $(($$ % 10000)))
  NS_NAME="tb${suffix}"
  HOST_IF="th${suffix}"
  NS_IF="tn${suffix}"
  local second=$(((RANDOM % 200) + 20))
  local third=$((($$ % 200) + 20))
  NS_CIDR="10.${second}.${third}.0/30"
  HOST_IP="10.${second}.${third}.1"
  NS_IP="10.${second}.${third}.2"
  ROUTE_TABLE=$((20000 + 10#$suffix))
  ip netns add "$NS_NAME" || return 1
  ip link add "$HOST_IF" type veth peer name "$NS_IF" || return 1
  ip link set "$NS_IF" netns "$NS_NAME" || return 1
  ip addr add "${HOST_IP}/30" dev "$HOST_IF" || return 1
  ip link set "$HOST_IF" up || return 1
  ip netns exec "$NS_NAME" ip addr add "${NS_IP}/30" dev "$NS_IF" || return 1
  ip netns exec "$NS_NAME" ip link set "$NS_IF" up || return 1
  ip netns exec "$NS_NAME" ip link set lo up || return 1
  ip netns exec "$NS_NAME" ip route add default via "$HOST_IP" || return 1
  ip netns exec "$NS_NAME" sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
  ip netns exec "$NS_NAME" sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
  write_netns_resolv "/etc/netns/${NS_NAME}/resolv.conf"
  if [[ $(cat /proc/sys/net/ipv4/ip_forward) != 1 ]]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1
    RESTORE_FORWARD=1
  fi
  add_iptables_rule nat POSTROUTING -s "$NS_CIDR" -m comment --comment "traffic-burn-${NS_NAME}" -j MASQUERADE || return 1
  add_iptables_rule filter FORWARD -s "$NS_CIDR" -m comment --comment "traffic-burn-${NS_NAME}" -j ACCEPT || return 1
  add_iptables_rule filter FORWARD -d "$NS_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "traffic-burn-${NS_NAME}" -j ACCEPT || return 1
  if iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -s "$NS_CIDR" -m comment --comment "traffic-burn-${NS_NAME}" -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
    IPT_ADDED+=("mangle|-D FORWARD -p tcp --tcp-flags SYN,RST SYN -s ${NS_CIDR} -m comment --comment traffic-burn-${NS_NAME} -j TCPMSS --clamp-mss-to-pmtu")
  fi
  if [[ -n $INTERFACE ]]; then
    local gw
    gw=$(ip route show dev "$INTERFACE" 2>/dev/null | awk '/^default/ { print $3; exit }')
    if [[ -n $gw ]]; then
      ip route replace default via "$gw" dev "$INTERFACE" table "$ROUTE_TABLE" || return 1
      ip rule add from "$NS_IP" lookup "$ROUTE_TABLE" priority $((10000 + 10#$suffix)) || return 1
    else
      log WARN "网卡 ${INTERFACE} 没有默认网关，限速流量改走系统默认路由"
    fi
  fi
}

apply_tbf_qdisc() {
  local dev=$1
  local bps=$2
  local in_ns=${3:-}
  if ((bps <= 0)); then
    return 0
  fi
  local kbit burst
  kbit=$(awk -v b="$bps" 'BEGIN { printf "%.0f\n", (b * 8) / 1000 }')
  if ((kbit < 1)); then
    kbit=1
  fi
  burst=$(burst_bytes_for "$bps")
  if [[ -n $in_ns ]]; then
    ip netns exec "$NS_NAME" tc qdisc replace dev "$dev" root tbf rate "${kbit}kbit" burst "${burst}" latency 200ms || return 1
  else
    tc qdisc replace dev "$dev" root tbf rate "${kbit}kbit" burst "${burst}" latency 200ms || return 1
  fi
}

setup_tbf_shaper() {
  SHAPER_BACKEND="tbf"
  if ! setup_tbf_network; then
    cleanup_tbf
    SHAPER_BACKEND=""
    return 1
  fi
  if ! apply_tbf_qdisc "$HOST_IF" "$MAX_DOWNLOAD_BPS" ""; then
    cleanup_tbf
    SHAPER_BACKEND=""
    return 1
  fi
  if ! apply_tbf_qdisc "$NS_IF" "$MAX_UPLOAD_BPS" 1; then
    cleanup_tbf
    SHAPER_BACKEND=""
    return 1
  fi
  return 0
}

cleanup_nft() {
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  fi
  if [[ -d $CG_PATH ]]; then
    if [[ -f ${CG_PATH}/cgroup.procs ]]; then
      local pid
      while IFS= read -r pid; do
        [[ -z $pid || $pid == "$$" ]] && continue
        kill "$pid" >/dev/null 2>&1 || true
      done <"${CG_PATH}/cgroup.procs"
    fi
    rmdir "$CG_PATH" >/dev/null 2>&1 || true
  fi
}

setup_nft_shaper() {
  command -v nft >/dev/null 2>&1 || return 1
  if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    log ERROR "系统不是 cgroup v2，无法使用 nftables 限速"
    return 1
  fi
  mkdir -p "$CG_PATH" || return 1
  SHAPER_BACKEND="nft"
  nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  nft add table inet "$NFT_TABLE" || return 1
  nft add chain inet "$NFT_TABLE" input '{ type filter hook input priority 0; policy accept; }' || return 1
  nft add chain inet "$NFT_TABLE" output '{ type filter hook output priority 0; policy accept; }' || return 1
  local chain bps burst
  for chain in input output; do
    if [[ $chain == input ]]; then
      bps=$MAX_DOWNLOAD_BPS
    else
      bps=$MAX_UPLOAD_BPS
    fi
    if ((bps <= 0)); then
      continue
    fi
    # 丢包限速在长传输上会比令牌速率略高。按 90% 下发，让实际速度留在设定上限以内。
    local policed
    policed=$(awk -v b="$bps" 'BEGIN { v = b * 0.90; if (v < 1) v = 1; printf "%.0f", v }')
    burst=$(burst_bytes_for "$policed")
    nft add rule inet "$NFT_TABLE" "$chain" \
      socket cgroupv2 level 1 "$CG_NAME" \
      meta length '>=' "$MIN_PACKET" \
      limit rate over "$policed" bytes/second \
      burst "$burst" bytes \
      drop || return 1
  done
}

cleanup_shaper() {
  case ${SHAPER_BACKEND:-} in
    nft) cleanup_nft ;;
    tbf) cleanup_tbf ;;
  esac
  SHAPER_BACKEND=""
}

setup_shaper() {
  if ((MAX_DOWNLOAD_BPS == 0 && MAX_UPLOAD_BPS == 0)); then
    return 0
  fi
  require_root
  ensure_commands ip tc nft iptables
  local want=${TRAFFIC_BURN_SHAPER:-auto}
  if [[ $want != nft ]] && tbf_supported; then
    if setup_tbf_shaper; then
      log INFO "限速已启用: tc tbf，下行 $(format_mbps "$MAX_DOWNLOAD_MBPS_NUM")，上行 $(format_mbps "$MAX_UPLOAD_MBPS_NUM")"
      return 0
    fi
    if [[ $want == tbf ]]; then
      die "指定了 tbf 限速但创建失败。已停止，不会以不限速方式燃烧"
    fi
    log WARN "tc tbf 不可用，改用 nftables 限速"
  fi
  if ! setup_nft_shaper; then
    cleanup_shaper
    die "限速启用失败。已停止，不会以不限速方式燃烧"
  fi
  log INFO "限速已启用: nftables，下行 $(format_mbps "$MAX_DOWNLOAD_MBPS_NUM")，上行 $(format_mbps "$MAX_UPLOAD_MBPS_NUM")"
  log INFO "当前内核没有可用的 tbf 队列，限速通过丢弃超额数据包实现，测速丢包率会偏高，实际速度会接近但不超过设定值"
}

launch_limited() {
  if [[ ${SHAPER_BACKEND} == tbf ]]; then
    ip netns exec "$NS_NAME" "$@" &
    CHILD_PID=$!
  elif [[ ${SHAPER_BACKEND} == nft ]]; then
    bash -c 'echo $$ > "$1" || exit 97; shift; exec "$@"' bash "$CG_PATH/cgroup.procs" "$@" &
    CHILD_PID=$!
  else
    "$@" &
    CHILD_PID=$!
  fi
  local rc=0
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""
  return "$rc"
}

# ---------------------------------------------------------------------------
# 测速一轮
# ---------------------------------------------------------------------------

parse_speedtest_output() {
  local file=$1
  python3 - "$file" <<'PY'
import json, sys
path = sys.argv[1]
raw = open(path, encoding="utf-8", errors="replace").read().strip()
if not raw:
    sys.exit(2)
decoder = json.JSONDecoder()
obj = None
try:
    obj = json.loads(raw)
except json.JSONDecodeError:
    index = 0
    while True:
        start = raw.find("{", index)
        if start < 0:
            break
        try:
            value, _end = decoder.raw_decode(raw, start)
        except json.JSONDecodeError:
            index = start + 1
            continue
        if isinstance(value, dict):
            obj = value
        index = start + 1
if not isinstance(obj, dict):
    sys.exit(2)

def section(name):
    value = obj.get(name) or {}
    return value if isinstance(value, dict) else {}

down = section("download")
up = section("upload")
server = section("server")
result = section("result")

def as_int(value):
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0

def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0

def clean(value):
    return str(value or "").replace("\t", " ").replace("\n", " ").replace("\r", " ")

fields = [
    str(as_int(down.get("bytes"))),
    str(as_int(up.get("bytes"))),
    "%.3f" % as_float(down.get("bandwidth")),
    "%.3f" % as_float(up.get("bandwidth")),
    clean(server.get("id")),
    clean(server.get("name")),
    clean(server.get("location")),
    clean(server.get("country")),
    clean(result.get("url")),
]
sys.stdout.write("\t".join(fields))
PY
}

bandwidth_to_mbps() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.2f\n", (b * 8) / 1000000 }'
}

build_speedtest_command() {
  SPEEDTEST_CMD=("$SPEEDTEST_BIN" --accept-license --accept-gdpr --format=json --progress=no)
  if [[ -n $SERVER_ID ]]; then
    SPEEDTEST_CMD+=(--server-id="$SERVER_ID")
  fi
  if [[ -n $INTERFACE && ${SHAPER_BACKEND} != tbf ]]; then
    SPEEDTEST_CMD+=(--interface="$INTERFACE")
  fi
}

run_one_round() {
  local out err parsed rc
  out=$(mktemp)
  err=$(mktemp)
  build_speedtest_command
  log INFO "开始第 $((ROUNDS + 1)) 轮官方测速"
  set +e
  launch_limited "${SPEEDTEST_CMD[@]}" >"$out" 2>"$err"
  rc=$?
  set -e
  if ((rc != 0)); then
    log ERROR "官方测速失败，退出码 ${rc}"
    if [[ -s $err ]]; then
      tail -n 20 "$err" >&2 || true
    fi
    rm -f "$out" "$err"
    return 1
  fi
  if ! parsed=$(parse_speedtest_output "$out"); then
    log ERROR "无法解析官方测速结果"
    if [[ -s $err ]]; then
      tail -n 20 "$err" >&2 || true
    fi
    rm -f "$out" "$err"
    return 1
  fi
  local down up down_bw up_bw sid name location country url server_label
  IFS=$'\t' read -r down up down_bw up_bw sid name location country url <<<"$parsed"
  if [[ -z $name && -n $sid ]]; then
    name="id ${sid}"
  fi
  if ((down + up <= 0)); then
    log ERROR "本轮没有产生流量，视为失败"
    rm -f "$out" "$err"
    return 1
  fi
  server_label="${name}"
  if [[ -n $location || -n $country ]]; then
    server_label="${server_label} ${location} ${country}"
  fi
  server_label=$(trim "$server_label")
  record_transfer "$down" "$up" "$server_label" "$url"
  local quota_text
  if ((QUOTA_BYTES > 0)); then
    quota_text="，本周期 $(format_bytes $((DOWN_BYTES + UP_BYTES))) / $(format_bytes "$QUOTA_BYTES")"
  else
    quota_text="，本周期 $(format_bytes $((DOWN_BYTES + UP_BYTES)))"
  fi
  log INFO "第 ${ROUNDS} 轮完成: 下行 $(format_bytes "$down") ($(bandwidth_to_mbps "$down_bw") Mbps)，上行 $(format_bytes "$up") ($(bandwidth_to_mbps "$up_bw") Mbps)${quota_text}，节点 ${server_label:-未知}"
  if [[ -n $url ]]; then
    log INFO "结果页面: ${url}"
  fi
  rm -f "$out" "$err"
  return 0
}

duration_exceeded() {
  if ((DURATION_SECONDS <= 0 || START_EPOCH <= 0)); then
    return 1
  fi
  local now
  now=$(date +%s)
  if ((now - START_EPOCH >= DURATION_SECONDS)); then
    return 0
  fi
  return 1
}

sleep_controlled() {
  local seconds=$1
  local reason=$2
  local now remain end left
  if ((seconds <= 0)); then
    return 0
  fi
  remain=0
  now=$(date +%s)
  if ((DURATION_SECONDS > 0 && START_EPOCH > 0)); then
    remain=$((START_EPOCH + DURATION_SECONDS - now))
    if ((remain <= 0)); then
      return 2
    fi
    if ((remain < seconds)); then
      seconds=$remain
    fi
  fi
  log INFO "${reason}，大约 ${seconds} 秒后继续"
  end=$((now + seconds))
  while true; do
    if duration_exceeded; then
      return 2
    fi
    now=$(date +%s)
    if ((now >= end)); then
      return 0
    fi
    left=$((end - now))
    if ((DURATION_SECONDS > 0 && START_EPOCH > 0)); then
      remain=$((START_EPOCH + DURATION_SECONDS - now))
      if ((remain <= 0)); then
        return 2
      fi
      if ((remain < left)); then
        left=$remain
      fi
    fi
    if ((left > 15)); then
      sleep 15
    else
      sleep "$left"
    fi
  done
}

print_plan() {
  local bin="（尚未安装）"
  local resolved=""
  local quota_text="不限制"
  if resolved=$(resolve_speedtest_bin 2>/dev/null || true); then
    if [[ -n $resolved ]]; then
      bin=$resolved
    fi
  fi
  if ((QUOTA_BYTES > 0)); then
    quota_text=$(format_bytes "$QUOTA_BYTES")
  fi
  printf '引擎: Ookla 官方 Speedtest CLI\n'
  printf '客户端: %s\n' "$bin"
  printf '配额: %s（%s）\n' "$quota_text" "$(period_label "$QUOTA_PERIOD")"
  printf '时段: %s\n' "${SCHEDULE:-全天}"
  printf '最长运行: %s\n' "$(format_duration "$DURATION_SECONDS")"
  printf '下行上限: %s\n' "$(format_mbps "$MAX_DOWNLOAD_MBPS_NUM")"
  printf '上行上限: %s\n' "$(format_mbps "$MAX_UPLOAD_MBPS_NUM")"
  printf '间隔: %s 秒\n' "$INTERVAL"
  printf '服务器: %s\n' "${SERVER_ID:-自动选择}"
  printf '网卡: %s\n' "${INTERFACE:-默认}"
  if ((MAX_DOWNLOAD_BPS > 0 || MAX_UPLOAD_BPS > 0)); then
    if [[ ${EUID} -ne 0 ]]; then
      printf '限速: 需要 root，当前不会启动燃烧\n'
    elif [[ ${TRAFFIC_BURN_SHAPER:-auto} == nft ]] || ! tbf_supported; then
      printf '限速: nftables\n'
    else
      printf '限速: tc tbf\n'
    fi
  else
    printf '限速: 关闭\n'
  fi
}

acquire_lock() {
  local lock_dir
  lock_dir=$(dirname "$STATE_FILE")
  mkdir -p "$lock_dir"
  exec 9>"${lock_dir}/traffic-burn.lock"
  LOCK_HELD=1
  if ! flock -n 9; then
    die "已有一个燃烧进程在运行"
  fi
  PID_FILE="${lock_dir}/traffic-burn.pid"
  printf '%s\n' "$$" >"$PID_FILE"
}

release_lock() {
  if [[ -n ${PID_FILE-} && -f ${PID_FILE} ]]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ $pid == "$$" ]]; then
      rm -f "$PID_FILE"
    fi
  fi
  if [[ ${LOCK_HELD:-0} == 1 ]]; then
    exec 9>&- || true
    LOCK_HELD=0
  fi
}

on_exit() {
  local code=$?
  trap - EXIT INT TERM
  if [[ -n ${CHILD_PID:-} ]]; then
    kill -TERM "$CHILD_PID" >/dev/null 2>&1 || true
    wait "$CHILD_PID" >/dev/null 2>&1 || true
    CHILD_PID=""
  fi
  cleanup_shaper || true
  release_lock || true
  exit "$code"
}

on_signal() {
  log INFO "收到停止信号，正在结束本轮并清理限速规则"
  exit 130
}

cmd_run() {
  set_defaults
  parse_run_args "$@"
  if [[ -f $CONFIG_FILE ]]; then
    load_config_file "$CONFIG_FILE"
  elif ((CONFIG_EXPLICIT)); then
    die "找不到配置文件: ${CONFIG_FILE}"
  fi
  apply_cli_overrides
  validate_settings
  prepare_dirs
  if ((DRY_RUN)); then
    print_plan
    return 0
  fi
  if ((MAX_DOWNLOAD_BPS > 0 || MAX_UPLOAD_BPS > 0)); then
    require_root
  fi
  command -v python3 >/dev/null 2>&1 || die "需要 python3 来解析官方测速结果"
  if ! SPEEDTEST_BIN=$(resolve_speedtest_bin); then
    die "未找到 Ookla 官方 Speedtest。请先运行: $0 install"
  fi
  acquire_lock
  trap on_exit EXIT
  trap on_signal INT TERM
  START_EPOCH=$(date +%s)
  load_state
  if [[ $QUOTA_PERIOD == run ]]; then
    DOWN_BYTES=0
    UP_BYTES=0
    ROUNDS=0
    PERIOD_KEY="run"
    save_state
  fi
  setup_shaper
  build_speedtest_command
  log INFO "测速命令: ${SPEEDTEST_CMD[*]}"
  log INFO "Traffic-Burnig ${VERSION} 开始。引擎为 Ookla 官方 Speedtest CLI。运行表示接受 Ookla 许可协议、服务条款和隐私政策；测速结果会提交到 Speedtest.net"
  if [[ -n $SCHEDULE ]]; then
    log INFO "燃烧时段: ${SCHEDULE}"
  else
    log INFO "燃烧时段: 全天"
  fi
  if ((QUOTA_BYTES > 0)); then
    log INFO "流量配额: $(format_bytes "$QUOTA_BYTES") / $(period_label "$QUOTA_PERIOD")"
  else
    log INFO "流量配额: 不限制"
  fi
  while true; do
    if duration_exceeded; then
      log INFO "已达到最长运行时间 $(format_duration "$DURATION_SECONDS")，停止"
      break
    fi
    local epoch
    epoch=$(now_epoch)
    if ! schedule_active "$SCHEDULE" "$epoch"; then
      if ((ONCE)); then
        log INFO "当前不在允许的燃烧时段内，本次不测速"
        break
      fi
      local wait_for
      wait_for=$(seconds_until_schedule "$SCHEDULE" "$epoch")
      if ! sleep_controlled "$wait_for" "当前不在燃烧时段"; then
        log INFO "已达到最长运行时间 $(format_duration "$DURATION_SECONDS")，停止"
        break
      fi
      continue
    fi
    load_state
    if quota_reached; then
      if [[ $QUOTA_PERIOD == run || $ONCE == 1 ]]; then
        log INFO "已达到流量配额 $(format_bytes "$QUOTA_BYTES")，停止"
        break
      fi
      local wait_period
      wait_period=$(seconds_until_next_period)
      if ! sleep_controlled "$wait_period" "本周期配额已用完"; then
        log INFO "已达到最长运行时间 $(format_duration "$DURATION_SECONDS")，停止"
        break
      fi
      continue
    fi
    if run_one_round; then
      FAIL_STREAK=0
      if quota_reached && [[ $QUOTA_PERIOD == run ]]; then
        log INFO "已达到本次流量配额 $(format_bytes "$QUOTA_BYTES")，停止"
        break
      fi
      if ((ONCE)); then
        break
      fi
      if ! sleep_controlled "$INTERVAL" "等待下一轮"; then
        log INFO "已达到最长运行时间 $(format_duration "$DURATION_SECONDS")，停止"
        break
      fi
    else
      FAIL_STREAK=$((FAIL_STREAK + 1))
      if ((FAIL_STREAK >= MAX_CONSECUTIVE_FAILURES)); then
        die "连续失败 ${FAIL_STREAK} 次，停止"
      fi
      local backoff=$((FAIL_STREAK * 5))
      if ((backoff > 60)); then
        backoff=60
      fi
      if ((ONCE)); then
        die "测速失败"
      fi
      if ! sleep_controlled "$backoff" "本轮失败，稍后重试"; then
        log INFO "已达到最长运行时间 $(format_duration "$DURATION_SECONDS")，停止"
        break
      fi
    fi
  done
  finish_run
}

finish_run() {
  trap - EXIT INT TERM
  cleanup_shaper || true
  release_lock || true
}

require_value() {
  if [[ $# -lt 2 ]]; then
    die "参数 $1 需要一个值"
  fi
}

parse_run_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --config)
        require_value "$@"
        CONFIG_FILE=$2
        CONFIG_EXPLICIT=1
        shift 2
        ;;
      --quota)
        require_value "$@"
        CLI_QUOTA=$2
        CLI_QUOTA_SET=1
        shift 2
        ;;
      --quota-period)
        require_value "$@"
        CLI_PERIOD=$2
        CLI_PERIOD_SET=1
        shift 2
        ;;
      --schedule)
        require_value "$@"
        CLI_SCHEDULE=$2
        CLI_SCHEDULE_SET=1
        shift 2
        ;;
      --duration)
        require_value "$@"
        CLI_DURATION=$2
        CLI_DURATION_SET=1
        shift 2
        ;;
      --max-mbps)
        require_value "$@"
        CLI_MAX_DOWN=$2
        CLI_MAX_UP=$2
        CLI_MAX_DOWN_SET=1
        CLI_MAX_UP_SET=1
        shift 2
        ;;
      --max-download)
        require_value "$@"
        CLI_MAX_DOWN=$2
        CLI_MAX_DOWN_SET=1
        shift 2
        ;;
      --max-upload)
        require_value "$@"
        CLI_MAX_UP=$2
        CLI_MAX_UP_SET=1
        shift 2
        ;;
      --interval)
        require_value "$@"
        CLI_INTERVAL=$2
        CLI_INTERVAL_SET=1
        shift 2
        ;;
      --server-id)
        require_value "$@"
        CLI_SERVER=$2
        CLI_SERVER_SET=1
        shift 2
        ;;
      --interface)
        require_value "$@"
        CLI_INTERFACE=$2
        CLI_INTERFACE_SET=1
        shift 2
        ;;
      --speedtest-bin)
        require_value "$@"
        CLI_BIN=$2
        CLI_BIN_SET=1
        shift 2
        ;;
      --log-file)
        require_value "$@"
        CLI_LOG=$2
        CLI_LOG_SET=1
        shift 2
        ;;
      --state-file)
        require_value "$@"
        CLI_STATE=$2
        CLI_STATE_SET=1
        shift 2
        ;;
      --once)
        ONCE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 安装、服务、状态
# ---------------------------------------------------------------------------

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

render_systemd_unit() {
  local bin=$1
  local config=$2
  cat <<EOF
[Unit]
Description=Traffic-Burnig 流量燃烧器
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="${bin}" run --config "${config}"
Restart=on-failure
RestartSec=30
TimeoutStopSec=30
Nice=10

[Install]
WantedBy=multi-user.target
EOF
}

cmd_install() {
  set_defaults
  local skip_speedtest=0
  local resolved=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --prefix)
        require_value "$@"
        PREFIX=$2
        shift 2
        ;;
      --skip-speedtest)
        skip_speedtest=1
        shift
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
  if [[ ${TRAFFIC_BURN_SKIP_SPEEDTEST:-0} == 1 ]]; then
    skip_speedtest=1
  fi
  if [[ $PREFIX == /usr/local || $PREFIX == /usr ]]; then
    require_root
  fi
  ensure_commands curl tar sha256sum python3 ip tc nft iptables flock
  install_self_to "${PREFIX}/bin/traffic-burn"
  log INFO "脚本已安装到 ${PREFIX}/bin/traffic-burn"
  if ((skip_speedtest)); then
    log INFO "已跳过官方客户端安装"
    return 0
  fi
  if resolved=$(resolve_speedtest_bin 2>/dev/null || true) && [[ -n $resolved ]]; then
    log INFO "已存在官方客户端: ${resolved}"
    return 0
  fi
  install_official_speedtest
}

cmd_init_config() {
  set_defaults
  local output="" force=0 wizard=1
  while [[ $# -gt 0 ]]; do
    case $1 in
      --output)
        require_value "$@"
        output=$2
        wizard=0
        shift 2
        ;;
      --quota)
        require_value "$@"
        QUOTA=$2
        wizard=0
        shift 2
        ;;
      --quota-period)
        require_value "$@"
        QUOTA_PERIOD=$2
        wizard=0
        shift 2
        ;;
      --schedule)
        require_value "$@"
        SCHEDULE=$2
        wizard=0
        shift 2
        ;;
      --duration)
        require_value "$@"
        DURATION=$2
        wizard=0
        shift 2
        ;;
      --max-download)
        require_value "$@"
        MAX_DOWNLOAD_MBPS=$2
        wizard=0
        shift 2
        ;;
      --max-upload)
        require_value "$@"
        MAX_UPLOAD_MBPS=$2
        wizard=0
        shift 2
        ;;
      --max-mbps)
        require_value "$@"
        MAX_DOWNLOAD_MBPS=$2
        MAX_UPLOAD_MBPS=$2
        wizard=0
        shift 2
        ;;
      --interval)
        require_value "$@"
        INTERVAL=$2
        wizard=0
        shift 2
        ;;
      --server-id)
        require_value "$@"
        SERVER_ID=$2
        wizard=0
        shift 2
        ;;
      --interface)
        require_value "$@"
        INTERFACE=$2
        wizard=0
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      --yes)
        wizard=0
        shift
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
  if [[ -z $output ]]; then
    output=$CONFIG_FILE
  fi
  if ((wizard)); then
    if [[ ! -t 0 ]]; then
      die "没有交互终端。请传入 --quota、--schedule 等参数，或使用 --yes 写入默认配置"
    fi
    wizard_config
  fi
  validate_settings
  if [[ -e $output && $force == 0 ]]; then
    die "配置已存在: ${output}。确认覆盖请加 --force"
  fi
  write_config "$output"
  log INFO "配置已写入 ${output}"
}

prompt_value() {
  local text=$1
  local default=$2
  local answer
  if [[ -n $default ]]; then
    read -r -p "${text} [${default}]: " answer || true
    if [[ -z ${answer:-} ]]; then
      answer=$default
    fi
  else
    read -r -p "${text}: " answer || true
    answer=${answer:-}
  fi
  printf '%s' "$answer"
}

value_ok() {
  local check=$1
  shift
  "$check" "$@"
}

valid_quota_input() {
  local value
  value=$(trim "${1:-}")
  [[ -z $value || $value == 0 ]] && return 0
  parse_size_to_bytes "$value" >/dev/null
}

valid_period_input() {
  local value
  value=$(trim "${1:-}")
  case $value in
    1 | 2 | 3) return 0 ;;
  esac
  normalize_period "$value" >/dev/null
}

valid_duration_input() {
  parse_duration "${1:-0}" >/dev/null
}

valid_mbps_input() {
  parse_mbps "${1:-0}" >/dev/null
}

valid_interval_input() {
  [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1 <= 86400))
}

valid_server_input() {
  [[ -z ${1:-} || ${1} =~ ^[0-9]+$ ]]
}

valid_interface_input() {
  [[ -z ${1:-} || ${1} =~ ^[A-Za-z0-9._:-]+$ ]]
}

ask_until() {
  local text=$1
  local default=$2
  local check=$3
  local value
  while true; do
    value=$(prompt_value "$text" "$default")
    if value_ok "$check" "$value"; then
      printf '%s' "$value"
      return 0
    fi
    printf '输入无效，请按提示重试。\n' >&2
  done
}

wizard_config() {
  printf '\n按提示生成配置。直接回车表示使用括号中的默认值。\n'
  printf '配额和速度留空或填 0 表示不限制。时段留空表示全天。\n\n'
  QUOTA=$(ask_until "流量配额，例如 20GB" "0" valid_quota_input)
  local period_choice
  period_choice=$(ask_until "配额周期: 1) 本次  2) 每天  3) 每月" "2" valid_period_input)
  case $period_choice in
    1 | run | 本次) QUOTA_PERIOD=run ;;
    2 | daily | 每天) QUOTA_PERIOD=daily ;;
    3 | monthly | 每月) QUOTA_PERIOD=monthly ;;
    *) QUOTA_PERIOD=$period_choice ;;
  esac
  SCHEDULE=$(ask_until "燃烧时段，例如 01:00-07:00,22:00-23:30" "" validate_schedule)
  DURATION=$(ask_until "单次最长运行时间，例如 2h，0 表示不限制" "0" valid_duration_input)
  MAX_DOWNLOAD_MBPS=$(ask_until "最大下行 Mbps" "0" valid_mbps_input)
  MAX_UPLOAD_MBPS=$(ask_until "最大上行 Mbps" "0" valid_mbps_input)
  INTERVAL=$(ask_until "每轮间隔秒数" "5" valid_interval_input)
  SERVER_ID=$(ask_until "Ookla 服务器 ID，可留空" "" valid_server_input)
  INTERFACE=$(ask_until "绑定网卡，可留空" "" valid_interface_input)
}

cmd_status() {
  set_defaults
  if [[ -f $CONFIG_FILE ]]; then
    load_config_file "$CONFIG_FILE"
  fi
  validate_settings
  prepare_dirs
  load_state
  local bin="未安装"
  local resolved=""
  if resolved=$(resolve_speedtest_bin 2>/dev/null || true); then
    if [[ -n $resolved ]]; then
      bin=$("$resolved" --version 2>/dev/null | head -n 1 || true)
      bin="${bin} (${resolved})"
    fi
  fi
  printf 'Traffic-Burnig %s\n' "$VERSION"
  printf '官方客户端: %s\n' "$bin"
  printf '配置文件: %s\n' "$CONFIG_FILE"
  printf '时段: %s\n' "${SCHEDULE:-全天}"
  if schedule_active "$SCHEDULE" "$(now_epoch)"; then
    printf '当前: 在允许时段内\n'
  else
    printf '当前: 不在允许时段内\n'
  fi
  if ((QUOTA_BYTES > 0)); then
    local used=$((DOWN_BYTES + UP_BYTES))
    local left=0
    if ((used < QUOTA_BYTES)); then
      left=$((QUOTA_BYTES - used))
    fi
    printf '配额: %s / %s，已用 %s，剩余 %s\n' \
      "$(period_label "$QUOTA_PERIOD")" \
      "$(format_bytes "$QUOTA_BYTES")" \
      "$(format_bytes "$used")" \
      "$(format_bytes "$left")"
  else
    printf '配额: 不限制，本周期已用 %s\n' "$(format_bytes $((DOWN_BYTES + UP_BYTES)))"
  fi
  printf '限速: 下行 %s，上行 %s\n' "$(format_mbps "$MAX_DOWNLOAD_MBPS_NUM")" "$(format_mbps "$MAX_UPLOAD_MBPS_NUM")"
  printf '累计燃烧: %s，完成轮数计数（当前周期）: %s\n' "$(format_bytes "$LIFETIME_BYTES")" "$ROUNDS"
  if [[ -n $LAST_TIME ]]; then
    printf '最近一轮: %s，下行 %s，上行 %s，节点 %s\n' \
      "$LAST_TIME" "$(format_bytes "$LAST_DOWN_BYTES")" "$(format_bytes "$LAST_UP_BYTES")" "${LAST_SERVER:-未知}"
  fi
  if has_systemd; then
    local active enabled
    active=$(systemctl is-active traffic-burn 2>/dev/null || true)
    enabled=$(systemctl is-enabled traffic-burn 2>/dev/null || true)
    printf 'systemd: %s，开机启动: %s\n' "${active:-未安装}" "${enabled:-未安装}"
  fi
}

cmd_service() {
  local action=${1:-}
  shift || true
  case $action in
    install)
      require_root
      set_defaults
      if [[ ! -x ${PREFIX}/bin/traffic-burn ]]; then
        install_self_to "${PREFIX}/bin/traffic-burn"
      fi
      if [[ ! -f $CONFIG_FILE ]]; then
        die "还没有配置文件。请先运行: traffic-burn init-config"
      fi
      has_systemd || die "未检测到 systemd"
      render_systemd_unit "${PREFIX}/bin/traffic-burn" "$CONFIG_FILE" >/etc/systemd/system/traffic-burn.service
      systemctl daemon-reload
      systemctl enable traffic-burn
      log INFO "systemd 服务已安装。启动: traffic-burn service start"
      ;;
    start)
      require_root
      has_systemd || die "未检测到 systemd"
      systemctl start traffic-burn
      systemctl --no-pager --full status traffic-burn || true
      ;;
    stop)
      require_root
      has_systemd || die "未检测到 systemd"
      systemctl stop traffic-burn || true
      log INFO "服务已停止"
      ;;
    restart)
      require_root
      has_systemd || die "未检测到 systemd"
      systemctl restart traffic-burn
      ;;
    status)
      has_systemd || die "未检测到 systemd"
      systemctl --no-pager --full status traffic-burn
      ;;
    uninstall)
      require_root
      if has_systemd; then
        systemctl disable --now traffic-burn >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/traffic-burn.service
        systemctl daemon-reload
      fi
      log INFO "systemd 服务已移除"
      ;;
    *)
      die "用法: $0 service install|start|stop|restart|status|uninstall"
      ;;
  esac
}

cmd_stop() {
  set_defaults
  if [[ -f $CONFIG_FILE ]]; then
    load_config_file "$CONFIG_FILE" || true
  fi
  local stopped=0
  if has_systemd && systemctl is-active --quiet traffic-burn 2>/dev/null; then
    require_root
    systemctl stop traffic-burn
    stopped=1
  fi
  local pid_file
  pid_file="$(dirname "$STATE_FILE")/traffic-burn.pid"
  if [[ -f $pid_file ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      stopped=1
    fi
  fi
  if ((stopped)); then
    log INFO "已发送停止信号"
  else
    log INFO "没有正在运行的燃烧进程"
  fi
}

cmd_servers() {
  set_defaults
  if [[ -f $CONFIG_FILE ]]; then
    load_config_file "$CONFIG_FILE" || true
  fi
  if ! SPEEDTEST_BIN=$(resolve_speedtest_bin); then
    die "未找到官方客户端。请先运行: $0 install"
  fi
  "$SPEEDTEST_BIN" --accept-license --accept-gdpr -L "$@"
}

cmd_uninstall() {
  local purge=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --purge) purge=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  require_root
  set_defaults
  cmd_service uninstall || true
  if [[ -f $(dirname "$STATE_FILE")/managed-speedtest ]]; then
    local managed
    managed=$(cat "$(dirname "$STATE_FILE")/managed-speedtest")
    if [[ -n $managed && -f $managed ]]; then
      rm -f "$managed"
      log INFO "已删除官方客户端 ${managed}"
    fi
    rm -f "$(dirname "$STATE_FILE")/managed-speedtest"
  fi
  rm -f /usr/local/bin/traffic-burn
  if ((purge)); then
    rm -f "$CONFIG_FILE" "$STATE_FILE" "$LOG_FILE" "${LOG_FILE}.1"
    rm -rf "$(dirname "$STATE_FILE")"
    log INFO "已删除配置、状态和日志"
  else
    log INFO "配置、状态和日志仍保留。彻底删除请加 --purge"
  fi
}

cmd_version() {
  printf 'traffic-burn %s\n' "$VERSION"
  printf 'Ookla Speedtest CLI 安装包版本 %s\n' "$OOKLA_VERSION"
}

usage() {
  cat <<EOF
Traffic-Burnig ${VERSION}
使用 Ookla 官方 Speedtest CLI 消耗本机流量，支持定时、定量和最大速度。

用法:
  $0                         交互菜单
  $0 install                 安装官方客户端和 traffic-burn 命令
  $0 init-config [选项]      写入定时、定量、限速配置
  $0 run [选项]              按配置燃烧
  $0 status                  查看配额和累计流量
  $0 stop                    停止前台进程或 systemd 服务
  $0 servers                 列出附近的官方测速节点
  $0 service install|start|stop|restart|status|uninstall
  $0 uninstall [--purge]     卸载

run / init-config 常用选项:
  --quota 20GB               定量。支持 MB/GB/TB 与 MiB/GiB，0 为不限制
  --quota-period daily       run、daily 或 monthly
  --schedule 01:00-07:00     定时。逗号分隔，支持 22:00-02:00 这种跨夜时段
  --duration 2h              单次最长运行时间
  --max-download 30          最大下行 Mbps
  --max-upload 10            最大上行 Mbps
  --max-mbps 20              同时限制上行和下行
  --interval 10              两轮之间的间隔秒数
  --server-id 12345          指定 Ookla 节点
  --once                     只测一轮
  --dry-run                  只打印计划，不产生流量

示例:
  $0 init-config --quota 20GB --quota-period daily --schedule 01:00-07:00 \\
      --max-download 30 --max-upload 10 --force
  $0 service install && $0 service start

官方客户端没有自带限速。本脚本在内核支持时用 tc tbf 整形；
否则用 nftables 限制测速进程的数据包。设定了上限却无法限速时，会直接停止。
EOF
}

interactive_menu() {
  set_defaults
  while true; do
    printf '\n============================================\n'
    printf '  Traffic-Burnig 流量燃烧器 %s\n' "$VERSION"
    printf '  引擎: Ookla 官方 Speedtest CLI\n'
    printf '============================================\n'
    printf '  1) 安装官方 Speedtest 和本脚本\n'
    printf '  2) 写入配置（定时 / 定量 / 限速）\n'
    printf '  3) 按配置前台燃烧\n'
    printf '  4) 安装并启动 systemd 服务\n'
    printf '  5) 查看状态\n'
    printf '  6) 停止燃烧\n'
    printf '  7) 列出测速节点\n'
    printf '  8) 卸载\n'
    printf '  0) 退出\n'
    printf '============================================\n'
    local choice
    read -r -p "请选择: " choice || exit 0
    case $choice in
      1) (cmd_install) || true ;;
      2) (cmd_init_config --force) || true ;;
      3)
        if [[ ! -f $CONFIG_FILE ]]; then
          local confirm
          read -r -p "还没有配置，将不限制时段、配额和速度。继续吗 [y/N]: " confirm || true
          if [[ ${confirm:-} != [yY] && ${confirm:-} != [yY][eE][sS] ]]; then
            continue
          fi
        fi
        cmd_run
        ;;
      4)
        (cmd_service install) || true
        (cmd_service start) || true
        ;;
      5) (cmd_status) || true ;;
      6) (cmd_stop) || true ;;
      7) (cmd_servers) || true ;;
      8) (cmd_uninstall) || true ;;
      0 | q) exit 0 ;;
      *) printf '无效选项\n' ;;
    esac
  done
}

main() {
  local cmd=${1:-}
  if [[ -z $cmd ]]; then
    if [[ -t 0 && -t 1 ]]; then
      interactive_menu
    else
      usage
      exit 2
    fi
    return 0
  fi
  shift
  case $cmd in
    run) cmd_run "$@" ;;
    install) cmd_install "$@" ;;
    init-config) cmd_init_config "$@" ;;
    status) cmd_status "$@" ;;
    stop) cmd_stop "$@" ;;
    servers) cmd_servers "$@" ;;
    service) cmd_service "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    version | -V | --version) cmd_version ;;
    help | -h | --help) usage ;;
    *)
      die "未知命令: ${cmd}。运行 $0 help 查看用法"
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
