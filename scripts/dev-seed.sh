#!/usr/bin/env bash
# Seed a box's Postgres (pg_dump → ship → restore). Run after
# scripts/dev-deploy.sh. Idempotent: it resets the public schema and restores
# the full dump (which carries an alembic_version, so the API's startup
# `alembic upgrade head` stays a no-op as long as heads match).
#
# dev: by default dumps the current LOCAL dara_v2 DB; pass a dump file as the
#      second arg to ship that instead. Plain restore — the dump wins on every
#      table (unchanged behaviour).
# stg: a BLESSED dump file is mandatory (e.g. from scripts/make-seed.sh under
#      snapshots/seeds/ — never a live local pg_dump), and the restore is a
#      PRESERVE-MERGE: the box's users / password_reset_tokens /
#      user_audit_log win (exported before, re-inserted after), and box-only
#      manual_overrides ids are re-inserted. Same shape as SEED 1–4 of
#      DaraReports/scripts/promote_22_cities_2026-10-04.sh.
#
# Prereqs: local Postgres reachable at localhost:5432 (PGPASSWORD=dara) and
#          pg_dump — only for `dev` without a dump file.
# Usage:   scripts/dev-seed.sh <dev|stg> [dump.sql.gz] [--yes] [--dry-run]
#          scripts/dev-seed.sh stg --merge-only <box preserve dir> [--yes]
#          (`feature` accepted as a deprecated alias for `dev`)
#   --dry-run     print target / TF dir / key / expected IP / mode and exit —
#                 no ssh, no dump, no restore (A5 preflight).
#   --merge-only  stg recovery: re-run the preserve-merge + asserts from an
#                 existing /opt/dara/preserve_<ts> dir (after a failed merge).
#   --yes         skip the stg 5 s pause.
set -euo pipefail

# --- box roles (env model — see DEV.md) ---------------------------------------
# dev → environments/dev2 : Ofek's INTERNAL box (any dump is fine). TF dir name
#       kept as `dev2` — its S3 state key must stay put.
# stg → environments/stg  : the box the people who test for us use
#       (stg.rs-intel.com). Blessed dumps ONLY, preserve-merge always.
# test was RETIRED 2026-10-08 (JIG-089): the ladder is dev → stg.
# -----------------------------------------------------------------------------

YES=0
DRY_RUN=0
MERGE_ONLY=""
RAW_TARGET=""
DUMP_FILE_ARG=""
EXPECT_MERGE_DIR=0
for arg in "$@"; do
  if [ "$EXPECT_MERGE_DIR" = "1" ]; then MERGE_ONLY="$arg"; EXPECT_MERGE_DIR=0; continue; fi
  case "$arg" in
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --merge-only) EXPECT_MERGE_DIR=1 ;;
    --*) echo "error: unknown flag: $arg" >&2; exit 1 ;;
    *)
      if [ -z "$RAW_TARGET" ]; then
        RAW_TARGET="$arg"
      elif [ -z "$DUMP_FILE_ARG" ]; then
        DUMP_FILE_ARG="$arg"
      fi
      ;;
  esac
done

usage() {
  echo "usage: dev-seed.sh <dev|stg> [dump.sql.gz] [--yes] [--dry-run]   (feature = deprecated alias for dev)" >&2
  echo "       dev-seed.sh stg --merge-only /opt/dara/preserve_<ts> [--yes]" >&2
}

case "$RAW_TARGET" in
  feature)
    echo "warning: target 'feature' is a deprecated alias for 'dev' (2026-07-19 env model) — use 'dev' going forward." >&2
    TARGET="dev"
    ;;
  dev) TARGET="dev" ;;
  stg) TARGET="stg" ;;
  test)
    echo "error: target 'test' was retired 2026-10-08 (JIG-089); use stg" >&2
    exit 2
    ;;
  *)
    usage
    exit 1
    ;;
esac

