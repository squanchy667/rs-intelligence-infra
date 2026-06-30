#!/usr/bin/env bash
# Deploy the current code to the Lightsail dev box (artifact-push model):
# build the UI static export + the amd64 API image locally, ship them + the
# compose/Caddy files to the box, and `docker compose up -d`.
#
# Prereqs: terraform applied in environments/dev; docker buildx; npm.
# Usage:   scripts/dev-deploy.sh
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$INFRA_DIR/.." && pwd)"
BE="$ROOT/dara-v2"
UI="$ROOT/dara-v2-ui"
DEV_TF="$INFRA_DIR/environments/dev"
KEY="$INFRA_DIR/dev_box_key.pem"
IMG_TAR="/tmp/dara-api-dev.tar.gz"

echo "==> Reading terraform outputs"
IP="$(terraform -chdir="$DEV_TF" output -raw static_ip)"
terraform -chdir="$DEV_TF" output -raw private_key_pem > "$KEY"
chmod 600 "$KEY"
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
# Public hostname via sslip.io (resolves to the IP) → Caddy auto-HTTPS. The IP is
# static, so this is stable; recompute on each deploy so a recreate just works.
SITE_HOST="${IP//./-}.sslip.io"
echo "    box = $IP   host = $SITE_HOST"

echo "==> Building UI static export (NEXT_PUBLIC_API_URL='' → same-origin /api/)"
( cd "$UI" && NEXT_PUBLIC_API_URL="" npm run build )

echo "==> Building API image (linux/amd64) and saving"
( cd "$BE" && docker buildx build --platform linux/amd64 -t dara-api:dev --load . )
docker save dara-api:dev | gzip > "$IMG_TAR"

echo "==> Waiting for cloud-init (docker install) on the box"
for i in $(seq 1 60); do
  if $SSH ubuntu@"$IP" 'test -f /opt/dara/.cloud-init-done' 2>/dev/null; then break; fi
  sleep 5
done

echo "==> Shipping artifacts"
$SSH ubuntu@"$IP" 'mkdir -p /opt/dara/out'
rsync -az -e "$SSH" --delete "$UI/out/" ubuntu@"$IP":/opt/dara/out/
rsync -az -e "$SSH" "$BE/docker-compose.dev.yml" ubuntu@"$IP":/opt/dara/docker-compose.yml
rsync -az -e "$SSH" "$BE/deploy/Caddyfile" ubuntu@"$IP":/opt/dara/Caddyfile
rsync -az -e "$SSH" "$IMG_TAR" ubuntu@"$IP":/opt/dara/dara-api-dev.tar.gz

echo "==> Loading image + starting stack on the box (SITE_ADDRESS=$SITE_HOST → auto-HTTPS)"
$SSH ubuntu@"$IP" "cd /opt/dara && gunzip -c dara-api-dev.tar.gz | docker load && SITE_ADDRESS='$SITE_HOST' docker compose up -d"

echo "==> Smoke: /api/health (HTTPS may take ~10-30s on first cert issuance)"
sleep 15
curl -fsS "https://$SITE_HOST/api/health" && echo "" \
  || curl -fsS "http://$IP/api/health" && echo " (http; cert still provisioning)" \
  || echo "not ready yet — check 'docker compose logs caddy' on the box"
echo "==> Done. App: https://$SITE_HOST   (seed data with scripts/dev-seed.sh)"
