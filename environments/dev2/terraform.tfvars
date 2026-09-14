project_name = "rs-intelligence"
environment  = "dev2"
aws_region   = "eu-west-1"
bundle_id    = "small_3_0" # 2 GB / 2 vCPU / 60 GB ~ $12/mo dualstack (was micro_3_0, 1 GB ~ $7/mo; CEO word 2026-09-14 — box RAM was the first bottleneck, reports/INFRA_CAPACITY_2026-09-14.md)
# 2026-09-14 resize: Lightsail cannot resize in place, so the new box is a small_3_0
# instance created from the micro box's snapshot (rs-intelligence-dev2-box-pre-resize-20260914)
# and imported into this state; the old rs-intelligence-dev2-box stays STOPPED outside
# state until the CEO deletes it. Static IP rs-intelligence-dev2-ip (54.155.62.174) moved over.
instance_name = "rs-intelligence-dev2-box-2"
