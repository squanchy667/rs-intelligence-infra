project_name = "rs-intelligence"
environment  = "dev"
aws_region   = "eu-west-1"
bundle_id    = "small_3_0" # 2 GB / 2 vCPU / 60 GB ~ $12/mo dualstack (was micro_3_0, 1 GB ~ $7/mo; CEO word 2026-09-14 — resize the test box before promote, same path as dev2)
# 2026-09-14 resize: Lightsail cannot resize in place, so the new box is a small_3_0
# instance created from the micro box's snapshot (rs-intelligence-dev-box-pre-resize-20260914)
# and imported into this state; the old rs-intelligence-dev-box stays STOPPED outside
# state until the CEO deletes it. Static IP rs-intelligence-dev-ip (54.195.65.131) moved over.
# NB: this root is the TEST (review) box, test.rs-intel.com — the directory name predates the split (DEV.md).
instance_name = "rs-intelligence-dev-box-2"
