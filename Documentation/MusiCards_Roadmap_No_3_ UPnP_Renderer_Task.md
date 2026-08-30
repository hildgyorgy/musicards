# MusiCards — Navidrome → UPnP/DLNA Renderer Casting

**Task brief for implementation.** This document is a complete architectural
analysis and implementation plan, written after reading the actual MusiCards
codebase (not a generic UPnP tutorial). It is meant to be handed to a coding
agent working directly in the repository. Every file path below is real and
exists in the project as of this writing.

## 0. Required reading before writing any code

Read these first, in this order:

1. `PLAYER_ARCHITECTURE.md` — product and architecture decisions for the
   player. Pay special attention to the "Spotify Connect-szerű viselkedés"
   requirement (closing/backgrounding the app must not interrupt playback on
   an external renderer) and the "Remote library foundation" section
   (Navidrome auth model).
2. `Documentation/Experiments/MusiCards_Navidrome_AVM_handoff.md` — a written
   record of manual network experiments against a real AVM Audio CS 2.3
   renderer and a real Navidrome server. It already **proves**, on real
   hardware:
   - The Navidrome raw stream (`format=raw&maxBitRate=0`) is directly
     playable by the AVM without any transcoding — the AVM fetches the file
     straight from Navidrome, the Mac/iPhone never touches the bytes.
   - Navidrome supports HTTP Range requests (`206 Partial Content`), which
     is what makes renderer-side seeking work.
   - Standard UPnP `AVTransport` discovery, `SetAVTransportURI`, `Play`,
     `Seek` all work against the AVM.
   - `SetNextAVTransportURI` works: the AVM autonomously switches from track
     N to track N+1 without any further command from the control point.
   - A vendor-specific `QPlay` queue extension was tried and abandoned — do
     **not** revisit it. Standard `AVTransport` + a moving two-item window
     (`CurrentURI` / `NextURI`) is the only supported approach.
3. `Tools/UPnP/navidrome_avm_setnext_probe.command` — the Python
   proof-of-concept script referenced above. It is a working, if informal,
   reference implementation of: SSDP discovery (with a known-URL fast path),
   AVTransport SOAP calls, DIDL-Lite metadata construction, and the
   `SetAVTransportURI` + `SetNextAVTransportURI` + `Seek` sequence. Treat its
   logic as validated ground truth for the SOAP/XML shapes, not as
   production code to reuse verbatim (it is untyped Python with interactive
   `input()` prompts).
4. Swift files listed throughout this document — read each one in full
   before touching it.

## 1. Goal

Add a fourth playback source/output combination to MusiCards: **Navidrome
library on the local network → an external UPnP/DLNA `MediaRenderer`
device**, with MusiCards acting purely as the UPnP *Control Point* (never as
the audio data path). Concretely:

- User picks a track/release backed by the Navidrome source, and picks an
  external renderer as the output (instead of the Mac/iPhone's own audio
  output).
- Seeking works (scrubbing the position slider issues a UPnP `Seek`).
- Closing or backgrounding the app does **not** interrupt playback — the
  renderer keeps playing because it is fetching the audio directly from
  Navidrome. Reopening the app must resynchronize its UI to the renderer's
  actual state immediately (no stale "paused at 0:00" flash).
- Bit-perfect: MusiCards must never decode, re-encode, resample or proxy the
  audio. The bytes must flow Navidrome → renderer only.
- Gapless track transitions, including for classical works split across
  many short movements.

**Explicit non-goal for v1:** casting local files (USB/SSD) to a UPnP
renderer. Only the Navidrome source is in scope, because only Navidrome can
serve the audio to the renderer directly over HTTP; a local file would
require MusiCards itself to act as an HTTP server, which conflicts with the
"app can close without interrupting playback" requirement (see §3.2).

## 2. Why the existing architecture is a good fit

MusiCards already has a clean seam for exactly this kind of extension:

