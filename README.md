# proxmox-t2-iso — T2 Mac 向け Debian+Proxmox インストーラ ISO ビルド

目的: MacBookPro15,1 (MBP-ubuntu) に、T2 カスタムカーネル＋Wi-Fi/BT ファームウェア自動配置込みの
Debian 13 (Trixie) をインストールし、その上に Proxmox VE 9 を載せるための ISO を組む。
計画全体は ~/workspace/proxmox-mbp-plan.md を参照。インストール実行は試験後 (2026-11-26–27 以降)。
ISO のビルド自体は MBP に変更を加えないので先行してよい (Mitaさん 2026-11-21)。

## 実測で確定した素材 (2026-11-21)

- ファームウェア: MBP-ubuntu の /lib/firmware/brcm は 281 ファイル / 19MB。
  全ファイルの sha256 目録を firmware/brcm-sha256sums.txt に保存済み。
  - Wi-Fi (BCM4364): brcmfmac4364b2/b3-pcie.apple,<board>.* が非圧縮で存在 (ekans/hanauma/kahana/
    kauai/lanai/maui/midway/nihau/sid, bali/borneo/kure/trinidad 等)
  - Bluetooth (BCM4377b3): brcmbt4377b3-apple,formosa.bin/.ptb
  - Apple 固有ファイルは非圧縮なので Debian 側へそのままコピーできる (汎用分は .zst だが不要)。
  - ビルド時に MBP から tar で吸い出すか、この目録と照合して同梱する。
- カーネルのバージョン状況 (2026-11-21 に git ls-remote で確認):
  - pve-kernel (git.proxmox.com): trixie 向けブランチは trixie-6.14 / trixie-6.17。PVE 9 の土台は 6.14/6.17 系。
  - linux-t2-patches (t2linux): バージョン別ブランチは 6.18 と 7.3 (他 main 等)。MBP の現行カーネルは 7.3.4-3-t2 / 6.18.5-t2。
  - **バージョンの谷間**: pve の 6.17 と t2 パッチの 6.18/7.3 が一致しない。ここがビルド方式の分岐点。

## カーネルビルド方式の候補

- 方式A (低リスク本命): mainline 6.18 / 7.3 ソース + linux-t2-patches (対応ブランチあり、
  実機で起動実績のある系統) に、Proxmox カーネルの config を土台として不足分を補う。
  ZFS は組み込みにならないが、本計画は LVM-thin / ext4 で ZFS を使わないので実害なし。
  proxmox-default-kernel パッケージは依存関係のため入れたまま、ブートは pin で T2 カーネルに固定。
- 方式B (理想・高コスト): pve-kernel 6.17 ソースに t2 パッチ (main / 6.18 ブランチ) を rebase。
  ZFS 組み込みと Proxmox パッチ系列をそのまま保てるが、パッチ競合の解消作業が発生する。
- 判定は中間段階 (50GB) のスモークテスト (VM 1台 + LXC 1台 + Jellyfin トランスコード) で行う。

## ISO の構成

1. 公式 Debian 13 netinst ISO をリマスター (xorriso で展開・再構築、EFI 保持)。
2. ブート用カーネル / initrd をカスタムカーネルに差し替え。initrd に apple-bce, NVMe (ans),
   SPI キーボード/トラックパッド等のモジュールと Wi-Fi ファームウェアを含める。
3. preseed: partman は最大の連続空き領域を自動選択し、VG pve の LVM レシピで入れる。
   既存の macOS / Data / Ubuntu には触らない。→ preseed.cfg (下書き)
4. 追加パッケージ置き場: カスタムカーネル .deb、t2fanrd、tiny-dfr、オーディオ設定、
   modules-load / modprobe quirk、ファームウェア配置 (late_command で /target/lib/firmware/brcm へ)。
5. Proxmox 化は初回起動スクリプト (first-boot) に分離: PVE リポジトリ追加、proxmox-ve 導入、
   公式カーネルのブート pin 外し、vmbr0 作成。

## 決定済み

- カーネルビルドの実行場所: **GitHub Actions** (Mitaさん決定 2026-11-21)。
  パイプラインは .github/workflows/build-kernel.yml + scripts/build-kernel.sh。
- パッチ適用の検証済み (2026-11-21): linux-6.18.56 に対し 6.18 ブランチの全 24 パッチが
  無競合で適用できた (patch-apply-verification-6.18.56.txt)。対象は方式A で確定。
- 残作業: GitHub へ push するには Mita さんの GitHub 認証が要る (gh は未ログイン)。
  リポジトリを作成して push すれば、Actions の手動実行で初回ビルドが回る。
