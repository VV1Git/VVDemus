---
description: Remove throwaway probe apps, abandoned agent simulators, and the real app on simulators you aren't using
allowed-tools: Bash(.claude/scripts/cleanup-stray-apps.sh:*)
---

Run the stray-app sweep and report what it did.

```
!.claude/scripts/cleanup-stray-apps.sh $ARGUMENTS
```

Pass `--dry-run` to list without removing, or `--keep-recent N` to change how many simulators
hold on to the real app (default 2, plus any booted one).

What it removes, and nothing else:

- **Probe apps** — a bundle id this project does not declare and that is not on the protected
  list in `.claude/cleanup-keep.txt`. These are the throwaway projects a session scaffolds to
  test one behaviour and then abandons.
- **Agent simulators** — devices named `*agent*` that a worktree run created and left behind,
  as long as they are not booted.
- **The real app on simulators not in use** — it keeps the booted device and the most recently
  installed ones. This destroys those devices' app data, which is fine because a simulator's
  play history is test junk, and stale copies of a fixed-port server are actively misleading
  (see the note about port 51825 in `ios/SETUP.md`).

Simulators only. Nothing here can touch a physical device.

If it reports something you wanted to keep, add that bundle id to `.claude/cleanup-keep.txt`
rather than editing the script — that file exists precisely because "not declared in this repo"
is not the same as "junk".
