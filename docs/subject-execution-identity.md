# Subject execution identity

Production executors separate executor-owned control operations from customer-controlled repository execution with a dedicated operating-system identity.

The production image declares:

- `RUNDIFF_SUBJECT_UID`
- `RUNDIFF_SUBJECT_GID`
- `RUNDIFF_SUBJECT_HOME`
- `RUNDIFF_SUBJECT_USER`

The four values are an all-or-nothing account contract. The UID and GID must be positive, the subject UID must differ from the executor UID, and the declared account home path must be absolute. Local development remains unchanged when none of the variables are present.

Customer-controlled Bundler/package-manager execution, Rails preparation, explicit process services, behavioral capture, and capture descendants use this identity. Executor-owned Git/worktree operations and installation of the exact Bundler tool version remain outside it.

Customer execution does not use the shared account home as writable state. For each active worktree RunDiff creates a subject-owned `tmp/rundiff/home` and sets `HOME` to that path. `USER` and `LOGNAME` remain the declared subject user. Baseline and candidate therefore cannot communicate through package-manager caches, dotfiles, or other mutable home-directory state.

Baseline and candidate use the same subject UID/GID but never have writable workspaces at the same time. Each side is activated immediately before its lifecycle and sealed back to the executor in an `ensure` path before the next side becomes writable. The execution parent remains executor-owned and non-writable to the subject identity; capture outputs are pre-created for the active side and sealed back after capture.

This boundary is a prerequisite for production container-service authority. It does not itself enable Compose or expose a Docker socket/runtime credential to the executor container.
