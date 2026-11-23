# proxmox-t2-iso

MacBookPro15,1 (Apple T2) 向けに、Debian 13 netinst ISO をリマスターし、T2 パッチ済み mainline カーネルを導入した後、初回起動で Proxmox VE を構成するためのリポジトリです。

> **実機インストールは所有者の判断があるまで凍結中です。** 検証は GitHub Actions と VM ドライランのみで行います。実機や実ディスクでインストーラ/preseed を実行しないでください。preseed の設計・期待値は以下に記しますが、実際の挙動は [VM ドライラン手順](docs/vm-dryrun.md)で確認してください。

## ビルド方針

- カーネルは `config-fragment.txt`、`config-required.txt`、`scripts/build-kernel.sh`、`build-kernel.yml` などカーネル関連ファイルを変更したまとまりごとに一度だけビルドします。通常は Release **`kernel-6.18.56-t2-pve-r3`** を再利用します。
- ISO はマイルストーン時のみビルドします。ドキュメントや小さな変更のたびにカーネル/ISO のフルビルドは行いません。
- `build-kernel.yml` は成功した場合のみ artifact と Release を公開します。ISO workflow は Release からカーネル `.deb` を取得します。

## 必要なツールと ISO の作成

リマスターに必要な主なコマンドは `xorriso`、`cpio`、`fakeroot`、`kmod`（`depmod`）、`python3`、`gzip`、`md5sum` と `dpkg-deb` です。`gh` は既存カーネル Release から `.deb` を取得する場合に使います。Debian/Ubuntu では `dpkg-deb` は `dpkg` パッケージに含まれます。

Debian 13 amd64 netinst ISO と `linux-image-*.deb` を用意し、次のように実行します。

```sh
DEBIAN_ISO=/path/debian-13.x-amd64-netinst.iso \
KERNEL_DEB_DIR=/path/debs \
  ./scripts/remaster-iso.sh out.iso
```

Release からカーネルパッケージを取得する例:

```sh
mkdir -p debs
gh release download kernel-6.18.56-t2-pve-r3 --pattern '*.deb' --dir debs
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
- preseed は `/install.amd/preseed-initrd.cpio` に分離し、`/install.amd/initrd-t2auto` を「小さな preseed cpio + `/install.amd/initrd.gz`」として作ります。この combined initrd を使うのは、GRUB の `--hotkey=t` エントリと BIOS/isolinux の `t2auto` エントリだけです。起動引数は `auto=true priority=critical preseed/file=/preseed.cfg` です。
- stock の **Install** / **Graphical install** / **Advanced options** は通常の `initrd.gz` または `gtk/initrd.gz` を使い、T2 用 preseed は読み込みません。Debian 標準の **Advanced > Automated install** は、このリポジトリの T2 自動インストールではありません。

### preseed のディスク設計

以下は現在の設計です。CI8 の ISO ビルドと VM ドライランはこの guard と GTK カーネルの組み合わせ修正より前に実施しました。既存領域の保持とレシピ配置の過去証跡は [CI8 最終検証](docs/vm-dryrun.md#ci8-最終検証結果-2026-11-21)、guard の block-device を使わない fixture 検証は [partman guard の説明](docs/vm-dryrun.md#partman-の対象ディスク-guard)を参照してください。これらの変更を含む ISO のビルドと VM 再検証は別途必要です。

- インストール対象は `/dev/nvme0n1`、partman の選択方法は `biggest_free` です。`partman-auto/method` は設定しません。
- Debian 13.8 の `biggest_free` は、method を設定しない構成では `partman-auto/disk` を候補絞り込みに使わず、全ディスクから最大の空き領域を選びます。T2 preseed は `partman/early_command` から `display.d/09t2guard` を入れ、書き込み前に最大領域のデバイスが GPT の `/dev/nvme0n1` であることと、`pve-final` のサイズを検証します。他のディスクや USB インストーラは接続できますが、その空き領域が最大ならインストールを停止します。
- 新しいパーティションを空き領域に作ります。既存 ESP を再利用せず、既存の LVM/MD を削除しません。
- レシピは新規 ESP 512 MB、`/boot` 1536 MB、swap 4096 MB、root 20480 MB ext4、残り全部を `method{ lvm }` の予約パーティションとします。
- guard は Debian の recipe decoder で必要サイズと有限拡張を計算します。現在のレシピは `/boot` が最大 512 MB 拡張され、その後の空きが pve PV に入ります。PV 用に 32 MiB（8 extents）と最後の partition alignment 用に 4 MiB を残し、足りない場合は partman の自動処理が始まる前に戻ります。
- Debian `expert_recipe` の MB は 10^6 bytes 単位で、parted の MiB/GiB 表示とは異なります。VM での実測表示は、レシピ 512 MB に対して 488.0 MiB、1536 MB に対して 1.4 GiB、4096 MB に対して 3.8 GiB、20480 MB に対して 19.1 GiB でした。
- partman はこのレシピだけでは VG を作りません。`late_command` が udev の `ID_PART_ENTRY_TYPE` が `E6D6D379-F507-44C2-A23C-238F2A3DF928`（Linux LVM）の予約パーティションを特定し、`pvcreate` / `vgcreate pve` を実行します。
- この方式では root と swap は通常パーティションであり LV ではありません。thin pool は初回起動時に VG の空き 100% から `pve/data` として作ります。

## late_command の責務

インストーラの `late_command` は、設計上、次の処理を行います。

1. 予約パーティションから LVM PV と VG `pve` を作成。
2. `first-boot-proxmox.sh` と `first-boot-proxmox.service` をインストール先へ配置。
3. ISO 内の T2 カーネル `.deb` を in-target でインストールし、`/boot/vmlinuz-*` と initrd の存在を確認。
4. `ssh.service` と `first-boot-proxmox.service` を enable。
5. `/etc/ssh/sshd_config.d/10-t2.conf` に `PermitRootLogin yes` と `PasswordAuthentication yes` を設定。任意の鍵を指定した場合は `/root/.ssh/authorized_keys` に配置。
6. ローカル ISO に含まれる場合のみ、ファームウェアを `/target/lib/firmware/brcm/` へ配置。

処理失敗を握りつぶさないよう `set -e` で停止させる設計です。パスワード、秘密鍵、Wi-Fi 認証情報を preseed やスクリプトへ平文で書きません。

## SSH とネットワーク

- SSH ログインは、インストーラの対話画面で設定する root パスワードを基本経路とします。作成するユーザーは root のみです。SSH はインストール直後から有効にする設計です。
- 鍵ログインを選ぶ場合に限り `SSH_AUTHORIZED_KEYS_FILE` を指定します。秘密鍵は ISO に入れず、パスワードも文書・preseed に記載しません。
- インストーラのネットワークは USB/Thunderbolt 有線 Ethernet アダプタを前提とします。Wi-Fi SSID/認証情報を preseed しません。
- 初回起動スクリプトは有線 NIC を選び、インストーラが設定した NIC の DHCP stanza を退避したうえで `/etc/network/interfaces.d/vmbr0` に `vmbr0`（DHCP、`bridge-ports <nic>`）を作成します。有線 NIC が見つからない場合は bridge 設定をスキップするため、初回起動時に有線接続が必要です。
- Proxmox Web UI: `https://<IP>:8006/`。ホスト名は `pve-mbp`、FQDN は `pve-mbp.local` です。名前解決は LAN の環境にも依存します。

