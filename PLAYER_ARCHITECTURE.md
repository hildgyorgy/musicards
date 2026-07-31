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
- The native app should remember user-approved music folders and restore
  access across launches using the appropriate persistent permissions/security
  bookmarks.
- The index should be durable and incrementally refreshed rather than rebuilt
  from scratch whenever the app starts.
- Folder access remains user-controlled. MusiCards must not silently scan the
  entire computer.
- File identity and MusicBrainz identity must remain distinct:
  - local files are the playable assets;
  - MusicBrainz releases and tracks provide the canonical viewer context;
  - matching connects the two without destructively rewriting either.

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
5. Add persistent user-approved folders and durable incremental indexing.
6. Match local files to the release/track currently shown by MusiCards.
7. Implement macOS output discovery, system-output routing and USB DAC routing.
8. Verify sample-rate switching and document the exact bit-perfect conditions.
9. Add iOS USB-C DAC behavior within native iOS routing constraints.
10. Polish the player UI only after the engine and lifecycle behavior are
    reliable.

## Implementation status — 2026-08-01

- Steps 1 and 2 are implemented. The macOS slice of step 3 has passed its first
  real listening test; the matching iOS slice is implemented and awaiting its
  first on-device test.
- `PlaybackTrack` keeps MusicBrainz-facing metadata separate from the local
  `PlaybackSource`.
- `PlaybackController` owns the shared queue and transport state.
- `PlaybackEngine` is the common platform-engine boundary.
- `PendingPlaybackEngine` is intentionally silent until native audio loading
  is implemented on a platform; it cannot accidentally pretend that playback
  succeeded. It remains available as the safe fallback implementation.
- `MacSystemPlaybackEngine` can decode one explicitly selected mono or stereo
  audio file and play it through the current macOS system output.
- `IOSSystemPlaybackEngine` uses `AVAudioSession` for native iOS route and
  sample-rate negotiation, then feeds prepared PCM to a RemoteIO Audio Unit.
  It shares the decoder, renderer and `PlaybackController` with macOS.
- The selected file is currently decoded into a single in-memory interleaved
  Float32 PCM buffer. This deliberately simple “memory play” implementation is
  suitable for validating the first signal path; it will later be replaced by
  bounded decoder/feeder buffering for large files.
- The realtime Audio Unit callback lives in `MCPPCMRenderer.c`. It performs no
  allocation, locking, file I/O, decoding, DSP or sample-rate conversion; it
  only copies prepared PCM into the output buffer and advances atomic state.
- The current default-output Audio Unit path is the `MAC AUDIO` path. It tries
  to match the output device's nominal sample rate to the source, but it is not
  the future direct-DAC path and must not yet be described as guaranteed
  bit-perfect.
- The first iOS slice intentionally does not yet handle audio interruptions,
  route changes, background playback or expose the negotiated hardware format.
  Those lifecycle behaviors must be added and tested before the iOS engine is
  considered production-ready.
- The existing iOS Apple Music now-playing observer remains a separate viewer
  feature and is not part of the MusiCards playback engine.

## Next task

The immediate validation task is deliberately narrow:

> Test one explicitly selected local lossless file on a physical iPhone,
> initially through its normal output and then through a connected USB-C DAC.
> Verify play, pause, resume, stop and natural completion. Do not add folder
> indexing, file-to-MusicBrainz matching, DAC selection or final player UI in
> the same step.
