# proxmox-t2-iso

MacBookPro15,1 (Apple T2) 向けに Debian 13 netinst ISO をリマスターし、T2BCE 対応の Proxmox kernel `7.0.14-30-pve-t2` を導入した後、初回起動で Proxmox VE を構成するリポジトリです。

> **実機インストールは所有者の判断があるまで凍結中です。** 検証は GitHub Actions と VM ドライランのみで行います。実機や実ディスクでインストーラ/preseed を実行しないでください。preseed の設計・期待値は以下に記しますが、実際の挙動は [VM ドライラン手順](docs/vm-dryrun.md)で確認してください。

## ビルド方針

- PVE kernel はカーネル担当の workflow でビルドし、ISO は Release **`kernel-7.0.14-30-pve-t2-r1`** の image deb を取得します。カーネル関連ファイル変更をまとめ、ビルドは一度だけ行います。
- ISO はマイルストーン時のみビルドします。ドキュメントや小さな変更のたびにカーネル/ISO のフルビルドは行いません。
- `build-kernel.yml` は成功した場合のみ artifact と Release を公開します。ISO workflow は Release からカーネル `.deb` を取得します。

## 必要なツールと ISO の作成

リマスターに必要な主なコマンドは `xorriso`、`cpio`、`fakeroot`、`kmod`（`depmod`）、`python3`、`gzip`、`md5sum` と `dpkg-deb` です。`gh` は既存カーネル Release から `.deb` を取得する場合に使います。Debian/Ubuntu では `dpkg-deb` は `dpkg` パッケージに含まれます。

Debian 13 amd64 netinst ISO と PVE T2 kernel image `.deb` を含むディレクトリを用意し、次のように実行します。PVE T2 image が優先され、旧 `linux-image-*.deb` は fallback 専用です。

```sh
DEBIAN_ISO=/path/debian-13.x-amd64-netinst.iso \
KERNEL_DEB_DIR=/path/debs \
  ./scripts/remaster-iso.sh out.iso
```

Release からカーネルパッケージを取得する例:

```sh
mkdir -p debs
gh release download kernel-7.0.14-30-pve-t2-r1 --pattern '*.deb' --dir debs
```

オプションの環境変数:

- `FIRMWARE_DIR=/path/brcm`: ローカルの私的ビルドに限り、Broadcom ファームウェアを ISO の `/t2/firmware/brcm/` に追加します。
- `SSH_AUTHORIZED_KEYS_FILE=/path/authorized_keys`: 任意の SSH 公開鍵ファイルを ISO に同梱し、インストール先の `/root/.ssh/authorized_keys` に配置します。

## ファームウェア方針

Apple ファームウェアのバイナリは、再配布条件が確認できていないため、公開リポジトリにも公開 ISO にも含めません。`firmware/` に置くのは SHA-256 目録のみです。Wi-Fi ファームウェアをインストーラ initrd に含めることもありません。

GitHub Actions の `build-iso` は `FIRMWARE_DIR` 未設定で実行され、ファームウェアなし ISO を作ります。workflow はその旨を `NOTE` と Step Summary の両方に表示します。私的なローカルビルドで `FIRMWARE_DIR` を指定した場合は `/t2/firmware/brcm/` に同梱し、インストーラの `late_command` が `/target/lib/firmware/brcm/` に配置する設計です。ローカル生成物を公開・配布しないでください。

## インストール選択とパーティション設計

### 起動メニュー

- GRUB は通常の **Install** をデフォルトにし、タイムアウトは 30 秒です。自動インストールはデフォルトでは起動しません。
- `/install.amd/preseed-initrd.cpio` に auto/manual 両方の preseed を収録し、単一の `/install.amd/initrd-t2` を共有します。GRUB hotkey `t` は自動、`m` は手動パーティションです。BIOS/isolinux にも同じ選択肢があります。
- 既定の stock **Install** は preseed なしで、誤操作時も自動でディスクを書き換えません。Graphical install / Advanced options も T2 preseed を使いません。

### preseed のディスク設計

自動モードは `/dev/nvme0n1` の最大 free extent を使い、partman guard で disk / GPT / recipe 容量を検証します。手動モードは guard を使わず、partman UI で利用者が未割当領域に区画を作成します。手順は [手動パーティション手順](docs/manual-partition-install.md)を参照してください。

