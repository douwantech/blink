# Voice configuration server plan

老板确认的配置边界：

- 共享 AI 配置：全局一份，包含固定 `userGlossary`，由服务端提供统一读写 API；App 所有账号读取同一份。
- 账号语音纠正列表：错词→正词学习数据按登录账号隔离，由服务端提供列表/读写 API；App 只拉当前账号的数据。

## Schema

- Extend the shared config store with one global JSON AI configuration document, including `userGlossary`.
- Add an account-scoped voice corrections JSON document keyed by the authenticated `user_id`, following `tabs`/`agents` isolation.
- Both writes increment the corresponding config version so clients can use the existing version/304 flow.

## API

- Authenticated shared AI config read/write endpoints.
- Authenticated current-account voice corrections list/read/write endpoints; no client-supplied account id.
- Unauthenticated requests return 403.

## App changes

- Fetch the shared AI configuration for all users and use its `userGlossary` in voice polishing.
- Fetch and apply the current account voice correction list; scope it to the active account on account changes.
- Preserve voice processing behavior with an offline fallback when the server cannot be reached.

## Verification

- Two authenticated accounts cannot read or write each other’s voice corrections.
- Unauthenticated API requests return 403.
- Shared AI configuration is identical for authenticated accounts.
- Successful writes increment the relevant config version.
- The App voice flow consumes the fetched shared glossary and current-account corrections.
