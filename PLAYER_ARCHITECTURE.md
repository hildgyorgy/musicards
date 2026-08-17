# MusiCards Player — Product and Architecture Decisions

This document preserves the decisions made before implementation of the
MusiCards audio player. It is the shared starting point for future player work.

## Product identity

- MusiCards remains a MusicBrainz release viewer first.
- Playback is a quiet, natural extension of the viewer, not a separate
  “full-featured player” identity.
- The intended experience is deliberately restrained: the player should be
  simple at first sight, then pleasantly surprising in its playback quality.
- MusiCards is the bridge between the listener, local audio files, MusicBrainz
  metadata and playback. It should manage that flow instead of creating a
  competing metadata universe.
- MusicBrainz remains the primary semantic metadata source despite its
  occasional imperfections, because its data is collaboratively maintained.

## Interface decisions

- `PLAYER` is a permanent fifth content section.
- On macOS it is the fifth accordion element.
- On iOS it is the fifth card in the card-deck metaphor.
- The existing platform metaphors must remain intact:
  - macOS: Liquid Glass/Frosted Glass accordion;
  - iOS: stacked cards with direct selection and animated expansion/collapse.
- The Player section should itself be expandable, just like every other
  section. Playback controls should not become a visually dominant,
  permanently floating player chrome.
- The current placeholder Player section is only a structural milestone. Its
  visual design should follow the existing MusiCards language.

## Shared versus platform-specific code

- Playback state, queue semantics, file-to-release/track matching and the
  domain model should be shared between macOS and iOS wherever practical.
- Platform presentation remains separate: accordion on macOS, card deck on
  iOS.
- Audio-device integration may require platform-specific implementations
  behind a shared playback-facing abstraction.
- Build the shared state and engine boundaries before polishing either
  platform’s controls.

## Playback-quality goal

- Local, lossless playback is the priority.
- The macOS path should use native Core Audio facilities and aim for
  unmodified/bit-perfect output where the selected hardware and format allow
  it.
- “Bit-perfect” must be described honestly: it depends on output routing,
  hardware capabilities, sample-rate handling, volume/DSP state and whether
  the device can be configured exclusively enough to avoid conversion.
- Avoid unnecessary DSP, resampling, normalization or format conversion.
- Playback quality and routing state should eventually be inspectable without
  turning the interface into an audio-engineering dashboard.

## Audio-output model

- Normal mode follows the current macOS system output. This can include the
  built-in speakers, display/HDMI and AirPlay.
- A second, explicit route should allow direct use of an attached USB DAC,
  such as a Chord Mojo 2.
- The UI concept is intentionally simple: system/Core Audio output versus the
  selected USB DAC. Exact wording and fallback behavior are still to be
  designed.
- Device discovery must be dynamic. A known DAC should be recognized when it
  appears, and disconnection must fall back safely without losing playback
  state.
- AirPlay belongs to the normal system-output path; it must not be advertised
  as bit-perfect.
- iOS should support compatible USB-C DACs through the native iOS audio path,
  while respecting iOS routing and lifecycle constraints.

## Local-library and indexing decisions

- The web player’s temporary browser indexing model is not sufficient for a
  permanently installed native app.
- The native app remembers one user-selected music root and restores access
  across launches using the appropriate persistent permission/security
  bookmark. **Connect Music Folder** reads the root's `library.json`; selecting
  the same root reloads it, while selecting a different root replaces the former
  index.
- One web-compatible manifest format is shared by every platform:
  - Windows and command-line users generate it with the dependency-free
    `Tools/generate_library.py` utility;
  - MusiCards for Mac can generate or incrementally update it natively after a
    user selects an offline music folder;
  - iOS never generates it and only connects to an existing manifest.
- Both native platforms import the manifest into the same durable SwiftData
  lookup. The macOS generator writes the same relative paths and MusicBrainz
  identifiers as the Python tool, then connects the generated index
  automatically.
- The macOS generator and Python utility both report how many audio folders
  were omitted because a MusicBrainz Release MBID was missing. Omission remains
  intentional, but is no longer silent.
- iOS never walks the connected folder or downloads the collection to build an
  index. Remote audio content is accessed only when its track is played.
- Folder access remains user-controlled. MusiCards must not silently scan the
  entire computer.
- File identity and MusicBrainz identity must remain distinct:
  - local files are the playable assets;
  - MusicBrainz releases and tracks provide the canonical viewer context;
  - matching connects the two without destructively rewriting either.