- インストール対象は `/dev/nvme0n1`、partman の選択方法は `biggest_free` です。`partman-auto/method` は設定しません。
- Debian 13.8 の `biggest_free` は、method を設定しない構成では `partman-auto/disk` を候補絞り込みに使わず、全ディスクから最大の空き領域を選びます。T2 preseed は `partman/early_command` から `display.d/09t2guard` を入れ、書き込み前に最大領域のデバイスが GPT の `/dev/nvme0n1` であることと、`pve-final` のサイズを検証します。他のディスクや USB インストーラは接続できますが、その空き領域が最大ならインストールを停止します。
- 新しいパーティションを空き領域に作ります。既存 ESP を再利用せず、既存の LVM/MD を削除しません。
- 自動レシピは ESP 512 MB、`/boot` 2048 MB、swap 4096 MB、root 20480–32768 MB ext4、残り全部を `method{ lvm }` の予約パーティションとします。
- guard は Debian の recipe decoder で必要サイズと有限拡張を計算し、PV 用 32 MiB と最終 partition alignment 用 4 MiB を確保できない場合は自動処理を止めます。
- Debian `expert_recipe` の MB は 10^6 bytes 単位で、parted の MiB/GiB 表示とは異なります。手動モードでは ESP 512 MiB、`/boot` 2 GiB、swap 4 GiB、root 24–32 GiB、PV に残りを使うことを推奨します。
- partman はこのレシピだけでは VG を作りません。`late_command` が udev の `ID_PART_ENTRY_TYPE` が `E6D6D379-F507-44C2-A23C-238F2A3DF928`（Linux LVM）の予約パーティションを特定し、`pvcreate` / `vgcreate pve` を実行します。
- この方式では root と swap は通常パーティションであり LV ではありません。thin pool は初回起動時に VG の空き 100% から `pve/data` として作ります。

## late_command の責務

インストーラの `late_command` は、設計上、次の処理を行います。

1. 自動では未使用 LVM 予約領域を一意検出して `pvcreate` / `vgcreate pve`。手動では mount / swap / VG / PV 状態を検査し、曖昧な状態や既存 filesystem 署名を変更しない。
2. ISO の kernel image `.deb` のみを in-target でインストールし、`vmlinuz-*-pve-t2` と対応 initrd を確認。
3. T2 modules を initramfs に追加し、`update-initramfs`。GRUB cmdline に `intel_iommu=on iommu=pt pcie_ports=compat` を設定。
4. first-boot、network/readiness scripts、systemd units と `pve-cluster` hostname 同期 drop-in を配置・enable。
5. SSH drop-in と任意の `authorized_keys`、ローカル ISO に含まれる場合のみ Broadcom firmware を配置。
6. staging deb を削除し、ログを `/var/log/t2-target-setup.log` に保存。

処理失敗を握りつぶさないよう `set -e` で停止させる設計です。パスワード、秘密鍵、Wi-Fi 認証情報を preseed やスクリプトへ平文で書きません。

## SSH とネットワーク

- SSH ログインは、インストーラの対話画面で設定する root パスワードを基本経路とします。作成するユーザーは root のみです。SSH はインストール直後から有効にする設計です。
- 鍵ログインを選ぶ場合に限り `SSH_AUTHORIZED_KEYS_FILE` を指定します。秘密鍵は ISO に入れず、パスワードも文書・preseed に記載しません。
- インストーラのネットワークは USB/Thunderbolt 有線 Ethernet アダプタを前提とします。Wi-Fi SSID/認証情報を preseed しません。
- USB Ethernet 用の `r8152` を含めます。ISO リマスターは `scripts/installer-modules.txt` から `modprobe --show-depends` で依存を解決し、必要な modules だけを installer initrd に入れて `depmod` します。カーネル全体の module tree はコピーしません。
- 初回起動時は IPv4 default route の device と source address から、有線 uplink を特定します。carrier の列挙順には依存せず、T2 内部 NCM 仮想 NIC も除外します。使える有線 default route がなければ first-boot は失敗を記録します。
- Proxmox と `ifupdown2` の導入が終わったあと、`vmbr0` と `bridge-ports <nic>` を `/etc/network/interfaces` 本体へ追加します。既存の NIC DHCP stanza は `inet manual` に変えます。Proxmox の API/UI が読む main file に設定し、`ifquery -i <candidate> vmbr0` と main file の再読込を確認します。前の版が作った `interfaces.d/vmbr0` は完全一致する場合だけ main file へ移します。独自の `vmbr0` は上書きせず、内容をログに出して停止します。
- bridge は初回起動中に live reload せず、次の reboot で有効化します。初回起動中に選んだ DHCP IP を `/etc/hosts` へ設定し、次の boot では `pve-cluster` の起動前に `vmbr0` の DHCP IPv4 lease に追随します。lease が30秒以内に来ない場合は既存の hosts mapping を保持し、PVE 起動を止めません。
- Proxmox Web UI: `https://<現在のIP>:8006/`。IP は router DHCP lease list または console で確認してください。`pve-mbp` と `pve-mbp.local` は `/etc/hosts` 内の node 名です。ISO は mDNS/Avahi や LAN DNS を設定しないため、別 PC から `.local` が必ず解決するとは限りません。

