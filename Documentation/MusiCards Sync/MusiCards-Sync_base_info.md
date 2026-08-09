# MusiCards Sync — Project Base Information

## 1. Project status and purpose

**MusiCards Sync** is a small native macOS utility for cloning my music library.

The application is currently functional and suitable for everyday use. Functionally it is close to an **1.0 release**.

The next development phase is primarily **cleanup, refactoring and stabilization**, not adding new features.

### Important principle

The current working version is the baseline.

During refactoring, do not unnecessarily redesign or change either:

- existing functionality;
- established UI/UX;
- synchronization semantics.

The application deliberately follows a **single-purpose tool** philosophy rather than becoming a general-purpose synchronization application.

> Few functions, implemented clearly, quickly, honestly and transparently.

The basic workflow is:

**Source → Destination → Check → Preview → Sync → Verify**

---

# 2. Synchronization model

There is one canonical Music library on the Mac.

**The Source is always the source of truth.**

MusiCards Sync creates one-way mirrors of this library on selected destinations.

This is deliberately **not**:

- two-way synchronization;
- conflict resolution;
- merge;
- version control;
- backup history;
- a configurable general-purpose sync framework.

The Destination is simply updated to match the Source.

Current destination types include:

- **Umbrel — Raspberry Pi 5**, via SSH/rsync;
- **CasaOS — Raspberry Pi 4**, via SSH/rsync;
- **local/external SSD**, via local rsync.

Remote and local destinations should remain two variants of the same conceptual destination abstraction.

---

# 3. Check → Preview → Sync → Verify

Before synchronization, the user runs **Check**.

Check performs a dry-run and presents a Sync Preview containing categories such as:

- New files
- Modified files
- New folders
- Deleted files
- Deleted folders
- System cleanup

The user can inspect this before explicitly starting Sync.

Sync then performs the real operation.

After Sync completes, an automatic verification/check is performed.

This separation is an important part of the application's safety and transparency:

> Show exactly what will happen before doing it.

---

# 4. rsync

Actual file operations are performed by a modern Homebrew rsync.

The version used during development has been:

```text
rsync 3.4.4
protocol version 32
```

Important rsync mechanisms used by the application include:

```text
--itemize-changes
--out-format
--delete
--info=progress2
--no-inc-recursive
```

plus explicit handling/exclusion/classification of macOS system files.

Remote destinations use rsync over SSH.

Local destinations use local rsync.

## Progress

The progress bar must represent **real synchronization progress**, not an artificial timer or animation.

`--info=progress2` provides overall rsync progress.

During development we observed that rsync's default incremental recursion could make the reported percentage occasionally move backwards because the total known file list was still growing.

The current solution uses:

```text
--no-inc-recursive
```

for the real Sync operation.

This makes rsync build the complete file list before transfer begins, keeping the progress denominator stable.

A short period at `0%` while rsync builds the list is acceptable.

A progress bar that moves backwards is not.

---

# 5. CRITICAL: Unicode NFC/NFD filename normalization

This must **not be forgotten during refactoring**.

During development we diagnosed a real macOS ↔ Linux filename normalization problem, particularly visible with Hungarian accented filenames.

A representative example was:

```text
Nyeső Mária
```

Visually identical filenames may have different Unicode representations.

For example, an accented character may exist as:

- a precomposed Unicode code point;
- a base character plus combining accent(s).

macOS may make this distinction largely invisible to the user, while Linux/ext4 and rsync can see different byte sequences as different filenames.

This caused real synchronization problems: visually identical filenames could repeatedly appear as changed, new or deletable.

## Existing checker/repair work

During development we created **working NFC/NFD checker and repair procedures/scripts/command sequences** which successfully diagnosed and repaired the music library.

These original checker/repair tools must be preserved with the project if available.

Suggested location:

```text
Tools/
    NFC_checker...
    NFC_repair...
```

or, if they are command sequences rather than standalone scripts:

```text
Tools/NFC_NFD_TOOLS.md
```

