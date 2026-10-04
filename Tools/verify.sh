#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"

cd "$repository_root"

run_step() {
    local description="$1"
    shift

    print "\n==> ${description}"
    "$@"
}

run_step \
    "Checking the Git diff for whitespace errors" \
    git diff HEAD --check

run_step \
    "Running MusiCards tests on macOS" \
    xcodebuild \
        -workspace "MusiCards.xcworkspace" \
        -scheme "MusiCards" \
        -destination "platform=macOS" \
        test \
        CODE_SIGNING_ALLOWED=NO

run_step \
    "Building MusiCards for iOS" \
    xcodebuild \
        -workspace "MusiCards.xcworkspace" \
        -scheme "MusiCards" \
        -destination "generic/platform=iOS" \
        build \
        CODE_SIGNING_ALLOWED=NO

run_step \
    "Running MusiCards Sync tests on macOS" \
    xcodebuild \
        -workspace "MusiCards.xcworkspace" \
        -scheme "MusiCards Sync" \
        -destination "platform=macOS" \
        test \
        CODE_SIGNING_ALLOWED=NO

print "\nAll verification steps passed."