## 初回起動の Proxmox 構成

`first-boot-proxmox.service` がネットワーク起動後に `first-boot-proxmox.sh` を一度実行します。成功時に `/var/lib/first-boot-proxmox.done` marker を作り、失敗時は成功扱いにしません。初回処理にはネットワーク接続が必要です。

スクリプトの処理内容:

- Proxmox VE の `pve-no-subscription` リポジトリと署名鍵を設定し、`proxmox-ve`、`postfix`、`open-iscsi`、`chrony`、`ifupdown2` を導入。`pve-manager` が作る標準の `pve-enterprise.sources` stanza は初回 apt 更新前とパッケージ導入後に無効化します。無関係な apt source と旧式の `.list` ファイルは変更しません。
- VG `pve` の存在を必須確認し、その空き extents の 100% から thin pool `pve/data` を作成して `local-lvm` として登録。
- インストール済み T2 カーネルを GRUB の **Parent>Title** 形式でデフォルト固定し、`GRUB_TIMEOUT=10` に設定。削除対象は Debian の `linux-image-amd64` メタパッケージのみ。
- 有線 NIC を使う `vmbr0` 設定を作成し、Proxmox 関連サービスと SSH を enable。

初回起動スクリプトは自動で再起動しません。処理ログは `/var/log/first-boot-proxmox.log` に記録されます。

## カーネル

