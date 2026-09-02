#!/usr/bin/env bash
# Apply a SQL delta file to a box's Postgres over SSH. The missing third leg
# next to scripts/dev-deploy.sh (code+image) and scripts/dev-seed.sh (full
# drop-schema + restore): this one ships a *delta* — a hand-written .sql file
# — into the box's `docker compose exec -T postgres psql`, without touching
# the schema or the rest of the data.
#
# Written for JIG-010 (promoting the JIG-009 §4j Bat Yam override sweep onto
# the dev box); JIG-014 uses it for every subsequent city promotion.
#
# The box's Postgres publishes no host port, so `psql` from a laptop cannot
# reach it. The only route is `docker compose exec -T postgres psql` inside
# /opt/dara over SSH — exactly what dev-seed.sh does for its restore step, and
# what this script mirrors.
#
# --dry-run is the default posture for anything C6-class: the file is rewritten
# locally so that every standalone COMMIT/END is neutralised, wrapped in an
# outer BEGIN … ROLLBACK, and the published `manual_overrides` count is read
# BEFORE and AFTER the run by two separate psql sessions — so the rollback is
# proven by re-reading the DB, not asserted by this script.
#
# Prereqs: terraform (for static_ip / private_key_pem), ssh, and a box whose
#          /opt/dara compose stack is up.
# Usage:   scripts/dev-apply-sql.sh <dev|test> <file.sql> [--dry-run] [--yes] [--i-mean-test]
#
# Safety rails:
#   * target `test` is REFUSED unless --i-mean-test is also passed (the review
#     box takes blessed dumps only — see DEV.md PROMOTION POLICY).
#   * --dry-run refuses to run at all if any COMMIT/END survives neutralisation.
#   * every command this script runs is printed before it runs.
set -euo pipefail

# --- box roles (2026-07-19 env model — see DEV.md) --------------------------
# dev  → environments/dev2 : Ofek's INTERNAL box (new work lands here first).
# test → environments/dev  : the REVIEW box. Blessed dumps ONLY; a hand-written
#        delta is exactly what must NOT land there casually, hence the extra
#        --i-mean-test flag on top of the shared 3s pause.
# The TF directory names are IMMUTABLE (S3 state keys) — dev2 = dev, dev = test.
# -----------------------------------------------------------------------------

YES=0
DRY_RUN=0
I_MEAN_TEST=0
RAW_TARGET=""
SQL_FILE=""
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --i-mean-test) I_MEAN_TEST=1 ;;
    --*)
      echo "error: unknown flag: $arg" >&2
      exit 1
      ;;
    *)
      if [ -z "$RAW_TARGET" ]; then
        RAW_TARGET="$arg"
      elif [ -z "$SQL_FILE" ]; then
        SQL_FILE="$arg"
      else
        echo "error: unexpected extra argument: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

usage() {
  echo "usage: dev-apply-sql.sh <dev|test> <file.sql> [--dry-run] [--yes] [--i-mean-test]" >&2
  echo "       (feature = deprecated alias for dev)" >&2
}

case "$RAW_TARGET" in
  feature)
    echo "warning: target 'feature' is a deprecated alias for 'dev' (2026-07-19 env model) — use 'dev' going forward." >&2
    TARGET="dev"
    ;;
  dev)
    echo "NOTE: target 'dev' = the INTERNAL box (environments/dev2) under the 2026-07-19 model; the review box is now 'test'." >&2
    if [ "$YES" != "1" ]; then
      echo "    pausing 3s in case this was a habit-typed old-vocabulary 'dev' (= today's 'test') — Ctrl-C to abort, or pass --yes to skip this pause." >&2
      sleep 3
    fi
    TARGET="dev"
    ;;
  test)
    if [ "$I_MEAN_TEST" != "1" ]; then
      echo "REFUSED: target 'test' is the REVIEW box. Under the promotion policy it takes" >&2
      echo "         ff-merged code and BLESSED DUMPS ONLY — never a hand-written SQL delta." >&2
      echo "         If you genuinely mean the review box, re-run with --i-mean-test." >&2
      exit 2
    fi
    echo "WARNING: target 'test' = the REVIEW box, and --i-mean-test was passed." >&2
    if [ "$YES" != "1" ]; then
      echo "    pausing 5s — Ctrl-C to abort, or pass --yes to skip this pause." >&2
      sleep 5
    fi
    TARGET="test"
    ;;
  *)
    usage
    exit 1
    ;;
esac

if [ -z "$SQL_FILE" ]; then
  usage
  exit 1
fi
if [ ! -f "$SQL_FILE" ]; then
  echo "error: sql file not found: $SQL_FILE" >&2
  exit 1
fi

case "$TARGET" in
  dev)  TF_DIR="environments/dev2"; KEY_NAME="feature_box_key.pem" ;;
  test) TF_DIR="environments/dev";  KEY_NAME="dev_box_key.pem" ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEV_TF="$INFRA_DIR/$TF_DIR"
