# Plura Mobile

Independent native mobile client plus an authenticated cross-platform desktop host for continuing ChatGPT conversations and Work/Codex-style agent sessions across multiple Desktop profiles. The primary product use case is a person who actively uses more than one ChatGPT profile/account and wants one mobile surface for those profiles; a one-target installation remains a fully supported degenerate case of the same architecture.

**Plura** is the shared product family/brand and **Plura Mobile** is this product. **Plura Desktop** is the separate upstream multi-profile runtime project that owns canonical Desktop/app-server profile lifecycle. ChatGPT and Codex are upstream integrations, not Plura's brand identity. Both Plura projects remain independently usable and are not affiliated with or endorsed by OpenAI.

The public repository may keep a descriptive `ChatGPT-Plura...` slug for discoverability, while the installed mobile product and user-facing UI use **Plura Mobile**. The desktop bridge component remains **Plura Host**. Public bundle/service identifiers use the repository-owned `io.github.LJY0317.PluraMobile` namespace; Apple signing-team selection is intentionally local and is not checked into the repository.

## Product principles

Plura treats the following as first-class design constraints rather than cleanup work:

- **OpenAI-change resilience** — UI text, model names, tool names, CSS classes, DOM paths, and incidental protocol fields are not product contracts. Prefer semantic data attributes, stable roles/relationships, capability discovery, versioned adapters, tolerant decoding, and `unknown` fallbacks. Exact English labels and observed DOM shapes are last-resort compatibility strategies isolated inside the Desktop adapter, never spread through the mobile UI.
- **Simple installation** — a new user should be able to install prerequisites, the Plura host, pair a device, and launch a profile from public documentation without reconstructing private paths or runtime state. Installed runtimes must not depend on the Git checkout after installation.
- **Complete removability** — Plura-owned launch agents, runtime copies, caches, pairing credentials, diagnostics, and state must have a documented removal path. Plura never removes the official ChatGPT application or another project's profile data as part of its own uninstall.
- **Mainstream-first within Plura Mobile's scope** — the product's primary path is the common workflow of its intended audience: one native remote surface across multiple ChatGPT Desktop profiles and their Chat + Work/Codex state. Rare diagnostic/special environments stay behind adapters rather than shaping the main flow.
- **Cardinality-agnostic core** — host/mobile contracts treat targets generically as `1..N`; a single target remains fully supported without a parallel implementation, while profile switching appears only when it is meaningful.
- **Canonical ownership** — Plura Desktop owns each managed Desktop/app-server lifecycle; Plura Mobile's Chat/Work layers attach through the versioned target/session contract and never create a hidden second writer.
- **Native presentation, portable semantics** — Chat/Work data contracts are platform-neutral; iOS and future Android clients render them with native platform UI rather than sharing a WebView.
- **Local-first presentation, remote-authoritative writes** — cached content appears immediately; live Mac state determines freshness and all writes.
- **Cross-platform host boundary** — Plura Host core, target/session contracts, pairing, cache semantics, and private-network transport are desktop-OS neutral. Desktop Chat mirroring uses Plura Desktop's canonical loopback renderer contract and has no OS UI-automation fallback. Windows/Linux support is implemented only to the level actually verified and never guessed from macOS behavior.

See `docs/ARCHITECTURE.md` for the adapter/timeline strategy and `docs/INSTALLATION.md` for install/update/removal guarantees.

The current mobile UI is the iOS/iPadOS implementation: SwiftUI navigation, UIKit transcript virtualization, native Markdown/code/image/display-math rendering, foreground-only networking, and iOS Keychain pairing. The host/target protocol is platform-neutral so an Android client can use the same contract without learning desktop profile paths or process details.

## Requirements

- Python 3 on the desktop host.
- **Plura Desktop** as the canonical target-runtime provider for profile discovery and Desktop/app-server lifecycle ownership. Public onboarding may guide users through installing or configuring Plura Desktop when they add accounts, but the two projects remain independently owned and usable; Plura Mobile does not duplicate the Desktop profile/runtime lifecycle.
- The official ChatGPT Desktop application for the host OS.
- Xcode for the current iOS client.

**Plura Host is not a Mac-only product boundary.** Its common core is designed for macOS, Windows, and Linux. macOS is the real-app verified implementation today; Windows/Linux credential/network/runtime adapters are structurally implemented and CI-covered where possible, but still require real official-ChatGPT-Desktop end-to-end verification before those platforms are described as fully supported.

