#!/bin/sh
# Build the image. Override the tag with IMAGE_TAG, e.g.
#   IMAGE_TAG=ghcr.io/pat-e/steam-gui-docker:latest ./build.sh
# Extra arguments are passed to `docker build` (e.g. --no-cache).
set -eu
cd "$(dirname "$0")"
IMAGE_TAG="${IMAGE_TAG:-steam-gui:local}"
exec docker build --pull -t "$IMAGE_TAG" "$@" .
