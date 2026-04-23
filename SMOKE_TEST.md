# Smoke test — staging runbook

Run this the first time you `terraform apply` against a new AWS account, and
again after any significant infra change. It's a **living checklist**: tick
items off in a copy (don't commit the ticked version), record anything that
failed as a GitHub issue, move on.

The spec originally assumed a custom domain (`staging.rsintelligence.com` +
`api-staging.rsintelligence.com`). We ship without one — everything is on
the default `d*.cloudfront.net` URL with the CloudFront-managed cert. Steps
below reflect what's actually deployed.

**Prereqs for this document:**
- `DEPLOYMENT.md` has been followed through step 7 (initial admin user exists)
- AWS CLI configured with profile `rs-intel`, region `eu-west-1`
- `gh` CLI authenticated as `squanchy667`
- The docs-repo [`PRODUCTION_CHECKLIST.md`](https://github.com/squanchy667/dara-v2-docs/blob/main/PRODUCTION_CHECKLIST.md) items are understood — this smoke test verifies the staging surface; it does not certify for production.

---

## 0. Environment variables for this session

Collect these once and reuse throughout.

```sh
export AWS_PROFILE=rs-intel
export AWS_REGION=eu-west-1

cd rs-intelligence-infra
export CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)
export CF_DIST_ID=$(terraform output -raw cloudfront_distribution_id)
export CF_URL="https://${CF_DOMAIN}"
export ALB_DNS=$(terraform output -raw alb_dns_name)
export ECS_CLUSTER=$(terraform output -raw ecs_cluster_name)
export ECS_SERVICE=$(terraform output -raw ecs_service_name)
export ECR_URL=$(terraform output -raw ecr_repository_url)
export FRONTEND_BUCKET=$(terraform output -raw frontend_bucket_name)
export LOG_GROUP=$(terraform output -raw ecs_log_group_name)
export ALERTS_TOPIC_ARN=$(terraform output -raw alerts_topic_arn)
export BACKEND_ROLE=$(terraform output -raw github_backend_role_arn)
export FRONTEND_ROLE=$(terraform output -raw github_frontend_role_arn)

# Sanity — print what we'll be hitting
echo "CloudFront: $CF_URL"
echo "ALB (internal test only): http://$ALB_DNS"
echo "ECS: cluster=$ECS_CLUSTER service=$ECS_SERVICE"
```

---

## 1. Infra state

- [ ] `terraform plan` is clean (no drift after apply)

  ```sh
  terraform plan -var-file=environments/staging/terraform.tfvars
  # expect: "No changes. Your infrastructure matches the configuration."
  ```

- [ ] Every expected resource exists

  ```sh
  terraform state list | sort
  # Scan for at least one resource per module: networking, ecr, secrets,
  # database, alb, storage, ecs, scheduling, monitoring, cicd
  ```

- [ ] **One-time manual steps are done**
  - [ ] SNS email subscription confirmed (check inbox for
        `AWS Notification - Subscription Confirmation`, click the link)
  - [ ] `aws secretsmanager put-secret-value` run to rotate the real nadlan
        reCAPTCHA key over the placeholder
  - [ ] `gh secret set AWS_DEPLOY_ROLE_ARN` in both the `dara-v2` and
        `dara-v2-ui` repos (`staging` environment)

---

## 2. ECR + ECS task is running

- [ ] Image exists in ECR with the `:latest` tag

  ```sh
  aws ecr describe-images \
      --repository-name rs-intelligence-api \
      --query 'imageDetails[?contains(imageTags, `latest`)].[imagePushedAt,imageSizeInBytes]' \
      --output table
  # expect: one row, image pushed recently, size < 1 GB
  ```

- [ ] Exactly one task is running in the service

  ```sh
  aws ecs describe-services \
      --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
      --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,status:status}' \
      --output table
  # expect: desired=1 running=1 pending=0 status=ACTIVE
  ```

- [ ] Task passed the container's own healthcheck

  ```sh
  TASK_ARN=$(aws ecs list-tasks \
      --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
      --query 'taskArns[0]' --output text)
  aws ecs describe-tasks \
      --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN" \
      --query 'tasks[0].containers[0].healthStatus' \
      --output text
  # expect: HEALTHY
  ```

- [ ] ALB reports the target as healthy

  ```sh
  TG_ARN=$(terraform output -raw alb_target_group_arn)
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'TargetHealthDescriptions[].TargetHealth.State' \
      --output text
  # expect: healthy  (single word, one target)
  ```

---

## 3. Health endpoint

Hit it both directly (through the ALB) and via CloudFront — they must match.

- [ ] Direct to ALB (internal-facing test)

  ```sh
  curl -sS "http://$ALB_DNS/api/health" | jq .
  # expect: status=ok, db=true, llm.provider=bedrock, llm.ok=true,
  #         version + uptime_seconds present
  ```

- [ ] Via CloudFront (what real users hit)

  ```sh
  curl -sS "$CF_URL/api/health" | jq .
  # same shape as above — HTTPS, CloudFront-fronted, same JSON
  ```

- [ ] Status code is 200

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' "$CF_URL/api/health"
  # expect: 200
  ```

- [ ] HTTPS works without warnings — load `$CF_URL/api/health` in a browser;
      the padlock is green and the cert chains back to Amazon.

---

## 4. Frontend loads

- [ ] Landing page renders

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' "$CF_URL/"
  # expect: 200
  ```

- [ ] `/login` route loads

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' "$CF_URL/login"
  # expect: 200
  ```

- [ ] SPA deep links fall back to `/index.html`

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' "$CF_URL/definitely-not-a-page"
  # expect: 200  (CloudFront 404→index.html rewrite)
  ```

- [ ] Open `$CF_URL/` in a browser:
  - [ ] Login screen displays in Hebrew (RTL layout)
  - [ ] No CORS errors in DevTools console
  - [ ] DevTools network tab shows requests going to `$CF_URL/api/*`
        (relative — NOT to a different host)

---

## 5. Auth flow

- [ ] Login with the seeded admin

  ```sh
  LOGIN=$(curl -sS -X POST "$CF_URL/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d '{"email":"ofekaviv9@gmail.com","password":"<from-password-manager>"}')
  echo "$LOGIN" | jq .
  export TOKEN=$(echo "$LOGIN" | jq -r .access_token)
  echo "Token length: ${#TOKEN}"
  # expect: {access_token, token_type=bearer, expires_in=86400, user={id,email,name,role=admin}}
  ```

- [ ] Wrong password returns 401

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$CF_URL/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d '{"email":"ofekaviv9@gmail.com","password":"wrong"}'
  # expect: 401
  ```

- [ ] Unknown email also 401 (same error, no enumeration)

  ```sh
  curl -sS -X POST "$CF_URL/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d '{"email":"nobody@example.com","password":"whatever"}' | jq .detail
  # expect: "invalid credentials"  (same text as wrong-password)
  ```

- [ ] `/api/auth/me` returns profile with valid token

  ```sh
  curl -sS "$CF_URL/api/auth/me" -H "Authorization: Bearer $TOKEN" | jq .
  # expect: {id, email, name, role=admin}
  ```

- [ ] `/api/auth/me` returns 401 without a token

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' "$CF_URL/api/auth/me"
  # expect: 401
  ```

- [ ] Tampered token rejected

  ```sh
  BAD="${TOKEN%?}X"
  curl -sS -o /dev/null -w '%{http_code}\n' "$CF_URL/api/auth/me" \
      -H "Authorization: Bearer $BAD"
  # expect: 401
  ```

- [ ] Browser test:
  - [ ] Load `$CF_URL/` unauthenticated → redirects to `/login`
  - [ ] Sign in with seeded admin → lands on dashboard
  - [ ] Reload the page — still authenticated (token in localStorage)
  - [ ] Top bar shows user name + email + logout icon
  - [ ] Click logout → returns to `/login`, localStorage token cleared

---

## 6. Feature flags

With the four `FF_*` flags off (staging defaults), those pages must be
hidden from a viewer and 404-like for admins (admins still see a "בקרוב"
placeholder).

- [ ] `/api/features` returns the expected state (no auth needed)

  ```sh
  curl -sS "$CF_URL/api/features" | jq .
  # expect: all four flags = false for staging
  ```

- [ ] Browser: logged in as admin, sidebar shows **Query Builder, Backtest,
      Pipeline, Rankings** greyed out with "בקרוב" pills
- [ ] Navigating to `$CF_URL/query` shows the "🚧 בקרוב" placeholder (admin view)
- [ ] Gush Map is still enabled (not flag-gated — by design, see
      batch-5 notes)
- [ ] Flip a flag in the running env and verify UI reacts within ~5 min
      (SWR revalidation window):

  ```sh
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
      --force-new-deployment \
      # after temporarily setting FF_QUERY_BUILDER=true in the task def env
      # (or change via terraform + apply)
  ```

  Skip this step if you don't want to do a full round-trip; the unit tests
  for this already cover it.

---

## 7. Data & reports

> This section assumes you've already run `seed-staging` per DEPLOYMENT.md
> step 6. If not, do that first.

- [ ] Cities endpoint returns the three seeded cities

  ```sh
  curl -sS "$CF_URL/api/cities" -H "Authorization: Bearer $TOKEN" | jq .
  # NOTE: this endpoint is currently /cities (root), not /api/cities.
  # PRODUCTION_CHECKLIST item: migrate legacy routes under /api/*.
  curl -sS "$CF_URL/cities" | jq length
  # expect: 3  (ירושלים, חדרה, אופקים)
  ```

- [ ] Dashboard shows Hebrew data — load `$CF_URL/` in browser and confirm
      the city tabs populate, metric cards show numbers, and the price trend
      chart renders

- [ ] Report generation end-to-end (Bedrock)

  ```sh
  curl -sS -X POST "$CF_URL/reports/generate" \
      -H 'Content-Type: application/json' \
      -d '{"city":"חדרה","report_type":"city_overview"}' | jq '{model_used, cached, generation_time_ms, report_content_head: (.report_content[0:200])}'
  # expect: model_used contains "claude-3-5-sonnet", non-empty report_content
  #         in Hebrew. generation_time_ms ~5-15s.
  ```

- [ ] If Bedrock is unreachable (bad creds, not-granted model access), the
      report **still generates** without the narrative — confirm by
      temporarily denying `bedrock:InvokeModel` on the task role and
      re-running the above. `report_content` should be empty but the
      response still 200s, and `aggregation_data` is populated.
      (Restore the perm after this check.)

---

## 8. CloudWatch logs + alarms

- [ ] ECS logs are streaming

  ```sh
  aws logs describe-log-streams --log-group-name "$LOG_GROUP" \
      --order-by LastEventTime --descending --limit 3 \
      --query 'logStreams[].{name:logStreamName,last:lastEventTimestamp}' \
      --output table
  # expect: one or more streams named "api/api/<task-id>", recent timestamps
  ```

- [ ] Tail the most recent stream — you should see uvicorn startup lines
      plus any requests you've made during this smoke test

  ```sh
  STREAM=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" \
      --order-by LastEventTime --descending --limit 1 \
      --query 'logStreams[0].logStreamName' --output text)
  aws logs get-log-events \
      --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM" \
      --limit 30 --query 'events[].message' --output text
  ```

- [ ] Alarms exist and are currently OK

  ```sh
  aws cloudwatch describe-alarms \
      --alarm-name-prefix rs-intelligence-staging \
      --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' \
      --output table
  # expect: two rows, both StateValue=OK
  # (ecs-no-running-task may show INSUFFICIENT_DATA if Container Insights
  # is off — documented caveat in modules/monitoring/README.md)
  ```

- [ ] Alarm round-trip (optional but strong): trigger then clear

  ```sh
  # Scale service to 0 — RunningTaskCount will hit < 1 after ~5 min
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --desired-count 0
  # Wait ~6 min, check inbox for SNS alarm email
  # Scale back to 1
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --desired-count 1
  # Wait another 6 min, expect OK email
  ```

  Only run this if you're willing to take the service down for ~10 minutes.

---

## 9. EventBridge (scheduling)

Daily-sync is **disabled by default** for staging (see
`modules/scheduling/README.md`). This section mostly verifies the module
wired up cleanly.

- [ ] No enabled rules targeting the cluster (default state)

  ```sh
  aws events list-rules \
      --name-prefix rs-intelligence-staging \
      --query 'Rules[].{name:Name,state:State}' \
      --output table
  # expect: empty — or at most entries with State=DISABLED if you flipped vars
  ```

- [ ] If you DID flip `enable_daily_sync = true`, the rule runs correctly

  ```sh
  # Manually invoke it:
  aws events put-events \
      --entries 'Source=manual.test,DetailType=manual-sync,Detail={}'
  # ...then check cluster tasks + CloudWatch logs for a RunTask-launched container.
  ```

---

## 10. ECS Exec (admin onboarding)

- [ ] Interactive shell opens

  ```sh
  TASK_ARN=$(aws ecs list-tasks --cluster "$ECS_CLUSTER" \
      --service-name "$ECS_SERVICE" --query 'taskArns[0]' --output text)
  aws ecs execute-command \
      --cluster "$ECS_CLUSTER" --task "$TASK_ARN" --container api \
      --interactive --command "/bin/sh"
  ```

- [ ] Inside the shell, verify env wiring

  ```sh
  # Migrations at head
  python -m dara_v2 db-current
  # expect: "0001 (head)"

  # Secret injection worked
  env | grep -E 'DATABASE_URL|JWT_SECRET|AWS_REGION|LLM_PROVIDER'
  # expect: DATABASE_URL=postgresql://... JWT_SECRET=<long-random>
  #         AWS_REGION=eu-west-1 LLM_PROVIDER=bedrock

  # DB connectivity
  python -c "from sqlalchemy import create_engine, text; from dara_v2.config import settings; e=create_engine(settings.database_url); print(e.connect().execute(text('SELECT 1')).scalar())"
  # expect: 1

  # Create another tester
  python -m dara_v2 create-user --email tester@example.com \
      --password 'tester-temp-pass' --name 'Test User' --role viewer

  # List users
  python -m dara_v2 list-users
  # expect: admin + the new tester

  exit
  ```

---

## 11. CI/CD round-trip

- [ ] **Backend** — trivial commit triggers build + deploy

  ```sh
  cd dara-v2
  git checkout -b smoke/backend-bump
  echo "# smoke-test $(date -u +%FT%TZ)" >> README.md
  git commit -am "smoke: backend CI test"
  git push origin smoke/backend-bump
  gh pr create --fill --base main --head smoke/backend-bump
  gh pr merge --squash --delete-branch
  gh run watch
  ```

  Then verify:
  - [ ] Workflow passes all steps (pytest → build → push → update-service → wait-stable)
  - [ ] A new `:latest` image is in ECR (pushed_at > your export)
  - [ ] ECS service rolled (check `runningCount` briefly shows 2 then back to 1)
  - [ ] Response to `$CF_URL/api/health` returns the new `uptime_seconds` counter starting low

- [ ] **Frontend** — same pattern

  ```sh
  cd ../dara-v2-ui
  git checkout -b smoke/frontend-bump
  echo "# smoke-test $(date -u +%FT%TZ)" >> README.md
  git commit -am "smoke: frontend CI test"
  git push origin smoke/frontend-bump
  gh pr create --fill --base main --head smoke/frontend-bump
  gh pr merge --squash --delete-branch
  gh run watch
  ```

  Then verify:
  - [ ] Workflow passes (typecheck → lint → build → s3 sync → invalidate)
  - [ ] `aws s3 ls "s3://$FRONTEND_BUCKET/"` shows updated `LastModified` on `index.html`
  - [ ] After CloudFront invalidation completes (~1 min), hard-refresh
        `$CF_URL/` in the browser — no stale content

---

## 12. Negative / edge cases

- [ ] Legacy root endpoints reachable through CloudFront `/api/*`? **No**
      — CloudFront only routes `/api/*` to the ALB. Verify:

  ```sh
  # These root paths ARE reachable if you hit the ALB directly (inside VPC)
  # but NOT through CloudFront. This is the staging threat model.
  curl -sS -o /dev/null -w '%{http_code}\n' "$CF_URL/cities"
  # expect: 403 or 404 (CloudFront default behavior serves S3 which has no /cities key)
  ```

  This behavior is known and documented in
  [PRODUCTION_CHECKLIST.md](https://github.com/squanchy667/dara-v2-docs/blob/main/PRODUCTION_CHECKLIST.md)
  under "Legacy root-level endpoints are unauthenticated" — the fix
  (move all routes under `/api/*`) is tracked as a prod-blocker.

- [ ] RDS NOT reachable from outside the VPC

  ```sh
  RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
  psql "postgresql://dara:wrong@${RDS_ENDPOINT}/dara_v2" -c "SELECT 1" 2>&1 | head -1
  # expect: connection timed out / refused — ingress is ECS-SG-only
  ```

- [ ] Frontend bucket NOT directly readable

  ```sh
  curl -sS -o /dev/null -w '%{http_code}\n' \
      "https://${FRONTEND_BUCKET}.s3.${AWS_REGION}.amazonaws.com/index.html"
  # expect: 403 — OAC-only access
  ```

---

## 13. Wrap-up

- [ ] Every failing step logged as a GitHub issue on the relevant repo
- [ ] TASK_BOARD.md marked with smoke-test completion date
- [ ] Passwords / tokens recorded in password manager (NOT in this file, NOT in a commit)
- [ ] Staging URL `$CF_URL` shared with internal testers
- [ ] Reviewed `PRODUCTION_CHECKLIST.md` — you know what's deferred before prod

---

## If something breaks mid-run

| Symptom | First thing to check |
|---------|-----------------------|
| `curl $CF_URL/api/health` hangs | ECS task crash-looping → `aws logs get-log-events` on the latest stream |
| 401 on `/api/auth/login` with correct creds | User wasn't created in RDS → ECS Exec → `dara-v2 list-users` |
| 502 / 503 from CloudFront on `/api/*` | ALB target unhealthy → `aws elbv2 describe-target-health` |
| Migration errors on boot | `aws logs get-log-events ... | grep alembic` → read the failed revision, fix, redeploy |
| `CertificateError` in browser | You're hitting the ALB DNS directly instead of CloudFront |
| Bedrock 403 / AccessDeniedException | Task role missing `bedrock:InvokeModel` on the model ARN, or model access not granted (T047) |
| SNS emails not arriving | Subscription still `PendingConfirmation` → re-send from SNS console |

Good luck.