For cloud Chat mirroring, Plura requests Plura Desktop's canonical renderer capability whenever it launches a target; the current versioned Desktop contract publishes a loopback-only renderer-CDP endpoint. Chat-mirror readiness is independent from app-server readiness: an already-running canonical session can be `ready` for Work while still requiring one normal quit/relaunch before semantic Chat mirroring is available. Plura Mobile exposes that condition as generic `chatMirrorState` rather than making renderer CDP a permanent mobile product contract. Rendererless sessions fail closed instead of falling back to OS UI automation. A confirmed **Relaunch** action can ask Plura Desktop to perform that normal quit/relaunch for the exact selected profile; it is never done silently. This renderer contract is implemented by Plura Desktop on its supported platform adapters, while real official-Desktop Chat-mirror behavior is currently verified end-to-end on macOS only.

## Install Plura Host on macOS

```sh
Tools/install-macos-host.sh
```

For development without installation you can still run:

```sh
python3 Tools/chatgpt-plura-host.py
```

The installer copies a self-contained host runtime into the existing Plura application-support location and registers the per-user LaunchAgent. It does not depend on the Git checkout after installation. The host is an idle event-driven socket server rather than a polling daemon. Re-run the installer after host source updates.

To preview/removal guidance, see `docs/INSTALLATION.md`. The compatibility uninstaller keeps state by default:

```sh
Tools/uninstall-macos-host.sh
```

To remove all Plura-owned Mac host state and pairing credentials as well as the runtime:

```sh
Tools/uninstall-macos-host.sh --purge
```

This never removes `/Applications/ChatGPT.app`, Plura Desktop's managed profiles, or another project's state.

The host prints every connection path it can safely discover. Pair the iOS app once; later runs reuse the saved host credential and endpoint hints. The iOS Keychain stores the capability token, last successful host URL, target ID, and private-overlay endpoints, so reconnects can fail over between LAN and overlay paths without falling back to a stale hard-coded address. To deliberately show or rotate the host pairing credential, use the one-shot commands below. They do not start another Host server, so they are safe to run while the installed LaunchAgent already owns port 8765:

```sh
python3 Tools/chatgpt-plura-host.py --show-pairing
python3 Tools/chatgpt-plura-host.py --reset-pairing --show-pairing
```

Foreground reconnects use a low-power fast path. If the last target was already `ready`, Plura Mobile races the saved LAN/private-overlay endpoint hints with a staggered authenticated `/ping`, then reconnects directly to the cached opaque target route. The normal path therefore does **not** run Desktop target discovery or re-enumerate Tailscale/other overlay endpoints every time the user returns from another app. Full `/targets` discovery remains a fail-closed fallback when the cached route is stale, the target is no longer ready, or the trusted host path cannot be reused. No background polling loop or sleep-prevention assertion is used.

Targets currently come from the Plura Desktop `targets --json` adapter behind Plura Mobile's generic target-runtime boundary. Multiple targets are the primary product experience: the official/default target and every managed target appear dynamically rather than being compiled into the app. With one discovered target the same code path selects it automatically and can reduce redundant switching chrome. Managed-profile launches are canonicalized by Plura Desktop itself: selector app, menu bar, CLI, and future controllers all converge on one lifecycle-bound Desktop/app-server runtime. Plura Mobile only attaches through the runtime contract; it does not own a second supervisor and never creates a fallback writer.

The mobile client exposes every dynamic Plura Desktop target rather than hard-coding Profile 1/Profile 2. The `Chat` surface uses a separate, authenticated read-only catalog exposed by Plura Host from the official Desktop's already-synchronized local conversation catalog. This preserves Desktop Project names/pin order and keeps `exec`/agent canaries out of the Chat list without guessing from Codex source kinds. `Work`/`Codex` continue to use the canonical app-server `thread/list` contract with all currently advertised source kinds.