### IMPORTANT

**Do not assume that the checker/repair logic is already fully integrated into the Swift application.**

One of the first project-analysis tasks is to compare:

1. the preserved working checker/repair reference implementation;
2. the current Swift project;

and determine precisely:

- which NFC/NFD detection logic is already implemented;
- which repair logic is already implemented;
- which parts still exist only as external scripts/commands;
- whether the current app behavior is equivalent to the known working reference implementation.

Do not re-invent the normalization algorithm if the working reference implementation exists.

The final system must safely support Hungarian and other Unicode filenames across macOS and Linux.

---

# 6. macOS system files

The synchronization logic explicitly handles macOS filesystem metadata/system files.

Examples include:

```text
.DS_Store
._filename
.Spotlight-V100
.Trashes
```

These should not pollute the music library or produce confusing ordinary deletion/change entries.

The Preview therefore has a separate:

```text
System cleanup
```

category.

Preserve this behavior.

---

# 7. Cancellation / Stop

Both Check and Sync can be interrupted by the user.

Cancellation is a normal application state, **not an error**.

Correct behavior:

```text
Stop
→ rsync terminate
→ cancelled state
→ "Synchronization stopped"
```

The UI must not display:

```text
Synchronization failed
```

for deliberate cancellation.

Likewise, the user should not see raw rsync termination output such as:

```text
rsync error: unexplained error (code 255)
```

when the process was deliberately stopped.

A friendly final log message is used:

```text
Synchronization was stopped by the user.
```

The current `RsyncProcessState` cancellation mechanism should be preserved.

## Possible race condition to inspect

A previous code review identified a theoretically very narrow race window around:

```text
setProcess()
↓
cancel()
↓
process.run()
```

Check the actual current implementation.

If there is no second `wasCancelled()` check immediately before `process.run()`, consider adding one.

Do not change this blindly; inspect the current source first.

---

# 8. Sleep prevention

Long synchronization operations must not fail because the Mac goes to sleep.

The application currently contains sleep-prevention handling during Sync.

Preserve this behavior.

The sleep-prevention activity must be released correctly on every exit path:

- successful completion;
- error;
- user cancellation.

---

# 9. UI / UX philosophy

MusiCards Sync is intentionally a small, native macOS utility.

The UI should remain calm, direct and transparent.

Avoid:

- feature creep;
- unnecessary settings;
- card-heavy dashboards;
- decorative gradients;
- glass effects;
- redundant controls;
- multiple ways of performing the same action.

The UI should expose complexity only when the user needs it.

Internally the application handles things such as:

- rsync arguments;
- SSH;
- Unicode normalization;
- cancellation;
- sleep prevention;
- progress parsing.

The user should see only what is useful for making a decision.

---

# 10. Main window design

The current main window has a vertical process hierarchy:

```text
SOURCE

DESTINATION

SYNC PREVIEW

SYNC
```

A vertical icon rail on the left is not merely decorative: **the icons themselves are the controls**.

Conceptually:

```text
←   SOURCE
    Music Library
    /technical/path/to/Music/


→   DESTINATION
    CasaOS – RPi 4
    /technical/destination/path/


↻   SYNC PREVIEW
    New files ...
    Modified files ...
    ...


↻   SYNC
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 37%
```

The actions are:

- **Source icon** → choose Source folder;
- **Destination icon** → choose Destination/profile;
- **Sync Preview icon** → run Check;
- **Sync icon** → start Sync.

There should not be redundant parallel controls such as separate:

```text
Choose…
Check Again
Sync
```

buttons elsewhere in the window.

## Visual hierarchy

SOURCE and DESTINATION are the most important objects.

The human-readable name is visually prominent:

```text
Music Library
CasaOS – RPi 4
MUSIC_1TB
```

Technical filesystem paths are secondary information:

- smaller;
- secondary gray;
- monospaced.

Section headers follow the established MusiCards style:

- small;
- uppercase;
- secondary gray;
- slightly increased character tracking.

