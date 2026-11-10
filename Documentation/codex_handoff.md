# MusiCards — Codex handoff

Living handoff for continuing on another Mac. Git and the user's latest
instructions take precedence. Never commit passwords, tokens, authenticated
media URLs, private server addresses or signing material here.

## Current checkpoint — 2026-11-10

- Latest local commit: **ea30c09** (`iphone duo`). The following iPad redesign
  is pending in the working tree; no commit or push was made for it.
- iPad at available sizes of at least 700x520 now uses the shared
  `SideMeterDeckLayout.swift` in Debug and Release, without the Duo debug flag.
  Portrait: wide left deck, full-content-width Release cover and whole-card
  scrolling, right-side real stereo meter with L/R labels. Landscape: existing
  home/settings on the left, deck and meter in the right half. The deck's left
  edge starts beyond the window centerline by its normal outer/inner margin.
  Smaller windows retain the former single-deck fallback.
  Ordinary iPhone presentation stays unchanged; Duo is now enabled in Release too.
- Landscape home/settings spacing is expanded on both iPad and Duo, through
  the existing `showsExplorePrompt == false` panel mode. Other home views keep
  their spacing. Side-meter decks allow 24 pt around their outer clipping bounds
  for the shadow halo; individual card content remains clipped to its shape.
  This avoids cutting off shadows at the 8 pt inner deck margin. Visually checked
  in landscape on the iPad Air simulator; no test audio was started for this pass.
- The shared side layout replaces iPad's former 100 pt internal deck margins
  with 8 pt internal margins and explicit outer margins. iPad adds 32 pt top
  space and 24 pt bottom space. Only localized active system occlusion bounds
  constrain the meter; bottom obstructions constrain its bottom, not its top.
- Visually checked on the iPad Air 11-inch (M4) simulator using real Navidrome
  playback in portrait and landscape, including rotation during playback and
  live L/R meters. Playback was paused afterward. Comprehensive Stage Manager,
  Split View, iPad mini and 13-inch interactive checks remain outstanding.
- Validation for this redesign: iPad simulator Debug build, generic iOS Release
  build and macOS arm64 Debug build all succeeded; `git diff --check` passed.
- Production promotion: removed the Duo flag and Debug branches, renamed the
  orientation delegate, and unified tablet/foldable selection in ContentView.
  Scheme Run is Release without LLDB. Full Tools/verify.sh passed: 261 main-app
  tests, generic iOS build and 62 Sync tests. SearchErrorSemanticsTests now has
  @MainActor to match the UI value construction; its targeted rerun passed.
  A signed Release simulator build was launched without flags and visually
  checked on Duo closed/open portrait and open landscape. Archive/Organizer
  signing validation and a fresh physical-device/AVM smoke test remain separate.
  Conventional iPhone 18 Pro was also launched from the same Release simulator
  product with no flag; the original full-width home/deck presentation remains.

- Historical release-cleanup checkpoint: main, **7cb3185**
  (`server settings refine`). The user subsequently removed the source-export
  archive in **d9bb868** (`Delete musicards.zip`). Playback safety changes are
  already committed in **84d52c7** (`polish`); they are not pending work.
- The working tree was clean before this small release cleanup. The cleanup
  updates this handoff, removes macOS-only plist noise and adds a narrow ignore
  rule for future root-level `musicards.zip` exports. Read Git for its eventual
  commit. No fetch was performed; this does not assert the live remote/push state.
- Main project: **2.2, build 11**. The user submitted 2.1; current App Store
  availability has not been rechecked. Project version does not prove publication.
- **iPad now intentionally supports all four orientations.** This supersedes
  the November 6 portrait-only decision. Do not restore that restriction or add
  UIRequiresFullScreen. iPhone keeps its existing portrait orientations.
- The full `Tools/verify.sh` passed on the committed November 9 application:
  **261 main-app macOS tests, generic iOS device build and 62 Sync tests**.
  Organizer archive/signing validation and a physical AVM retest remain pending.
- Shared scheme Run uses Release without LLDB intentionally. The user did not
  reproduce crackles outside Xcode. Audio System Trace showed deadline misses
  with debugger involvement; the exact mechanism was not proven. Temporary
  traces/exports were deleted at the user's request.

Start with `git status --short --branch` and `git log -5 --oneline`.

