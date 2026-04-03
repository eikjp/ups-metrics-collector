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
│   ├── ups-collect.sh           # メトリクス収集・送信スクリプト（Linux版）
│   └── ups-collect-mac.sh       # メトリクス収集・送信スクリプト（macOS版）
├── systemd/
│   ├── ups-collect.service      # systemd サービスユニット
│   └── ups-collect.timer        # systemd タイマーユニット（1分間隔）
├── launchd/
│   └── ups-collect-mac.plist    # launchd 設定ファイル（macOS版）
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

---

## macOS 対応

macOS 向けのスクリプト（`scripts/ups-collect-mac.sh`）と launchd 設定ファイル（`launchd/ups-collect-mac.plist`）を提供しています。Linux 版と同じ環境変数ファイル・同じ InfluxDB 送信フォーマットを使用します。

### 前提条件（macOS版）

- macOS（Apple Silicon / Intel、どちらでも動作）
- `zsh`（macOS デフォルトシェル、`/bin/zsh`）
- `curl`（macOS 標準）
- `jq`（JSON パース）: `brew install jq`
- `upsc`（NUT クライアント、`COLLECT_UPS=true` の場合）
- CPU温度取得ツール（任意・チップ別）:
  - **Apple Silicon（M1/M2/M3/M4）**: `macmon` — `brew install macmon`
  - **Intel Mac**: `osx-cpu-temp` — `brew install osx-cpu-temp`

スクリプトは `uname -m` でチップ種別を自動判別し、対応するツールを使用します。ツールが未インストールの場合は CPU温度フィールドをスキップします。

### セットアップ手順

#### 1. 環境変数ファイルの配置

Linux 版と同じファイルをそのまま流用できます。

```bash
sudo cp env/ups-collect.env.example /etc/ups-collect.env
sudo vi /etc/ups-collect.env        # 実際の値を記入
# LaunchAgent はログインユーザー権限で動作するため、ファイルの所有者を自分にする
sudo chown $(whoami):staff /etc/ups-collect.env
sudo chmod 600 /etc/ups-collect.env
```

> **注意（Linux版との違い）**: Linux の systemd サービスは root で動作するため `chown root:root` で問題ありませんが、macOS の LaunchAgent はログインユーザー権限で動作します。`chown root:wheel` にすると `source` 時に permission denied が発生します。

#### 2. スクリプトの配置・権限設定

```bash
sudo cp scripts/ups-collect-mac.sh /usr/local/bin/ups-collect-mac.sh
sudo chmod 755 /usr/local/bin/ups-collect-mac.sh
```

#### 3. plistの配置・有効化

plist ファイルの配置先：

```
~/Library/LaunchAgents/com.<hostname>.ups-collect.plist
```

`<hostname>` の部分を実際のホスト名（`hostname -s` で確認）に置き換えてください。

```bash
# plist をコピー（ホスト名に合わせてファイル名を変更）
cp launchd/ups-collect-mac.plist \
  ~/Library/LaunchAgents/com.$(hostname -s).ups-collect.plist

# plist 内の Label も同様に変更（任意・ファイル名と合わせるとトラブルシュートが容易）
# <string>com.local.ups-collect</string>
# → <string>com.<hostname>.ups-collect</string>

# launchd に登録・有効化
launchctl load ~/Library/LaunchAgents/com.$(hostname -s).ups-collect.plist
```

#### 4. 動作確認

```bash
# 手動で即時実行（ログを標準出力に表示）
zsh /usr/local/bin/ups-collect-mac.sh

# launchd 経由でのログ確認
tail -f /tmp/ups-collect-mac.log
tail -f /tmp/ups-collect-mac.err

# launchd ジョブの状態確認
launchctl list | grep ups-collect
```

### スリープ動作について

`StartInterval` を使用しているため、Mac がスリープ中はタイマーのカウントが停止します。スリープを解除することはありません。スリープ解除後に次の実行タイミングが来た時点でスクリプトが実行されます。

### launchd の無効化

```bash
launchctl unload ~/Library/LaunchAgents/com.$(hostname -s).ups-collect.plist
```

---

## クレジット

本リポジトリのコードおよびドキュメントは [Claude](https://claude.ai)（Anthropic）の支援により生成しました。