- Search results expose local availability by exact release MBID. Once such a
  release is loaded, its MusicBrainz tracks match local files first by release
  track MBID (Picard's `MUSICBRAINZ_RELEASETRACKID`). This distinguishes repeated
  appearances of the same recording inside one release. Older or incomplete
  indexes fall back deterministically to recording MBID
  (`MUSICBRAINZ_TRACKID`).

## Metadata behavior

- MusicBrainz release and track structure remains authoritative in the viewer.
- Local embedded tags are useful for locating and matching files, but should
  not replace richer MusicBrainz credits and relationships.
- A successful match should make playback feel like a capability of the
  currently viewed release rather than navigation into a separate library app.
- Existing credit grouping rules remain valid, including treating an explicit
  MusicBrainz `performer` role as a performer/musician credit rather than a
  technical credit.

## Explicit non-goals for the first implementation

- No attempt to reproduce a large library manager such as Tonal.
- No metadata-editing universe of our own.
- No visually dominant “audiophile” control panel.
- No EQ, effects, normalization, crossfeed or other DSP in the first engine.
- No promise of bit-perfect playback for AirPlay or every system-output route.
- No simultaneous construction of indexing, matching, queue UI, DAC handling
  and final visual polish.

## Incremental implementation order

1. Finish and commit the cross-platform fifth Player card/accordion milestone.
2. Define the shared playback state, queue model and engine protocol.
3. Play one explicitly selected local file reliably, first on macOS and then
   on iOS behind the same engine boundary.
4. Add basic transport state and connect it to the Player section.
5. Add a persistent user-selected music root and import the shared
   `library.json` into a durable lookup.
6. Match local files to the release/track currently shown by MusiCards.
7. Implement macOS output discovery, system-output routing and USB DAC routing.
8. Verify sample-rate switching and document the exact bit-perfect conditions.
9. Add iOS USB-C DAC behavior within native iOS routing constraints.
10. Polish the player UI only after the engine and lifecycle behavior are
    reliable.

## Implementation status — 2026-08-02

- Steps 1 and 2 are implemented. The macOS slice of step 3 has passed its first
  real listening test; the matching iOS slice is implemented and awaiting its
  first on-device test.
- `PlaybackTrack` keeps MusicBrainz-facing metadata separate from the local
  `PlaybackSource`.
- `PlaybackController` owns the shared queue and transport state.
- Queue replacement and audio preparation use monotonically increasing request
  generations. A superseded async artwork/decode result cannot replace a newer
  selection, configure a stale Audio Unit or publish stale playback state.
  In-app and system Play commands remain unavailable while preparation is in
  progress.
- `PlaybackEngine` is the common platform-engine boundary.
- `PendingPlaybackEngine` is intentionally silent until native audio loading
  is implemented on a platform; it cannot accidentally pretend that playback
  succeeded. It remains available as the safe fallback implementation.
- `MacSystemPlaybackEngine` can decode one explicitly selected mono or stereo
  audio file and play it through the current macOS system output.
- `IOSSystemPlaybackEngine` uses `AVAudioSession` for native iOS route and
  sample-rate negotiation, then feeds prepared PCM to a RemoteIO Audio Unit.
  It shares the decoder, renderer and `PlaybackController` with macOS.
- Local files are decoded incrementally into a bounded, approximately
  eight-second interleaved Float32 ring buffer. File duration therefore no
  longer determines playback memory use; this remains bounded for long and
  high-sample-rate ALAC, FLAC and AAC files.
- A serial feeder owns the Core Audio decoder and keeps file I/O and decoding
  away from the realtime thread. Seeking stops the output, seeks the decoder,
  resets and primes the ring buffer, then resumes only if playback was active.
- The ring buffer is the source-neutral boundary for future playback sources.
  A later Navidrome or Dropbox adapter may add network download, retry and
  caching behavior while feeding the same renderer with decoded PCM.
- The realtime Audio Unit callback lives in `MCPPCMRenderer.c`. It performs no
  allocation, locking, file I/O, decoding, DSP or sample-rate conversion; it
  only copies prepared PCM into the output buffer and advances atomic state.
- The current default-output Audio Unit path is the `MAC AUDIO` path. It tries
  to match the output device's nominal sample rate to the source, but it is not
  the future direct-DAC path and must not yet be described as guaranteed
  bit-perfect.
- The iOS engine observes audio-session interruptions and relevant route
  changes. It preserves position across a temporary interruption and resumes
  only if playback was active beforehand and iOS explicitly permits it.
- Disconnecting a DAC or headphones pauses playback instead of allowing an
  unexpected switch to the iPhone speaker. Connecting a new route rebuilds the
  RemoteIO output and resumes it only when playback was already active.
- Interruption and route-change behavior has passed its first physical-device
  validation. Exposure of the negotiated hardware format remains deferred.
- The app declares the iOS Audio background mode in its source Info.plist. A
  dedicated `PlatformNowPlayingCoordinator` publishes the local MusiCards
  track, elapsed time,
  duration and playback rate to `MPNowPlayingInfoCenter` without coupling
  MediaPlayer APIs to the realtime engine. Local listening is explicitly
  excluded from system content and journaling suggestions.
- Control Center and lock-screen play, pause, toggle, stop and position-change
  commands are forwarded to the shared `PlaybackController`. Unsupported
  queue, skip, rating and playback-rate commands remain disabled.
- macOS uses the same Now Playing coordinator and additionally publishes the
  explicit system playback state required by MediaPlayer on macOS.
- Background playback, system controls and embedded Now Playing artwork have
  passed physical-device validation on both platforms.
- A persistent SwiftData local-library index is now connected on both
  platforms. User-selected roots are retained as security-scoped bookmarks;
  the app stores file fingerprints, MusicBrainz identities, display metadata
  and technical audio properties rather than copying audio content.
- Refresh is incremental: every supported path is enumerated, but unchanged
  files are recognized by relative path, size and modification date. Only new
  or changed ALAC/FLAC/AAC files have their metadata read again, and missing
  paths are removed from the index.
- MusicBrainz search rows show a small play indicator for locally indexed
  release MBIDs. The Tracks card shows a play control only where the selected
  release and recording MBIDs resolve to a local file; starting one builds a
  queue from every locally available track of that release.
- For explicitly selected files, Now Playing artwork uses embedded audio-file
  cover metadata when available. MusicBrainz/Cover Art Archive fallback remains
  deferred until local files are matched to MusiCards releases.
- The existing iOS Apple Music now-playing observer remains a separate viewer
  feature and is not part of the MusiCards playback engine.

## Next task

The next implementation phase is deliberately a stabilization phase, not a
feature phase:

1. keep the current app behavior covered by repeatable regression tests;
2. migrate incrementally to Swift 6 language mode;
3. only after that consider the separately scoped direct-DAC playback path.

## Regression safety net — 2026-08-13

The `MusiCardsTests` macOS-hosted unit-test target protects shared, platform-
independent behavior without opening audio devices or requiring a real music
folder.

- Manifest tests cover the current `library.json` schema, legacy safe defaults
  and rejection of paths that escape the connected root.
- Local-library matching tests cover exact release-track MBID priority, the
  hybrid SACD/CD-layer case, partial albums, unique legacy recording-MBID
  fallback, ambiguity rejection and exact normalized artist matching.
- Playback-controller tests use a fake engine to cover queue replacement,
  previous/next boundaries, prepare/play/pause behavior, automatic advance,
  end-of-queue output restoration and seek clamping.
- MusicBrainz query tests preserve the intended artist/release search shape and
  verify Lucene escaping for punctuation and embedded quotes.

Run the suite from Xcode with the `MusiCards` scheme, or from the repository
root with:

```sh
xcodebuild -project "MusiCards Release Viewer.xcodeproj" \
  -scheme MusiCards -destination "platform=macOS" test
```

## Remote library foundation — 2026-08-17

- The first remote-library adapter is intentionally Navidrome-only at the
  product level. Its transport follows the current OpenSubsonic protocol so
  the implementation stays clean without promising compatibility with old,
  unmaintained Subsonic servers.
- Connection verification uses HTTPS, POST requests and salted token
  authentication. Raw passwords are never placed in URLs or persisted in a
  server profile; legacy plaintext authentication and TLS bypasses are not
  supported.
- Passwords are stored separately in the system Keychain. A persisted server
  profile contains only its display name, base URL and username.
- A connection is accepted only when `ping` succeeds and the server identifies
  itself as both OpenSubsonic-compatible and Navidrome. This gives later
  streaming work a small, explicit compatibility boundary.
- This phase adds no remote playback or new connection UI. The playback engine
  remains source-neutral so a later Navidrome source can feed the same queue,
  metadata and renderer used by local files.