### November 9 application changes — committed in 7cb3185

- Navidrome has explicit not-configured/checking/local/remote/unavailable states.
  Prefer a reachable local address, otherwise remote. A saved profile alone
  does not authorize renderer playback. Startup, foregrounding, SOURCE opening
  and NWPathMonitor network changes recheck reachability; concurrent checks
  share work and late/cancelled responses cannot restore old state.
- Playback reuses a verified endpoint between network/foreground checks instead
  of probing a failed local address before every remote track. On an endpoint
  change, the next explicit Play rebuilds the remote preparation and preserves
  the current seek position when supported. No automatic speaker fallback.
- **UPnP requires an active verified local Navidrome connection.** Remote-only
  setup supports system audio only. The renderer never receives the remote URL
  as fallback. Loss of local connectivity pauses active renderer playback;
  explicitly choose System audio to play on the controlling device instead.
  This is a deliberate product policy, not a claim that HTTPS is unsafe.
- SOURCE shows blue **ACTIVE** beside the actual local or remote address's
  heading. No active badge is shown while checking, unavailable or when that
  address has unsaved edits. Reconnect is available after failed reachability.
- A combined library artist credit resolves the searched credited artist using
  MusicBrainz release credits/artist IDs, never comma splitting or the first
  fuzzy artist result. The user confirmed the Steve Khan example works.
- Discography arrows use verified Release-to-Release-group MBID membership,
  not album-title equality. Metadata requests cover the selected artist's owned
  candidates in batches of 25, share the MusicBrainz rate limiter, and cache
  successful results in memory. Ownership always follows the active provider.
- iPad landscape/short windows keep a centered deck whose width is also bounded
  by viewport height. Compact Release artwork is height-limited, and its header
  and metadata scroll together. Home spacing is smaller in compact layouts.
  Real SwiftUI/UIKit release views were rendered on an iPad simulator at
  1180x820, 1133x744 and 820x1180 with a synthetic cover. The temporary rendering
  harness was removed. This was not a full interactive iPad/Stage Manager test.
  The user found landscape much improved. Superseded at larger window sizes by
  the November 10 shared iPad/Duo design above.

### Next session — office AVM check before 2.2 submission

The side-meter presentation is now production code shared by Debug and Release.
The former Duo environment flag and preview-only delegate were removed. Run uses
Release without LLDB again. `SideMeterDeviceLayout` selects phone side layouts
from the system rail/fold geometry; conventional phones keep the original deck.
`DeviceOrientationDelegate` allows all orientations on iPads and on windows with
an iOS 27.1+ fold division (including inactive divisions), keeping conventional
phones portrait-only. No private device names or display APIs are used.

The implementation is shared by iPad and Duo in SideMeterDeckLayout.swift:
- Portrait has a deck and a right-side stereo meter. iPad has explicit outer
  margins and L/R labels. Release cover fills content width; header and metadata
  scroll together. Open portrait Duo uses an 8 pt top inset and public system
  concentric corner radii; closed Duo keeps its 12 pt inset.
- Landscape uses one full-window background, the existing home/settings on the
  left, and the deck/meter on the right. iPad reserves the right half plus normal
  deck margins; Duo keeps its phone-sized deck. Left settings spacing is expanded.
  The right deck omits a duplicate home view. Smaller iPad windows fall back to
  the former single-deck layout.
- The meter uses existing measured PCM RMS, observer leases and Reduce Motion;
  it has no fabricated renderer data and no extra audio/UI timer. A stable empty
  container allows metering to start before the first sample or Player opening.
  Localized active system occlusions constrain the top/bottom separately;
  container-sized bounding frames cannot locate an obstruction and are ignored.
- Card shadows have 24 pt of additional outer clipping room in side layouts;
  individual card content is still clipped to its rounded shape.

Prior Debug simulator checks covered closed/open portrait Duo and open landscape
Duo with real Navidrome playback. iPad Air 11-inch simulator checks covered both
orientations and rotation during playback with live L/R meters. These do not
constitute physical hardware or comprehensive Stage Manager certification.
No synthetic fixture/sample levels remain in app code. Keep normal simulator
signing when installing builds so existing connections retain Keychain access.

Use the normal Release run without LLDB for listening. Do not put real server
addresses, credentials, authenticated stream URLs or SOAP bodies in this log.

