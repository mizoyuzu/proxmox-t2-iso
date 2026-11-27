# Upstream T2BCE patch: PR preparation notes

**Status: preparation only. No fork or pull request has been created. Owner approval is required before publishing or submitting anything upstream.** This note records the rationale and the evidence to assemble after the kernel build and VM checks complete.

## Proposed destination and scope

- Repository: [Ken5998/pve-edge-kernel-t2](https://github.com/Ken5998/pve-edge-kernel-t2)
- Intended change: update its `T2.patch` for the T2BCE driver/configuration names used by the pinned t2linux patch set. Keep the request limited to kernel flavor/configuration integration; the ISO remaster, installer preseed, firmware, and this repository's deployment scripts are out of scope.
- Planned source pins: Proxmox `pve-kernel` commit `1cc9d3c72dff80f433cf090707c52c477d920540`; `t2linux/linux-t2-patches` commit `7214248ed18659d576cc3a7feda20329d1eefc6f`.

## Rationale and source evidence

The target repository builds Proxmox VE 9 kernels with additional patches for T2 Macs. The pinned t2linux patch tree contains `1001-Add-t2bce-driver-stack.patch` and `1002-Integrate-t2bce-driver-stack.patch`, and its `extra_config` uses `CONFIG_T2BCE_CORE`, `CONFIG_T2BCE_VHCI`, `CONFIG_T2BCE_AUDIO`, `CONFIG_T2BCE_DMA`, and `CONFIG_T2BCE_AVE`. The target's current `master/T2.patch` still requests `CONFIG_APPLE_BCE`; that is the stale integration point to replace because it does not enable the new T2BCE module stack. The current target patch already sets the `-pve-t2` release suffix and several T2 options, so compare the exact upstream base and avoid redundant hunks when preparing the change.

References (review these again against the exact source revisions before submitting):

- [Ken5998/pve-edge-kernel-t2](https://github.com/Ken5998/pve-edge-kernel-t2) — destination project and its Proxmox/T2 kernel purpose.
- [Ken5998's current `T2.patch`](https://github.com/Ken5998/pve-edge-kernel-t2/blob/master/T2.patch) — target baseline; currently contains `CONFIG_APPLE_BCE` and already uses the `-pve-t2` release suffix.
- [t2linux/linux-t2-patches at the pinned revision](https://github.com/t2linux/linux-t2-patches/tree/7214248ed18659d576cc3a7feda20329d1eefc6f) — includes the T2BCE driver stack and integration patches.
- [t2linux PR #51, “Replace apple-bce with t2bce”](https://github.com/t2linux/linux-t2-patches/pull/51) — upstream context for replacing the monolithic apple-bce integration with t2bce.
- [Pinned `extra_config`](https://github.com/t2linux/linux-t2-patches/blob/7214248ed18659d576cc3a7feda20329d1eefc6f/extra_config) — reference for T2BCE symbol names.

## Expected semantic `T2.patch` delta

The exact patch file and hunk context must be reviewed from W1's built branch before preparing a PR. Against the target `master/T2.patch` inspected for this note, the semantic delta is to replace the stale BCE option and add missing T2BCE modules:

```diff
debian/rules.d/config-amd64.opts:
--m CONFIG_APPLE_BCE
+-m CONFIG_T2BCE_CORE
+-m CONFIG_T2BCE_VHCI
+-m CONFIG_T2BCE_AUDIO
+-m CONFIG_T2BCE_DMA
+-m CONFIG_T2BCE_AVE
+-m CONFIG_APPLE_GMUX
+-m CONFIG_HID_MAGICMOUSE
+-m CONFIG_SENSORS_APPLESMC
+-e CONFIG_STAGING
```

The target file already has `-m CONFIG_HID_APPLETB_BL`, `-m CONFIG_HID_APPLETB_KBD`, `-m CONFIG_DRM_APPLETBDRM`, `-m CONFIG_BT_HCIBCM4377`, and `-m CONFIG_APFS_FS`; retain those existing settings rather than duplicating them. Its Makefile already has `EXTRAVERSION=-$(KREL)$(KREL_EXTRA)-pve-t2`; only add a suffix hunk if the exact upstream base used for the PR does not. Compare Proxmox's base config and add other missing support symbols only when the pinned source/config verification demonstrates they are absent. Do not retain `CONFIG_APPLE_BCE` as a substitute for the T2BCE modules. The target package release is `7.0.14-30-pve-t2`.

## Evidence required before proposing the PR

- [ ] Exact base/source commit IDs and resulting `T2.patch` SHA-256.
- [ ] Reviewed patch diff (`git diff --check`, full diff, and summary); no unrelated local installer changes.
- [ ] Successful pinned PVE kernel build log and package names, including the `-pve-t2` release.
- [ ] Extracted kernel `.config` showing each required T2BCE option is `=m`, and no stale `CONFIG_APPLE_BCE` dependency.
- [ ] Package module listing containing `t2bce_core.ko`, `t2bce_vhci.ko`, `t2bce_audio.ko`, `t2bce_dma.ko`, and `t2bce_ave.ko`; attach the relevant `modules.dep` excerpt.
- [ ] `tests/run-all.sh` result and the kernel configuration/package verifier result.
- [ ] Remastered ISO inspection result and disposable QEMU evidence for installer kernel, initrd module availability, first-boot, and post-reboot PVE checks. State explicitly that QEMU does not validate physical T2 hardware.
- [ ] Evidence contains no Apple firmware binary, password, token, or other secret.

Keep logs, config excerpts, checksums, and screenshots in the approved evidence location; do not commit large build outputs or Apple firmware to the public repository. Replace this checklist's pending items with exact artifact paths and hashes after the owner reviews the build results.

## Submission gate

1. W1 supplies the exact `T2.patch`, build log, config excerpt, and module evidence; Qoder reviews the diff and verification result.
2. The owner reviews the proposed diff and evidence and explicitly approves publishing/submission.
3. Only after that approval, prepare a fork/branch and open a PR against `Ken5998/pve-edge-kernel-t2`. Do not create a PR from this task or imply that a PR is already open.

Suggested draft title: **`Update T2 kernel config for T2BCE modules`**.
