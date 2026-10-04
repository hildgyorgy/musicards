# MusiCards — Codex handoff

> **Living handoff document for continuing the project on another computer.**
>
> Update this file after every material development session. Keep it focused on
> the current truth rather than accumulating a full changelog; Git remains the
> history. Never place passwords, tokens, private server addresses, signing
> material, personal paths, or other secrets in this tracked file.

## 1. Snapshot

- **Last updated:** 2026-10-04 (Europe/Budapest)
- **Repository:** `musicards`
- **Branch:** `main`
- **Last completed application checkpoint before this documentation update:**
  `c3d9c1c` — `Polish playback output, Shazam search, and Wikipedia links`.
- **Remote state at documentation review:** `main` matched `origin/main` after
  the user pushed `c3d9c1c`.
- **Working tree at documentation review:** clean.

The checkpoint above deliberately identifies the last completed application
change rather than claiming that this tracked document can contain the hash of
its own future commit. Git and the user's newest instructions remain the source
of truth.

Always begin a new session with:

```sh
git status --short --branch
git log -5 --oneline --decorate
```

If the snapshot above differs from Git, Git and the user's newest instructions
take precedence; update this document before handing the project off again.

### Next session: AVM at the Mac Studio

The user plans to continue on 2026-10-05 at the office, where the physical
AVM Audio CS 2.3 is available. On that computer, pull/fetch first, check Git
state, then read this file, `PLAYER_ARCHITECTURE.md`, the AVM experiment handoff,
and the UPnP task brief linked in §7. Explain the proposed next step and ask
before changing code; this is the user's explicit collaboration preference.

- **Agreed UI:** source and output selection belong on the home screen as a
  deliberate playback setup. The collapsed and expanded players only *display*
  the active output; they do not switch it. The home-screen `OUTPUT` pill is
  currently a status label, not an active selector. Do not make a misleading
  button before UPnP selection actually exists.
- **System routes already work:** a plugged-in Chord Mojo 2 is selected by iOS;
  on macOS the user can select it or AirPlay in Control Center. MusiCards shows
  the active route automatically. No separate in-app Mojo/AirPlay picker is
  needed for this stage. UPnP renderers such as the AVM are the future explicit
  output choice, discovered on the local network.
- **No production UPnP control exists yet.** The AVM experiment proved direct
  Navidrome → renderer streaming and `SetNextAVTransportURI`; it is not an app
  implementation. The next session should validate the AVM and current design
  assumptions before choosing the first small implementation slice.
- **Hardware checks still needed:** the new macOS Core Audio route observer
  builds and passes automated tests, but actual AVM discovery/casting and live
  output changes on the Mac Studio have not been verified in this session.
- **Security boundary:** never log or commit authenticated Navidrome stream
  URLs, passwords, salts, tokens, or new private LAN addresses.

## 2. Released products

### MusiCards

- **Public version:** 2.0
- **Build:** 8
- **Status:** approved by Apple and **Ready for Distribution** on both iOS and
  macOS as of 2026-08-29.
- **App Store:** <https://apps.apple.com/app/id6763909271>
- **Platforms:** iPhone, iPad, and macOS.
- **macOS architecture:** Apple silicon (`arm64`) only. Intel support was
  deliberately removed before the 2.0 release.
- **Deployment targets in the project:** iOS 26.0 and macOS 26.0 for the main
  app target.

### Submitted 2.1 and current development version

- **Version in the project:** 2.1 (build 10).
- **Distribution state reported by the user:** 2.1 has been sent to the App
  Store. Approval and public availability have **not** been confirmed. Do not
  assume the submitted binary contains every change in `c3d9c1c`; some final
  cleanup was committed after the user reported the submission.
- **Last confirmed public version:** 2.0 (build 8), pending confirmation of
  2.1 approval/release.

### MusiCards Sync

- **Version in the project:** 1.0 (build 2).
- **Platform:** macOS, Apple silicon only.
- It is a separate, purpose-built companion utility, not a general-purpose
  synchronization product.
- Its main function is one-way synchronization from the canonical music archive
  to playback copies such as an external SSD, Navidrome storage, or another
  selected folder.
