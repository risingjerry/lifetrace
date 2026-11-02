# Security policy

lifetrace records sensitive local data (window titles, URLs, on-screen text, shell
commands, agent prompts). Bugs that leak that data are security bugs, for example:

- a secret that survives redaction (`[REDACTED]` rules in `Sources/LifetraceCore/Activity.swift`
  and `lifetrace_sources/core.py`);
- text read from a password field, an excluded app or a private browser window;
- data written outside the data directory, or with permissions wider than 0700/0600;
- any network access.

Please report them privately through GitHub's **Report a vulnerability** button on the
Security tab of this repository, not in a public issue. Include the version
(`lifetrace --version`), macOS version and a minimal synthetic reproduction — never
your real activity log. Expect a first reply within a week.

Supported: the latest release on `main`.