- `Playback/PlaybackEngine.swift` defines a `@MainActor` `PlaybackEngine`
  protocol: `prepare(_:)`, `play()`, `pause()`, `stop()`, `seek(to:)`,
  `eventHandler`, `canSeek`. `MacSystemPlaybackEngine`,
  `IOSSystemPlaybackEngine`, and `PendingPlaybackEngine` already implement
  it side by side.
- `Playback/PlaybackController.swift` owns the queue, generation-based race
  protection, and all transport logic, and talks **only** to this protocol.
  It has real unit test coverage (`MusiCardsTests/PlaybackControllerTests.swift`)
  using a fake engine.
- `Playback/PlaybackEngineFactory.swift` and `App/MusiCardsAppModel.swift`
  (`init`) are the only two places that construct and inject a concrete
  engine into `PlaybackController`.

**Conclusion: implement the new capability entirely as one or more new
`PlaybackEngine` conformances plus new supporting services. Do not modify
`PlaybackController.swift`'s transport logic.** This keeps the best-tested,
most safety-critical file in the codebase untouched, and mirrors the
existing pattern (`PendingPlaybackEngine` sitting next to the real engines).

## 3. Key design decisions

These are the non-obvious calls that determine whether this feature actually
works well or subtly breaks. Each includes the reasoning; do not silently
pick a different option without understanding the trade-off described.

### 3.1 Output switching: a composite/router `PlaybackEngine`, not a protocol change

`PlaybackController` is constructed once with a single, fixed `engine: PlaybackEngine`
(see `MusiCardsAppModel.init`). To let the user switch between "play on this
device" and "play on renderer X" — including mid-session — introduce:

```swift
@MainActor
final class OutputRoutingPlaybackEngine: PlaybackEngine {
    enum Route: Equatable {
        case systemOutput
        case upnpRenderer(UPnPRendererDescriptor)
    }

    @Published private(set) var currentRoute: Route = .systemOutput

    private let systemEngine: PlaybackEngine   // Mac/iOS engine, unchanged
    private let upnpEngine: UPnPPlaybackEngine // new, see §4

    var eventHandler: ((PlaybackEngineEvent) -> Void)? {
        didSet { /* forward to whichever inner engine is active */ }
    }

    // prepare/play/pause/stop/seek: forward to the active inner engine.

    func switchRoute(to route: Route, resumingFrom item: PlaybackQueueItem?, position: TimeInterval) async {
        // capture position on the old engine, stop it, activate the new
        // engine, prepare(item) + seek(position) + (if it was playing) play()
    }
}
```

This is constructed once in `MusiCardsAppModel.init` and passed to
`PlaybackController` exactly where `PlaybackEngineFactory.makeDefault()` is
used today. `PlaybackController` never learns that routing exists — from its
point of view it always talks to one `PlaybackEngine`. Route switching,
including the handoff of playback position, is entirely internal to this
wrapper. Expose `currentRoute` (and a list of discovered renderers) to the
UI via a small `ObservableObject` wrapper or by having
`OutputRoutingPlaybackEngine` itself be `ObservableObject`.

### 3.2 The stream URL / credential problem — and why direct handoff is correct

This is the most important trade-off in the whole feature.

`RemoteLibrary/OpenSubsonicRequestBuilder.swift` builds **POST** requests
with the Subsonic salted token in the request body. `RemoteLibrary/NavidromeRemoteAudioByteSourceProvider.swift`
explicitly documents the intent: *"the playback engine receives only a
byte-source factory, never credentials or an authenticated request URL."*
This is good local-decode design, but it is fundamentally incompatible with
UPnP: `AVTransport.SetAVTransportURI` requires a plain HTTP **GET** URI that
the *renderer* fetches on its own. There is no way to hand a renderer a
POST-with-body request.

Two ways to resolve this:

