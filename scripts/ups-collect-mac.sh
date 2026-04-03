#!/bin/zsh
# ups-collect-mac.sh
# UPS メトリクス + 監視ホストメトリクス収集・InfluxDB Cloud 送信（macOS版）
# シークレットは /etc/ups-collect.env から環境変数として注入される
#
# 必要なツール:
#   - curl        : InfluxDB への HTTP POST（macOS 標準）
#   - jq          : JSON パース（macOS 標準外）
#                   brew install jq
#   - upsc (NUT)  : UPS データ取得（COLLECT_UPS=true の場合）
#                   https://networkupstools.org/
#   - macmon      : CPU温度取得（Apple Silicon のみ・任意）
#                   brew install macmon
#                   未インストールの場合は CPU温度フィールドをスキップ
#   - osx-cpu-temp: CPU温度取得（Intel Mac のみ・任意）
#                   brew install osx-cpu-temp
#                   未インストールの場合は CPU温度フィールドをスキップ

# チップ種別判別（arm64 = Apple Silicon、x86_64 = Intel）
CHIP_ARCH=$(uname -m)

# 環境変数ファイルをロード
ENV_FILE="/etc/ups-collect.env"
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# ─── 設定（環境変数が未セットなら即終了） ────────────────
: "${INFLUX_URL:?INFLUX_URL is not set}"
: "${INFLUX_TOKEN:?INFLUX_TOKEN is not set}"
: "${INFLUX_ORG:?INFLUX_ORG is not set}"
: "${INFLUX_BUCKET:?INFLUX_BUCKET is not set}"
COLLECT_UPS="${COLLECT_UPS:-true}"
if [[ "$COLLECT_UPS" == "true" ]]; then
  : "${UPS_HOST:?UPS_HOST is not set}"
fi
: "${HOST_NAME:?HOST_NAME is not set}"
: "${HOST_ROLE:?HOST_ROLE is not set}"
# ─────────────────────────────────────────────────────────

# タイムスタンプ（全ラインで共通）
# macOS の date は %N（ナノ秒）非対応のため、秒をナノ秒に変換
TIMESTAMP="$(date +%s)000000000"

influx_post() {
  local label="$1"
  local data="$2"
  local http_status
  http_status=$(curl -s -m 10 -o /tmp/influx_${label}_response.txt -w "%{http_code}" \
    --request POST \
    "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=ns" \
    --header "Authorization: Token ${INFLUX_TOKEN}" \
    --header "Content-Type: text/plain; charset=utf-8" \
    --data-raw "${data}")
  if [[ "$http_status" != "204" ]]; then
    echo "ERROR: [${label}] InfluxDB returned ${http_status}" >&2
    cat /tmp/influx_${label}_response.txt >&2
    return 1
  fi
}

# ═══════════════════════════════════════════════════════
# UPS メトリクス
# ═══════════════════════════════════════════════════════

if [[ "$COLLECT_UPS" == "true" ]]; then

  # UPS データ取得
  UPS_DATA=$(upsc "${UPS_HOST}" 2>/dev/null)
  if [[ -z "$UPS_DATA" ]]; then
    echo "ERROR: upsc failed" >&2
    exit 1
  fi

  # 各値を抽出
  get_val() { echo "$UPS_DATA" | grep "^${1}:" | awk '{print $2}'; }

  BATTERY_CHARGE=$(get_val "battery.charge")
  BATTERY_RUNTIME=$(get_val "battery.runtime")
  BATTERY_VOLTAGE=$(get_val "battery.voltage")
  INPUT_VOLTAGE=$(get_val "input.voltage")
  OUTPUT_VOLTAGE=$(get_val "output.voltage")
  UPS_LOAD=$(get_val "ups.load")
  UPS_STATUS=$(get_val "ups.status")

  # 必須フィールドが取得できなければ終了
  if [[ -z "$BATTERY_CHARGE" ]] || [[ -z "$UPS_STATUS" ]]; then
    echo "ERROR: required fields missing" >&2
    exit 1
  fi

  # デフォルト値（取得できなかったフィールドの補完）
  BATTERY_RUNTIME=${BATTERY_RUNTIME:-0}
  BATTERY_VOLTAGE=${BATTERY_VOLTAGE:-0}
  INPUT_VOLTAGE=${INPUT_VOLTAGE:-0}
  OUTPUT_VOLTAGE=${OUTPUT_VOLTAGE:-0}
  UPS_LOAD=${UPS_LOAD:-0}

  # Line Protocol 構築
  # ups_status はタグ（文字列・カーディナリティ低）、数値はフィールド
  LINE_UPS="ups_metrics,host=${HOST_NAME},ups_status=${UPS_STATUS} \
battery_charge=${BATTERY_CHARGE},\
battery_runtime=${BATTERY_RUNTIME}i,\
battery_voltage=${BATTERY_VOLTAGE},\
input_voltage=${INPUT_VOLTAGE},\
output_voltage=${OUTPUT_VOLTAGE},\
ups_load=${UPS_LOAD} \
${TIMESTAMP}"

  # InfluxDB Cloud に送信
  influx_post "ups" "${LINE_UPS}" || exit 1