1. On the office LAN, open SOURCE: the local address should show ACTIVE with
   local-only or dual-address setup. Select the AVM in OUTPUT and start an album.
2. Check Play/Pause/resume, seek, volume/mute, previous/next and natural track
   transitions. Confirm the displayed track/output follows the actual playback.
3. Lock the iPhone and let several tracks finish. Earlier AVM/Macast successes
   predate November 9 endpoint changes and do not certify the new build.
4. With remote-only setup, verify remote ACTIVE and System audio playback;
   UPnP selection/playback must be unavailable. With both addresses, test
   local -> remote -> local as network/VPN reachability changes. A lost AVM
   connection must not start playback on the phone/Mac speakers automatically.
5. If neither address is reachable, neither address gets ACTIVE. Reconnect
   should recover after connectivity returns. Test a restart away from the LAN.
6. If possible, check iPad landscape and reduced window sizes for reachable
   controls/content. Visual perfection is deferred; inaccessible controls are not.

After these checks, confirm build 11 is unused for App Store version 2.2 (raise
it if already uploaded), archive Release, and validate signing/provisioning in
Organizer. The unsigned verification script cannot perform Store validation.

### Player UI update — 2026-11-06

Expanded source/output metadata now uses one line per source/output, without
SOURCE/OUTPUT headings. The expanded player's reserved row below the seek bar
shows two fine dotted RMS signal meters for native system playback only.
The C callback measures the rendered PCM without modifying it and publishes a
single atomic stereo-energy snapshot. The main actor reads it using existing
10 Hz progress updates; the view adds short interpolation, with no new timer.
Mono is mirrored. The scale is logarithmic (-50 to 0 dBFS), before OS/DAC volume.
UPnP has no local PCM and never displays a fabricated meter. Pause/failure/queue
changes clear the level; route changes clear old system data. Reduce Motion hides
the decorative animation. Collapsed players retain their output-name row.
Tests check stereo RMS, mono/underrun silence, unchanged output samples, the
display scale and pause/renderer/queue transitions. This update is in cba4d7c.
The full `Tools/verify.sh` run passed on 2026-11-06: main macOS tests, generic
iOS device build and all 62 Sync tests.

### Playback safety and testability update — 2026-11-06 (committed in 84d52c7)

- FLAC bridge initialization requires all callbacks and a live context, rejects
  repeat initialization before changing callback/context pointers, and leaves
  rejected wrappers reusable. Tests cover every missing argument and repeat init.
- The common playback coordinator explicitly tracks user intent and session
  lifetime. It skips superseded queued seeks, waits for seeks arriving during
  Play preparation, preserves Play when a newer user seek supersedes an implicit
  replay rewind, and prevents duplicate starts. Reset detaches old-session I/O
  logically: retained old decoders can finish but cannot delay or control new
  output. Pause is immediate; a later Play waits for same-session mutations.
- AudioUnitOutputDriving is an internal start/stop/dispose seam. The default
  driver calls the same Apple APIs; headless tests use the real core, DecodedPCM,
  feeder and C renderer with an inert output driver and controllably blocked
  decoder. They cover Pause, Play, replacement, start failure, non-finite seek,
  stop-before-dispose and release after in-flight cancellation.
- DecodedPCM still cancels before draining the feeder queue. In-flight work
  retains the session until it exits; tests verify Stop can return while old
  seek I/O stays blocked and that the session is freed once that seek returns.
  Do not remove the drain or free the renderer eagerly. Queue identity is now
  per decoder, so another decoder's feeder is not mistaken for this one.
- VU measurement is opt-in at the C boundary, disabled by default. Visible,
  active expanded-player views hold independent UUID leases; backgrounding,
  closing the player or Reduce Motion releases the view's lease. Routing enables
  it only for system playback and preserves that preference for new decoders.
  No signal scan or meter events occur without a request. PCM remains unchanged.
- A local optimized C microbenchmark (five median runs, 512 stereo frames,
  write plus render) measured about 0.124 microseconds/block disabled and 1.124
  enabled. This is a Mac microbenchmark, not an iPhone deadline certification.
  Full-sample double precision was retained; visibility gating saves the work
  entirely when unused. No extra timer was added.
