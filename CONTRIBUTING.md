# Contributing

Thanks for helping. Small, focused pull requests are easiest to review.

1. Read [AGENTS.md](AGENTS.md) — layout, build, test and the privacy rules apply to
   human contributors too.
2. `make test` (Swift + Python) must pass. Add a test for every bug fix.
3. Changing an event, field or query output? Update `Schema.swift` and `SCHEMA.md`
   (and `SOURCES.md` for readers) in the same PR.
4. New source readers: built-in readers must be stdlib-only, read-only and work on a
   stock Mac. Anything app- or machine-specific works better as an
   [extra reader](SOURCES.md#extra-readers-your-own-sources) in your own repo.
5. Never include real activity data, screenshots of your timeline, personal paths or
   account names in code, tests, issues or PRs. Use synthetic fixtures.

Bug reports: include `lifetrace --version`, macOS version, `lifetrace status --json`
with private fields removed, and steps to reproduce.
