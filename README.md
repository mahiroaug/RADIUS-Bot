# RADIUS + Slack連携 有線LAN認証システム（本番運用ガイド）

本ドキュメントは、公開CA（Let's Encrypt）＋DNS-01（Route53）で取得したサーバ証明書を用い、FreeRADIUS（PEAP）＋Slack Bot（Socket Mode）＋dnsmasq（DHCP）＋Cisco Catalyst（802.1X）を本番運用するための手順に特化しています。開発向け手順は付録に分離します。

---

## 目的と前提
- 目的: 認証成功端末のみVLAN10へ収容し、ユーザーはSlackから自身のRADIUSアカウントをセルフ運用。
- 規模: 約30台（Mac中心、一部Windows/Linux）。
- 認証方式: IEEE 802.1X（EAP-PEAP + MSCHAPv2）。クライアント証明書は不要。
- ネットワーク: Cisco Catalyst。未認証は遮断（ゲストVLANなし）。
- サーバ: オンプレMiniPC上でDocker稼働。
- 証明書: 公開CA（Let's Encrypt）をDNS-01（Route53）で取得。サーバ名検証を必須化。

---

## 構成概要
- FreeRADIUS: PEAP認証。Slack BotがユーザーID/パスワードを管理。
- Slack Bot（Python, slack_bolt, Socket Mode）: DMコマンドでユーザー自身が登録/削除/再発行。
- dnsmasq: DHCP（DNS機能は無効化）。VLAN10へIP配布。
- Cisco Catalyst: 802.1X中継。成功時のみVLAN10へ。

---

## 事前準備
- FQDN: `radius.example.com`（サーバ名検証に使用）
- CAAを運用している場合はLet's Encryptを許可
  - 例: `CAA 0 issue "letsencrypt.org"`
- Route53: 開発用ノートPC（devcontainer）でCertbotを実行し、TXTを追加できる権限を用意（本番RADIUSサーバにAWS資格情報は置かない）
- ネットワーク設計
  - VLAN10: 192.168.4.0/22（GW 192.168.4.1）
  - 802.1X成功時のみVLAN10へ。未認証は遮断。

---

## 環境変数（.env）
- 必須
  - `SLACK_APP_TOKEN=...`  Socket Mode用App-Level Token（xapp-）
  - `SLACK_BOT_TOKEN=...`  Bot User OAuth Token（xoxb-）
  - `RADIUS_FQDN=...`  公開CAのFQDN（PEAPのサーバ名検証用）

---

## セットアップ手順（本番）

### 1) DevContainer初期化（ノートPC）
- DevContainer作成後、`.devcontainer/setup-devcontainer.sh` が自動実行され、Python依存とCertbot + Route53プラグインを導入します。

### 2) 証明書の発行（ノートPC, Route53 DNS-01）
```bash
export RADIUS_FQDN=radius.example.com
sudo certbot certonly \
  --dns-route53 \
  -d "$RADIUS_FQDN" \
  -m admin@example.com \
  --agree-tos --non-interactive
```

### 3) 証明書の配布（ノートPC → オンプレRADIUS）
```bash
export RADIUS_HOST=<RADIUSサーバのIP/ホスト名>
export RADIUS_USER=<SSHユーザ>   # 省略可
# 発行結果（/etc/letsencrypt/live/<FQDN>）をRADIUSへ配布
bash scripts/remote_push_radius_cert.sh
# または一括（発行→配布）
bash scripts/prod/issue_and_deploy_cert.sh
```
- サーバ側配置と役割
  - `radius/certs/server.pem` ← fullchain.pem（中間含む）
  - `radius/certs/server.key` ← privkey.pem
  - `radius/certs/ca.pem`     ← chain.pem or fullchain.pem
  - `radius/certs/dh`         ← 別途生成（次項）

### 4) DHパラメータの生成（サーバ側1回）
```bash
openssl dhparam -out radius/certs/dh 2048
chmod 644 radius/certs/dh
```

