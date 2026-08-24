# Bundled rsync provenance

MusiCards Sync bundles rsync because its synchronization workflows require a
known rsync version with iconv and secluded-args support. It is distributed as
a separate executable component; this document does not relicense the Swift
application.

## Component

- Upstream project: rsync — https://rsync.samba.org/
- Upstream release: 3.5.0
- License: GNU GPLv3; see [`COPYING`](COPYING)
- Attribution: Andrew Tridgell, Wayne Davison, and other rsync contributors
- Final executable: `ThirdParty/rsync/rsync`
- Final architecture: arm64 only
- Deployment target: macOS 26.0
- SHA-256: `f7c094851eca6ef0d5254eb272340b5429b9efd8cf7afaf373312c9f8b2b320d`

## Corresponding source

The official rsync 3.5.0 release archive is preserved at
[`source/rsync-3.5.0.tar.gz`](source/rsync-3.5.0.tar.gz), with SHA-256:

`c7ffd1ef653e99540f661e47cb00b7f9cad1ee6b972399b16f93d672656e0d33`

The extracted upstream source is retained beside the archive for inspection.
`COPYING` is copied verbatim from that archive. **No source patches were
applied.**

## Build procedure

Run [`build-rsync.sh`](build-rsync.sh) from the repository checkout. The script
verifies the archive checksum, extracts it into a fresh temporary directory,
and uses the Apple/Xcode toolchain without network access or package managers:

```text
MACOSX_DEPLOYMENT_TARGET=26.0
CC=$(xcrun --find clang)
CFLAGS="-arch arm64 -mmacosx-version-min=26.0 -isysroot $(xcrun --sdk macosx --show-sdk-path)"
LDFLAGS="$CFLAGS"
./configure --disable-openssl --disable-xxhash --disable-lz4 --disable-zstd
make -j1
```

The script pins the system `getaddrinfo` feature probe because macOS provides
the required implementation and the upstream fallback source is not needed.
It builds and links the bundled `popt` and `zlib` implementations from the
preserved source distribution, and links iconv from the macOS SDK. The serial
build avoids a race in the upstream generated compatibility sources. Their
license/notice text is preserved in [`licenses/popt-COPYING`](licenses/popt-COPYING)
and [`licenses/zlib-LICENSE`](licenses/zlib-LICENSE).

The recorded build environment for the verified build was:

- Xcode 26.6 (17F113)
- Apple clang 21.0.0 (clang-2100.1.1.101)
- macOS 26.6.2 (25G83)
- host architecture arm64

These records describe this build; they do not claim bit-for-bit
reproducibility across arbitrary future toolchains.

The rebuilt executable reports rsync 3.5.0 with iconv and optional
secluded-args. Its dependencies are `/usr/lib/libiconv.2.dylib`,
`/usr/lib/libSystem.B.dylib`, and `/usr/lib/libcharset.1.dylib` only.

## Patch 4 handoff

The eventual distribution must include this license/notice material and the
corresponding-source archive plus this build/provenance record when shipping
the bundled rsync executable. The DMG itself is intentionally not created in
Patch 3.1.
