# PROMOTIONS — dev → test ledger

Every promotion of code into the `test` branch gets one row BEFORE Ofek pushes. Rules live in
`DaraReports/ENV_AND_PIPELINE_2026-07-23.md` §4: cherry-pick squash-commits only, migrations in
order + paired dump, test ⊆ dev, no test-only commits.

| Date | Feature | Commit(s) cherry-picked (dev → test) | Validated by | Gates | Dump paired | Deployed |
|---|---|---|---|---|---|---|
| 2026-07-21 | TLS: RSA cert key type (Caddy) | `c001319` → `0f97a84` *(pre-ledger, grandfathered)* | Ofek (team TLS failure) | manual TLS handshake ×4 hosts | no (Caddyfile only) | ✓ 07-21 |
| 2026-07-21 | Deals page defaults יד ראשונה | `ed7dfd9`-equivalent → `7c14fe1` *(pre-ledger, grandfathered)* | Ofek (team request) | served-bundle check | no | ✓ 07-21 |
| 2026-07-23 | Env chip (env · git sha · data date) — first ledgered promotion | BE `4532676`+`77b5b28` → `346e7af`+`ee7c197` · UI `dc3c5d1`+`ca6d45d` → `2812fc0`+`1ace0e5` | Ofek ("we cherry pick to test", chip = his env feature) | BE test_health 10/10 on test tree · UI vitest 12/12 + tsc clean | no (migration-free; test data untouched per blessed-dump rule) | pending deploy |
