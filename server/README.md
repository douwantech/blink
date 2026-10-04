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
| PUT | `/v1/config/tabs` | Signed in | Replace own tab state |
| PUT | `/v1/config/selection` | Signed in | Replace own recent selection |
| PUT | `/v1/config/agents` | Signed in | Replace own agent map |
| POST | `/v1/admin/users` | Admin | Create account |
| PATCH | `/v1/admin/users/{id}` | Admin | Change `password`, `disabled`, `isAdmin`, `canWrite` |

`GET /v1/config` returns `{version, machines, tabs, recentSelection, agents, user}`. `machines` use `BlinkMachine`'s Codable field names (`id`, `name`, `host`, `user`, `transport`, `blinkdHost`, `blinkdPort`, `blinkdToken`, `rustdeskId`, `rustdeskPassword`, etc.), plus `position` for ordering. The server sends the connection tokens to every signed-in employee as required by #29; clients must keep cached snapshots in protected storage and avoid logging them. `tabs` uses the existing `TabState` JSON shape. `agents` maps the existing `machineId|title` key to `claude`, `codex`, or `deepseek`. `recentSelection` is an object reserved for the client's current machine/tab IDs. Empty accounts receive empty defaults.

`version` combines the shared machine revision and the signed-in account's revision. Pass the last version on the next request; `304` means the cached snapshot is still current. Any machine change increments the shared revision. Tab, selection, or agent changes increment only that user's revision. Clients should treat the full snapshot as authoritative and cache it for offline read-only use.

Only admins with `canWrite=true` can change shared machines. Every signed-in user can update their own tabs, recent selection, and agent choices; these endpoints always use the authenticated user ID. Admins can manage accounts even when `canWrite=false`. Other users cannot edit machines or accounts.

Both `/v1/login` and `/admin/session` share a MySQL-backed limit of 10 attempts per username per five minutes across FC instances. Configure an additional IP-level limit at the FC/API gateway to cover floods of arbitrary usernames. The custom domain is HTTPS-only.

## Admin page

`/admin/login` is the public sign-in page. After an existing admin signs in, `/admin` shows shared machines, accounts, and read-only personal tabs/recent selections. Every `/admin` data or mutation endpoint checks a short-lived, HttpOnly, SameSite=Strict admin session cookie; non-admin accounts cannot enter. Machine editing still requires `canWrite`. Admin mutations require a same-origin-only custom request header. The HTML and JavaScript are embedded into the same Go binary and FC function; there is no separate web service.

The machine form includes a `notes` field. The API retains this and other unrecognized machine fields, so editing an existing machine does not discard newer client fields.

## Import an existing Mac snapshot

The Mac sync file `~/.blink/sync/blink_config.json` contains `machines`, `tabs`, `agents`, `currentId`, and `filterMachineId`. It also contains machine connection tokens. Obtain a copy through a private channel and keep it outside the repository. The import targets the account that signs in: shared machines are upserted, while that account's tabs, agents, and recent selection are replaced. The tool does not delete machines already on the server; compare IDs before import if the shared library is already populated. Re-running the import is safe for these same values, though it increments config versions again.

From `server/`, preview without credentials:

```sh
go run ./tools/import-config --input /private/path/blink_config.json
```

To apply, set `BLINK_IMPORT_USER` and `BLINK_IMPORT_PASSWORD` in the local shell or secret store, then run:

```sh
go run ./tools/import-config --input /private/path/blink_config.json --base-url https://blink-api.douwantech.com --apply
```

The account must have both `isAdmin` and `canWrite`. The tool checks that every source machine ID appears in the resulting snapshot and that tabs, agents, and selection match. It prints counts and machine IDs, never token values or passwords. If a request fails partway through, fix the cause and rerun it.

## Deployment prerequisites

Jack is provisioning the FC function, RDS MySQL database and user, DNS and HTTPS certificate for `blink-api.douwantech.com`, and secret values. Do not put any secret value in the PR or issue.
