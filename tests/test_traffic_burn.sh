#!/usr/bin/env bash
# shellcheck shell=bash
# 这些变量由被测脚本的函数读写，shellcheck 看不到跨文件的运行时赋值。
# shellcheck disable=SC2034,SC2153
set -euo pipefail

ROOT=$(readlink -f "$(dirname "$0")/..")
# shellcheck disable=SC1091
source "$ROOT/traffic-burning.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local got=$1
  local want=$2
  local label=$3
  if [[ $got != "$want" ]]; then
    fail "${label}: 得到 [${got}]，期望 [${want}]"
  fi
}

assert_ok() {
  local label=$1
  shift
  if ! "$@"; then
    fail "${label}"
  fi
}

assert_fail() {
  local label=$1
  shift
  if "$@"; then
    fail "${label}：应当失败"
  fi
}

unit_tests() {
  assert_eq "$(parse_size_to_bytes 10GB)" 10000000000 "10GB"
  assert_eq "$(parse_size_to_bytes 1.5MB)" 1500000 "1.5MB"
  assert_eq "$(parse_size_to_bytes 2GiB)" 2147483648 "2GiB"
  assert_eq "$(parse_size_to_bytes 0)" 0 "zero bytes"
  assert_eq "$(parse_size_to_bytes "")" 0 "empty bytes"
  assert_fail "bad size" parse_size_to_bytes '10GB;touch'

  assert_eq "$(parse_duration 90m)" 5400 "90m"
  assert_eq "$(parse_duration 2h)" 7200 "2h"
  assert_eq "$(parse_duration 1d)" 86400 "1d"
  assert_eq "$(parse_duration 30)" 30 "30s"
  assert_eq "$(parse_duration 0)" 0 "0 duration"

  assert_eq "$(awk -v m="$(parse_mbps 50Mbps)" 'BEGIN { printf "%.0f", m }')" 50 "50Mbps"
  assert_eq "$(awk -v m="$(parse_mbps 1Gbps)" 'BEGIN { printf "%.0f", m }')" 1000 "1Gbps"
  assert_eq "$(awk -v m="$(parse_mbps 500Kbps)" 'BEGIN { printf "%.3f", m }')" 0.500 "500Kbps"
  assert_eq "$(mbps_to_bps 8)" 1000000 "8 Mbps in bytes"

  assert_eq "$(normalize_period daily)" daily "period daily"
  assert_eq "$(normalize_period 每月)" monthly "period monthly"
  assert_fail "bad period" normalize_period weekly

  assert_ok "empty schedule" validate_schedule ""
  assert_ok "normal schedule" validate_schedule "01:00-07:00, 22:00-23:30"
  assert_ok "overnight schedule" validate_schedule "22:00-02:00"
  assert_fail "equal window" validate_schedule "05:00-05:00"
  assert_fail "bad hour" validate_schedule "25:00-26:00"
  assert_fail "comma only" validate_schedule ","

  local epoch
  TZ=UTC
  export TZ
  epoch=$(date -d '2026-09-22 23:30:00' +%s)
  assert_ok "overnight active" schedule_active "22:00-02:00" "$epoch"
  epoch=$(date -d '2026-09-22 01:15:00' +%s)
  assert_ok "after midnight active" schedule_active "22:00-02:00" "$epoch"
  epoch=$(date -d '2026-09-22 12:00:00' +%s)
  assert_fail "midday inactive" schedule_active "22:00-02:00" "$epoch"
  epoch=$(date -d '2026-09-22 06:00:00' +%s)
  assert_fail "window end is exclusive" schedule_active "01:00-06:00" "$epoch"
  epoch=$(date -d '2026-09-22 21:30:00' +%s)
  assert_eq "$(seconds_until_schedule "22:00-06:00" "$epoch")" 1800 "seconds until window"
  assert_eq "$(seconds_until_schedule "" "$epoch")" 0 "empty schedule wait"

  assert_eq "$(ookla_arch_from x86_64)" x86_64 "arch amd64"
  assert_eq "$(ookla_arch_from aarch64)" aarch64 "arch arm64"
  assert_eq "$(ookla_arch_from armv7l)" armhf "arch armhf"
  assert_eq "$(ookla_sha256 x86_64)" "5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7" "sha"

  local tmp state_file
  tmp=$(mktemp -d)
  state_file="${tmp}/state"
  set_defaults
  TRAFFIC_BURN_TEST_MODE=1
  TRAFFIC_BURN_NOW_EPOCH=$(TZ=UTC date -d '2026-09-22 12:00:00' +%s)
  QUOTA_PERIOD=daily
  STATE_FILE=$state_file
  DOWN_BYTES=100
  UP_BYTES=40
  LIFETIME_BYTES=140
  ROUNDS=2
  PERIOD_KEY=$(current_period_key)
  LAST_SERVER="Tokyo"
  save_state
  DOWN_BYTES=0
  UP_BYTES=0
  ROUNDS=0
  load_state
  assert_eq "$DOWN_BYTES" 100 "state kept"
  assert_eq "$UP_BYTES" 40 "state up kept"
  assert_eq "$LIFETIME_BYTES" 140 "lifetime kept"
  TRAFFIC_BURN_NOW_EPOCH=$(TZ=UTC date -d '2026-09-23 00:10:00' +%s)
  load_state
  assert_eq "$DOWN_BYTES" 0 "next day reset"
  assert_eq "$LIFETIME_BYTES" 140 "lifetime survives rollover"
  assert_eq "$PERIOD_KEY" "2026-09-23" "period key"
  rm -rf "$tmp"
  unset TRAFFIC_BURN_NOW_EPOCH

  local cfg marker
  tmp=$(mktemp -d)
  cfg="${tmp}/bad.conf"
  marker="${tmp}/pwned"
  printf 'QUOTA=%s\n' "\$(touch ${marker})" >"$cfg"
  set_defaults
  if (load_config_file "$cfg" && validate_settings); then
    fail "恶意配置应当被拒绝"
  fi
  if [[ -e $marker ]]; then
    fail "配置值被当成命令执行了"
  fi
  printf 'UNKNOWN=1\n' >"$cfg"
  if (set_defaults && load_config_file "$cfg"); then
    fail "未知配置项应当被拒绝"
  fi
  rm -rf "$tmp"

  set_defaults
  load_config_file "$ROOT/traffic-burn.conf.example"
  validate_settings
  assert_eq "$QUOTA_BYTES" 20000000000 "example quota"
  assert_eq "$QUOTA_PERIOD" daily "example period"
  assert_eq "$MAX_DOWNLOAD_BPS" 3750000 "example down bps"
  assert_eq "$SCHEDULE" "01:00-07:00" "example schedule"

  tmp=$(mktemp -d)
  set_defaults
  QUOTA=20GB
  QUOTA_PERIOD=daily
  SCHEDULE="01:00-07:00"
  DURATION=2h
  MAX_DOWNLOAD_MBPS=30
  MAX_UPLOAD_MBPS=10
  INTERVAL=8
  SERVER_ID=""
  INTERFACE=eth0
  validate_settings
  write_config "${tmp}/out.conf"
  set_defaults
  load_config_file "${tmp}/out.conf"
  validate_settings
  assert_eq "$QUOTA_BYTES" 20000000000 "roundtrip quota"
  assert_eq "$DURATION_SECONDS" 7200 "roundtrip duration"
  assert_eq "$INTERFACE" eth0 "roundtrip interface"
  rm -rf "$tmp"

  tmp=$(mktemp -d)
  set_defaults
  wizard_config <<EOF
nope
20GB
2
01:00-07:00
2h
30
10
8

eth0
EOF
  assert_eq "$QUOTA" 20GB "wizard quota"
  assert_eq "$QUOTA_PERIOD" daily "wizard period"
  assert_eq "$SCHEDULE" "01:00-07:00" "wizard schedule"
  assert_eq "$DURATION" 2h "wizard duration"
  assert_eq "$MAX_DOWNLOAD_MBPS" 30 "wizard down"
  assert_eq "$MAX_UPLOAD_MBPS" 10 "wizard up"
  assert_eq "$INTERVAL" 8 "wizard interval"
  assert_eq "$INTERFACE" eth0 "wizard interface"
  rm -rf "$tmp"

  printf 'unit tests ok\n'
}

