# proxmox-t2-iso

MacBookPro15,1 (Apple T2) 向けに、Debian 13 netinst ISO をリマスターし、T2 パッチ済み mainline カーネルを導入した後、初回起動で Proxmox VE を構成するためのリポジトリです。

> **実機インストールは所有者の判断があるまで凍結中です。** 検証は GitHub Actions と VM ドライランのみで行います。実機や実ディスクでインストーラ/preseed を実行しないでください。preseed の設計・期待値は以下に記しますが、実際の挙動は [VM ドライラン手順](docs/vm-dryrun.md)で確認してください。

## ビルド方針

- カーネルは `config-fragment.txt`、`config-required.txt`、`scripts/build-kernel.sh`、`build-kernel.yml` などカーネル関連ファイルを変更したまとまりごとに一度だけビルドします。通常は既存 Release **`kernel-6.18.56-t2-pve`** を再利用します。
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
gh release download kernel-6.18.56-t2-pve --pattern '*.deb' --dir debs
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
- 自動インストールは GRUB の `--hotkey=t` エントリを明示的に選択した場合のみ実行します。起動引数は `auto=true priority=critical preseed/file=/preseed.cfg` です。
- BIOS/isolinux 側のエントリ名は `t2auto` です。

### preseed のディスク設計

以下は確定設計です。最終 preseed の F テストを使い捨て VM ディスクで実施した記録は [VM ドライラン](docs/vm-dryrun.md)を参照してください。最終リマスター ISO の CI ビルドと VM 起動確認は別途実施後に記録します。

- インストール対象は `/dev/nvme0n1`、partman の選択方法は `biggest_free` です。`partman-auto/method` は設定しません。
- 新しいパーティションを空き領域に作ります。既存 ESP を再利用せず、既存の LVM/MD を削除しません。
- レシピは新規 ESP 512 MB、`/boot` 1536 MB、swap 4096 MB、root 20480 MB ext4、残り全部を `method{ lvm }` の予約パーティションとします。
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

- Proxmox VE の `pve-no-subscription` リポジトリと署名鍵を設定し、`proxmox-ve`、`postfix`、`open-iscsi`、`chrony`、`ifupdown2` を導入。
- VG `pve` の存在を必須確認し、その空き extents の 100% から thin pool `pve/data` を作成して `local-lvm` として登録。
- インストール済み T2 カーネルを GRUB の **Parent>Title** 形式でデフォルト固定し、`GRUB_TIMEOUT=10` に設定。削除対象は Debian の `linux-image-amd64` メタパッケージのみ。
- 有線 NIC を使う `vmbr0` 設定を作成し、Proxmox 関連サービスと SSH を enable。

初回起動スクリプトは自動で再起動しません。処理ログは `/var/log/first-boot-proxmox.log` に記録されます。

## カーネル

- mainline Linux **6.18.56** に `linux-t2-patches` の **6.18** ブランチを適用します。パッチ 24 件の適用は `patch-apply-verification-6.18.56.txt` に記録されています。
- `defconfig` と T2 側 `extra_config` に `config-fragment.txt` をマージし、`config-required.txt` の各設定をビルド前にアサートします。
- `FB_EFI` と framebuffer/console の依存チェーン、PVE 用 nftables/ipset/bridge/cgroup 機能を設定・検査します。
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
- MacBookPro15,1 の T2 実機での EFI 起動、画面表示、各デバイス動作は未検証です。カーネル設定のアサートだけで実機動作を保証するものではありません。
- 実機インストールおよび実機検証は未実施です。まず VM で partman の配置、既存 p1/p2 の保持、インストール後のファイルと LVM を確認してください。
- 初回の Proxmox パッケージ導入にはネットワーク接続が必要です。有線 NIC が認識されない場合、`vmbr0` は作成されません。
- 公開 CI ISO には Apple ファームウェアがありません。無線デバイスの動作を保証しません。

## VM での確認

preseed の VM ドライラン、既存パーティションの保持確認、オフライン検査の具体的な手順は [docs/vm-dryrun.md](docs/vm-dryrun.md) を参照してください。