fi

# ═══════════════════════════════════════════════════════
# ホストメトリクス
# ═══════════════════════════════════════════════════════

# CPU温度
# Apple Silicon: macmon を使用（sudo不要）
# Intel:         osx-cpu-temp を使用
# どちらも未インストールの場合は CPU温度フィールドをスキップ
CPU_TEMP=""
if [[ "$CHIP_ARCH" == "arm64" ]]; then
  # Apple Silicon (M1/M2/M3/M4)
  # macmon pipe --samples 1 出力例: {"temp":{"cpu_temp_avg":42.5,...},...}
  if command -v macmon &>/dev/null && command -v jq &>/dev/null; then
    CPU_TEMP=$(macmon pipe --samples 1 2>/dev/null | jq -r '.temp.cpu_temp_avg' 2>/dev/null)
  fi
else
  # Intel Mac
  # osx-cpu-temp 出力例: "42.4°C"
  if command -v osx-cpu-temp &>/dev/null; then
    CPU_TEMP=$(osx-cpu-temp 2>/dev/null | sed 's/°C//' | tr -d ' ')
  fi
fi

# ロードアベレージ（1分・5分）
# sysctl -n vm.loadavg 出力例: "{ 0.52 0.46 0.38 }"
LOAD_RAW=$(sysctl -n vm.loadavg)
LOAD_1M=$(echo "$LOAD_RAW" | awk '{print $2}')
LOAD_5M=$(echo "$LOAD_RAW" | awk '{print $3}')

# メモリ使用率（%）
# active + wired ページ数を全体メモリで割って算出
PAGE_SIZE=$(sysctl -n hw.pagesize)
MEM_TOTAL=$(sysctl -n hw.memsize)
PAGES_ACTIVE=$(vm_stat | awk '/Pages active:/ {gsub(/\./, "", $3); print $3}')
PAGES_WIRED=$(vm_stat | awk '/Pages wired down:/ {gsub(/\./, "", $4); print $4}')
MEM_USED=$(( (PAGES_ACTIVE + PAGES_WIRED) * PAGE_SIZE ))
MEM_USED_PCT=$(awk "BEGIN {printf \"%.1f\", ${MEM_USED} / ${MEM_TOTAL} * 100}")

# ディスク使用率（/ パーティション）
DISK_USED_PCT=$(df / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')

# アップタイム（秒）
# sysctl -n kern.boottime 出力例: "{ sec = 1743700000, usec = 0 } Thu Apr  3 ..."
BOOT_SEC=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ',')
UPTIME_SEC=$(( $(date +%s) - BOOT_SEC ))

# ホストメトリクスの Line Protocol 構築
# CPU温度が取得できた場合のみフィールドに追加
if [[ -n "$CPU_TEMP" ]]; then
  LINE_HOST="host_metrics,host=${HOST_NAME},role=${HOST_ROLE} \
UPS_MONITOR_cpu_temp=${CPU_TEMP},\
UPS_MONITOR_cpu_load_1m=${LOAD_1M},\
UPS_MONITOR_cpu_load_5m=${LOAD_5M},\
UPS_MONITOR_mem_used_pct=${MEM_USED_PCT},\
UPS_MONITOR_disk_used_pct=${DISK_USED_PCT}i,\
UPS_MONITOR_uptime_sec=${UPTIME_SEC}i \
${TIMESTAMP}"
else
  LINE_HOST="host_metrics,host=${HOST_NAME},role=${HOST_ROLE} \
UPS_MONITOR_cpu_load_1m=${LOAD_1M},\
UPS_MONITOR_cpu_load_5m=${LOAD_5M},\
UPS_MONITOR_mem_used_pct=${MEM_USED_PCT},\
UPS_MONITOR_disk_used_pct=${DISK_USED_PCT}i,\
UPS_MONITOR_uptime_sec=${UPTIME_SEC}i \
${TIMESTAMP}"
fi

influx_post "host" "${LINE_HOST}" || exit 1

if [[ "$COLLECT_UPS" == "true" ]]; then
  echo "OK: UPS + host metrics sent at $(date '+%Y-%m-%d %H:%M:%S')"
else
  echo "OK: host metrics sent (UPS collection skipped) at $(date '+%Y-%m-%d %H:%M:%S')"
fi