Cloud ChatGPT conversations can therefore be listed and grouped on iOS even when they are not local Codex rollout threads. Those cloud-only rows open as a **Desktop mirror** through Plura Desktop's canonical renderer capability. Newly activated canonical targets request the loopback-only renderer endpoint and read the semantic DOM already rendered by the official Desktop; an older running session that lacks that launch-time capability reports `restart-required` and fails closed until one normal quit/relaunch. Renderer-capable sessions also have an experimental guarded follow-up path: the host re-verifies the requested conversation, refuses to overwrite an existing Desktop draft/attachment selection, inserts through the official composer, confirms the newly rendered user turn, and deduplicates confirmed requests. Photos or Files selected on iOS are first uploaded to a bounded process-local host staging area, then referenced by opaque IDs; the renderer hands the staged desktop paths to the official Desktop's own file input, so Plura does not create a second browser/WebView upload stack. The mobile client enters the conversation immediately and loads/refreshes the mirror in place rather than blocking the conversation list behind an `Opening…` overlay. Local app-server-backed Chat rows continue to open through the normal app-server contract. Plura does not copy browser cookies, authentication tokens, or private ChatGPT request credentials to hydrate or write cloud conversations.

If a managed target is still running from the older private launch path, the contract reports `restart-required`. Quit it normally once and launch it again through any supported managed launch surface; no separate "shared mode" is required afterward.

## Build the iOS client

