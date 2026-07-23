BEGIN;
-- city-scoped tables
DELETE FROM presentation_deals WHERE city_id IN (5534,5535);
-- crossref chain (children before parents)
DELETE FROM crossref_matches WHERE run_id IN (SELECT id FROM crossref_runs WHERE city_id IN (5534,5535))
   OR nadlan_row_id IN (SELECT id FROM nadlan_snapshot WHERE run_id IN (SELECT id FROM crossref_runs WHERE city_id IN (5534,5535)) OR deal_id IN (SELECT id FROM deals WHERE city_id IN (5534,5535)));
DELETE FROM nadlan_snapshot WHERE run_id IN (SELECT id FROM crossref_runs WHERE city_id IN (5534,5535))
   OR deal_id IN (SELECT id FROM deals WHERE city_id IN (5534,5535));
DELETE FROM tax_authority_snapshot_61 WHERE run_id IN (SELECT id FROM crossref_runs WHERE city_id IN (5534,5535));
DELETE FROM tax_authority_snapshot_legacy WHERE run_id IN (SELECT id FROM crossref_runs WHERE city_id IN (5534,5535));
DELETE FROM deals WHERE city_id IN (5534,5535);
DELETE FROM tenders WHERE city_id IN (5534,5535);
DELETE FROM market_snapshots WHERE city_id IN (5534,5535);
DELETE FROM reports WHERE city_id IN (5534,5535);
-- (tax_authority_snapshot_all is a VIEW over per-city tables — no delete needed)
DELETE FROM tax_deals_clean WHERE city_id IN (5534,5535);
DELETE FROM tax_authority_snapshot_5534;
DELETE FROM tax_authority_snapshot_5535;
DELETE FROM crossref_runs WHERE city_id IN (5534,5535);
-- settlement-scoped tables (Bat Yam 6200, TLV 5000)
DELETE FROM amenities WHERE settlement_id IN ('6200','5000');
DELETE FROM construction_permits WHERE settlement_id IN ('6200','5000');
DELETE FROM mavat_plans WHERE settlement_id IN ('6200','5000');
DELETE FROM renewal_complexes WHERE settlement_id IN ('6200','5000');
DELETE FROM xplan_plans WHERE settlement_id IN ('6200','5000');
DELETE FROM cbs_indices WHERE settlement_id IN ('6200','5000');
-- projects + children + presentation layer
DELETE FROM presentation_projects WHERE project_id IN (SELECT id FROM projects WHERE settlement_id IN ('6200','5000'));
DELETE FROM project_parties WHERE project_id IN (SELECT id FROM projects WHERE settlement_id IN ('6200','5000'));
DELETE FROM project_parcels WHERE project_id IN (SELECT id FROM projects WHERE settlement_id IN ('6200','5000'));
DELETE FROM project_addresses WHERE project_id IN (SELECT id FROM projects WHERE settlement_id IN ('6200','5000'));
DELETE FROM project_status_history WHERE project_id IN (SELECT id FROM projects WHERE settlement_id IN ('6200','5000'));
DELETE FROM ml_projects WHERE canonical_project_id IN (SELECT id FROM projects WHERE settlement_id IN ('6200','5000'));
DELETE FROM projects WHERE settlement_id IN ('6200','5000');
-- supply + tenders presentation
DELETE FROM presentation_supply WHERE settlement_code IN ('6200','5000');
DELETE FROM presentation_tenders WHERE tender_id NOT IN (SELECT id::text FROM tenders);
-- developer links whose deals are gone; then developers with no links left
DELETE FROM deal_developers WHERE deal_id NOT IN (SELECT deal_id FROM presentation_deals);
DELETE FROM developers WHERE id NOT IN (SELECT DISTINCT developer_id FROM deal_developers);
-- cities themselves
DELETE FROM cities WHERE id IN (5534,5535);
COMMIT;
