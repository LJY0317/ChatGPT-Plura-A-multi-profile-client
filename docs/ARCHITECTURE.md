# Plura Mobile architecture

Plura Mobile is an independent native remote client that interoperates with the official ChatGPT Desktop application and the canonical Codex/app-server runtime owned by the separate **Plura Desktop** project.

## Design priorities

The project optimizes for these properties together:

1. OpenAI-change resilience.
2. Simple installation for a public repository user.
3. Complete removal of Plura-owned state.
4. One canonical Desktop/app-server writer per logical profile.
5. Native iOS/Android presentation with a platform-neutral semantic contract.
6. Local-first presentation without treating cached data as write-authoritative.
7. Bounded, event-driven background behavior.
8. Multi-profile-first product value over a cardinality-agnostic `1..N` target core.
9. Desktop-OS-neutral host/protocol boundaries, with platform adapters for behavior that truly differs.

These priorities mean that an implementation detail observed in one ChatGPT build is never promoted directly into a mobile product contract.

## Runtime ownership

```text
Official ChatGPT Desktop
        ^
        | canonical launch/session
TargetRuntime provider
  (current: Plura Desktop adapter)
        ^
        | versioned target/session contract
Plura Host
        ^
        | authenticated Plura protocol
Plura Mobile (native client)
```

The selected TargetRuntime provider owns target identity and the Desktop/app-server lifecycle. Plura Mobile never reconstructs profile directories, never launches a fallback app-server, and never copies ChatGPT browser/session credentials. The current provider is Plura Desktop; that implementation detail is intentionally isolated behind the runtime interface.

## Target cardinality policy

Plura Mobile is primarily differentiated by users who maintain multiple ChatGPT Desktop profiles and want one mobile surface across their Chat and Work/Codex state. A single target remains a fully supported degenerate case, not a separate implementation mode.

The runtime/host/mobile layers always use the same generic target collection and selected-target contract:

- one target: use the same generic target path and reduce redundant switching chrome where appropriate;
- multiple targets: preserve the user's last selection and make profile identity/switching a first-class part of the product UX;
- no duplicated `singleAccountMode`/`multiAccountMode` business logic;
- no hard-coded `Profile 2` branches in transport, Chat parsing, Work/Codex, cache, or write paths.

The host depends on a narrow `TargetRuntime` lifecycle interface rather than on Plura Desktop implementation details. `PluraDesktopClient` is the current adapter. Plura Desktop remains an independent upstream product/repository and the canonical multi-profile runtime; Plura Mobile must not duplicate its lifecycle implementation. Users who need additional Desktop accounts install/setup Plura Desktop, potentially through a guided Plura Mobile onboarding flow.

The semantic `role` reported by the versioned runtime contract (for example `default`) is authoritative. Plura Mobile does not infer product meaning from opaque target IDs.

## Chat vs Work

Work/Codex consumes the canonical app-server protocol and therefore receives structured thread/item events directly.

Cloud Chat conversations currently use the official Desktop as the source of truth:

1. Prefer the loopback renderer-CDP endpoint created at canonical Desktop launch.
2. Extract semantic conversation structure from the already-authenticated official renderer.
3. If the canonical renderer capability is not ready, fail closed and surface the target's renderer state rather than guessing through OS UI automation.
4. Never add a second WebView/browser profile merely to mirror Chat.

Chat-mirror capability is launch-time state and is separate from app-server readiness. The Plura Host contract exposes the generic `chatMirrorState`, derived directly from Plura Desktop's versioned renderer state. A target can therefore be usable for Work while `chatMirrorState=restart-required`. Plura Mobile never quits such a Desktop silently: it may offer an explicit, confirmed **Relaunch for Fast Chat** action, after which Plura Desktop performs one normal target quit and relaunches the same target with its best available Chat follower capability.

## OpenAI-change resilience

Adapter code follows this priority order:

1. Stable IDs and protocol fields.
2. Semantic `data-*` attributes exposed by the renderer.
3. ARIA roles/names and structural relationships.
4. Standard HTML semantics (`p`, headings, lists, `pre/code`, links, tables, blockquotes, media).
5. Bounded compatibility heuristics.
6. Exact UI strings only as isolated last-resort fallback.

