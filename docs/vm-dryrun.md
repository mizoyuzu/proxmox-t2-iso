# preseed の VM ドライラン

この手順は Debian Installer のパーティション配置、既存パーティションの保持、インストール先のファイル、LVM の状態をオフラインで確認するためのものです。**実機・実ディスクでは実行しないでください。** すべての書き込み先は使い捨ての VM ディスクイメージに限定します。

2026-11-21 に、使い捨て 64 GiB GPT ディスクと UEFI QEMU で final preseed の F テストを実施しました。p1/p2 の保持、p3–p7 の作成、partman の追加ダイアログがないこと、`late_command` による p7 の `pvcreate` / `vgcreate pve`、空き extents 7937 × 4 MiB（31.00 GiB）を確認済みです。最終リマスター ISO の CI ビルド、VM インストーラ完了、およびオフライン検査の結果は、この文書末尾の [CI8 最終検証結果](#ci8-最終検証結果-2026-11-21)に記録しています。

## 1. ホスト要件

Debian/Ubuntu の Linux ホストを使用します。必要な主なツール/パッケージ:

```sh
sudo apt-get update
sudo apt-get install -y qemu-system-x86 qemu-system-gui ovmf parted gdisk xorriso \
  util-linux kmod dosfstools e2fsprogs lvm2
```

- `OVMF_CODE` と `OVMF_VARS` は OVMF の UEFI ファームウェアです。Debian/Ubuntu では `/usr/share/OVMF/OVMF_CODE_4M.fd` と `/usr/share/OVMF/OVMF_VARS_4M.fd` が一般的ですが、実際のファイル名は `find /usr/share/OVMF -maxdepth 1 -type f` で確認してください。
- KVM が利用できない場合、QEMU の例にある `accel=kvm` を `accel=tcg` に、`-cpu host` を `-cpu max` に変更します。TCG は低速です。
- インストール対象 ISO は、このリポジトリの remaster workflow で生成した ISO を指定します。

## partman の対象ディスク guard

Debian 13.8 の `partman-auto/automatically_partition/20biggest_free/choices` は、`$DEVICES` 全体を走査して最大の free extent を返します。`partman-auto/disk=/dev/nvme0n1` は、`partman-auto/method` を設定しない `biggest_free` の選択肢を絞り込みません。そこで T2 preseed は `partman/early_command` から guard を `/lib/partman/display.d/09t2guard` に配置します。Debian の display hook 順では `09t2guard` は `10initial_auto` より先に動くため、partman が自動パーティションを作成する前に検査できます。

Guard は Debian の実際の `biggest_free/choices` を呼び、選ばれた partman device が GPT の `/dev/nvme0n1` か確認します。さらに Debian の recipe decoder で `pve-final` の最低サイズと、min より大きい factor を持つ有限パーティションの拡張量を計算します。現行レシピでは `/boot` に最大 512 MB を先に割り当てます。残りの PV に 32 MiB（8 extents）と最終パーティションの alignment 用 4 MiB、合計 36 MiB を確保できない場合、guard は exit 255 で自動処理を止めます。エラーは installer log に記録され、ディスク構成を直してから再試行できます。

他ディスクや USB インストーラの接続自体は許可します。Debian が `/dev/nvme0n1` 以外を最大 free extent と判断した場合は、書き込みを始める前に停止します。この guard の fixture 検証は block device を使いません:

```sh
./tests/test-partman-t2-guard.sh
```

これは partman hook の wrong-device / 容量不足時の exit 255 と、条件を満たす対象 disk の許可を確認する shell fixture です。QEMU の実際の partman ドライランは次の手順で別途実施します。

## 2. 64 GiB のテストディスクを作る

以下の `DISK` は新規の一時ファイルです。実ディスクのデバイス名（例: `/dev/nvme0n1`）を絶対に指定しないでください。

```sh
DISK=/tmp/t2-preseed-dryrun-64g.raw
truncate -s 64G "$DISK"

# 新しい空ファイルだけに対して GPT を作成: p1=200 MiB EFI、p2=8 GiB Linux filesystem
sgdisk --clear \
  --new=1:2048:+200M --typecode=1:ef00 --change-name=1:Existing-EFI \
  --new=2:0:+8G    --typecode=2:8300 --change-name=2:Existing-Linux \
  "$DISK"
sgdisk --print "$DISK"
```

既存の macOS/Ubuntu 領域がある状況を模擬するため、p1 を FAT32、p2 を ext4 にし、保持確認用ファイルを置きます。Linux loop device のパーティションデバイスを使います。

```sh
LOOP=$(sudo losetup --find --show --partscan "$DISK")
echo "$LOOP"  # 例: /dev/loop0。以降、同じシェルで変数を使う
sudo partprobe "$LOOP"
sudo udevadm settle
sudo mkfs.fat -F 32 "${LOOP}p1"
sudo mkfs.ext4 -F "${LOOP}p2"
sudo mkdir -p /mnt/t2-dryrun/p1 /mnt/t2-dryrun/p2
sudo mount "${LOOP}p1" /mnt/t2-dryrun/p1
sudo mount "${LOOP}p2" /mnt/t2-dryrun/p2
echo 'keep p1' | sudo tee /mnt/t2-dryrun/p1/DRYRUN-P1.txt >/dev/null
echo 'keep p2' | sudo tee /mnt/t2-dryrun/p2/DRYRUN-P2.txt >/dev/null
sudo umount /mnt/t2-dryrun/p2 /mnt/t2-dryrun/p1
sudo losetup -d "$LOOP"
```

これはファイルシステムとマーカーファイルを持つ p1/p2 を用意するだけです。macOS の実データや実際の macOS/APFS 起動環境を再現するものではありません。

## 3. OVMF + NVMe で ISO を起動

ISO と OVMF のパスを環境に合わせます。OVMF の可変領域はテンプレートをコピーして使い、共有テンプレートを QEMU から直接書き換えないでください。

```sh
ISO=/path/to/debian-13-t2-proxmox.iso
DISK=/tmp/t2-preseed-dryrun-64g.raw
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
OVMF_VARS=/tmp/OVMF_VARS-t2-dryrun.fd
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 8G -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive if=none,id=installcd,file="$ISO",media=cdrom,readonly=on \
  -device ide-cd,drive=installcd \
  -drive if=none,id=t2disk,file="$DISK",format=raw \
  -device nvme,drive=t2disk,serial=T2DRYRUN0001 \
  -boot order=d,menu=on \
  -display gtk -serial mon:stdio
```

`-display gtk` は UEFI/GRUB とインストーラ画面用、`-serial mon:stdio` は QEMU のシリアル接続/モニタ用です。この ISO の通常の GRUB エントリに serial kernel console 引数が含まれるとは限らないため、インストーラ画面は GTK 側で操作してください。QEMU モニタに切り替えるにはシリアル端末で `Ctrl-A` の後 `C` を押します。

起動後、GRUB の通常 **Install** がデフォルトであることを確認します。自動インストールを試す場合は、GRUB の `t` ホットキーを明示的に押して `Automated install (T2 Proxmox)` を選択します。通常 Install を選んだままタイムアウトさせると、自動インストールにはなりません。

T2 用 preseed は小さな `/install.amd/preseed-initrd.cpio` に分離され、`/install.amd/initrd-t2auto` はその cpio と `/install.amd/initrd.gz` を連結した initrd です。GRUB の T2 自動インストール項目と BIOS/isolinux の `t2auto` だけがこれを使います。stock の Install / Graphical install / Advanced options は main または gtk initrd を使うため preseed を受け取りません。Debian 標準の **Advanced > Automated install** は T2 用の自動インストール項目ではありません。

シリアルコンソールで自動インストールを試す場合は、GRUB メニューで `c` を押してコマンドラインを開き、次のように起動します。

```text
linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg console=ttyS0,115200n8 --- quiet
initrd /install.amd/initrd-t2auto
boot
```

シリアルコンソールでは Debian Installer が言語候補を display level 0 に絞るため、通常の候補は C/英語だけです。preseed は `localechooser/languagelist=ja` を質問に直接設定するので、`debian-installer/language=ja` だけでは不足するシリアルを含め、どのコンソールでも言語質問をスキップします。CI8 の最終ビルドと VM ドライラン結果は、この文書末尾の [CI8 最終検証結果](#ci8-最終検証結果-2026-11-21)を参照してください。

インストーラでは root パスワードを対話入力します。パスワードは記録・共有せず、preseed に追加しません。自動エントリでインストールを完了した後は、インストール済み OS を初回起動する前に VM を poweroff してください。QEMU モニタで `system_powerdown` を実行するか、インストーラの電源オフ操作を使います。first-boot のネットワーク処理を走らせず、インストール直後の状態をオフラインで確認します。

## 4. オフライン検証

QEMU を終了してテストディスクが使用されていないことを確認してから、loop device に再接続します。以下の管理者権限が必要な操作には `sudo` を付けています。

```sh
DISK=/tmp/t2-preseed-dryrun-64g.raw
LOOP=$(sudo losetup --find --show --partscan "$DISK")
sudo partprobe "$LOOP"
sudo udevadm settle

# MiB 表示で全パーティションと free space を確認
sudo parted -s "$LOOP" unit MiB print free
sudo sgdisk -i 1 "$LOOP"
sudo sgdisk -i 2 "$LOOP"
sudo sgdisk -i 7 "$LOOP"
```

### 2026-11-21 の実測値

Debian `partman-auto/expert_recipe` のサイズ指定は decimal MB（1 MB = 10^6 bytes）です。以下の MiB/GiB は `parted` 等で確認した binary 単位の表示で、レシピ値とは数値が一致しません。

| 番号 | 用途 | レシピ値 / 初期値 | VM での実測 |
| --- | --- | --- | --- |
| p1 | 既存 ESP | 200 MiB | 200 MiB、保持。PARTUUID は前後で不変 |
| p2 | 既存 Linux filesystem | 8192 MiB | 8192 MiB、保持。PARTUUID は前後で不変 |
| p3 | 新規 ESP | 512 MB | 488.0 MiB。p1 を再利用しない |
| p4 | `/boot` | 1536 MB | 1.4 GiB |
| p5 | swap | 4096 MB | 3.8 GiB |
| p6 | root ext4 | 20480 MB | 19.1 GiB |
| p7 | LVM 予約領域 | 残り全部 | 31.0 GiB、`LVM2_member` |

p7 は Linux LVM type GUID `E6D6D379-F507-44C2-A23C-238F2A3DF928` で、VG `pve` は 1 PV / 0 LV、`VFree` 31.00 GiB でした。空き extents は 7937 × 4 MiB です。p1/p2 の保持は PARTUUID が前後で不変であることでも確認しました。

### p1/p2 の保持

既存領域が上書きされていないことを、パーティション情報と作成したマーカーの両方で確認します。

```sh
sudo mkdir -p /mnt/t2-dryrun/p1 /mnt/t2-dryrun/p2
sudo mount -o ro "${LOOP}p1" /mnt/t2-dryrun/p1
sudo mount -o ro,noload "${LOOP}p2" /mnt/t2-dryrun/p2
sudo cat /mnt/t2-dryrun/p1/DRYRUN-P1.txt
sudo cat /mnt/t2-dryrun/p2/DRYRUN-P2.txt
sudo umount /mnt/t2-dryrun/p2 /mnt/t2-dryrun/p1
```

両方のマーカーが読め、`parted`/`sgdisk` で p1/p2 のサイズ・種類が変わっていないことを確認します。

### VG と空き extents

初回起動前の状態で p7 の PV/VG が `pve` として存在し、thin pool 用の空き extents が残ることを確認します。ホストに同名 `pve` VG がある場合は名前衝突の危険があるため、この操作を行わず、同名 VG のない使い捨て Linux 検証環境を使ってください。

```sh
PART7="${LOOP}p7"
sudo pvscan --cache --devices "$PART7"
sudo vgchange --devices "$PART7" -ay pve
sudo pvs --devices "$PART7" -o pv_name,vg_name,pv_size,pv_free
sudo vgs --devices "$PART7" -o vg_name,vg_size,vg_free,vg_free_count pve
sudo lvs --devices "$PART7" -a -o vg_name,lv_name,lv_attr,lv_size pve
```

`pve` VG と正しい p7 PV が表示され、VG に空き extents が残っていることが期待値です。first-boot をまだ実行していないため、`pve/data` thin pool はこの時点では作成されていない想定です。

### インストール先のファイル

この設計では root は通常パーティション p6、`/boot` は p4 です。読み取り専用で mount して T2 カーネルと first-boot/SSH のファイルを確認します。

```sh
ROOT=/mnt/t2-dryrun/root
sudo mkdir -p "$ROOT"
sudo mount -o ro,noload "${LOOP}p6" "$ROOT"
sudo mount -o ro "${LOOP}p4" "$ROOT/boot"

# vmlinuz と対応する initrd が /boot に存在すること
sudo find "$ROOT/boot" -maxdepth 1 -type f \
  \( -name 'vmlinuz-*-t2-pve' -o -name 'initrd.img-*-t2-pve' \) -print

sudo test -f "$ROOT/etc/systemd/system/first-boot-proxmox.service"
sudo test -f "$ROOT/etc/ssh/sshd_config.d/10-t2.conf"
sudo test -f "$ROOT/usr/local/sbin/first-boot-proxmox.sh"
sudo grep -E '^(PermitRootLogin|PasswordAuthentication)[[:space:]]+yes$' \
  "$ROOT/etc/ssh/sshd_config.d/10-t2.conf"

sudo umount "$ROOT/boot" "$ROOT"
sudo vgchange --devices "$PART7" -an pve
sudo losetup -d "$LOOP"
```

`find` の結果に `vmlinuz-*-t2-pve` と `initrd.img-*-t2-pve` の両方があり、`test` がすべて成功することを確認します。確認に失敗した場合は記録を残して調査し、実機には進まないでください。

## 5. 片付け

loop device が切り離され、QEMU が停止していることを確認します。テストディスクと OVMF vars は使い捨ての `/tmp` ファイルです。実ディスクやホストの LVM を操作・削除しないでください。

## CI8 最終検証結果 (2026-11-21)

以下は最終 CI ISO を使った使い捨て VM ドライランの記録です。証跡ファイルはユーザー指定の `proxmox-t2-iso-vmtest` evidence bundle にあります。検証対象は ISO の preflight、Debian Installer の完了、インストール済みディスクのオフライン状態までです。

### CI artifact と ISO preflight — PASS

- GitHub Actions run **44922625539**、build commit **16798c5**。ISO SHA-256 は `f8655a1a7a1372bca972038fc1872eb3240f86105a98bea64b498aa1ec4bde2e`。artifact ZIP と抽出 ISO の両方でチェックサム PASS。
- Preflight PASS: ISO root と main initrd に `/preseed.cfg` はなく、main initrd の `/dev/console` と `/dev/null` は character device。`preseed-initrd.cpio` は `preseed.cfg` のみで、日本語用 `localechooser/languagelist` / `debian-installer/language` 行を含み、root/user password は preseed していません。
- `initrd-t2auto` は `preseed-initrd.cpio` に main initrd を連結したもの。combined initrd を使うのは T2 自動インストール項目だけで、stock Install / Graphical install / Advanced options は preseed-free であることを確認。

### VM installer — PASS

- 新規の使い捨て **64 GiB NVMe** ディスクを UEFI/OVMF と serial console を使う QEMU VM に接続。GRUB CLI で `auto=true priority=critical preseed/file=/preseed.cfg console=ttyS0,115200n8 --- quiet` と `initrd /install.amd/initrd-t2auto` を指定して起動しました（完全な QEMU invocation は `run-qemu-ci8.sh`）。
- 言語、location、locale、keyboard、timezone、anna の質問は表示されず、対話入力は root password とその確認入力のみでした。インストーラは完了して reboot を要求。
- QEMU の `-no-reboot` により要求時に VM が停止したため、インストール済み OS は起動していません。first boot も行っていません。
- 操作上の異常: 最初の GRUB キー入力は中断。後の余分な tab/input で一時的にインストーラのメインメニューへ戻りましたが、インストーラを再開して完了しました。これは操作上の中断で、コード障害は観測されませんでした。

### インストール済みディスクの読み取り専用オフライン検査 — PASS

- p1/p2 の `DRYRUN-P1` / `DRYRUN-P2` marker と PARTUUID（それぞれ `D3BF572A-F2E3-4C98-8314-BF267884ABF5` / `80C42A46-7629-4401-87B3-D1A398A09C33`）を保持。
- Partition layout: p3 vfat、p4 ext4、p5 swap、p6 ext4、p7 LVM2_member。VG `pve`: 1 PV、0 LV、VFree **33,290,190,848 bytes**（first-boot 前の状態）。
- `6.18.56-t2-pve` kernel と initrd が存在し、`first-boot-proxmox.service` は enable 済み。SSH 設定は `PermitRootLogin yes` / `PasswordAuthentication yes`。locale `ja_JP.UTF-8`、keyboard `jp`、timezone `Asia/Tokyo`、hostname `pve-mbp` を確認し、`/tmp/t2-debs` は存在しません。
- インストール済み `/etc/default/grub` は `GRUB_DEFAULT=0` で、生成済み `grub.cfg` の先頭 entry は T2 kernel を指定。**first-boot script 内の GRUB pin は実行も検証もしていません**（installed OS を起動していないため）。

### 未検証事項とリスク

実機 T2 hardware は未検証です。公開 ISO に Apple firmware は含みません。インストール済み OS の boot、first-boot PVE provisioning、live SSH、`vmbr0`、first-boot による GRUB pin、および first boot は未検証です。Proxmox Web UI の動作も確認していません。Debian の current point release が変わった場合は ISO を再検証してください。

証跡一覧: `CI8-FINAL-REPORT.txt`、`CI8-PREFLIGHT.txt`、`CI8-CHECKSUMS.txt`、`CI8-SERIAL-CLEAN.txt`、`ci8-offline-checks.txt`、`ci8-late-command-evidence.txt`、`ci8-installed-grub-defaults.txt`、`ci8-installed-grub.cfg`、`ci8-installed-first-boot.sh`、`run-qemu-ci8.sh`。

<a id="ci10-grub-pin"></a>

## CI10 first-boot GRUB pin failure と修正 (2026-11-22)

r3 kernel/script の VM 検証では first-boot provisioning（`pve-cluster`、thin pool、SSH、PVE 管理 endpoint を含む）は完了しましたが、**GRUB pin は FAIL** でした。`/etc/default/grub` は `Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux 6.18.56-t2-pve` を選択していた一方、PVE 導入後に生成されたメニュー名は `Advanced options for Proxmox VE GNU/Linux>Proxmox VE GNU/Linux, with Linux 6.18.56-t2-pve` でした。そのため Boot 2 では T2 kernel ではなく、先頭の PVE kernel `7.0.14-30-pve` が選択されました。

原因は、インストール済み PVE の grub integration に合わせてメニューを再生成する前に、古い Debian メニューからタイトルを読み取っていたことです。以前の検証は `set default` が要求した文字列と一致することしか確認せず、現在のメニューに同じタイトルの non-recovery T2 entry があるかを確認していませんでした。最初の修正では表示タイトルを pin 先にしましたが、表示名は package operation 後に変わり得ます。

現在の `scripts/first-boot-proxmox.sh` は `/boot/grub/grub.cfg` の linux line から実際の `vmlinuz-<version>` を読み、`$menuentry_id_option` を使った `gnulinux-advanced-<bootid>>gnulinux-<version>-advanced-<bootid>` の組み合わせだけを受け入れます。generic `gnulinux-simple-*` ID は使いません。複数の T2 kernel があれば現在動作中の T2 version を優先し、そうでなければ GRUB の最初の version-specific T2 entry を選びます。GRUB default はネットワーク/APT より前に更新し、全 package operation 後に再生成・再検証します。古い `Parent>Title` default はこの手順で ID path に移行します。stock PVE kernel entry は GRUB 内に残るため、手動選択できます。

shell 回帰テストは古い Debian title default と PVE title の異なる menu を fixture にし、ID path への移行、複数 T2 version の選択、および title 変更後も同じ ID が解決することを確認します。合成 OVMF 検査では実際の GRUB 2.12 が Debian と Proxmox の異なる menu title で version-specific T2 ID を選ぶことを確認しました。続く QEMU/OVMF boot smoke では実 kernel binary を使い、Debian と PVE の menu title のどちらでも同じ ID path が `6.18.56-t2-pve` を起動し、`GRUB_DEFAULT=0` の control が `7.0.14-30-pve` を起動することを確認しました。これは GRUB の ID 解決と kernel 選択を検証する狭い boot test であり、full installer や更新後の first-boot service 全体の再検証ではありません。CI8 の full installer VM は引き続き installed OS を起動していません。今回の検査に実機または実ディスクは使用していません。同じ CI10 証跡には `pve-firewall: iptables-restore: unable to initialize table 'raw'` も記録されていますが、これは別の kernel 設定課題であり、今回変更していません。

証跡 bundle: `r4-firstboot-evidence/CI10-FIRSTBOOT-REPORT.txt`、`offline-boot1-grub-menu.txt`、`grub-after-boot1.cfg` / `grub-boot1-final.cfg`。
