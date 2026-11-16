# Claude Control (Mantra): takeover

What it is: a menu-bar app (LSUIElement, bundle community.auroville.claudecontrol, repo markoboskoauroville/CLAUDE_CONTROL, public, unpromoted: no README, no description). One play/pause for everything Claude Code runs on this Mac. Band like Talk Mode's (app/StatusBand.swift, same file): green "RUNNING n", amber "PAUSED n", grey NO SESSION; n = Claude Code sessions. Left click = toggle; right click or option-click = menu (Pause all, Resume all, sessions with folder and state, tools with state, Quit).

How sessions are found (app/Core.swift, `ps -axww -o pid,ppid,stat,command`): a root is a process whose argv0 is a file named exactly `claude` (not inside an .app), or node running @anthropic-ai/claude-code. Everything below a root (child tree by ppid: bash, python, blender, adb, ffmpeg, gh run watch ...) is paused too.
Pause all: (1) every tool in ~/.config/claude-control/tools.json through its own pause API (Macro Recorder, Queen; the app is never SIGSTOPped); (2) SIGSTOP on the Claude trees, deepest first, up to four scans so new children are caught, parents last. Resume: SIGCONT parents first (only pids in the state file whose command still matches), then the tools' resume. State: ~/Library/Application Support/Claude Control/paused.json (survives an app restart).
Never stopped (with their subtrees): this app, claudectl, the process listening on :8837, Macro Recorder, Talk Mode, Voice to Text, Firefox, Tailscale, Connection Keeper, Hammerspoon, chatd.py.
Warning in the menu and `!` on the band after 10 min paused. The app starts from a SessionStart hook in ~/.claude/settings.json (`open -g -a`), quits 60 s after the last session ends (never while paused). Nothing starts at login.

CLI: `claudectl pause|resume|status` (~/.local/bin/claudectl runs the app's own binary, same logic). Tests: CLAUDECTL_TESTDIR=<dir> restricts matching to `claude` processes under that dir (use `exec -a <dir>/claude`) and keeps state/tools there.

Tools registry (MANTRA_MANIFEST modules/pause-all.md): array of {name, pause, resume, status}; an action is {cmd:[...]} or {method,url}; status has jsonField (boolean) or pausedWhen (stdout text).

Build: only GitHub Actions (.github/workflows/build.yml, release vN Latest). Install: gh release download, unzip to /Applications, codesign "Mantra Apps". Updater: app/Updater.swift asks at start. Macro Recorder has no SIGSTOP route; its pause API is its own.

## Menu-bar hover card and pipes (v3, 16.11.2026)
Marko: "with all my apps on the menu bar, make a comprehensive pop-up menu. When I hover over, I want to see what is it and what is it doing." and "for my apps always make a pipes before and after so I know where one app ends and other begins." `app/HoverCard.swift` is the shared kit file (MANTRA_MANIFEST kits/menubar-hover, rule modules/menubar-hover.md): hovering the item about 0.4 s shows a card with name, what it is, state and live lines; a thin grey pipe stands before and after the visible title. The app supplies its lines in the `HoverCard.attach(...)` closure. Test without a mouse: launch with `--hovercard-shot`. Change the lines in the app; change the module only in the kit.
