# PROMOTIONS — dev → test ledger

Every promotion of code into the `test` branch gets one row BEFORE Ofek pushes. Rules live in
`DaraReports/ENV_AND_PIPELINE_2026-07-23.md` §4: cherry-pick squash-commits only, migrations in
order + paired dump, test ⊆ dev, no test-only commits.

| Date | Feature | Commit(s) cherry-picked (dev → test) | Validated by | Gates | Dump paired | Deployed |
|---|---|---|---|---|---|---|
| 2026-07-21 | TLS: RSA cert key type (Caddy) | `c001319` → `0f97a84` *(pre-ledger, grandfathered)* | Ofek (team TLS failure) | manual TLS handshake ×4 hosts | no (Caddyfile only) | ✓ 07-21 |
| 2026-07-21 | Deals page defaults יד ראשונה | `ed7dfd9`-equivalent → `7c14fe1` *(pre-ledger, grandfathered)* | Ofek (team request) | served-bundle check | no | ✓ 07-21 |
