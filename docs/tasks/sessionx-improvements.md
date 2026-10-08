# Sessionx improvements

Status: built 2026-10-05 (phases 1-3). UI v2 (phase 5) built 2026-10-06.
Phase 6 refinements (D34-D49) built 2026-10-07. Phase 7 (D50-D62) built
2026-10-08, awaiting a live trial.

## Goal

Make the prefix `o` session picker useful for running many coding agents. It
should show, per session, which Claude Code and pi agents are running, their
names and their status, and how much memory each window and session uses. A
pane-level memory chip belongs in the status line. Opening the picker must
stay fast and cheap.

## User intent (verbatim)

Recorded as given on 2026-10-04. Engineering compromises below must not
replace these desires.

> Currently the tmux sessionx pane that shows the "peek" into the current
> activity of a given session is absolutely useless to me (as it is currently
> configured) when looking at the last focused pane itself within that session
> and its current running items.

> - Memory usage across individual panes AND sessions (via sessionx) as a
>   whole in order to track which processes are taking the most resources on
>   my machine
> - Agentic status (across my frequently used pi and Claude code sessions)
>   where each agentic session reports its resembling name, its status
>   (working, idle, awaiting response) at a SESSION level when switching
>   between sessions in the sessionx pane

Memory / resource usage:

> - I need a pane based status line chip addition to the left that shows the
>   memory usage for that specific pane ideally if this is possible.
> - Ideally the tmux sessionx window reports memory usage per active WINDOW

Agentic status:

> - For this I am thinking about taking inspiration from "Herder" where it is
>   a multiplexer that reports agentic status across different sessions /
>   windows but as a first class status line, where I dont want a statusline,
>   but would rather see a sessionx capability to see the status of different
>   running agents as I reported above. [...] the different sessions and their
>   running agentic sessions in a way that makes it easy to switch between
>   them, whilst seeing at a global level what each session is running, and
>   the statuses of pi and claude code sessions.
> - We need to look into what it will take for each of these coding agents to
>   keep their status synced via our tmux runtime / sessionx runtime tracking
>   - in order to not have to fetch statuses across EVERYTHING via tmux
>   commands when I invoke the tmux sessionx window
> - I think that sessionx should be configured as patches in this dotfiles
>   project so that I do not need to maintain a fork of this, but I am open to
>   hearing what the best approach for this is.

> We MUST make sure that any iterations we are making on our tmux runtime /
> sessionx exetension is NOT resource intensive, quick and performant - whre
> we cannot be causing major load on our machine everytime I want to see the
> session x pane - which historically has been slow to open even without any
> custom extensions over the session x repo

> Sessionx is also DEFINITELY out of date and something we need to look to
> update BEFORE we start any of these changes as they may already support the
> tooling to expose resource usage as per the "Memory / Resource usage" goals.

Follow-up given on 2026-10-05:

> lets just go custom for this. It seems like sessionx will continue to have
> problems and update outside of th escope of what we are trying to avhieve
> here which COULD be a much faster and more satisfying experience to triage
> and iterate on this new extension for tmux (inlcuding hooks congigured for
> agents) via our dotfiles repo - it only makes sense!