- SearchViewModel accepts an injected coverArtLoader, defaulting to the existing
  shared cache. Library-first search tests now inject no network artwork loader.
  This removes real Cover Art Archive traffic from the barcode pagination test,
  which had exceeded its one-second polling allowance in a full run.

Historical verification: complete Tools/verify.sh passed (main macOS suite, generic iOS
device build, 62 Sync tests). All 23 targeted core/renderer/FLAC tests passed
with Address Sanitizer, including the final per-session feeder identity.
All 36 focused core/renderer/controller tests also passed with Thread Sanitizer;
no data races were reported in that run. A subsequent complete verify.sh run
passed with the additional actual-core replay-versus-explicit-seek regression.
Manual follow-up remains: real iPhone/Mac pause/seek/replay/route changes and
VU visibility/background transitions; no physical AVM was used in this session.

## Current product

- MusicBrainz Search, Release, Tracks, Artist & Discography and Player use the
  iOS/iPadOS card deck and macOS accordion. SOURCE, OUTPUT and help use native
  sheets. Share code except for actual platform differences.
- Home is the deliberate source/output setup; players display the active output.
  macOS has a small library-index creation link on Home.
- This device selects a folder containing library.json, generated by MusiCards
  for Mac or Sync from Picard-tagged files. This is intentional. Display readable
  provider/volume paths; original URLs and security-scoped bookmarks govern access.
  Folder restore avoids blocking startup. Source switching cancels pending
  connection work; sheet dismissal alone does not.
- Navidrome supplies catalog and MBIDs without library.json. SOURCE holds one
  account with optional local-network and remote HTTPS addresses, at least one
  required. Prefer reachable local, otherwise remote; renderers require an
  active verified local connection, with no remote fallback. One unverified
  endpoint can be retained if the other verifies.
- System audio follows OS-selected speakers, USB DAC, Bluetooth or AirPlay.
  Route display is reactive. Names use normal case consistently; expanded
  source/output metadata use one line each. Never fabricate output bit depth.
- UPnP playback is functional for **Navidrome tracks only**, with direct
  server-to-renderer audio, AVTransport/DIDL-Lite, polling, optional volume/mute,
  SetNext staging and existing-renderer-session adoption.
- Discovery: multicast SSDP, bounded local /24 deep search, stored and manual
  address. Passive advertisements are an invisible helper. Tap selects immediately.
- User tests confirmed AVM playback and Macast deep-search discovery, seek,
  volume, transitions, output switching and five tracks with iPhone locked.
  Home multicast discovery remained unreliable. Do not infer certification of
  all renderers or sample-level gapless from these observations.
- Search scope, consolidated resets and origin-preserving barcode/Shazam retries
  are implemented. Availability is strictly Release-MBID based, not fuzzy names.
- Wikipedia prefers English, otherwise an artist-appropriate available language;
  the link displays the actual language code.

## Review fixes committed in 673e02a — 2026-11-02

1. Local-HTTP validation parses complete IPv4 and explicit local IPv6 ranges.
   Public, malformed and numeric-disguised hosts are rejected. Stream URL building
   independently checks local-only HTTP; the legacy ping bypass cannot permit
   public HTTP. Remote HTTPS remains supported.
2. Shared AudioPlaybackOperationCoordinator preserves latest user intent:
   Pause cancels seek auto-resume; Stop/replacement invalidates late results.
3. Play waits for decoder mutations; seeks serialize and only the latest resumes.
   C reset takes an atomic render-access flag while changing cursors. The callback
   never waits: it emits silence if reset holds the flag. Feeder writes/reset
   stay on the serial feeder queue. Seek UI publication checks queue generation.
4. UPnP STOPPED/NO_MEDIA_PRESENT advances only with known end-of-track evidence,
   within at most two seconds. Early/unknown-duration stops pause without consuming
   the queue; ERROR_OCCURRED reports failure. Last position/duration cover devices
   that reset position on Stop. Stale polls are invalidated.
5. SSDP LOCATION must be local HTTP(S). URLBase and service endpoints stay on the
   discovered host; different ports are allowed. Discovery and SOAP refuse HTTP
   redirects, including ones that could forward a token-bearing SOAP body.

