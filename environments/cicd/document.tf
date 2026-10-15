# ── Shared SSM deploy document ──────────────────────────────────────────
#
# One aws:runShellScript document, shared by all three environments — the
# env-specific behavior lives entirely in the parameters GitHub Actions
# passes at ssm:SendCommand time, not in the document itself.
#
# The script mirrors the artifact-push shape of scripts/dev-deploy.sh but
# pulls the bundle from S3 (presigned URL) instead of rsync-ing from a
# laptop, and verifies its sha256 before extracting.
#
# Env-injection strip-then-append pattern is inherited verbatim from
# scripts/dev-deploy.sh (~L179: `grep -v` the stamp keys out of the
# existing .env, then append the fresh values) — every other .env key
# (JWT_SECRET, etc.) is left untouched. The stamp key list here
# (ENV_LABEL/GIT_SHA/UI_GIT_SHA/SV_TAG) is the CI ladder's superset of the
# two keys dev-deploy.sh strips today.
#
# SiteAddress/CanonicalHost both use a single-hostname allowedPattern
# (no spaces) — CI-3 collapses dev-deploy.sh's current multi-host
# SITE_ADDRESS to a canonical-host-only value, and this document is
# written for that post-CI-3 world.
locals {
  gha_deploy_script = <<-EOT
    set -eu
    cd /opt/dara
    curl -fsSL --retry 3 -o bundle.tar.gz "{{ArtifactUrl}}"
    echo "{{ArtifactSha256}}  bundle.tar.gz" | sha256sum -c -
    rm -rf incoming && mkdir incoming
    tar -xzf bundle.tar.gz -C incoming
    rsync -a --delete incoming/out/ /opt/dara/out/
    cp incoming/docker-compose.yml /opt/dara/docker-compose.yml
    cp incoming/Caddyfile /opt/dara/Caddyfile
    # JIG-101 B3: .env holds secrets; keep it (and its backups) 600 root:root.
    # umask is scoped to this block so out/, Caddyfile, compose keep their modes.
    old_umask=$(umask); umask 077
    touch .env
    (grep -v -e '^ENV_LABEL=' -e '^GIT_SHA=' -e '^UI_GIT_SHA=' -e '^SV_TAG=' .env || true) > .env.tmp
    cat incoming/stamps.env >> .env.tmp
    install -m 600 -o root -g root .env.tmp .env
    rm -f .env.tmp
    for f in .env.bak*; do [ -e "$f" ] || continue; chown root:root "$f"; chmod 600 "$f"; done
    umask "$old_umask"
    gunzip -c incoming/api-image.tar.gz | docker load
    # JIG-101 B5: custom Caddy image (rate_limit), shipped in the bundle when present.
    if [ -f incoming/caddy-image.tar.gz ]; then gunzip -c incoming/caddy-image.tar.gz | docker load; fi
    SITE_ADDRESS="{{SiteAddress}}" docker compose up -d
    rm -rf incoming bundle.tar.gz
    docker image prune -f >/dev/null 2>&1 || true
    i=0
    while [ $i -lt 30 ]; do
      if curl -fsSk --resolve "{{CanonicalHost}}:443:127.0.0.1" "https://{{CanonicalHost}}/api/health" >/dev/null 2>&1; then
        # JIG-101 FIX-G: anonymous /api/health is trimmed (A9) and CI holds no
        # password. Report what is running from the box itself: docker inspect
        # of the api container -> ENV_LABEL, stamped GIT_SHA and the image's
        # OCI revision label (build-bundle.sh). Only these 3 values are printed;
        # the rest of Config.Env (secrets) never leaves python. ssm-deploy.sh
        # reads this line from StandardOutputContent for health-gate.sh.
        cid=$(docker compose ps -q api || true)
        docker inspect "$cid" 2>/dev/null | python3 -c 'import json,sys; c=json.load(sys.stdin)[0]["Config"]; e=dict(x.split("=",1) for x in c.get("Env") or []); l=c.get("Labels") or dict(); print("DARA_HEALTH_DETAIL " + json.dumps(dict(env=e.get("ENV_LABEL",""), git_sha=e.get("GIT_SHA",""), image_revision=l.get("org.opencontainers.image.revision",""))))' || echo "DARA_HEALTH_DETAIL_UNAVAILABLE"
        exit 0
      fi
      i=$((i+1)); sleep 5
    done
    echo "health probe failed" >&2
    docker compose logs --tail 50 api caddy >&2 || true
    exit 1
  EOT
}

resource "aws_ssm_document" "gha_deploy" {
  name            = "rs-intelligence-gha-deploy"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Deploy a GitHub Actions build artifact to an rs-intelligence Lightsail box (dev/stg)."
    parameters = {
      ArtifactUrl = {
        type        = "String"
        description = "Presigned S3 URL for the env-scoped bundle.tar.gz."
        # <account>.s3[.-]eu-west-1.amazonaws.com/<env>/<sha>/bundle.tar.gz?<query>
        allowedPattern = "^https://rs-intelligence-cicd-artifacts-[0-9]+\\.s3[.-]eu-west-1\\.amazonaws\\.com/(dev|stg)/[0-9a-f]{7,40}/bundle\\.tar\\.gz\\?\\S+$"
      }
      ArtifactSha256 = {
        type           = "String"
        description    = "sha256 of bundle.tar.gz — verified before extraction (integrity floor for the presigned-URL transport)."
        allowedPattern = "^[a-f0-9]{64}$"
      }
      SiteAddress = {
        type           = "String"
        description    = "Caddy SITE_ADDRESS value — a single canonical hostname (see CI-3)."
        allowedPattern = "^[A-Za-z0-9.-]+$"
      }
      CanonicalHost = {
        type           = "String"
        description    = "Hostname the in-document health probe resolves to 127.0.0.1 via curl --resolve."
        allowedPattern = "^[A-Za-z0-9.-]+$"
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "deploy"
        inputs = {
          timeoutSeconds = 600
          # POSIX sh, no bashisms. SSM joins these lines into one script —
          # the leading `set -eu` is what makes a failed sha256 check abort
          # the deploy instead of extracting a corrupt bundle.
          runCommand = split("\n", trimspace(local.gha_deploy_script))
        }
      }
    ]
  })

  tags = { Name = "rs-intelligence-gha-deploy" }
}
