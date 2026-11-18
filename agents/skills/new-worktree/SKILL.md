---
name: new-worktree
description: Spin a small, newly called-out piece of work off this chat into its own branch and worktree, then move this very chat there (resumed in the worktree's tmux session with its next task already sent, the pane here closed). Use on /new-worktree [name], "spin this off", "own branch for that", or when something small and separable surfaces mid-initiative.
---

Give the thing just called out its own branch, worktree and tmux session beside the main checkout, then move this chat into it: the conversation resumes there with its next prompt already sent, and the pane here closes. The user runs nothing and pastes nothing. The worktree is light: env files copied, ports allotted, nothing installed, no LFS models, unless the user asks for a heavier base.

## 1. Decide the inputs from the chat

- Repo: `ROOT=$(git rev-parse --show-toplevel)` in this chat's working directory. `wt` finds the main checkout from any worktree of the repo.
- Base ref, in this order:
  1. a branch or ref the user named;
  2. this chat's branch, when the new work needs commits that exist only here (it builds on changes made on this branch that are not on main). Pass `--from "$(git branch --show-current)"`;
  3. otherwise the remote main: run `git fetch -q origin main` (skip silently when it fails), pass no `--from`, and `wt` uses `origin/main`.
- Branch name: the user's, else make one up. Short kebab-case, 2 to 4 words that say what it is: `fix-expo-port-banner`, `tidy-env-pull-log`. A `feat/` prefix is fine (`wt` turns `/` into `-` for the directory and session name). No `.` or `:`.

## 2. Create it with wt

```sh
OUT=$(wt new "$ROOT" --branch "$BRANCH" --from "$BASE" --json)   # drop --from for the remote main
```

Read `path`, `branch`, `from`, `ports_block`, `ports`, `env_copied` and `env_rewritten` from the JSON. `wt` creates the directory beside the main checkout, writes `.env.ports` for the next free block, copies main's gitignored env files (never `.env.ports`, `.env.branch`, generated or rendered ones), rewrites `.env.local` to the new block, skips LFS smudge and sets `lfs.fetchexclude` for the models path. If the branch already exists `wt` checks it out instead, and rejects `--from`: drop it and run again. If `wt` refuses with `target exists` and that directory is a worktree on the branch you meant (`git -C <dir> branch --show-current`), it was created earlier for this same thing: use it as `WT` and go on to step 3. Exit codes: 2 usage, 5 refused (target exists, branch checked out elsewhere, symlinked env file in main), 6 no free port block, 1 other. On any other failure report `wt`'s error line and stop.

## 3. Write your next prompt, then hand the chat over

The prompt is the first thing you read when you wake up in the worktree, so write it to yourself: where you are (path, branch, base), the small thing to do, where it lives in the code, what done looks like, and anything this chat decided that it must honor. Three to eight lines. Then, as the last tool call of this turn:

```sh
WT=$(jq -r .path <<<"$OUT")
F=$(mktemp -t new-worktree)
cat >"$F" <<'MSG'
Continuing in <path> on <branch>, cut from <base>, port block <k>. Task: ...
MSG
chat-move "$WT" --message-file "$F"
```

`chat-move` (`git/.local/bin`, on PATH) returns at once with `this claude chat moves to session <name> ... when this turn ends`. Reply with one line, such as `moving this chat to <name>`, and end the turn. A worker under the tmux server then creates the session named after the worktree directory (the picker's own naming) when it is missing, opens a shell window in it, types `claudef --resume <this session>` (or `pif --fork <this session file>`) with your prompt as the first message, answers Claude Code's trust dialog for the new directory, waits for the agent to come up, and closes this pane. The whole conversation is there. The user's view is not switched; the picker shows the new session on the worktree's row.

If `chat-move` fails before returning (no `$TMUX_PANE`, not a claudef or pif chat, missing directory), report its error and leave the worktree in place: the user can open it with `prefix o`. If the worker fails later, it leaves this pane alone, shows a message on it, and logs to `~/.local/state/chat-move/log`.

## 4. Not unless asked

- No `pnpm install`, `pod install` or any other install.
- No LFS models. Only when the user asks for a heavy or native-build base: `git -C "$WT" lfs pull -I 'packages/native-tools/ios/Models/**'` (served from the local LFS store when main has them).
- No files in the new worktree beyond what `wt` writes. No commits.

## 5. Nothing else to report

Your one-line reply is the whole report. The user has no handoff to paste and no client to switch. The facts (path, branch, base, ports, env files copied) belong in the prompt you wrote for the new chat, where they are needed.