Cross-host descriptions and redirecting renderers are intentionally rejected.
Retest AVM/Macast compatibility. A selected renderer still receives a reusable
Navidrome token by protocol design. This does not authenticate devices or secure
an untrusted LAN; DNS identity is not cryptographic. Never log authenticated
stream URLs or SOAP bodies. Do not loosen endpoint policy without a concrete,
documented compatibility requirement.

Regression tests cover disguised/public hosts, renderer stream validation,
hostile device/service URLs, same-host different ports, real loopback redirects,
Pause/Play/Stop during suspended seek, superseded seeks, concurrent C reset/render
and early renderer Stop. Existing natural-end/SetNext tests must remain green.
These five fixes and the later playback safety changes above are committed.

## Verification

Run `./Tools/verify.sh`: whitespace, main macOS tests, generic iOS device build
without signing, then Sync macOS tests. It does not run iOS tests or validate
Store provisioning. The latest full run on 2026-11-09 passed all 261 main-app
macOS tests, the generic iOS device build and all 62 Sync tests. The earlier
November 6 sanitizer results are historical; sanitizers were not rerun for the
November 9 UI/endpoint changes. iPad simulator build/render validation worked
on November 9; do not confuse the limited size fixtures with a full interactive
landscape, Split View or Stage Manager test.

Manual follow-up: seek → Pause, paused seek → Play, rapid seeks, output switching,
early renderer Stop and normal track transitions on physical Apple devices and
AVM/Macast. No physical renderer was used by the agent for the November fixes.
Keep audio quality checks separate from sanitizer/debugger timing.

## Architecture and next work

Read PLAYER_ARCHITECTURE.md for product decisions; current code and this handoff
supersede its historical placeholders. Relevant files under MusiCards/:

- App/MusiCardsAppModel.swift: composition and selection/load coordination.
- Playback/PlaybackController.swift: queue, commands and generations.
- Playback/AudioUnitPlaybackCore.swift: shared lifecycle and operation coordination.
- Playback/MacSystemPlaybackEngine.swift and IOSSystemPlaybackEngine.swift:
  platform device/session policy.
- Playback/MCPPCMRenderer.c: realtime consumer; no blocking, allocation, logging
  or Swift actor entry in the callback.
- Playback/LocalAudioFileDecoder.swift, RemoteAudioFileDecoder.swift,
  LibFLACRemoteAudioDecoder.swift, MCPFLACDecoderBridge.c: decoder/feeder path.
- RemoteLibrary/HTTPRandomAccessByteSource.swift: remote range reads.
- Playback/UPnP/: discovery, endpoint policy, SOAP and renderer transport.
- LibraryAccess/ and RemoteLibrary/: providers, Navidrome and credentials.
- ViewModels/SearchViewModel.swift: search and progressive merging.

See Documentation/MusiCards_Roadmap.md. Current priority is hardening/release
verification of existing UPnP playback. Local hog/exclusive mode and local gapless
remain deferred. Broader filtering and mini-player are optional decisions.
Do not start broad AppModel/SearchViewModel refactoring from line counts alone.
An independent decoder/C-bridge memory-safety audit remains worthwhile and was
not completed by this review.

Historical references:
- Documentation/Experiments/MusiCards_Navidrome_AVM_handoff.md
- Documentation/MusiCards_Roadmap_No_3_ UPnP_Renderer_Task.md
- Tools/UPnP/navidrome_avm_setnext_probe.command

## Sync and collaboration

Sync is a separate macOS Apple-silicon app (project 1.0/build 2). Preserve one-way
Check → Preview → Sync → Verify, real rsync progress, deletion previews and NFC/NFD.
Before editing read Documentation/MusiCards Sync/MusiCards-Sync_base_info.md,
NFD-NFC.md there, and ThirdParty/rsync/README.md and NOTICE.md. Preserve third-party
licensing/provenance and its dedicated UI.

Main app targets Apple-silicon macOS and iOS/iPadOS 26+. Multicast approval was
enabled by the user; macOS UDP discovery uses client/server sandbox capabilities.
Do not change signing/capabilities speculatively or rename Keychain services and
preference keys without migration.

MetaBrainz 2.0 announcement was published. Prepared Reddit/other promotional copy
was not confirmed published. Do not infer Store or announcement publication.

Preserve unrelated edits, explain consequential work and stay within approved
scope. Do not commit, push or publish implicitly. Update this file after material
sessions; commit/push intended changes before switching Macs and inspect Git on
the destination machine.