case "$TARGET" in
  dev) TF_DIR="environments/dev2"; KEY_NAME="feature_box_key.pem"; EXPECTED_IP="54.155.62.174"; MODE="plain-restore" ;;
  stg) TF_DIR="environments/stg";  KEY_NAME="stg_box_key.pem";     EXPECTED_IP="34.254.119.146"; MODE="preserve-merge" ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEV_TF="$INFRA_DIR/$TF_DIR"
KEY="$INFRA_DIR/$KEY_NAME"
DUMP="/tmp/dara_${TARGET}_seed.sql.gz"

if [ -n "$MERGE_ONLY" ] && [ "$TARGET" != "stg" ]; then
  echo "error: --merge-only applies to stg only" >&2; exit 1
fi
if [ "$TARGET" = "stg" ] && [ -z "$MERGE_ONLY" ] && [ "$DRY_RUN" != "1" ] && [ -z "$DUMP_FILE_ARG" ]; then
  echo "error: stg takes a BLESSED dump file only — pass it as the second argument (never a live local pg_dump)." >&2
  exit 1
fi

# --- preserve-merge SQL (stg) ----------------------------------------------------
# Each function PRINTS a bash script; the caller pipes it into `bash -s` on the
# box (PSQL = the box's `docker compose exec -T postgres psql …`) or locally
# (PSQL = a plain `psql <dsn> …`), so the exact same SQL is what a local
# rehearsal runs (DaraReports/jig/evidence/JIG-089/seed_rehearsal.md).
#   $1 = psql command string (must include -X -v ON_ERROR_STOP=1)
#   $2 = preserve directory (on whichever host runs the script)
PRESERVE_TABLES="users password_reset_tokens user_audit_log"   # box copy wins
# box-only manual_overrides ids are re-inserted (dump wins on shared ids)
USERS_IDENTITY_SQL="select id||' '||email||' '||role||' '||md5(coalesce(password_hash,'')) from users order by id"

preserve_export_script() {
  local psql_cmd="$1" dir="$2"
  cat <<EOF
set -euo pipefail
umask 077
# </dev/null: on the box psql is \`docker compose exec -T\`, which would
# otherwise swallow the rest of this script from bash -s's stdin.
q() { $psql_cmd -At -c "\$1" </dev/null; }
mkdir -p '$dir'
: > '$dir'/counts_before.txt
for t in $PRESERVE_TABLES manual_overrides; do
  q "\\copy (select * from \$t order by id) to stdout csv header" > '$dir'/\$t.csv
  q "select id from \$t order by id" > '$dir'/\$t.ids_before
  echo "\$t \$(wc -l < '$dir'/\$t.ids_before | tr -d ' ')" >> '$dir'/counts_before.txt
done
q "$USERS_IDENTITY_SQL" > '$dir'/users.identity_before
echo "preserve-export: \$(tr '\n' ' ' < '$dir'/counts_before.txt)→ $dir"
EOF
}