The Source and Destination arrows are prominent Apple-blue controls.

Unavailable actions are gray/disabled.

---

# 11. Main-window Sync progress

The main window contains a minimal Sync status section.

It uses:

- a long;
- thin;
- native;
- Apple-blue progress bar;

with percentage shown discreetly on the right.

The detailed progress information remains in the progress sheet.

The main window should remain visually quiet.

---

# 12. Progress sheet

The current progress popup/sheet design is considered successful and should **not be redesigned during cleanup**.

It contains:

- operation title/status;
- thin progress bar;
- percentage;
- continuously streaming rsync output/file names;
- Stop while running;
- Close after completion.

The sheet provides detailed feedback while keeping the main window simple.

Check may use an indeterminate spinner because it is not performing the actual transfer.

Sync uses determinate overall progress.

---

# 13. Sync confirmation

Starting a real synchronization requires explicit confirmation.

The Sync confirmation button must be a normal/default macOS action.

It must **not** use `.destructive` styling.

Therefore the Sync confirmation button is Apple-blue, not red.

Red should be reserved for genuinely destructive/error semantics.

---

# 14. Current titlebar issue

The native macOS app title has been removed from the titlebar while retaining the standard traffic-light controls.

The titlebar/content separator is still being refined.

Current observed behavior:

- when the application first opens, the separator is hidden;
- after running Preview/Check, the separator can reappear.

This suggests SwiftUI/macOS may be reconfiguring the `NSWindow` titlebar after state changes.

Current direction:

- use a small `WindowChromeConfigurator`;
- keep the standard traffic lights;
- hide title text;
- use `titlebarSeparatorStyle = .none`;
- reapply the configuration after relevant SwiftUI state changes if necessary.

Avoid:

- polling;
- timers;
- brittle `asyncAfter` hacks;
- unnecessarily replacing the entire native titlebar.

This is a small remaining UI issue, not a reason to redesign the window architecture.

---

# 15. AppDesign

Presentation constants and reusable visual components have begun moving out of `ContentView.swift` into:

```text
AppDesign.swift
```

This is considered a good direction.

Examples include:

- rail width;
- icon sizes;
- spacing;
- section header styling;
- thin progress bar styling.

Avoid scattering visual magic numbers throughout `ContentView`.

---

# 16. Current architectural concern

An external code review inspected the project and found the overall code quality good, particularly `SyncEngine.swift`.

The main architectural concern is `ContentView.swift`.

It has grown to roughly 600+ lines and currently mixes too many responsibilities:

- SwiftUI layout;
- application state;
- Check orchestration;
- Sync orchestration;
- progress parsing;
- cancellation;
- sleep prevention;
- configuration persistence;
- error state;
- `NSOpenPanel` calls.

This is becoming a SwiftUI equivalent of a **Massive View Controller**.

We agree with this criticism.

---

# 17. Planned SyncViewModel refactor

The primary 1.0 architectural cleanup should introduce a:

```text
SyncViewModel
```

preferably using modern Swift Observation (`@Observable`) if compatible with the deployment target.

Conceptual architecture:

```text
ContentView
    │
    │ UI / presentation / user interaction
    ▼
SyncViewModel
    │
    │ application state + orchestration
    ▼
SyncEngine
    │
    │ rsync / Process / pipes / cancellation
    ▼
filesystem / SSH
```

Alongside:

```text
SyncConfigurationStore
    └── persistence

AppDesign
    └── presentation constants/components
```

The purpose is separation of responsibilities and testability.

A target of approximately 250–300 lines for `ContentView` may be reasonable, but **line count itself is not the objective**.

Clean responsibilities are the objective.

---

# 18. Do not create a Massive ViewModel

Do not simply move 500 lines from `ContentView` into a new 500-line `SyncViewModel`.

The ViewModel should primarily own:

- application state;
- Check orchestration;
- Sync orchestration;
- cancellation;
- progress state;
- errors/status;
- sleep-prevention lifecycle.