### 5) dnsmasq（DHCP）
- `dnsmasq/dnsmasq.conf` はDHCP専用（`port=0`）。VLAN10の例:
```conf
no-daemon
log-queries
log-dhcp
bind-interfaces
port=0
no-resolv
no-hosts
dhcp-authoritative
dhcp-leasefile=/var/lib/misc/dnsmasq.leases

# VLAN10（インタフェース名は環境に合わせて変更: 例 eth0.10 / eno1.10 など）
interface=eth0.10
# 192.168.4.0/22 の一部範囲を配布（必要に応じて調整）
dhcp-range=interface:eth0.10,192.168.5.0,192.168.7.254,255.255.252.0,12h
# デフォルトゲートウェイ / DNS（パブリックDNS）
dhcp-option=interface:eth0.10,option:router,192.168.4.1
dhcp-option=interface:eth0.10,option:dns-server,8.8.8.8,1.1.1.1
```
- コンテナは `network_mode: host`。リースは `./dnsmasq/leases` に保存。

### 6) Docker起動
```bash
docker-compose up -d --build
```
- 主要ボリューム
  - `./radius/certs` → `/etc/freeradius/3.0/certs:ro`
  - `./radius/authorize` → `/etc/freeradius/mods-config/files/authorize:ro`
  - `./dnsmasq/dnsmasq.conf` → `/etc/dnsmasq.conf:ro`
  - `./dnsmasq/leases` → `/var/lib/misc`

### 7) Cisco Catalyst（例）
```cisco
! グローバル
aaa new-model
dot1x system-auth-control
radius server RADIUS1
 address ipv4 <RADIUSサーバIP> auth-port 1812 acct-port 1813
 key radiusSecret
!
! 対象ポート（例: Gi1/0/1）
interface Gi1/0/1
 switchport mode access
 authentication port-control auto
 dot1x pae authenticator
 authentication event success vlan 10
! 未認証は遮断（ゲストVLANなし）
```

### 8) Slack App（Socket Mode）
- コマンド: `/radius_register`, `/radius_unregister`, `/radius_status`, `/radius_resetpass`, `/radius_help`
- 構成
  - Socket Mode有効化、App-Level Token（SLACK_APP_TOKEN）
  - Bot Tokenスコープ: `chat:write`, `commands`, `im:history`, `users:read`

---

## 運用
- 証明書の更新（90日ごと）
  - ノートPCで `certbot renew` → `scripts/remote_push_radius_cert.sh` で配布
```bash
certbot renew --quiet && \
  RADIUS_FQDN=radius.example.com \
  RADIUS_HOST=<RADIUSサーバ> \
  RADIUS_USER=<SSHユーザ> \
  bash scripts/remote_push_radius_cert.sh
```
- 監視/ログ
  - `docker-compose logs -f freeradius`
  - `docker-compose logs -f dnsmasq`
  - Catalyst: `show authentication sessions`, `show dot1x all`
- セキュリティ
  - クライアントで「サーバ証明書検証＋サーバ名一致」を必須化
  - 秘密鍵（server.key）は600/リポジトリ非管理
  - Slackトークンは.envで厳格管理

---

## E2Eテスト
1. Slackで `/radius_register` → ID/パスワード発行
2. 端末の有線802.1Xに上記のID/PASSを設定
3. 認証成功 → VLAN10 → DHCPでIP取得（192.168.4.0/22）
4. インターネット疎通確認
5. 失敗系: 未登録/誤パス → ポート遮断（DHCP不取得）

---

## ディレクトリ（抜粋）
```
project-root/
├── bot/                      # Slack Bot（Python, Socket Mode）
├── dnsmasq/
│   ├── dnsmasq.conf          # DHCP設定（DNS無効化）
│   └── leases/               # リース永続化
├── radius/
│   ├── authorize.sample      # FreeRADIUS ユーザー定義（サンプル）
│   └── certs/                # 本番: server.pem/server.key/ca.pem/dh を配置
├── scripts/
│   ├── dev/
│   │   └── generate_dev_certs.sh       # 開発用：自己署名生成（本番では未使用）
│   ├── prod/
│   │   └── issue_and_deploy_cert.sh    # 本番：発行→配布の一括実行
│   └── remote_push_radius_cert.sh      # 本番：生成済み証明書の配布
├── docker-compose.yaml
└── README.md
```

---

## 付録（開発）
- 自己署名での動作確認（本番では使用しない）
```bash
bash scripts/dev/generate_dev_certs.sh
# 生成先: radius/certs/{server.pem,server.key,ca.pem,dh}
```

---

## ライセンス
MIT
