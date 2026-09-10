# Stockpile identity API

The server behind Stockpile's sign-in, accounts, roles and audit trail. It owns
**identity only** — users, sessions, permissions, invitations, audit records.
The inventory itself stays in the drift/SQLite database on each device, exactly
as it did before, so the app still opens and works offline.

Dart, `shelf`, drift over PostgreSQL. It compiles to a single binary.

## Why this shape

**Dart, not a second language.** The whole app is Dart and the SDK is already
installed. drift is already the data layer, so the schema, migrations and query
style match what the Flutter side does — and drift's typed queries mean SQL
injection is impossible by construction rather than by discipline.

**Opaque tokens, not JWT.** A session token is 32 random bytes; the database
holds only a SHA-256 fingerprint of it. That costs one indexed lookup per
request, which a JWT would avoid — but a JWT cannot be revoked. Signing out,
"sign out everywhere", an administrator revoking a device, and the forced
sign-out after a password change all need revocation that takes effect on the
*next* request. Paying an indexed lookup is the right side of that trade.

**Argon2id for passwords, SHA-256 for tokens.** Passwords are low-entropy and
guessable, so they get a memory-hard KDF (19 MiB, t=2, p=1 — OWASP's
configuration). Session tokens are 256 bits of uniform randomness, so there is
no dictionary to slow down and a fast hash is correct.

## Running it

```bash
cd server
cp .env.example .env          # then fill it in
dart pub get
createdb stockpile_auth       # the schema is created on first boot

dart run bin/generate_secret.dart      # → paste into TOKEN_PEPPER
dart run bin/create_admin.dart --email you@example.com --name "Your Name"
dart run bin/server.dart

dart test                     # 126 tests, against a real PostgreSQL
dart analyze
```

`dart test` needs a database of its own:

```bash
createdb stockpile_auth_test
# or point it elsewhere:
TEST_DATABASE_URL=postgres://user:pass@host:5432/db dart test
```

> On this machine `xcode-select -p` points at a directory that no longer
> exists, which breaks the toolchain even for `dart test`. Prefix commands with
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or fix it once
> with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

Point the app at it:

```bash
flutter run -d chrome --dart-define=STOCKPILE_API_URL=http://localhost:8080
flutter build web --release --dart-define=STOCKPILE_API_URL=https://api.example.com
```

The URL is compile-time on purpose: a release build cannot be redirected at
another server by editing a file next to it.

## Creating the first administrator

```bash
dart run bin/create_admin.dart --email you@example.com --name "Your Name"
```

It creates a **pending account with no password** and prints a single-use
invitation link, which is also emailed when SMTP is configured. No password is
ever typed on a command line or left in shell history. It refuses to run once
an administrator exists; `--force` overrides that.

### Recovering a locked-out administrator

There is no back door, by design. In order of preference:

1. **Another administrator** resets them from Users → the person → *Send a
   password reset*.
2. **A brute-force lockout** clears itself after `LOCKOUT_MINUTES`. An
   administrator can also lift it immediately with *Unlock now*.
3. **Nobody can get in.** Deactivate the stranded account directly, then
   bootstrap a fresh one:

   ```sql
   UPDATE users SET deleted_at = now() WHERE email = 'locked-out@example.com';
   ```

   ```bash
   dart run bin/create_admin.dart --email you@example.com --name "Your Name" --force
   ```

   The soft delete frees the address, so the same one can be re-invited.

## Configuration

Every variable is documented in `.env.example`. `.env` is gitignored; the
template is not, so never put a real secret in it. Values in the real process
environment always beat the file.

The security-relevant ones:

| Variable | Why it matters |
|---|---|
| `TOKEN_PEPPER` | Mixed into every token hash and kept out of the database, so a stolen dump alone cannot be used to forge a session. **Required in production**, ≥32 chars. Changing it signs everyone out and voids outstanding links. |
| `APP_URL` | Every emailed link is built from this, never from a request header — a spoofed `Host` therefore cannot aim a password-reset link at an attacker's domain. Must be `https://` in production. |
| `CORS_ORIGINS` | Exact origins allowed from a browser. There is no wildcard. |
| `TRUST_PROXY_HEADERS` | Only `true` when a proxy you control sets `X-Forwarded-For`. Otherwise a client can spoof its own IP and walk past the per-IP throttle. |
| `ACCESS_TOKEN_TTL_MINUTES` | How long a leaked access token stays useful. Default 15. |
| `MAX_FAILED_LOGINS` / `LOCKOUT_MINUTES` | Lockout threshold and duration. The lock always expires by itself. |

In production the server **refuses to start** without `TOKEN_PEPPER`, without
`EMAIL_HOST`, or with a non-https `APP_URL`. A misconfigured server should not
run insecurely; it should not run.

