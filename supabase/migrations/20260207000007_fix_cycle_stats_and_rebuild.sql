-- Re-insert shop_cycle_stats seed rows that were removed by the truncate,
-- then re-run rebuild_restock_history to compute appearance rates.
INSERT INTO shop_cycle_stats VALUES ('seed', 0, NULL), ('egg', 0, NULL), ('decor', 0, NULL)
ON CONFLICT DO NOTHING;

SELECT rebuild_restock_history();
SELECT rebuild_weather_summary();
