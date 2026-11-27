# MacBookPro15,1 実機ブリングアップ手順

この手順は MacBookPro15,1 (T2) で、起動経路・内蔵入力・NVMe・有線 NIC を段階的に確認するためのものです。**macOS と必要なデータの完全バックアップを先に作成**し、作業中は MacBook に電源アダプタを接続してください。USB-C/Thunderbolt 有線 LAN アダプタ、インストーラ USB メモリを用意します。インストール前のセッション A は診断だけで、ディスクへの書き込みを行いません。

## 起動前の準備

1. macOS の完全バックアップがあり、復元手段を確認できることを確認します。
2. T2 Mac をシステム終了します。電源を入れた直後から **Command-R** を押し続けて macOS リカバリを起動します。
3. メニューバーの **Utilities > Startup Security Utility** を開き、対象の macOS システムを選びます。
4. Secure Boot を **No Security**（セキュアブート無効）にし、External Boot を **Allow booting from external or removable media**（外部/リムーバブルメディアからの起動を許可）に設定します。管理者認証を求められた場合は macOS の管理者で認証します。
5. リカバリを終了して電源を切り、インストーラ USB と有線 LAN アダプタを接続します。電源投入直後から **Option (⌥)** キーを押し続け、Startup Manager で EFI のインストーラ USB を選びます。

## セッション A — インストーラを起動して検査だけ行う

**まだインストールを開始しません。** Debian Installer が起動したら、シェルへ切り替えます（テキスト画面では `Alt+F2`、機種/画面構成によっては `Ctrl+Alt+F2`）。root シェルで次を実行します。

```sh
sh /cdrom/t2/scripts/t2-hardware-preflight.sh
```

`SUMMARY: PASS: ...` となり、`FAIL` がないことを確認します。これは sysfs/proc、`lsblk`、`blkid -p`、`ip` を読むだけの検査です。**ディスクの初期化、パーティション作成、インストールは行いません。** WARN は Secure Boot 状態や任意機能などを示します。Secure Boot が有効ならセッションを中断し、macOS Recovery の Startup Security Utility で設定を見直します。

レポートを残す場合は、別の USB ストレージを接続し、`lsblk -f` でデバイスを確認してから、そのパーティションをマウントします。以下の `/dev/sdX1` は実際に確認したデバイスへ置き換えてください。誤ったデバイスを選ばないでください。

```sh
mkdir -p /mnt/report-usb
mount /dev/sdX1 /mnt/report-usb
sh /cdrom/t2/scripts/t2-hardware-preflight.sh --report /mnt/report-usb/t2-hardware-preflight.txt
sync
umount /mnt/report-usb
```

レポートを保存しない場合は `--report` を付けません。診断結果を確認したら `Alt+F1`（または `Ctrl+Alt+F1`）でインストーラへ戻るか、電源を切ります。FAIL が残る場合はインストールへ進まず、後述の失敗マトリクスを確認します。

## セッション B — Proxmox VE のインストール

セッション A の結果を確認した後にだけ進みます。GRUB で **Automated install (T2 Proxmox)**（`t`）または **Manual partition install (T2 Proxmox)**（`m`）を選びます。既存 macOS/Ubuntu パーティションを保持し、対象ディスクと区画を画面上で慎重に確認してください。手動パーティションの選択・レイアウトは [手動パーティションでのインストール手順](manual-partition-install.md) を参照してください。特に既存の macOS EFI パーティションを再利用・フォーマットしないでください。

## セッション C — 初回起動と管理接続

1. インストール完了後、内蔵ストレージから起動します。初回起動処理はネットワークの IPv4/DNS 接続を待ってから Proxmox VE パッケージの導入・設定を行います。有線 LAN アダプタを接続したまま待ちます。
2. 処理完了後に再起動します。再起動後、管理用ブリッジ `vmbr0` の DHCP アドレスを確認します。
3. 同じ LAN から `https://<vmbr0のIPv4アドレス>:8006/` と SSH で接続できることを確認します。SSH の認証はインストール時に設定した root 認証情報を使います。
4. 初回起動ログは `/var/log/first-boot-proxmox.log`、カーネル/デバイスログは `journalctl -b` と `dmesg` で確認します。

