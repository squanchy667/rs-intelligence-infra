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
    touch .env
    (grep -v -e '^ENV_LABEL=' -e '^GIT_SHA=' -e '^UI_GIT_SHA=' -e '^SV_TAG=' .env || true) > .env.tmp
    cat incoming/stamps.env >> .env.tmp
    mv .env.tmp .env
    gunzip -c incoming/api-image.tar.gz | docker load
    SITE_ADDRESS="{{SiteAddress}}" docker compose up -d
    i=0
    while [ $i -lt 30 ]; do
      if curl -fsSk --resolve "{{CanonicalHost}}:443:127.0.0.1" "https://{{CanonicalHost}}/api/health" >/dev/null 2>&1; then exit 0; fi
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
    description   = "Deploy a GitHub Actions build artifact to an rs-intelligence Lightsail box (dev/test/stg)."
    parameters = {
      ArtifactUrl = {
        type        = "String"
        description = "Presigned S3 URL for the env-scoped bundle.tar.gz."
        # <account>.s3[.-]eu-west-1.amazonaws.com/<env>/<sha>/bundle.tar.gz?<query>
        allowedPattern = "^https://rs-intelligence-cicd-artifacts-[0-9]+\\.s3[.-]eu-west-1\\.amazonaws\\.com/(dev|test|stg)/[0-9a-f]{7,40}/bundle\\.tar\\.gz\\?\\S+$"
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
