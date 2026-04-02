# ups-metrics-collector

UPS および UPS 監視ホスト（Linux）のメトリクスを収集し、InfluxDB Cloud へ送信する bash スクリプトです。

---

## 概要

[NUT (Network UPS Tools)](https://networkupstools.org/) の `upsc` コマンドを使って UPS のステータスを取得し、UPS 監視ホストのシステム情報（CPU 温度・負荷率・メモリ使用率など）と合わせて InfluxDB Cloud へ送信します。収集は systemd timer により定期実行されます。収集したデータは Grafana Cloud で可視化します。

`COLLECT_UPS=false` を設定することで、UPS 非接続ホストでもホストメトリクスのみ収集できます。

```
APC UPS
  └─ NUT (upsd / upsc)
       └─ ups-collect.sh          # 本リポジトリ
            ├─ ups_metrics        ─┐
            └─ host_metrics        ├─ InfluxDB Cloud (bucket: ups)
                                   └─ Grafana Cloud
```

---

## 構成

```
ups-metrics-collector/
├── README.md
├── scripts/
│   └── ups-collect.sh           # メトリクス収集・送信スクリプト
├── systemd/
│   ├── ups-collect.service      # systemd サービスユニット
│   └── ups-collect.timer        # systemd タイマーユニット（1分間隔）
└── env/
    └── ups-collect.env.example  # 環境変数テンプレート（シークレットなし）
```

---

## 収集メトリクス

### UPS メトリクス（measurement: `ups_metrics`）

| フィールド | 内容 | 型 |
|---|---|---|
| `battery_charge` | バッテリー残量（%） | float |
| `battery_runtime` | 推定残り時間（秒） | integer |
| `battery_voltage` | バッテリー電圧（V） | float |
| `input_voltage` | 入力電圧（V） | float |
| `output_voltage` | 出力電圧（V） | float |
| `ups_load` | 負荷率（%） | float |

タグ：`host`、`ups_status`（OL / OB / LB など）

### ホストメトリクス（measurement: `host_metrics`）

| フィールド | 内容 | 型 |
|---|---|---|
| `UPS_MONITOR_cpu_temp` | CPU 温度（℃） | float |
| `UPS_MONITOR_cpu_load_1m` | ロードアベレージ 1分 | float |
| `UPS_MONITOR_cpu_load_5m` | ロードアベレージ 5分 | float |
| `UPS_MONITOR_mem_used_pct` | メモリ使用率（%） | float |
| `UPS_MONITOR_disk_used_pct` | ディスク使用率（%） | integer |
| `UPS_MONITOR_uptime_sec` | 起動経過時間（秒） | integer |

タグ：`host`、`role`

---

## 前提条件

- Linux ホスト（systemd 対応、`/sys` および `/proc` が利用可能であること）
- NUT クライアント（`upsc` コマンド）がホストにインストール済み（`COLLECT_UPS=false` の場合は不要）
- systemd が利用可能
- InfluxDB Cloud アカウント・バケット `ups` 作成済み
- 書き込み専用 API トークン発行済み

---

## セットアップ

### 1. リポジトリの取得

```bash
git clone https://github.com/<your-account>/ups-metrics-collector.git
cd ups-metrics-collector
```

### 2. 環境変数ファイルの配置

```bash
sudo cp env/ups-collect.env.example /etc/ups-collect.env
sudo vi /etc/ups-collect.env        # 実際の値を記入
sudo chown root:root /etc/ups-collect.env
sudo chmod 600 /etc/ups-collect.env
```

設定項目：

#### UPS 接続ホスト（デフォルト）

```bash
INFLUX_URL=https://ap-northeast-1-1.aws.cloud2.influxdata.com
INFLUX_TOKEN=your-write-token-here
INFLUX_ORG=your-org-name
INFLUX_BUCKET=ups
UPS_HOST=ups@localhost
HOST_NAME=your-hostname
HOST_ROLE=ups_monitor
COLLECT_UPS=true        # 省略時も true として動作
```

#### UPS 非接続ホスト（ホストメトリクスのみ）

```bash
INFLUX_URL=https://ap-northeast-1-1.aws.cloud2.influxdata.com
INFLUX_TOKEN=your-write-token-here
INFLUX_ORG=your-org-name
INFLUX_BUCKET=ups
HOST_NAME=your-hostname
HOST_ROLE=general
COLLECT_UPS=false       # UPS_HOST の設定は不要
```

> **注意**：`/etc/ups-collect.env` は API トークンを含むため、リポジトリには含めていません。`ups-collect.env.example` をテンプレートとして使用してください。

### 3. スクリプトの配置

```bash
sudo cp scripts/ups-collect.sh /usr/local/bin/ups-collect.sh
sudo chown root:root /usr/local/bin/ups-collect.sh
sudo chmod 755 /usr/local/bin/ups-collect.sh
```

### 4. systemd ユニットの配置・有効化

```bash
sudo cp systemd/ups-collect.service /etc/systemd/system/
sudo cp systemd/ups-collect.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ups-collect.timer
```

### 5. 動作確認

```bash
# 即時実行
sudo systemctl start ups-collect.service

# ログ確認
sudo journalctl -u ups-collect.service -n 20

# タイマー確認（Next trigger が約1分後になっていること）
systemctl status ups-collect.timer
```

---

## 動作確認フロー

#### UPS 接続ホスト

```
upsc ups@localhost                   # UPS からデータが取れるか確認
  ↓
sudo systemctl start ups-collect.service  # スクリプト単体テスト
  ↓
InfluxDB Cloud Data Explorer         # bucket: ups にデータが入ったか確認
  ↓
Grafana Cloud                        # グラフに反映されているか確認
```

#### UPS 非接続ホスト（COLLECT_UPS=false）

```
sudo systemctl start ups-collect.service
  ↓
sudo journalctl -u ups-collect.service -n 5
  # "OK: host metrics sent (UPS collection skipped)" が出ることを確認
  ↓
InfluxDB Cloud Data Explorer         # host_metrics にのみデータが入ることを確認
```

---

## クレジット

本リポジトリのコードおよびドキュメントは [Claude](https://claude.ai)（Anthropic）の支援により生成しました。
