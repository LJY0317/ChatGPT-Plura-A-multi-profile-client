# Installing and removing Plura Mobile

## Goals

Installation and removal are product requirements:

- a public-repository user should not need to reconstruct internal profile paths;
- the installed host must keep working after the Git checkout moves or is deleted;
- updating the host should be repeatable;
- removing Plura Mobile must remove Plura-Mobile-owned state without touching the official ChatGPT app or independently owned Plura Desktop data.

## macOS host

### Current source build

The current source/developer build uses the independent **Plura Desktop** control runtime as its `TargetRuntime` provider. This intentionally avoids duplicating canonical Desktop/app-server lifecycle logic inside Plura Mobile. The two products remain separate: Plura Desktop is usable without Plura Mobile, and Plura Mobile consumes only its versioned target/session contract.

Public onboarding may offer a guided Plura Desktop setup when a user chooses **Add another account**, but installation ownership must remain explicit. Plura Mobile must never silently absorb, delete, or rewrite an independently installed Plura Desktop profile/runtime.

Public packaging may make the integration easier to discover or install, but it must preserve ownership: existing Plura Desktop installations are adopted through the public versioned contract rather than copied or rewritten; Plura Mobile uninstall never removes independently owned Plura Desktop profiles/runtime; and no Plura Mobile code path creates a second profile supervisor or fallback writer. With one discovered target the same target contract still applies; multiple targets are the primary product use case, not a separate implementation mode.

If an already-running ChatGPT profile predates Plura Desktop's fast Chat launch capability, Plura Mobile can show **Relaunch for Fast Chat**. That action is explicit and target-scoped: after user confirmation, Plura Host asks Plura Desktop to perform a normal quit of the exact Desktop process and relaunch the same target through the canonical runtime. Install/update flows must never perform this relaunch automatically.

Prerequisites:

- Python 3;
- the official ChatGPT Desktop application;
- the companion Plura Desktop control runtime;
- optional private-network software such as Tailscale for off-LAN access.

Install/update the host:

```sh
Tools/install-macos-host.sh
```

The installer copies a self-contained runtime to Application Support and installs a per-user LaunchAgent. Re-running it replaces only the derived host runtime and preserves pairing/state.

After installation, show the current pairing token without stopping or duplicating the running Host:

```sh
python3 Tools/chatgpt-plura-host.py --show-pairing
```

This is a one-shot operator query: it prints the reachable endpoints and current token, then exits without binding the Host listen port. Use `--reset-pairing --show-pairing` only when you deliberately want to rotate the credential.

Remove the installed runtime but preserve host pairing/state:

```sh
Tools/uninstall-macos-host.sh
```

Remove all Plura-owned Mac host artifacts, including host state and the Plura bridge Keychain credential:

```sh
Tools/uninstall-macos-host.sh --purge
```

`--purge` does **not** remove:

- `/Applications/ChatGPT.app`;
- ChatGPT account/profile data;
- Plura Desktop-managed profiles or their manifests;
- Tailscale/ZeroTier/NetBird/WireGuard;
- the Git checkout itself.

Those components have independent ownership and uninstall procedures.

## iPhone/iPad

The installed app is branded **Plura Mobile** and uses the public `io.github.LJY0317.PluraMobile` bundle namespace. A source build for a physical device requires the developer to choose their own Apple Development team locally in Xcode; signing-team identifiers are not stored in the repository. `Forget Pairing` removes Plura Mobile's saved pairing credential and local presentation snapshot before uninstalling the app if the user wants an explicit in-app reset.

As with most iOS applications, deleting the app removes its sandbox; Keychain lifecycle is controlled by iOS and can outlive an app deletion. Plura therefore provides the explicit `Forget Pairing` path for users who want the credential removed before deleting the app.

## Fresh public-source installs

The public source tree intentionally does not embed private developer signing identities or pre-public credential namespaces. Switching from an older private/development build to this public identity may require reinstalling/re-pairing once. The public uninstaller owns only the identifiers and paths documented by the public source tree.

## Windows and Linux host packaging

The Plura Host common core already has Windows/Linux platform boundaries for credentials, paths, private-network discovery, and target-runtime integration, and CI exercises portable code where possible. Plura Desktop's current canonical target/session contract also carries the loopback renderer capability across its platform adapters. Production installer/service integration and the official ChatGPT Desktop launch/renderer behavior on Windows/Linux are not yet treated as proven; validate those environments on real machines while keeping the authenticated mobile protocol unchanged. Do not add OS UI-automation fallbacks or copy platform-specific path assumptions into the common core.