| | A. Hand the renderer a direct, classic Subsonic GET stream URL (query-string auth: `u`/`t`/`s`/`v`/`c`/`id`/`format=raw`, exactly like the probe script) | B. Run an HTTP proxy/relay inside MusiCards that re-serves already-authenticated bytes to the renderer over a local, unauthenticated URL |
|---|---|---|
| Audio path | Navidrome → renderer, zero-hop, guaranteed bit-perfect | Navidrome → MusiCards → renderer (re-served, not re-encoded, but MusiCards is in the data path) |
| App can close without interrupting playback | **Yes** | **No** — the proxy dies with the app/background suspension |
| Credentials | Visible to the renderer / on the LAN (salted token, not the raw password) | Hidden from the renderer |

**Decision: implement option A.** The "app can close and playback
continues" requirement is explicit, written product policy
(`PLAYER_ARCHITECTURE.md`, the experiment doc's "Spotify Connect-szerű
viselkedés" section), and is only achievable if MusiCards is never in the
audio data path. Exposing a salted, time-bounded Subsonic token to a
renderer on the trusted local network is the same trade-off every existing
Navidrome/Subsonic UPnP-casting client makes (Symfonium, Feishin, etc.) —
it is standard practice for this protocol family, not a shortcut.

**Implementation implication:** add one new, narrowly-scoped, explicitly
documented method for this single purpose — do not reuse or widen the
existing `RemoteAudioByteSourceProviding` abstraction. Suggested shape,
alongside the existing `OpenSubsonicRequestBuilder`:

```swift
extension OpenSubsonicRequestBuilder {
    /// Builds a GET-able, salted-token-authenticated stream URL intended
    /// ONLY to be handed to a UPnP/DLNA renderer on the trusted local
    /// network as the AVTransport CurrentURI/NextURI. Never log, persist,
    /// or transmit this URL off the local network — unlike every other
    /// request this builder makes, the credential travels in the URL
    /// itself, by necessity of the UPnP protocol.
    func castableStreamURL(
        profile: NavidromeServerProfile,
        password: String,
        salt: String,
        songID: String
    ) -> URL { ... }
}
```

This lives in the Navidrome/RemoteLibrary layer (it needs
`NavidromeCatalogCredentials`, obtained the same way
`NavidromeRemoteAudioByteSourceProvider` obtains them via
`NavidromeCatalogConnectionProviding.catalogCredentials()`), and is called
only from the UPnP engine when it needs to prepare a queue item whose
source resolves to a Navidrome asset.

### 3.3 Gapless: the real risk is in *this* codebase, not in UPnP itself

`SetNextAVTransportURI` is proven to work end to end (§0.2). The risk is
**not** whether the AVM can gap-lessly transition — it can. The risk is that
`PlaybackController`'s existing queue-advance logic will fight it.

Look at `PlaybackController.selectItem(at:autoplay:)` (used by both
`selectNext` and `selectPrevious`, and invoked by the `.finished` handler in
`handle(_:)`):

```swift
await engine.stop()
...
if autoplay { await play() }   // → engine.prepare(item) then engine.play()
```

**Every** track advance — including the automatic one that fires when a
track finishes — calls `engine.stop()` then `engine.prepare()` then
`engine.play()`. If the UPnP engine translated these 1:1 into SOAP calls
(`Stop`, `SetAVTransportURI`, `Play`), it would **audibly interrupt** a
transition the renderer is already handling gaplessly on its own — the
opposite of the goal. Research into real-world UPnP control points (e.g.
BubbleUPnP) confirms this is a known failure mode: renderers must stay in
`TransportState=PLAYING` through a gapless transition, and repeatedly
calling `GetMediaInfo` on some renderers resets their stored `NextURI` back
to `NOT_IMPLEMENTED`, breaking gapless. **Do not poll `GetMediaInfo` in the
playback loop** — it was fine as a one-shot sanity check in the probe
script, but must not run repeatedly in production. Use `GetPositionInfo.TrackURI`
instead (see below).

**Required design: `UPnPPlaybackEngine.stop()` must never send an
immediate SOAP `Stop`.**

The naive fix — "remember that the next `prepare()` corresponds to a track
already playing" — only covers the mid-session auto-advance case. §3.9
below shows that the *ordinary*, already-existing "start playing this
queue" call path (`PlaybackController.replaceQueue(...)`, used by every
"user tapped a track" flow, and also the one cold-start rehydration must
reuse) calls `engine.stop()` unconditionally too, with no prior "I just
detected an autonomous transition" signal to hang a flag on. The general
mechanism that covers **both** cases:

