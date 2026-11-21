# AGENTS.md — proxmox-t2-iso

MacBookPro15,1 (T2) 向け Proxmox VE インストール用、カスタムカーネル付き
Debian 13 リマスターISO のビルドリポジトリ。

## エージェント体制 (所有者指定, 2026-11-21 改訂)

Codex はアカウント側の制限で使えないため、体制は以下に変更された。

- **主担当: Qoder CLI / DeepSeek-Flash** (T3 Code プロバイダ acpRegistry_qoder_cli)
  設計判断、タスク分解、レビュー、最終確認を担う。原則として自分では
  ファイルを編集せず、ワーカーの成果をレビューして指示を出す。
- **実作業: OpenCode / exe.dev Gateway の GPT-6 Luna (Responses API、
  reasoning = high)** (モデル slug: exedev-gpt/gpt-6-luna)
  ファイル編集、スクリプト修正、CI実行とログ確認などの具体作業を担う。
  作業はブランチ fix/review-2026-11-21 上で行う。
- 現在のタスクは `REVIEW-FIXES.md` にまとまっている。着手前に必ず読むこと。

## 安全ルール (厳守)

- 実機 (MBP-ubuntu) や実ディスクに対してインストーラや preseed を実行しない。
  検証は GitHub Actions と VM ドライランのみ。
- Apple ファームウェアのバイナリをこの公開リポジトリにコミットしない
  (チェックサム目録のみ。再配布条件が未確認のため)。
- パスワードや秘密情報を preseed やスクリプトに平文で書かない。
- main ブランチへ直接 push しない。作業ブランチで進め、マージは所有者が判断する。
