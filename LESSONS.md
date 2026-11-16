# LESSONS

- 16.11.2026: never SIGSTOP the app that owns an input lock (Macro Recorder): pause it through its API.
- The session that runs `claudectl pause` is itself under a Claude root: the CLI excludes its own pid and anything with "claudectl" in its command line.
- Nothing can be compiled on the Mac: test the CLI on a dummy tree from the release build.

## Lesson: hover card and pipes (16.11.2026)
Poll the mouse (macOS draws a status item once per display, only one copy owns the button, so a tracking area misses the other display). The panel needs `titleVisibility = .hidden` for the one-title guard. A non-activating NSPanel at statusBar+1 never takes focus. Pipes for text items: attributed title; for icon items: pipedIcon + rightPipe; for view items: drawPipes or PipesView.

## Lesson: say which thing (16.11.2026)
A bare "RUNNING 1" says nothing when several things can be paused. Every word names its subject (CLAUDE, QUEEN, MACRO); show only what differs. Verify the item with `screencapture -x -D 2` (display 2 = MacBook here) cropped to the right half of the top strip.