- During synchronization it creates or refreshes `library.json` and copies the
  index to the destination with the music files.
- The main MusiCards macOS app can also create and refresh the same
  `library.json`; MusiCards Sync is not required merely to generate an index.

## 3. Current product model

MusiCards began as a visual MusicBrainz release browser. Version 2.0 retains the
four original cards and adds a fifth:

1. SEARCH
2. RELEASE
3. TRACKS
4. ARTIST & DISCOGRAPHY
5. PLAYER

The application now combines MusicBrainz exploration with playback from:

- an indexed personal/local library; and
- an optional user-owned Navidrome server.

### Deliberate MusicBrainz identity rule

Playback is intentionally release-MBID based. Only releases whose audio-file
tags contain a MusicBrainz Release ID (normally written by MusicBrainz Picard)
are exposed as playable. MusiCards must not guess release identity from folder
names, filenames, or fuzzy metadata.

A small blue play arrow indicates that the displayed MusicBrainz release has a
match in the active library and can be played.

This strict relationship is a product principle, not an accidental limitation:
MusiCards should remain strongly and transparently connected to MusicBrainz.

## 4. Version 2.0 — completed state

The following work is already implemented and should be treated as the stable
2.0 baseline:

- Local indexed-library playback and optional Navidrome playback.
- Background playback on iOS/iPadOS and system Now Playing / lock-screen
  controls.
- Shared queue/controller architecture with macOS and iOS system playback
  engines.
- Remote random-access audio path and FLAC support through pinned binary Swift
  packages.
- Player display of the actual audio format/codec (for example ALAC, FLAC, AAC)
  rather than merely the filename extension (for example M4A), plus bitrate,
  sample rate, bit depth, and channel layout where available.
- Library-first search integration and blue playable indicators.
- Recent content caching: the three recent artists and releases retain useful
  loaded content so reopening them feels immediate.
- Release-selection async race protection using task cancellation plus a
  selection generation check before publishing success or failure.
- Artist Wikipedia lookup prefers English but can fall back to another
  available language edition.
- Improved scroll clearance when Apple Music Now Playing content expands the
  Search card.
- iPad full-screen-only vertical deck padding (32 points); windowed iPad layout
  remains unchanged.
- Dark-mode card treatment: macOS keeps the restrained natural glass appearance;
  iOS uses a thin, uniform system-blue contour without a white highlight. Light
  mode remains restrained.
- Card contour and card corner radii are aligned.
- Intel macOS compatibility was removed intentionally.
- Privacy manifests, signing/capability review, bundled-rsync provenance, and
  third-party licence material were completed before release.

### Post-2.0 / 2.1 development

- MusicBrainz requests now silently retry at most five times after transient
  timeout, selected connectivity, HTTP 429, and HTTP 5xx failures. Backoff is
  0.5, 1.5, 3, 5, then 8 seconds; cancellation remains immediate,
  `Retry-After` is respected, and total scheduled retry delay is capped at 20
  seconds. Non-transient HTTP, request, and data failures are not retried. The
  HTTP executor and retry sleeper are injectable so the complete retry chain is
  covered by deterministic tests.
- Track Details still loads recording and work/creator metadata for every genre.
  Recording-level performer, technical, and note data is now published before
  work enrichment, so a failed work request cannot erase already loaded data.
  Failed work enrichment remains explicitly retryable and retries only the work
  request. The UI shows loading and retry state instead of silently falling back
  to `n/a` after a request failure. On the creators/work page, `n/a` appears only
  after a successful, complete lookup establishes that the data is genuinely
  absent; pending and failed work lookups show loading or retry UI instead.
- The album-wide composer preload now runs only for releases using the classical
  track-list layout. This does not affect creators/work on non-classical Track
  Details; those continue to load on demand through `TrackDetailStore`. It
  removes unused duplicate MusicBrainz traffic for non-classical releases.
- Artist-card loading now has three independent progressive sections. The
  already-known artist name/lifespan is published immediately; artist-detail →
  Wikidata/Wikipedia starts first; and the initial discography page starts as a
  separate task. Wikipedia can therefore appear while a slow discography is
  still loading, and either section can fail or retry without clearing or
  reloading the other. Wikipedia and initial discography now have explicit
  loading, completed-empty (`n/a`), and retry states instead of silent blank
  space. Cached Wikipedia content remains visible during refresh.
