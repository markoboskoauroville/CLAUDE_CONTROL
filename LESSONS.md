# LESSONS

- 16.11.2026: never SIGSTOP the app that owns an input lock (Macro Recorder): pause it through its API.
- The session that runs `claudectl pause` is itself under a Claude root: the CLI excludes its own pid and anything with "claudectl" in its command line.
- Nothing can be compiled on the Mac: test the CLI on a dummy tree from the release build.