rsync-specific parsing can remain near `SyncEngine` or be extracted into small dedicated parser types where appropriate.

`NSOpenPanel` is a UI interaction and may reasonably remain close to the View rather than being mechanically moved into the ViewModel.

Prefer small, meaningful abstractions over abstraction for its own sake.

---

# 19. SyncEngine

The existing `SyncEngine` is considered one of the strongest parts of the project.

Its public conceptual API is clean:

```text
preview
sync
cancel
```

It is independent from SwiftUI.

The existing `RsyncOutputState` and `RsyncProcessState` use `NSLock` and `@unchecked Sendable`.

Although this can look old-fashioned compared with actors, there is a deliberate reason:

`FileHandle.readabilityHandler` is a synchronous callback potentially running on a GCD thread.

Moving each received output fragment into independent `Task {}` calls could reorder output.

The lock-based implementation preserves deterministic output ordering.

Do not replace this with actors merely because actors appear more modern.

Any concurrency refactor must preserve ordering and Swift 6 safety.

---

# 20. Dead code to inspect

A previous review identified possible dead code.

Do not delete it blindly; first verify references across the current project.

## SyncPreviewView.swift

Reportedly no longer used because `ContentView` contains its own current Preview layout.

If genuinely unused, remove it.

Do not maintain two competing preview UI implementations.

## SyncEngine.rsyncVersion()

Reportedly unused.

If it has no current caller or planned immediate purpose, remove it.

Do not retain dead code for hypothetical future About/Diagnostics functionality.

---

# 21. parsePreview consistency

A previous review found an inconsistent force unwrap in `parsePreview(_:)`, conceptually:

```swift
line.firstIndex(of: "|")!
```

while a similar nearby branch safely uses:

```swift
if let separator = line.firstIndex(of: "|") {
    ...
}
```

The force unwrap may currently be logically safe because the tested prefix contains `|`, but the parser should use one consistent defensive style.

Prefer the safe form.

This is cleanup, not a behavior change.

---

# 22. ConfigurationStore cleanup

`SyncConfigurationStore()` has previously been instantiated repeatedly in several places.

If this is still true in the current project, use one shared store instance where appropriate.

Do not introduce dependency-injection machinery merely for this small utility unless it provides concrete value.

---

# 23. Hardcoded personal paths

Inspect:

```text
SyncConfiguration.defaultConfiguration
```

and related defaults.

The repository should not unnecessarily contain personal paths such as:

```text
/Users/hildgyorgy/...
```

for:

- Music source;
- SSH private key;
- other machine-specific paths.

A fresh install should use generic/empty defaults and ask the user to choose the necessary source/path.

Existing saved user configuration must continue to work.

Do not break the current machine's stored configuration merely to clean the source defaults.

---

# 24. Raspberry Pi destinations

Current remote systems include:

## Umbrel / Raspberry Pi 5

Uses an mDNS-style hostname such as:

```text
umbrel.local
```

## CasaOS / Raspberry Pi 4

During development the CasaOS machine was reachable at:

```text
192.168.1.33
```

The machine hostname is:

```text
rpi4
```

`casaos.local` did **not** work.

Consider whether:

```text
rpi4.local
```

is reliable.

If not, keeping the IP address is acceptable, preferably with DHCP reservation on the router.

Do not blindly replace the known-working IP destination.

---

# 25. Testing

The current project reportedly has no meaningful unit-test coverage.

The 1.0 cleanup should add a small XCTest target for deterministic parsing/normalization logic.

High-value tests include:

## parsePreview(_:)

Representative inputs:

```text
>f+++++++++|album/track.m4a
<f...|album/track.m4a
cd+++++++++|album/
*deleting|album/old.m4a
*deleting|.DS_Store
```

Verify classification into:

- new files;
- modified files;
- new folders;
- deleted files;
- deleted folders;
- system cleanup.

## Progress parsing

Representative input:

```text
18,482,351,220  37%   42.31MB/s
```

Verify:

```text
0.37
```

Also test lines which are not progress output.

## Unicode NFC/NFD

Once the original checker/repair implementation has been inspected, create regression tests using equivalent Unicode strings with different normalization forms.

This is particularly important because the Unicode problem was real, difficult to diagnose, and easy to reintroduce.

---

# 26. Do Not Regress checklist

After meaningful refactoring, verify:

- [ ] NFC/NFD checker behavior is preserved
- [ ] NFC/NFD repair behavior is preserved
- [ ] Hungarian Unicode filenames remain stable
- [ ] Umbrel RPi5 remote destination works
- [ ] CasaOS RPi4 remote destination works
- [ ] local external SSD destination works
- [ ] destination switching works
- [ ] Source selection works
- [ ] Check produces correct Preview
- [ ] New Files classification is correct
- [ ] Modified Files classification is correct
- [ ] New Folders classification is correct
- [ ] Deleted Files classification is correct
- [ ] Deleted Folders classification is correct
- [ ] System Cleanup classification is correct
- [ ] Sync confirmation works
- [ ] Sync confirmation button is normal Apple-blue
- [ ] progress represents real rsync progress
- [ ] progress never moves backwards
- [ ] detailed progress sheet streams output continuously
- [ ] Check can be stopped
- [ ] Sync can be stopped
- [ ] deliberate Stop is not reported as failure
- [ ] cancellation does not expose raw rsync code-255 error
- [ ] sleep prevention works during Sync
- [ ] sleep prevention is released after success
- [ ] sleep prevention is released after failure
- [ ] sleep prevention is released after cancellation
- [ ] automatic verification runs after Sync
- [ ] existing main-window layout is preserved
- [ ] existing progress-sheet design is preserved
- [ ] native traffic lights remain
- [ ] Swift 6 concurrency warnings are absent
- [ ] Xcode build is warning-free

---

# 27. Refactoring methodology

Refactor incrementally.

Do **not** rewrite the complete application in one pass.

Preferred sequence:

1. inspect the complete current project;
2. establish the actual current architecture;
3. map dependencies between Swift files/types;
4. compare implementation with this document;
5. inspect the preserved NFC/NFD checker/repair reference;
6. identify genuinely dead code;
7. perform small behavior-neutral cleanup;
8. build and verify;
9. introduce `SyncViewModel` incrementally;
10. build and regression-check again;
11. add unit tests;
12. only then consider further improvements.

The current working implementation is the source of truth for behavior.

This document provides project history, intent and architectural direction, but it may describe an earlier implementation detail that has since changed.

If the current project differs from this document:

**report the discrepancy first rather than automatically rewriting working code to match an outdated assumption.**

---

# 28. Development philosophy

MusiCards Sync should remain a **purpose-built tool rather than a Swiss Army knife**.

Do not add a feature merely because it is technically possible.

Complexity should live inside the implementation when necessary, not be transferred to the user as configuration.

The ideal experience is:

```text
Choose what to copy.

Choose where it goes.

Check what will happen.

Sync it.

See that it worked.
```

Or, in one sentence:

> **One source. One destination. Check first. Show exactly what will happen. Sync safely. Verify.**

The internal code should ultimately become as clear and purposeful as the application's external behavior.

---

# 29. First Codex task

Before changing any files:

1. Read this document completely.
2. Inspect the complete current Xcode project.
3. Inspect all Swift source files and project configuration relevant to the app.
4. Inspect any NFC/NFD checker/repair reference files in `Tools/`.
5. Produce a concise report containing:
   - current architecture;
   - responsibility of each important source file/type;
   - dependency relationships;
   - genuinely dead or duplicated code;
   - current NFC/NFD implementation status;
   - discrepancies between this document and the actual project;
   - Swift 6/concurrency concerns;
   - recommended incremental refactoring sequence.
6. **Do not modify any project files yet.**

The project is currently working.

Understand it first; refactor it second.
