#!/bin/bash
# UPS メトリクス + 監視ホストメトリクス収集・InfluxDB Cloud 送信
# シークレットは /etc/ups-collect.env から環境変数として注入される

# ─── 設定（環境変数が未セットなら即終了） ────────────────
: "${INFLUX_URL:?INFLUX_URL is not set}"
: "${INFLUX_TOKEN:?INFLUX_TOKEN is not set}"
: "${INFLUX_ORG:?INFLUX_ORG is not set}"
: "${INFLUX_BUCKET:?INFLUX_BUCKET is not set}"
COLLECT_UPS="${COLLECT_UPS:-true}"
if [ "$COLLECT_UPS" = "true" ]; then
  : "${UPS_HOST:?UPS_HOST is not set}"
fi
: "${HOST_NAME:?HOST_NAME is not set}"
: "${HOST_ROLE:?HOST_ROLE is not set}"
# ─────────────────────────────────────────────────────────

# タイムスタンプ（全ラインで共通）
TIMESTAMP=$(date +%s%N)

influx_post() {
  local label="$1"
  local data="$2"
  local status
  status=$(curl -s -m 10 -o /tmp/influx_${label}_response.txt -w "%{http_code}" \
    --request POST \
    "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=ns" \
    --header "Authorization: Token ${INFLUX_TOKEN}" \
    --header "Content-Type: text/plain; charset=utf-8" \
    --data-raw "${data}")
  if [ "$status" != "204" ]; then
    echo "ERROR: [${label}] InfluxDB returned ${status}" >&2
    cat /tmp/influx_${label}_response.txt >&2
    return 1
  fi
}

# ═══════════════════════════════════════════════════════
# UPS メトリクス
# ═══════════════════════════════════════════════════════

if [ "$COLLECT_UPS" = "true" ]; then

  # UPS データ取得
  UPS_DATA=$(upsc "${UPS_HOST}" 2>/dev/null)
  if [ -z "$UPS_DATA" ]; then
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
  if [ -z "$BATTERY_CHARGE" ] || [ -z "$UPS_STATUS" ]; then
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

# CPU温度（millidegrees → ℃、小数2桁）
CPU_TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
CPU_TEMP=$(awk "BEGIN {printf \"%.2f\", ${CPU_TEMP_RAW:-0} / 1000}")

# ロードアベレージ（1分・5分）
LOAD_1M=$(awk '{print $1}' /proc/loadavg)
LOAD_5M=$(awk '{print $2}' /proc/loadavg)

# メモリ使用率（%）
MEM_TOTAL=$(awk '/^MemTotal:/    {print $2}' /proc/meminfo)
MEM_AVAIL=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
MEM_USED_PCT=$(awk "BEGIN {printf \"%.1f\", (1 - ${MEM_AVAIL}/${MEM_TOTAL}) * 100}")

# ディスク使用率（/ パーティション）
DISK_USED_PCT=$(df / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')

# アップタイム（秒）
UPTIME_SEC=$(awk '{printf "%d", $1}' /proc/uptime)

LINE_HOST="host_metrics,host=${HOST_NAME},role=${HOST_ROLE} \
UPS_MONITOR_cpu_temp=${CPU_TEMP},\
UPS_MONITOR_cpu_load_1m=${LOAD_1M},\
UPS_MONITOR_cpu_load_5m=${LOAD_5M},\
UPS_MONITOR_mem_used_pct=${MEM_USED_PCT},\
UPS_MONITOR_disk_used_pct=${DISK_USED_PCT}i,\
UPS_MONITOR_uptime_sec=${UPTIME_SEC}i \
${TIMESTAMP}"

influx_post "host" "${LINE_HOST}" || exit 1

if [ "$COLLECT_UPS" = "true" ]; then
  echo "OK: UPS + host metrics sent at $(date '+%Y-%m-%d %H:%M:%S')"
else
  echo "OK: host metrics sent (UPS collection skipped) at $(date '+%Y-%m-%d %H:%M:%S')"
fi
