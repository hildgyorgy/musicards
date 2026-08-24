#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_ARCHIVE="$ROOT_DIR/ThirdParty/rsync/source/rsync-3.5.0.tar.gz"
OUTPUT="$ROOT_DIR/ThirdParty/rsync/rsync"
EXPECTED_ARCHIVE_SHA256="c7ffd1ef653e99540f661e47cb00b7f9cad1ee6b972399b16f93d672656e0d33"
DEPLOYMENT_TARGET="26.0"

command -v xcrun >/dev/null
command -v tar >/dev/null
command -v shasum >/dev/null
command -v make >/dev/null
command -v lipo >/dev/null
command -v otool >/dev/null

[[ -f "$SOURCE_ARCHIVE" ]]
actual_sha256="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_ARCHIVE_SHA256" ]]; then
    echo "Source archive checksum mismatch: $actual_sha256" >&2
    exit 1
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
clang_path="$(xcrun --find clang)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/musicards-rsync-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT

tar -xzf "$SOURCE_ARCHIVE" -C "$build_root"
source_dir="$build_root/rsync-3.5.0"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CC="$clang_path"
export CFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $sdk_path"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $sdk_path"
export ac_cv_func_getaddrinfo=yes
export rsync_cv_HAVE_GETADDR_DEFINES=yes

(
    cd "$source_dir"
    ./configure \
        --disable-openssl \
        --disable-xxhash \
        --disable-lz4 \
        --disable-zstd
    # The upstream make graph generates compatibility sources; a serial build
    # avoids racing those generated headers on a clean extraction.
    make -j1
)

built_binary="$source_dir/rsync"
[[ -x "$built_binary" ]]
[[ "$(lipo -info "$built_binary")" == *"arm64"* ]]
version_output="$("$built_binary" --version)"
grep -Fq "rsync  version 3.5.0" <<<"$version_output"
grep -Fq "iconv" <<<"$version_output"
grep -Fq "secluded-args" <<<"$version_output"

if otool -L "$built_binary" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// { found = 1 } END { exit found }'; then
    :
else
    echo "Built rsync has a non-system dylib dependency" >&2
    exit 1
fi

temporary_output="$OUTPUT.tmp"
cp "$built_binary" "$temporary_output"
chmod 755 "$temporary_output"
mv "$temporary_output" "$OUTPUT"

echo "Built $OUTPUT"
echo "Source archive SHA-256: $actual_sha256"
echo "Output SHA-256: $(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
echo "Toolchain: $clang_path"
echo "SDK: $sdk_path"
echo "Deployment target: $DEPLOYMENT_TARGET"
