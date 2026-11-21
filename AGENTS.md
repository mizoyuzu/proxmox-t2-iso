# AGENTS.md — proxmox-t2-iso

MacBookPro15,1 (T2) 向け Proxmox VE インストール用、カスタムカーネル付き
Debian 13 リマスターISO のビルドリポジトリ。

## エージェント体制 (所有者指定, 2026-11-21 最終形)

- **オーケストレーションは Qoder CLI / DeepSeek-Flash (reasoning effort = Max)**
  が担う。設計判断、タスク分解、ワーカーの起ち上げと監視、レビュー、最終確認は
  すべて Qoder の仕事。
- **実作業ワーカーは Qoder 自身が T3 Code のスレッド機能で生やす**:
  プロバイダ opencode、モデル exedev-gpt/gpt-6-luna (exe.dev Gateway,
  Responses API)、reasoning = high。プロジェクトの opencode.json で
  build エージェントのデフォルトをこの構成にしてある。
  ワーカーごとに作業ブランチ + ワークツリーを割り当てること。
- 司令 (タスクの起点) は所有者/アシスタントから Qoder スレッドへ投げられる。
  Qoder 以外がワーカーを直接立てることはしない。
- 現在のタスクは `REVIEW-FIXES.md` にまとまっている。着手前に必ず読むこと。

## ビルド方針 (所有者指定)

- 変更のたびにカーネルビルド / ISOビルドを回さない (カーネルは1回約9分)。
- カーネルビルドはカーネル関連ファイル (config-fragment.txt /
  config-required.txt / scripts/build-kernel.sh / build-kernel.yml) の変更を
  まとめたときに1回だけ。それ以外は既存リリース kernel-6.18.56-t2-pve を再利用。
- ISOビルドはマイルストーン時のみ。途中確認はローカルの軽い検証で済ませる。
- フルビルドは最終確認で各1回が目安。

## 安全ルール (厳守)

- 実機 (MBP-ubuntu) や実ディスクに対してインストーラや preseed を実行しない。
  検証は GitHub Actions と VM ドライランのみ。
- Apple ファームウェアのバイナリをこの公開リポジトリにコミットしない
  (チェックサム目録のみ。再配布条件が未確認のため)。
- パスワードや秘密情報を preseed やスクリプトに平文で書かない。
- main ブランチへ直接 push しない。作業ブランチで進め、マージは所有者が判断する。