- `stop()` never calls the SOAP `Stop` action synchronously. It starts a
  short, cancelable deferred timer (roughly 200–300ms) and returns
  immediately.
- Independently, the engine tracks the renderer's actual state via
  `GetPositionInfo.TrackURI` / `TransportState` (polling and/or GENA — see
  §3.5). It does **not** rely on `GetMediaInfo` for this: research into
  real-world UPnP control points (e.g. BubbleUPnP) confirms this is a known
  failure mode — repeatedly calling `GetMediaInfo` resets some renderers'
  stored `NextURI` back to `NOT_IMPLEMENTED`, breaking gapless.
- Whenever `prepare(item)` is called (from *any* caller, for *any* reason)
  and the engine finds that `item`'s resolved URI already matches what the
  renderer reports as its current (or, for the autonomous-advance case,
  previously-staged-next) `TrackURI` while `TransportState` is
  `PLAYING`/`PAUSED_PLAYBACK`: it cancels any pending deferred `Stop`,
  sends **no** `SetAVTransportURI`, and resolves `prepare()` immediately by
  adopting the renderer's reported state. `play()` is likewise a no-op if
  the renderer already reports `PLAYING`. As part of servicing that
  `prepare(item)` call, it computes the *next* queue item (§3.4) and issues
  `SetNextAVTransportURI` for it, sliding the two-item window forward.
- If no matching `prepare(item)` arrives before the deferred timer elapses
  — a genuine full stop (queue cleared, no follow-up track) — the real SOAP
  `Stop` fires.
- A genuine user-initiated jump (a different track, previous, a new
  release) does not match anything the engine already knows about, so it
  takes the normal path: the deferred `Stop` is allowed to fire (or is
  fired immediately, since we already know this is a real transition), then
  a real `SetAVTransportURI` (+ a fresh `SetNextAVTransportURI`) + real
  `Play` follow.

This debounced-and-idempotent shape is deliberately *more general* than
"remember the auto-advance": it requires no advance signal, so it equally
protects the mid-session gapless transition (§3.3) and the cold-start
rehydration path (§3.9) with one mechanism, and it is the reason §3.9 can
reuse `PlaybackController`'s ordinary queue-start API instead of needing
any new method on `PlaybackController`.

This is the single most important piece of engineering in this feature.
Write unit tests specifically for this state machine (fake SOAP transport,
scripted `GetPositionInfo` responses, and a controllable clock for the
debounce timer) before wiring it to a real renderer.

### 3.4 Queue lookahead for the UPnP engine

`PlaybackEngine.prepare(_:)` only ever receives the *current* item — the
protocol has no concept of "next." The UPnP engine needs to know the next
queue item to be able to pre-stage `SetNextAVTransportURI`. Do this via a
small injected closure rather than changing the protocol:

```swift
final class UPnPPlaybackEngine: PlaybackEngine {
    init(
        renderer: UPnPRendererDescriptor,
        streamURLResolver: @escaping (PlaybackQueueItem) throws -> URL,
        nextItemProvider: @escaping () -> PlaybackQueueItem?
    ) { ... }
}
```

