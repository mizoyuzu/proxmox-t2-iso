# T2 カーネルの更新と復旧

この文書は、Proxmox VE と共に運用する T2 対応カーネルの保護・更新手順です。対象は `proxmox-kernel-*-pve-t2`（現行形式）と `linux-image-*-t2-pve`（旧形式）です。実機に適用する前に、使い捨て VM で更新と起動を確認してください。

## バージョン体系

T2 カーネルのバージョンは PVE の base kernel バージョンに対応します。たとえば PVE base `7.0.14-30` に対する T2 カーネルの release は `7.0.14-30-pve-t2`、パッケージ名は `proxmox-kernel-7.0.14-30-pve-t2` です。実際の値は deb の package metadata と `/boot/vmlinuz-*` で確認します。

インストール時と first-boot の package 操作後に T2 kernel package を apt hold します。first-boot は version-specific な GRUB ID に既定値を固定し、最後に `/usr/local/sbin/t2-kernel-state.sh` で実行中カーネル、インストール済みパッケージ、hold、GRUB の対応を監査します。

## PVE base 更新時の T2 カーネル入れ替え

新しい PVE base に合わせた T2 kernel deb をビルドし、適用前に対応する kernel image と modules が揃っていることを検証します。既存版の rescue deb を消さず、VM で次の遷移を確認してから保守時間に実施します。

1. 現行の package 名・kernel release・GRUB ID path と rescue deb を記録します。新しい deb の package 名と `/boot/vmlinuz-<release>` が同じ release を示すことを確認します。
2. 現行 T2 package の hold を一時解除し、新 deb をインストールします。side-by-side で新旧両方を保持し、APT の変更内容を確認してから続行します。

   ```sh
   apt-mark unhold <旧T2-package名>
   apt-get install /path/to/proxmox-kernel-<新PVE-base>-pve-t2_<version>_amd64.deb
   apt-mark hold <旧T2-package名> <新T2-package名>
   ```

3. 新旧それぞれの `/boot/vmlinuz-*` と `/boot/initrd.img-*` が揃い、新しい package が installed で hold されていることを確認します。新しい T2 kernel entry が GRUB に生成されていることも確認します。
4. `/etc/default/grub` の `GRUB_DEFAULT` を新 kernel の version-specific ID path に変更します。`grub.cfg` から、`gnulinux-advanced-<boot-id>` submenu と `gnulinux-<新kernel-release>-advanced-<同じboot-id>` entry の組を選び、タイトル文字列や `gnulinux-simple-*` ID は使わないでください。変更後に `update-grub` を実行し、生成された `/boot/grub/grub.cfg` に同じ組と `vmlinuz-<新kernel-release>` があることを確認します。
5. 旧 deb は `/var/lib/t2/kernel/` に残し、旧 package もこの段階では削除しません。GRUB の既定値が新しい entry になっていることを再確認して再起動します。
6. 再起動後、`uname -r` が新 release であること、T2 デバイス・ネットワーク・PVE 管理機能が正常であることを確認します。その後、旧 package の hold を解除し、削除計画を確認してから旧 package だけを削除します。新 package は hold のままにします。最後に `t2-kernel-state.sh` を実行し、全項目が PASS であることを確認します。

   ```sh
   apt-mark unhold <旧T2-package名>
   apt-get remove <旧T2-package名>
   apt-mark showhold
   /usr/local/sbin/t2-kernel-state.sh
   ```

   `apt autoremove` は実行せず、旧 deb は復旧用に残します。

更新作業中は新旧 2 package が一時的に installed となるため、監査スクリプトの「T2 package はちょうど1つ」項目は旧版を整理するまで FAIL になります。再起動後の検証が済む前に旧 package を削除しないでください。

## hold の解除と再設定

hold は通常の APT upgrade/autoremove が T2 kernel package を更新・削除するのを防ぐ選択状態です。カーネルを更新するときだけ、対象 package を明示して一時解除します。

```sh
apt-mark showhold
apt-mark unhold <更新対象のT2-package名>
# deb をインストール・検証し、新しい GRUB ID に固定した後:
apt-mark hold <新しいT2-package名>
apt-mark showhold
```

更新後は hold が実際に設定されたことを `apt-mark showhold` で確認してください。hold はセキュリティ更新そのものではなく、更新・削除を抑止する保護です。新しい T2 kernel を用意していない状態で unhold のまま運用しないでください。

## レスキュー deb

インストール時に使用した kernel image deb は target の `/var/lib/t2/kernel/` に 0644 で保存されます。ディレクトリは 0755 です。ネットワークがない場合は対象の deb を指定して再インストールし、initramfs と GRUB を更新します。

```sh
dpkg -i /var/lib/t2/kernel/<保存されたkernel-deb名>.deb
update-initramfs -u -k <kernel-release>
update-grub
apt-mark hold <T2-package名>
apt-mark showhold
```

必要な依存 package がシステムに無い場合、`dpkg -i` は依存関係エラーになります。ネットワーク接続が戻ってから依存関係を解決してください。レスキュー deb を複数世代保管する場合、kernel image deb は容量が大きくなるため、`/boot` と root filesystem の空き容量を事前に確認してください。起動確認前の旧版 deb は削除しないでください。

監査だけ行う場合は、次を実行します。これは読み取り専用です。

```sh
/usr/local/sbin/t2-kernel-state.sh
```

## 禁止事項

- T2 kernel package を `apt autoremove` の対象にしないでください。特に GRUB が指す版を削除すると、起動できなくなるおそれがあります。
- hold したまま新しい deb で無理に置換したり、旧版を確認なしに削除したりしないでください。
- 一般の PVE kernel だけを残して T2 kernel を消さないでください。T2 hardware 対応と GRUB の pin を確認してから更新します。
- GRUB の表示タイトル、番号、`gnulinux-simple-*` を T2 kernel pin に使わないでください。
- 実機・実ディスクに対してインストーラや preseed を試さないでください。更新手順の初回確認には使い捨て VM を使います。
