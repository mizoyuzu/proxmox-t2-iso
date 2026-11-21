# レビュー指摘と修正タスク (2026-11-21)

このリポジトリは MacBookPro15,1 (T2) に Proxmox VE を入れるための
Debian 13 リマスターISO + T2カーネルビルド一式。
現状の到達点:

- カーネルビルド (build-kernel.yml) は成功。Release `kernel-6.18.56-t2-pve` 済み。
  linux-t2-patches 6.18ブランチの24件は linux-6.18.56 に無競合で当たることを検証済み。
- **ISOビルド (build-iso.yml) は失敗している** (下記 §0)。
- 外部レビューで「現状は実機インストールに使わない方がよい」と判定された。
  本書の指摘をすべて潰し、ISOビルドがグリーンになるまでがこのタスクのゴール。

実機インストールは所有者 (Mita) の大学入試 (2026-11-26〜27) の後まで凍結。
このタスクはリポジトリ内の修正とCI検証のみ。実機や実ディスクに対する操作は禁止。

## 0. ISOビルド失敗 (最優先で再現・修正)

- Run: https://github.com/mizoyuzu/proxmox-t2-iso/actions/runs/44901086102
- Remasterステップで exit code 2:

```
installer kernel: 6.18.56-t2-pve
cpio: dev/console: Cannot mknod: Operation not permitted
cpio: dev/null: Cannot mknod: Operation not permitted
```

- GitHub Actions の通常ユーザーでは initrd 展開時のデバイスノード作成ができない。
  `scripts/remaster-iso.sh` の initrd 展開/再梱包を、非rootでも通る方式に変えること
  (例: `cpio --no-create` 相当の工夫、fakeroot、rootでの実行、デバイスノードを
  含まない再梱包手順など、再現性のある方法を選ぶ)。

## 1. 優先ブロッカー (レビュー指摘)

### 1-1. LVM と EFI の設定が意図どおりにならない可能性が高い
- `preseed.cfg` は `biggest_free` を選びつつ LVM を指定しているが、この組み合わせでは
  通常の自動パーティション処理に入り、レシピの `$lvmok` が期待どおり使われない。
  VG `pve` が作られない構成になり得る。
- T2 Mac ではインストーラが既存 ESP を `/boot/efi` にマウントしない挙動が確認されている。
  既存の Ubuntu/macOS の起動への影響も含めて要検証。
- root LV を最大サイズ `-1` にすると、thin pool 用の空きが残らない。
  → partman の方式を明示的なものに直し、VG `pve` + root/swap + thin pool 用空きが
    残るレシピにすること。VMドライランで partman の挙動を確認できる形にすること。

### 1-2. インストール後に T2 カーネル等が入らない
- `scripts/remaster-iso.sh` が ISO に置くのは `t2/debs` と `t2/scripts`。
  一方 `preseed.cfg` の late_command は別パスからファームウェアや設定をコピーし、
  `/media/cdrom/t2/debs` から .deb を入れようとしている。パスが一致せず、
  失敗も `|| true` で見逃している。
- `first-boot-proxmox.sh` は ISO に置かれるが、実行・インストールする処理がない。
  → パスを一本化し、失敗を握りつぶさないこと。first-boot スクリプトが
    インストール先で確実に一度実行される仕組み (systemd unit 等) を入れること。

### 1-3. GitHub Actions 上で ISO 展開が失敗する
- §0 と同じ。加えて、ファームウェア取得先の `firmware-files/brcm` がリポジトリに無く、
  ISOビルド workflow に取得処理もない (リポジトリ内はチェックサム目録のみ)。
  → ファームウェアは公開リポジトリにバイナリをコミットしない方針を維持しつつ、
    ビルド時にどう供給するか (手元ビルド用パス / CIではファームウェア無しISOを明示、等)
    を設計し、README と workflow に明記すること。再配布条件が未確認のため、
    公開ISOへの同梱はしない。

### 1-4. カスタムカーネルで画面が映らない懸念
- `config-fragment.txt` は `CONFIG_FB_EFI=y` を指定するが、依存する
  framebuffer/console 設定が不足し、検証した 6.18 の設定では FB_EFI が有効にならなかった。
  → 依存チェーンごと有効化し、`config-required.txt` に画面表示系の必須設定を追加して
    ビルド時に落ちるようにすること。

## 2. 次に直したい点 (レビュー指摘)

- **自動インストールの安全性**: 先頭GRUB項目が5秒後に自動起動する。
  初期テストでは自動実行を外すか、対象を明示して確認できるようにする。
- **GRUB の T2 カーネル固定**: `first-boot-proxmox.sh` がネストされた submenu 内の
  エントリIDを `GRUB_DEFAULT` に設定する可能性があり、そのIDだけでは選択できない。
  `submenu>entry` 形式や grub-set-default 等、正しい方法に直すこと。
- **Proxmox 用カーネル設定**: nftables/IP set、bridge firewall、cgroup bandwidth など
  PVE の firewall・ネットワーク・リソース制御で使う機能の不足が残っている。
  `config-required.txt` を拡充すること。
- **再現性**: カーネル build workflow はビルド失敗時にも Release ステップへ進み得る。
  失敗時に止まるよう直すこと。
- preseed の early_command にある `modprobe nvme_apple` は誤り
  (NVME_APPLE は Apple Silicon 用。T2 の SSD は標準 NVMe = BLK_DEV_NVME)。
  ついでに除去/修正すること。

## 3. 所有者の決定 (2026-11-21、レビューへの回答)

- **ネットワークは有線LANを使う**。MBP15,1 に有線ポートはないが、
  USB/Thunderbolt 有線アダプタで接続する前提でよい。
  → インストール中の Wi-Fi は必須ではない。Wi-Fi の SSID/認証情報を
    preseed する必要はない (ファームウェア同梱は post-install 用に残してよい)。
- その代わり **インストール完了後に SSH でローカルLANから入れることが必須**:
  - openssh-server をインストールし有効化すること。
  - ログイン経路を明確にすること (root のSSH鍵を置く仕組みか、
    インストール時に対話で root パスワードを設定する方式か、どちらかに決めて
    preseed と README に明記)。
  - vmbr0 の設計は有線NIC前提でよい (Wi-Fi アップリンク前提の NAT 設計は不要)。
    `first-boot-proxmox.sh` の vmbr0 TODO は有線前提で埋めること。

## 4. 進め方

- 作業ブランチ `fix/review-2026-11-21` を切って進める。main へ直接 push しない。
- こまめにコミットし、ブランチは origin に push してよい。マージは所有者が判断する。
- 変更したら build-kernel / build-iso の両 workflow をそのブランチで回し、
  グリーンになるまで直すこと (gh CLI が使える)。
- 完了条件: build-iso が成功し、§1 のブロッカー4件すべてにコード上の対応が入り、
  preseed のVMドライラン手順が README か docs に残っていること。