`nextItemProvider` reads from the live `PlaybackController` (`queue`,
`currentIndex`, `hasNext`). Because of the construction order in
`MusiCardsAppModel.init` (engine must exist before `PlaybackController`,
which the engine's closure needs to reference), wire this with a weak,
settable reference set immediately after both objects are constructed —
this is a normal composition-root pattern, not a redesign.

### 3.5 Discovery (SSDP)

- Use **unicast** `M-SEARCH` (send to the renderer's last-known IP, or to
  `239.255.255.250:1900` as a *send*, which does not require joining the
  multicast group) and listen for the unicast `HTTP/1.1 200 OK` reply on an
  ephemeral local port. This is exactly what the probe script already does,
  and it works on iOS **without** requesting Apple's special multicast
  networking entitlement, because that entitlement only gates *joining* a
  multicast group to receive spontaneous `NOTIFY` announcements — not
  sending datagrams or receiving unicast replies to a request you sent.
- Passive `ssdp:alive`/`ssdp:byebye` listening (which does need the
  multicast entitlement) is out of scope for v1. Re-run active discovery on
  app foreground and when the user opens the renderer picker.
- Add `NSLocalNetworkUsageDescription` to both `MusiCards/MusiCards Release
  Viewer-Info.plist` and `MusiCards/MusiCards Release Viewer-iOS-Info.plist`
  — iOS 14+ silently drops local-subnet UDP/TCP traffic without this key
  and a granted permission prompt.
- Cache the last-known device description URL (as the probe script does)
  and try it first before falling back to a full SSDP round, matching the
  documented finding that SSDP occasionally doesn't answer on the first
  try.
- Parse the device description XML for the `AVTransport` service
  (`controlURL`), and additionally for `RenderingControl` (§3.7) and
  `ConnectionManager` (§3.6).

### 3.6 Format/compatibility validation

Before attempting to play a FLAC/ALAC/high-res track on a renderer, query
`ConnectionManager:GetProtocolInfo` (`Sink` field) once per discovered
renderer and check whether the item's MIME type is declared as supported.
If not, fail fast with a clear, specific error (e.g. "This renderer does not
declare support for FLAC") instead of silently attempting playback and
producing a confusing runtime failure. This is what makes the feature feel
"profi" rather than experimental.

### 3.7 Volume (optional, recommended)

`RenderingControl` (`GetVolume`/`SetVolume`/`GetMute`) lets MusiCards read
and adjust the renderer's own volume. Not required for v1 functional
correctness, but worth adding once the transport path is solid — poll or
GENA-subscribe to keep it in sync if the renderer is also controlled from
its own remote/app.

### 3.8 State freshness on resume — start simple

Match what `PLAYER_ARCHITECTURE.md` already specifies:

1. On foreground: one-shot `GetTransportInfo` + `GetPositionInfo` +
   `GetMediaInfo`, resolve the URI back to a Navidrome song/queue item,
   update the UI immediately. No waiting, no animation of "catching up."
2. While foregrounded and playing: poll `GetPositionInfo` roughly every 1–2
   seconds for the position, interpolating locally between polls for a
   smooth scrubber (start time + known rate, corrected on each poll) so the
   UI doesn't feel like it's stepping.
3. **GENA event subscription (SUBSCRIBE + a local NOTIFY listener) is an
   optional v2 enhancement**, not required for v1 — polling alone, done
   this way, already satisfies "instant fresh state on reopen" because the
   one-shot query on resume is what actually matters, not sub-second
   push latency while already in the foreground. Only build GENA if 1–2s
   polling turns out to feel sluggish in practice.

### 3.9 Cold-start / relaunch queue rehydration — the UI already exists, the data doesn't

This was found by tracing what actually happens if the user force-quits
MusiCards (or the OS kills it) while the AVM keeps playing on its own, then
reopens the app cold.

**The good news — no new UI work needed.** `App/ContentView.swift` already
does the right thing generically, for any playback source:

```swift
showsCollapsedHeader: { card in
    card.id == .player && appModel.hasCurrentPlaybackItem
},
collapsedHeaderProvider: { card in
    collapsedHeaderContent(card)   // → CollapsedPlayerBar when card.id == .player
}
```

On iOS, `.player` is one of the cards peeked at the bottom of the "TO
EXPLORE" stack on the home screen (`DeckBackgroundView` is the `background:`
of that same `DeckView`) — it is the front-most peeked card, i.e. the most
prominent one. Whenever `appModel.hasCurrentPlaybackItem` is true, that
row already renders the full `CollapsedPlayerBar` (title, remaining time,
seek bar, prev/play/next) right there, with no further change. And
`hasCurrentPlaybackItem` is driven purely by
`playbackController.$currentIndex.map { $0 != nil }` — it does not care
which `activeLibrarySource` tab is selected, so it is already correct
regardless of whether the UI happens to be showing the Local or Navidrome
tab when the AVM turns out to be the thing that's playing.

**The actual gap: at cold launch, `PlaybackController.currentIndex` is
`nil`.** Everything in §3.8 assumes a queue item is already known and only
its position/status needs refreshing. On a fresh launch there is no queue
yet — nobody in this session has picked a track. If the AVM is playing
something, the engine must **reconstruct a full `PlaybackQueueItem` from
scratch**, purely from what the renderer reports, before any of the
existing UI wiring above has anything to display.

Concretely:

1. Query `GetTransportInfo` + `GetPositionInfo` (+ `GetMediaInfo` once) on
   the discovered/last-known renderer.
2. Extract the Navidrome song ID from the reported `TrackURI`'s query
   string (`id=...`) — **do not** round-trip through the DIDL-Lite
   `CurrentURIMetaData`; several renderers don't return it reliably, and
   MusiCards controls the URL format from §3.2 anyway, so the `id`
   parameter is always there and trivial to parse.
3. Fetch that song's metadata from Navidrome and build a
   `PlaybackAssetReference(source: .navidrome, ...)` /
   `PlaybackTrack` / `PlaybackQueueItem`, exactly the shape
   `ReleasePlaybackQueueBuilder` already produces for a normal "user tapped
   a track" flow. (Whether to reconstruct just the single track or the
   whole surrounding release/queue is a product-polish decision, not a
   correctness one — a single-item queue is a perfectly valid v1.)