mock_tests() {
  local tmp mock log state cfg home
  tmp=$(mktemp -d)
  mock="${tmp}/mock-speedtest"
  log="${tmp}/mock.log"
  state="${tmp}/state"
  cfg="${tmp}/empty.conf"
  home="${tmp}/home"
  : >"$cfg"
  mkdir -p "$home"
  cat >"$mock" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >> "$log"
cat <<'JSON'
{"download":{"bytes":1500,"bandwidth":1000},"upload":{"bytes":600,"bandwidth":400},"server":{"id":9,"name":"Mock","location":"Lab","country":"XX"},"result":{"url":"https://example.test/result"}}
JSON
EOF
  chmod +x "$mock"

  TRAFFIC_BURN_TEST_MODE=1 \
    "$ROOT/traffic-burning.sh" run \
    --config "$cfg" \
    --speedtest-bin "$mock" \
    --quota 2000 \
    --quota-period run \
    --interval 0 \
    --log-file "${tmp}/run.log" \
    --state-file "$state" >"${tmp}/out.txt"
  assert_eq "$(wc -l <"$log" | tr -d ' ')" 1 "quota stops after one round"
  grep -q -- '--accept-license' "${tmp}/run.log"
  grep -q -- '--accept-gdpr' "${tmp}/run.log"
  grep -q -- '--format=json' "${tmp}/run.log"
  python3 - "$state" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["down_bytes"] == 1500, data
assert data["up_bytes"] == 600, data
assert data["rounds"] == 1, data
assert data["lifetime_bytes"] == 2100, data
PY

  : >"$log"
  TRAFFIC_BURN_TEST_MODE=1 \
    "$ROOT/traffic-burning.sh" run \
    --config "$cfg" \
    --speedtest-bin "$mock" \
    --quota 5000 \
    --quota-period run \
    --interval 0 \
    --log-file "${tmp}/run2.log" \
    --state-file "${tmp}/state2" >"${tmp}/out2.txt"
  assert_eq "$(wc -l <"$log" | tr -d ' ')" 3 "quota allows three rounds"

  local hour sched start end
  hour=$(((10#$(date +%H) + 3) % 24))
  printf -v sched '%02d:00-%02d:01' "$hour" "$hour"
  : >"$log"
  start=$(date +%s)
  TRAFFIC_BURN_TEST_MODE=1 \
    "$ROOT/traffic-burning.sh" run \
    --config "$cfg" \
    --speedtest-bin "$mock" \
    --schedule "$sched" \
    --duration 3 \
    --interval 0 \
    --log-file "${tmp}/sched.log" \
    --state-file "${tmp}/state3" >"${tmp}/out3.txt"
  end=$(date +%s)
  assert_eq "$(wc -l <"$log" | tr -d ' ')" 0 "outside schedule does not test"
  if ((end - start > 8)); then
    fail "时段外等待没有遵守最长运行时间"
  fi

  cat >"$mock" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >> "$log"
exit 1
EOF
  : >"$log"
  if TRAFFIC_BURN_TEST_MODE=1 \
    "$ROOT/traffic-burning.sh" run \
    --config "$cfg" \
    --speedtest-bin "$mock" \
    --once \
    --interval 0 \
    --log-file "${tmp}/fail.log" \
    --state-file "${tmp}/state4" >"${tmp}/out4.txt" 2>"${tmp}/err4.txt"; then
    fail "测速失败应当返回非零"
  fi

  if TRAFFIC_BURN_TEST_MODE=1 \
    "$ROOT/traffic-burning.sh" run \
    --config "$cfg" \
    --speedtest-bin "$mock" \
    --max-download 5 \
    --quota 100 \
    --interval 0 \
    --log-file "${tmp}/noroot.log" \
    --state-file "${tmp}/state5" >"${tmp}/out5.txt" 2>"${tmp}/err5.txt"; then
    fail "非 root 设置了限速却仍然启动了"
  fi
  grep -q 'root' "${tmp}/err5.txt"
  assert_eq "$(wc -l <"$log" | tr -d ' ')" 1 "failed once still invoked mock before root check? no"
  # The failure mock was replaced and the root check happens before launch.
  # The previous once-test already wrote one line. Re-count only this attempt:
  # log was truncated before the once-test, then the root test must not append.
  # Re-run the assertion against a fresh log.
  : >"$log"
  if TRAFFIC_BURN_TEST_MODE=1 \
    "$ROOT/traffic-burning.sh" run \
    --config "$cfg" \
    --speedtest-bin "$mock" \
    --max-download 5 \
    --interval 0 \
    --log-file "${tmp}/noroot2.log" \
    --state-file "${tmp}/state6" >"${tmp}/out6.txt" 2>"${tmp}/err6.txt"; then
    fail "限速缺少 root 时应当退出"
  fi
  assert_eq "$(wc -l <"$log" | tr -d ' ')" 0 "限速失败前不能调用测速"

  "$ROOT/traffic-burning.sh" run --dry-run \
    --config "$cfg" \
    --quota 10GB \
    --quota-period daily \
    --schedule 01:00-07:00 \
    --max-download 30 \
    --max-upload 5 >"${tmp}/dry.txt"
  grep -q '10.00 GB' "${tmp}/dry.txt"
  grep -q '01:00-07:00' "${tmp}/dry.txt"
  if [[ $EUID -ne 0 ]]; then
    grep -q '需要 root' "${tmp}/dry.txt"
  fi

  "$ROOT/traffic-burning.sh" help >/dev/null
  "$ROOT/traffic-burning.sh" version | grep -q '2.0.0'
  if "$ROOT/traffic-burning.sh" </dev/null >"${tmp}/noargs.txt" 2>&1; then
    fail "没有参数且不是终端时应当退出 2"
  fi

  "$ROOT/traffic-burning.sh" install --prefix "${tmp}/prefix" --skip-speedtest >"${tmp}/install.log"
  [[ -x ${tmp}/prefix/bin/traffic-burn ]]
  TRAFFIC_BURN_SOURCE_URL="file://${ROOT}/traffic-burning.sh" \
    bash <(cat "$ROOT/traffic-burning.sh") install --prefix "${tmp}/prefix2" --skip-speedtest >"${tmp}/install2.log"
  [[ -x ${tmp}/prefix2/bin/traffic-burn ]]
  grep -q 'Ookla 官方 Speedtest' "${tmp}/prefix2/bin/traffic-burn"

  HOME=$home XDG_CONFIG_HOME="${home}/.config" XDG_STATE_HOME="${home}/.local/state" \
    "$ROOT/traffic-burning.sh" init-config --yes --output "${home}/traffic-burn.conf" >"${tmp}/init.log"
  [[ -f ${home}/traffic-burn.conf ]]

  rm -rf "$tmp"
  printf 'mock tests ok\n'
}

shaper_tests() {
  if [[ $EUID -ne 0 ]]; then
    fail "限速测试需要 root"
  fi
  fuser -k 18767/tcp 18768/tcp >/dev/null 2>&1 || true
  local tmp_shaper
  tmp_shaper=$(mktemp -d)
  set_defaults
  MAX_DOWNLOAD_MBPS=8
  MAX_UPLOAD_MBPS=0
  validate_settings
  TRAFFIC_BURN_SHAPER=nft
  setup_shaper
  python3 - >"$tmp_shaper/http.port" 2>"$tmp_shaper/http.err" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        size = 4_000_000
        payload = b"x" * size
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except BrokenPipeError:
            return
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        remaining = length
        while remaining:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_args):
        return
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
  local server_pid=$!
  local port=""
  local _
  for _ in $(seq 1 50); do
    if [[ -s $tmp_shaper/http.port ]]; then
      port=$(cat "$tmp_shaper/http.port")
      break
    fi
    sleep 0.05
  done
  [[ $port =~ ^[0-9]+$ ]] || fail "限速测试服务没有启动: $(cat "$tmp_shaper/http.err" 2>/dev/null || true)"
  cleanup_all() {
    cleanup_shaper || true
    if [[ -n ${server_pid:-} ]]; then
      kill "$server_pid" >/dev/null 2>&1 || true
      wait "$server_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n ${ns_server:-} ]]; then
      kill "$ns_server" >/dev/null 2>&1 || true
      wait "$ns_server" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_all EXIT
  sleep 0.2
  local client="${tmp_shaper}/download.py"
  mkdir -p "$tmp_shaper"
  cat >"$client" <<PY
import time, urllib.request
started = time.perf_counter()
data = urllib.request.urlopen("http://127.0.0.1:${port}/", timeout=30).read()
elapsed = time.perf_counter() - started
print(f"{len(data)} {elapsed:.3f}")
PY

  local result
  result=$(launch_limited python3 "$client")
  local got elapsed
  got=${result%% *}
  elapsed=${result##* }
  assert_eq "$got" 4000000 "shaped download size"
  python3 - "$elapsed" <<'PY'
import sys
elapsed = float(sys.argv[1])
if not 2.8 <= elapsed <= 7.0:
    raise SystemExit(f"8 Mbps 限速下 4MB 用了 {elapsed:.2f}s，不在 2.8-7 秒内")
print(f"download shaped in {elapsed:.2f}s")
PY

  cleanup_shaper
  MAX_DOWNLOAD_MBPS=8
  MAX_UPLOAD_MBPS="0.05"
  validate_settings
  TRAFFIC_BURN_SHAPER=nft
  setup_shaper
  cat >"$client" <<PY
import time, urllib.request
started = time.perf_counter()
data = urllib.request.urlopen("http://127.0.0.1:${port}/", timeout=30).read()
elapsed = time.perf_counter() - started
print(f"{len(data)} {elapsed:.3f}")
PY
  result=$(launch_limited python3 "$client")
  elapsed=${result##* }
  python3 - "$elapsed" <<'PY'
import sys
elapsed = float(sys.argv[1])
if elapsed > 8:
    raise SystemExit(f"上行限得很低时，下行仍被 ACK 拖慢了: {elapsed:.2f}s")
print(f"ack bypass kept download at {elapsed:.2f}s")
PY

  cleanup_shaper
  MAX_DOWNLOAD_MBPS=0
  MAX_UPLOAD_MBPS=4
  validate_settings
  setup_shaper
  cat >"$client" <<PY
import time, urllib.request
payload = b"y" * 2000000
started = time.perf_counter()
request = urllib.request.Request("http://127.0.0.1:${port}/", data=payload, method="POST")
urllib.request.urlopen(request, timeout=30).read()
elapsed = time.perf_counter() - started
print(f"{len(payload)} {elapsed:.3f}")
PY
  result=$(launch_limited python3 "$client")
  elapsed=${result##* }
  python3 - "$elapsed" <<'PY'
import sys
elapsed = float(sys.argv[1])
if not 3.2 <= elapsed <= 7.0:
    raise SystemExit(f"4 Mbps 上行限速下 2MB 用了 {elapsed:.2f}s，不在 3.2-7 秒内")
print(f"upload shaped in {elapsed:.2f}s")
PY

  cleanup_shaper
  if nft list table inet traffic_burn >/dev/null 2>&1; then
    fail "清理后 nft 表还在"
  fi
  if [[ -d /sys/fs/cgroup/traffic-burn ]]; then
    fail "清理后 cgroup 还在"
  fi

  set_defaults
  setup_tbf_network
  python3 - "$HOST_IP" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
host = sys.argv[1]
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"pong"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_args):
        return
ThreadingHTTPServer((host, 18768), Handler).serve_forever()
PY
  local ns_server=$!
  sleep 0.2
  local ns_out
  ns_out=$(ip netns exec "$NS_NAME" python3 -c 'import urllib.request; print(urllib.request.urlopen("http://'"$HOST_IP"':18768/", timeout=5).read().decode())')
  assert_eq "$ns_out" pong "netns can reach host veth"
  local ns_name=$NS_NAME
  cleanup_tbf
  if ip netns list | grep -q "$ns_name"; then
    fail "网络命名空间没有删除"
  fi
  if iptables -t nat -S | grep -q "traffic-burn-${ns_name}"; then
    fail "NAT 规则没有删除"
  fi
  kill "$ns_server" >/dev/null 2>&1 || true
  wait "$ns_server" >/dev/null 2>&1 || true
  ns_server=""
  trap - EXIT
  printf 'shaper tests ok\n'
}

main() {
  if [[ ${1:-} == --shaper ]]; then
    shaper_tests
    return 0
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$ROOT/traffic-burning.sh" "$ROOT/tests/test_traffic_burn.sh"
    printf 'shellcheck ok\n'
  fi
  unit_tests
  mock_tests
  if [[ $EUID -eq 0 ]]; then
    shaper_tests
  elif sudo -n true >/dev/null 2>&1; then
    sudo bash "$ROOT/tests/test_traffic_burn.sh" --shaper
  else
    printf 'skip shaper tests: no root\n'
  fi
}

main "$@"
