# Worktree-native tmux (agent-first, worktree-first multiplexer)

Status: planning, opened 2026-10-30, revised 2026-10-31 after the user's first
feedback round (section "User feedback"). Nothing is built yet. This document
holds the user's intent verbatim, the findings, the open decisions and the
recommended approach. The concise recommendation goes back in chat; this file
is the contextful record. D2 is accepted; D1 changed to strict.

Related system docs (current behaviour, not plans):

- `docs/tmux-agent-sessions.md` (the picker behind `prefix o`, decisions D1-D83)
- `docs/tmux-remote-workspaces.md` (remote endpoints, the September 2026 slot removal)
- `docs/tasks/tmux-workspace-resurrection.md` (save/restore practices)

## User intent (verbatim, 2026-10-30)

> Top level goal:
> - dotfiles provides my personal Tmux configuration + multiplexer solution to agentic converstaion/worktree management were I need it to be easier to observe activity of agetns across tmux sessions that are WORKTREE based on different projects.
>
> Dotfiles tmux multiplexer agentic manggement rule ideas (looking for feedback on them):
> - I will refer to the bindkey + o menu as the "picker" which is our main control panel for switching threads / worktrees (tmux sessions and selecting / previewing windows as current)
> - (the core idea hinges on this) We should try to see if tmux sessions can now specific to a worktree / main checkout dir of a git project similar to how the picker currently shows worktrees and agregates their panes/windows by worktree grouping.
> - By enabling this the picker becomes a control panel / base of operations for seeing which worktrees are active, awiting input, finished, working, etc.
> - The picker should allow the following:
>     - Closing all panes / windows of a specific worktree and deleting the worktree from disk (with a warning if it has dirty git changes)
>     - Opening up a new workree for a specific project selected in the picker
> - Opening up a new worktree for a given project should:
>     - Add a new worktree to a centrealized folder for worktrees
>     - Pull all .env.* files to the new worktree from the source project dir (so that every worktree is equally capable of invesigative and development resource usage - without an agent saying "i dont have access to those keys" where the rule of thumb is - if its on the same machine / sandbox, the keys can be shared across worktrees - there is no securtiy reason to prevent this.
>     - Somehow for all ports used for dev server runnable things we should make an effort to have a practice where the ports are unique across ALL worktrees at all times in order to spin up dev servers without fear of conflict - this will likely be a .env file that projects pul from. That said - it might not be a good idea to make this project neutral. Keep in mind that the main project I use is this content-engine and it is the only one I ever really spin up multiple dev servers across worktrees forr - so perhaps this project can set the standard and the dotfiles can accept said standard as port balancing, and if I ever setup a new project that wants this capability, I can have it conform to dotfile's expected stadnard - which is whatever we make the content-engine project use initially.
> - The current content-engine project is currently messly distributed among multiple slot based worktrees which is NOT a good pattern and one this initiative looks to overwrite with simplicity of ephemeral ad hoc work / quick new work stream ethos of development. We need to move those slots into the new directory for ephemeral worktrees and identify which are stale and can be rid of as we look to start from a good setting for this initiative (use sonnet subagnet to comb through all this and see what will need to be done on this font)
>     - One thing the slot sytem DID do well was allow me to remember which slots have heavy build artifacts in their directories to be able to quickly spin up native builds (ios) and other kinds of things + the fact that LFS tries to download the llm model files at @packages/native-tools/ios/Models/ all the time right?
>     - We need to figure out a good rule of thumb for reuse of this kind of thing. A couple ideas: the worktree selection PICKER shows when a worktree has heavy build materials via certain criteria as a specific icon  / symbol next to its name, we could just use the main project dir as the heavy build - but there are many times when I want to develop on two native builds at once. Any other ideas ? If its just me being able to tell which worktrees have heavy build artifacts (ios dir, model files, even node_modules) i can decide which worktrees to override into new branches instead of clearing the directory (which in itself COULD be a capability along side adding and deleting worktrees! Please consider this)
> - There should be a hotkey to see all worktrees of all git projects (with or without tmux sessions) identified in my ~/Developer top level folder so I am able to close / delete / reopen those worktrees / projects lest they get lost / dead and block up storage
> - There should be ONE session that should be easily selectable (either a hotkey or always a item in the sesion list) in the picker needs to be a non project based home session -> meaning ANY windows in tmux I use EVER that are NOT tied to a project will be accessible and useable from this session.
> - We need to thnk about what happens if a home session window/pane is moved into a directory that is a git project - does that move the window then and there to a session for that worktree? What if the window has two panes - where both are in different worktrees / git projects?
>
> That is about it for the CORE needs I want for my mutliplexer setup to be much more agent AND worktree/git aligned / agent first + worktree first.
>
> There is also the idea that this should be EASILY workable with the docs/tmux-remote-workspaces.md where i can offload worktrees to remote machines and have panes pointing to said remote machines!
>
> Similarly, we need to enusre that whatever we build here CONTINUES to be supported by the docs/tasks/tmux-workspace-resurrection.md pracitices already built out
>
> Please come back to me with a final report of this initaitvie and how we should approach it, and your top level recommednations in a concise manner - with the more contextful planning matter / open decisions / findings documetned in a single @docs/tasks/worktree-native-tmux.md

Standing instruction for this initiative: opus subagents for investigation,
research and opinion feedback; a sonnet subagent for the content-engine
worktree audit. The user references
`~/Developer/content-engine-trees/content-engine-1` as the main checkout.

## User feedback (verbatim, 2026-10-31)

> For remote MIRROR agent will DEINFIETLY need a way to clean up worktrees that are shared with remote upon deletion from local.
>
> ```
> worktree
>   regardless of session (it already does)
> ```
> - I actually don't think that it does
> - For example this is my preview windows for the "feat/scheduling-init" session:
> - [screenshot: six window cards: 1 FUCKING PRS, 5 z, 12 lane-monitor, 1 braze, 1 z (selected, Scheduling integration research), 2 claudef]
> - I'm pretty sure that these windows/panes, or whatever they are, are not all belonging to the scheduling and that session work tree. Is that true? What's going on here?
>
> I don't think you've given me a good enough breakdown as to why we shouldn't be doing strict one-session-per-work-tree instead of these new hybrid tide sessions. I still don't understand the means of that decision and why we're leaning into that. It doesn't make any sense to be honest
>
> I think D2 deleting, refusing dirty by default with stash escape, is a good idea
>
> `Keep the existing plus-100 block formula` - I have no idea what this is - Is it something that we should keep? Does it work with the Content Engine? If it does is it a good standard to set up? Like I said in my prompt, my initial brief, I don't know
>
> D5: How does R12 play against my original idea of just showing when a worktree is "heavy" ? What odes heavy account for ? node_modules? Dervied data? LFS models? What else?
> - I would never want to bottleneck a worktree from being able to adopt heavy directory-based matter. If it decides to, it'd be more of a discipline thing: if I'm going to do a heavy task, I should open it in a worktree that is heavy, right, or replace one that is heavy? I'm not sure how your suggestion really works with my goals here
>
> ```
>   - R15, R16. Picker gets a cheap "All" scope with no-pane worktrees loaded
>     after the first frame. The cross-~/Developer cleanup is a separate
>     janitor view with async git columns and bulk actions.
> ```
> - This is just so vague. It's so vague man. I'm getting pissed off with how vague these kinds of things are. I'm thinking that we might need to even make a SUPER CONCISE update / CHANGE to the communication (@agents/communication.md ) document because I hate seeing these kinds of blocks when it is this fucking vague.
>
> I know that information, research, and investigations have been done and that these are referring to concepts that I still don't know anything about because I do not read. The files that are used agentically to document concepts and investigation material (for context on an as-needed basis for me to make decisions) should be available in the response
>
> I want to accept the suggestions but I need them to be aligned with what I need and want before I can accept these. I think the best flow here is that we get aligned on what the actual goals here are, what the actual best use cases are, and how this shit works (especially given my original prompt, which was pretty clear about things that I think would be good), so that I can accept the decisions, we can implement it, and I can start using it and do iterative feedback after using it, not trying to do everything up front. All about earned complexity here

Flow agreed from this: align on goals and mechanics, accept decisions, build
the smallest version, iterate from real use. Do not front-load.

## User feedback, second round (verbatim, 2026-10-31)

> [status bar screenshot: session `roll-scheduling`, windows `z 1` and `claudef 2`, folder segment `content-engine-1`] for example you can also see here that I have a session that is named DIFFERENTLY to my worktree that I select from the picker with significantly less windows. Its SUPER confusing and BAD DX - so i guess maybe strict is the best palce to at least START with this local dotfiles tooling. Just please remember the stakes are not that high, right? We make a decision. If I don't like it we've got the tasking document already kind of here, planned out. I can question the decisions made. We can change them and then we can reimplement. It's easy
>
> Just based on what I did share with you in the screenshot, there were a bunch of those kinds of windows. You're right: they were all focused on the same directory. Hypothetically doing something like `strict` shouldn't change because it's more of a discipline issue. The fact that I've got all of those threads open on that same directory is my problem. It's not something that we can really solve for, isn't it? Especially if we start making sessions based on worktree membership for different threads, right?
>
> I guess one thing I realize that we haven't actually discussed is what happens when a window has a pane belonging to one worktree and another pane belonging to another worktree. Do we just show that window for both worktree previews? Probably, right?
>
> Wait how do they even get positioned if we go into `strict` mode? Which sessions do they belong to? Interesting, right? Could they belong to both? I wouldn't be mad about that.
>
> I don't think they can log to both. I think that's a tmux constraint
>
> [on the drift marker and `C-a m`] This feels like it's getting too complicated. I don't actually understand what you mean by "other work tree." Are we saying this? Are you sure this makes sense? How could a window have a current working directory elsewhere but be assigned to a specific work tree?
>
> So long as you understand the main goals, which are:
> - work tree first
> - tmux organization and navigation
> - using the picker as a hub, a source, and a control center for understanding what's working, what needs attention, what has been finished, what has been idle for a while, what should be deleted, all that kind of stuff
> That's the main overarching intent. How do we solve that? It's kind of up in the air
>
> But the way in which the UI works with the picker and the other kinds of practices feeling good as they are is just about how everything is organized and the lifecycle is maintained and stuff like that
>
> D4: cool lock it in - sounds good.
>
> D5: Okay I could see how Node modules wouldn't be considered heavy. Although if we can do work trees and we can work on things without Node modules being installed (or investigate things without Node modules being installed), I'm pretty sure it does need to be installed to be able to use things like platform protocols. Writing code and stuff like that maybe doesn't need Node modules. Probably does for testing and shit like that, right?
>
> Maybe Node modules never become part of the heavy path and just good discipline of clearing worktrees when they're no longer needed will limit storage taken by Node modules.
>
> For LFS models, we do have the opportunity to classify them as heavy because of what you suggested before: the ability to split and spin up a worktree and not call LFS by default (such that those models never get pulled through). Those models don't get written to disk in the new work tree (whatever LFS is handling) and we only ever pull them on an as-needed basis. If we pull in LFS models then maybe that becomes heavy on an LFS level.
>
> Maybe we have a native iOS symbol and an LFS symbol for when things have these two kinds of heavy components. If we ever work on projects that have different other style heavy components, maybe we can make that clear. I feel like the dotfiles that we maintain should have a pattern matching kind of system that assigns a specific heavy element if that pattern exists: where to find that pattern, how to find it, and what kind of script runs that, such that a work tree can be labeled with these heavy elements.
>
> Does that make sense? Is this a good idea? I feel like it is because this will incentivize and make clear what the discipline needs to be in terms of storage maintenance and reusing specific worktrees where it makes sense.
>
> There should be an easy way for me to run a command on a specific worktree or hotkey a specific worktree from the picker once it's no longer needed, instead of deleting it, but to repurpose it. Think about that. Maybe repurposing pulls it back to main, keeping the heavy dependencies already assigned to it, and then creates a new branch. I don't know. Maybe I need to name the branch. Maybe it just spins up. Maybe I don't know what it does to be honest.
>
> Maybe when I'm going to add a new work tree, it can ask me if I want to choose one that already exists to place the new work tree at (which is always derived from main or the branch of my targeting choice), right? Maybe I can create a new work tree off of... There could be a hotkey for creating a new worktree off of a specific worktree selected under the picker cursor. I don't know, which would create a worktree off of the current branch of that worktree, right? Otherwise it would just do it from main.
>
> Maybe I have the choice to be able to just add a new worktree or replace an existing one. When I'm replacing an existing one I should be able to see those heavy elements to see, "Okay that's already got those heavy elements. I'll just replace it with that," for example, because I know that that work tree thread is done. I should be able to see if agents are working on it.
>
> We should also be able to see, ideally in the picker view, if a work tree has been merged into main, if it's pushed to remote, or if it's dirty. There should be icons for these kinds of things. We have to be very conscious about real estate, getting it, and having too much cognitive load. This could be something that shows up when hovering over it, in the preview area at the top, I don't know. Maybe there could be a row for specific data points like this but I would like to see what is heavy, what has at least one heavy element from the picker list.
>
> Thinking about these kinds of things, what do you think is best? Maybe just implement what you think is best or no, let's discuss it. I think frame it out to me based on what you think this should look like and then I can confirm so that at least I know what's going to be implemented and what to expect.
>
> R15 and R16:
> - I think the list should just always show ALL worktrees for ALl developer projects in the lsit, ordered by last active. W/ ability o cylce through repos (tab button already!) (ordered by most last active of course (or most worktrees?)).
> - ctrl-w becomes nothing - Also you're wrong about Control-W being limited to listing only worktrees that have a pane. It's currently switching between session mode and worktree mode, which we're folding into one anyway, so it just goes away and becomes nothing. I am not interested in your Control-G suggestion either .
> What is B: retargets?
> - I think we should just see all worktrees for all projects, all the time  (unless searching / tab filter)

## V1 frame (2026-10-31, confirmed by the user, ready to implement)

This section is the build spec for the first slice. Where it differs from
the R-items below, this section wins; the R-items keep the reasoning.

User, third round (verbatim, 2026-10-31): "I think the repos used should be
within 2 layers of Developer - ie the Developer/[repos] and the
Developer/[organizational-dir]/[repos] all considered as one large family of
repos to manage from the picker." And: keep the "Not in V1" list documented,
and add to it "thinking about other things that should go into the preview
area among the window selections (as labels / extra helpful info)". "All of
this sounds great - I think fold it in to the plan and let me know when its
ready to implement."

Goals it serves: worktree first; tmux organization and navigation; the
picker as the hub for what is working, needs attention, finished, idle, and
deletable.

Model

- V1. A worktree has one session, named after its directory. A window is in a
  worktree because it is in that session. Pane cwd never changes membership
  and is never used to group. Mixed-worktree windows are simply in whichever
  session they were opened in. tmux can link one window into several
  sessions (`link-window`), but resurrect would save and restore it twice,
  so V1 does not use it.
- V2. No drift marker, no move key. A window that cd's elsewhere is just a
  window in its session (example: a shell in the `content-engine-1` session
  that cd's to `~/Developer/dotfiles` to check a config). If it should live
  elsewhere, tmux's own `move-window` works; a picker key can come later if
  use shows the need. The home-window-cd's-into-a-repo case is the same:
  nothing happens.
- V3. Sessions that are not a worktree (`home`, `processes`, anything legacy)
  stay listed as plain session rows exactly as today, so nothing is hidden
  during or after migration. `home` is created on demand. Remote `rw-*`
  sessions are already per worktree and list under their worktree.
- V4. Migration: rename `roll-scheduling` and friends to their worktree
  directory name where the session has one worktree; sessions whose windows
  all sit in content-engine-1 (`roll-10-yap-integration`, `roll-deferred`,
  `roll-main`, `roll-scheduling`) merge into one `content-engine-1` session
  with topic-named windows, or the user first gives a topic its own
  worktree. Done once, by hand with a script, then a verified save. This
  does not stop six threads being opened in main; it shows them under one
  honest name.

List

- V5. The list always shows every worktree of every git repo under
  `~/Developer`, one family. Discovery: `~/Developer/*/.git` and
  `~/Developer/*/*/.git` (a repo directly under Developer, or under one
  organizational directory), plus each main repo's `.git/worktrees/*/gitdir`
  for linked worktrees at any depth (this is how `.eph/*` is found). Rows
  dedupe by root path, since a slot directory such as `content-engine-10`
  is both a depth-2 entry and a linked worktree of content-engine-1. Two
  clones of the same project (`yap-trial` at depth 1 and inside
  `content-engine-trees`) stay two repos. Snapshot 2026-10-31: 60 repos,
  linked worktrees on 4 of them (content-engine-1: 90). Shown whether or not
  a row has a session, ordered by last active: last pane activity when it
  has a session, else the worktree's `HEAD` or index mtime.
  Rows without a session are dim. Tab cycles repos (existing), repos ordered
  by their most recently active worktree. Search filters as today.
  `ctrl-w` is removed (session mode and worktree mode are one list).
- V6. Row content, left to right, with no new columns beyond today's: name,
  agent state badge (existing), heavy symbols (V8), lock marker if locked,
  "missing" marker if the directory is gone. Windows cards below as today.
- V7. Git state (dirty, ahead of remote, merged into main) is shown in the
  preview area for the selected row only, computed when the cursor rests on
  a row (about 110 ms for `git status`, run async), never for the whole
  list. If use shows it is wanted in the row, it becomes a cached symbol.

Heavy

- V8. Heavy elements are a pattern table in dotfiles, one line each:
  symbol, name, how to detect (a path glob, optionally a script). A
  worktree shows the symbol of every element present. Initial table:
  - `ios`: `apps/expo/ios/Pods` or `ios/build` exists.
  - `lfs`: any file under `packages/native-tools/ios/Models/` larger than
    1 KB (LFS pointer files are about 130 bytes, so a stat distinguishes).
  - DerivedData is external and path keyed; add it as a script detector
    once the first two have been used.
  `node_modules` is not an element. Detection is stat only, after the first
  frame.
- V9. New worktrees are created with `GIT_LFS_SKIP_SMUDGE=1` and a
  `lfs.fetchexclude` for the models path, so `lfs` is only shown when models
  were pulled on purpose (`git lfs pull -I` from the local store).

Lifecycle keys (all on worktree rows; each refuses while an agent in the
worktree is Working, and shows dirty count and heavy symbols in the
confirm line)

- V10. `N` new worktree: prompt for branch name; base is `main` by default,
  or the selected row's branch when the prompt is opened with `shift-N`.
  Creates the directory in the repo's worktree root, copies env (R6),
  allocates ports (R10), creates and switches to the session, runs
  `pnpm install --prefer-offline` visibly in the first window.
- V11. `R` repurpose (what the earlier draft called "B retarget"): keep the
  directory and everything heavy in it, switch it to a new branch cut from
  `main` (prompt for the name), refuse if dirty unless stash-then-switch is
  chosen, keep `.env.ports`, drop `.env.branch`. The session keeps its name,
  windows stay. This is the "replace an existing one" path: pick a finished
  worktree whose symbols you want, press `R`.
- V12. `D` delete: D2 policy. Closes remote endpoints for the root first
  (R18), kills the session, trashes the directory, prunes, removes matching
  DerivedData, background verified save.

### Not in V1 (kept on purpose, revisit after use)

- Janitor view (R16).
- Drift marker and move key (R2 as first drafted).
- Git state (dirty, ahead, merged) as symbols in the row; V1 puts it in the
  preview for the selected row only.
- `ctrl-g` All scope toggle (superseded by V5 always-all).
- Heavy pool and locks as a requirement (R12 first draft).
- Per-repo declaration file (R11). content-engine's paths and keys are
  hard-coded in `wt` until a second repo needs different ones.
- Preview area content: what else belongs in the preview among the window
  cards as labels or extra helpful info (candidates: git state per V7, ports
  block, heavy element names in words, last commit subject, remote endpoint
  host, age of the worktree, PR state). Decide from use, one at a time.

## Live state at open (2026-10-30, read-only snapshot)

Five subagent reports fed this section: picker architecture (opus), remote and
resurrection constraints (opus), prior-art research (opus), rule critique
(opus), and the content-engine worktree audit (sonnet). Nothing was changed on
disk or in tmux during the round.

### tmux

- 19 sessions, 68 panes. Names are topic based (`roll-5-carousels-release`,
  `roll-deferred`, `roll-main`), not worktree based.
- Sessions and worktrees cross each other both ways. `content-engine-5` has 14
  panes spread over three sessions. `roll-deferred` spans five groups
  (content-engine-4, content-engine-5, `.eph/env-protection`,
  `.eph/platform-supabase`, and a pane in `~/.Trash`).
- Three `roll-main` panes (two Claude, one nvim) sit in
  `.eph/braze-integration`, which no longer exists. `roll-deferred:11.0` is a
  Claude pane whose path is `~/.Trash/roll-hiring` (4.1 GB in the Trash) and
  whose `@agent_cwd` is `active/roll-hiring`, also gone. Worktree mode hides
  all of these because a missing directory resolves to no worktree.
- The current verified resurrect snapshot contains those panes. On a restore
  they would come back in `$HOME` (or inside the Trash) and auto-run
  `claudef --resume` there.
- `roll` is an existing `$HOME` session and is a name prefix of every `roll-*`
  session. Upstream tmux-resurrect matches session names by prefix on restore
  into a live server.

### content-engine-trees

| Measure | Value |
|---|---|
| Registered worktrees | 86 (1 main, 15 numbered slots, 30 under `.eph/`, 3 under `active/`, 28 nested `.claude/worktrees/*`, 9 named top-level) |
| Total size | 428.8 GB (`du`, apparent bytes; pnpm uses APFS clones so real reclaim may be lower) |
| `node_modules` share | 294 GB across 76 worktrees, 3.7 to 4.5 GB each |
| Nested `.claude/worktrees/*` | 103 GB, no live pane references any of them |
| Real LFS model copies | 65 worktrees, about 12.6 GB; 18 newer nested worktrees hold pointer files only |
| Xcode DerivedData | six `RollPreview-*` entries of 5.5 to 9.2 GB, about 45 GB, each keyed by worktree path |
| Heavy in-tree iOS builds | content-engine-5 (12.6 GB `ios/build`), content-engine-11 (11.3 GB), content-engine-visualizer (7.0 GB) |
| Disk | 92% full, 75 GiB free |
| Stashes | 56, shared across all worktrees |

Other facts the plan depends on:

- `.eph/` is already the ad hoc ephemeral convention (30 worktrees, named by
  task slug, branches with normal `feat/`, `fix/` prefixes). No tool creates
  it. The repo's ship plan tells agents to delete `.eph` worktrees after the PR
  merges, applied by hand.
- `.env.ports` (keys `NEXT_PORT`, `DASHBOARD_PORT`, `ENGINE_PORT`,
  `EXPO_PORT`) is the project's declared port contract. Defaults apply when
  the file is absent (`platform/gcp/src/envOutputDefaults.ts`,
  `platform/gcp/PROTOCOL.md` "This repo allocates no ports"). The slot-era
  formula was base plus 100 per slot. 18 files exist, with duplicates: three
  named worktrees reuse slot 4's ports, `track-ux` reuses slot 5's, and every
  `.eph/*` worktree falls back to the same defaults as `content-engine-1`.
- `pnpm env:pull` renders `.env.local` from GCP plus `.env.ports`, so
  `.env.local` holds literal ports in `SERVER_ORIGIN`, `ENGINE_URL`,
  `EXPO_PUBLIC_SERVER_ORIGIN`, `VITE_SERVER_ORIGIN` and `DEEP_LINK_BASE_URL`.
  Copying or symlinking it verbatim clones the source's ports.
- `.env.branch` pins one branch's Supabase cloud branch and credentials.
  Headers in content-engine-1, -9, -10, -11 and `trial-never-paid` name
  branches that are long gone.
- `content-engine-4` and `-5` are locked with reason `initializing` since
  2026-01-10, a transient lock from an interrupted `git worktree add`.
- LFS objects live in the shared `.git/lfs/objects` (4.2 GB). A new worktree
  smudges from the local store (0.11 s for the 71 MB weight), so the cost is
  194 MB of disk per worktree, not a download. `lfs.fetchexclude` is unset.
- Metro's port is compiled into React-Core (`RCT_METRO_PORT`), so a worktree's
  `EXPO_PORT` must stay stable across rebuilds. Expo does not require 8081.
- The old `chore/ports-from-env-ports-file` branch (`.eph/retire-worktree-claim-1`)
  is fully landed on `origin/main` (PR #433 merged, local commits patch-equal).
- `content-engine-trees/content-engine` is a separate Feb 2026 clone with
  1801 staged deletions. `latest-editor` is another full clone at
  `release/1.0.2`. `minified-repo` is a worktree of `yap-trial`, a different
  repo. `.eph/content-engine-adjustments` is an orphan (registration gone,
  4.6 GB, planning docs from 2026-09-15).

### Picker (current code facts)

- A session has no worktree field. Membership is computed per pane from the
  effective directory (`Pane.Dir()`, `@agent_cwd` for live agents). Worktree
  rows pull windows from every session. Cards show only `W name`, so the
  content-engine-5 row shows window `1` three times with no session name.
- `@agent_cwd` drifts from the pane: this orchestrator (`dotfiles:3.0`) has
  `@agent_cwd` in content-engine-1, so it files under content-engine-1.
  Automatic window moving keyed on agent cwd would move the wrong things.
- The resolver reads only `.git`, `gitdir`, `commondir` and `HEAD`. A linked
  worktree's admin dir name is not its directory name (content-engine-11's is
  `worktrees/content-engine-fix-engagements-awareness`), so any listing must
  read `<admin>/gitdir`. `<admin>/locked` is readable at the same cost.
- Stat survey of heavy markers across the 86 worktrees: `node_modules` 78,
  real LFS models 80, `apps/expo/ios/Pods` 16, `android` 1. Only native
  markers discriminate. 688 stats took 1.5 to 1.8 ms warm, 61 ms cold.
- Actions already run as a `tea.Cmd`; `Init()` returns nil; there is no busy
  state. `checkSessionName` rejects `.` and `:`. tmux default keys are still
  bound (`unbind-key -a` is commented out), so new hotkeys need a
  `tmux list-keys` check.
- `git status --porcelain` on content-engine-1 takes about 110 ms: fine for an
  action, not for listing.

### Remote workspaces and resurrection (constraints)

- Session identity across a restore is the session name. tmux-resurrect saves
  no `@` options; the sidecar saves per-pane fields keyed by session name;
  `@session-uuid` is re-stamped from `sessions.jsonl` by name. A new
  `@worktree_root` session option is a runtime cache only.
- No `session-renamed` hook exists. Renaming a session that owns a remote
  endpoint breaks post-restore reattachment of that endpoint.
- Session names must not start with `rw-` (client-guard patch) and must avoid
  `.` and `:`. New code should target sessions with `=name`.
- Neither the resurrect validity gate nor the sidecar gate checks that a
  pane's cwd exists. Deleting a worktree with live panes needs a verified save
  afterwards.
- The worker checkout path is repo identity plus local dir name plus a
  checksum of the local path. Moving a worktree makes a new worker clone and
  orphans the old one. Retargeting in place keeps the mapping and the worker's
  build artifacts.
- Handoff transfers tracked and untracked-but-not-ignored files only. `.env.*`
  files never reach a worker; the worker runs default ports. No port handling
  remains in the plugin.
- Scope boundary (final since 2026-09-08): creating, moving, removing,
  retargeting worktrees, copying env, allocating ports, heavy detection and
  the `.eph` convention all stay out of tmux-remote-workspaces. The remote
  layer needs only: the path is a git worktree with an `origin`, the path
  stays stable while an endpoint exists, and endpoints are closed before the
  worktree is deleted, moved or retargeted.
- The picker's kill path keys on `@remote-host`, but endpoints are
  authoritative in the registry keyed by `focus_path`. A delete action should
  close endpoints by registry lookup, which needs one small read-only rw
  command.

## Findings

- F1. (Superseded by D1 on 2026-10-31.) The four analysis agents argued
  against strict one-session-per-worktree. On re-reading, every argument was
  against *automatic window moving*, not against the 1:1 rule itself. The
  breakdown is in D1. What survives from the reports: windows never move
  automatically, and drift is shown rather than acted on.
- F2. The content-engine ports contract already exists and is what the user
  described: the project owns the keys and the mapping with defaults when the
  file is absent, and "local tooling" (dotfiles) fills in `.env.ports` at
  worktree creation. Deriving ports from a path hash alone collides at 30
  worktrees (about 99% with 100 blocks), so allocation needs a probe either
  way. Files on disk are the registry; nothing central.
- F3. The expensive artifact is not in the worktree. Xcode DerivedData is keyed
  by worktree path, so renaming or moving a heavy worktree discards 5 to 9 GB
  of warm build. The slot system's real value was path stability, which
  "retarget in place" preserves.
- F4. Ephemeral worktrees should skip LFS smudge. 65 copies of 194 MB exist
  and only native builds need them. `GIT_LFS_SKIP_SMUDGE=1` at `worktree add`
  plus a per-worktree `lfs.fetchexclude` keeps them lazy; `git lfs pull -I`
  materialises from the local store without network.
- F5. `.env.local` cannot be symlinked or copied verbatim today because it
  embeds the source's ports. Either dotfiles rewrites the port-derived keys
  offline after copying, or the project moves those keys into the
  `.env.ports` layer so `.env.local` becomes pure secrets. `.env.branch` must
  never propagate.
- F6. The cleanup opportunity is large and mostly safe. 24 worktrees are
  STALE-CLEAN (merged or ancestor of main, no panes, about 105 GB) and 35 are
  RECENT-MERGED (about 141 GB, touched in the last 14 days, eyeball first).
  Eight STALE-DIRTY and six UNKNOWN worktrees hold work that exists nowhere
  else and need a human look. Full table in the appendix.
- F7. Three orphan situations need action before the next restore: the
  `.eph/braze-integration` panes, the `~/.Trash/roll-hiring` pane, and the
  `.eph/content-engine-adjustments` directory.
- F8. Every proposed picker addition fits the open budget (one tmux call, no
  git spawn) if worktree enumeration, heavy probes and git status run as a
  `tea.Cmd` after the first frame or only on action.
- F9. No surveyed tool moves a window when its cwd changes, and tmux has no cwd
  hook (3.8 adds format monitors that poll once a second, which is not
  needed). The `.worktreeinclude` convention (Claude Code, Conductor,
  worktrunk, ccmanager) and APFS clone copies (`cp -c`) are the shared
  prior art for env propagation.
- F10. The user's screenshot (2026-10-31) is the worktree view's row for
  content-engine-1, the main checkout, which is on branch
  `feat/scheduling-init`, so the row is labelled by branch and looks like "the
  scheduling worktree". Its six cards come from four sessions because the
  picker groups cards by each pane's directory (`Pane.Dir()`: `@agent_cwd`
  for a live agent, else `pane_current_path`), not by session:
  `roll-10-yap-integration` (1 FUCKING PRS), `roll-deferred` (5 z, 12
  lane-monitor), `roll-main` (1 braze: the shell is in the deleted
  `.eph/braze-integration`, but the Claude pane's `@agent_cwd` is
  content-engine-1) and `roll-scheduling` (1 z, 2 claudef). `roll-main`'s
  `walkthrough-repurposing` window is missing from the grid because its agent
  cwd is the deleted directory, which resolves to no worktree. So the picker
  does group across sessions today, and that is exactly the confusion: the
  main checkout is shared by four topic sessions, and the row name hides
  that it is the main directory. Strict sessions (D1) remove the cross-session
  grouping; a `missing` row (R3) stops windows vanishing.
- F11. The ports generator is gone. All 18 `.env.ports` files carry the
  header `Generated by worktree-slot ensure`, and that tool was deleted with
  the September slot removal. New worktrees get no file and run on defaults;
  worktrees created by copying a slot directory keep the slot's ports (the
  three `content-engine-billing-*` worktrees all declare slot 4's ports).
  The format and the plus-100 step are the only parts still alive, and they
  are what the project's renderer and dev scripts consume (R10).
- F12. Remote mirrors need the local delete to reach them. `rw close` already
  does tombstone-first teardown of one endpoint and its worker directory
  (`docs/tmux-remote-workspaces.md` "rw close"), but the registry is keyed by
  endpoint id and session, and there is no query "endpoints whose focus path
  is under this worktree". R18 is therefore required for `wt rm`, not
  optional: the delete action lists endpoints for the root, closes each
  through `rw close`, and only then kills panes and removes the directory.

## Recommended approach

### Model

- R1. Strict: one session per worktree. The session is named after the
  worktree directory (`content-engine-1`, `scheduling`; `.` and `:` become
  `-`; never starting with `rw-`), carries `@worktree_root`, and is the only
  place that worktree's windows live. Membership is by session, not by where
  a pane's shell is. The picker's worktree view and session view become one
  list: a row is a worktree, its cards are the windows of its session.
  Remote `rw-*` sessions are already one per worktree. After a restore the
  root is re-derived from the session name plus `session_path` and
  re-stamped by a post-restore hook appended after rw's.
- R2. Drift is shown, never acted on. When a window's pane or agent cwd is in
  a different worktree than its session, the card shows a dim
  `-> <worktree>` marker. `C-a m` moves that window into the other
  worktree's session, creating it if needed. A window whose panes sit in two
  worktrees moves whole, by the selected pane (`break-pane` first if that is
  wrong). Nothing moves automatically: tmux has no cwd hook, and an agent
  that reads another repo is not a reason to relocate it.
- R3 (superseded by D94: plain sessions are unlimited; `home` is just one
  of them). `home` is the single non-worktree session, created on demand with
  `new-session -A -d -s home -c ~` (never from `tmux.conf`, restore assumes
  an empty server), always a row. A home window that cd's into a repo gets
  the same drift marker and the same manual move; nothing else happens.
  Panes whose directory no longer exists show under a synthetic `missing`
  row so they stop vanishing (F10). Set `detach-on-destroy previous` so
  killing a worktree session never drops the client.
- R4. Enter on a worktree row with no session creates and opens it. A second
  session for the same worktree is refused: Enter switches to the existing
  one. `C-a C` (new session) becomes "new worktree" (R6) or `home`.
- R4a. One-off migration (part of P1): the 18 live sessions fold into
  worktree sessions. The four sessions with panes in content-engine-1
  (`roll-10-yap-integration`, `roll-deferred`, `roll-main`,
  `roll-scheduling`) become windows of one `content-engine-1` session unless
  each topic gets its own worktree first, which is the point of
  worktree-first. Topic names survive as window names. Re-save the resurrect
  snapshot after migration, since the session name is the restore identity.

### Lifecycle (`wt` script, picker calls it)

- R5. One owner for git operations: a bash script `wt` installed on PATH
  (stow package under `git/.local/bin/wt`), callable from the picker, zsh and
  agents, overridable for tests like `rw-close.sh`. tmux operations stay in
  Go where the kill paths and shim already live.

  ```
  wt new <repo-root> --branch B [--from REF] [--name DIR] [--json]
  wt status <root> --json
  wt rm <root> [--force] [--ignore-panes] [--json]
  wt retarget <root> --branch B [--from REF] [--stash] [--json]
  exit: 0 ok, 2 usage, 3 dirty, 4 locked, 5 refused, 6 ports, 1 other
  ```

- R6. `wt new`: `GIT_LFS_SKIP_SMUDGE=1 git worktree add` into the repo's
  worktree root (content-engine: `content-engine-trees/.eph/<slug>`), set
  `lfs.fetchexclude` for the models path in the worktree config, copy
  gitignored `.env*` from the main worktree by APFS clone except the deny list
  (`.env.ports`, `.env.branch`, `*.generated`, `*.rendered`), allocate a port
  block and write `.env.ports`, rewrite the port-derived keys in the copied
  `.env.local` offline, then run the repo's post-create hook if one exists.
  The picker then creates the tied session, puts `pnpm install
  --prefer-offline` in its first window so it is visible and does not block,
  and switches to it.
- R7. `wt rm`: refuse a main checkout that still has linked worktrees
  (narrowed by D102 from "refuse the main worktree"; one without linked
  worktrees goes whole to `~/.Trash`); refuse locked unless forced (showing
  the reason); refuse dirty unless forced, with a "preserve then delete" path
  that runs a tagged `git stash push -u` first (matches AGENTS.md); refuse
  while panes or agent cwds are inside unless the picker passes
  `--ignore-panes` after killing them. Order in the picker: `wt status`,
  inline confirm showing dirty count, ahead count, live agents by state,
  nested worktrees and remote endpoints (refuse if any agent is Working);
  close endpoints by registry `focus_path`; kill member panes and windows;
  `wt rm` renames the root into a trash dir and removes it in the background
  after `git worktree prune`; delete DerivedData entries whose `WorkspacePath`
  matched; run `resurrect_save.sh quiet` in the background. The branch is
  never deleted.
- R8. `wt retarget`: refuse dirty unless `--stash`; refuse while a live remote
  endpoint exists for the root (point to `rw return`); refuse if the branch is
  checked out elsewhere; `git switch -c B REF` or `git switch B`; keep
  `.env.ports`; delete `.env.branch`; report `needs_install` and `needs_pods`
  from lockfile and `app.config` diffs. The path, session name and worker
  mapping do not change.

### Env and ports

- R9. Copy, never symlink. Writers inside a worktree (`env:pull`,
  `env:branch:pull-pr`, agents editing `.env.production`) would otherwise
  clobber the source through the link, and a dangling `/Users/...` link would
  travel to Linux workers. Staleness is accepted; add `wt env-refresh` later
  that re-copies only shareable files. (Done as D109, 2026-11-03: `wt
  env-refresh` pulls in main through `wt.envPull` and re-copies the same
  deny-listed set with each worktree's ports kept; `C-a e` in the picker.)
- R10. Ports. The contract is content-engine's and exists today: an optional
  `.env.ports` file at the worktree root with four keys, `NEXT_PORT`,
  `DASHBOARD_PORT`, `ENGINE_PORT`, `EXPO_PORT`. `pnpm env:pull` reads it and
  renders `.env.local` with literal URLs (`SERVER_ORIGIN`, `ENGINE_URL`,
  `EXPO_PUBLIC_ENGINE_URL`), and the dev scripts read the same keys with
  defaults 3000, 3010, 7500, 8081 when the file is absent
  (`docs/notes/dev-environments.md`, `apps/next/package.json`,
  `platform/gcp/src/envOutputDefaults.ts`). The "plus 100 formula" is only
  what the surviving files use: block k gets each default plus 100k, so
  block 3 is 3300, 3310, 7800, 8381. `wt new` picks the lowest k not
  declared by any sibling `.env.ports` and none of whose four ports is bound
  (`lsof`), writes the file, and that is the whole allocator. Files on disk
  are the registry. Cap k at 40 so the NEXT band (3000 and up) never reaches
  the ENGINE band (7500 and up). The file travels with the directory, is
  never recomputed, survives retarget, and is on the copy deny list (F11).
  Remote workers run defaults and are not port balanced. Add `--strictPort`
  to Vite so a taken port fails instead of sliding onto a neighbour.
- R11. Per-repo declaration, committed in the repo (`.worktree.json` or git
  config keys): worktree root, env deny list, ports file and step, heavy
  marker paths, LFS lazy paths, post-create hook. Repos without it get the
  generic defaults (copy `.env*` except the example, no ports). content-engine
  sets the standard; a small offline `env:ports:apply` in the project that
  rewrites `.env.local` from `.env.ports` would let dotfiles stop knowing the
  key names.

### Heavy worktrees

- R12. "Heavy" means native build state, measured by a stat probe, never
  designated. From the audit the markers that discriminate are
  `apps/expo/ios/Pods` (16 of 86 worktrees), `ios/build` (3 worktrees, 7 to
  13 GB) and an Xcode DerivedData entry whose `WorkspacePath` is the
  worktree (6 entries, 48 GB total, 5 to 9 GB each), plus `android` (1).
  `node_modules` (78 of 86, 3.7 to 4.5 GB each) and smudged LFS models (80 of
  86, 194 MB) are in nearly every worktree and are not "heavy"; they are the
  cost of a worktree being usable at all.
- R13. Badge: one reserved cell after the repo badge on every row. Nerd Font
  native glyph when Pods, `ios/build`, `android` or a DerivedData entry
  exists; dim dot when only `node_modules` or models exist; blank otherwise.
  Stat-only probe (no git, no `du`), run after the first frame. No cap, no
  pool, no lock needed: any worktree becomes heavy by building and shows it.
- R14. Reuse is discipline, not enforcement. When a task needs a device or
  simulator build, pick a badged worktree that is idle and clean and
  `retarget` it (new branch in place; Pods, `ios/build` and DerivedData stay
  warm because the path does not change). Otherwise open an ephemeral
  worktree and pay the cold build if the task ever needs one, after which it
  is badged too. The one hard rule: never rename or move a heavy worktree,
  because DerivedData is keyed by path (F3). `git worktree lock --reason
  heavy` is optional protection against deleting one you want to keep, and
  the picker shows a lock marker when present; it is not the badge source.

### Discovery and cleanup

- R15. "All" scope in the picker. Today `ctrl-w` lists only worktrees that
  have at least one pane. `ctrl-g` adds every other worktree of the repos
  you work in as dim rows with no cards, showing directory, branch, lock
  marker and the heavy badge. On those rows Enter creates and opens the
  session, `D` deletes (R7, same refuse-dirty rule), `B` retargets (R8). The
  set of repos comes from a one-line-per-repo registry file
  (`~/.local/state/agent-picker/repos`) appended whenever a repo has panes
  or `wt new` runs, seeded once by a depth-2 scan of `~/Developer`. Cost is
  reading `<commondir>/worktrees/*/{gitdir,HEAD,locked}`, no git process,
  after the first frame. This is the V1 answer to "a hotkey to see all
  worktrees of all git projects under `~/Developer`, with or without
  sessions, to close, delete or reopen".
- R16. Janitor view, deferred until R15 proves insufficient in use. It would
  be a separate full-screen list on its own hotkey: one line per worktree
  across every repo under `~/Developer`, with dirty, ahead, merged, PR state
  and size filling in asynchronously, multi-select and bulk delete. It is
  not in the picker because `git status` on 86 worktrees takes seconds and
  the picker opens in one tmux call. Build only when real use shows R15 is
  not enough.

### Remote and resurrection integration

- R17. Add an indexed `session-renamed` hook to rw that calls the existing
  `session-created-hook.sh` (identity upkeep, in scope for rw), before any
  existing session is renamed.
- R18. Required for delete (F12): add a read-only `rw endpoints --focus-path
  <root>` so `wt rm` and the picker delete action can find every endpoint
  mirroring the worktree and close each through `rw close` (tombstone first,
  worker directory torn down) before killing panes and removing the local
  directory. Without this the remote copy is left behind.
- R19. Sidecar records `#{@worktree_root}` per pane and the post-restore step
  re-stamps it on the session, the same pattern as `@session-uuid`.
- R20. Every new binding and script follows the existing checklist: no live
  tmux from tooling or tests, isolated `-S` server with trap teardown and
  private state dirs, `|| true` on dialog bindings, saves only through
  `resurrect_save.sh` in the background, `=name` targets, indexed hooks loaded
  after rw.

## Build order (replaces the earlier phases table)

| Step | Content | Touches live tmux? | Needs |
|---|---|---|---|
| B0 Hygiene | Close or retarget the `.eph/braze-integration` and `~/.Trash/roll-hiring` panes, verified save, unlock the two stale `initializing` locks, remove the STALE-CLEAN list, triage STALE-DIRTY and UNKNOWN, remove orphan `.eph/content-engine-adjustments` after saving its docs, delete DerivedData for removed paths | yes (panes, save) | D9 yes |
| B1 `wt` script | `new`, `status`, `repurpose`, `rm` with the exit codes in R5; env copy by deny list; port allocator; LFS skip; tests on a temp repo | no | none |
| B2 Picker list | Repo discovery (V5), always-all rows, dedupe, order by last active, Tab repo order, remove `ctrl-w`, heavy symbols (V8), lock and missing markers, git state in preview (V7) | no (isolated `-S` server tests) | none |
| B3 Picker keys | `N`, `shift-N`, `R`, `D` calling `wt`; confirm lines; Working refusal; endpoint close via rw (R18); background verified save | no until merged | B1, B2 |
| B4 Migration | Rename single-worktree sessions to directory names; merge the four content-engine-1 sessions; create `home`; re-save | yes, by hand with a script, last | B2 merged |
| B5 Durability | `@worktree_root` re-stamp after restore, rw `session-renamed` hook, docs D84+ in `docs/tmux-agent-sessions.md`, retire this task doc | no | B3, B4 |

## Cleanup log (B0, user drives every batch)

User, 2026-10-31: "for the clean up I want to drive ALL decisions - lets do
it first. Every batch of operations (of which there will be many should be
proposed to me as to what moves / what changes re panes, sessions, repos,
worktrees, etc)". Each batch below is proposed, then marked approved (with
exceptions) and done, with what actually ran.

### Batch 1: orphan panes, stale locks, orphan directory (proposed 2026-10-31)

Live facts checked 2026-10-31 16:40 (last resurrect save is from the same
minute and still contains every item below).

| Item | What exists now | Proposed action | Why it is safe |
|---|---|---|---|
| C1 | `roll-main` window 1 `braze`: Claude pane (idle, shell in deleted `.eph/braze-integration`, agent reports cwd content-engine-1, last recap: Braze migration fully closed out) and an nvim pane | `kill-window -t roll-main:1` | Branch `fix/braze-server-review` is 0 commits ahead of `origin/main`; directory already gone |
| C2 | `roll-main` window 2 `walkthrough-repurposing`: Claude pane (idle, cwd deleted, 164k tokens, an unsent prompt drafting a walkthrough-primitives handoff is typed in its input) | Capture the pane text to the scratchpad for the user, then `kill-window -t roll-main:2`. `roll-main` then has no windows and ends | Same branch; the agent cannot read files from a deleted cwd, so it cannot continue usefully |
| C3 | `roll-deferred` window 9 `management`: Claude pane idle in `~/.Trash/roll-hiring`, last activity Sep 28, a hiring plan conversation | `kill-window -t roll-deferred:9`. Leave the Trash item for the user to empty (4.1 GB) | Branch `exp/roll-hiring` is 0 ahead of `origin/main`; admin dir already gone, nothing to prune |
| C4 | `content-engine-4` and `content-engine-5` worktrees locked with reason `initializing`, written by the deleted slot tool; both have live panes | `git worktree unlock` on each | Lock only blocks `remove` and `prune`; no behaviour change for running panes |
| C5 | `.eph/content-engine-adjustments`: 4.5 GB directory whose `.git` file points at an admin dir that no longer exists, so git does not list it; files dated Sep 15; 391 markdown files differ from today's main and 232 are not on main, almost all because main moved on since September | Option a: `mv` to `~/.Trash` (reversible, frees nothing until emptied). Option b: tar `docs/`, `initiative.md`, `overlay-detection-consolidation.md`, `AGENTS.md` to `content-engine-trees/_salvage/` then `rm -rf`. Option c: leave | HEAD is unknown (admin dir gone), so nothing can be verified against a branch; the docs are the only unique content |
| C6 | After C1 to C5: run `tmux/scripts/resurrect_save.sh` and confirm the new snapshot has no pane in a missing directory | Verified save | Without it, the next restore recreates C1 to C3 in `$HOME` and auto-resumes Claude there |

Not proposed in this batch: `roll` session (one empty window in `$HOME`, it
is the `home` candidate), the four `$HOME` shells in `roll-5-carousels-release`
window 4, and every registered worktree (batches 2 and on).

Batch 1 outcome (2026-10-31 17:33): user approved C1, C3 cleanup, C4, C5
(kill), C6, and had already killed C2 and C3's windows. Ran: `kill-window
roll-main:1` (session `roll-main` ended), `git worktree unlock` on
content-engine-4 and -5, `rm -rf .eph/content-engine-adjustments`,
`resurrect_save.sh`; new snapshot `tmux_resurrect_20261031T173337` has no
pane in a missing directory. User added to C4: "For ALL slot based
worktrees that are still active their chats and worktrees must be moved
accordinly." That is batch 2.

### Batch 2: move active slot worktrees and their chats (proposed 2026-10-31)

Mechanics, same for every row:

1. `git worktree move content-engine-N .eph/<slug>` (slug = branch minus
   type prefix, D10). `.env.ports`, `.env.local`, node_modules and Pods
   travel with the directory; pnpm hoisted links are relative, so they keep
   working.
2. Chats: Claude keeps transcripts under
   `~/.claude/projects/<escaped-cwd>/`, pi under
   `~/.pi/agent/sessions/<escaped-cwd>/`. Rename both to the new escaped
   path, so `--resume` from the new directory lists the old chats.
3. Running agents keep working after the move (macOS cwd follows the
   renamed directory), but a running Claude or pi writes its transcript to
   the path it computed at startup, so it recreates the old chat directory.
   No restart is forced; a merge pass at the end of the batch, and again
   whenever asked, moves stragglers into the new directory.
4. tmux: `rename-session` to the new directory basename (strict, V1) and
   `move-window` the windows that belong to this worktree out of
   `roll-deferred` and the other topic sessions. Pane shells, nvim and
   agents show the new path by themselves.
5. Native: every slot has Pods whose `expo-configure-project.sh` embeds the
   absolute path, so run `pod install` before the next iOS build of a moved
   worktree. Xcode DerivedData is keyed by path, so a moved worktree's next
   build is cold.

| Item | Worktree now | Branch, dirty, ahead | Panes now | Proposed directory | Proposed session and window moves | Cost |
|---|---|---|---|---|---|---|
| M3 | content-engine-3 (6.6 GB) | docs/nointro-approved-smoke, 3 dirty, 2 ahead, pushed | `roll-3-revenue`:1 `gst` (zsh) | `.eph/nointro-approved-smoke` | rename `roll-3-revenue` to `nointro-approved-smoke` | pod install before iOS build |
| M4 | content-engine-4 (8.3 GB) | feat/web-funnel-improvements-1, 7 dirty, 1 ahead, pushed | `roll-web-funnel-changes`:1 (Claude awaiting, nvim); `roll-deferred`:7 `search-results`, :8 `protect-environments`, :9 `figma-linx` (3 Claude, 2 nvim); `processes`:1 shell | `.eph/web-funnel-improvements-1` | rename `roll-web-funnel-changes` to `web-funnel-improvements-1`; move `roll-deferred` windows 7, 8, 9 into it; `processes` shell untouched | same |
| M5 | content-engine-5 (46 GB, 12.6 GB `ios/build`, 9 GB DerivedData, hosts 3 nested `.claude/worktrees`) | feat/duplicate-asset-grouping, 2 dirty, no upstream | `roll-5-carousels-release` 6 windows (4 Claude idle); `roll-9-broll-duplicate-assets`:1 (Claude); `roll-deferred`:1-4 (4 Claude idle) | Option a: keep path (heavy, D10). Option b: `.eph/duplicate-asset-grouping` then `git worktree repair` on the three nested worktrees | rename `roll-5-carousels-release` to the directory name; move `roll-9-broll-duplicate-assets`:1 and `roll-deferred`:1-4 into it; `roll-9-broll-duplicate-assets` ends | (b) throws away the warm 9 GB DerivedData and 12.6 GB `ios/build` becomes stale; recommended (a) |
| M6 | content-engine-6 (6.5 GB) | feat/agentic-harness, clean, 7 ahead, pushed | `roll-6-agentic-engineering` 2 windows (2 Claude, 2 nvim) | `.eph/agentic-harness` | rename to `agentic-harness` | pod install before iOS build |
| M11 | content-engine-11 (18 GB, 11.3 GB `ios/build`, 9 GB DerivedData) | feat/editor-overhaul, clean, 12 ahead, pushed | `astra`:1 `pif` (pi idle) | Option a: keep path (heavy). Option b: `.eph/editor-overhaul` | rename `astra` to the directory name | same as M5; recommended (a) |
| M13 | content-engine-13 (5.5 GB) | feat/onboarding-adjustments, 24 dirty, 2 ahead, no upstream | `roll-13-investigations` 8 windows (6 Claude idle, 2 pi idle, 2 shells) | `.eph/onboarding-adjustments` | rename to `onboarding-adjustments` | pod install before iOS build; push first is advisable (24 dirty files exist only here) |
| M7 | `.eph/env-protection` | already ephemeral | `roll-deferred`:6 `staging-concerns` (Claude awaiting) | unchanged | new session `env-protection`, move window 6 into it | none |
| M8 | `.eph/platform-supabase` | already ephemeral | `roll-deferred`:11 `staging salvage?` (nvim) | unchanged | new session `platform-supabase`, move window 11 into it | none |
| M9 | after M4 to M8 `roll-deferred` holds only windows 5 `z` (Claude working in content-engine-1) and 12 `lane-monitor` | | | | left for the content-engine-1 consolidation (B4) with `roll-scheduling` and `roll-10-yap-integration` | |
| M10 | end of batch | | | | chat merge pass, then `resurrect_save.sh` and verify | |

Not in this batch: content-engine-1 (main checkout, stays), the nested
`.claude/worktrees` under content-engine-5 (two are STALE-CLEAN, one UNKNOWN;
batch 3), every worktree without panes.

User, 2026-10-31 (verbatim): "We need to be careful about the roll-deferred
chats as they are definitely valuable. Perhaps what is cleaneest is that
each chat is moved to its own worktree and rebased as a new agentic chant
using the same thread on that new worktree per deferred task? You should
smoke test this approach for correctness and retention ofthe chat without
braekding it using the roll-deferred chats before I let you do this to any
other chats / worktrees (ie ESPECIALLY for feat/scheduling-init - which must
be untouched)". Batch 2 above is on hold; batch 2a replaces its chat
handling.

### Batch 2a: one worktree per deferred chat, smoke test first (proposed 2026-10-31)

How a Claude chat is keyed on disk (checked 2026-10-31, Claude Code 2.1.316):

- The running process is listed in `~/.claude/sessions/<pid>.json` with its
  `sessionId` and `cwd`. The tmux pane's `@agent_pid` option gives the pid.
- The transcript is `~/.claude/projects/<cwd with / replaced by ->/<sessionId>.jsonl`
  plus a sibling directory `<sessionId>/subagents/` with the subagent
  transcripts. Most lines carry a `cwd` field (the directory at that turn)
  and a `gitBranch` field (informational).
- The picker's state comes from hooks the Claude process fires, which pass
  the transcript path themselves, so a resumed chat in a new pane is tracked
  normally.

Dry run on a throwaway chat (scratch directories A and B, both removed
after): `claude -p --resume <id>` from B without moving the file found the
chat and recalled the code word, but wrote the continuation into A's
project folder, so the chat stays filed under the old directory and B's
resume list would not show it. After copying the `.jsonl` and its
`<id>/` directory into B's project folder with `cwd` patched to B, resume
from B recalled the code word and wrote the continuation into B's copy.
Recipe per chat: copy transcript and subagent dir into the new project
folder, patch `cwd`, start `claude --resume <id>` in the new worktree,
remove the original only after the user confirms.

The eight `roll-deferred` chats (pid, session id prefix, size, subagents,
branch the chat worked on, last write):

| Window | Chat | pid | id | Size | Subagents | Branch then | Worktree now | Last write |
|---|---|---|---|---|---|---|---|---|
| 1 mutli-scene-layers | Multi-slide text dragging and layer implications | 35904 | 6043ad4b | 632K | 10 | feat/carousels-init (merged) | content-engine-5 | Oct 16 |
| 2 text-carousel-export-parity | Sonnet subagent Skia text alignment carousel exports | 36247 | e4532029 | 2.1M | 14 | feat/carousels-init (merged) | content-engine-5 | Oct 16 |
| 3 download-original | Template original video download optimization | 36643 | 75673075 | 372K | 2 | feat/carousels-init (merged) | content-engine-5 | Oct 16 |
| 4 onboarding-funnel-flexibility | Draft page swipe gesture navigation | 36977 | 5e7c9e42 | 1.1M | 0 | feat/carousels-init (merged) | content-engine-5 | Oct 16 |
| 6 staging-concerns | BG-UPGRADE F1B5FB69 iCloud scene failure | 81698 | ad907d45 | 9.7M | 78 | chore/non-prod-environment-protection (2 ahead) and six others | `.eph/env-protection` | Oct 31 |
| 7 search-results | TanStack website search results | 40797 | e0b4cf05 | 3.1M | 8 | feat/web-funnel-improvements-1 (1 ahead) | content-engine-4 | Oct 16 |
| 8 protect-environments | Advertorials system architecture and implementation | 40120 | 3d846359 | 17M | 58 | feat/web-funnel-improvements-1 (1 ahead) | content-engine-4 | Oct 16 |
| 9 figma-linx | Figma scripting in headless Linux VMs | 48735 | 4e998c00 | 1.2M | 2 | feat/web-funnel-improvements-1 (1 ahead) | content-engine-4 | Oct 31 |

Windows 5 `z` and 12 `lane-monitor` are content-engine-1 (`feat/scheduling-init`)
and are not touched. Window 11 `staging salvage?` is an nvim pane in
`.eph/platform-supabase`, no chat.

Smoke test (S1), proposed on window 3 `download-original`: the smallest
chat, idle since Oct 16, whose branch is merged.

1. `git worktree add .eph/download-original -b feat/download-original origin/main`
   with `GIT_LFS_SKIP_SMUDGE=1`; copy `.env*` from content-engine-1 except
   `.env.ports` and `.env.branch`; write `.env.ports` for the next free
   block; `pnpm install --prefer-offline` in the new session's first window.
2. Copy `75673075-….jsonl` and `75673075-…/` into
   `~/.claude/projects/-Users-kalemedlin-Developer-content-engine-trees--eph-download-original/`,
   patch `cwd` from `…/content-engine-5` to `…/.eph/download-original`.
   Original files stay in place.
3. In `roll-deferred:3` send `/exit` to the idle Claude (pid 36643), so no
   process writes to the old copy.
4. `new-session -d -s download-original -c .eph/download-original`, window
   `download-original`, run `claudef --resume 75673075-3c0c-4049-afb2-cf877ca83917`.
5. Checks: the resumed chat shows the full thread; its `/status` cwd is the
   new worktree; the pane gets `@agent_state` from hooks; the new project
   folder gets the continuation; a `/resume` list from the new worktree
   shows the chat. Then the user reads it and confirms.
6. On confirmation: delete the original transcript and subagent dir from
   the content-engine-5 project folder, kill `roll-deferred:3`, save.

If S1 passes, the same recipe runs for windows 1, 2, 4 (base: `origin/main`,
branches merged), and for 6, 7, 8, 9 the user picks the base: `origin/main`
or the chat's branch (`chore/non-prod-environment-protection` for 6,
`feat/web-funnel-improvements-1` for 7 to 9, which is content-engine-4's
current branch and is 1 commit ahead with 7 dirty files).

S1 result (2026-11-02, passed, awaiting user confirmation for step 6).
User instruction for the run (verbatim): "do the smoke test and tell me
what to check and what SHOULD be maintained before we can move on to
replicating this across the board - assuming that the chats are ALL frozen
in done states (ie awiting input, completed, and NOT working) - use an opus
agent to drive this and the report results before moving on. Ideally we do
the tmux send key comamnds to do all the required moving / cleaning such
that I do not need to run any commands myself and I can use the existing
picker and tmux browsing to see if the moved sessions / chats are valid and
a good appraoch that we can apply to all". Split applied: the opus agent
ran every disk step (no tmux, standing rule), the orchestrator ran the tmux
steps.

What ran:

1. `GIT_LFS_SKIP_SMUDGE=1 git worktree add .eph/download-original -b feat/download-original origin/main`
   (origin/main 6c2a639dc). Models dir holds 13 LFS pointers of 128 to 134
   bytes, nothing downloaded.
2. `cp -c` of `.env.local` and `.env.production` from content-engine-1.
   `.env.ports` written as block k=1 (3100, 3110, 7600, 8181; blocks in use
   were 0 and 2 to 15, `lsof` clear). 13 lines of `.env.local` rewritten
   (`NEXT_PORT`, `DASHBOARD_PORT`, `ENGINE_PORT`, `EXPO_PORT`,
   `SERVER_ORIGIN`, `ENGINE_URL`, `DEEP_LINK_BASE_URL` and their
   `EXPO_PUBLIC_*` and `VITE_*` twins). `DATABASE_URL` left alone.
3. Transcript `.jsonl` plus `<id>/subagents/` copied with `cp -p` into the
   new project folder; 55 `cwd` fields patched in the main file, 183 in the
   one subagent file; line counts unchanged (99 and 151); every line still
   parses. Helper scripts: scratchpad `s1/rewrite_ports.py`,
   `s1/patch_cwd.py`, `s1/verify.sh`.
4. tmux: `send-keys /exit` to `roll-deferred:3.0` (pid 36643 exited in
   under a second; that `/exit` appended 4 lines to the SOURCE transcript);
   `new-session -d -s download-original -c .eph/download-original`; window
   `install` running `pnpm install --prefer-offline`; window
   `download-original` running `claudef --resume 75673075-…`.
5. Resume showed the full thread with the old timestamps (Sep 25), status
   bar `feat/download-original`, hooks stamped the pane (`@agent_pid`
   66311, state idle, cwd new worktree, name "Template original video
   download optimization"). `~/.claude/sessions/66311.json` has the new cwd.
6. One check turn ("run pwd and git branch, summarise last advice"): the
   chat answered with the new path, `feat/download-original`, and a correct
   one-sentence summary of its Sep 25 recommendation. The 40 new transcript
   lines all carry the new `cwd` and `gitBranch: feat/download-original`;
   they were written to the NEW copy (100 to 140 lines) and the source
   stayed at 104. The `-- INSERT --` prompt needed a second Enter because
   tmux delivered the long prompt as a bracketed paste; only matters for
   send-keys driven turns.

Findings that change the recipe for the rollout:

- Exit the old process BEFORE copying, not after. Its `/exit` writes to the
  source copy; copying afterwards keeps everything in one place.
- Move, do not copy. Two copies of one session id resolve by a rule we did
  not pin down (the dry run suggested newest mtime wins). With `cp -p` both
  had the same mtime and the new process still chose the new folder, but
  there is no reason to leave the ambiguity. The source goes to a scratch
  backup until the user confirms, then is deleted.
- Replayed `agents-md: … content-engine-5/AGENTS.md` lines in the resumed
  view are history from the old cwd, not a fresh load. New turns run in the
  new cwd (proved by `pwd`).
- Old `gitBranch` fields stay stale (informational only).
- `pnpm install` must run before any dev server; Pods are absent (fresh
  worktree); LFS skip applies only to `worktree add`.
- The old window stays as a bare zsh until killed.

S1 close-out (2026-11-02): the user confirmed from the picker and the chat
("I think this worked correctly!"). Source transcript and its subagent dir
moved to the session scratchpad `s1/backup-src/` (not deleted yet); the bare
`roll-deferred:3` window killed; `resurrect_save.sh` run, snapshot
`tmux_resurrect_20261102T141734_92506_9799.txt` lists the new session.

### Batch 3: fold every non-working chat into its own worktree (proposed 2026-11-02)

User intent (verbatim, 2026-11-02):

> wait apply this same practice to all chats/sessions except those in:
> co feat/agentic-harness and co feat/scheduling-init
> To be specific, leave these alone but fold everything else out:
> 70120c95-4b47-44ca-8adf-592530240cac chat and the [Image #7] 3 pans in this z window.
> 58f80135-5e73-4d6f-a431-f7d75068b08e chat and the "topology" window and the "brute" window too please w/ chat: bb6fb67e-a2b4-41dd-a1f4-662bced32f91 and 758a8597-d5ab-4200-b389-b983878f3641
> those are the ones that are currently working and I want them to KEEP Their current OWNED dirty workrtrees of the branches they live on.  All other chats on those branches that are not currently working or not referenced here can be folded into their own work trees or whatever you want there. Or propose back to me things that need to be closed out because they're done. Some of them are active investigations that would probably be best suited for their own work trees instead of on these ones that I've referenced s

Live inventory (read-only, 2026-11-02 14:25). Chat ids are the first 8
characters; "last" is the last transcript timestamp; sizes are transcript
sizes.

Protected (untouched):

| tmux target | chat | dir / branch | note |
|---|---|---|---|
| roll-scheduling:1 z (3 panes) | 70120c95 (awaiting) + 2 nvim | content-engine-1 feat/scheduling-init, 21 dirty | user-named |
| roll-6-agentic-engineering:1 topology | 58f80135 (awaiting) + nvim | content-engine-6 feat/agentic-harness, 5 dirty, 13 ahead | user-named |
| roll-6-agentic-engineering:2 brute | 758a8597 (idle), bb6fb67e (working), zsh | content-engine-6 | user-named |
| dotfiles:3 | fb7beae7 (this chat) | dotfiles | |
| processes, remotion, dotfiles:1-2 | shells, nvim | | one dir each already |

Holds (cannot move now):

- H1 `roll-deferred:4` "x", chat 617efdf6, cwd content-engine-1, is WORKING
  (a general-purpose subagent has run a "hang harness" for 1h49m; its work
  is on nested worktree `.claude/worktrees/agent-a8e1f863a6572c994`, branch
  `fix/font-catalog-bound-parameter`). Fold out after it stops.
- H2 `astra:1` pi chat in content-engine-11 (feat/editor-overhaul, clean,
  12 ahead). pi stores sessions flat under `~/.pi/agent/sessions/` now and
  the resume-by-id path is unverified, so no pi chat moves in this batch.
  The slot itself moves in Batch 2 (`git worktree move`, pi keeps cwd).

Group A, content-engine-5 (branch `feat/duplicate-asset-grouping`, fully
merged into main, 2 dirty doc files). Base for every new worktree: origin/main.

| code | tmux target | chat | last | what it is | proposal |
|---|---|---|---|---|---|
| X1 | roll-5-carousels-release:3 rendering | 397dee30 5.8M | Sep 30 | viewshot thumbnail removal, rendering dev-tools test reminder | move to `.eph/rendering` |
| X2 | roll-5-carousels-release:4 icloud-issues-STILL | 9875bdd2 11M, 39 sub | Sep 27 | iCloud bottleneck pivot (docs/tasks/icloud) | move to `.eph/icloud-pivot` |
| K1 | roll-5-carousels-release:5 release-residuals | f80e3a02 8.5M | Oct 8 | 1.0.2 ship-plan fold-in; release shipped; owns the 2 dirty docs (`docs/pending-backfills.md`, `docs/tasks/release-1.0.2-ship-plan.md`) | close; save the doc diff as a patch in scratchpad, then discard |
| K2 | roll-5-carousels-release:6 IP-local-bias | 584408e0 157 lines | Oct 5 | single question on 90k-item sync bias | close |
| X3 | roll-9-broll-duplicate-assets:1 | 12173fc1 | Oct 12 | on-device duplicate detection research | move to `.eph/duplicate-assets` |
| X4 | roll-deferred:1 mutli-scene-layers | 6043ad4b | Sep 27 | text drag across scenes | move to `.eph/multi-scene-layers` |
| X5 | roll-deferred:2 text-carousel-export-parity | e4532029 | Sep 27 | native vs export parity | move to `.eph/text-carousel-export-parity` |
| X6 | roll-deferred:3 onboarding-funnel-flexibility | 5e7c9e42 | Sep 28 | swipe-back on draft page / stack rebuild | move to `.eph/onboarding-funnel-flexibility` |

Shell-only panes in these sessions (`pnpm`, `miscellanious`, 5 spare zsh
panes) die with the sessions. After Group A content-engine-5 holds no chat;
its removal (and its 3 clean nested worktrees) is a Batch 2 item.

Group B, content-engine-4 (branch `feat/web-funnel-improvements-1`, 1
unmerged docs commit, 7 dirty `packages/native-tools/src/specs/*.nitro.ts`).

| code | tmux target | chat | last | what it is | proposal |
|---|---|---|---|---|---|
| X7 | roll-web-funnel-changes:1 codes-referrals | 8f40eba9 9.6M | Oct 30 | web funnel regression check, quick wins | owner of the branch: move the worktree itself to `.eph/web-funnel-improvements` (`git worktree move`, dirty files travel), session `web-funnel-improvements` |
| X8 | roll-deferred:6 search-results | e0b4cf05 | Oct 12 | TanStack site search-result detail (SEO) | move to `.eph/search-results` from origin/main |
| K3 | roll-deferred:7 protect-environments | 3d846359 17M, 29 sub | Oct 12 | affiliate pages; its last turn started a new worktree and `.eph/advertorials` exists (9 dirty, Oct 6) | close (alternative: move to `.eph/advertorials`) |
| X9 | roll-deferred:8 figma-linx | 4e998c00 awaiting | Oct 20 | Figma scripting from a Linux VM | move to existing `.eph/figma-linux` (4 dirty) |

Group C, content-engine-13 (branch `feat/onboarding-adjustments`: 2 unmerged
commits = grafana evidence fix (PR #490 closed, not merged) plus a merge of
main; 24 dirty files = account-link flow + support reference number work).

| code | tmux target | chat | last | what it is | proposal |
|---|---|---|---|---|---|
| X10 | roll-13-investigations:5 link-account-refernece | afc0b105 | Oct 6 | Apple ID link failure, support reference number; owns the dirty files | owner: move the worktree itself to `.eph/onboarding-adjustments`, session `onboarding-adjustments` |
| K4 | roll-13-investigations:3 | 15aa9f8b | Sep 27 | grafana false positive, post mortem written | close |
| K5 | roll-13-investigations:4 | 625e90cb 12 lines | Sep 27 | empty chat | close |
| K6 | roll-13-investigations:6 onboarding-succcess-rates | 016a9f66 181 lines | Oct 6 | 1.0.2 onboarding success check | close |
| X11 | roll-13-investigations:7 | e25213dc 2.2M | Oct 8 | grafana paging alert, browse-quota readback (its staged `docs/tracking/browse-quota-readback.md` stays in X10's worktree) | move to `.eph/grafana-readback` from origin/main |
| X12 | roll-13-investigations:8 ben-instagram-camera | 0e00d16b | Oct 8 | user report, missing photos | move to existing `.eph/ben-missing-photos` (1 dirty) |
| Q3 | roll-13-investigations:1 assets-no-match, :2 elliotmurphy | pi chats | | small investigations (36k, 68k tokens) | kill, or hold as windows of `onboarding-adjustments` until a pi recipe exists |

Group D, content-engine-1 chats outside the protected z window.

| code | tmux target | chat | last | what it is | proposal |
|---|---|---|---|---|---|
| X13 | roll-scheduling:2 | 49ab36ad awaiting | Oct 30 | creator profile access by UUID (security) | move to existing `.eph/creator-profile-access` (clean) |
| X14 | roll-scheduling:3 | 9be6fb9a | Nov 2 | ASC developer access for Usman, PR #643 channel protection; next steps are manual (merge, invites) | move to `.eph/asc-developer-access` from origin/main (or close if you consider the checklist done) |
| X15 | roll-scheduling:4 | 2570dba9 | Nov 2 | crash investigation for one user | move to `.eph/crash-report-wakeforest` from origin/main |
| X16 | roll-10-yap-integration:1 "FUCKING PRS" | 17f04b68 awaiting | Oct 30 | yap integration PRs | move to existing `.eph/yap-release` (`integration/release-1.0.4-yap`) |
| K7 | roll-deferred:10 lane-monitor | zsh | | bare shell in content-engine-1 | kill |

Group E, already in their own worktree, only the session is wrong (no
transcript move, `tmux move-window` into a session named after the dir).

| code | tmux target | chat | proposal |
|---|---|---|---|
| X17 | roll-deferred:5 staging-concerns | ad907d45 awaiting, `.eph/env-protection` | new session `env-protection` |
| X18 | roll-deferred:9 "staging salvage?" | nvim only, `.eph/platform-supabase` (6 dirty .err files) | new session `platform-supabase` |
| K8 | roll-3-revenue:1 gst | zsh only, content-engine-3 (3 dirty docs, 2 ahead) | kill the session; the worktree is a Batch 2 decision |
| K9 | roll:1 [empty] | zsh in ~ | kill (the `home` session returns on demand in B3) |

Non content-engine sessions (agent-reach, pipeline-agent-idea,
reverse-engineer-anything) already hold one directory each; only renames
later (B4). Untouched here.

Recipe per X move (from S1): confirm `@agent_state` is not working; send
`/exit`; move transcript + subagent dir to the new project folder; patch
`cwd` in every line; `git worktree add` (new) with `GIT_LFS_SKIP_SMUDGE=1`;
next free `.env.ports` block (16 upward: NEXT 4600+, EXPO 10681+); copy
`.env.local`/`.env.production` with ports rewritten; new session named after
the dir with a `claudef --resume <id>` window; verify pwd/branch; kill the old
window; `resurrect_save.sh` after each group. K close: send `/exit`, kill
the window, transcript stays where it is (nothing deleted).

Risks:

- R-disk: `node-linker=hoisted` copies files (link count 1), 3.3 to 3.5 GB
  per worktree; 79 GB free. 11 new worktrees at full install is about 38 GB.
  Proposal: no `pnpm install` in this batch; each chat installs on first
  need (the `install` window pattern from S1 stays available).
- R-pods: fresh worktrees have no Pods or DerivedData; any iOS build is a
  full build.
- R-move: X7 and X10 move a worktree with dirty files (`git worktree move`
  keeps them); Pods in those two embed the old absolute path.

User decisions on Batch 3 (verbatim, 2026-11-02):

> processes and remotion are gone. I closed them.
> roll-deferred "x" is NOT running anymore and can be folded into its own worktree for further actioning since its tasking is not done.
> I killed the astra one - no need to know if pif restores like claude code for this one time set of clean up operations I dont think
> I think everyhting that is proposed to MOVE shoudl be moved - i will be able to see if they shoudl be cleared later with the tooling once it is working as this initaive intendeds whre I can easily delete and clear!
> K1 that shit has shipped along while ago - we can clear whatever is still hanging around as it is likely NoT useful anymore..
> K2: Not sure what you are talking about here at all..
> K3: Im pretty sure the advertorials work has already long since shipped - im not sure if anything here is valuable to reatin - reread and repropose.
> K4, K5 and K6 may all just be shit we can clear. No grafana false-positive haves come up in the last couple weeks so im assuming that is done!
> Close out all other ks
> iF you can smoke test moving one o the pi intances from roll-13 before we commit to that that would be great!
> No pnpm install on new worktres please

#### S2: pi smoke test (2026-11-02, passed)

Chat "Elliot Murphy account investigation" (pi, roll-13 window 2, session
`01a0d065-…`). Under the `pif` wrapper pi stores sessions FLAT in
`~/.pi/agent/sessions/` (`PI_CODING_AGENT_SESSION_DIR`), one file per
session, cwd only in the line-1 header. Recipe: `/quit` (NOT `/exit`: pi
treats `/exit` as a prompt and the model answered "Session closed."; those
two lines were stripped before resume), patch the header `cwd`, new session
named after the dir, `pif --session <id>`. First launch asked "Trust project
folder?"; answered "Trust parent folder (.eph)" so every fold-out is covered
(`~/.pi/agent/trust.json`). Resumed with the full thread, same token count,
picker options stamped, check turn answered pwd/branch correctly and appended
to the same file (49 to 53 lines).

#### Batch 3 outcome (2026-11-02 14:49)

Done, all verified by pane options (`@agent_cwd` = new worktree, branch in
the status line) and a resurrect save
(`tmux_resurrect_20261102T144901_37388_25785.txt`, sidecar carries the
resume ids):

- 12 new worktrees `.eph/<name>` on branch `wt/<name>` from origin/main
  6c2a639dc, port blocks 17 to 28 (next free 29), `.env.local` ports
  rewritten, no install: rendering, icloud-pivot, duplicate-assets,
  multi-scene-layers, text-carousel-export-parity,
  onboarding-funnel-flexibility, search-results, grafana-readback,
  asc-developer-access, crash-report-wakeforest, font-catalog-hang (X19,
  the "x" chat; its branch `fix/font-catalog-bound-parameter` is merged, so
  base main), assets-no-match (pi). Plus elliotmurphy (block 16, S2).
- Moved into existing worktrees: figma-linux, ben-missing-photos,
  creator-profile-access, yap-release.
- Worktrees moved whole with their dirty files (`git worktree move`):
  content-engine-4 to `.eph/web-funnel-improvements` (owner chat 8f40eba9),
  content-engine-13 to `.eph/onboarding-adjustments` (owner chat afc0b105).
- Sessions created by `tmux move-window`: env-protection, platform-supabase.
- Closed (process exited, window killed, transcript left in its old project
  folder): K1 f80e3a02 (its two dirty docs in content-engine-5 saved as
  `scratchpad/b3/k1-content-engine-5-docs.patch` then discarded; worktree
  now clean), K2 584408e0, K4 15aa9f8b, K5 625e90cb, K6 016a9f66, K7, K8
  (roll-3-revenue), K9 (roll). K3 3d846359 exited and its window killed,
  transcript still under the content-engine-4 project folder pending the
  repropose below.
- content-engine-5 now has no chat and no dirty file; content-engine-4 and
  -13 no longer exist as paths. Batch 2 shrinks to: remove content-engine-5
  (and its 3 clean nested worktrees), decide content-engine-3 (3 dirty
  docs), content-engine-11 (editor-overhaul, clean, 12 ahead, chat killed).
- Sessions now (28): the 21 worktree sessions above, download-original,
  roll-scheduling (z only), roll-6-agentic-engineering, dotfiles,
  agent-reach, pipeline-agent-idea, reverse-engineer-anything.

Incidents during the batch (recorded so the recipe improves):

- Claude Code: `/exit` typed by send-keys landed as text in 5 panes that
  were in vim normal mode; one chat (asc-developer-access, 9be6fb9a) got a
  stray "t" turn and answered "stray keystroke". Double Ctrl-C exits
  reliably regardless of input mode; use it in the `wt` script.
- Starting 15 shells at once hit the zshrc `pyenv rehash` lock (60 s wait
  each, one stale lock removed). Stagger launches or skip rehash in agent
  shells.
- Three nvim panes in content-engine-4 held unnamed modified scratch
  buffers (one short line each, visible: "1", "1", "18 stay quiet because
  the"). The save-before-quit used `:w >> file` on a file that did not
  exist, so the write failed silently and `:qa!` discarded them. Next time
  `:w file` (no append) or read the buffer with capture-pane first.
- An orphan headless `nvim --embed` (pid 44644, from the 2026-10-13 resurrect
  restore) still had its cwd in content-engine-13; killed.
- tmux renumbers windows on kill, so kill by `#{window_id}` not index.

K3 repropose (chat 3d846359, from the opus reread): the advertorials
(PR #507) and landing follow-ups (PR #508) shipped, and the task docs were
retired into notes. What is NOT done: the environment-gate plan the chat
wrote in `docs/tasks/tanstack-control-and-safety.md` (on main, status "plan,
not started"); its last turn created `.eph/env-access-gate` (branch
`feat/env-access-gate`, no commits beyond main) and asked decisions D4 to D7
and Q1 to Q3 that were never answered, including a flag that the Vercel
bypass key ships in every preview and staging web bundle. The 9 dirty files
in `.eph/advertorials` look like an earlier draft of PR #508 (header.tsx
matches the shipped commit exactly). Proposal: move 3d846359 into the
existing `.eph/env-access-gate`; discard `.eph/advertorials` (Batch 2
removal). Alternative: close it and keep only the task doc on main.

K3 resolution (2026-11-02). User: "Do whatever you propose here. but i
thought it migh belong on / with this overlapping topic branch right??:
chore/non-prod-environment-protection". Confirmed: that branch's own commit
"opens the environment-protection initiative" and the K3 plan is the
preview/staging admission gate, same topic. Done: chat 3d846359 moved into
`.eph/env-protection` and resumed as window `env-access-gate` of session
`env-protection` (pid 71573, status line shows
`chore/non-prod-environment-protection`); `.eph/env-access-gate` removed and
branch `feat/env-access-gate` deleted (its only content was an untracked copy
of `docs/tasks/tanstack-control-and-safety.md`, byte-identical to main);
`.eph/advertorials` removed and merged branch `feat/advertorials-polish`
deleted after saving its draft to `scratchpad/b3/advertorials-dirty.patch`
and `advertorials-untracked/`. Snapshot
`tmux_resurrect_20261102T150736_74954_1939.txt`.

### Batch 2 (stale sweep) outcome, executed 2026-11-02

User instruction: "just figure it out and do next steps please". Policy I
applied without further asking: only lossless operations. A worktree with
zero dirty files goes; its local branch is deleted only when already merged
into origin/main, otherwise the branch stays in git; anything dirty is kept
and listed here. Removal log: `scratchpad/b3/removals.log`
(`/private/tmp/claude-501/-Users-kalemedlin-Developer-dotfiles/fb7beae7-09e5-4609-867f-0abb694691cb/scratchpad/b3/removals.log`).

Result in one line: 70 worktrees removed, 5 dirty slot worktrees moved into
`.eph/` keeping their dirt, 0 skipped, 0 failed, 4 orphan Xcode caches
deleted, disk free 93 GB to 159 GB. Snapshot
`tmux_resurrect_20261102T161053_72443_13191.txt`. All 28 sessions still
have a valid pane cwd.

Removed, clean and merged, branch deleted (48): the slot dirs
`content-engine-5`, `content-engine-9`, `content-engine-billing-side-effects`,
`-billing-switch-copy`, `-fix-grafana-uid`, `-funnel-amendments`,
`-period-end-downgrade`, `-return-origin`, `-visualizer`,
`web-funnel-followup`, `active/onboarding-perf`; the `.eph/` dirs `alerting`,
`carousel-feed-metrics`, `carousels-server`, `editor-overhaul-docs`,
`editor-sheets-pass`, `fixes-2026-10-22`, `font-catalog-api`,
`gestures-port`, `import-observability-v2`, `naming-alignment`, `oom-fix`,
`release-102-compat-fixes`, `release-main-sync`, `release-sync`,
`text-stroke-bg`, `trial-reactivation`, `yap-549`, `yap-550`,
`yap-hook-api`; 18 nested `content-engine-1/.claude/worktrees/agent-*` and
`content-engine-5/.claude/worktrees/track-ux`. Branch names are in the log.

Removed, clean but unmerged, branch kept in git (22): `content-engine-10`
[feat/onboarding-wave1-experiments], `-14` [fix/staging-migration-repair],
`-15` [fix/admin-template-legacy-heuristic-save], `-16`
[fix/circle-alert-accuracy], `-selection-resp`
[feat/editor-selection-responsiveness], `active/content-engine-sync-release`
[feature/duration-unit-rename], `active/content-engine-creator-clean`
[fix/restore-scene-count-chip, 5 unpushed commits; its only dirt was the
deleted LFS model files], `pr-524-yap-export-all` (detached, no branch),
`.eph/legacy-drafts-cutoff`, `.eph/retire-worktree-claim-1`,
`.eph/tanstack-patch`, `.eph/yap-logic-fixes`, `content-engine-5/.claude/
worktrees/aspect-ratio-impl` and `slide-ux-pass`, and 9 nested agent
worktrees under `content-engine-1/.claude/worktrees` (jwt-claims-version,
trial-never-paid, agent-a1a3c4f2, agent-abe32b08…, agent-ae7362e8…, three
`worktree-agent-*` branches). `git branch -d` on any of these later is a
one-liner once their content is confirmed landed.

Moved with `git worktree move` (dirt, node_modules and Pods ride along,
nothing copied or installed):

| From | To | Branch | Dirty |
| --- | --- | --- | --- |
| content-engine-3 | `.eph/nointro-approved-smoke` | docs/nointro-approved-smoke | 3 docs |
| content-engine-7 | `.eph/content-sync-downloads` | fix/content-sync-downloads (6 ahead) | 2 untracked docs |
| content-engine-8 | `.eph/editor-preview-polish` | feat/editor-preview-polish (merged) | `docs/tasks/cicd-consolidation.md` |
| content-engine-12 | `.eph/usearch-index-sync` | fix/usearch-index-sync-robustness (5 ahead of origin/staging) | 3 docs |
| content-engine-11 | `.eph/editor-overhaul` | feat/editor-overhaul (12 ahead, pushed) | clean, heavy build kept |

None of the five has a tmux session yet; they appear in the picker list
once B2 (list all worktrees) lands, or `prefix o` plus `N` today. Caveat:
CocoaPods embeds absolute paths, so `.eph/content-sync-downloads`,
`.eph/editor-preview-polish` and `.eph/editor-overhaul` need `pod install`
before an iOS build from the new path. One shell (pid 81429, under the
`env-protection:env-protection` chat) still had cwd `content-engine-8` from
before its chat was relocated; the rename carried the handle along.

Deleted outside git: `active/` (empty after the two removals) and four
orphan DerivedData caches whose WorkspacePath no longer exists:
`RollPreview-ackqw…` (content-engine-5, 8.3G), `RollPreview-dncuh…`
(content-engine-9, 8.3G), `RollPreview-abvam…` (content-engine-11, 6.1G),
`RollPreview-fwcrv…` (content-engine-8, 7.4G), plus `gestures-port` (5.5G)
earlier in the sweep.

Kept and listed at first, resolved by the user in the follow-up below:

- Nested dirty agent worktrees under `content-engine-1/.claude/worktrees/`:
  `sync-gate-tutorial-owner` (12 dirty, last commit 2026-10-12),
  `agent-a9c9d70d757f625aa` (4 dirty, 2026-10-30, locked),
  `agent-a2c7c90f` (2 dirty, 2026-03-22), `agent-aa6a95ef` (5 dirty,
  2026-03-22). All 0 ahead of origin/main, so the dirt is the only content.
- `content-engine-trees/yap-trial`: standalone clone, not a worktree
  (feat/yap-text-sheet-icon-tabs, 1 dirty, 3.9G) plus its DerivedData
  `RollPreview2-agnjn…` (9.2G).
- Non-git dirs in `content-engine-trees`: `content-engine`, `designs`,
  `font-catalog-staging`, `hiring-notes`, `latest-editor`,
  `looter-examples`, `minified-repo`, `reverse-engineering`.

L1 to L3 follow-up (2026-11-02). User: "L1 ... Dont leave them in here?
Moe them out to the standard place", "L2 ... Get rid of this - no yap-trial
needed anymore - its on remote and remembered already.", "L3 ... Give them
proper ports please!". Done:

- L1: the four nested worktrees moved with `git worktree move` to
  `.eph/sync-gate-tutorial-owner`, `.eph/agent-a2c7c90f`,
  `.eph/agent-a9c9d70d757f625aa` (unlocked first), `.eph/agent-aa6a95ef`,
  dirt intact; `content-engine-1/.claude/worktrees/` removed. Names kept
  as they were; rename with `R` once the picker has it.
- L2: `yap-trial` deleted (its HEAD bf3b9c4 is in its remote main via
  PR #93; remote branch already gone; 0 stashes) together with its
  DerivedData `RollPreview2-agnjn…` (9.2G). Its one untracked file,
  `docs/tasks/yap-pipeline-fixture-harness.md` (not on any main), is saved
  at `scratchpad/b3/yap-trial-untracked/docs/tasks/`.
- L3: port blocks assigned, `.env.ports` written, `.env.local` and
  `.env.production` copied from content-engine-1 where missing and
  rewritten with `rewrite_ports.py` (13 port-bearing keys in
  `.env.local`, none in `.env.production`), `.env.branch` never copied.
  Blocks: ben-missing-photos 4, creator-profile-access 8,
  env-protection 9, figma-linux 13, platform-supabase 14 (had its own
  files at defaults, rewritten in place), yap-release 15,
  sync-gate-tutorial-owner 29 (own `.env.local`, rewritten),
  agent-a2c7c90f 30, agent-a9c9d70d757f625aa 31, agent-aa6a95ef 32. Every
  worktree now has a unique NEXT_PORT (3000 to 6200, step 100; blocks
  0 to 32 used, next free 33). Pre-rewrite copies of the files that
  already existed are in `scratchpad/b3/env-backup/<worktree>/`.

Incident during L3 (fixed, no effect): `.eph/agent-a9c9d70d757f625aa/
.env.local` was a symlink to `content-engine-1/.env.local` (Claude Code's
own agent-worktree setup does that), so the block-31 rewrite went through
the link and changed content-engine-1's ports for about four minutes.
Nothing was listening on 3000/3010/7500/8081 in that window. Restored
byte-identical from the backup, the symlink replaced with a real file,
agent-aa6a95ef recopied from the restored source. No env symlink remains
under content-engine-1, content-engine-6 or `.eph/`. Rule for B1: `wt`
copies env files, never follows or creates symlinks, and refuses a source
`.env.local` that is itself a symlink.

State after the sweep: `content-engine-trees` holds `content-engine-1`
(main checkout, feat/scheduling-init), `content-engine-6`
(feat/agentic-harness), `.eph/` with 31 worktrees plus three non-worktree
items inside it (`braze-marketing-handoff.md`, `web-funnel-code`,
`web-funnel-figma`), and the non-git dirs `content-engine`, `designs`,
`font-catalog-staging`, `hiring-notes`, `latest-editor`, `looter-examples`,
`minified-repo`, `reverse-engineering`. No nested worktrees, no `active/`,
no `yap-trial`. B0 hygiene is complete; next is B1 (`wt` script).

## Layout change and final fold (proposed 2026-11-02, D14)

User (verbatim): "Im actually not a big fan of the content-engine-trees dir
naming or anything like that. PLUS is the content-engine-trees/.eph out of
the two step check in ~/Developer/{here} and ~/Deveoper/[dir]/{here}

just start with fthe first step tbh I just wnat to start using this stysatem
- maybe not just teh first step as I really want ot start testing the full
final outcome intended for this tasking.  also while we are at it, PLEASE
fold the worktrees for feat/agentic-harness and feat/scheduling-init into
their own worktrees so i no longe rhave to see content-engine-1 and
content-engine-6 naming convenstios as its annoying and messy. Make sense?
Do so WITHOUT disrupting their contents / current active panes / nvim
buffers / chats please - I want to be able to resume the converstainos from
eaxctly where they were left"

Answer on discovery: `.eph/*` is found. The main checkout
`content-engine-trees/content-engine-1/.git` is at depth 2, and every
linked worktree is read from that repo's `git worktree list`, at any depth.
Nothing changes in discovery under the new layout.

D14 proposed layout (one `mv` for the parent, one per worktree, then
`git worktree repair` with the new paths; session names do not change
because they are already the directory basenames):

```
~/Developer/content-engine/            project folder (was content-engine-trees)
  main/                                the git main checkout, on branch main (was content-engine-1)
  scheduling-init/                     feat/scheduling-init, new linked worktree, takes the 8 dirty docs + 1 untracked from content-engine-1
  agentic-harness/                     feat/agentic-harness (was content-engine-6, renamed)
  rendering/ icloud-pivot/ ... x31     every .eph/<topic> moved up one level, flat, nothing hidden
  designs/ hiring-notes/ ...           the non-git dirs stay as they are (picker ignores them)
```

Session for the main checkout is `main` (created on demand, never deleted
by `D`); if a second repo ever adopts the layout, `main` gets a repo
prefix, decided then. `wt new` creates siblings of `main`.

Migration M (all by the orchestrator over send-keys, no subagent touches
tmux; same recipe as Batch 3 and S1):

- M1 capture: resurrect save; inventory every pane; copy the three
  modified nvim buffers to the scratchpad as insurance (98786 in
  roll-scheduling holds `/private/tmp/important-scheduling.md`, 52331 in
  roll-6 holds one unnamed buffer, 59646 in platform-supabase one more).
- M2 exit the 23 claude chats (double Ctrl-C) and the 2 pi chats
  (`/quit`). Shells and nvim keep running; a directory rename carries
  their cwd handles along on APFS.
- M3 renames: parent, main, 31 worktrees, content-engine-6; `git worktree
  repair <new paths>`; new `scheduling-init` worktree from the same commit;
  copy its dirt over and `git checkout -- .` in main; `git switch main`;
  `cp -c` (APFS clone, instant, no extra space) node_modules from main into
  scheduling-init so the chat can still run tests.
- M4 path-keyed state: move each transcript folder and patch `cwd` (S1
  recipe) for all chats including 758a8597; copy the 9 `~/.claude.json`
  project entries to the new keys (trust, allowedTools); pi trust.json;
  `main/.claude/settings.local.json` paths; `GIT_WORKTREE_PARENT` in
  `zsh/.zshrc`; rename sessions `roll-scheduling` to `scheduling-init` and
  `roll-6-agentic-engineering` to `agentic-harness`; `cd` the two
  scheduling panes and `:cd` its nvim into `scheduling-init`; nvim 59646
  gets `:w`, `:mksession`, quit and `nvim -S` with patched paths only if
  it has buffers under the old path.
- M5 resume every chat in place with `claudef --resume <id>` and
  `pif --session <id>`; verify pane options; delete the two DerivedData
  entries keyed to content-engine-1 and content-engine-6; resurrect save.
- M6 separately: `content-engine-trees/content-engine` is a stale extra
  clone (2.8G, on main, last commit 2026-02-16, 1829 status lines). Propose
  delete.

Window of disruption: the chats are out for the few minutes between M2
and M5, same as Batch 3. Pods in main and agentic-harness embed absolute
paths and need `pod install` before the next iOS build, same caveat as the
moved slot worktrees.

B1 (`wt`) and B2 (picker list) started in parallel on 2026-11-02 with the
sibling layout as a one-line constant, so they do not wait on D14.

D14 outcome (executed 2026-11-02 17:52 to 18:01). User: "Do now with an
opsu subagnet please! Its ready - everything has stopped and is awiating
input and should be preserved that was running before." Split used: an opus
agent authored and ran every filesystem, git and transcript step
(`scratchpad/d14/d14.py`, phases preflight, migrate, verify; 74/74 verify
checks pass; log `scratchpad/d14/logs/migrate.log`; backups under
`scratchpad/d14/backup/`), the orchestrator alone sent the tmux keystrokes.

- Layout is now exactly the D14 drawing: `~/Developer/content-engine/`
  with `main` (clean, on `main` at origin/main 3c4ff9deb, hooks path
  fixed), `scheduling-init` (feat/scheduling-init at aabedf51c, all 113
  dirty and untracked files byte-identical to before, block 33, APFS clone
  of main's node_modules plus 22 nested ones: 49 s, 123 MiB of metadata),
  `agentic-harness` (dirt untouched), the 32 former `.eph` worktrees and
  the three loose items as flat siblings, `.eph` gone. `git worktree list`:
  35 entries, none prunable, every linked worktree's dirty hash equal to
  preflight. `auth-email-sender` got block 34 and env files.
- Chats: 23 claude chats exited with double Ctrl-C (one needed `/exit` as
  well: the scheduling chat had two background agents) and 2 pi chats with
  `/quit`; transcripts moved (24 project folders renamed, cwd patched; chat
  70120c95 split into the scheduling-init folder), `~/.claude.json` keys
  for main, scheduling-init and agentic-harness added, 6 pi session headers
  patched, pi trust.json gained the new parent, `GIT_WORKTREE_PARENT` in
  `.zshrc` updated. All 25 resumed in their own panes with the right ids
  and new cwds (verified from `~/.claude/sessions/*.json`); the scheduling
  chat shows the same 146.7k-token thread. pi resumes need the bare id
  after the underscore in the file name (`pif --session 01a0d067-…`), not
  the file name.
- Shells and nvim were never touched; cwd handles followed the rename. The
  shell under the scheduling chat and the one under the env-protection
  chat (still in content-engine-8's old place) were `cd`'d by send-keys
  first; the scheduling nvim got `:cd`. Three modified nvim buffers were
  copied to `scratchpad/d14/nvim-buffers/` beforehand (none needed).
- Chat 17f04b68 (yap-release) had entered `auth-email-sender` through
  Claude Code's own worktree feature; on exit Claude moved its transcript
  back to the yap-release folder, so it resumed from `yap-release` and the
  `yap-release` session keeps its name. `auth-email-sender` is a clean,
  session-less row.
- Sessions renamed: `roll-scheduling` to `scheduling-init`,
  `roll-6-agentic-engineering` to `agentic-harness`; and B4 for the two
  non-content-engine repos: `reverse-engineer-anything` to `rea`,
  `agent-reach` to `search-primitives` (its remote is agent-reach, so its
  badge reads agent-reach). `pipeline-agent-idea` stays a plain session (no
  repo). Snapshot `tmux_resurrect_20261102T180112_40653_30262.txt`, zero
  old-path references.
- Not done, user's call: delete `content-engine/content-engine` (the
  February clone); `pod install` in main and agentic-harness before the
  next iOS build; the dotfiles `.zshrc` change is uncommitted.

D93 (2026-11-02, user): "it thinks the project acronym is 'ma' but that is
just the main checkout branch - it shoudl be the repo's remote name as the
acyonrm right? and if not then the local file system name of the root dir?"
Done: the repo name is the last path component of `remote.origin.url`,
falling back to the directory; tests added, suites green, binary rebuilt.
Side effect: clones of one remote share a Tab group (`main` and
`latest-editor` both under content-engine), rows stay separate.

D94 (2026-11-02, user): "still seeing the following non worktree sessions
that I think shoudl be folded into their resective worktrees no?:
pipeline-agent-idea? It looks like its going to be posible to spin up
sessions that are NOT work tree based - and that is FINE, and they can be
in whatever number I want - not just one like I previuosly mentioned!"
Decision: plain (non-worktree) sessions are a first-class kind with no
count limit; R3's "single non-worktree session" is withdrawn. Nothing to
build: the picker already lists every such session as a plain row and
creates one from an unmatched query on `enter` or with `C-a C`
(`docs/tmux-agent-sessions.md`, "Keys and actions"). `pipeline-agent-idea`
has nothing to fold into: its one pane sits in
`~/Developer/examples/templating-test`, which is not a git repo, so it
stays a plain session. B3 must not remove or merge plain sessions.

D95 (2026-11-02, user, with two picker screenshots): "why are unopened
worktrees showing ABOVE the worktrees / sessions that have recent
acitivty?" and "this ordering is so random - i think its pretty clear what
the ordering should be like i made clear at the start of this thread".
Cause: a session's recency was attach time and pane focus stamps only
(D63, 2026-10-09: agent state changes deliberately did not reorder rows).
Every session restored on 2026-11-02 had neither until visited, so those
rows fell back to their worktree's git mtime (Oct 8 to Oct 20) and sorted
among bare rows by commit date, while their agents had just finished.
Fix: recency also takes each pane's newest agent state change (the time
the state chip shows), per V5 "last pane activity". A bare worktree still
ranks by its HEAD or index mtime, so one committed to yesterday sits below
a session idle for two weeks; that is the intended "last active" order.
D63's no-reorder rule is withdrawn for state changes; counts and states
themselves still do not reorder.


B3 outcome (2026-11-02). The picker's worktree lifecycle keys landed,
calling `wt` with `--json` (decisions D96 to D101 in
`docs/tmux-agent-sessions.md`). B3 shipped them as `C-a n`, `C-a N`,
`C-a p`, `C-a D`; the table shows the keys as moved by D103, and `C-a D`
as extended by D102.

| Key | Action |
|---|---|
| `C-a c` | Prompt `new worktree from main: `, `wt new <root> --branch B`, then create the new directory's session there and switch to it (picker exits) |
| `C-a C` | Same with `--from <row's branch>` (the commit when detached), prompt `new worktree from <branch>: ` |
| `C-a x` | Prompt `repurpose <dir> to branch: `, `wt repurpose`; exit 3 asks `dirty (N files): stash and switch? [y/N]` and reruns with `--stash`; stays open with the result and `needs install` / `needs pods` |
| `C-a D` | `wt status`, confirm `delete <dir>: <branch>, N dirty, N untracked, ↑A, <heavy>, <agents> [y/N]`, a tagged-stash confirm when dirty (`--force`), kill the session (rw-close for remote panes), `wt rm`, background `resurrect_save.sh quiet`, rescan. Since D102 a main row with no linked worktrees confirms `delete repo <repo> (whole checkout, to Trash): ...` and goes to `~/.Trash`, one with linked worktrees is refused with the repo filter set to it, and a missing row is pruned |

Deviations from V10 to V12 and R6 to R8:

- Keys sit behind the picker's `C-a` prefix, since bare letters are the
  query; repurpose was `p` because `C-a R` is rename session (D103 later
  moved it to `x`).
- No install of any kind after `new` (user decision; V10 and R6's
  `pnpm install` withdrawn).
- R18 skipped: `rw endpoints --focus-path` does not exist. Remote panes in
  the row's session close through the kill path; an endpoint with no pane
  there is not found.
- The Working refusal applies to `p` and `D` only; `new` changes nothing
  that exists. Main and missing rows are refused locally for `p` and `D`
  (wt does not refuse repurposing main); locked is refused for `D` only,
  with the reason from `wt status`. `D` also refuses the client's own row,
  since killing the session under the popup could end the picker before
  `wt rm` runs.
- When `wt status` already shows changes, the stash question comes before
  the session is killed; a tree that turns dirty after the read gets the
  same question after the kill.
- Delete on a missing row runs `wt rm` with no confirm; wt refused a
  missing directory, so the stale registration stayed (prune by hand).
  Closed by D102: wt now prunes it. R7's trash rename and DerivedData
  removal are not done for linked worktrees; `wt` was not changed in B3.

Tests: Go `go vet` clean and `go test ./...` passes (18 new tests:
10 model, 8 action against a fake `wt` and save shim);
`tests/worktree-keys-test.sh` 44 passed (real `wt`, isolated `-S` server,
control-mode client, picker driven with `send-keys`);
`tests/worktree-list-test.sh` 18, `tests/wt-test.sh` 135, agent-state 213,
pane-mem 43 pass. Binary rebuilt into `bin/agent-picker`.

D102 (2026-11-02, user). The user pressed `C-a D` on the row "be main"
(better-context, a plain single-checkout repo whose only worktree is its
main checkout) and the picker answered "refusing to delete the main
worktree: better-context". The user, verbatim: "What? Why? this is
stupid." Their opening intent was to see every worktree of every project
under `~/Developer` "so I am able to close / delete / reopen those
worktrees / projects lest they get lost / dead and block up storage". The
refuse-main rule (R7, D2) was written with content-engine's main checkout
in mind, the hub of 34 linked worktrees; for a repo with no linked
worktrees, main is the project. Decision:

- R7's "refuse the main worktree" is narrowed to "refuse a main checkout
  that still has linked worktrees" (`wt rm` exit 5, `main checkout has N
  linked worktrees: remove them first`; prunable ones count).
- A main checkout without linked worktrees is a whole-repo removal: never
  `rm -rf`, but `mv` to `~/.Trash/<basename>` (`-<YYYYmmddTHHMMSS>` when
  taken), recoverable. Dirty needs `--force`, which makes the tagged stash
  first so it rides along inside the trashed repo. JSON adds `trashed_to`
  and `main: true`. `wt status --json` gains `linked` for main checkouts.
- `wt rm` on a registered worktree whose directory is gone prunes it
  (`git worktree prune` in the main checkout found through the
  registration) and reports `pruned`, closing the B3 missing-row gap.
- Picker: `C-a D` on a main row confirms `delete repo <repo> (whole
  checkout, to Trash): <branch>, N dirty, N untracked, ↑A or no upstream,
  <heavy>, <agents> [y/N]`; the rest of D99's flow is kept. With linked
  worktrees there is no confirm. The user then asked, verbatim: "will that
  TELL me there are other worktrees for that branch? If that DOES happen
  can you set the tab cycle to that repo to highlight the other worktrees
  in this case (clearing the search term if there is one?)". So the error
  line reads `<repo> still has N linked worktrees: delete them first`, the
  repo filter is set to that repo and the query cleared, and a reload
  keeps the filter. `C-a x` (repurpose) still refuses main. A missing row
  is pruned and shows `pruned <dir>`.

Details in D102 of `docs/tmux-agent-sessions.md`.

D103 (2026-11-02, user). The user, verbatim: "I dont think we shoudl be
using n and p if those hotkeys are already used for the switching between
rows up and down - since a bind key plus these buttons could be an honest
mistake in effort to go up or down. How about c for create and x for (cut
being = repurpose) ? and shift C for create from current selection?"
Decision: `C-a c` new worktree from main, `C-a C` new worktree from the
selected row's branch, `C-a x` repurpose, `C-a D` delete. `C-a n`,
`C-a N`, `C-a p` do nothing. The displaced keys move: new window from
`C-a c` to `C-a w`, new detached session from `C-a C` to `C-a s` (both
letters were free). On a plain session row `c C x D` do nothing and `w`
and `s` work as the old `c` and `C`. Details in D103 of
`docs/tmux-agent-sessions.md`.

D104 (2026-11-02, user). The user, verbatim: "n, p with bind key should
go up and down like normal control. Im also thinking ALL hotkets can
either be bindkey prefaced then [key], ctrl + [key] or bindkey prefaced
then the ctrl + [key] - all doing the same thing - just to make it
obvious and simple". The bind key is the picker's `C-a`. Rule: one action
table keyed by letter; for every lowercase letter with an action,
`ctrl-<letter>`, `C-a <letter>` and `C-a ctrl-<letter>` fire the same
action. Letters: `n p` next and previous row, `h j k l` card moves, `t`
full-repo mode, `w` new window, `s` new session, `r` rename window, `q`
kill pane or window, `c` new worktree from main, `x` repurpose; `C` (new
worktree from the row's branch), `R` (rename session), `Q` (kill session)
and `D` (delete) are `C-a <Letter>` only. Exceptions: `ctrl-a` is the
prefix (`C-a C-a` keeps it armed); `ctrl-c` and `esc` close, so `c` is
`C-a c` or `C-a ctrl-c`; ctrl carries no shift, so `C-a ctrl-<letter>` is
always the lowercase action; bare letters type into the query; prompts
and confirms are a separate keymap where `ctrl-u`, `ctrl-w`, `ctrl-a`,
`ctrl-k` and `ctrl-h` edit. `ctrl-w` (unbound since D86) becomes new
window, `ctrl-q` kills in one keystroke as `C-a q` did, `ctrl-s` and
`ctrl-q` reach the picker because raw mode clears `IXON`. `C-a N` stays a
dead key (D103); `d` and `u` have no action. Details in D104 of
`docs/tmux-agent-sessions.md`.

D105 (2026-11-02, user). After the second delete confirm `dirty: preserve
with a tagged stash, then delete? [y/N]` the user said, verbatim: "This
seems overkill after the first y/n message. If i want it in trash why
would I ever need this? Alos the messages in the status bar upon a
confirmation should NOT need to show the git dirty status or anything -
just a simple short mesage for all confirmations!" Decision: D2's
"refuse dirty with stash escape" is replaced by "everything deleted goes
to the Trash with its dirt".

- `wt rm` moves a linked worktree to `~/.Trash/<basename>` (suffix
  `-YYYYmmddTHHMMSS` on collision), then `git worktree prune` in the main
  checkout, instead of `git worktree remove`. No dirty refusal, no tagged
  stash; `--force` only overrides a lock. Main checkouts keep the
  linked-worktree refusal (D102). The `rm` JSON keeps `trashed_to`.
- One confirm per action, short: `delete <dir> to Trash? [y/N]`, `delete
  repo <repo> to Trash? [y/N]`, `kill session <name>? y/N`. No dirty,
  ahead, heavy or agent counts. `wt status` runs only where a refusal
  needs it (a main row's linked count, a locked row's reason). The
  Working, locked, current-row and linked-worktree refusals stay on the
  error line.
- Repurpose: the branch prompt is the only question; the picker always
  passes `--stash` and says `repurposed <dir> to <branch>, N changes
  stashed`.
- Result lines are short: `deleted <dir>`, `deleted repo <repo>`, `pruned
  <dir>`, `repurposed <dir> to <branch>`; errors keep wt's message.

Details in D105 of `docs/tmux-agent-sessions.md`.

D106 (2026-11-02, user, a trial). On the preview line (`~/Developer/
content-engine/scheduling-init  feat/scheduling-init  7 dirty  18
untracked  no …`) the user said, verbatim: "okay now i want to address the
visaulization of the data in the preview pane for a given session /
worktree. I think we need to look into taking a little more space - like
a cell that is colored differently/consistently w/ border or background
or something to make it clear about the data it is showing. It does not
need to show the branch! and I think the dirty / untracked + code line
changes need to be shown in each of their own status cells in that top
row. I also want to experiment with having the row that shows these cells
at the BOTTOM of the preview area just above the list first". Built, for
the user to judge live:

- The line moved to the bottom of the grid area, directly above the list.
- Directory as plain text, then one cell per figure on a shared
  background (`cSurface1`): `N dirty`, `N untracked`, `+A -D` lines
  (green and red), `↑A ↓B` or `no upstream`, `ports N`. Zero cells stay,
  dimmed. No branch. No border (it would cost three lines).
- `inspect.ReadGit` adds `git diff HEAD --numstat` for the line counts.

Details in D106 of `docs/tmux-agent-sessions.md`.

D107 (2026-11-02, user). After one look at D106 the user said, verbatim:
"Okay i prefer the top of the screen - but it should have a line
underneath it as a border to the rest of the cells - shoudl be a little
darker than the other border lines - it will look good. Also I do NOT
need to see the ports in the chips there!" Built: the preview line is
back on top, a full-width rule under it one shade darker than the other
rules (`cSurface1` against `cSurface2`), the cards below that; the
`ports N` cell is dropped (the value is still read). The cells, the
dropped branch and the line counts from D106 stay.

Details in D107 of `docs/tmux-agent-sessions.md`.

D108 (2026-11-03, user). On `refusing to delete myncer: it is the session
you are in` the user said, verbatim: "This should not be an error - and
if this is the case, we just switch to the next most recent ssession."
Built: `C-a D` on the client's own row switches the client to the most
recently active other session (the picker's own recency order), then
kills and trashes as usual; only a lone session is refused. The popup is
the client's, so it survives the switch.

Details in D108 of `docs/tmux-agent-sessions.md`.

D109 (2026-11-03, user). Verbatim: "I need you to get into the content
engine local project and at the root, i Need to make sure that the gcp
MOST RECENT secrets are pulled - ideally there is a mechanism that can be
run from the picker that copies ALL crendetials across ALL worktrees
(honoring the specific port sets for diferent worktrees - and i guess not
.env.branch as a principle?) make sense? That way I can do a gcp secrets
ppull across production, staging, .env.local etc and apply all of those
env files and values across each worktree wehere each worktree SHOULDhave
access to those values?"
Built: `wt env-refresh <root> [--no-pull]` runs the main checkout's
`wt.envPull` git config command there (content-engine: `pnpm
env:pull:staging && pnpm env:pull:production`), then copies main's
gitignored `.env*` files, minus `.env.ports`, `.env.branch`, `*.generated`
and `*.rendered`, over every linked worktree's, atomically, rewriting
`.env.local` for each worktree's own port block. Symlinked targets and
missing directories are reported, never written. `C-a e` on any worktree
row runs it after one confirm. The first live run refreshed all 34
content-engine worktrees from a fresh pull.
Follow-up, verbatim: "I think C-a e should do it from the main and C-a E
shoudl do it from crrent selected worktree". Built: `wt env-refresh <root>
--here` takes the given worktree as the source, copied as it is to every
other worktree, main included, each rewritten from the source's port
block to its own, with no pull (a pull there would only reproduce main's
render and overwrite anything particular the worktree holds). `C-a E` runs
it after `refresh env of every <repo> worktree from <dir>? [y/N]`.

Details in D109 of `docs/tmux-agent-sessions.md`.

D110 (2026-11-04, user). Verbatim: "lets make a skill in
@../../../../agents/skills/ called /new-worktree where essentially given
any chat of a specific branch an agent is supposed to take the context of
the chat to decide whether the current branch, or other branch of context
(if non discussed then the main remote branch) should be branched off of
for the new worktree. The new worktree should create a new worktree via
our system and automatically switch the current window that said agent
chat is in (not the current one focused that is) to the new worktree
session, ensuring the worktree uses the common .env copy practices etc.
The agent will be in charge of creating the name - if it is not provided
it should make it up - something wquick and easy. The reason I want this
is because I find myself talking in a split chat for a given initiative
and it calls out something smal and new that would be best shipped as its
own branch but via its own dedicated worktree chat - NO LFS - unless
asked or is clear I want a heavier worktree base to use. Make sense?"
Built first (2026-11-04 morning): `agents/skills/new-worktree/SKILL.md`
(loaded by claudef and pif through the `skills` symlinks, no restow), which
ran `wt new`, created the session and switched the user's client to it,
with a handoff brief to paste. Two runs later the user corrected the goal,
verbatim: "Is there no script that it can call to move the chat, the
session, the agentic coding session, no matter what platform or client it
is? It could be PIF or claudef. If either of those is true and I run the
skill, then there should be a command that assists it to move that chat
over to the new session (or maybe replicate it over on that new session),
such that whatever is needed to resume from there can kick off. The one
we're currently on goes away. I don't know. I don't think it should
actually automatically switch my view to that new pane or worktree
session. It should just spin up the new session, add the agent session
into it, and get rid of the one we're currently using, right at the end
of its task. It needs to kill itself before it moves over to the next
work tree, or maybe even after it moves over to the next work tree, to
resume the conversation." And: "It should not be coming back to me with
anything that I should have to run manually. Ideally it starts or resumes
the current chat over in the new worktree and continues with its own
tasking - Maybe by resuming from a thread in the new work tree and then
putting its own message that it wants to continue with as the next
message to go with, maybe for Send Keys."
Built: `git/.local/bin/chat-move <dir> --message-file F` (linked into
`~/.local/bin` like `wt`). Run by the agent as the last call of its turn,
it finds the chat from what the agent's shell inherits
(`CLAUDE_CODE_SESSION_ID`, or `PI_SESSION_FILE` which pi exposes by
default) and `$TMUX_PANE`, queues a job under `~/.local/state/chat-move`
and hands it to a worker started with `tmux run-shell -b`, which outlives
the pane. The worker waits until the pane's `@agent_state` leaves
`working` (the turn ended), creates the session named after `<dir>`
(the picker's naming) when missing and a shell window in it, types
`claudef --resume <id> "<message>"` or `pif --fork <file> "<message>"`
into that shell (Claude resumes a session from any directory and copies it
to the new cwd's project; pi forks the session file into a new session
whose header cwd is the worktree; both verified in print mode), waits for
`@agent_pid` on the new pane, then kills the old pane. Claude Code asks
"Is this a project you trust?" in a directory it has not seen, which a
new worktree always is, and runs no hook until answered; the worker reads
the pane each second and answers it once (Down, Enter). Claude's "No
conversation found" fails the job at once. pi asks for trust only when
the project ships `.pi` resources, which content-engine does not. A client whose
session would die with that pane is moved to the new session first; no
other client is switched. Failures leave the old pane alone, show on it
through `display-message` and are logged. The skill now writes the next
prompt to a file, calls `chat-move`, and replies with one line; no handoff,
no client switch. `tests/chat-move-test.sh` (plugin tests dir, isolated
server, fake `claudef` and `pif` on PATH, 44 pass) covers refusals, a
Claude move creating the session with a quoted multi-line message intact
and the trust dialog answered, a pi move into an existing session, an
agent that never comes up (pane and message kept) and a turn that never
ends (nothing created). Typing into a real zsh pane with the user's zshrc
was checked on an isolated server. Live smoke on the real server
(2026-11-04): a throwaway claudef chat with one exchange, in a throwaway
session, moved by `chat-move` into a scratch directory's session in 3 s;
the resumed chat answered its typed prompt there, the hooks published
`claude`/`finished` on the new pane, the old pane and its session were
gone. An earlier live attempt showed the trust dialog verbatim; the
answer path is covered by the fake in the test.

## Open decisions

Each has a recommendation. None is locked until the user says so.

- D1. Session model. Decided 2026-10-31: strict as the starting point (V1 to
  V4), revisit after use. Earlier recommendation text kept for the record:
  strict, one session per worktree (R1 to R4a). The earlier "hybrid" was strict minus two things:
  topic sessions were still allowed, and the worktree view derived
  membership from pane directories across sessions. F10 shows what that
  looks like in practice and it is the confusion the user hit. Breakdown:
  - What strict buys: a worktree row and a session row are the same thing,
    so the picker needs one model, not two. Delete, restore and remote
    mapping all key on the session name already, and the session name is
    now the worktree name. "Which worktrees are active, awaiting, finished"
    is answered by the session list with no cross-session grouping.
  - What strict costs: (a) the four topic sessions in content-engine-1 fold
    into one session, or each becomes a worktree, a one-off migration;
    (b) a window that cd's elsewhere is marked, not moved, so drift can
    exist, the same as hybrid; (c) nothing else. Agent cwd drift was the
    reports' main objection, and it only argues against automatic moving,
    which neither model does.
  - Alternative kept: hybrid as previously written, if the user wants to
    keep topic sessions on the main checkout. Then the row label must show
    the directory, not the branch, and cards must show their session.
- D2. Delete policy. Accepted 2026-10-31: refuse dirty and locked by default,
  "preserve then delete" (tagged stash) as the escape, branch never deleted
  (R7). Replaced 2026-11-02 by D105: everything deleted goes to the Trash
  with its dirt; locked is still refused and the branch is still kept.
- D3. Env propagation. Recommended: copy by deny list, rewrite the port
  keys offline, project hook optional (R6, R9, R11). Alternative: symlink
  secrets after the project moves port-derived keys out of `.env.local`
  (cleaner long term, needs a content-engine change first).
- D4. Port scheme. Locked 2026-10-31: keep content-engine's file and the
  plus-100 step (R10). It works with content-engine because the renderer, dev
  scripts and docs already consume exactly that file and no project change
  is needed; the only missing piece is the allocator, which `wt new` is.
  It is a good standard for this machine up to 40 concurrent worktrees of
  one repo. Alternative: 10-port blocks at 20000 and up from a path
  checksum (research proposal); only better past that count, and would
  change the project's documented defaults.
- D5. Heavy. Confirmed 2026-10-31: pattern table of heavy elements, one
  symbol each, `ios` and `lfs` first, `node_modules` excluded (V8, V9).
- D6. List scope. Confirmed 2026-10-31: every worktree of every repo within
  two layers of `~/Developer`, always, ordered by last active, Tab cycles
  repos (V5). `ctrl-w` and the `ctrl-g` idea are dropped. Janitor view not
  built.
- D11. Git state placement. Confirmed: preview area for the selected row
  only (V7). Alternative kept: cached symbols in the row.
- D12. Repurpose semantics. Confirmed: `R` keeps directory and heavy state,
  cuts a new branch from `main`, prompts for the name (V11). `shift-N` is
  the "new worktree off this row's branch" case (V10).
- D13. Drift. Confirmed: no marker, no move key in V1 (V2).
- D7. Home session name. Recommended: a new `home` session; leave `roll`
  alone or rename it once rw's `session-renamed` hook exists (R17), since
  `roll` is a prefix of every `roll-*` name.
- D8. Worktree root for other repos. Recommended: per-repo declaration with a
  default of `<main-checkout-parent>/.eph/<slug>` when the main checkout
  lives in a `*-trees` directory, else `~/Developer/.worktrees/<repo>/<slug>`.
  Directory slug from the branch with the type prefix stripped.
- D9. P0 removal list. Recommended: approve the 24 STALE-CLEAN worktrees now,
  review the 35 RECENT-MERGED (three nested harness worktrees were created on
  2026-10-29 and may belong to a running agent), and triage the 14
  STALE-DIRTY and UNKNOWN by the notes in the appendix.
- D10. Branch and directory naming. Recommended: `<type>/<slug>` branches,
  directory named by slug only, stop `tmp/`, `wt/` and automatic
  `worktree-agent-*` branches. Keep heavy directory names as they are
  (path stability).

## Decision log

- 2026-10-31: D2 accepted by the user. D1 recommendation changed from hybrid
  to strict; D5 from locked pool to measured badge; D6 janitor deferred.
- 2026-10-31 (second round): D1 strict decided as the start. D4 locked.
  V1 frame written; D5, D6, D11, D12, D13 proposed in it.
- 2026-10-31 (third round): D5, D6, D11, D12, D13 confirmed. Repo family
  defined as two layers under `~/Developer`. Plan ready to implement in the
  order of the Build order table. Still open: D3 (env, recommendation
  stands and is what `wt new` will do), D7 (`home`, recommendation stands),
  D8, D9 (removal list needs a yes), D10.
- 2026-11-02: Batch 3 executed and verified, K1 to K9 closed, K3 folded
  into `.eph/env-protection`. Batch 2 stale sweep executed under the
  lossless policy (D9 resolved by that policy: 70 removed, 5 moved, dirty
  kept). B0 complete.
- 2026-11-02 (evening): B1 and B2 built by two opus agents, verified and
  installed. B1: `git/.local/bin/wt` (new, status, rm, repurpose, ports;
  no install ever; copy never symlink, symlinked source refused; allocator
  answers block 33 on the real repo), tests `tests/wt-test.sh` 135 pass,
  stowed to `~/.local/bin/wt`. B2: picker lists every worktree of every
  repo within two layers of `~/Developer` (74 rows live), session or not,
  ordered by last active, `ios`/`lfs`/lock/missing markers, git state and
  ports in the preview, `ctrl-w` removed; Go tests plus
  `tests/worktree-list-test.sh` (18), agent-state (213), pane-mem (43)
  pass; binary rebuilt (old one at `scratchpad/b2/agent-picker.pre-b2`).
  Decisions D84 to D92 in `docs/tmux-agent-sessions.md`. Known gap for
  D14: the repo badge is the main checkout's basename, so under the new
  layout it would read `main`; B3 must take the project folder name when
  the main checkout is named `main`. Remote `rw-*` rows join a worktree
  only by name (V3 said by worktree); revisit in B5.
- 2026-11-02 (night): D14 executed and verified (see "D14 outcome"); B4
  done for all four sessions; D93 repo name from origin remote. B0, B1,
  B2, B4 complete. Next: B3 keys, then B5.
- 2026-11-02 (night): B3 landed: `C-a n`, `C-a N`, `C-a p`, `C-a D` call
  `wt` (see "B3 outcome"); no install, R18 skipped, Working refusal on `p`
  and `D`; Go tests, `worktree-keys-test.sh` (44) and the existing suites
  pass; binary rebuilt. Next: B5.
- 2026-11-02 (night, user): D102 and D103. R7 narrowed: `wt rm` refuses
  only a main checkout that still has linked worktrees, and moves one
  without any to `~/.Trash`; a missing worktree is pruned. `C-a D` on main
  confirms a whole-repo delete, or, with linked worktrees, refuses and
  narrows the list to that repo. Lifecycle keys moved to `C-a c`, `C-a C`,
  `C-a x`, `C-a D`; new window and new session moved to `C-a w`, `C-a s`.
  `tests/wt-test.sh` 179, `worktree-keys-test.sh` 68, Go tests pass;
  binary rebuilt.
- 2026-11-02 (night, user): D104 and D105. One letter table with three
  forms per letter (`ctrl-<letter>`, `C-a <letter>`, `C-a ctrl-<letter>`);
  `C-a n`/`C-a p` move rows; `ctrl-w` is new window. D2 replaced: `wt rm`
  trashes linked worktrees too, dirt and all; one short confirm for every
  action; repurpose stashes without asking. `tests/wt-test.sh` 182,
  `worktree-keys-test.sh` 76, `worktree-list-test.sh` 18, agent-state 213,
  Go tests pass; binary rebuilt.
- 2026-11-02 (night, user): D106 trial. Preview line moved below the
  cards, its figures as cells, branch dropped, `+A -D` line counts added.
  Go tests pass; binary rebuilt with the setup flags.
- 2026-11-02 (night, user): D107. Preview back on top over a darker rule,
  ports cell dropped. Go tests pass; binary rebuilt.
- 2026-11-03 (morning, user): D108. Deleting the client's own session
  switches the client to the next most recent session first instead of
  refusing. Go tests and `worktree-keys-test.sh` 76 pass; binary rebuilt.
- 2026-11-03 (morning, user): D109. `wt env-refresh` and `C-a e`: a fresh
  GCP pull in main copied to every worktree, ports kept, `.env.branch`
  never. content-engine's `wt.envPull` set; all 34 worktrees refreshed
  live. Then `--here` and `C-a E` (the selected worktree as the source, no
  pull). `wt-test.sh` 244 and `worktree-keys-test.sh` 88 pass; Go tests
  pass; binary rebuilt.
- 2026-11-04 (morning, user): D110. `/new-worktree` skill in
  `agents/skills/new-worktree` and `git/.local/bin/chat-move`: an agent
  spins a small called-out item off its chat through `wt new`, then moves
  its own chat into the worktree's session (resume or fork with its next
  prompt typed in, old pane killed). `chat-move-test.sh` 44 pass; live
  smoke on the real server passed. No picker or wt change.

## Appendix: content-engine worktree audit (2026-10-30)

Classes: ACTIVE has live panes. RECENT means HEAD or index mtime on or after
2026-10-16. MERGED means HEAD is an ancestor of `origin/main` or the PR is
merged. STALE-CLEAN* means clean, commits found on main by subject but not by
patch id (verify before deleting; branches are local only). UNKNOWN means
clean, old, with work not found on main.

| Class | Count | Size |
|---|---|---|
| ACTIVE | 9 | 110.4 GB |
| RECENT-MERGED | 35 | 141.0 GB |
| RECENT-DIRTY | 3 | 11.3 GB |
| RECENT-OPEN | 1 | 4.5 GB |
| STALE-CLEAN | 20 | 88.2 GB |
| STALE-CLEAN* | 4 | 17.2 GB |
| STALE-DIRTY | 8 | 26.2 GB |
| UNKNOWN | 6 | 27.7 GB |

ACTIVE (keep): content-engine-1 (main; 8 dirty, 6 untracked planning docs),
content-engine-3 (3 dirty docs), content-engine-4 (locked; 7 modified
`*.nitro.ts`), content-engine-5 (locked; 12.6 GB iOS build, 9.8 GB
gitignored triage output, hosts 3 nested worktrees), content-engine-6 (1
unpushed docs commit), content-engine-11 (11.3 GB iOS build, 11 commits ahead,
pushed, no PR), content-engine-13 (24 dirty files of expo and api work, no
upstream, exists only on disk), `.eph/env-protection`, `.eph/platform-supabase`.

RECENT-OPEN (keep): `.eph/infer-profile-ownership` (PR #631 open).

RECENT-DIRTY (save docs, then remove): `.eph/env-access-gate` (1 untracked task
doc), `.eph/figma-linux` (3 modified figma docs, 1 untracked task doc),
content-engine-8 (1 untracked task doc).

STALE-CLEAN (safe to remove, 20): `.eph/carousel-feed-metrics`,
`.eph/carousels-server`, `.eph/editor-sheets-pass`, `.eph/gestures-port`,
`.eph/naming-alignment`, `.eph/release-102-compat-fixes`,
`.eph/release-main-sync`, `.eph/release-sync`, `.eph/retire-worktree-claim-1`,
`.eph/trial-reactivation`, content-engine-9, content-engine-15,
content-engine-16, content-engine-10 (PR #482 closed unmerged, remote branch
keeps the commits), content-engine-visualizer (clean but 7 GB iOS build,
retarget candidate instead), `C1:cw/agent-a1a3c4f2`, `C1:cw/agent-ae7362e8`,
`C1:cw/trial-never-paid`, `C5:cw/track-ux`, `C5:cw/aspect-ratio-impl` (PR #205
closed).

STALE-CLEAN* (verify by subject, 4): content-engine-14,
`C1:cw/agent-a6ae134f`, `C1:cw/agent-aa1434dc`, `C1:cw/agent-ac2c4250`.

RECENT-MERGED (eyeball, 35): `.eph/alerting`, `.eph/fixes-2026-10-22`,
`.eph/font-catalog-api`, `.eph/import-observability-v2`, `.eph/oom-fix`,
`.eph/text-stroke-bg`, `.eph/yap-549`, `.eph/yap-550`, `.eph/yap-hook-api`,
`.eph/yap-logic-fixes`, `.eph/yap-release`, `active/onboarding-perf`,
content-engine-billing-side-effects, content-engine-billing-switch-copy,
content-engine-fix-grafana-uid, content-engine-funnel-amendments,
content-engine-period-end-downgrade, content-engine-return-origin,
pr-524-yap-export-all (detached), web-funnel-followup, and 15 nested
`C1:cw/*` worktrees (`agent-a0551b3b`, `agent-a1f5600f`, `agent-a2e0745b`,
`agent-a711aca9`, `agent-a722e9db`, `agent-a75b47b6`, `agent-a8ef5042`,
`agent-aa11af7b`, `agent-aa87a2e7`, `agent-ae09c690`, `agent-ae8895f7`,
`agent-afaa898f`, and the three created 2026-10-29: `agent-a7d928b7`,
`agent-ac068132`, `agent-af083b50`).

STALE-DIRTY (human look, 8): `.eph/advertorials` (9 files of real landing-page
WIP), `.eph/ben-missing-photos` (1 untracked task doc),
`active/content-engine-creator-clean` (5 unstaged model deletions),
`C1:cw/agent-a2c7c90f` (2 modified expo services from March),
`C1:cw/agent-aa6a95ef` (5 modified native-tools files from March),
`C1:cw/sync-gate-tutorial-owner` (skills dir relocation), content-engine-12
(1 modified note, 2 untracked task docs), content-engine-7 (2 untracked task
docs).

UNKNOWN (human look, 6): `.eph/legacy-drafts-cutoff` (1 local commit,
referenced by `docs/tasks/legacy-tracks-retirement.md`), `.eph/tanstack-patch`
(1 local XSS patch commit, likely superseded), `active/content-engine-sync-release`
(wip refactor commit, agent stopped mid-flight), `C1:cw/jwt-claims-version`
(PR #208 closed, origin branch exists), `C5:cw/slide-ux-pass` (7 expo commits
on no remote), content-engine-selection-resp (3 perf commits, two on main by
subject).

Unregistered directories: `content-engine` (Feb 2026 full clone, 2.9 GB, 1801
staged deletions), `latest-editor` (full clone at `release/1.0.2`, 4.7 GB,
clean), `yap-trial` (separate repo, 4.0 GB, 3 prunable worktrees under
`/private/tmp`), `minified-repo` (worktree of yap-trial, 2.6 GB),
`reverse-engineering` (tiny repo, no remote), `.eph/content-engine-adjustments`
(orphan, 4.6 GB, planning docs), `.eph/web-funnel-code`, `.eph/web-funnel-figma`,
`designs`, `font-catalog-staging`, `hiring-notes`, `looter-examples`,
`.devcontainer` (plain folders), `~/.Trash/roll-hiring` (trashed worktree,
4.1 GB, live pane).

Retarget candidates (heavy, keep): content-engine-5, content-engine-11,
content-engine-visualizer. Prebuilt Pods only (0.2 to 0.4 GB, not worth
protecting): content-engine-1, -3, -4, -6, -7, -8, -9, -10, -13,
`.eph/gestures-port`, `C1:cw/agent-aa1434dc`.
