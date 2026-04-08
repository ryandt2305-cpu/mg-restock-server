-- Implement "Conditional Prediction" (Mean Residual Life)
-- FIX: Added DROP VIEW to handle column reordering/renaming

DROP VIEW IF EXISTS restock_predictions;

CREATE OR REPLACE VIEW restock_predictions AS
WITH calculations AS (
  SELECT
    h.item_id,
    h.shop_type,
    h.median_interval_ms,
    h.appearance_rate AS base_rate,
    h.last_seen,
    
    -- Cycle Time Helper
    CASE h.shop_type
      WHEN 'seed' THEN 300000
      WHEN 'egg' THEN 900000
      WHEN 'decor' THEN 3600000
      ELSE 300000
    END::numeric AS cycle_ms,
    
    -- Step 1: Calculate Current Probability (Step Boost Logic)
    CASE
      -- Hard Cap (Day 22+)
      WHEN (EXTRACT(EPOCH FROM (now() - to_timestamp(h.last_seen / 1000.0))) / 86400) >= 22
      THEN 0.9999
      
      -- Boost Phase (Day 15-22)
      WHEN (EXTRACT(EPOCH FROM (now() - to_timestamp(h.last_seen / 1000.0))) / 86400) >= 15
      THEN LEAST(0.9999, h.appearance_rate * 5.0)
      
      -- Standard Phase
      ELSE h.appearance_rate
    END AS current_probability,
    
    -- Step 2: Baseline Estimate (Median)
    COALESCE(h.median_interval_ms, h.average_interval_ms) AS baseline_interval_ms

  FROM restock_history h
)
SELECT
  c.item_id,
  c.shop_type,
  c.median_interval_ms,
  c.base_rate,
  c.last_seen,
  c.current_probability,
  
  -- Final Prediction Logic
  CASE
    -- Scenario A: Already Overdue (Now > Last Seen + Baseline)
    -- Predict: Now + (CycleTime / CurrentProbability)
    WHEN (c.last_seen + c.baseline_interval_ms) < (EXTRACT(EPOCH FROM now()) * 1000)::bigint
    THEN (EXTRACT(EPOCH FROM now()) * 1000)::bigint + (c.cycle_ms / GREATEST(0.0001, c.current_probability))::bigint
    
    -- Scenario B: Not Overdue
    -- Predict: Last Seen + Baseline
    ELSE (c.last_seen + c.baseline_interval_ms)
  END AS estimated_next_timestamp,

  -- For Debugging/UI
  c.baseline_interval_ms AS expected_interval_ms

FROM calculations c;