```sh
xcodebuild \
  -project "ChatGPT Plura — A multi-profile client.xcodeproj" \
  -scheme "ChatGPT Plura — A multi-profile client" \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Or open `ChatGPT Plura — A multi-profile client.xcodeproj` in Xcode and choose a simulator or signed physical device. For a physical device, select your own Apple Development team in Xcode; no developer-team identifier is committed. The built/installed product name and public display name are **Plura Mobile**.

`project.yml` is the canonical XcodeGen source. XcodeGen is needed only when regenerating the checked-in Xcode project after project-structure changes.

## Runtime behavior

- The target-runtime provider owns target launch/session lifecycle. The host only discovers, requests launch, and attaches to canonical sessions; the current implementation uses the Plura Desktop adapter.
- Mobile presentation is **local-first while connectivity remains remote-authoritative**. The app keeps a bounded on-device snapshot of the last known target list, Chat catalog/Projects, Work thread list, and currently open conversation. A foreground/cold launch can therefore render useful saved state immediately while host reachability and freshness are re-established in the background. Saved content is read-only until the selected Mac target is live again; credentials remain in Keychain and are never copied into the presentation snapshot.
- Connection state and content state are intentionally independent. A reconnecting/offline badge must not blank an already-renderable conversation/list. The full-screen `Mac unavailable` state is reserved for first-use/no-cache cases rather than normal foreground resume.
- Host endpoint discovery uses a bounded Happy-Eyeballs-style race across the last successful route and saved private-network routes instead of waiting for each LAN/Tailscale candidate to time out serially. The first authenticated `/targets` response wins and the remaining probes are cancelled; this keeps network transport replaceable without coupling product state to a single VPN address.
- Codex JSON-RPC is handled by `CodexAppServerClient`; WebSocket lifecycle is isolated in `RemoteWebSocketTransport`.
- Backgrounding preserves the current conversation UI and keeps the socket when iOS allows it. If iOS suspends/aborts the WebSocket, returning to the app reconnects automatically without discarding the visible conversation/list state.
- The Chat list comes from the Desktop-synchronized read-only catalog and preserves active ChatGPT Project grouping/pin order. Work/Codex history still requests every current app-server source kind and pages turns with `thread/turns/list`.
- Cloud-only ChatGPT rows open as a Desktop mirror only when the selected canonical session exposes Plura Desktop's renderer capability; rendererless sessions fail closed and can request an explicit normal relaunch when the contract reports `restart-required`. The mobile composer can send guarded text follow-ups and can stage up to four Photos/Files attachments (25 MiB each) through the official Desktop file input. Staged files are target-scoped, bounded to 100 MiB total/32 entries, removed immediately after a confirmed submit, and otherwise expire after 15 minutes or when the host exits. If a transport failure makes submission ambiguous, Plura requires a successful transcript refresh before allowing retry rather than blindly resending. The mirror reports whether Desktop currently exposes a response-stop control and whether older messages are still loading. The current Desktop exposes multiple media/file inputs, so Plura selects the unique generic file input by semantic `accept` behavior and refuses ambiguous future layouts instead of guessing. Current Desktop builds move accepted files out of the hidden `FileList` into renderer-owned composer attachment state, so Plura recognizes the semantic `data-composer-attachments` / `data-visible-attachments` state while retaining the older `FileList` check as a compatibility fallback. Guarded text and `.txt` attachment sends have been verified end-to-end against a dedicated disposable Chat, including idempotent request replay and transcript confirmation.
- Plura Mobile keeps a bounded per-target cache of up to 32 recently opened cloud conversations. Revisiting one renders the saved transcript immediately and revalidates it in place; foregrounding an already-connected app refreshes the active mirror automatically. A never-opened cloud conversation still depends on the official Desktop rendering it once, so the UI enters the conversation immediately and shows non-blocking freshness progress instead of pretending that first hydration is instantaneous.
- New and existing threads use the installed app-server contract and streamed `turn/start` notifications.
- New threads inherit the selected Plura Desktop/Codex runtime's approval/sandbox defaults instead of forcing `approvalPolicy=never`. Current command, file-change, and additional-permission server requests are surfaced on iOS as explicit Allow/Deny prompts, including network/filesystem requests needed by remote agent work.
- Server-driven `currentTime/read` is answered locally, and `item/tool/requestUserInput` questions are rendered as native iOS forms with option, free-text, and secret-text answers. Standard MCP `mcpServer/elicitation/request` forms are also rendered natively with typed string, number/integer, boolean, single-select, and multi-select values plus required/default/range constraints. URL, device-verification, and OpenAI-proprietary elicitation modes remain explicitly declined rather than guessed.
- Observable Work/Codex activity (commands, file changes, MCP/dynamic tools, collaboration tools, web searches, status/duration, and user-visible reasoning summaries) is normalized into semantic timeline items. Raw/internal reasoning contents are intentionally never surfaced. Unknown future protocol item kinds are retained as bounded generic activity instead of leaking arbitrary payload fields or disappearing silently.
- Semantic activity stays structured all the way into native presentation instead of being preformatted into one Markdown status line. Plura Mobile renders generic activity cards from stable semantic kinds plus title/status/duration/detail metadata; individual model names, MCP server names, and tool names are not presentation switches. This lets new upstream tools degrade to a safe generic Activity card without requiring product-wide hard-coded updates.
- Chat message presentation preserves semantic Markdown reconstructed by the Desktop adapter instead of treating every turn as plain text. On iOS, headings/lists/quotes remain native attributed text; fenced code becomes a separate selectable, syntax-highlighted card with language metadata and Copy action; Markdown tables become horizontally/vertically scrollable native table blocks; and images/display math remain ordered peer blocks. The mobile renderer is block-oriented so a future explicit rich-content contract can replace the current conservative Markdown projection without replacing the conversation screen.
- Diagnostics are structured, bounded, and omit capability tokens and full message bodies.

## Private-network transports

Plura's application protocol is transport-independent. Pairing advertises multiple reachable endpoints and the iOS client tries the last successful path first, then saved alternatives.

- **LAN** — discovered hardware-LAN address for same-network use.
- **Tailscale / Headscale-compatible Tailscale clients** — the host automatically prefers MagicDNS and also advertises Tailscale IPs when the CLI is available. Headscale is a control-plane alternative for the same Tailscale client rather than a separate Plura transport.
- **ZeroTier** — active managed addresses are detected from `zerotier-cli` when installed.
- **NetBird** — the standard `wt0` overlay address is detected on macOS, Linux, and Windows when present.
- **Raw WireGuard or another private overlay** — add a stable endpoint explicitly with repeatable `--advertise-endpoint ws://PRIVATE-HOST:8765`. A custom `wss://...` endpoint is also accepted when a trusted private transport terminates TLS, but its confidentiality/trust model is that transport's responsibility rather than Plura's.

For example:

```sh
python3 Tools/chatgpt-plura-host.py \
  --advertise-endpoint ws://plura-mac.internal:8765
```

The desktop host must be awake, the Plura Host process must be running, and the selected target runtime must be available for live conversation/Work/Codex execution. Overlay products solve reachability; they do not execute work while the host computer is asleep.

For Tailscale, install and sign in on both the Mac and iPhone, join the same tailnet, keep the tunnel connected, and let Plura learn the Mac's MagicDNS/IP endpoints after one successful connection. ZeroTier and NetBird follow the same model: both devices join the same private overlay and Plura talks to the normal host bridge through the assigned private address. No router port-forward is required for these overlay paths.

## Security and limitations

