-- Backfill fingerprints for nulls (deterministic)
update public.restock_events
set fingerprint = concat(
  shop_type, ':', timestamp::text, ':',
  coalesce(
    (
      select string_agg(item_part, '|' order by item_part)
      from (
        select concat(coalesce(item->>'itemId',''), ':', coalesce(item->>'stock', item->>'quantity', '')) as item_part
        from jsonb_array_elements(items) as item
      ) parts
    ),
    ''
  )
)
where fingerprint is null;

-- Enforce NOT NULL after backfill
alter table public.restock_events
  alter column fingerprint set not null;