preserve_merge_script() {
  local psql_cmd="$1" dir="$2"
  cat <<EOF
set -euo pipefail
d='$dir'
for t in $PRESERVE_TABLES manual_overrides; do [ -s "\$d/\$t.csv" ] || { echo "preserve-merge: missing \$d/\$t.csv" >&2; exit 1; }; done
# Column lists come from each CSV's own header, so a dump whose schema gained
# a column still loads (the new column takes its default) instead of misaligning.
cols() { head -1 "\$d/\$1.csv"; }
{
  echo 'begin;'
  echo 'delete from user_audit_log; delete from password_reset_tokens; delete from users;'
  for t in users password_reset_tokens user_audit_log; do
    echo "\\\\copy \$t (\$(cols \$t)) from stdin csv header"; cat "\$d/\$t.csv"; echo '\\.'
  done
  echo 'create temp table mo_box as select * from manual_overrides with no data;'
  echo "\\\\copy mo_box (\$(cols manual_overrides)) from stdin csv header"; cat "\$d/manual_overrides.csv"; echo '\\.'
  echo "insert into manual_overrides (\$(cols manual_overrides)) select \$(cols manual_overrides) from mo_box b where not exists (select 1 from manual_overrides m where m.id = b.id);"
  # Sequence fix: only where the id column owns a sequence. Today every id in
  # the preserve set is a uuid (no sequence), so this is a no-op; it is
  # dynamic SQL on purpose — a static max(id) would not even parse on uuid.
  cat <<'SQL'
do \$seqfix\$
declare t text; sq text;
begin
  foreach t in array string_to_array('$PRESERVE_TABLES manual_overrides', ' ') loop
    sq := pg_get_serial_sequence(t, 'id');
    if sq is not null then
      execute format('select setval(%L, greatest(coalesce((select max(id) from %I), 0), 1), (select max(id) from %I) is not null)', sq, t, t);
    end if;
  end loop;
end \$seqfix\$;
SQL
  echo 'commit;'
} | $psql_cmd -q >/dev/null
echo "preserve-merge: committed (box wins on $PRESERVE_TABLES; box-only manual_overrides re-inserted; id sequences fixed where present)"
EOF
}

preserve_verify_script() {
  local psql_cmd="$1" dir="$2"
  cat <<EOF
set -euo pipefail
d='$dir'; fail=0
q() { $psql_cmd -At -c "\$1" </dev/null; }
n() { wc -l < "\$1" | tr -d ' '; }
for t in $PRESERVE_TABLES; do
  q "select id from \$t order by id" > "\$d/\$t.ids_after"
  if cmp -s "\$d/\$t.ids_before" "\$d/\$t.ids_after"; then echo "  ok \$t ids before == after (count \$(n "\$d/\$t.ids_after"))"
  else echo "  ASSERT FAIL \$t ids differ (before \$(n "\$d/\$t.ids_before"), after \$(n "\$d/\$t.ids_after"))"; fail=1; fi
done
q "$USERS_IDENTITY_SQL" > "\$d/users.identity_after"
if cmp -s "\$d/users.identity_before" "\$d/users.identity_after"; then echo "  ok users identity (id/email/role/password-hash md5) before == after"
else echo "  ASSERT FAIL users identity changed"; fail=1; fi
q "select id from manual_overrides order by id" > "\$d/manual_overrides.ids_after"
missing=\$(comm -23 <(sort "\$d/manual_overrides.ids_before") <(sort "\$d/manual_overrides.ids_after") | wc -l | tr -d ' ')
subj=\$(n "\$d/manual_overrides.ids_before")
if [ "\$subj" = "0" ]; then echo "  ASSERT FAIL manual_overrides preserve set is EMPTY — the check could not detect a loss"; fail=1
elif [ "\$missing" = "0" ]; then echo "  ok preserved manual_overrides ids missing = 0 (of \$subj checked; after = \$(n "\$d/manual_overrides.ids_after"))"
else echo "  ASSERT FAIL \$missing preserved manual_overrides ids missing (of \$subj)"; fail=1; fi
seqs=0
for t in $PRESERVE_TABLES manual_overrides; do
  sq=\$(q "select coalesce(pg_get_serial_sequence('\$t','id'),'')")
  [ -n "\$sq" ] || continue
  seqs=\$((seqs+1))
  behind=\$(q "select (select coalesce(last_value,0) from pg_sequences where schemaname||'.'||sequencename = '\$sq') < coalesce((select max(id) from \$t),0)")
  if [ "\$behind" = "f" ]; then echo "  ok \$t id sequence \$sq >= max(id)"; else echo "  ASSERT FAIL \$t id sequence \$sq behind max(id)"; fail=1; fi
done
[ "\$seqs" = "0" ] && echo "  ok id sequences: none owned by the 4 preserve tables (uuid ids) — nothing to fix (4 tables checked)"
exit "\$fail"
EOF
}

