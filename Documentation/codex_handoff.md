# MusiCards — Codex handoff

> **Living handoff document for continuing the project on another computer.**
>
> Update this file after every material development session. Keep it focused on
> the current truth rather than accumulating a full changelog; Git remains the
> history. Never place passwords, tokens, private server addresses, signing
> material, personal paths, or other secrets in this tracked file.

## 1. Snapshot

- **Last updated:** 2026-08-30 (Europe/Budapest)
- **Repository:** `musicards`
- **Branch:** `main`
- **HEAD:** `632f92c` — `Update MusiCards_Roadmap.md`
- **Remote state at handoff:** `main` matched `origin/main`.
- **Working tree at handoff:** one pre-existing untracked document:
  `Documentation/MusiCards_Roadmap_No_3_ UPnP_Renderer_Task.md`.
- The UPnP document belongs to the user. Do not delete, overwrite, rename, or
  stage it without checking the current task and Git state first.
- This handoff file is new and will also appear as untracked until the user
  commits it.

Always begin a new session with:

```sh
git status --short --branch
git log -5 --oneline --decorate
```

If the snapshot above differs from Git, Git and the user's newest instructions
take precedence; update this document before handing the project off again.

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
  - platform-neutral playback-engine contract.
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

Before handing off a code change, normally run in this order:

1. `git diff --check`
2. affected unit tests
3. MusiCards macOS build
4. MusiCards iOS build
5. MusiCards Sync build/tests when Sync or shared indexing code changed

At this handoff no new build or test run was required because only this Markdown
document was added. A sandboxed `xcodebuild -list` probe could not access normal
Xcode/SwiftPM caches and CoreSimulator services; this is an execution-environment
restriction, not evidence of a project failure. The shipped 2.0 build 8 had
already passed the release checks and Apple review.

## 7. Roadmap and next likely work

The current roadmap is `Documentation/MusiCards_Roadmap.md`. Its four principal
directions are:

1. **My Library / full MusicBrainz catalogue switch** — recommended first,
   initially scoped to Search.
2. **Bit-perfect/exclusive macOS output** — HAL device selection, hog mode,
   sample-rate control, hot-plug fallback, and diagnostics.
3. **Navidrome → UPnP/DLNA renderer control** — MusiCards as control point only;
   audio flows directly from Navidrome to the renderer.
4. **Gapless playback** — pre-resolution/preloading and later engine-level
   seamless buffer handoff; likely the highest-risk item.

There is also a possible macOS mini-player idea.

### UPnP experiment already completed

Do not restart UPnP discovery from assumptions. Existing real-hardware work is
documented in:

- `Documentation/Experiments/MusiCards_Navidrome_AVM_handoff.md`
- `Tools/UPnP/navidrome_avm_setnext_probe.command`
- the currently untracked
  `Documentation/MusiCards_Roadmap_No_3_ UPnP_Renderer_Task.md`

The experiment against an AVM Audio CS 2.3 and Navidrome already demonstrated:

- direct raw Navidrome stream playback by the renderer;
- HTTP Range support and renderer-side seeking;
- SSDP/AVTransport discovery and SOAP control;
- working `SetNextAVTransportURI` and autonomous transition to the next track;
- no audio bytes need to pass through the Mac or iPhone.

The detailed UPnP task document explicitly rejects the abandoned vendor-specific
QPlay approach. Standard AVTransport with a moving Current/Next window is the
planned direction. No UPnP production implementation has been started yet.

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

1. **Snapshot:** date, branch, HEAD, remote relation, and exact dirty files.
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