4. Feed it into `PlaybackController` through its **existing, ordinary**
   queue-start API — `beginQueueRequest()` → `prepareForQueueReplacement(_:)`
   → `replaceQueue(with:startingAt:request:)` → `play()` → `seek(to:
   reportedPosition)` — the same sequence every existing "user tapped a
   track" call site already uses. **Do not add a new adoption method to
   `PlaybackController`** — this sequence already calls `engine.stop()`
   (twice, in fact: once inside `prepareForQueueReplacement`, once inside
   `replaceQueue`) before `play()` ever reaches `engine.prepare()`. That is
   only safe to do silently, without an audible interruption on the AVM,
   *because* `UPnPPlaybackEngine.stop()` is deferred/cancelable per the
   refined §3.3 design — `prepare()` for the just-reconstructed item will
   recognize the URI as already active on the renderer, cancel the pending
   `Stop`, and adopt state instead of re-issuing `SetAVTransportURI`.
5. `LibraryManager.resolvePlaybackAsset` already dispatches on
   `reference.source` (`LibraryAccess/LibraryManager.swift`), not on the
   globally active `libraryManager.source` / `activeLibrarySource` — so a
   reconstructed Navidrome reference resolves correctly through
   `NavidromeLibraryProvider` even if the Local tab happens to be the
   currently-selected one in the UI. No changes needed there either.

**Trigger point:** `ContentView.swift` already has

```swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active {
        appModel.refreshActiveLibraryIfNeeded()
    }
}
```

`scenePhase` reaches `.active` both on a cold launch and on returning from
the background, so this single existing hook is the right place to also
trigger the rehydration/resync check — add a sibling call (e.g.
`appModel.refreshPlaybackRouteIfNeeded()`) rather than inventing a new
lifecycle entry point. Only attempt rehydration when
`playbackController.currentIndex == nil` and a renderer route was
previously in use (or is newly discovered); if a queue item is already
known, this is the ordinary §3.8 resync instead, not a rebuild.

## 4. Proposed file layout

New files, under a new `Playback/UPnP/` group, mirroring the existing code
style (small, single-responsibility Swift files, `@MainActor` where the rest
of the playback layer is `@MainActor`, `nonisolated`/`Sendable` for pure
data types):

