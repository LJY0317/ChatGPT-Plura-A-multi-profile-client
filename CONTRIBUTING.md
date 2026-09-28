# Contributing

Thanks for contributing to Plura Mobile and Plura Host.

## Before making changes

- Keep the official ChatGPT app unmodified.
- Preserve the single-writer ownership model: Plura attaches to the canonical runtime instead of starting a hidden competing writer/app-server.
- Prefer stable semantic identifiers and capability probes over model names, localized labels, incidental CSS classes, or undocumented layout details.
- Keep secrets, signing material, local state, screenshots, caches, and developer-specific configuration out of Git.
- Do not add real account/session data to tests or fixtures.

## Local checks

Run the Host tests and Python compile checks:

```sh
python3 -m unittest discover -s Tools/tests -v
python3 -m compileall -q Tools/chatgpt_plura_host Tools/chatgpt-plura-host.py Tools/tests
```

For iOS, build and run the unit tests with Xcode or `xcodebuild`. Simulator builds do not require a checked-in signing team. Physical-device builds should select the contributor's own Apple Development team locally; do not commit a `DEVELOPMENT_TEAM` value.

## Pull requests

- Keep changes focused and explain behavior changes and compatibility implications.
- Add or update tests for changed behavior where practical.
- Avoid unrelated formatting churn.
- Run `git diff --check` before submitting.
- Never include credentials or private user data in screenshots, logs, fixtures, or commit messages.

## Real-account mutation testing

Some paths can change real user data, including Chat sends, attachment uploads, and approvals. Do not use another person's account or an existing personal conversation for mutation testing without explicit authorization. Prefer read-only validation unless a dedicated test target has been chosen.

## Security reports

For security-sensitive findings, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
