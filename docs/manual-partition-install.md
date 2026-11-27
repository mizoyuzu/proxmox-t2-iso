# 手動パーティションでの T2 Proxmox インストール

この経路は Debian Installer の **Manual** パーティション画面で、利用者が対象ディスクと区画を選びます。partman の自動ディスク選択や安全 guard は使いません。macOS/Ubuntu の領域に影響するおそれがあるため、必ず使い捨て VM で確認してください。実機・実ディスクでの実行は、所有者が明示的に承認するまで禁止です。

## 推奨レイアウト

macOS 側で APFS を縮小して未割当領域を作り、**既存 GPT を維持**します。新しい partition table を作らず、空き領域だけに次を作成します。

| 用途 | サイズ | 種類 / FS | mount point |
| --- | ---: | --- | --- |
| 新しい ESP | 512 MiB | EFI System Partition / FAT32 | `/boot/efi` |
| `/boot` | 2 GiB | ext4 | `/boot` |
| swap | 4 GiB | swap area | - |
| root | 24–32 GiB | ext4 | `/` |
| Proxmox 用 PV | 残り全部 | physical volume for LVM | - |

macOS の ESP は再利用・フォーマットしないでください。`/boot` には T2 kernel と stock PVE kernel を併存させるため 2 GiB を確保します。root は plain ext4 とし、LUKS / ZFS root は対象外です。

## インストール手順

1. ISO の GRUB メニューで **Manual partition install (T2 Proxmox)** を選びます（hotkey `m`）。通常の Debian **Install** は既定のままで、自動でこの経路に入りません。
2. locale / network / mirror は preseed されます。root password は installer で対話入力します。ネットワークは USB/Thunderbolt 有線 Ethernet と DHCP を想定します。
3. Partition disks で **Manual** を選択します。既存の GPT と macOS/Ubuntu 区画を保持し、未割当領域だけに上表の区画を作成します。
4. ESP の use as を EFI System Partition にし、mount point を `/boot/efi` にします。ext4 区画は format を有効にして `/boot` と `/` に割り当て、swap は swap area にします。
5. 残りは **physical volume for LVM** として設定します。LVM configuration で VG `pve` を作成し、可能なら LV は作らず空き extents を残します。VG を作らなかった場合、late setup は VG 未所属 PV がちょうど 1 個のときだけ VG `pve` を作成します。
6. 区画・mount point を見直し、**Finish partitioning and write changes to disk** を選びます。これ以降の T2 kernel / initramfs / GRUB / systemd 設定は自動です。

手動 late setup は `/target`、`/target/boot`、`/target/boot/efi` の mount と target の swap entry を検証します。既存 VG `pve` がある場合は `pve/data` がまだ無く、free extent があることを確認します。VG が無い場合は VG 未所属 PV が一つだけであることを確認し、ファイルシステム署名のある PV は変更しません。曖昧・不完全な LVM 構成では停止し、レイアウトを修正してインストールをやり直してください。

## 自動インストールとの違い

- `t` の **Automated install** は `/dev/nvme0n1` の最大 free extent を利用し、partman guard で選択先・容量を検査します。
- `m` の **Manual partition install** は guard と `partman-auto/*` の設定を使わず、利用者が partman UI で区画を作成します。
- 両方の経路は同じ T2 initrd を共有し、preseed cpio に `preseed.cfg` と `preseed-manual.cfg` を一度ずつ収録します。
- 初回起動には有線 IPv4 / DNS 接続が必要です。PVE パッケージ導入、thin pool 作成、vmbr0 の設定を行います。

インストール後の VM 検査は [VM dry-run 手順](vm-dryrun.md)を参照してください。確認すべき kernel は `7.0.14-30-pve-t2`、管理 readiness では T2BCE modules と `zfs` module も検査します。