Product code must not branch on specific model names or enumerate today's tool names to decide core behavior. Model lists and tool/activity kinds are capabilities/data from the upstream contract. Unknown future item kinds are retained as generic bounded activity rather than dropped.

When ChatGPT markup changes, the intended maintenance unit is a renderer extraction strategy or fixture, not the iOS/Android screen.

For Cloud Chat, non-message activity is emitted only from explicit semantic roots inside a conversation turn. The current adapter recognizes renderer-owned app/tool cards, appshot attachments, approval surfaces, and input-request surfaces when those roots are present; otherwise it keeps the legacy message projection. It does not infer reasoning, tool usage, or file changes from localized labels or incidental visible text when no stable semantic root is available.

## Semantic timeline

The mobile UI consumes semantic timeline items such as:

```text
message
reasoningSummary
toolCall
commandExecution
fileChange
webSearch
imageView
approval
attachment
notice
unknown
```

Raw hidden chain-of-thought is out of scope. Only reasoning/status information the upstream user interface or supported protocol exposes to the user belongs in the timeline.

Message content should preserve block semantics rather than flattening renderer DOM to one `innerText` string. The Desktop adapter should reconstruct/emit headings, paragraphs, lists, links, code/pre blocks, blockquotes, tables, images/attachments, and future unknown blocks through a backwards-compatible representation. Plain text remains the fail-safe fallback.

The current renderer compatibility adapter reconstructs conservative Markdown from standard/semantic HTML rather than ChatGPT CSS classes. The native iOS renderer then turns that projection into ordered native blocks: assistant content is full-width, user content remains a compact trailing bubble, fenced code becomes a selectable syntax-highlighted card with language metadata and Copy, tables become scrollable native grids, and headings/lists/quotes/images/display math keep their semantic presentation. Unknown containers recurse through standard descendants and ultimately fall back to bounded visible text, so an upstream markup change should lose decoration before it loses conversation content.

Non-message timeline items stay structured through presentation as well. `ChatMessage.Kind` selects a generic native activity-card family (reasoning summary, tool, command, file change, web search, attachment, approval, notice, or unknown), while `title`, `status`, `durationMilliseconds`, and bounded detail remain independent metadata. The UI does not branch on individual OpenAI model names, MCP server names, tool names, or provider-specific labels. Unknown future kinds degrade to a generic Activity card that preserves ordering and safe visible detail. User-visible reasoning summaries may appear in the Thinking card, but raw/internal reasoning content remains intentionally discarded.

The current compatibility bridge reconstructs conservative Markdown from semantic/standard renderer HTML and the iOS presentation layer immediately decomposes that projection into ordered native blocks. Text, fenced code, tables, images, and display math therefore retain their relative order; code is presented as a distinct selectable/copyable card and tables as native scrollable grids rather than being painted into the surrounding paragraph. This is intentionally a presentation boundary rather than a permanent wire-format commitment: when the Desktop adapter can emit explicit structured blocks reliably, those blocks can feed the same native components while legacy `text`/Markdown remains a fallback for older hosts and future markup surprises.

## Presentation cache and refresh

The mobile client uses stale-while-revalidate behavior:

- previously visited content appears immediately from a bounded protected snapshot;
- connection/freshness state is independent from visible content;
- opening a cached conversation starts a background refresh rather than blanking the screen;
- foregrounding an already-connected app refreshes the active mirrored Chat conversation automatically;
- a future event-driven renderer observer may deliver live updates, but persistent polling is not a prerequisite for usable UI.

Conversation caches are bounded per target and must be evicted by recency/size. Credentials, pending write transactions, and staged attachment IDs are never persisted as presentation cache.

## Reconnect fast path

Pairing identity and transport lifetime are separate concerns. The iOS Keychain keeps the long-lived Host capability credential, last successful Host URL, selected target ID, and private-network endpoint hints. A suspended or replaced WebSocket does not invalidate that pairing.

When the app needs to reconnect and the saved target was previously `ready`, it first uses a low-cost path:

