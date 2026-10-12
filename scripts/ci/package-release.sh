#!/bin/sh
set -eu

platform=$1
root=$(pwd -P)
staging=$(mktemp -d /tmp/skyext-release.XXXXXX)
trap 'rm -rf "$staging"' EXIT

mkdir -p release-assets
rsync -a \
    --exclude='.git*' \
    --exclude='.github' \
    --exclude='build-output' \
    --exclude='release-assets' \
    ./ "$staging/"
(cd "$staging" && zip -qr "$root/release-assets/skyext-$platform.zip" .)