## Email

`EMAIL_HOST` empty means mail is logged rather than sent, and the log records
**only the recipient and subject** — never the link, because that is a secret.
The invite endpoint returns the invitation URL directly in that mode so a fresh
clone can complete the flow.

Prove the mail path before trusting it:

```bash
dart run tool/send_test_email.dart you@example.com
```

That sends one message through the configured transport and prints the failure
if there is one. Worth running on every deployment: a silent mail failure means
nobody can reset a password, and you will find out from a user rather than from
a log.

### Gmail and Google Workspace

```
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_SSL=false
EMAIL_USERNAME=you@yourdomain.com
EMAIL_PASSWORD=<16-character app password>
EMAIL_FROM=Stockpile <you@yourdomain.com>
```

Three things that catch people out:

- The password must be an **app password**, generated at
  [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).
  With 2-step verification on, Google refuses the account password for SMTP.
  It is displayed as four groups of four; the spaces are cosmetic.
- Port **587 is STARTTLS**, so `EMAIL_SSL=false`. Use `true` only for 465,
  which some networks block outbound.
- Keep `EMAIL_FROM` on the same address as `EMAIL_USERNAME`. Gmail rewrites the
  From header to the authenticated account regardless, so a mismatch only makes
  the configuration lie about what it sends.

Password reset cannot be completed without a mail path, since nothing else ever
reveals that token. For local development, run a catcher:

```bash
docker run -d -p 1025:1025 -p 8025:8025 axllent/mailpit
# EMAIL_HOST=localhost  EMAIL_PORT=1025  EMAIL_ALLOW_INSECURE=true
```

Messages sent: invitation, email verification, email-change confirmation (to
the new address) and notice (to the old), password reset, password changed,
new sign-in from an unrecognised device, account locked, account disabled,
account restored, admin-initiated reset.

## Database

Eleven tables, created on first boot and migrated by drift.

| Table | Holds |
|---|---|
| `users` | Accounts. `password_hash` is null until an invitation is claimed. `session_epoch` invalidates every session at once. `deleted_at` is a soft delete. |
| `roles`, `permissions` | The catalogue. System roles are re-synced from code on every boot. |
| `user_roles`, `role_permissions` | Grants. |
| `user_permissions` | Per-user overrides, including explicit **denials** that beat a role grant. |
| `sessions` | One signed-in device. Only token *fingerprints*. `rotated_to_session_id` detects refresh replay. |
| `auth_tokens` | Invitation, reset, verification and email-change links. Hashed, single-use, expiring. |
| `login_attempts` | Every attempt, for the lockout and the user's own activity list. |
| `audit_logs` | The security trail. Append-only by convention; no endpoint edits or deletes. |
| `notification_preferences` | Opt-outs for *application* mail only. |

Notable indexes: a **partial** unique index on `users(email) WHERE deleted_at IS
NULL`, so a deactivated account releases its address; unique indexes on every
token fingerprint, which is the hot path for authenticating a request; and
`audit_logs(created_at DESC, id)`, because rows written in the same microsecond
would otherwise page unstably.

Nothing is stored in plaintext that should not be: no passwords, no session
tokens, no link tokens.

## API

Errors are always `{"error":{"code","message","details?}}`. The `message` is
already phrased for a person; the `code` is what a client branches on. Nothing
else ever reaches a client — an unexpected exception becomes a bare 500.

### Public

| Method | Path | Notes |
|---|---|---|
| `POST` | `/auth/login` | Returns the user and a token pair. |
| `POST` | `/auth/refresh` | Rotates the pair. Replay kills every session. |
| `POST` | `/auth/forgot-password` | Always the same 200, whatever the address. |
| `POST` | `/auth/reset-password` | Single-use token. |
| `GET` | `/auth/invitation?token=` | Name and address only, so the accept page can greet. |
| `POST` | `/auth/accept-invitation` | Sets the password, activates, marks verified. |
| `POST` | `/auth/verify-email` | |
| `POST` | `/auth/resend-verification` | Generic response; capped at 3 per 15 min. |
| `POST` | `/account/public/verify-email-change` | Followed from the new mailbox. |
| `GET` | `/health` | Says nothing about the stack. |

### Authenticated

