The SSH packet, transport, and crypto implementation in `SshBytes.ets`,
`SshCrypto.ets`, and `SshSession.ets` is adapted from TermArk by Lev
(https://gitcode.com/leveleven/TermArk), MIT licensed. The license is in
`LICENSE`. Blink adds HUKS-backed Ed25519 user authentication, host-key
confirmation and pinning, and the terminal adapter.
