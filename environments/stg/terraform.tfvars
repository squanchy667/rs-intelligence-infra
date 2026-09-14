project_name = "rs-intelligence"
environment  = "stg"
aws_region   = "eu-west-1"
bundle_id    = "small_3_0" # 2 GB / 2 vCPU / 60 GB ~ $12/mo dualstack (CEO word 2026-09-14, plans/PLAN_STG_STANDUP_2026-09-14.md: never micro — box RAM was the first bottleneck on the 1 GB micros, reports/INFRA_CAPACITY_2026-09-14.md)
# instance_name stays null on a fresh apply (module default <project>-stg-box). Set it only after a
# snapshot-based resize (DEV.md "Resize a box" step 7), exactly as dev/dev2 do today.
