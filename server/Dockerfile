# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
# Pinned to the SDK in server/pubspec.yaml. A floating `stable` would turn an
# unrelated Dart release into a surprise red build on an untouched commit.
FROM dart:3.12 AS build

WORKDIR /app

# Dependencies first, as their own layer: pubspec changes far less often than
# source, so an ordinary code change reuses the resolved package cache.
COPY server/pubspec.yaml server/pubspec.lock ./
RUN dart pub get

COPY server/ ./

# `--offline` proves the lockfile is complete: if the copied source needs a
# package the previous step did not fetch, this fails here rather than
# resolving something new and unpinned at build time.
RUN dart pub get --offline

# `dart build cli`, not `dart compile exe`: drift pulls in `sqlite3`, which
# declares build hooks, and `dart compile exe` refuses to run with those
# present. (The server itself never touches SQLite — it talks to PostgreSQL
# through drift_postgres — but the package is in the graph regardless.)
#
# Each command produces a self-contained bundle of `bin/<exe>` plus the shared
# libraries it needs in a sibling `lib/`, so the runtime image needs no Dart
# SDK at all — which is what keeps it under 100 MB rather than 600.
RUN dart build cli -t bin/server.dart -o /app/out/server \
 && dart build cli -t bin/migrate.dart -o /app/out/migrate \
 && dart build cli -t bin/create_admin.dart -o /app/out/create_admin \
 && dart build cli -t bin/repair_cancelled_sales.dart -o /app/out/repair_cancelled_sales \
 && dart build cli -t tool/send_test_email.dart -o /app/out/send_test_email

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# ca-certificates: the SMTP client verifies the mail host's TLS certificate.
# curl: the container healthcheck. Both are small and neither is optional —
# without certificates every password-reset email fails at TLS.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# An unprivileged user. Nothing this process does needs root, and a container
# that runs as root hands an RCE the whole filesystem.
RUN groupadd --system --gid 10001 stockpile \
 && useradd --system --uid 10001 --gid stockpile --no-create-home stockpile

WORKDIR /app
RUN mkdir -p /app/bin

# Each bundle keeps its executable beside the `lib/` it loads from, so they are
# copied whole rather than cherry-picking binaries.
COPY --from=build /app/out/server/bundle /app/server
COPY --from=build /app/out/migrate/bundle /app/migrate
COPY --from=build /app/out/create_admin/bundle /app/create_admin
COPY --from=build /app/out/repair_cancelled_sales/bundle /app/repair_cancelled_sales
# The mail diagnostic. It lives in tool/ rather than bin/ because it is not
# part of running the service — but a diagnostic that cannot be run where the
# problem is proves nothing, and the mail path only fails in deployment.
COPY --from=build /app/out/send_test_email/bundle /app/send_test_email

# Stable paths, so compose files and deploy scripts do not have to know about
# the bundle layout.
RUN ln -s /app/server/bin/server /app/bin/server \
 && ln -s /app/migrate/bin/migrate /app/bin/migrate \
 && ln -s /app/create_admin/bin/create_admin /app/bin/create_admin \
 && ln -s /app/repair_cancelled_sales/bin/repair_cancelled_sales /app/bin/repair_cancelled_sales \
 && ln -s /app/send_test_email/bin/send_test_email /app/bin/send_test_email

USER stockpile

ENV PORT=8080
EXPOSE 8080

# Hits the API's own health route rather than merely checking the port is
# open: the process can be listening while its database connection is gone,
# and a port check would call that healthy.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1

# Exec form, so the binary is PID 1 and receives SIGTERM directly. The server
# closes its listener and finishes in-flight requests on that signal; behind a
# shell it would never see it and every deploy would drop connections.
ENTRYPOINT ["/app/bin/server"]
