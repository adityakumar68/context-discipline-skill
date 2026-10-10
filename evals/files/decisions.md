# Decisions: auth refactor (session-token service), 2026-10-08

1. Replace cookie sessions with short-lived JWT access tokens (15 min) + rotating refresh tokens (30 days). User OK'd.
2. Refresh tokens stored hashed (argon2id) in Postgres table `refresh_tokens`; one row per device.
3. Token signing: Ed25519, keys rotated monthly, old key kept 2 weeks for verification.
4. Logout = revoke the device's refresh token; "log out everywhere" revokes all rows for the user.
5. Migration: dual-read for 2 weeks (accept old cookie sessions and new tokens), then remove cookies.
6. Out of scope: SSO/OAuth providers, MFA changes.
Context brief for the codebase: notes/auth-context-brief.md (interfaces of `auth/session.py`, `api/middleware.py`).
