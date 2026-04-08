alter table restock_events
  add column if not exists fingerprint text;

create unique index if not exists restock_events_fingerprint_idx
  on restock_events (fingerprint);