- The shared request pipeline still retries transient failures for MusicBrainz,
  Wikidata, and Wikipedia, but the 1.05-second MusicBrainz admission interval is
  now applied only to `musicbrainz.org` hosts. Wikidata/Wikipedia traffic no
  longer consumes MusicBrainz rate-limit slots.
- Search now has an explicit `MY LIBRARY` / `MUSICBRAINZ` scope. Library-only
  searches return owned catalogue results without starting a global
  MusicBrainz request; the combined scope preserves library-first progressive
  results and MusicBrainz enrichment.
- User-entered comma syntax is parsed once into a typed `LibraryCatalogQuery`.
  Providers no longer infer artist/release intent from punctuation or from an
  artificial trailing comma.
- Local availability remains strictly release-MBID based. Untagged albums no
  longer mark similarly named MusicBrainz artists or release groups playable.
- Library-only artist rows resolve to MusicBrainz only through an exact
  case/diacritic/whitespace-normalized artist-name match; fuzzy first results
  are not selected silently.
- The Apple Music Now Playing row is visible again on the iOS Search card and
  was verified manually on a physical iPhone.
- `Tools/verify.sh` now provides one local preflight command for the complete
  macOS test suite, generic iOS build, and MusiCards Sync tests.
- Personal Xcode `xcuserdata` files are no longer tracked; each development
  machine keeps its own breakpoints, bookmarks, and scheme-management state.
- The macOS window can be dragged again; the fix is committed as `95e8795`.
- Search state-reset helpers are consolidated, and barcode/Shazam retry keeps
  its original request type. A Shazam-to-manual-edit edge case is also fixed
  and regression-tested.
- The player now displays the active system output reactively in collapsed and
  expanded views, with source/output details in the expanded player. The home
  screen says `PLAYBACK SETUP` and shows the active output without offering an
  in-app output switch yet. iPad built-in output is named `THIS IPAD`.
- iOS observes audio-route notifications; macOS observes Core Audio default
  device, device-name/data-source, transport, and nominal sample-rate changes.
  A two-second timer remains only as fallback if the default-device listener
  cannot be installed. Playback position ticks no longer query the route.
- Artist Wikipedia links use consistent language labels. English is preferred;
  otherwise an available artist-native language is preferred, with a bounded
  optional Wikidata lookup and fallback behavior.

Do not casually redesign these behaviours while starting a roadmap item. The
2.0 release is the known-good baseline.

## 5. Architecture map

Read `PLAYER_ARCHITECTURE.md` before changing playback code.

Important seams and files:

- `MusiCards/App/MusiCardsAppModel.swift`
  - application composition and shared state;
  - selection/load coordination;
  - injection of library and playback services.
- `MusiCards/Playback/PlaybackEngine.swift`
  - platform-neutral playback-engine contract and current output inspection.
- `MusiCards/Playback/MacOutputRouteObserver.swift`
  - event-driven macOS system-output route observation.
- `MusiCards/Playback/PlaybackController.swift`
  - queue, transport state, selection generations, and orchestration;
  - heavily tested and safety-critical: avoid unnecessary changes.
- `MusiCards/Playback/MacSystemPlaybackEngine.swift`
- `MusiCards/Playback/IOSSystemPlaybackEngine.swift`
  - concrete Core Audio playback paths.
- `MusiCards/Playback/AudioUnitPlaybackCore.swift`
  - shared low-level render path.
- `MusiCards/Playback/RemoteAudioFileDecoder.swift`
- `MusiCards/Playback/LibFLACRemoteAudioDecoder.swift`
- `MusiCards/RemoteLibrary/HTTPRandomAccessByteSource.swift`
  - Navidrome/remote random-access decode path.
- `MusiCards/LibraryAccess/LibraryManager.swift`
  - active Local/Navidrome source routing.