# stg restore, fail-closed (JIG-089 F1): DROP + restore under ON_ERROR_STOP, the
# restore's stderr kept in <dir>/restore.err, and any non-zero exit or ERROR line
# fails the step BEFORE the merge can run.
#   $1 = psql command string (with -X -v ON_ERROR_STOP=1)  $2 = dump .sql.gz path
#   $3 = preserve directory (restore.err lands there)
restore_script() {
  local psql_cmd="$1" dump="$2" dir="$3"
  cat <<EOF
set -uo pipefail
err='$dir/restore.err'; : > "\$err"
$psql_cmd -q -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" </dev/null 2>>"\$err" >/dev/null
rc_drop=\$?
if [ "\$rc_drop" != "0" ]; then echo "restore: DROP/CREATE SCHEMA failed (exit \$rc_drop)"; grep ERROR "\$err" | head -5; exit 1; fi
gunzip -c '$dump' | $psql_cmd -q >/dev/null 2>>"\$err"
rcs="\${PIPESTATUS[*]}"
nerr=\$(grep -c 'ERROR' "\$err" || true)
if [ "\$rcs" != "0 0" ] || [ "\$nerr" != "0" ]; then
  echo "restore: FAILED (gunzip/psql exit \$rcs, \$nerr ERROR line(s) in \$err)"
  grep ERROR "\$err" | head -5
  exit 1
fi
echo "restore: ok (exit \$rcs, 0 ERROR lines)"
EOF
}

# --- dry run: print the plan, touch nothing ------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  echo "dev-seed.sh DRY RUN — nothing is shipped, restored or connected to"
  echo "  target      = $TARGET"
  echo "  tf dir      = $DEV_TF"
  echo "  ssh key     = $KEY ($( [ -f "$KEY" ] && echo present || echo 'absent — would be written from terraform output -raw private_key_pem' ))"
  echo "  expected ip = $EXPECTED_IP (asserted against terraform output -raw static_ip before any ssh)"
  echo "  mode        = $MODE"
  if [ "$TARGET" = "stg" ]; then
    echo "  dump        = ${DUMP_FILE_ARG:-<REQUIRED: a blessed .sql.gz — a real stg run refuses without one>}"
  else
    echo "  dump        = ${DUMP_FILE_ARG:-<local pg_dump of dara_v2>}"
  fi
  if [ "$TARGET" = "stg" ]; then
    echo "  preserve    = $PRESERVE_TABLES (box wins) + box-only manual_overrides ids → /opt/dara/preserve_<ts>/ on the box"
  fi
  exit 0
fi

# --- resolve + assert the box ----------------------------------------------------
IP="$(terraform -chdir="$DEV_TF" output -raw static_ip)"
if [ "$IP" != "$EXPECTED_IP" ]; then
  echo "error: terraform says $TF_DIR static_ip=$IP, expected $EXPECTED_IP for target '$TARGET' — wrong root or the box moved; refusing." >&2
  exit 1
fi
if [ ! -f "$KEY" ]; then
  terraform -chdir="$DEV_TF" output -raw private_key_pem > "$KEY"; chmod 600 "$KEY"
fi
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
BOX_PSQL='docker compose exec -T postgres psql -U dara -d dara_v2 -X -v ON_ERROR_STOP=1'
box_bash() { $SSH ubuntu@"$IP" 'cd /opt/dara && bash -s'; }

if [ "$TARGET" = "stg" ] && [ "$YES" != "1" ]; then
  echo "WARNING: target 'stg' = the box people test on ($IP). Preserve-merge reseed; api down ~1–2 min." >&2
  echo "    pausing 5s — Ctrl-C to abort, or pass --yes to skip this pause." >&2
  sleep 5
fi

