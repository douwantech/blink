# Blink config server

Go HTTP service for Alibaba Cloud FC (custom container, port `9000`) and RDS MySQL 8. The public endpoint must use HTTPS. The server has no background workers; each request finishes its database work before responding.

## Setup

Set these in FC environment variables or its secret manager:

- `BLINK_MYSQL_DSN`: MySQL driver DSN, for example `user:password@tcp(rds-host:3306)/blink?parseTime=true&loc=UTC&tls=true`. Use an RDS user restricted to the Blink database and require TLS.
- `BLINK_BOOTSTRAP_USER` and `BLINK_BOOTSTRAP_PASSWORD`: first administrator, created only when the username does not already exist. Password must have at least 12 characters. Remove these variables after first successful deployment.
- `PORT`: optional; defaults to `9000`.

The server creates its tables at startup from `schema.sql`. Create the empty `blink` database and grant its RDS user schema and data permissions before starting it. Keep all credentials out of Git. Set FC concurrency, memory, database access, HTTPS custom domain, and DNS in the cloud account. No FC or RDS resources are created by this repository.

For local development, set the environment variables in your shell or an ignored secret store, then run `go run .`. Build the FC image with `docker build -t blink-config .` and push it to the chosen registry.

## API v1

All JSON uses UTF-8. Authenticated requests send `Authorization: Bearer <token>`. Tokens are random 32-byte values, valid for 30 days; only their SHA-256 hashes are stored in MySQL. Disabling a user blocks their token immediately. Resetting a password or disabling an account deletes its sessions.

| Method | Path | Access | Purpose |
| --- | --- | --- | --- |
| POST | `/v1/login` | Public | `{ "username": "...", "password": "..." }` → token, expiry, user |
| POST | `/v1/logout` | Signed in | Revoke current session |
| GET | `/v1/config?version=G:U` | Signed in | Full snapshot or `304` if current |
| PUT | `/v1/machines/{id}` | Admin with `canWrite` | Create or replace a machine |
| DELETE | `/v1/machines/{id}` | Admin with `canWrite` | Remove a machine |
| PUT | `/v1/config/tabs` | Admin with `canWrite` | Replace own tab state |
| PUT | `/v1/config/selection` | Admin with `canWrite` | Replace own recent selection |
| PUT | `/v1/config/agents` | Admin with `canWrite` | Replace own agent map |
| POST | `/v1/admin/users` | Admin | Create account |
| PATCH | `/v1/admin/users/{id}` | Admin | Change `password`, `disabled`, `isAdmin`, `canWrite` |

`GET /v1/config` returns `{version, machines, tabs, recentSelection, agents, user}`. `machines` use `BlinkMachine`'s Codable field names (`id`, `name`, `host`, `user`, `transport`, `blinkdHost`, `blinkdPort`, `blinkdToken`, `rustdeskId`, `rustdeskPassword`, etc.), plus `position` for ordering. The server sends the connection tokens to every signed-in employee as required by #29; clients must keep cached snapshots in protected storage and avoid logging them. `tabs` uses the existing `TabState` JSON shape. `agents` maps the existing `machineId|title` key to `claude`, `codex`, or `deepseek`. `recentSelection` is an object reserved for the client's current machine/tab IDs. Empty accounts receive empty defaults.

`version` combines the shared machine revision and the signed-in account's revision. Pass the last version on the next request; `304` means the cached snapshot is still current. Any machine change increments the shared revision. Tab, selection, or agent changes increment only that user's revision. Clients should treat the full snapshot as authoritative and cache it for offline read-only use.

Only admins with `canWrite=true` can change configuration. Admins can manage accounts even when `canWrite=false`. Non-admins have read-only access. The API does not currently support editing another user's personal tab state; the administrator can set up a user's state on that user's client after signing in.

## Deployment prerequisites

Laoda needs to provision the FC function, RDS MySQL database and user, DNS and HTTPS certificate for `blink-api.douwantech.com`, and secret values. Do not put any secret value in the PR or issue.