```sh
ip -br addr
ip route
systemctl --no-pager --full status first-boot-proxmox.service
tail -n 100 /var/log/first-boot-proxmox.log
journalctl -b --no-pager
dmesg | tail -n 100
```

## 失敗マトリクス

| 症状 | 原因候補 | 確認コマンド/場所 | 次のアクション |
| --- | --- | --- | --- |
| Option 起動メニューに USB が出ない / GRUB が出ない | External Boot が禁止、Secure Boot 設定、USB 作成/接続不良 | macOS Recovery の Startup Security Utility、起動時 Option、別 USB ポート | Secure Boot 無効と外部起動許可を再確認し、USB を挿し直す。内蔵ディスクへインストールしない。 |
| GRUB は出るが画面が暗い/表示されない | EFI framebuffer/表示モード、外部画面・バックライト初期化 | インストーラの `dmesg`、別画面/輝度キー、USB キーボードで `Alt+F2` | USB キーボードでシェルに入り診断する。画面が確認できるまでインストールを進めない。 |
| 内蔵キーボード/トラックパッドが反応しない | `t2bce_core`/`t2bce_vhci` 未ロード、デバイス初期化失敗 | `lsmod | grep t2bce`、`grep -E 'Handlers=|Name=' /proc/bus/input/devices`、`dmesg | grep -iE 't2bce|apple|input'` | USB キーボード/マウスで操作し、`modprobe t2bce_core t2bce_vhci` を試して再検査する。モジュールエラーが続く場合は中断する。 |
| USB-C 有線 NIC がない / carrier が 0 | アダプタ非対応、ケーブル/スイッチ/DHCP 側、ドライバ未ロード | `ip link`、`lsusb`、`readlink /sys/class/net/<IF>/device/driver`、`dmesg | grep -iE 'usb|ether|r815|network'` | アクティブな LAN ポートへ接続し直す。対応アダプタ/ドライバを確認し、IPv4 と default route が得られるまで初回起動へ進まない。 |
| NVMe が見えない | NVMe コントローラ初期化、起動モード/カーネル問題 | `lsblk`、`ls /sys/class/nvme`、`lspci -nn`、`dmesg | grep -iE 'nvme|pcie'` | インストーラ起動をやり直して確認する。ディスクを作成/消去する操作はしない。引き続き見えない場合は中断する。 |
| `blkid` が既存署名を報告する / LVM 予約が不明 | macOS/Ubuntu の既存領域、以前のインストール、誤ったディスク選択 | `lsblk -f`、`blkid -p <確認対象デバイス>`、自動/手動手順 | 対象とパーティションを特定できるまでインストールしない。macOS 領域を消去せず、手動手順を再確認する。 |
| 初回起動がネットワーク待ちで失敗 | DHCP/DNS、NIC の link、vmbr0 の構成 | `ip -br addr`、`ip route`、`getent ahostsv4 enterprise.proxmox.com`、`journalctl -u first-boot-proxmox.service -b` | 有線リンクと DHCP/DNS を直し、ログを確認してからサービスを再実行する。 |

## ロールバック

起動時に GRUB メニューが表示されたら、タイムアウト（通常 10 秒）内に、必要なら **Advanced options** のサブメニューから `-t2` を含まない在庫の **Proxmox VE カーネル**を選択します。選択操作には外付け USB キーボードを使えます。起動後に T2 カーネル側を調査・修復します。インストーラ USB は復旧用に保管してください。GRUB が使えない場合は、電源投入時 Option キーからインストーラ USB を選び、診断用途にとどめます。起動メディアから実ディスクへ変更を加える前に、バックアップと対象ディスクを再確認してください。
