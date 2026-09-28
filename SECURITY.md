# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability, credential exposure, authentication bypass, pairing-token weakness, or any report that contains private account/device information.

Use GitHub's private vulnerability reporting for this repository instead. Include the affected version/commit, platform, reproduction steps, expected behavior, and any relevant logs with secrets redacted.

For ordinary non-sensitive bugs, a normal GitHub issue is appropriate.

## Sensitive data

Plura is designed so that pairing credentials stay in platform credential storage and are not committed to the repository. Do not include real ChatGPT session data, cookies, access tokens, pairing tokens, Apple signing material, provisioning profiles, private keys, or personal filesystem paths in issues, pull requests, fixtures, or logs.

## Scope

Security-sensitive areas include:

- Plura Host pairing and capability-token handling.
- Network endpoint validation and private-network transport policy.
- Desktop target/session attachment boundaries.
- Keychain/credential storage on Apple platforms.
- File/attachment staging and cleanup.
- Guarded write actions such as Chat sends and approvals.

The official ChatGPT application is an external dependency and must not be patched, re-signed, or modified by Plura.