KEY="$INFRA_DIR/$KEY_NAME"

# Every command this script runs is printed first (the JIG-010 evidence rule).
run() { echo "\$ $*"; "$@"; }

echo "==> Resolving box address (terraform -chdir=$DEV_TF output -raw static_ip)"
IP="$(terraform -chdir="$DEV_TF" output -raw static_ip)"
echo "    target=$TARGET  tf=$TF_DIR  ip=$IP  file=$SQL_FILE  dry_run=$DRY_RUN"

if [ ! -f "$KEY" ]; then
  echo "==> Materialising ssh key from terraform output -raw private_key_pem"
  terraform -chdir="$DEV_TF" output -raw private_key_pem > "$KEY"; chmod 600 "$KEY"
fi
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
PSQL_REMOTE='cd /opt/dara && docker compose exec -T postgres psql -U dara -d dara_v2 -v ON_ERROR_STOP=1'

# --- the payload -------------------------------------------------------------
PAYLOAD="$(mktemp -t dev-apply-sql)"
trap 'rm -f "$PAYLOAD"' EXIT

if [ "$DRY_RUN" = "1" ]; then
  # Neutralise every standalone COMMIT / END so the file cannot commit, then
  # wrap the whole thing in our own transaction and roll it back.
  NEUTRALISED="$(mktemp -t dev-apply-sql-neutral)"
  trap 'rm -f "$PAYLOAD" "$NEUTRALISED"' EXIT
  sed -E 's/^([[:space:]]*)(COMMIT|END)([[:space:]]*;)/\1-- [dry-run neutralised] \2\3/I' \
      "$SQL_FILE" > "$NEUTRALISED"

  # Refuse to run if anything that could commit survived. Any line whose first
  # non-space token is COMMIT or END is a commit; after the sed above there
  # must be none left.
  if grep -Eiq '^[[:space:]]*(COMMIT|END)[[:space:]]*;' "$NEUTRALISED"; then
    echo "REFUSED: a COMMIT/END survived dry-run neutralisation in $SQL_FILE — not shipping." >&2
    grep -Ein '^[[:space:]]*(COMMIT|END)[[:space:]]*;' "$NEUTRALISED" >&2
    exit 3
  fi
  NEUTRALISED_N="$(grep -c '\-\- \[dry-run neutralised\]' "$NEUTRALISED" || true)"
  echo "==> DRY RUN: neutralised $NEUTRALISED_N COMMIT/END statement(s) in $SQL_FILE"

  {
    echo "\\echo '=== DRY RUN — outer BEGIN; nothing below can persist ==='"
    echo "BEGIN;"
    cat "$NEUTRALISED"
    echo ""
    echo "\\echo '=== DRY RUN — rolling back ==='"
    echo "ROLLBACK;"
  } > "$PAYLOAD"
else
  echo "==> APPLY (NOT a dry run): $SQL_FILE will be executed as written on '$TARGET'."
  echo "    The file's own COMMIT is left intact. This mutates the box."
  if [ "$YES" != "1" ]; then
    echo "    pausing 5s — Ctrl-C to abort, or pass --yes to skip this pause." >&2
    sleep 5
  fi
  cp "$SQL_FILE" "$PAYLOAD"
fi

# --- before ------------------------------------------------------------------
COUNT_SQL="SELECT count(*) AS published_overrides FROM manual_overrides WHERE status='published';"
echo "==> BEFORE — published manual_overrides on the box"
echo "\$ $SSH ubuntu@$IP '$PSQL_REMOTE -c \"$COUNT_SQL\"'"
$SSH ubuntu@"$IP" "$PSQL_REMOTE -c \"$COUNT_SQL\""

# --- run ---------------------------------------------------------------------
echo "==> RUN — piping $(wc -l < "$PAYLOAD" | tr -d ' ') lines into the box's psql"
echo "\$ $SSH ubuntu@$IP '$PSQL_REMOTE' < $PAYLOAD"
set +e
$SSH ubuntu@"$IP" "$PSQL_REMOTE" < "$PAYLOAD"
RC=$?
set -e
echo "    psql exit code: $RC"

# --- after -------------------------------------------------------------------
# A separate session: a dry run that really rolled back must show the same
# number here as it did BEFORE. This is the proof, not the script's word.
echo "==> AFTER — published manual_overrides on the box (re-read, new session)"
echo "\$ $SSH ubuntu@$IP '$PSQL_REMOTE -c \"$COUNT_SQL\"'"
$SSH ubuntu@"$IP" "$PSQL_REMOTE -c \"$COUNT_SQL\""

if [ "$DRY_RUN" = "1" ]; then
  echo "==> Dry run complete. BEFORE and AFTER above must be equal; if they are not, the file committed something and that is an incident."
else
  echo "==> Apply complete. Remember: the override count is NOT the effect."
  echo "    Rebuild the read model, then verify a TARGET PARCEL's value in presentation_deals."
fi
exit "$RC"
