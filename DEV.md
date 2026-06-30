# Dev environment — runbook

A single **Lightsail** box (~$5/mo, 1 GB) running the whole app via
docker-compose: **postgres + api + caddy** (no Ollama). Caddy serves the static
UI at `/` and proxies `/api/*` to the API on the **same origin**, so the UI
build (`NEXT_PUBLIC_API_URL=""`) works unchanged.

This is the cheap, always-on **dev** tier of the dev → staging → prod pipeline.
It is intentionally NOT the ECS/ALB/RDS staging architecture — **staging stays
the real integration gate**.

- IaC: `environments/dev/` (own state key `dev/terraform.tfstate`) + `modules/dev-box/`.
- App: `dara-v2/docker-compose.dev.yml` + `dara-v2/deploy/Caddyfile`.
- Scripts: `scripts/dev-deploy.sh` (code/UI/image) · `scripts/dev-seed.sh` (data).

## Create the box (once)
```sh
cd environments/dev
terraform init
terraform apply -var-file=terraform.tfvars      # ~2-3 min; creates Lightsail box + static IP
terraform output url                            # http://<static-ip>
```

## Deploy the current build
```sh
cd ..                       # repo root (rs-intelligence-infra)
./scripts/dev-deploy.sh     # builds UI + amd64 API image, ships them, docker compose up -d
./scripts/dev-seed.sh       # pg_dump local DB → restore on the box (deals/amenities/approvals)
```
Redeploy after code changes = re-run `dev-deploy.sh` (add `dev-seed.sh` only when
you want to refresh the data). The API entrypoint runs `alembic upgrade head` on
boot; the seed dump carries `alembic_version=0024`, so it stays a no-op.

## URL / DNS
Live at **https://54-195-65-131.sslip.io** (sslip.io resolves the embedded IP →
the static IP; Caddy auto-provisions a Let's Encrypt cert and redirects 80→443).
The hostname is derived from the static IP by `dev-deploy.sh` (`SITE_ADDRESS`),
so a recreate with a new IP just works. To use a branded domain instead: point
an A record at the static IP and set `SITE_ADDRESS=dev.yourdomain.com`.

## Smoke
```sh
SITE=54-195-65-131.sslip.io
curl https://$SITE/api/health
# open https://$SITE  → login smoke@dara.local / DaraDemo2026!  → /gush, /deals
```

## Stop paying (~$5/mo while up)
```sh
cd environments/dev && terraform destroy -var-file=terraform.tfvars
```
This removes the box + static IP. (There's no RDS/ALB/NAT to leak cost — the
only standing resource is the instance.) Re-create with `terraform apply` + the
two scripts.

## Notes / caveats
- **HTTP only on the IP** (no domain). To add HTTPS later: point a domain at the
  static IP and replace `:80` with the domain in `deploy/Caddyfile` (Caddy
  auto-provisions a cert).
- **Ollama dropped** → the LLM report-narrative endpoints don't work here; the
  deals / gush map / developer / amenities features (what's under test) do.
- **SSH key**: `terraform output -raw private_key_pem` is written to
  `dev_box_key.pem` by the scripts (gitignored — do not commit).
- Cost surface check: `aws lightsail get-instances` → one `micro_3_0`; no
  RDS/ALB/NAT/CloudFront created by this env.