## 初回起動の Proxmox 構成

`first-boot-proxmox.service` がネットワーク起動後に `first-boot-proxmox.sh` を一度実行します。`/var/lib/first-boot-proxmox.done` は初回のパッケージ構成とネットワーク設定が完了した marker です。初回スクリプトは自動再起動しません。成功時の `/var/lib/first-boot-proxmox.status` は `awaiting-reboot <boot-id>` となり、この時点では SSH/Web UI/local-lvm の稼働完了を表しません。

スクリプトの処理内容:

- Proxmox VE の `pve-no-subscription` リポジトリと署名鍵を設定し、`proxmox-ve`、`postfix`、`open-iscsi`、`chrony`、`ifupdown2` を導入。`pve-manager` が作る標準の `pve-enterprise.sources` stanza は初回 apt 更新前とパッケージ導入後に無効化します。無関係な apt source と旧式の `.list` ファイルは変更しません。
- VG `pve` の存在を必須確認し、その空き extents の 100% から thin pool `pve/data` を作成して `local-lvm` として登録。
- インストール済み T2 カーネルを GRUB のバージョン別 ID path `gnulinux-advanced-<bootid>>gnulinux-<version>-advanced-<bootid>` でデフォルト固定し、`GRUB_TIMEOUT=10` に設定します。ネットワーク/APT より前に一度固定し、全 package operation 後に再確認します。stock PVE kernel は GRUB から手動選択できます。削除対象は Debian の `linux-image-amd64` メタパッケージのみ。
- IPv4 default route に対応する有線 NIC を使う `vmbr0` 設定を `/etc/network/interfaces` に stage し、Proxmox 関連サービスと SSH を enable。

初回起動スクリプトは自動で再起動しません。処理ログは `/var/log/first-boot-proxmox.log` に記録されます。

次の boot では `pve-management-ready.service` が T2 kernel suffix、`t2bce_core` / `t2bce_vhci`、`modinfo zfs`、SSH、PVE services、active な `local-lvm`、`vmbr0` の IPv4 lease と hostname 解決、loopback 上の HTTPS endpoint を確認します。成功すると status が `ready <current-boot-id> <IP>` になります。失敗時は `not-ready <current-boot-id>` を記録し 30 秒間隔で再確認します。boot ID が変われば以前の `ready` は使わず、新しい boot の状態を検査します。first-boot の apt install 中には status file がまだないため、ready unit は PVE service を起動せず apt 処理を待たせません。

HTTPS readiness 検査は local endpoint の応答性を調べ、現在の DHCP IP と証明書 SAN の一致は検証しません。`pvecm updatecerts --force` は既定 node certificate を再生成してしまうため自動では呼びません。管理 UI が応答してもブラウザの証明書名警告が出る場合は、node CA と証明書設定を個別に確認してください。実行中の boot 中に DHCP lease が変わる場合、`/etc/hosts` の追随は次の boot または `pve-cluster` 再起動時です。

## カーネル

- installer と installed OS は Proxmox `pve-kernel` **7.0.14-30** + t2linux patch set をベースにした `proxmox-kernel-7.0.14-30-pve-t2` を使用します。release tag は `kernel-7.0.14-30-pve-t2-r1`、kernel version は `7.0.14-30-pve-t2` です。
- ISO は PVE T2 image deb を優先し、headers / signed-template / meta deb は除外します。旧 `linux-image-*.deb` は移行用 fallback です。`/t2/debs/` には image deb だけを格納します。
- first-boot は起動中の kernel が `*-pve-t2` または互換 `*-t2-pve` でなければ停止します。GRUB は stock PVE kernel を fallback として残し、version-specific T2 kernel ID を既定に pin します。
- ISO の installer initrd は storage、filesystem、T2/input、USB/Thunderbolt/network、crypto の必要 modules と依存だけを収録し、200 MiB のサイズ上限を検査します。依存 module を追加するときは `scripts/installer-modules.txt` を更新します。
- first-boot readiness では T2BCE modules と `modinfo zfs` も検査します。root filesystem は ext4 + LVM-thin、thin pool は `pve/data` です。