```
Playback/UPnP/
  SSDPDiscoveryService.swift        // unicast M-SEARCH, device description fetch
  UPnPRendererDescriptor.swift      // friendlyName, UDN, descriptionURL, controlURLs
  AVTransportClient.swift           // SOAP actions: SetAVTransportURI, SetNextAVTransportURI,
                                     // Play, Pause, Stop, Seek, GetTransportInfo,
                                     // GetPositionInfo, GetMediaInfo
  RenderingControlClient.swift      // GetVolume/SetVolume/GetMute (§3.7)
  ConnectionManagerClient.swift     // GetProtocolInfo (§3.6)
  DIDLLiteMetadataBuilder.swift     // builds <DIDL-Lite> XML from PlaybackTrack + URL
  UPnPPlaybackEngine.swift          // PlaybackEngine conformance, §3.3/§3.4 state machine
  OutputRoutingPlaybackEngine.swift // §3.1 composite engine
RemoteLibrary/
  OpenSubsonicRequestBuilder.swift  // + castableStreamURL(...) extension, §3.2
```

## 5. UI integration points

- `Playback/CollapsedPlayerBar.swift` — add a small route/output button
  (only visible/enabled when the active library source is Navidrome) that
  opens a renderer picker (list of `SSDPDiscoveryService` results +
  "This device"). Selecting an entry calls
  `OutputRoutingPlaybackEngine.switchRoute(to:...)`.
- `Playback/PlayerCardContentView.swift` — `fileAndOutputTitle(_:)`
  currently always calls `AudioOutputRouteInspector.current()` to build the
  "SOURCE → TRANSPORT → DEVICE" label. When `OutputRoutingPlaybackEngine.currentRoute`
  is `.upnpRenderer(descriptor)`, branch to build the label as
  `"NAVIDROME → LOCAL NETWORK → \(descriptor.friendlyName.uppercased())"`
  instead — the local Core Audio/AVAudioSession device is not meaningful in
  this state (system output is idle).

## 6. Testing strategy

Follow the existing test culture exactly (`MusiCardsTests/`,
`MusiCardsTests/Fixtures/`): inject an abstract SOAP/HTTP transport into
`AVTransportClient` and friends so unit tests run against canned XML
responses, no real network or hardware needed. Specifically prioritize:

- `UPnPPlaybackEngineTests`: the idempotency/gapless state machine from
  §3.3 — scripted sequences of `GetPositionInfo` responses simulating an
  autonomous track transition, asserting that no redundant `Stop`/`SetAVTransportURI`/`Play`
  is sent and that the two-item window slides forward correctly.
- `DIDLLiteMetadataBuilderTests`: XML escaping, duration formatting.
- `AVTransportClientTests`: SOAP envelope shape, SOAPACTION header,
  HTTP-error-to-`Error` mapping.
- `SSDPDiscoveryServiceTests`: parsing of description XML into
  `UPnPRendererDescriptor` (reuse the two known-good XML fixtures implied
  by the experiment doc).
- Reuse the existing `PlaybackControllerTests` fake-engine pattern to prove
  that `OutputRoutingPlaybackEngine` satisfies the `PlaybackEngine`
  contract identically regardless of active route.

## 7. Phased implementation order

1. `SSDPDiscoveryService` + `AVTransportClient` + `DIDLLiteMetadataBuilder`,
   each unit-tested against fixtures, no UI yet.
2. `OpenSubsonicRequestBuilder.castableStreamURL(...)`, documented per §3.2.
3. `UPnPPlaybackEngine` implementing the full state machine from §3.3/§3.4,
   including the deferred/cancelable `stop()`. Validate manually against
   the real AVM before moving on — specifically test the "app was
   force-quit, renderer kept playing, relaunch the app" scenario, since
   that is what exercises the deferred-stop path most aggressively (two
   `stop()` calls back to back from `replaceQueue`, see §3.9).
4. `OutputRoutingPlaybackEngine` + wiring into `MusiCardsAppModel.init`
   (replacing the direct `PlaybackEngineFactory.makeDefault()` injection
   into `PlaybackController` with the router), plus the cold-start
   rehydration call from §3.9 hung off `ContentView`'s existing
   `scenePhase == .active` handler.