if [ -n "$MERGE_ONLY" ]; then
  echo "==> stg --merge-only: re-running preserve-merge + asserts from $MERGE_ONLY"
  preserve_merge_script "$BOX_PSQL" "$MERGE_ONLY" | box_bash
  preserve_verify_script "$BOX_PSQL" "$MERGE_ONLY" | box_bash
  echo "==> Merge-only done."
  exit 0
fi

if [ -n "$DUMP_FILE_ARG" ]; then
  if [ ! -f "$DUMP_FILE_ARG" ]; then
    echo "error: dump file not found: $DUMP_FILE_ARG" >&2
    exit 1
  fi
  echo "==> Using existing dump: $DUMP_FILE_ARG"
  cp "$DUMP_FILE_ARG" "$DUMP"
  echo "    dump: $(du -h "$DUMP" | cut -f1)"
else
  LOCAL_PGHOST="${LOCAL_PGHOST:-localhost}"
  LOCAL_PGUSER="${LOCAL_PGUSER:-dara}"
  LOCAL_PGDB="${LOCAL_PGDB:-dara_v2}"
  export PGPASSWORD="${PGPASSWORD:-dara}"

  echo "==> Dumping local DB ($LOCAL_PGUSER@$LOCAL_PGHOST/$LOCAL_PGDB)"
  pg_dump -h "$LOCAL_PGHOST" -U "$LOCAL_PGUSER" -d "$LOCAL_PGDB" \
    --no-owner --no-privileges | gzip > "$DUMP"
  echo "    dump: $(du -h "$DUMP" | cut -f1)"
fi

echo "==> Shipping dump to box ($IP)"
rsync -az -e "$SSH" "$DUMP" ubuntu@"$IP":/opt/dara/seed.sql.gz