- The bridge is for a trusted LAN or authenticated encrypted private overlay. Prefer device-to-device overlays whose relay path remains end-to-end encrypted (for example Tailscale/Headscale-compatible clients or NetBird). Never port-forward the current plain `ws://` listener to the public Internet.
- iOS ATS is intentionally relaxed so `ws://` can travel inside an already-encrypted private overlay. `RemoteEndpointPolicy` still rejects manually entered plaintext public Internet hosts: local/private IPv4, Tailscale CGNAT, IPv6 ULA/link-local, `.local`, `.home.arpa`, and `.ts.net` are allowed directly, while additional overlay hostnames are accepted only after an authenticated paired host has advertised and persisted that endpoint. Untrusted public hosts must use `wss://`.
- Because ATS is relaxed only to support the private bridge transport, other app networking remains deliberately constrained: remote Markdown images are loaded only over `https://`, and all host HTTP/WebSocket requests pass through `RemoteEndpointPolicy` before `URLSession` is used.
- The host exposes only opaque target routes; it does not expose `CODEX_HOME`, desktop user-data paths, fixed backend ports, or credentials in its target discovery contract.
- The Chat catalog endpoint returns only conversation ID/title/time/source plus Project ID/name/pin metadata and whether the row is locally openable. The host opens the Desktop catalog SQLite database read-only and never returns/logs unrelated global-state contents, browser cookies, resume tokens, or authentication credentials.
- The Desktop-mirror endpoints are capability-authenticated behind the same opaque target route. Reading and guarded writing both use Plura Desktop's canonical loopback renderer contract and fail closed when that capability is unavailable; Plura Host does not fall back to OS Accessibility/UI automation. Attachment bytes are accepted only through the authenticated target route into process-local temporary storage, are size/count/TTL bounded, and never become pairing state or repository data. The host does not call private ChatGPT backend APIs, copy ChatGPT credentials, or persist mirrored message bodies.
- Desktop mirroring is best-effort and depends on the official Desktop renderer's semantic structure. The loopback renderer/session boundary is platform-neutral in Plura Desktop, but real Chat-mirror behavior is currently verified end-to-end only on macOS; Windows/Linux must be validated on the official app before being described as equivalent. Mirroring can change the visible Desktop chat selection when selecting another conversation and can return a partial history while Desktop is still loading older messages. A future stable semantic Desktop/app-server follower contract can replace this projection without changing Work/Codex writer ownership.
- One logical managed target has one authoritative Plura Desktop runtime. Recovery does not create a hidden second writer.
- Plura Mobile can optionally post a privacy-safe native completion notification when a live Work/Codex `turn/completed` event arrives after the app enters the background. Permission is requested only when the user enables the setting, notification text does not include conversation/task contents, and no background polling loop is added. Delivery while iOS has fully suspended the app still requires a future push-capable transport.
- The Android client is not yet implemented. The shared host/target protocol is the intended cross-mobile boundary; Android behavior remains unverified rather than inferred from iOS.

## Roadmap: discovery and off-LAN access

- Remove manual LAN-IP management with stable host identity and local discovery (for example Bonjour/mDNS) while keeping the existing authenticated target contract.
- Secure off-LAN connectivity now has a vendor-neutral endpoint layer with Tailscale/Headscale-compatible clients, ZeroTier, NetBird, and explicit private-overlay endpoints. Tailscale failover has been verified end-to-end on a physical iPhone (LAN failure → Tailscale target discovery → WebSocket 101 → initialize → models/threads). Remaining provider-specific work is packaging/onboarding and equivalent real-device validation for the other overlays rather than coupling the app protocol to one VPN vendor.
- If a self-contained product path is needed later, add a rendezvous/relay/NAT-traversal layer with end-to-end authenticated encryption. Plura Desktop remains local runtime authority; relay/discovery transport belongs to Plura rather than the upstream profile project.

## Checks

```sh
python3 -m unittest discover -s Tools/tests -v
python3 -m compileall -q Tools/chatgpt_plura_host Tools/chatgpt-plura-host.py Tools/tests
```

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and test expectations. Security-sensitive findings should be reported through the process in [SECURITY.md](SECURITY.md), not in a public issue.

The iOS CI job also selects an available iPhone simulator dynamically and runs `ChatGPTPluraTests`; local simulator names and OS versions are intentionally not hard-coded in the project documentation.

Physical-device behavior is recorded separately from simulator/CI checks.
