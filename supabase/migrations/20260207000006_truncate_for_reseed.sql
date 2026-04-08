-- Truncate all event and derived tables before re-seeding with fixed aliases.
-- This ensures clean data without the old Tulip/Pine data loss or +60000 offset.
TRUNCATE
  public.restock_events,
  public.restock_history,
  public.weather_events,
  public.weather_summary,
  public.shop_cycle_stats;