## リポジトリ構成

```text
.
├── .github/workflows/  # build-kernel.yml / build-iso.yml
├── docs/               # VM dry-run / 手動パーティション手順
├── firmware/           # ファームウェアの SHA-256 目録のみ
├── scripts/            # カーネル、ISO、初回起動の処理
├── preseed.cfg         # 自動インストール
└── preseed-manual.cfg  # 手動パーティション install
```

## 既知の制約とリスク

- root と swap は LVM LV ではなく通常パーティションです。
- 既存 ESP は再利用・変更せず、別の ESP を作る設計です。実ディスク上での共存動作は未検証です。
- MacBookPro15,1 の T2 実機での EFI 起動、画面表示、各デバイス動作は未検証です。カーネル設定のアサートや VM 成功だけで実機動作を保証するものではありません。
- 旧 mainline ISO の CI8/CI10 VM 検証は、新しい PVE T2 kernel ISO の検証結果ではありません。新経路のフル ISO build、auto/manual VM install、installed T2 kernel / T2BCE / ZFS readiness は未検証です。実機動作も未検証です。
- 初回の Proxmox パッケージ導入にはネットワーク接続が必要です。有線 IPv4 default route が見つからない場合は first-boot が明示的に失敗し、`/var/log/first-boot-proxmox.log` に理由を記録します。
- 公開 CI ISO には Apple ファームウェアがありません。無線デバイスの動作を保証しません。
- Debian の current point release が変わると、再ビルド ISO の内容やインストーラ挙動も変わる可能性があります。

## 過去の mainline ISO 検証記録 (2026-11-21; 新しい PVE kernel 経路には適用されません)

- GitHub Actions run **44922625539**（commit **16798c5**）で ISO をビルド。ISO SHA-256: `f8655a1a7a1372bca972038fc1872eb3240f86105a98bea64b498aa1ec4bde2e`。artifact ZIP と抽出 ISO のチェックサムは PASS。
- ISO preflight は PASS。main initrd に preseed はなく、`preseed-initrd.cpio` と `initrd-t2auto` を確認。combined initrd を使うのは T2 自動インストール項目だけで、stock 項目は preseed-free。日本語の locale/language 行があり、root/user パスワードは preseed されていません。
- 新規 64 GiB NVMe の UEFI/OVMF・シリアルコンソール VM でインストーラ完了まで PASS。GRUB CLI から `initrd-t2auto` で起動し、言語・地域・locale・keyboard・timezone・anna の各質問はなく、対話入力は root パスワード（確認入力を含む）のみ。QEMU は `-no-reboot` で停止し、インストール済み OS は起動していません。
- オフライン検査では p1/p2 のマーカーと PARTUUID を保持し、p3 vfat、p4 ext4、p5 swap、p6 ext4、p7 LVM2_member を確認。VG `pve` は 1 PV / 0 LV、空き 33,290,190,848 bytes。T2 kernel/initrd、first-boot service、SSH 設定、locale/keyboard/timezone、hostname、および `/tmp/t2-debs` 不在も確認。`GRUB_DEFAULT=0` と T2 kernel が先頭の生成済み GRUB 項目を確認しましたが、first-boot script による GRUB pin は実行・検証していません。
- 操作者による最初の GRUB キー入力は中断され、後の余分な tab/input で一時インストーラーメニューへ戻りましたが、インストーラを再開して完了しました。コード障害は観測されていません。

検証の詳細と境界（CI10 の GRUB pin failure、ID path 修正、狭い QEMU/OVMF boot smoke、および別件の `iptables-restore` 警告）は [docs/vm-dryrun.md](docs/vm-dryrun.md#ci10-grub-pin) を参照してください。

## VM での確認

preseed の VM ドライラン、既存パーティションの保持確認、オフライン検査の具体的な手順は [docs/vm-dryrun.md](docs/vm-dryrun.md) を参照してください。
