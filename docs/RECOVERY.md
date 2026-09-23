# Recovery and removal

Existing native profile directories are adopted in place. Removing their registration in Profile Deck leaves their files, login, history and shared sources unchanged. The canonical memory owner cannot be unregistered until ownership is handed over explicitly.

Instruction edits use an expected-content hash and private recovery record. Restore refuses to overwrite later edits. Configuration recovery is scoped to managed non-secret keys, not a complete profile snapshot. Restore does not reverse external account actions.

When shared-source paths conflict, inspect the originals and compare them before applying a change. Do not merge whole profile homes. Missing cloud-backed workspaces remain unavailable until the original mount returns.

Quit Profile Deck to stop its observers. Native work continues independently.
Disable its launch-at-login option and remove the companion application using
normal macOS application removal. Preserve native clients, adopted launchers,
shared workspaces, memories, skills and plugin caches.

Manager-owned data in Application Support can be moved to Trash separately after reviewing any handoff drafts or recovery records worth retaining. Do not delete the canonical shared home or any provider profile as part of companion removal.
