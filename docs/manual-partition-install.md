# 手動パーティションでの T2 Proxmox インストール

この経路は Debian Installer の **Manual** パーティション画面で、利用者が対象ディスクと区画を選びます。partman の自動ディスク選択や安全 guard は使いません。macOS/Ubuntu の領域に影響するおそれがあるため、必ず使い捨て VM で確認してください。実機・実ディスクでの実行は、所有者が明示的に承認するまで禁止です。

## 推奨レイアウト

macOS 側で APFS を縮小して未割当領域を作り、**既存 GPT を維持**します。新しい partition table を作らず、空き領域だけに次を作成します。

| 用途 | サイズ | 種類 / FS | mount point |
| --- | ---: | --- | --- |
| 新しい ESP | 512 MiB | EFI System Partition / FAT32 | `/boot/efi`* |
| `/boot` | 2 GiB | ext4 | `/boot` |
| swap | 4 GiB | swap area | - |
| root | 24–32 GiB | ext4 | `/` |
| Proxmox 用 PV | 残り全部 | physical volume for LVM | - |

macOS の ESP は再利用・フォーマットしないでください。`/boot` には T2 kernel と stock PVE kernel を併存させるため 2 GiB を確保します。root は plain ext4 とし、LUKS / ZFS root は対象外です。

* `/boot/efi` は新しい ESP の推奨 mount point です。ただし Apple hardware では Debian の `archdetect` が `amd64/mac` を返し、`lib/partman/fstab.d/efi` が早期終了するため、ESP がインストール中に実際には mount されず、`/etc/fstab` にも追加されないことがあります。これは想定された挙動です。macOS の既存 ESP は絶対に再利用・フォーマットせず、新しく作成した ESP を使ってください。

## インストール手順

1. ISO の GRUB メニューで **Manual partition install (T2 Proxmox)** を選びます（hotkey `m`）。通常の Debian **Install** は既定のままで、自動でこの経路に入りません。
2. locale / network / mirror は preseed されます。root password は installer で対話入力します。ネットワークは USB/Thunderbolt 有線 Ethernet と DHCP を想定します。
3. Partition disks で **Manual** を選択します。既存の GPT と macOS/Ubuntu 区画を保持し、未割当領域だけに上表の区画を作成します。
4. 新しい ESP の use as を EFI System Partition にし、推奨 mount point `/boot/efi` を指定します。Apple hardware では Debian が ESP を実際には mount しないことがありますが、これは正常です。grub-installer は ESP に bootloader をインストールします。macOS の既存 ESP は再利用・フォーマットしないでください。ext4 区画は format を有効にして `/boot` と `/` に割り当て、swap は swap area にします。
5. 残りは **physical volume for LVM** として設定します。この設定だけでは PV は初期化されません。partman の **Configure the Logical Volume Manager** を少なくとも一度開くと PV が `pvcreate` されます。その上で、Configure LVM 内で VG `pve` を作成し LV は作らず空き extents を残す方法を推奨します。別案として Configure LVM を一度開いて PV を初期化し、VG には割り当てず終了すれば、late setup が VG 未所属 PV をちょうど 1 個検出して VG `pve` を作成します。Configure LVM を一度も開かないと PV が存在せず、late setup は停止します。
6. 区画・mount point を見直し、**Finish partitioning and write changes to disk** を選びます。これ以降の T2 kernel / initramfs / GRUB / systemd 設定は自動です。

手動 late setup は `/target` と `/target/boot` の mount、および target の swap entry を検証します。`/target/boot/efi` の mount は要求しません。Apple hardware では Debian の `archdetect` が `amd64/mac` を返し、`lib/partman/fstab.d/efi` が早期終了するため、partman-efi は ESP を fstab に追加せず、インストール中に mount しないことがあります。これは想定された挙動で、grub-installer は ESP に bootloader をインストールします。既存 VG `pve` がある場合は `pve/data` がまだ無く、free extent があることを確認します。VG が無い場合は、Configure LVM で初期化済みの VG 未所属 PV がちょうど一つあるときだけ VG `pve` を作成します。PV が未初期化、候補が複数、またはファイルシステム署名がある場合は変更せず停止します。曖昧・不完全な LVM 構成では状態を修正してからインストールを再開してください。

## 自動インストールとの違い

- `t` の **Automated install** は `/dev/nvme0n1` の最大 free extent を利用し、partman guard で選択先・容量を検査します。
- `m` の **Manual partition install** は guard と `partman-auto/*` の設定を使わず、利用者が partman UI で区画を作成します。
- 両方の経路は同じ T2 initrd を共有し、preseed cpio に `preseed.cfg` と `preseed-manual.cfg` を一度ずつ収録します。
- 初回起動には有線 IPv4 / DNS 接続が必要です。PVE パッケージ導入、thin pool 作成、vmbr0 の設定を行います。

インストール後の VM 検査は [VM dry-run 手順](vm-dryrun.md)を参照してください。確認すべき kernel は `7.0.14-30-pve-t2`、管理 readiness では T2BCE modules と `zfs` module も検査します。