- `MusiCards/LibraryAccess/LocalLibraryProvider.swift`
- `MusiCards/LibraryAccess/NavidromeLibraryProvider.swift`
  - deterministic release/recording availability and playable asset lookup.
- `MusiCards/RemoteLibrary/NavidromeConnection.swift`
- `MusiCards/RemoteLibrary/NavidromeConnectionStore.swift`
- `MusiCards/RemoteLibrary/OpenSubsonicClient.swift`
  - validated Navidrome-only OpenSubsonic connection and credentials flow.
- `MusiCards/ViewModels/SearchViewModel.swift`
  - MusicBrainz/library search merging and search state.
- `MusiCards/Services/RecentContentCache.swift`
  - cached recent artist/release content.
- `MusiCards/Deck/iOS/`
  - iOS/iPad deck geometry and card appearance.
- `MusiCards Sync/`
  - separate synchronization utility.

The main schemes are:

- `MusiCards` in `MusiCards Release Viewer.xcodeproj`
- `MusiCards Sync` in `MusiCardsSync.xcodeproj`

`MusiCards.xcworkspace` contains both projects and the pinned Swift package
resolution for:

- `flac-binary-xcframework` 0.2.0
- `ogg-binary-xcframework` 0.1.3

## 6. Tests and verification

The repository has substantial XCTest coverage. Main areas include:

- release-selection races;
- playback controller and render callbacks;
- local and Navidrome library providers;
- Navidrome connection validation and remote byte-range reads;
- FLAC and remote decoder behaviour;
- MusicBrainz search/error/rate-limit semantics;
- library-first search and recent-content caching;
- local-library manifests and release queue building;
- Now Playing integration;
- MusiCards Sync preview, rsync arguments/output/progress, cancellation-related
  view-model behaviour, index generation, remote destinations, bundled rsync,
  and Unicode normalization.

Before handing off a code change, run affected focused tests while developing,
then run the complete local preflight from the repository root:

```sh
./Tools/verify.sh
```

The script checks the complete tracked diff since `HEAD`, runs the MusiCards
macOS tests, builds MusiCards for a generic iOS device, and runs the MusiCards
Sync macOS tests. It stops at the first failure and does not change source files.

Most recent complete `./Tools/verify.sh` verification was for application
checkpoint `5ba2b45` on 2026-10-04:

- the complete tracked diff passed the whitespace check;
- all MusiCards macOS tests passed;
- the MusiCards generic iOS device build passed with code signing disabled;
- all 62 MusiCards Sync tests passed;
- Apple Music Now Playing was also verified manually on a physical iPhone.

After `c3d9c1c`, the MusiCards macOS XCTest suite passed, the generic iOS
Simulator build passed, and `git diff --check` was clean. These were separate
checks, **not** a fresh complete `./Tools/verify.sh` run; MusiCards Sync tests
were not rerun for this checkpoint. The user also confirmed automatic Mojo 2
route display on iPhone and output changes through macOS Control Center.

## 7. Roadmap and next likely work

The current roadmap is `Documentation/MusiCards_Roadmap.md`. Its four principal
directions are:

1. **My Library / full MusicBrainz catalogue switch** — the first, Search-only
   scope is implemented; broader artist/release-group filtering remains an
   optional product decision.
2. **Bit-perfect/exclusive macOS output** — HAL device selection, hog mode,
   sample-rate control, hot-plug fallback, and diagnostics.
3. **Navidrome → UPnP/DLNA renderer control** — MusiCards as control point only;
   audio flows directly from Navidrome to the renderer.
4. **Gapless playback** — pre-resolution/preloading and later engine-level
   seamless buffer handoff; likely the highest-risk item.

There is also a possible macOS mini-player idea.

The `SearchViewModel` state-reset consolidation is done. The agreed next
feature is Navidrome → AVM UPnP playback, with the physical renderer available
at the office. A separate later cleanup may remove the redundant extracted
rsync source tree while retaining its verified source archive, licence
material, provenance, and build script.

### UPnP experiment already completed

Do not restart UPnP discovery from assumptions. Existing real-hardware work is
documented in:

- `Documentation/Experiments/MusiCards_Navidrome_AVM_handoff.md`
- `Tools/UPnP/navidrome_avm_setnext_probe.command`
- `Documentation/MusiCards_Roadmap_No_3_ UPnP_Renderer_Task.md`

The experiment against an AVM Audio CS 2.3 and Navidrome already demonstrated:

- direct raw Navidrome stream playback by the renderer;
- HTTP Range support and renderer-side seeking;
- SSDP/AVTransport discovery and SOAP control;
- working `SetNextAVTransportURI` and autonomous transition to the next track;
- no audio bytes need to pass through the Mac or iPhone.

The detailed UPnP task document explicitly rejects the abandoned vendor-specific
QPlay approach. Standard AVTransport with a moving Current/Next window is the
planned direction. No UPnP production implementation has been started yet.
Treat that task document as a design proposal, not a current-code guarantee:
recheck its routing and queue assumptions against the present code and the
user's agreed home-screen output UX before implementing it.

Do not begin a roadmap item solely because it is listed here. Confirm the user's
next requested priority first.

## 8. MusiCards Sync constraints

Read these before modifying Sync:

- `Documentation/MusiCards Sync/MusiCards-Sync_base_info.md`
- `Documentation/MusiCards Sync/NFD-NFC.md`
- `ThirdParty/rsync/README.md`
- `ThirdParty/rsync/NOTICE.md`

Important invariants:

- Source is the single source of truth; synchronization is one-way.
- Preserve the Check → Preview → Sync → Verify workflow.
- Preview must transparently show additions, modifications, deletions, folders,
  and macOS system cleanup before the real operation.
- Progress is based on real rsync progress; do not replace it with an animation.
- Preserve Unicode NFC/NFD handling for macOS ↔ Linux filenames, especially
  accented Hungarian names.
- Preserve bundled rsync licence/provenance and the dedicated third-party
  licence UI.
- Keep Sync purpose-built; do not turn it into a general file-sync framework.

## 9. Public communication state

- MetaBrainz 2.0 announcement is live:
  <https://community.metabrainz.org/t/musicards-2-0-the-musicbrainz-release-browser-is-now-also-a-personal-music-player/815556>
- The announcement explains the strict Picard/Release-MBID playback rule and
  the blue play indicator.
- A first-comment description of MusiCards Sync has been prepared.
- Reddit announcement copy has been prepared for:
  - a new standalone `r/MusicBrainz` post;
  - a shorter Navidrome-focused comment in the current `r/Navidrome`
    **App News Weekly** thread (standalone app-promotion posts are not permitted
    there).
- At the time of this handoff, publication of those new Reddit texts was not
  confirmed. Check with the user before describing them as already posted.

## 10. Product and collaboration principles

- Preserve MusicBrainz transparency: do not fabricate unavailable metadata.
- Prefer deterministic MBID relationships over fuzzy matching.
- Keep changes minimal and scoped to the user's explicit request.
- Preserve unrelated and uncommitted user work.
- Inspect Git state before editing and report any pre-existing changes.
- Use cancellation and generation/identity checks for async UI publication where
  stale results could overwrite a newer selection.
- Keep platform-specific visual decisions platform-specific.
- Do not reintroduce Intel support without an explicit product decision.
- Do not add signing, capabilities, privacy declarations, or external services
  speculatively; inspect the concrete feature and target requirements first.
- After implementation, verify in proportion to risk and summarize both the
  final diff and verification results.

## 11. How to update this handoff

At the end of a material session, update at least:

1. **Snapshot:** date, branch, last completed checkpoint, remote relation, and
   exact dirty files.
2. **Released products:** only when version/build/distribution state changed.
3. **Completed state:** move newly finished work here in one concise bullet.
4. **Roadmap:** mark what started, finished, changed direction, or was rejected.
5. **Verification:** record the most recent relevant builds/tests and any genuine
   blocker separately from sandbox/tooling limitations.
6. **Public communication:** update only confirmed publication state.

Before switching computers:

1. commit or intentionally preserve all wanted changes;
2. update this file;
3. run `git status --short --branch`;
4. push the intended branch;
5. on the other computer, pull/fetch first and ask Codex to read this document
   plus the current Git state before making changes.
