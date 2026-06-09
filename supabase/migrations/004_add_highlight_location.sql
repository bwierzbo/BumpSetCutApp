-- Add location tagging to highlights (park/court where the rally was played)
alter table highlights
  add column if not exists location_name text,
  add column if not exists latitude  double precision,
  add column if not exists longitude double precision;

create index if not exists idx_highlights_location on highlights(location_name);