| Method | Path | Permission |
|---|---|---|
| `GET` | `/auth/session/me` | — |
| `POST` | `/auth/session/logout` | — |
| `POST` | `/auth/session/logout-all` | — |
| `POST` | `/auth/session/change-password` | — (issues a replacement session for this device) |
| `PATCH` | `/account/profile` | — |
| `POST` | `/account/email` | — (needs the current password) |
| `GET`/`DELETE` | `/account/sessions[/:id]` | — (own sessions only) |
| `GET` | `/account/activity` | — |
| `GET`/`PATCH` | `/account/notifications` | — |
| `GET` | `/users` | `users.view` |
| `POST` | `/users` | `users.create` |
| `GET` | `/users/:id` | `users.view` |
| `PATCH` | `/users/:id` | `users.update` |
| `PATCH` | `/users/:id/status` | `users.disable` |
| `PATCH` | `/users/:id/roles` | `roles.manage` |
| `PATCH` | `/users/:id/permissions` | `roles.manage` |
| `POST` | `/users/:id/reset-password` | `users.reset_password` |
| `POST` | `/users/:id/unlock` | `users.update` |
| `POST` | `/users/:id/resend-invitation` | `users.create` |
| `DELETE` | `/users/:id/invitation` | `users.delete` |
| `DELETE` | `/users/:id` | `users.delete` (soft) |
| `DELETE` | `/users/:id/sessions/:sid` | `sessions.revoke` |
| `GET` | `/audit-logs`, `/audit-logs/actions` | `audit_logs.view` |

## Roles and permissions

Permissions — not roles — are what the API checks. A role is a named bundle,
so adding a capability means appending one entry to `lib/src/rbac/permissions.dart`
and granting it, not editing conditionals across handlers.

- **Administrator** — everything. Derived from the catalogue, so a new
  permission is granted automatically and the role can never drift into being
  unable to administer something.
- **Inventory Manager** — stock, purchasing, sales, partners, reports. Not
  users, settings or the audit trail.
- **Staff** — view, record stock movements, receive goods. No deletes, no
  pricing.

`user_permissions` grants or **denies** one permission to one person on top of
their role. Denial wins, so withholding a capability never means forking a role.

Two invariants the API enforces: the last active administrator cannot be
demoted, disabled or deactivated, and nobody can disable or deactivate their
own account.

## Security

- **Passwords** — Argon2id, PHC-encoded with its parameters, per-password salt.
  Hashes are upgraded transparently on sign-in when the defaults are raised.
  Never logged, never returned, never in an audit record.
- **Account enumeration** — sign-in answers identically for a wrong password and
  an unknown address, and spends the same time on both by verifying against a
  decoy hash. Forgot-password and resend-verification are always the same 200.
- **Brute force** — per-account lockout (time-bounded, self-healing, liftable by
  an admin), a per-IP sliding window in the database, an in-process flood guard,
  and a growing artificial delay after repeated failures. No mechanism can lock
  someone out permanently.
- **Sessions** — 15-minute access tokens, 30-day refresh tokens that rotate on
  every use with replay detection. A replayed token ends every session for that
  account. `session_epoch` kills them all in one write.
- **CSRF** — structurally inapplicable: tokens travel in an `Authorization`
  header, never a cookie, so there is nothing for a cross-site form post to ride.
- **XSS** — the API serves no HTML and sets `default-src 'none'`. On the web the
  client's token storage is reachable by any script in its origin; see
  `lib/data/token_storage.dart` for that trade-off in full.
- **CORS** — an explicit origin allowlist, echoed with `Vary: Origin`. No wildcard.
- **SQL injection** — every query is a typed drift expression.
- **Input** — bodies capped at 64 KB; `limit`/`offset` clamped rather than trusted.
- **Errors** — no stack trace, SQL message or path ever reaches a client.
- **Audit** — every security-relevant action, with a redaction list that strips
  credential-shaped fields even if a caller passes one by mistake.

## Deploying

```bash
dart compile exe bin/server.dart -o build/stockpile-server
```

Checklist:

- [ ] `APP_ENV=production` — turns on the strict configuration checks.
- [ ] `TOKEN_PEPPER` from `generate_secret.dart`, stored with your other secrets.
- [ ] `DATABASE_URL` over TLS. The server requires it in production.
- [ ] `APP_URL` and `CORS_ORIGINS` set to real https origins.
- [ ] `EMAIL_*` configured and **tested** — a silent mail failure means nobody
      can reset a password.
- [ ] `TRUST_PROXY_HEADERS=true` **only** behind a proxy that overwrites
      `X-Forwarded-For`.
- [ ] TLS terminated in front of the server.
- [ ] Back up PostgreSQL. It is the only copy of who may sign in.

The server runs housekeeping every six hours (expired sessions, spent tokens,
login attempts older than 90 days) and finishes in-flight requests on `SIGTERM`.

### Running more than one instance

Everything that matters is in the database and shared: lockouts, token issue
caps, sessions, the audit trail. The only per-instance piece is the in-process
flood guard in `rate_limiter.dart`, so the effective flood limit is the
configured limit times the instance count. Move it to Redis if that matters;
the durable protections do not change.
