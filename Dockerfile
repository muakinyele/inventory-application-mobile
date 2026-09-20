# syntax=docker/dockerfile:1
#
# The Flutter web client, served by nginx, which also reverse-proxies the API.
# The API lives in server/Dockerfile.

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
# Pinned to amd64: Flutter publishes the Linux SDK for x64 only (the release
# manifest lists no arm64 archive for this version), so an arm64 builder would
# unpack x86 binaries and fail under emulation. This stage emits HTML, JS and
# wasm — no native code — so the runtime stage below is free to be whatever
# the target platform is. On an arm64 developer machine this stage runs under
# emulation and is slow; in CI it is native.
FROM --platform=linux/amd64 debian:bookworm-slim AS build

# The SDK is installed rather than taken from a community Flutter image
# because the project pins 3.44.1 (.metadata, and the CI workflow), and the
# widely used ghcr.io/cirruslabs/flutter images do not publish that tag.
# Building against a different SDK than CI checks is how "works on my machine"
# gets into a release.
ARG FLUTTER_VERSION=3.44.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
 && tar -xJf /tmp/flutter.tar.xz -C /opt \
 && rm /tmp/flutter.tar.xz

ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

# Flutter refuses to run in a repository it does not own, and the SDK was
# unpacked as root while the build may not be.
RUN git config --global --add safe.directory /opt/flutter \
 && flutter --version

WORKDIR /app

# Dependencies as their own layer, for the same reason as the API image.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# Relative, not absolute. nginx serves this bundle and proxies /api to the API
# container, so the client calls its own origin — which means one image is
# valid in development, staging and production, and CORS never enters into it.
# An absolute URL would bake an environment into the image.
ARG API_BASE_URL=/api

# ICONS ARE TREE-SHAKEN, which this build previously turned off. The flag cost
# 1.6 MB on every cold visit: the full MaterialIcons face is 1,645,184 bytes and
# the icons this app actually names come to 24,668 — a 98.5% reduction, and the
# second largest thing the browser was being asked to download after the engine
# itself. Nothing here builds an IconData at runtime, which is the one case
# tree-shaking cannot see through and the only reason to disable it; the
# analyzer's own check for that is what makes the build fail rather than ship
# blank squares. CupertinoIcons is warned about and is not a dependency of this
# project, so those glyphs were never in the bundle with the flag either.
RUN flutter build web --release \
      --dart-define=STOCKPILE_API_URL="${API_BASE_URL}"

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM nginx:1.27-alpine AS runtime

# The stock image ships a default site that would otherwise answer on / and
# shadow the app.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY docker/nginx/app.conf.template /etc/nginx/templates/app.conf.template
COPY --from=build /app/build/web /usr/share/nginx/html

# nginx's own entrypoint renders anything in /etc/nginx/templates through
# envsubst, so the API upstream is chosen at *start* time. That is what keeps
# the image environment-agnostic.
ENV API_UPSTREAM=http://api:8080 \
    DNS_RESOLVER=127.0.0.11

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null 2>&1 || exit 1