PRESERVE_DIR=""
if [ "$TARGET" = "stg" ]; then
  PRESERVE_DIR="/opt/dara/preserve_$(date -u +%Y%m%dT%H%M%SZ)"
  RECOVER="scripts/dev-seed.sh stg --merge-only $PRESERVE_DIR --yes"
  # F2: watchdog + api go down FIRST, so no login / invite / reset lands between
  # the export and the restore (the export needs postgres only).
  echo "==> stg 0/4 — pause the box watchdog and stop the api (nothing can write users/audit from here on)"
  if ! $SSH ubuntu@"$IP" 'sudo -n systemctl stop dara-watchdog.timer 2>/dev/null || true; cd /opt/dara && docker compose stop api'; then
    $SSH ubuntu@"$IP" 'cd /opt/dara && docker compose start api; sudo -n systemctl start dara-watchdog.timer 2>/dev/null || true' || true
    echo "error: could not stop the api — NOTHING was exported or restored; api and watchdog (re)started. Re-run when the box answers." >&2
    exit 1
  fi
  echo "==> stg 1/4 — export the preserve set on the box → $PRESERVE_DIR (box wins)"
  if ! preserve_export_script "$BOX_PSQL" "$PRESERVE_DIR" | box_bash; then
    # nothing was changed yet: put the box back in service
    $SSH ubuntu@"$IP" 'cd /opt/dara && docker compose start api; sudo -n systemctl start dara-watchdog.timer 2>/dev/null || true' || true
    echo "error: preserve export failed — NOTHING was restored; api and watchdog restarted. Fix the cause and re-run." >&2
    exit 1
  fi
  if [ -n "${PRESERVE_OFFBOX:-}" ]; then
    mkdir -p "$PRESERVE_OFFBOX" && chmod 700 "$PRESERVE_OFFBOX"
    scp -q -r -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
      "ubuntu@$IP:$PRESERVE_DIR/." "$PRESERVE_OFFBOX/"
    echo "    off-box copy → $PRESERVE_OFFBOX"
  fi

  # stg: the api stays DOWN through restore + merge, so no reviewer ever logs in
  # against the dump's users; it is started only after the merge commits.
  echo "==> stg 2/4 — restore (reset schema → restore, fail-closed; api stays down)"
  if ! restore_script "$BOX_PSQL" /opt/dara/seed.sql.gz "$PRESERVE_DIR" | box_bash; then
    # F1: fail closed — no merge on a failed/partial restore; api AND watchdog stay DOWN
    # (verifier R1 2026-10-08: a restarted watchdog would `docker restart` the api onto a
    # half-restored DB after ~90 s and mail an alert). The recovery steps below end with the
    # watchdog start.
    {
      echo "error: the stg restore FAILED — the merge did NOT run. The api and the watchdog are left STOPPED"
      echo "       on purpose (a running watchdog would restart the api onto a half-restored DB); the database may be partially restored."
      echo "       The box's own users / tokens / audit / overrides are safe in: $PRESERVE_DIR  (restore log: $PRESERVE_DIR/restore.err)"
      echo "       Recovery — do NOT re-run the full seed (it would export the broken DB as the preserve set):"
      echo "         1) fix the dump, ship it to /opt/dara/seed.sql.gz and restore it by hand on the box:"
      echo "            cd /opt/dara && docker compose exec -T postgres psql -U dara -d dara_v2 -X -v ON_ERROR_STOP=1 -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"
      echo "            gunzip -c seed.sql.gz | docker compose exec -T postgres psql -U dara -d dara_v2 -X -v ON_ERROR_STOP=1 >/dev/null"
      echo "         2) then re-run the merge + asserts from the preserved rows:"
      echo "            $RECOVER"
      echo "            and start the api: ssh … 'cd /opt/dara && docker compose start api'"
      echo "         3) last, re-arm the watchdog: ssh … 'sudo -n systemctl start dara-watchdog.timer'"
    } >&2
    exit 1
  fi
  echo "==> stg 3/4 — preserve-merge (one transaction) + id-sequence fix"
  if ! preserve_merge_script "$BOX_PSQL" "$PRESERVE_DIR" | box_bash; then
    $SSH ubuntu@"$IP" 'cd /opt/dara && docker compose start api; sudo -n systemctl start dara-watchdog.timer 2>/dev/null || true' || true
    echo "error: preserve-merge failed — the box now carries the DUMP's users. The box's own rows are safe in $PRESERVE_DIR." >&2
    echo "       fix the cause, then: $RECOVER" >&2
    exit 1
  fi
  $SSH ubuntu@"$IP" 'cd /opt/dara && docker compose start api'
else
  echo "==> Restoring on the box (stop api → reset schema → restore → start api)"
  $SSH ubuntu@"$IP" 'set -e; cd /opt/dara;
    docker compose stop api || true;
    docker compose exec -T postgres psql -U dara -d dara_v2 -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;";
    gunzip -c seed.sql.gz | docker compose exec -T postgres psql -U dara -d dara_v2 >/dev/null;
    docker compose start api'
fi

if [ "$TARGET" = "stg" ]; then
  echo "==> stg 4/4 — asserts (users/tokens/audit ids before == after, 0 preserved override ids lost, sequence)"
  VERIFY_RC=0
  preserve_verify_script "$BOX_PSQL" "$PRESERVE_DIR" | box_bash || VERIFY_RC=$?
  $SSH ubuntu@"$IP" 'sudo -n systemctl start dara-watchdog.timer 2>/dev/null || true'
  if [ "$VERIFY_RC" != "0" ]; then
    echo "error: preserve asserts FAILED — see the lines above; preserve set kept at $PRESERVE_DIR" >&2
    exit 1
  fi
fi

echo "==> Verifying row counts on the box"
$SSH ubuntu@"$IP" 'cd /opt/dara && docker compose exec -T postgres psql -U dara -d dara_v2 -t -c "SELECT (SELECT count(*) FROM presentation_deals) AS deals, (SELECT count(*) FROM amenities) AS amenities, (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM manual_overrides) AS overrides;"'
echo "==> Seed done."