1. race the last successful Host endpoint plus saved LAN/private-overlay endpoints with a small stagger;
2. authenticate an inexpensive `/ping` that does not refresh Desktop targets or enumerate overlay providers;
3. attach directly to the cached opaque target WebSocket route;
4. reuse the Host runtime's canonical session cache when it is still valid.

Only a stale/unready cached target, unreachable trusted endpoint set, or failed cached-route handshake falls back to full `/targets` discovery. That fallback is allowed to refresh the canonical Desktop target/session contract because it is recovery, not the normal foreground path. This design avoids both persistent background polling and repeated expensive Desktop discovery while preserving fail-closed recovery when the Mac/target really changed. A Host or Desktop restart can still make the first recovery slower while canonical session state is rebuilt; ordinary app switching should not repeatedly pay that cost.

Target states that require explicit user action are not treated as transient transport failures. In particular, a cached `restart-required` or `unsupported` target is surfaced immediately instead of paying for another Desktop discovery pass, and those states suppress automatic reconnect scheduling instead of entering an exponential retry loop. An explicit profile refresh can still force discovery when the operator changed Desktop state externally. When a target is `restart-required`, the native UI surfaces an explicit relaunch action with confirmation because a normal Desktop quit/relaunch can interrupt an unsent draft or in-progress response; after that explicit relaunch, Plura forces one fresh target discovery before attaching. If the relaunch request itself fails after changing Desktop state, the same user-initiated operation performs one bounded fresh discovery/connect attempt before surfacing failure so the client does not remain stuck on a stale pre-relaunch snapshot. This recovery is not periodic polling.

Explicit Chat relaunch failures are reported as bounded structured stages rather than raw subprocess output. The Host distinguishes `quit`, `refresh-after-quit`, and `launch`, emits only privacy-safe reason/cause codes plus the Plura Desktop control-runtime version when available, and Plura Mobile records those fields in its local diagnostics. This keeps diagnostics actionable without persistently logging Desktop stdout/stderr or conversation content on the Mac.

## Completion notifications

Completion notification policy is event-driven. The iOS client may schedule a generic local notification only when the user has explicitly enabled notifications, the app has entered the background, and the canonical Work/Codex stream delivers `turn/completed`. Transient inactive states such as system overlays do not qualify. The notification deliberately omits task, thread, and message contents so lock-screen delivery does not expand Plura's data exposure.

This local path does not keep a polling socket or background timer alive. It is therefore best-effort once iOS suspends the app. A future APNs/relay delivery implementation should feed the same semantic completion boundary rather than introduce a second writer or a persistent polling architecture.

## Native UI boundary

iOS uses SwiftUI/UIKit and Android should use native Android/Compose conventions. UI source code is not the cross-platform boundary. The shared boundary is:

- target/session state;
- semantic timeline items and message blocks;
- attachment capabilities;
- connection/freshness state;
- guarded write commands.

This allows each platform to provide native typography, code cards, attachment presentation, keyboard behavior, accessibility, and navigation while sharing semantics.

## Desktop host/platform boundary

Plura Host is a cross-platform companion component even though macOS is the only real official-Desktop environment fully exercised today. Common code owns authenticated transport, target routing, semantic contracts, attachment staging, private-network discovery, and bounded diagnostics. Platform adapters own credential storage, executable/process integration, and filesystem conventions.

Plura Desktop's versioned target/session contract is the only Desktop Chat follower boundary consumed by Plura Host. Its current implementation publishes a canonical loopback renderer-CDP endpoint on renderer-capable sessions across the Desktop platform adapters. Plura Host never substitutes OS Accessibility/UI automation when that capability is unavailable; it fails closed and surfaces the contract state instead. Windows/Linux real-app behavior must still be verified from observed official-Desktop evidence before those platforms are claimed as equivalent.

## Branding

**Plura** is the shared family brand and **Plura Mobile** is this product/installed mobile app. `Plura Host` is its cross-platform desktop companion component. The independent **Plura Desktop** project remains a separate desktop-runtime product/repository even when the two Plura projects are distributed or documented together. `ChatGPT` and `Codex` identify upstream integrations in descriptive text rather than becoming part of Plura Mobile's brand identity.

Legacy bundle IDs/service identifiers may remain stable when changing them would break updates. That compatibility is an implementation detail, not the public brand.