- mainline Linux **6.18.56** に `linux-t2-patches` の **6.18** ブランチを適用します。パッチ 24 件の適用は `patch-apply-verification-6.18.56.txt` に記録されています。
- `defconfig` と T2 側 `extra_config` に `config-fragment.txt` をマージし、`config-required.txt` の各設定をビルド前にアサートします。
- `FB_EFI` と framebuffer/console の依存チェーン、PVE 用 nftables/ipset/bridge/cgroup 機能を設定・検査します。
- PVE の `local-lvm` 用に `CONFIG_DM_THIN_PROVISIONING=m` (`dm-thin-pool`) と依存モジュールを含めます。パッケージリビジョン 2 はこのカーネル設定の修正です。旧 r1 は first-boot の thin pool 作成に使えません。
- `CONFIG_FUSE_FS=y` は pmxcfs (`pve-cluster` が `/etc/pve` を mount) と lxcfs に必須です。r2 は FUSE が欠落していたため first-boot の `pve-cluster` 起動に失敗し、first-boot を完了できません。FUSE を含む r3 が最初の first-boot 可能リリースです。
- T2 Mac の内蔵 SSD は標準 NVMe として扱います。`BLK_DEV_NVME` を使用し、Apple Silicon 向け `NVME_APPLE` は使いません。
- このカーネルは Proxmox の PVE カーネルそのものではなく、mainline + T2 patches に PVE ホスト用設定を加えたものです。ZFS は対象外で、ストレージ設計は ext4 + LVM-thin です。

## リポジトリ構成

```text
.
├── .github/workflows/  # build-kernel.yml / build-iso.yml
├── docs/               # VM ドライラン手順
├── firmware/           # ファームウェアの SHA-256 目録のみ
├── scripts/            # カーネル、ISO、初回起動の処理
├── config-fragment.txt # カーネル設定 fragment
├── config-required.txt # 必須カーネル設定のアサート一覧
└── preseed.cfg         # Debian Installer の自動インストール設定
```

## 既知の制約とリスク

- root と swap は LVM LV ではなく通常パーティションです。
- 既存 ESP は再利用・変更せず、別の ESP を作る設計です。実ディスク上での共存動作は未検証です。
- MacBookPro15,1 の T2 実機での EFI 起動、画面表示、各デバイス動作は未検証です。カーネル設定のアサートや VM 成功だけで実機動作を保証するものではありません。
- CI10 の r3 VM では first-boot の PVE 構成、thin pool、SSH、管理 endpoint は PASS でしたが、GRUB pin は FAIL し、Boot 2 で標準 PVE kernel が選ばれました。生成済み PVE メニューから pin 先を導出する修正を追加しましたが、修正版の VM 再検証は未実施です。CI8 の新規インストール VM では OS を起動していません。実機動作も未検証です。
- 初回の Proxmox パッケージ導入にはネットワーク接続が必要です。有線 NIC が認識されない場合、`vmbr0` は作成されません。
- 公開 CI ISO には Apple ファームウェアがありません。無線デバイスの動作を保証しません。
- Debian の current point release が変わると、再ビルド ISO の内容やインストーラ挙動も変わる可能性があります。

## CI8 最終検証 (2026-11-21)

- GitHub Actions run **44922625539**（commit **16798c5**）で ISO をビルド。ISO SHA-256: `f8655a1a7a1372bca972038fc1872eb3240f86105a98bea64b498aa1ec4bde2e`。artifact ZIP と抽出 ISO のチェックサムは PASS。
- ISO preflight は PASS。main initrd に preseed はなく、`preseed-initrd.cpio` と `initrd-t2auto` を確認。combined initrd を使うのは T2 自動インストール項目だけで、stock 項目は preseed-free。日本語の locale/language 行があり、root/user パスワードは preseed されていません。
- 新規 64 GiB NVMe の UEFI/OVMF・シリアルコンソール VM でインストーラ完了まで PASS。GRUB CLI から `initrd-t2auto` で起動し、言語・地域・locale・keyboard・timezone・anna の各質問はなく、対話入力は root パスワード（確認入力を含む）のみ。QEMU は `-no-reboot` で停止し、インストール済み OS は起動していません。
- オフライン検査では p1/p2 のマーカーと PARTUUID を保持し、p3 vfat、p4 ext4、p5 swap、p6 ext4、p7 LVM2_member を確認。VG `pve` は 1 PV / 0 LV、空き 33,290,190,848 bytes。T2 kernel/initrd、first-boot service、SSH 設定、locale/keyboard/timezone、hostname、および `/tmp/t2-debs` 不在も確認。`GRUB_DEFAULT=0` と T2 kernel が先頭の生成済み GRUB 項目を確認しましたが、first-boot script による GRUB pin は実行・検証していません。
- 操作者による最初の GRUB キー入力は中断され、後の余分な tab/input で一時インストーラーメニューへ戻りましたが、インストーラを再開して完了しました。コード障害は観測されていません。

検証の詳細と境界（CI10 の GRUB pin failure、修正内容、未実施の再検証、および別件の `iptables-restore` 警告）は [docs/vm-dryrun.md](docs/vm-dryrun.md#ci10-grub-pin) を参照してください。

## VM での確認

preseed の VM ドライラン、既存パーティションの保持確認、オフライン検査の具体的な手順は [docs/vm-dryrun.md](docs/vm-dryrun.md) を参照してください。
