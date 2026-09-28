## Summary

Describe the behavior or documentation change and why it is needed.

## Validation

- [ ] `git diff --check`
- [ ] Relevant Host tests pass, if Host behavior changed.
- [ ] Relevant iOS build/tests pass, if iOS behavior changed.
- [ ] No credentials, session data, signing material, private filesystem paths, or unrelated personal information are included.

## Compatibility / safety

- [ ] The official ChatGPT application is not patched, re-signed, or modified.
- [ ] The canonical single-writer/runtime ownership model is preserved.
- [ ] Real-account mutation testing, if any, used an explicitly authorized test target.
- [ ] Any new local-only state or signing material is excluded from Git.