> Final statuses I want for agent panes:
> - "Finished" (a response has been done with no awaiting input indication)
> - "Working" (currently running / processing OR subagents still running)
> - "Awaiting Input" (when the agent is looking for a human in the loop
>   response)
> - "Idle" (when an agent is up and the user has visited it after focusing on
>   the pane EXPLICITLY when it is in a "Finished" state, or if the agent has
>   not been run yet / created no responses

> Obivously agent hooks would be the best for classifying these - and ideally
> (keen to here your perormance points here) we have a listening service on
> hooks to opulate our new custom Picker when it is invoked so the wait time
> is NEAR 0. But also such that the memory usage remains low.

> I think permission prompts are stupid and I NEVER use AskUserQuestion tools
> (its always chat / respnse based questions / requwests from the agent for
> human in the loop guidance - never a AskUserQuestion tool call - although if
> the agent was ever to use this, then that should theoretically be a free way
> to classify that agent thread as "awaiting input")

> For Memory of the current pane it should sit on the right of the status line
> along side the Auto save time since, the directory, and hostname chips.

Follow-up given on 2026-10-05, on the window list:

> I think we shoudl support doing ctrl-w (i dont care for ctrl-t) where what
> happens is INSTEAD of the session view, we dont try to change the sessions
> list view, but rather hide the sessins list view and just show the window
> preview pane but as selectable where all windows are for all sessions and
> include their sesions name that are now renamable, killable, and openable,

> For normal mode: every session selection must reveal its iwindows via that
> preview pane in a NON selectable way, AND every session in the session list
> MUST show its status aggregatinos (ie x Finished, x Awaiting, x Idle, etc)
> (and memory) for quick skimming when choosing which window to select - make
> sense?

> For the window panes, since not every window uses an agent, some windows
> have multiple panes and could have Multiple agrents, but every window / pane
> may use consequential amount of ram, you must consider this for the window
> preview view. Maybe it would be smartest to order windows in the preview
> area now by their order, but by which was updated last in terms of agentic
> status or creation? Im not too sure. I think it would be best for when the
> sessions list is active, that the unselectable preview pane does its best to
> be navigable / scrollable in itself for example maybe it SHOULD BE
> SELECTEABLE in any caes (session mode vs window mode) in fact here is what I
> think would make more sense:

> ctrl+w toggles PANE MODE on and off, so window in the preview area split
> their aggregative UI (however that looks) into one pane per selectable row?

> preview areas are ALWAYS selectable and the first window is always selected
> (maybe selection shows something a little more abourt that window / pane
> when cursor is over it) where the way to change selection of a preview
> window / pane being shows is ctrl+j for down, and ctrl+k for up, whilst the
> ctrl+n for session down, and ctrl+p for session up? That way on enter the
> user always goe to whatever window / pane the cursor has selected (which
> will be by default the pane/window last visited anyway right? OR the most
> recent pane to change its status (ie finishing agentic / awiting input
> agentic right? which WILL be more useful than just resume last window from
> last time the session was foucsed!)

Follow-up given on 2026-10-05, on picker keys:

> okay fuck it, those hotkeys seem problemaitc we need something better that
> uses the same non modifer keys for create, quit and rename. Please also note
> my mac option key is wired to aerospace and may be problematic to use as a
> modifier, as well as the fn key being used for wispr flow recording tap to
> speak. Is it not possible to use the tmux bind key whilst WITHIN this menu?
> That way the same tmux hotkeys that we'd otherwise use in the main tmux
> panes (ie bindkey + c for create, bindkey + r for window rename and bindkey
> + shift + r for session rename, as well as bindkey + q for quit window,
> where for create and quit we could definitely have shift apply the command
> to the whole session (make sense?)

> Q14: Sessions bottom up, and window/pane preview pane as numbered (lowest
> index top down) w/ most recent change automatically selected.

Follow-up given on 2026-10-06, on the UI (wireframes:
[pane mode](assets/sessionx-improvements/wireframe-pane-mode.png),
[window mode](assets/sessionx-improvements/wireframe-window-mode.png)):

![Pane mode wireframe](assets/sessionx-improvements/wireframe-pane-mode.png)

![Window mode wireframe](assets/sessionx-improvements/wireframe-window-mode.png)

> we NEED to work on a better UI / UX for this feature which is super
> importnat for me to enable BETTER developer experience when using this tool

> - There are 4 statuses: Done - lucide "circle-check" (green background),
>   Working - lucide "circle-dashed" (blue background), Awaiting input -
>   lucide "circle-question-mark" (orange background), Idle - lucide
>   "circle-minus" (gray background).
> - The typing area has the normal search scoped item count / total session
>   item count to the right of the search bar, and to the right of that will
>   be a simple cell to show the state of the bindkey pressed (green - not
>   pressed, red not pressed) similar to how tmux renders it but with no icon.
> - The session browse view:
>     - Shows max 4 items in the view
>     - Shows the current session selection w/ the transparent white
>       highlight background
>     - Shows statuses to the right of the session name aggregated and
>       grouped to how many processes report speciic statuses
>     - Memory status per sessino floats to the right
>     - Scroll indicator shows to the left as it currently does
> - Window preview:
>     - Continues to use the ctrl+j and ctrl+k to step through is now a grid
>       depending on the size of the parent window of course as to how many
>       grid cols/rows can be supported
>     - The initial screenshot shows pane mode (default) but can be
>       compressed to windows if using ctrl+w like we've decided. Where if it
>       is window mode it looks like this: [window mode wireframe] (shows
>       having less window cards than the grid area view is sized for where
>       empty space is OKAY) where windowed items show the count of panes
>       along with the chips to show processes and their counts/statuses. If
>       a window only has one pane then it just shows the normal pane card but
>       without the decimal indicator for its pane number when in window mode.
>         - Status cards are aggregated per window (when multiple panes) just
>           like the session view does, in a wrap list with pane count at
>           index 0, and the memory usage label at index last.
>     - Pane mode cards / single pane window mode cards, shows the window
>       name + window number as [window_num.pane_num] at the top w/ the window
>       name next to it, the agent's session name (if exists) in the second
>       row, and on the bottom row the status of that agent (if exists) and
>       what agent runtime its using (claudef vs pif) WITHIN the status chip
>       using the same icon/color practice as communciated above. Memory sits
>       tight to the right of teh status indicator.
>     - If the pane based card is for a non agentic session, the second row
>       shows the command currently running/last run (ie "nvim", "pnpm
>       branch" etc instead of the agentic session name.
>     - Everything is either wrapped, or text truncated (ie window names,
>       agentic session names, recently run/current command labels) at the
>       horiztonal end of the cell.
>     - Stepping through the window preview will START highlighting the
>       latest status change or the window currently used in that session
>       which could be further along the grid view. Stepping through goes
>       from left to right, up to down, when using ctrl + j to move right /
>       down, and ctrl + k to move up / left.
>     - Non selected panes show more transparent than the selected card which
>       much be OBVIOUS.
> - No more command hints shown in this session browser panel.

Follow-up given on 2026-10-06, answering Q15-Q18:

> did you see that the session search area is at the bottom of the picker?
> and the window grid is at the top?
> Do we NEED to rely so heavily on FZF itself? is there no chance for
> something more cutsom that LEVERAGES fzf where possible?
> Q15: Lets owrk in lucide into our terminal / ghostty setup
> Q16: this is not true, im seeing it curently here in the current
> implementation: [screenshot of the v1 session list, showing a dark column
> at the left of the rows with a light mark on the selected row]
> Q17: No timings - Put the time since status formatted in [x]m, [x]s, [x]h,
> [x]d, [x]w, etc but AFTER the status indicator ICON - this is going to be
> really useful but is not shown in my designs. The timing indicator needs to
> be in the status `div`, overlaying the background color of that specific
> status representation - for aggregated status items (ie multiple panes OR
> in session mode to show the last time something with that status changed)
> just use the latest status change as the time since update.
> Q18: Yes row based navitgation makes sense in this use case

Follow-up given on 2026-10-06, answering Q20:

> Q20 yes document installing go for linux - thats fine. Let me know when
> the plan is ready for implementation.

Follow-up given on 2026-10-06, on search:

> For these risks, to be fair, i only EVER use the search key with a plain
> text name of a session / a PART of a session name (not necessearily from
> the start of the sesion name being typed) so i dont think we really need
> all the FZF bells and whilstles ESPECIALLY since it is justbeing used for
> simple string matching / piece matching of session names - dont overfit to
> FZF but keep it for the leverage it provides which we seem to alwready be
> aware of.

> EVERYTHING else you have suggested is good for plan lock in.

Follow-up given on 2026-10-06 after the first live trial of UI v2. The
user attached a screenshot of the built picker and a new goal screenshot
that replaces the pane mode wireframe (described in "UI v2 refinements",
because the screenshot files were not kept):

> Please make it such that the status aggregate items per session are
> shifted over to the RIGHT floating next to the memory blocks. That would
> look better.

> Might as well make the visible session list 6 (since 4 is a bit light)
> (since i need max 3 rows of preview cards above) (can we still show the
> tops of cards in the 4th row?)

> I need you to ACTUALLY use the AGENTIC SESSION NAME (each agentic
> session/transcript gets a name/summary name that we should be using in the
> second row of pane based preview cards (below the window name part??) for
> when the agent is claudef or pif right?? Thoughts? Isntead it currently
> seems to be showing hte last message sent by the user? / returned?

> The lucide icons look a little not aligned centered in the cells they
> belong in for some reason

> Add the memory background color/ spacing that we do for the sessions but
> in the widnow/pane cards for the memory indication. It should look better

Follow-up given on 2026-10-06, answering the coordinator's suggestions
(O1-O7) and Q22-Q23:

> O1: transparenc is fine - leave it.
> O2: Lets move to half width cards (not three rows but max two) for the
> pane/window cards.
> O3: The empty band is usulaly going to be filled due to more panes /
> windows in use - i just gave you an example with not too many. Lets keep
> the sizing as it is now for the popup itself.
> O4: Why is it impossible for us to just use plain white for this pannel
> in text that overlays catpuccin pastel colors??
> O5: Im happy with the scroll bar being as is.
> O6: Yes I agree lets have lines show aobve and below the text input area
> to make it more visually distincitive and therfor use more rows.
> O7: I actually like the lavendar usage here - keep it.
> Q22: Yes (but so long as it only runs briefly and not so often) When
> should it be run? I DO want the session name to be generated but not all
> of the time - only where it needs to / when it goes stale
> Q23: Dont worry about this - leave it as is, it was just how the old
> sessionx used to render it.

Follow-up given on 2026-10-06, on D46 and Q24:

> My issue is that creating a summary on the end of every turn WILL
> optimize for non stale summaries, BUT it may also result in higher cost
> full context window summaries of the current context window if done on
> EVERY turn. Maybe a turn with a certain number of tools used / steps
> should provide a threshold for when the summarization is run or not run.

> agreed with all of that you're saying. Q24: do NOT keep dark text on
> pastel chips at all- white for everything please.

Follow-up given on 2026-10-07, on the popup background:

> maybe give it the same bg color as the sessionx picker uses?

Follow-up given on 2026-10-07, during the second live trial (screenshot:
four window cards whose second line reads `pif --session <id>` or
`claudef --resume <id>`, idle for 2d):

> Still getting a bunch of these agentic statuses - will these be resolved
> if I reopen those agentic sessions?
>
> I have an important thing that I want. Effectively I NO LONGER want to
> see a switch between break out panes and non breakout panes in the
> window preview mode. These are the new rules:
> - Default is the grouped mode for a given window and its panes
> - We keep the "x panes" chip, drop the GROUPING for aggregated status
>   cards, in that they will ALWAYS SHOW AS INDIVIDUAL AGENT
>   RERESENTATION. This will be acheived by:
>     - If the window has multiple coding agents, then it gets split up
>       into two separate panes (each showing the total panes of the
>       window)
>     - All window's (or pane's if multiple agent panes in the same
>       window) have a subtitle as the AGENT session's name (as windwos no
>       longer group MULTIPLE session panes).
>     - If a window has no agent panes, it shows pane count and in the
>       subtitle it shows a trunacated represetnation of the first pane's
>       command actively running.
>     - ALWAYS SHOW PANE COUNT (even if just one)
> Are there any other clarifications needed for this?
>
> For the sessions view:
> - Idle status aggregations (whilst they remain in the window selection
>   grid) will be removed from each session list in favor of:
>     - Columns FLOATING to the rigth end of the session row are as follows
>       (from left to rigth):
>         - [WORKING, AWAITING INPUT, DONE status aggregation chips (in
>           this order if all exist) (all with the aggregated numbers +
>           time since last update]
>         - "[num][lucide "bot" icon(for number of agents)] [formatted time
>           since most recent update]"
>         - "[session memory usage as is]"
>     - no more idle status. We get an indication of what bots are idle vs
>       currently working / procuding status in the aggregation chips, but
>       our num of agent sessions + time since last can also give a basic
>       idea on the session as a whole (including how it may have idle
>       agents)
>
> Please also note that AWAITING INPUT status is NOT set to idle on visit
> - it remains unti the user either clears the agent or starts a new turn
> that requires no more information on the final agent respose (as
> opposed to "done" status) (ONLY FOR THE SESSION LIST)
>
> In this way I want to TRY showing the terms "Working", "Done", AND
> "Awaiting" instead of the icons in the sessions list view? (just
> temporarily ? Or view a hotkey like ctrl + w since that is NO LONGER used
> anymore?
>
> If a coding agent is actively running a subagent - or a script (ie
> claude coed) will that still present as working?

Follow-up given on 2026-10-08, answering Q25-Q33:

> there should be a fallback for sessions when no name / caht has been
> started yet so it is clear its an empty chat and I dont think something
> is broken.
>
> Q25: Yes
> Q26: Both should show the same number for the total of that window AND
> the total pane count. The only thing that differs is the specific agent
> session title and the W.P naming
> Q27: Yes there is literally no alternative that makes sense.
> Q28: Yes.
> Q29: No it should show 0, so that all the colums to the right (agent
> counts) take the SAAME width, The only variable width items that float
> to the right of the session row is the status icons of which could be
> any combination of our 3 status types shown there.
> Q30: No My idea here is that each section of things floating to the
> right have NO backgorund color (except the status chips) and use lines
> to break up the sections and have CONSISTENT widths across each session
> row.
> Q31: No do "2 Working 4m"
> Q32: Okay.
> Q33: Sure but that should work with the obvious idea of having it show a
> title if a chat is open and empty (same for claude code)
>
> Fold that into the plan as outstanding items to build - and awwait my go
> ahead for implementation
>
> Also if possible please return the chip colors back to the cattpuccing
> pastel colors

Follow-up given on 2026-10-08, on the popup border:

> also one more thing the backgroudn color used for the picker should also
> be drawn behind the outer border cells too

Follow-up given on 2026-10-08, answering Q34:

> White on pastel do as you're told

Follow-up on 2026-10-08, after the phase 7 build:

> Dont order it by last entered. Upon opening the picker this is what I want
> rendered:
>
> Bottom session = session used to open picker from
> Bottom-up ordered by awaiting input > done > working (multiplying the
> number of each in order to figure out how it should be ordered) > time
> since last interacted with > last time session was opened (tmux). -> Do
> these make sense as ordering heuristics?
> Always start the cursor on the session above the current which is at the
> bottom (one up from bottom)
>
> Also the less transparent white / darker white text overlaying the pastel
> cards is NOT a good color. White's usage in itself is good, but the grayer
> text for the formatted time should be a darker color version of the pastel
> color itself. Lets see how that looks along side the white text next to
> it.
>
> The lucide robot icon I asked for is not showing here. Also the robot icon
> needs to preceed the agent count per session. Also the time next to the
> agent count in the session's view should be a darker white than it is
> curently (to apply a similar style GLOBALLY of time formatted textx being
> a darker / less visible format than the full contrasted white text (across
> varied bacgkround colors) make sense?

Follow-ups on 2026-10-08:

> please add a cell space between the robot icon and the count

> Lets try (for all status cards that use pastel cattpuccin colors to have
> the text color be the saem as the formatted time color is, but make the
> formatted time color a little more transparent / lighter so it is less
> contrasted than the other text in these status divs)
>
> Also for some reason ALL of the icons recently became TOO small - i like
> them being smaller than they were initially but right now they are too
> small. Just a TAD bigger would be useful (not much bigger because - again
> I like them being smaller)

## Boundaries

- Opening the picker makes one tmux call and one footprint helper call
  (about 5 ms). No per-session tmux calls, no pane scraping and no ssh. Agent
  state is published ahead of time.
- Agents push their own state. The picker never scrapes pane contents to
  decide status.
- No fork or patch set of tmux-sessionx is maintained. The picker is custom
  (D1).
- Verification of tmux-side work is static or user-run. Agents never invoke
  `tmux` against the live server.

## Findings

F2, F4 and F5 describe sessionx and are historical after D1. F7 lists the
raw hook surface from research. The Design section governs.

### F1. Sessionx has no resource usage support

Neither the pinned commit `3a1911e` (2024-09-25) nor upstream HEAD `628575b`
(2026-09-01) displays memory or CPU. No upstream issue or PR proposes it. The
only per-session decoration added since the pin is a git branch column
(`@sessionx-git-branch`). Memory display has to be built here.

### F2. Upstream is 35 commits ahead, with a startup refactor

- HEAD moves option parsing and fzf argument building from open time to plugin
  load (`sessionx.tmux` stores them in `@sessionx-_built-args`). The pinned
  `sessionx.sh` re-reads about 30 options on every open.
- HEAD still forks about 17 tmux clients per open, plus 15 to 25 `sed`, `grep`
  and `awk` processes, and launches the popup through the `fzf-tmux` bash
  wrapper.
- Upstream issue #123 ("The popup feels slow", about 1 s) is still open. PR
  #217 claimed 460 ms to 180 ms and was closed unmerged.
- HEAD defaults `@sessionx-bind-select-up` to `ctrl-p` and `-down` to `ctrl-n`
  (commit ae9afad). The two overrides at `tmux/tmux.conf:99-100` are likely
  redundant after updating.
- Updating means changing both `TMUX_SESSIONX_PIN` (`setup/lib.sh:104`) and the
  `@plugin` line (`tmux/tmux.conf:50`), then reloading tmux so `sessionx.tmux`
  runs at load.
- Local reading copy: `~/Developer/utils/tmux-sessionx`.

### F3. Local startup measurements already exist

`docs/tasks/tmux-workspace-resurrection.md` ("Workspace picker measurements")
records 45 tmux client calls before fzf and startup times of 1.18 to 2.03 s at
the pinned commit, excluding the popup itself. The binding is a synchronous
`run-shell`.

### F4. Sessionx extension points are weak

- The preview command is built once in `sessionx.tmux:67-68` and points at
  `scripts/preview.sh`. The `ctrl-t`, `ctrl-w` and `ctrl-b` binds reset the
  preview to `preview.sh`, so an fzf-level override gets reverted. A patch to
  `preview.sh` single mode is the clean seam.
- The list is built in three places: `sessionx.sh` `input()`, the `ctrl-b`
  reload bind, and `reload_sessions.sh`. Extra columns need edits in all three.
- `strip_git_branch_info` (`scripts/git-branch.sh:47-51`) drops anything after
  two or more spaces, so extra columns separated that way already survive
  selection.
- `tmux/scripts/sessionx_fast.sh` and its test (untracked, dated 2026-09-17)
  sourced the pinned `sessionx.sh` and replaced its option reads with one
  snapshot. Nothing bound them. Deleted per D6.

### F5. Patch infrastructure exists

- `install_tmux_plugins` in `setup/lib.sh` pre-clones pinned plugins
  (`:340-435`), applies five tmux-resurrect patches by marker string with
  `git apply --check` (`:435-540`), and applies `treemux-polling.patch` with a
  reverse-check for idempotency (`:560-575`).
- `tmux/plugins/` is gitignored (`.gitignore:2`). Patches run only on
  `make install` and `make install-headless`. TPM `prefix U` can move a plugin
  off its pin until the next install.
- `tmux/tests/treemux_polling_test.sh` is the template for a patch test.
- `upstream-sources.json` does not track patched TPM plugins.

### F6. Herder is herdr, and prior art converges on pushed state

- herdr (github.com/herdrdev/herdr) is a Rust multiplexer that replaces tmux.
  It classifies panes as working, blocked or idle. Integration reports from the
  agent (pi among them) win over screen-pattern matching, which is the
  fallback. Its sidebar and cross-machine agent list are the UX reference.
  Adopting it would replace tmux and the resurrect and remote-workspace stack.
- bearded-giant/tmux-sessionx (a detached copy of sessionx, 0 stars, pushed
  2026-09-30) already adds a Claude status column. Its rows read
  `name | last attached | window count | claude status | label`. State comes
  from pane options `@claude_state` (`busy`, `ready`, `ask`) and
  `@claude_state_at`, set by hooks. A session with several agents shows counts
  such as `ask 1 · busy 2`, and the preview lists each agent pane. It has no pi
  support. Useful as a reference, not as a dependency.
- Other tools (tmux-agent-deck, samleeney/tmux-agent-status) use hooks too.
  tmux-agent-deck reports 11.9 ms median per hook state change with 120 panes.
- Shared pitfalls: a crashed agent leaves `busy` behind, Esc on a prompt fires
  no hook, and `pane_current_command` is unreliable for Claude Code because it
  renames its process.
- Ideas worth borrowing: sort rows by attention (awaiting, then done-unseen,
  then working, then idle), a "done, not yet viewed" state, and a binding that
  jumps to the next agent waiting for input.

### F7. Agent hook surfaces

Claude Code (`claude/.config/claudef/settings.json`, launched by
`claude/.local/bin/claudef`, which inherits `$TMUX` and `$TMUX_PANE`):

| Event | State |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit` | working |
| `PreToolUse` matching `AskUserQuestion` | awaiting |
| `PostToolUse` matching `AskUserQuestion` | working |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | awaiting |
| `Stop` | idle |
| `SessionEnd` | clear |

- claudef runs with `bypassPermissions`, so permission prompts almost never
  happen. "Awaiting" mainly means `AskUserQuestion` or an elicitation.
- When Claude asks a question in plain text and stops, `Stop` fires. That case
  cannot be told apart from a finished reply using hook events alone. The
  `Stop` payload includes `last_assistant_message`, which the marker check in
  the design uses.
- Name: hook stdin has no title. `/rename` and auto-summaries appear as
  `custom-title` or `summary` entries in the transcript at `transcript_path`.
  A `Stop` hook can read the latest one. The fallback is the first prompt from
  `UserPromptSubmit`.
- Only `SessionStart` is hooked today, to
  `tmux/local-plugins/tmux-workspace-resurrect/scripts/record-agent-session.sh`.
  It writes a per-pane JSON with the session id and already validates pane
  identity against stale `$TMUX`.
- Confirmed in the installed 2.1.289 schema: `async` hooks, a `SubagentStart`
  event carrying `agent_id`, and `last_assistant_message` on `Stop` and
  `StopFailure`.

pi (`@earendil-works/pi-coding-agent`, launched by the `pif` zsh function with
`PI_CODING_AGENT_DIR=~/.config/pif`):

| Event | State |
|---|---|
| `agent_start` | working |
| `agent_settled` | idle (`agent_end` is too early: retries, compaction, queued follow-ups) |
| `ui_prompt_start` | awaiting |
| `ui_prompt_end` | working if `!ctx.isIdle()`, else idle |
| `session_shutdown` | clear |

- Name: `pi.getSessionName()`. `session_info_changed` fires on `/name`.
- `pi/.config/pif/extensions/tmux-workspace-resurrect.ts` is the only tmux
  integration and calls the same recorder on `session_start`.
- Incidental: `setup/node.sh` still installs the old package name
  `@mariozechner/pi-coding-agent`.

### F8. Memory measurement on macOS

Measured on this laptop (36 GB, about 845 processes, under memory pressure):

| Method | Cost |
|---|---|
| `ps -axo pid=,ppid=,rss=` snapshot | 28 ms median |
| awk tree sum over 1 to 20 pane roots | 1 to 5 ms |
| `footprint` CLI, 105 pids | 12.7 s |
| C helper using `proc_pid_rusage` `ri_phys_footprint`, all 604 pids | 4.9 ms (0.3 ms of work) |

- RSS is badly wrong for idle processes on macOS because compressed pages are
  excluded. Examples: one node process at 48 MB RSS against 2137 MB footprint,
  another at 2 MB against 59 MB.
- Footprint overcounts shared and graphics memory. The per-process sum came to
  75 GB on a 36 GB machine. It is good for ranking panes, not for exact totals.
- Linux: `ps` RSS is reasonable. `/proc/<pid>/smaps_rollup` Pss is accurate but
  costs a file read per pid.
- tmux caches each `#()` job by its expanded command string. A chip with
  `#{pane_pid}` in the command becomes one 28 ms job per pane per interval.
  `status-interval` is 5 s, set by tmux-sensible.
- No existing plugin does per-pane process-tree memory as a tmux option.
  tmux-task-monitor (popup TUI grouped by window) is the closest reference.

### F9. Status line and pane options today

- catppuccin with `session` on the left and `directory host` on the right
  (`tmux/tmux.conf:61-87`). The autosave chip is wired after TPM by
  `wire_autosave_indicator.sh`, and `tmux/scripts/autosave_indicator.sh` is the
  template for a hand-built chip.
- `pane-border-status` is off. `prefix P` toggles it (`tmux/tmux.reset.conf:41`).
- Pane options writes do not trigger resurrect saves. Autosave is a 300 s
  launchd or systemd timer, and continuum's interval is 0.

### F10. Remote agents are invisible locally

Agents in rw workspaces run inside the worker's own tmux server. The local
pane is an ssh attach loop carrying only `@remote-host`, `@rw-worker`,
`@rw-endpoint` and `@rw-workspace`. A local picker cannot see their state
without a pull over ssh. Never poll ssh from a `#()`.

## Decisions

Recorded 2026-10-05 from the user's answers. Superseded entries keep their
codes and point to the decision that replaced them.

- D1. Build a custom picker in this repo instead of patching or forking
  sessionx. Sessionx changes outside this scope, and owning the picker makes
  it faster to triage and iterate together with the agent hooks.
- D2. Agent pane states are exactly these four, in the user's words:
  - Finished: a response has been done with no awaiting input indication.
  - Working: currently running or processing, or subagents still running.
  - Awaiting Input: the agent is looking for a human in the loop response.
  - Idle: the agent is up and the user explicitly focused the pane while it
    was Finished, or the agent has not been run yet and has produced no
    responses.
- D3. Remote rw panes are out of scope for v1 and show as "remote". The label
  stays useful even if remote status is added later.
- D4. Current-pane memory sits in `status-right`, next to the autosave,
  directory and hostname chips.
- D5. Measure memory with the footprint helper (F8), run on demand. No
  periodic sampler.
- D6. `tmux/scripts/sessionx_fast.sh`, its test and fixtures were deleted on
  2026-10-05. Its one idea (a single option snapshot) does not apply to a
  picker that reads no options.
- D7. The user never uses permission prompts or `AskUserQuestion`. Questions
  for the user arrive as chat text. An `AskUserQuestion` call still counts as
  Awaiting Input when it happens.
- D8 (Q7). An agent that finishes while its pane is visible in an attached
  session goes straight to Idle.
- D9 (Q8). Sessions are sorted completely by recent use. The current session
  is at the bottom, and each row up was used further in the past. Session
  movement stays on `ctrl-n` (down) and `ctrl-p` (up), the bindings the user
  had configured for sessionx.
- D10 (Q9). Picker actions are switch, create, rename and kill. Closing every
  window of a session must keep killing it. Keys superseded by D16.
- D11 (Q11). No tree mode. The preview is a second selectable list with its
  own cursor: `ctrl-n` and `ctrl-p` move between sessions, `ctrl-j` and
  `ctrl-k` move within the preview, and `enter` goes to the preview
  selection. `ctrl-w` toggles pane mode, which lists one row per pane instead
  of one per window. This replaces the earlier idea of a global list of every
  window across sessions.
- D12. Every session row shows its agent state counts and its memory.
- D13 (Q10). The current session stays at the bottom of the session list and
  the session cursor starts one row up, on the previous session. The window
  ordering in the user's Q10 answer is superseded by D17.
- D14 (Q12). Superseded by D16.
- D15 (Q13). Preview rows keep index order so they do not reshuffle while
  navigating. The preview cursor starts on the row whose agent changed state
  most recently (`@agent_at`), or on the session's active window when it has
  no agents.
- D16. Create, rename and kill use the tmux prefix (`C-a`) followed by the
  same letters as in normal tmux panes. Lowercase acts on the preview
  selection, uppercase on the session. No Option (Alt) chords, because Option
  is used by AeroSpace, and no `fn`, which triggers Wispr Flow. No Ghostty
  remaps.
- D17 (Q14). The session list runs bottom up by recency. The preview lists
  windows (or panes) top down by ascending index, with the most recent agent
  state change selected automatically. The top-down list becomes a grid in
  D22.

Recorded 2026-10-06 from the UI follow-up and its wireframes. Design detail
is in "Picker UI v2".

- D18. Layout, top to bottom: the preview as a grid of cards, the session
  list showing at most 4 rows, and the input line. No header and no key
  hints.
- D19. Status labels and icons, each on a coloured chip background:
  - Done (internal value `finished`, renamed in the UI only): Lucide
    `circle-check`, green.
  - Working: Lucide `circle-dashed`, blue.
  - Awaiting input: Lucide `circle-question-mark`, orange.
  - Idle: Lucide `circle-minus`, gray.
- D20. The input line shows the match count (`22/22`) at the right. Right of
  the count is a plain colour cell with no icon: green while the prefix is
  not armed, red while it is armed. It replaces the header chip.
- D21. A session row shows the name, then aggregated status chips (`count
  icon`, in the order Awaiting, Done, Working, Idle), then memory aligned to
  the right edge. The selected row has a light highlight across its full
  width. The left edge keeps the v1 indicator (Q16): a dark column beside
  the rows with a light mark on the selected row. In fzf this is the gutter
  column and the `▌` pointer.
- D22. The preview is a grid of cards. Column and row counts follow the
  preview size. `ctrl-j` steps to the next card (right, then wraps to the
  next row), `ctrl-k` to the previous one. The first selection follows D15
  (latest agent state change, else the active window or pane), which may be
  further down the grid.
- D23. Pane mode is the default when the picker opens. `ctrl-w` toggles
  window mode. Supersedes the window-mode default in v1.
- D24. A pane card has three rows:
  1. `W.P window name`.
  2. The agent's name, or for a pane without an agent the command running or
     last run (`nvim`, `pnpm branch`).
  3. A status chip holding the runtime label (`claudef` or `pif`) and the
     status icon, with memory tight to its right. Without an agent, memory
     only.
- D25. Window mode. A window with one pane shows its pane card without the
  `.P` suffix. A window with several panes shows `W window name`, then a
  wrapping list of chips: `N panes` first, the aggregated status chips, and
  memory last. Fewer cards than grid slots leaves empty space.
- D26. Text that does not fit (window names, agent names, commands) is
  truncated with `…` or wrapped at the card's right edge.
- D27. Unselected cards are obviously dimmer than the selected card,
  including their chips. The selected card has a bright border and text.
- D28 (Q15). Lucide is added to the terminal setup, so the D19 icons are
  real Lucide glyphs.
- D29 (Q17). Every status chip shows the time since that status began,
  after the icon and on the chip's own background: `42s`, `5m`, `3h`, `2d`,
  `3w`. An aggregated chip (a multi-pane window card, or a session row)
  shows the age of the most recent change among the panes it counts. Agent
  cards read `claudef ◌ 5m`, session rows `1 ◌ 5m`.
- D30 (Q18). `ctrl-d` and `ctrl-u` move one card row down or up, keeping
  the column.
- D31 (Q19). The picker becomes a custom Go TUI (Bubble Tea and Lip Gloss)
  that uses fzf's matching algorithm as a library. It replaces the fzf-based
  `scripts/picker`, `scripts/preview` and `scripts/action`. Accepted with the
  Q20 answer, which only applied if Go was chosen.
- D32 (Q20). Linux setup installs Go, so the picker builds on headless
  workers too.
- D33. Search is plain matching of a name or a piece of one, anywhere in
  the session name. fzf's matcher is kept for its fuzzy matching and
  highlight positions. Its extended syntax is not reimplemented. The rest
  of the 2026-10-06 plan, the defaults marked "(default)" included, is
  accepted as written.

## Design

Implementation defaults chosen by the coordinator, not by the user, are
marked "(default)". Change them freely.

### Components and location

All new tmux-side code lives in one local plugin,
`tmux/local-plugins/tmux-agent-sessions/` (name is a default), loaded with
`run-shell` from `tmux/tmux.conf` next to the other local plugins
(`tmux/tmux.conf:117-124`) and before TPM.

| Path | Role |
|---|---|
| `tmux-agent-sessions.tmux` | binds `prefix o`, installs the `pane-focus-in` hook, appends the memory chip to `status-right` |
| `scripts/agent-state` | publisher called by Claude hooks |
| `scripts/picker` | builds the list and runs fzf |
| `scripts/preview` | renders the preview from the open-time snapshot |
| `scripts/action` | create, rename, kill and switch handlers called from fzf |
| `scripts/pane-mem` | memory entry point: runs `bin/pane-mem-darwin` when present, otherwise `ps` and awk |
| `src/pane-mem.c` | footprint helper source |
| `bin/` | compiled helper, gitignored |

Outside the plugin:

- Claude hooks in `claude/.config/claudef/settings.json`.
- pi extension `pi/.config/pif/extensions/agent-state.ts`.
- The marker rule in `agents/communication.md`.
- Helper build in `setup/lib.sh`, after the local plugin readability check
  (`setup/lib.sh:576-587`): compile with `clang -O2` on macOS when `clang`
  exists. No build on Linux.

### Agent state contract

Pane options, written only by the publishers and the focus hook:

| Option | Written by | When |
|---|---|---|
| `@agent_kind` | publisher | session start (`claude` or `pi`) |
| `@agent_pid` | publisher | session start |
| `@agent_state` | publisher, focus hook | every transition below |
| `@agent_at` | publisher | every transition except focus to Idle, so a visit does not move the D15 auto-selection |
| `@agent_state_at` | publisher, focus hook | when `@agent_state` changes value (repeats keep the stamp); status age (D29) |
| `@agent_name` | publisher | see naming below |
| `@agent_subs` | publisher | subagent start and stop (pi: running `/sub` count, D61), reset to 0 at session start |
| `@agent_empty` | publisher | `1` from session start (startup, `/new`, `/clear`) while the chat has no prompt, unset on the first prompt, resume and compaction (D59) |

Rules for the publishers:

- Every write for one event is a single tmux invocation chained with `\;`.
- No-op without `$TMUX_PANE`. Reuse the stale-`$TMUX` guard from
  `tmux/local-plugins/tmux-workspace-resurrect/scripts/record-agent-session.sh:20-36`.
- `@agent_pid`. Claude: at `SessionStart` the publisher walks up from its
  parent with `ps -o ppid=` until it reaches the process whose parent is
  `#{pane_pid}`, the pane's shell. This avoids depending on whether the hook
  runs under an intermediate `sh`, and on Claude Code renaming its process.
  pi: `process.pid`.
- Naming. Claude: on `UserPromptSubmit`, if `@agent_name` is empty, set it to
  the first 40 characters of the prompt. On `Stop`, read the last
  `custom-title` entry from the tail of `transcript_path` and overwrite the
  name when one exists. The transcript is read for the name only, never for
  state. pi: `pi.getSessionName()` at `session_start` and the name from
  `session_info_changed`, otherwise the first 40 characters of the first
  input.
- `@agent_subs` changes with `set-option -F`. Decrement clamps at zero:

  ```
  set -pF @agent_subs '#{e|+|:#{@agent_subs},1}'
  set -pF @agent_subs '#{?#{e|>|:#{@agent_subs},0},#{e|-|:#{@agent_subs},1},0}'
  ```

- Claude hooks are registered with `async: true`, except `UserPromptSubmit`,
  `SubagentStart` and `SubagentStop`, which run synchronously so a turn's
  `Stop` can never land before them, and `SessionEnd`, which must finish
  before Claude exits.

### Classifying Awaiting Input vs Finished

Agents end a reply that needs the user's answer with the exact final line
`Awaiting your input.`, required by a rule in `agents/communication.md`. Both
`claude/.config/claudef/communication.md` and `pi/.config/pif/communication.md`
are symlinks to that file. The check reads raw reply text, not the rendered
terminal, so terminal styling changes cannot break it.

- Claude: the `Stop` hook stdin carries `last_assistant_message` (confirmed in
  the installed 2.1.289 schema). The publisher checks its last non-empty line.
- pi: the extension checks the final assistant message in process on
  `agent_settled`.
- Rejected: screen scraping (drifts with agent UI changes) and a pi
  `report_status` tool (an extra tool round trip on every reply).
- Known miss: a question without the marker shows as Finished. Add a
  "last line ends with ?" fallback only if misses show up in practice.
- pif background subagents receive `communication.md` too, but they run with
  `--no-extensions` (`pi/.config/pif/extensions/subagent-widget.ts:259-266`),
  so they never publish pane state.

### State transitions

This table is authoritative. F7 lists the raw hook surface from research.

| Trigger | Result |
|---|---|
| Claude `SessionStart`, pi `session_start` | idle; set kind and pid; `@agent_subs` 0 |
| Claude `UserPromptSubmit`, pi `agent_start` | working |
| Claude `PreToolUse` on `AskUserQuestion`, pi `ui_prompt_start` | awaiting |
| Claude `PostToolUse` on `AskUserQuestion` | working |
| pi `ui_prompt_end` | working if `!ctx.isIdle()`, else unchanged until `agent_settled` |
| Claude `Notification` `elicitation_dialog` | awaiting |
| Claude `Notification` `idle_prompt` while working | idle (recovers from an Esc interrupt, which fires no `Stop`) |
| Claude `SubagentStart` / `SubagentStop` | `@agent_subs` +1 / -1, state unchanged |
| Claude `Stop` with `@agent_subs` > 0 | working |
| `Stop` or `agent_settled`, marker present | awaiting |
| `Stop` or `agent_settled`, no marker, pane visible | idle (D8) |
| `Stop` or `agent_settled`, no marker, pane not visible | finished |
| tmux `pane-focus-in` while finished | idle |
| Claude `SessionEnd`, pi `session_shutdown` | all `@agent_*` options unset |

- "Pane visible" is
  `#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}`,
  evaluated with `if -F` in the same tmux call that sets the state. An
  attached but unfocused terminal counts as visible (default).
- The focus transition is a tmux hook with an `if -F` check, so it spawns no
  process. `focus-events` is on (`tmux/tmux.conf:27`). It also fires when the
  terminal regains focus, which counts as a visit.
- When a background Claude subagent finishes, Claude Code resumes the main
  agent, whose next `Stop` sets the final state. `SubagentStop` reaching 0
  does not change state on its own.
- Known limits: `idle_prompt` arrives about 60 s after an Esc interrupt, so
  the pane shows Working until then. A subagent that dies without
  `SubagentStop` leaves the pane Working until the next `SessionStart`. A
  crashed agent is hidden by the picker's liveness check below.

### Memory

`scripts/pane-mem <pid>...` prints `<pid> <kib>` for each given root that is
alive, summing the root's whole process tree. Roots that are not alive print
nothing, which the picker uses as its liveness check for `@agent_pid`.

- macOS: `bin/pane-mem-darwin` reads `ri_phys_footprint` and the parent pid
  of every process with `proc_listallpids` and `proc_pid_rusage`, about 5 ms
  for 604 processes (F8).
- Fallback and Linux: one `ps -axo pid=,ppid=,rss=` snapshot summed with awk,
  about 30 ms.
- Picker: one call at open with every pane pid and every `@agent_pid`.
- Status chip: `#(~/.config/tmux/local-plugins/tmux-agent-sessions/scripts/pane-mem-chip #{pane_pid})`
  appended to `status-right` after TPM, following
  `tmux/scripts/wire_autosave_indicator.sh`. tmux runs it at most once per
  `status-interval` (5 s) per distinct command and client. After a pane change
  the chip is blank until the job returns, a few milliseconds later.
- Format: whole MiB below 1 GiB (`640M`), one decimal above (`2.4G`).
- Footprint overcounts shared and graphics memory (F8), so numbers rank panes
  rather than add up to system totals.

### Picker

Open path:

1. `prefix o` runs `display-popup -E -w 90% -h 85%` with `scripts/picker`
   and the invoking client's name (`#{client_name}`) as its argument, so
   switch commands target the right client. display-popup does not
   format-expand its command (tmux 3.7b `cmd-display-menu.c`), so the binding
   wraps it in `run-shell -b`, which does.
   - Fixed 2026-10-05 after the first live trial: closing the picker with
     `esc` showed `... returned 130` and left the client stuck in view mode.
     fzf exits 130 on `esc`, and `run-shell` shows any non-zero exit in view
     mode. The picker now always exits 0 (action errors already pause inside
     the popup), and the binding ends in `|| true` as a second guard.
   - The same takeover hit the other modals, which all go through
     `tmux/scripts/dialog.sh` from `run-shell` bindings: the scripts showed
     the dialog, then exited non-zero, so tmux opened view mode once the
     dialog was dismissed. Fixed the same way on 2026-10-05:
     - `manual_resurrect_save.sh` (`prefix C-s`, the save-failed dialog) and
       `window_nav.sh` (`prefix H`/`L`) exit 0 after their dialog.
     - `resurrect_restore.sh` keeps exit 1 for Continuum and its test, but a
       binding sets `TMUX_RESTORE_DIALOG=1`, so a failed `prefix C-M-r` or
       `M-F11` restore now shows its reason in the dialog. run-shell hides
       stderr, so before this the user saw only `returned 1`.
     - Every `run-shell` binding that can open a dialog ends in `|| true`:
       `C-s`, `C-M-r`, `M-F11` (`wire_resurrect_save.sh` and
       `tmux-workspace-resurrect.tmux`), `H`, `L`, `/`, `\`, `q`, `&`
       (`tmux.reset.conf`), `Tab` (`tmux.conf`), and `[` and `PPage` on
       remote panes (`tmux-remote-workspaces.tmux`).
     - Left alone: `prefix C-g` doctor, whose report is meant to show in view
       mode.
   - Width and height are fixed in the plugin's `.tmux` file (default),
     replacing `@sessionx-window-*`.
2. One `tmux list-panes -a -F` reads session, window, pane, pids, commands,
   `#{session_last_attached}`, `@remote-host` and every `@agent_*` option.
3. One `pane-mem` call.
4. One awk pass writes the session list and a per-session preview file into
   a `mktemp -d` directory, removed by a trap on exit.
5. fzf starts.

Session list:

- Input is ordered newest `session_last_attached` first, so in fzf's default
  layout the current session sits at the bottom. tmux sets that time on every
  session switch (`server_client_set_session` in tmux `server-client.c`).
  Never-attached sessions have 0 and land at the top.
- `load:pos(2)` puts the cursor on the previous session (D13).
- Row: name, then state counts for states that are present in the order
  Awaiting, Finished, Working, Idle, then memory:

  ```
  api        ◆1 ✔2        1.8G
  web        ✔1 ●2 ○1     2.4G
  infra      remote
  ```

  ◆ Awaiting Input, ✔ Finished, ● Working, ○ Idle. Agent names appear in the
  preview, not in the row.

Preview:

- Window mode rows: `index name  memory  agent summary`, ascending index. The
  agent summary is the agent's glyph, name and state age when the window has
  one agent, or counts when it has several. The selected row expands below
  itself to list its panes as in pane mode.
- Pane mode rows: `window.pane command  memory  glyph name age`.
- Rows without agents still show memory. Remote panes show `remote` in place
  of memory and agent fields. A session can mix local and remote panes.
- Two cursors. fzf has one list, so the preview cursor index and the mode
  live in a state file in the temp directory. `ctrl-j` and `ctrl-k` run
  `execute-silent` to change the index, then `refresh-preview`. Moving the
  session cursor (fzf `focus` event) resets the index to the D15 default.
- Scrolling. fzf cannot set the preview scroll from a state file, so the
  preview script prints only the rows that fit in `$FZF_PREVIEW_LINES`. The
  view follows the cursor at the edges, like the session list: it scrolls
  only when the selected row would leave the view, keeping a one-row margin.
  The scroll offset lives in the same state file. `ctrl-u` and `ctrl-d` move
  the preview cursor by half a page.
- `enter` runs `switch-client -c <client> -t <session>:<window>`, plus
  `select-pane` in pane mode. When the query matches no session, `enter`
  creates a session named by the query.

Keys:

| Key | Action |
|---|---|
| `ctrl-n` / `ctrl-p` | next / previous session |
| `ctrl-j` / `ctrl-k` | next / previous preview row |
| `ctrl-u` / `ctrl-d` | preview cursor up / down half a page |
| `ctrl-w` | toggle pane mode |
| `?` | toggle the preview |
| `enter` | go to the preview selection, or create a session from an unmatched query |
| `esc` | close |
| `C-a c` | new window in the selected session, name prompted (empty keeps automatic naming) |
| `C-a C` | new session, name prompted with the query as default |
| `C-a r` | rename the selected window |
| `C-a R` | rename the selected session |
| `C-a q` | kill the selected window, or the selected pane in pane mode |
| `C-a Q` | kill the selected session, after a y/N confirmation prompt (default) |

Prefix emulation. In tmux 3.7b a popup is an overlay:
`server_client_handle_key` gives every key to the overlay callback before
any key table is consulted (`server-client.c:1476` at tag 3.7b), and
`popup_key_cb` writes it to the popup's job. tmux prefix bindings never run
while the popup is open. tmux 3.8 replaces popups with floating panes, so
re-check on upgrade. fzf emulates the prefix:

```
--bind 'c:...,C:...,r:...,R:...,q:...,Q:...'
--bind 'start:unbind(c,C,r,R,q,Q)'
--bind 'ctrl-a:rebind(c,C,r,R,q,Q)+change-header(<red chip> prefix  c C r R q Q)'
```

- The header starts with a chip in the same colours as the session icon at
  the left of the tmux status line (`#a6e3a1` green at rest, `#f38ba8` red
  while the prefix is armed, from the catppuccin `#{?client_prefix,...}`
  format). Arming swaps the chip to red and lists the six keys. Disarming
  restores the green chip. fzf renders ANSI colours in the header without
  `--ansi`.
- While unbound the six letters type into the query.
- Each of the six runs its action, then `unbind(c,C,r,R,q,Q)` and restores
  the header.
- `change` and `focus` events, and the `ctrl-j`, `ctrl-k`, `ctrl-u`, `ctrl-d`,
  `ctrl-w` and `?` bindings, also unbind. Each of those keys does its
  normal job and disarms the prefix, so `C-a ctrl-j` moves the preview
  cursor as if `C-a` was never pressed, and `C-a x` types `x`.
- `ctrl-a` replaces fzf's default beginning-of-line.
- Name prompts run in the popup through fzf `execute`.
- The list reloads after create, rename and kill.

Kill paths:

- tmux `prefix q` routes panes with `@remote-host` through
  `tmux-remote-workspaces/scripts/rw-close.sh --pane` instead of `kill-pane`.
  The picker does the same: for a window or session kill, every remote pane
  in it goes through `rw-close.sh --pane` first, then the window or session
  is killed.
- Closing every window of a session is plain tmux behaviour and keeps
  killing it. The picker builds its list fresh on every open.

Live bindings checked on 2026-10-05: prefix is `C-a`, `prefix c` is
`new-window -c "#{pane_current_path}"`, `prefix r` and `prefix R` prompt to
rename the window and the session, `prefix q` is the rw-guarded `kill-pane`,
`prefix C` is `customize-mode -Z`, and `prefix Q` is unbound.

Target: under 100 ms to first render at normal load. This is an estimate to
measure after the build. Under heavy memory pressure a single tmux call has
been seen at 0.56 s (F3).

### Picker UI v2 (2026-10-06)

Replaces the v1 fzf picker: `scripts/picker`, `scripts/preview`,
`scripts/action`, their tests, the snapshot directory and the state file. Kept
from v1: the agent state contract, the publishers, the focus hook, `pane-mem`,
the memory chip, one `list-panes` call and one `pane-mem` call per open, the
D9/D13 session order, the D15 default selection, the D16 prefix keys and the
kill paths. Wireframes:
[pane mode](assets/sessionx-improvements/wireframe-pane-mode.png),
[window mode](assets/sessionx-improvements/wireframe-window-mode.png). The
window mode sketch draws cards 1 and 2 both bright. Read as one selected card
(assumption).

Evidence behind the choices below:

- An fzf feasibility pass (fzf 0.73.1 source and man page) found that
  most wireframe elements needed workarounds there: the list sized through
  the preview height, the prefix cell through `--info-command` (a shell per
  redraw), memory alignment through padding, and a preview process per
  keystroke (15 ms measured for v1, 20 to 30 ms estimated for a grid).
- A Go spike on 2026-10-06 (scratch module, Go 1.26.3) built fzf's matcher
  and the Charm v2 libraries and timed them (numbers below).

#### Components

| Path (plugin dir) | Role |
|---|---|
| `picker/` | Go module (`go.mod`, `go.sum`, one `main` package split into files by concern: snapshot, match, render, model, actions) |
| `bin/agent-picker` | built binary, gitignored with the rest of `bin/` |
| `tmux-agent-sessions.tmux` | binds `prefix o` to the binary, sets `@agent_clock` |
| `scripts/agent-state`, `scripts/pane-mem*` | unchanged except `@agent_state_at` below |

Pinned dependencies (latest stable on 2026-10-06):

```
github.com/junegunn/fzf      v0.74.4   only src/algo and src/util
charm.land/bubbletea/v2      v2.0.10   event loop, alt screen
charm.land/lipgloss/v2       v2.0.6    borders, padding, colour, display width
charm.land/bubbles/v2        v2.2.1    textinput for the query and prompts
```

- fzf's `algo` and `util` build with no cgo and no init side effects. Only 4
  external packages get linked. `algo.Init("default")` must run at start,
  or scores are wrong.
- Matching (D33): the whole query is one case-insensitive pattern, matched
  against each session name with `algo.FuzzyMatchV2`, which also returns
  the matched positions for highlighting. A typed piece of a name matches
  wherever it sits in the name. There is no fzf extended search syntax
  (`^`, `$`, `!`, `'`, space-separated terms). It lives in unexported code
  in package `fzf` and the user does not use it.
- The v2 Charm modules are published under `charm.land`. The
  `github.com/charmbracelet/*/v2` paths fail `go get`.
- `lipgloss.Width` counts a private-use glyph as 1 cell.
- Size and start: about 3 MB stripped. Cold start is about 23 ms, almost all
  package init in the Charm libraries (a bare Go binary starts in 3 ms).

#### Open path

1. `prefix o` runs `display-popup -E -w 90% -h 85%` with
   `bin/agent-picker '#{client_name}'`, wrapped in `run-shell -b ... ||
   true` as in v1. When the binary is missing at plugin load, `prefix o`
   shows `display-message "agent-picker not built: run make install"`
   instead (no fzf fallback).
2. One `tmux display-message -p -c CLIENT '#{session_id}' \; list-panes -a
   -F ...` call with the v1 fields plus `@workspace-last-command` and
   `@agent_state_at`.
3. One `pane-mem` call with every pane pid and `@agent_pid`. A missing
   agent pid still means a dead agent.
4. First frame. Estimate: about 25 ms start, the tmux call and about 5 ms of
   `pane-mem`, well inside the 100 ms target. Measure after the build.

Bubble Tea in the popup:

- Start with `tea.WithColorProfile` set to truecolor and never call
  lipgloss background detection, so no colour query goes to the terminal.
- Bubble Tea v2 sends one async query for synchronized output on Ghostty.
  Nothing waits on the reply. Its open issue #1590 says a reply can leak to
  the shell when the program quits within milliseconds. Verify in the
  isolated-server run.
- Issue #1718: the size can read as 0 under tmux. Fall back to 80x24 until
  the first size message.
- The escape timeout is 50 ms, the same as fzf's default.
- All state is in memory. A keystroke updates the model and redraws, with
  no process started. Data is reloaded (tmux call plus `pane-mem`) only
  after an action.

#### Layout

From the top: the card grid, the session list, the input box.

- Session list: always 4 rows. With fewer sessions the empty rows sit at
  the top, because the list runs bottom up (D17). The panel has a lighter
  background than the grid.
- Left gutter (D21): a dark column with a light mark on the selected row.
- Session row: name, then status chips, then memory on a darker cell at the
  right edge. A long name is truncated with `…` before anything else is
  cut. The selected row is highlighted across its full width.
- Input box: the query with a cursor, then at the right the match count
  (`matches/total` sessions) and a 2-column solid cell. The cell is
  `#a6e3a1` at rest and `#f38ba8` while the prefix is armed (D20).
- Grid: everything above the list. When less than one card row fits, the
  grid is hidden (default).

Search:

- The query filters session names. Rows keep recency order and are not
  re-sorted by score, like v1's `--no-sort`. Matched characters are
  highlighted (default).
- After a query change, the cursor moves to the bottom match (default).
- `enter` with no match creates a session named by the query, as in v1.
- The `textinput` keymap is trimmed so it does not take `ctrl-a`, `ctrl-d`,
  `ctrl-j`, `ctrl-k`, `ctrl-n`, `ctrl-p`, `ctrl-u` or `ctrl-w`. Arrows,
  backspace and typing still edit the query.

#### Cards

Geometry (default):

- Minimum card width 30 columns, a 1-column gap, and
  columns = floor((width + 1) / 31).
- A card is 3 content rows inside a rounded border. A multi-pane window
  card grows when its chips wrap, and each grid row takes the height of its
  tallest card.
- The scroll offset counts grid rows and follows the selection at the
  edges.
- `ctrl-j` / `ctrl-k` step through cards in reading order. `ctrl-d` /
  `ctrl-u` move one row, keeping the column (D30).

Content:

- Pane card (D24), and a single-pane window in window mode without `.P`
  (D25):
  1. `W.P window name`.
  2. The agent name, or the command.
  3. A status chip with runtime label, icon and age (`claudef ◌ 5m`), then
     memory.
- Multi-pane window card (D25): `W window name`, then wrapping chips:
  `N panes`, the aggregated status chips (`count icon age`), memory last.
- Remote panes (D3) show `remote` where memory goes and no chip.
- Command on non-agent cards (default rule): the zsh preexec hook
  (`zsh/.zsh/tmux-workspace-resurrect.zsh:45-52`) stores the full command
  line in the pane option `@workspace-last-command`. When
  `pane_current_command` is a shell, the card shows that last command,
  dimmed. Otherwise it shows `@workspace-last-command`, which gives
  `pnpm branch` where `pane_current_command` says `node`. Without it, the
  card falls back to `pane_current_command`. `#{pane_title}` is unusable
  because `allow-set-title off` (`tmux/tmux.conf:25`).
- Text is truncated with `…` or chips wrap at the card edge (D26).

Colour (catppuccin mocha):

- Chip backgrounds: Done `#a6e3a1`, Working `#89b4fa`, Awaiting `#fab387`,
  Idle `#6c7086`, with dark text `#1e1e2e` like the status line chips
  (default).
- Terminals have no alpha. The highlight, the panel and dimmed cards use
  colours pre-blended against the base `#1e1e2e`.
- Unselected cards blend every colour, chips included, about halfway toward
  the base (default, tune in the live trial). The selected card has a
  bright border and full colour (D27).
- Ghostty runs `background-opacity = 0.9` with the default
  `background-opacity-cells = false`. Cells with an explicit background
  render opaque and default cells at 90%. Left as is.

#### Status age (D29)

- Format: `42s`, `5m`, `3h`, `2d`, then weeks (`3w`) from 7 days, with no
  months.
- A new pane option `@agent_state_at` holds the epoch second the current
  state began. The publishers write it with every transition, next to
  `@agent_at`. The focus hook writes it on Finished to Idle. D15 keeps
  reading `@agent_at`, so a visit still does not move the default
  selection.
- The focus hook gets the time without a process. The plugin sets
  `set -g @agent_clock '%s'`, and the hook runs
  `set -pF @agent_state_at '#{T:@agent_clock}'`. `T:` expands strftime.
  Verified on an isolated tmux 3.7b server on 2026-10-06: the hook stamped
  the current epoch on Finished to Idle and did nothing for Working.
- An aggregated chip shows the newest `@agent_state_at` among the panes it
  counts.

#### Lucide (D28)

- `lucide-static` 1.52.0 (ISC licence) ships `font/lucide.ttf`, family name
  `lucide`. Codepoints were read from the font's cmap:

  | Status | Icon | Codepoint |
  |---|---|---|
  | Done | circle-check (cmap name `check-circle-2`) | U+E226 |
  | Working | circle-dashed | U+E4B0 |
  | Awaiting | circle-question-mark (alias `circle-help`) | U+E082 |
  | Idle | circle-minus | U+E07E |
  | Agents (D57) | bot | U+E1BB |

- U+E226 collides with a Hack Nerd Font glyph, and 815 of Lucide's 1907
  codepoints overlap Hack. So `ghostty/config` maps only these four:
  `font-codepoint-map = U+E226,U+E4B0,U+E082,U+E07E=lucide`.
- macOS setup downloads the pinned `lucide-static` tarball, checks its
  sha256 and installs `lucide.ttf` into `~/Library/Fonts`. Linux workers
  need no font, because the glyphs render in Ghostty on the laptop.
- Each icon is followed by a space inside its chip, in case Ghostty lets a
  glyph spill over (verify visually).

#### Actions

- The tmux side effects move from `scripts/action` into Go (default): one
  language, targets passed as ids, no snapshot directory, and errors shown
  inline instead of a "press a key" pause.
- Covered:
  - switch (with `select-pane` in pane mode);
  - create session from an unmatched query;
  - new window;
  - new session;
  - rename window and session;
  - kill pane, window and session.
- Remote panes still close through `rw-close.sh --pane` first.
- Name prompts and the `C-a Q` y/N confirmation are inline, in place of the
  input line. `esc` cancels.
- `tests/action-test.sh` cases become the checklist for the Go action
  tests.

#### Build and setup

- Build: `go build -trimpath -ldflags='-s -w' -o bin/agent-picker ./picker`
  in the plugin dir. It runs in `install_tmux_plugins` (`setup/lib.sh`)
  after the `pane-mem` block, on macOS and Linux. Go's build cache makes
  re-runs cheap. Without `go`, or when the build fails, setup prints a
  `WARNING:` and continues.
- macOS gets Go from `Brewfile:32` (already present) and
  `Brewfile.headless:33`.
- Linux (D32): a new `setup/go.sh`, modelled on `setup/neovim.sh:41-93`:
  - Pin `GO_VERSION=1.26.3` with sha256 values for linux-amd64 and
    linux-arm64, verified with `sha256sum -c`. This is the first
    checksum-verified download in setup.
  - Install to `~/.local/opt/go-<version>` and symlink `go` and `gofmt`
    into `~/.local/bin`.
  - Skip when `go version` already reports the pin. Linux only.
  - Not apt: Ubuntu 24.04's `golang-go` is 1.22, older than the module
    needs.
- `setup/linux-headless.sh` calls `setup/go.sh` before
  `install_headless_dotfiles` (around `:700` and `:529`), and adds `go` to
  `verify_commands` (`:649`).
- Parity: move `go` from `setup/tool-parity-exceptions.txt:61` to the
  "installed by other mechanism" list (`docs/headless-vs-local.md:235`).
- Doctor: add `go` to `REQUIRED_CMDS` (`setup/headless-doctor.sh:110`), and
  a WARN-level `check_executable` for `bin/agent-picker`.
- Docs: add Go to `README.md:46-48` and `docs/headless-workers.md:56-64`,
  `:180` and `:237`.

#### Tests

- Go tests (`go test ./picker`):
  - snapshot parsing from fixture `list-panes` output;
  - the matcher: a piece from the middle of a name, case folding, no
    match, highlight positions;
  - age formatting;
  - golden renders of session rows, pane and window cards and the input
    line, at a few widths, with ANSI stripped and styled;
  - model tests that feed key messages: prefix arm and disarm, card
    stepping, row moves, mode toggle, D15 default, enter;
  - action tests against a fake `tmux` shim first in `PATH`, with
    `TMUX`/`TMUX_PANE` unset, asserting the shim before anything runs.
- Kept bash tests: `agent-state-test.sh` (plus `@agent_state_at`) and
  `pane-mem-test.sh`.
- Removed with their scripts: `action-test.sh`, `picker-test.sh` and
  `preview-test.sh`.
- One pty run against an isolated `-S` tmux server: open, type, arm the
  prefix, step cards, rename, kill, enter. Then the user's live trial.

#### Verify during the build

- Icon glyph width in Ghostty (spill into the following space).
- The Bubble Tea startup query leaking on a very fast quit (#1590).
- First frame size in the popup (#1718).
- Measured open time against the 100 ms target.

Results, 2026-10-06, on an isolated tmux 3.7b server with a nested client
opening the real popup:

- First frame was full size, so #1718 did not show.
- No reply leaked into any pane, including on `esc` 80 ms after open
  (#1590).
- Keypress to first frame: 76 to 89 ms, polling overhead included.
- Exercised: typing, prefix arm and disarm (cell colour), window mode,
  card steps, `C-a r`, `C-a c`, `C-a q`, `C-a Q` with `n`, `enter`, `esc`
  with no view mode left behind. The publishers' `@agent_state_at`
  keep-or-restamp format was checked on the same kind of server, through
  the nested `if -F` path of the Claude `Stop` hook.
- Glyph width in Ghostty is left for the live trial.

Built differently from the text above:

- The module has four packages so the work could be split: `state` (the
  snapshot types and the `Actions` interface), `tmuxio` (the tmux call,
  `pane-mem`, actions), `ui` (Bubble Tea model and rendering) and `main`.
- Prompts get `ctrl-u`, `ctrl-w`, `ctrl-a` and `ctrl-k` as in tmux's own
  command prompt, so a prefilled name can be cleared. The query keeps the
  trimmed keymap. Found in the isolated run.
- `ctrl-j` and `ctrl-k` wrap between rows but stop at the first and last
  card. `C-a esc` closes the picker.
- An action reloads even when it fails, because a kill can succeed after
  `rw-close.sh` fails. A failed reload keeps the old snapshot. Errors show
  in the input line.
- The `N panes` chip is `#45475a` with light text, since dark text was
  unreadable on it.
- macOS installs the font with `setup/lucide-font.sh` (`make lucide-font`,
  part of `make setup`). The doctor's `check_executable` takes a `warn`
  argument for the picker binary.

### UI v2 refinements (2026-10-06, after the first live trial)

The goal screenshot (replaces the pane mode wireframe) shows:

- A 3 x 2 grid of cards that spans the full popup width, with a solid dark
  background. The selected card has a white border, the others gray
  borders and dim text. Cards read `1.1 advertorials`, `[agent session
  name]` or `[process ie "nvim"]`, then the chip (`claudef ◌ 2hr`) and
  memory.
- Status chips with white text on saturated backgrounds (green, teal blue,
  orange, gray), the age a little dimmer than the count or label.
- Session rows with the name at the left and the chips pushed right,
  against a fixed-width dark memory cell.
- A thin track at the left of the list with a light thumb.
- The input line between two horizontal rules, with `22/22 +T` and the
  prefix cell at the right.

Decisions from the user's explicit asks:

- D34. Session row: the status chips float right, directly left of the
  memory cell. The name stays at the left. Supersedes the chip position in
  D21.
- D35. The session list shows 6 rows. Supersedes the 4 rows in D18 and
  D21.
- D36. The grid shows at most 3 full card rows. When more rows exist below,
  the top of the next row (its top border and first content line) shows
  under them as a cue.
- D37. Row 2 of an agent card is the agent's session title:
  - Claude writes an auto title into the transcript as `{"type":"ai-title",
    "aiTitle":...}`, repeated through the file, and `/rename` writes
    `custom-title`. The publisher only read `custom-title`, so cards showed
    the first-prompt fallback, which for a resumed session is the latest
    prompt. New order: last `custom-title`, else last `ai-title`, else the
    first prompt until a title exists. Read at `SessionStart` (so a resumed
    session shows its title at once), `UserPromptSubmit` and `Stop`.
  - pi has no auto title. A name exists only after `/name`, `--name` or
    `pi.setSessionName()`, stored as `session_info` entries.
    `agent-state.ts` already reads it and falls back to the first prompt.
- D38. Card memory sits on the same dark cell, with the same padding, as
  the session rows' memory.
- D39. The Lucide icons are centered in their cells. Cause: the four glyphs
  are about 0.92 em circles on a 1 em advance, drawn from the baseline up
  (ascent 1000, descent 0), in a cell about 0.6 em wide, so they spill
  right and sit high. Ghostty 1.3.1 has no per-font scale or offset, and its
  Nerd Font fit rules are keyed by codepoint, so they likely apply to
  U+E226 but not the other three. Fix: a derived font holding only the four
  glyphs, rescaled and centered against Hack's cell metrics, mapped to the
  same codepoints.

Decisions from the user's answers to the coordinator's suggestions (Q21 to
Q23), 2026-10-06. Where they differ from the goal screenshot, these win.

- D40 (O1). The picker keeps Ghostty's transparency. Cells get no explicit
  base background.
  Superseded 2026-10-07 at the user's request ("maybe give it the same bg
  color as the sessionx picker uses?"): the popup gets sessionx's
  background, `#1e1e2e` (catppuccin mocha base, which sessionx got from
  fzf's `bg` in `FZF_DEFAULT_OPTS`), through `display-popup -s
  'bg=#1e1e2e'` in `tmux-agent-sessions.tmux`. Cells with their own
  background keep it.
- D41 (O2). The grid has at most two columns, each half the width (one
  column when half the width is under the 30-column card minimum).
  Supersedes the column rule under "Cards". With D36 the grid shows at most
  6 full cards.
- D42 (O3). The popup stays `-w 90% -h 85%`. More windows and panes fill
  the space between the grid and the list.
- D43 (O5). The left gutter and selection mark stay as built.
- D44 (O6). The input line gets a horizontal rule above and below it, two
  more rows, in the card border colour (`#585b70`, default).
- D45 (O7). The `W.P` label in the selected card stays lavender.
- D46 (Q22, revised after research the same day). pif generates a session
  title once, and again only after a compaction or on request:
  - First title: after the first settled reply whose prompt has at least 10
    characters, so a "hi" never becomes the title. Input is the first
    prompt plus the start of the reply, about 2,000 characters, keeping the
    head and the tail when longer.
  - Retitle on compaction only. The input is pi's compaction summary, capped
    at 2,000 characters. pi has already paid for that summary and it covers
    the whole session.
  - A `/retitle` command regenerates on demand, for a mid-session change of
    topic.
  - No per-turn or every-N-prompts retitle, and no tool or step count
    thresholds. Tool counts measure work, not a change of topic.
  - Runs as a background promise on `agent_settled` (and after compaction),
    so it never delays a turn or the state publish. Errors are dropped.
  - Never replaces a name set by `/name` or `--name`. The extension records
    each auto title it sets (a custom session entry, default). If the
    current name differs from the last recorded one, the user set it, and
    auto titles stop for that session. The check lives in one function that
    every write path goes through.
  - One call to a fast, cheap model through `ctx.modelRegistry.complete`,
    output capped at about 30 tokens. The prompt follows Claude Code's: a
    short noun phrase of two to five words, in sentence case, without
    request verbs. The model is picked during the build from what the
    registry offers (open).
  - The title is set with `pi.setSessionName()`. The existing
    `session_info_changed` listener publishes it to `@agent_name`, and pi's
    `/resume` list shows it too.
  - The first-prompt fallback stays until the first title arrives.
  - Evidence (2026-10-06 research):
    - pi 0.85.1 names sessions only by hand.
    - Four community extensions (`@byteowlz/pi-auto-rename`,
      `pi-session-title`, `pi-session-naming`,
      `@agnishc/edb-auto-name-session`) title once, on the first message.
      None retitles on compaction or protects manual names this way, so
      the feature is written in the repo instead of installed.
    - Claude Code 2.1.292 titles once with its small fast model from about
      2,000 characters, and in 163 local sessions never changed a title.
    - OpenCode, Codex, LibreChat, Open WebUI and others title once from the
      first message with a cheap model. None sends the full context, and
      none uses activity thresholds.
    - Estimated cost: about 500 input and 30 output tokens per title, a
      fraction of a cent.
- D47 (Q23). No `+T` beside the match count. It came from sessionx.
- D48. Stop `make install` from deleting claudef's ccline links. Found
  while checking why the claudef status line showed emoji in the live
  trial:
  - `cleanup_focus_agent_links` (`setup/lib.sh:293`, run by `make install`
    and `make install-headless`, `Makefile:147` and `:244`) removes
    `~/.claude/ccline/config.toml`, `models.toml` and
    `themes/personal.toml` when they are symlinks into this repo. It was
    written for old stow links at those paths.
  - The `claudef` launcher (`claude/.local/bin/claudef:22-36`) now creates
    links at the same paths on purpose. After each `make install`, ccline
    finds no `config.toml`, falls back to its built-in plain theme and
    shows emoji until the next claudef launch.
  - Fix: drop the three `~/.claude/ccline/` paths from the function's
    list. The launcher owns them and setup leaves them alone. The `rmdir`
    of `~/.claude/ccline/themes` can stay, because it only removes an
    empty directory and that one holds ccline's stock themes. The doctor's `runtime:claudef-ccline` check
    (`setup/headless-doctor.sh:558-566`) already expects the links and
    stays as is.
- D49 (Q24). Every chip uses white text, with no dark text on any chip.
  The backgrounds become darker shades of the same catppuccin hues,
  darkened until white text reaches about 4.5:1 (starting values, tune in
  the live trial):

  | Status | Was | Now | White contrast |
  |---|---|---|---|
  | Done | `#a6e3a1` | `#2f8628` | 4.6:1 |
  | Working | `#89b4fa` | `#1b6ef5` | 4.6:1 |
  | Awaiting | `#fab387` | `#c65108` | 4.6:1 |
  | Idle | `#6c7086` | `#6c7086` | 4.9:1 |

  The count and runtime label are white `#ffffff`, the age a little
  dimmer (default). The `N panes` chip keeps its light text. Supersedes
  the chip colours under "Colour".

Build notes for phase 6 (2026-10-07):

- Picker (`picker/ui`): `heights()` in `model.go` gives the input line
  priority, then up to 6 list rows and the two rules, and the grid takes
  the rest. Small screens drop grid rows first, then list rows, then the
  rules. At 180x45 the grid uses 17 of its 36 lines (3 rows plus the cue),
  so a blank gap sits between the grid and the list. Check it in the
  trial. The age on chips is `#e0e0e0`. One memory cell style now serves
  rows and cards. No `+T` existed to remove.
- D37 (`scripts/agent-state`, `transcript_title`): one pass over the last
  256 KiB for both entry types, then one whole-file scan with `rg` (about
  15 ms on a 45 MB transcript, about 260 ms with macOS grep) when the tail
  has no title. SessionStart reads the title only for `resume` and
  `compact`.
- D39 (`setup/lucide-font.sh`, `setup/lucide-font-derive.py`): Ghostty
  1.3.1 source confirms the cause:
  - A PUA codepoint without a Nerd Font rule only gets "fit", with no
    alignment change, and may use two cells when a space follows. The
    font's own outline position decides where it lands.
  - U+E226 has a Nerd Font rule (`fit_cover1`, centred), which is why it
    looked right.
  - A codepoint-mapped font is scaled to match the primary font's x-height.
  - JetBrains Mono NL is not installed, so Hack Nerd Font Mono is the
    primary font.
  
  The derived "Lucide Picker" font copies Hack's metrics (scale 1.0) and
  puts each circle at the cell width, centred on the cell. That matches
  what Ghostty does to U+E226. It is built with `uv run --with
  fonttools==4.62.1`, its output is byte-identical between runs and pinned
  by sha256, and it replaces `~/Library/Fonts/lucide.ttf`. `ghostty/config`
  maps the four codepoints to `Lucide Picker`.
- D46 (`agent-state.ts`):
  - The model is `openai-codex/gpt-5.6-luna` with `reasoningEffort:
    "none"` (10 output tokens in a probe). The preference list continues
    with haiku 4.5, gemini 2.5 flash-lite and gpt-5-nano, then the
    session's model.
  - `/retitle` skips the manual-name guard, because the user asked for it,
    and records the result as an auto title. The other paths re-check the
    guard just before writing, so a `/name` during the call wins.
  - Verified end to end over pi's RPC mode with tmux unset: "hi" got no
    title, then the first title, `/retitle`, a manual name kept through a
    compaction, a retitle on compaction, and no title leaking into a
    session switched to mid-call.
- D48: `cleanup_focus_agent_links` no longer lists the three ccline paths.

### Card and session row rules (2026-10-07, second live trial)

From the user's 2026-10-07 follow-up, with Q25-Q33 answered on 2026-10-08.
Built 2026-10-08 on the user's go-ahead (build notes after D61).

Cards:

- D50. The grid has one mode. The window/pane toggle goes away, and
  `ctrl+w` is reused by D57. Supersedes the two grid modes.
- D51. One card per window. A window with two or more agent panes gets one
  card per agent pane instead, in pane order. A window with one agent pane
  is one card for that agent.
- D52. A card shows at most one agent: its kind, status icon and age. No
  aggregate status chips on cards.
- D53. Card subtitle: the agent's session name (`@agent_name`). A window
  with no agent shows its first pane's (lowest index) running command,
  truncated. An agent whose chat is still empty shows the empty-chat
  placeholder (D59).
- D54. The `N panes` chip always shows, `1 pane` included.
- D58 (Q25, Q26). Window cards are headed `W name`, split agent cards
  `W.P name`. Split cards of one window show the same window memory total
  and the same window pane count. Only the header and the agent title
  differ.
- Enter (Q27): a split card focuses its pane, a window card its window,
  keeping the active pane.

Session rows:

- D55 (Q29, Q30, Q31). Floating right, left to right, in three sections
  divided by thin vertical lines (`#585b70`, the D44 rule colour):
  1. Status chips: Working, Awaiting, Done, in that order, each only when
     its count is above zero. Each reads count, label, age (`2 Working
     4m`): the number of agents in that state and the age of the newest
     change among them. The only section whose width varies.
  2. Agents: `N<bot> age`, all agents in the session and the age of the
     most recent state change of any. Shows `0` with no age for a session
     without agents. Fixed width on every row.
  3. Memory, as now. Fixed width on every row.

  Only the status chips have a background. The agents and memory sections
  have none, which drops the dark memory cell from rows (D38). Cards
  follow the rows, so card memory loses it too (coordinator's call, since
  D38 asked for the two to match). No Idle chip on rows. Cards keep Idle.
- D56. A visit never clears Awaiting. Already true: the focus hook only
  turns Done into Idle. Awaiting lasts until the next prompt, `/clear` or
  the agent exiting.
- D57 (Q28). Status chips on rows show the words Working, Awaiting and Done
  by default. `ctrl+w` switches to icons (`2 <icon> 4m`) for that picker
  run, not saved. After the trial one is kept and the toggle removed. The
  Lucide `bot` glyph joins the derived font and the Ghostty codepoint map.
- D60. Chip backgrounds return to the catppuccin pastels: Done `#a6e3a1`,
  Working `#89b4fa`, Awaiting `#fab387`, Idle `#6c7086`. Supersedes the
  darker shades in D49. Text stays white on every chip (Q34, per D49).

- D62. The popup border cells get the picker background too: `-S
  'bg=#1e1e2e'` beside `-s 'bg=#1e1e2e'` in the `prefix o` binding
  (`tmux-agent-sessions.tmux`). The border keeps its default line colour.

Agents:

- D59 (Q33 and the empty-chat fallback). A Claude or pif agent whose chat
  has no messages yet shows a placeholder title, `Empty chat` (default,
  dimmed), instead of a command or nothing, so an empty chat doesn't look
  broken. It shows from session start (startup, `/new`, `/clear`) until
  the first prompt, when the first-prompt fallback and then the auto title
  take over. pif also generates the first title at session start when a
  reopened session has a qualifying exchange and no title. Claude already
  shows a reopened session's title at SessionStart (D37).
- D61 (Q32). pif publishes the number of running `/sub` subagents to
  `@agent_subs`, as Claude's hooks do, so the parent stays Working until
  they finish.

Phase 7 build notes (2026-10-08):

- Empty-chat signal: a new pane option `@agent_empty` (`1` = no prompt
  yet), set by both publishers, rather than inferring emptiness from a
  missing `@agent_name`, which a resurrected or untitled agent also has.
  Card subtitle order: `Empty chat` (dimmed) when `@agent_empty`, else
  `@agent_name`, else the pane command.
- pif at session start: a reopened session without a name publishes its
  first prompt (40 chars) as `@agent_name` until the title lands.
- D61: `subagent-widget.ts` emits the running count on the `pif:subagents`
  event bus channel. `agent-state.ts` publishes it as `@agent_subs`, and a
  settle with subagents running publishes Working. A finished subagent
  starts a parent turn, which settles as usual. If none starts within 2 s
  (a `/subrm` or `/subclear`), the held Working settles on its own.
  Verified over RPC with a fake tmux shim.
- Rows: both separators always draw, and the agents column is a constant
  7 cells (count to 99, glyph, age), so agents and memory align on every
  row. Cards with one agent stay window cards (`W name`). A no-agent window
  shows its lowest-index pane's command. `q` kills a split card's pane or a
  window card's window. `ctrl+w` stays word-delete inside prompts.
- Font: `bot` (U+E1BB) is narrower than the widest glyph, so the shared
  scale and the four status glyphs are unchanged. New derived sha
  `98b735f9...c651e9`.

### Order and time colours (2026-10-08, after the phase 7 build)

- D63. Session order, top to bottom, with the client's own session always
  last. The others are sorted so higher priority sits lower, compared in
  turn: Awaiting count, Done count, Working count, the newest agent state
  change, then `session_last_attached`. Counts compare one after another
  (2 Awaiting beats 1 Awaiting plus 5 Done), not as a weighted product.
  The cursor still starts one above the bottom (D13), on the top priority
  session. Supersedes least recently used order.
- D64. A chip's age text is a darker shade of its own pastel: Done
  `#5b7d59`, Working `#4b638a`, Awaiting `#8a624a`, Idle `#3b3e4a`. Count,
  label and icon stay white.
- D65. Formatted time is always dimmer than the text beside it. Without a
  background the age is `#7f849c`, or `#a6adc8` on the selected row.
- D66. The agents column reads `<bot> N age`, icon first, then a space.

- D67 (trial). Chip count, label and icon use the darker pastel (D64's
  age colour). The age is 30% of the way from that toward the chip
  background: Done `#719b6f`, Working `#5e7bac`, Awaiting `#ac7a5c`, Idle
  `#4a4d5c`. Supersedes white chip text (D60, Q34) for this trial.
  Darkened on 2026-10-08 ("too light ... keep the formatted time text
  color the same"): text Done `#465f44`, Working `#394c69`, Awaiting
  `#694b39`, Idle `#2d2f38`. The ages are unchanged.
- D68. Icons are 1.15 cell widths, centred, so they overflow slightly into
  the neighbouring spaces. Done moves from U+E226 to U+E1C0, because
  Ghostty's Nerd Font rule for the E200-E2A9 range holds U+E226 to one
  cell. New derived sha `450ed542...2cce`.

- D69 (fix, 2026-10-08). Claude's `idle_prompt` notification fires 60 s
  after the prompt goes idle, even while background subagents run, and the
  Esc-recovery rule turned Working into Idle. It now applies only when
  `@agent_subs` is 0. Seen live on a session with 2 running agents. Known
  gap: a subagent that backgrounds a command and ends its turn fires
  SubagentStop at once and SubagentStart only when it resumes, so it is
  uncounted in between.
- D70 (fix, 2026-10-08). Closes that gap and covers the main agent's own
  `run_in_background` shells. Stop and `idle_prompt` check whether the
  Claude process has a child shell from its Bash tool (command contains
  `/.claude/shell-snapshots/`). At those points no foreground tool runs, so
  any such shell is background work, and the state stays Working. Seen live
  with a subagent polling CI through `sleep 120`. Costs about 40 ms per
  Stop (one `ps -A`). A dev server started as a Claude background shell
  would keep its agent Working, which is acceptable because persistent
  jobs go in tmux panes.

### Removing sessionx

Done in the same change as the picker binding:

- `tmux/tmux.conf:50` (`@plugin` line) and `tmux/tmux.conf:96-110`
  (`@sessionx-*` options and comments).
- `setup/lib.sh:51-52` (header comment), `:104-108` (`TMUX_SESSIONX_PIN`),
  `:341-392` (pre-clone and re-pin), and the cross-reference comment at
  `:412`.
- The installed copy at `~/.config/tmux/plugins/tmux-sessionx` stays on disk
  until the user deletes it.
- Historical mentions in other docs stay as they are.

## Open questions

Q21-Q24 were answered on 2026-10-06 (D40-D47, D49). Phase 6 was built on
2026-10-07; the title model in D46 is gpt-5.6-luna.

Q25-Q34 were answered on 2026-10-08 (D55, D57-D61). None are open.

- Q34 was answered on 2026-10-08: white text on the pastel chips (D60).

## Phases

1. State layer: marker rule, `agent-state` publisher, Claude hooks, pi
   extension, focus hook.
2. `pane-mem` helper, its setup build, and the `status-right` chip.
3. Picker, `prefix o` binding and sessionx removal.
4. Later: remote agent state pulled through rw.
5. UI v2 (D18-D33, "Picker UI v2"), in order:
   1. Toolchain: `setup/go.sh` and its Linux wiring, the parity list, the
      doctor, the docs, the Lucide font install and the Ghostty codepoint
      map, and the picker build step in `install_tmux_plugins`.
   2. State: `@agent_state_at` in both publishers, `@agent_clock` and the
      focus hook, with tests.
   3. Go picker: snapshot, matcher, render, model and keys, actions, and
      tests.
   4. Switch `prefix o` to the binary, remove `scripts/picker`,
      `scripts/preview`, `scripts/action` and their tests, then the
      isolated-server pty run and the user's live trial.
6. UI v2 refinements (D34-D49): layout and colour
   changes in `picker/ui`, Claude title sources in `scripts/agent-state`,
   pif auto titles in `agent-state.ts`, the derived icon font in
   `setup/lucide-font.sh` and `ghostty/config`, the ccline link fix in
   `cleanup_focus_agent_links`, then another live trial.
7. Card and session row rules (D50-D62), built 2026-10-08: the
   single-mode grid and split cards, the sectioned session row with word
   chips and the `ctrl+w` toggle, the pastel chips, the `bot` glyph in the
   derived font, the empty-chat placeholder in both publishers, pif titles
   at session start, pif subagent counts, and the popup border background.