5. UI: route picker in `CollapsedPlayerBar`, route label branch in
   `PlayerCardContentView`.
6. `ConnectionManagerClient` (§3.6) + graceful format-mismatch errors.
7. `RenderingControlClient` (§3.7) volume sync.
8. Optional: GENA event subscription (§3.8) if polling proves insufficient
   in practice.

## 8. Explicit non-goals for v1

- Casting local files to a UPnP renderer (see §1).
- Passive SSDP (`ssdp:alive`/`byebye`) listening / the multicast networking
  entitlement.
- GENA eventing (start with polling; see §3.8).
- DSD support (already explicitly out of scope per the experiment doc).
- The QPlay extension (already tried and explicitly abandoned).
- Any DSP, EQ, resampling, or normalization on the UPnP path — the entire
  point is bit-perfect passthrough.

## 9. Requirements traceability

| Original requirement | How this plan satisfies it |
|---|---|
| Seek | Real UPnP `Seek` action; renderer performs its own HTTP Range request against Navidrome (proven working, §0.2). |
| App close/reopen → instant fresh state | Audio path never runs through the app (§3.2 decision A), so closing never interrupts playback; one-shot `GetTransportInfo`/`GetPositionInfo`/`GetMediaInfo` on foreground gives an immediate, correct resync (§3.8) — and on a cold relaunch, where no queue item is known yet, §3.9 reconstructs one from the renderer's reported state and feeds it through the existing "start playing" path, so the already-existing `CollapsedPlayerBar`/home-screen wiring shows it with no UI changes. |
| Bit-perfect | Direct Navidrome→renderer HTTP transfer of `format=raw&maxBitRate=0`; MusiCards never decodes or re-encodes on this path (§3.2). |
| Gapless | `SetNextAVTransportURI` moving two-item window, proven on real hardware; the actual engineering risk (PlaybackController's stop/prepare/play triplet on track advance) is solved by the idempotent state machine in §3.3. |

## 10. Decisions already made — do not relitigate without new evidence

- Direct-URL handoff over an in-app proxy (§3.2): chosen for bit-perfectness
  and app-close resilience; the credential-visibility trade-off is accepted
  and standard for this protocol family.
- Composite/router engine over changing `PlaybackController`/`PlaybackEngine`
  (§3.1): chosen to avoid touching the most safety-critical, best-tested
  file in the codebase.
- Unicast SSDP over requesting the multicast entitlement (§3.5): chosen to
  avoid an Apple entitlement-request process that is unnecessary for active
  discovery.
- `GetPositionInfo.TrackURI` over `GetMediaInfo` for detecting autonomous
  track transitions (§3.3): chosen because of a documented renderer-side bug
  class (`NextURI` resetting to `NOT_IMPLEMENTED` after `GetMediaInfo`
  polling) seen in real-world UPnP control point implementations.
- Polling-first, GENA-optional (§3.8): chosen because a one-shot resync on
  foreground already satisfies the stated requirement; GENA adds
  implementation complexity (a local HTTP listener, subscription renewal)
  for a UX improvement that may not be perceptible.
- `UPnPPlaybackEngine.stop()` is deferred/cancelable, never an immediate
  SOAP `Stop` (§3.3, refined): chosen over a narrower "remember the
  detected auto-advance" flag because the identical problem — a `stop()`
  call immediately followed by a `prepare()` for a URI already active on
  the renderer — also occurs on the ordinary queue-start path used by cold
  rehydration (§3.9), which has no prior detection event to hang a flag on.
- Cold-start rehydration reuses `PlaybackController`'s existing
  `beginQueueRequest`/`prepareForQueueReplacement`/`replaceQueue`/`play`/`seek`
  sequence rather than adding a new "adopt external state" method (§3.9):
  preserves the "zero changes to `PlaybackController`" principle from §2,
  and is only safe to do silently because of the deferred-stop decision
  above.
