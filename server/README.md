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
| PUT | `/v1/machines/batch` | Admin with `canWrite` | Replace the ordered machine array in one transaction |
| DELETE | `/v1/machines/{id}` | Admin with `canWrite` | Remove a machine |
| PUT | `/v1/pinned/{id}` | Admin with `canWrite` | Create or replace one browser bookmark |
| PUT | `/v1/pinned/batch` | Admin with `canWrite` | Replace the ordered bookmark array in one transaction |
| DELETE | `/v1/pinned/{id}` | Admin with `canWrite` | Remove a browser bookmark |
| PUT | `/v1/config/tabs` | Signed in | Replace own tab state |
| PUT | `/v1/config/selection` | Signed in | Replace own recent selection |
| PUT | `/v1/config/agents` | Signed in | Replace own agent map |
| POST | `/v1/admin/users` | Admin | Create account |
| PATCH | `/v1/admin/users/{id}` | Admin | Change `password`, `disabled`, `isAdmin`, `canWrite` |

`GET /v1/config` returns `{version, machines, pinned, tabs, recentSelection, agents, user}`. `machines` use `BlinkMachine`'s Codable field names (`id`, `name`, `host`, `user`, `transport`, `blinkdHost`, `blinkdPort`, `blinkdToken`, `rustdeskId`, `rustdeskPassword`, etc.). Machine array order is authoritative; the SQL `position` column is internal and never added to client JSON. The server sends the connection tokens to every signed-in employee as required by #29; clients must keep cached snapshots in protected storage and avoid logging them. `tabs` uses the existing `TabState` JSON shape, with the global public tabs in front of the account's own (see [Public tabs](#public-tabs)). `agents` maps the existing `machineId|title` key to `claude`, `codex`, or `deepseek`. `recentSelection` is an object reserved for the client's current machine/tab IDs. Empty accounts receive empty defaults.

`pinned` is the shared browser bookmark list shown on the app's browser「后台」sidebar: `{id, title, url, authUser, authPassword}` entries in display order. It is global, not per-account — every signed-in employee receives the same list, so nobody has to enter bookmarks by hand. `authUser`/`authPassword` are an optional HTTP Basic pair and must be set together; blank means the site needs no credentials. Array order is authoritative (`position` stays internal, exactly like machines), `title` and an `http`/`https` `url` are required, and unknown fields are retained. Like machine tokens, these credentials reach every signed-in client, so clients must keep cached snapshots in protected storage and avoid logging them.

`version` combines the shared machine revision and the signed-in account's revision. Pass the last version on the next request; `304` means the cached snapshot is still current. Any machine, bookmark, or shared-directory change — including a project's `public` flag and employee list — increments the shared revision, because the public tabs are derived from that list and a client holding an older version would otherwise be told `304` forever. Tab, selection, or agent changes increment only that user's revision. Clients should treat the full snapshot as authoritative and cache it for offline read-only use.

Only admins with `canWrite=true` can change shared machines or shared bookmarks. Every signed-in user can update their own tabs, recent selection, and agent choices; these endpoints always use the authenticated user ID. Admins can manage accounts even when `canWrite=false`. Other users cannot edit machines or accounts.

Both `/v1/login` and `/admin/session` share a MySQL-backed limit of 10 attempts per username per five minutes across FC instances. Configure an additional IP-level limit at the FC/API gateway to cover floods of arbitrary usernames. The custom domain is HTTPS-only.

## Admin page

`/admin/login` is the public sign-in page. After an existing admin signs in, `/admin` shows shared machines, the employee and project directories, accounts, the global public tabs, and each account's own tabs with the employee and project each tab is linked to. Admins can maintain the directories, add a tab for an account, and close a tab for that account. The employee list carries a machine column derived from the project lists, so a name is never shown as a bare ID.

| Method | Path | Purpose |
| --- | --- | --- |
| PUT | `/admin/api/employees/{id}` | Create or replace an employee, `{"id":"jack","name":"Jack"}` |
| PUT | `/admin/api/employees/{id}/avatar` | Admin-only PNG upload (max 2 MiB) |
| GET | `/admin/api/employees/{id}/avatar` | Serve the avatar to the admin page's `<img>`, `404` when none is stored |
| DELETE | `/admin/api/employees/{id}` | Remove an employee |
| PUT | `/admin/api/projects/{id}` | Create or replace a project, `{"id":"huum","name":"Huum","public":true,"employees":[{"id":"jack","machineId":"mac-mini","workDir":"/Users/apple/Codes/jack"}]}` |
| DELETE | `/admin/api/projects/{id}` | Remove a project |

Both directories are org-wide and shared like `machines`, ordered by ID, and carry no position column. The path ID and the body `id` must match; IDs allow lowercase letters, digits, `.`, `_`, and `-` (max 60 characters, must start with a letter or digit) because an employee and a project ID are concatenated into a tmux session name that people type. Uppercase is rejected so two entries cannot differ only by case and produce two session names nobody can tell apart. Deleting an entry that tabs still reference is allowed: those tabs keep their session name, and the page falls back to showing the bare ID.

A project carries two more fields than an employee: `public` and `employees`, a list of `{"id":"jack","machineId":"mac-mini","workDir":"/Users/apple/Codes/jack"}`. The machine and optional absolute work directory sit on the employee/project pair because two employees on one project may run on different hosts and paths. Public tabs include that `workDir` in `/v1/config`; clients enter it before starting the CLI. Existing pairs without `workDir` keep the legacy directory fallback until configured in the admin page. `PUT /admin/api/projects/{id}` merges rather than replaces: `public` and `employees` are only written when the request names them, so a request that changes only the name cannot empty the employee list, and fields another writer added survive. An omitted field keeps its stored value; `PUT /admin/api/employees/{id}` cannot write a project at all, because it would drop those two fields.

Employee avatars use the existing RDS as the smallest deployment change: PNG bytes live in `employee_avatars` with a foreign key to `employees`, while the directory JSON carries only `/v1/employees/{id}/avatar`. Signed-in clients fetch that endpoint after login; the admin page uploads PNGs from the employee editor and shows the stored image as a 40px thumbnail in the 头像 column and in the edit dialog. This avoids adding OSS credentials or a second storage lifecycle, and employee deletion cascades to the blob. The thumbnail uses `GET /admin/api/employees/{id}/avatar` rather than the `/v1` endpoint: a browser `<img>` carries the admin session cookie, not a bearer token, and `/v1` would answer it `401`.

`POST /admin/api/users/{id}/tabs` accepts `{"machineId":"...","employeeId":"...","projectId":"..."}` — all three are required, must already exist, and the created tab's `tmuxSession` is `<employeeId>-<projectId>`. The `cc-` prefix belongs to the remote startup convention and is not part of this field. Adding the same employee, project, and machine twice for one account returns `409`. `DELETE /admin/api/users/{id}/tabs/{tabId}` closes one tab.

Each tab's employee and project live in the `tab_links` table, not inside the tab JSON: clients upload their whole `TabState` on sync and re-encoding drops fields they do not model, so link data stored in the tab entry would be erased by the account's next sync. `GET /admin/api/state` returns `links` per account keyed by tab ID, and closing a tab deletes its row.

### Public tabs

A project marked `public` turns its employee list into a global set of tabs: one per employee on the list, named `<employee>-<project>`, on that pair's machine. Every account sees the same set. `buildPublicTabView` in `admin_public.go` derives it from the project rows, `GET /admin/api/state` returns it as `publicTabs` (a flat array of `{projectId, projectName, employeeId, machineId, session, tabId}` in project then employee order, so the page never re-parses a session name), and the card is read-only — changing the list is how the set changes.

`GET /v1/config` puts the same tabs, as ordinary `TabEntry` objects, in front of the account's own and marks each with `"shared": true`. Deriving them at read time rather than storing them is what keeps a client from uploading them back: clients PUT their whole `TabState`, so a stored public tab would be re-adopted as the account's own and would linger after the project stopped being public. Two details follow from that:

- A public tab's ID is a UUIDv5 over the namespace `924f04d2-3134-500d-b88c-c008790adaac` (itself `uuid5(NAMESPACE_URL, "https://blink.douwantech.com/public-tab")`), the employee ID, and the project ID, so the same pair always gets the same ID on every account and on every server. A copy uploaded by a client therefore matches the derived one and is dropped from the account's own list instead of appearing twice, case-insensitively.
- The injected IDs are removed from `closedIds`, so an account that closed a public tab gets it back on the next sync. Public tabs are not closable per account.
- A stored tab whose ID is a public tab ID is dropped on the way out, and the stored `updatedAt` is preserved rather than refreshed: the read path must not look like a local edit.

`employeeMachines` in the same response maps each employee to the machines the public lists put them on, in project order and de-duplicated. Two entries mean the lists disagree about where that employee runs — the employee table shows both and says so; it is reporting only, never an error.

Because the tab set is derived, a project write or delete bumps the shared config version in the same transaction (`PUT`/`DELETE /admin/api/projects/{id}`). Without that bump an already-synced client would send its version back and be served `304` with the old tab set. Deleting an employee does not bump it — an employee row carries no tab on its own.

Adding or closing a tab updates only the target account's `user_configs` row and config revision. Closing a tab records its ID in `closedIds` so it stays closed during sync; a public tab cannot be closed that way, as above. Every `/admin` data or mutation endpoint checks a short-lived, HttpOnly, SameSite=Strict admin session cookie; non-admin accounts cannot enter. Machine editing still requires `canWrite`. The page also manages the shared browser bookmarks (the「后台书签」card): add, edit, reorder, and delete, with an optional authentication username/password per entry. Its API is `PUT`/`DELETE /admin/api/pinned/{id}`. Admin mutations require a same-origin-only custom request header. The HTML and JavaScript are embedded into the same Go binary and FC function; there is no separate web service.

The machine form includes a `notes` field. The API retains this and other unrecognized machine fields, so editing an existing machine does not discard newer client fields.

## Import an existing Mac snapshot

The Mac sync file `~/.blink/sync/blink_config.json` contains `machines`, `tabs`, `agents`, `pinned`, `currentId`, and `filterMachineId`. It also contains machine connection tokens. Obtain a copy through a private channel and keep it outside the repository. The import targets the account that signs in: the shared machine array is replaced transactionally in source order, while that account's tabs, agents, and recent selection are replaced. Re-running the import is safe for these same values, though it increments config versions again.

From `server/`, preview without credentials:

```sh
go run ./tools/import-config --input /private/path/blink_config.json
```

To apply, set `BLINK_IMPORT_USER` and `BLINK_IMPORT_PASSWORD` in the local shell or secret store, then run:

```sh
go run ./tools/import-config --input /private/path/blink_config.json --base-url https://blink-api.douwantech.com --apply
```

When the snapshot carries `pinned`, the tool also replaces the shared bookmark list (`PUT /v1/pinned/batch`), keeping source order. Bookmark ids are derived from each URL's host (a numeric suffix disambiguates entries on the same host), so re-running the import is idempotent instead of creating duplicates. Entries without a title take the host as their title and are reported in the preview, because the server requires a non-empty title. A snapshot without `pinned` leaves the shared bookmarks untouched.

The account must have both `isAdmin` and `canWrite`. The tool checks exact machine array order and JSON content, plus tabs, agents, and selection. It prints counts only, never IDs, token values, or passwords. If a request fails partway through, fix the cause and rerun it.

## Deployment prerequisites

Jack is provisioning the FC function, RDS MySQL database and user, DNS and HTTPS certificate for `blink-api.douwantech.com`, and secret values. Do not put any secret value in the PR or issue.
