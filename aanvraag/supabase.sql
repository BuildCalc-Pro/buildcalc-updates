-- BuildCalc Inmeten: Supabase-koppeling.
-- Plak dit in Supabase > SQL Editor en klik op Run. Je kunt het later opnieuw draaien; het maakt niets dubbel.
-- De tabellen zijn dicht; alleen de functies hieronder mogen erbij. De sleutel bewijst dat jij de calculator bent.
-- Een collega krijgt een afgeleide sleutel: die mag de lijst zien en inmeten, maar geen werkvoorbereiders zien of toevoegen.

create table if not exists inm_instelling (sleutel text primary key);
create table if not exists inm_wvb (
  id bigint generated always as identity primary key,
  naam text not null, email text,
  token text unique not null default substr(md5(random()::text || clock_timestamp()::text), 1, 16),
  toegevoegd timestamptz default now());
create table if not exists inm_aanvraag (
  id bigint generated always as identity primary key,
  wvb_id bigint references inm_wvb(id),
  adres text not null, opdrachtgever text, deadline date,
  status text not null default 'open',
  ingediend timestamptz default now(), ingemeten timestamptz);

alter table inm_aanvraag add column if not exists door text;

alter table inm_instelling enable row level security;
alter table inm_wvb enable row level security;
alter table inm_aanvraag enable row level security;

-- Alleen de sleutel uit deze SQL blijft geldig. Maak je in BuildCalc een nieuwe sleutel, dan werken oude koppelingen niet meer.
delete from inm_instelling where sleutel <> 'PLAK_HIER_DE_SLEUTEL';
insert into inm_instelling values ('PLAK_HIER_DE_SLEUTEL') on conflict do nothing;

-- 'beheer' = jouw eigen sleutel, 'collega' = sha256 van 'collega:' + jouw sleutel.
create or replace function inm_rol(p_sleutel text) returns text language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_sleutel, '') <> '' and p_sleutel <> 'PLAK' || 'HIER_DE_SLEUTEL' then
    if exists (select 1 from inm_instelling where sleutel = p_sleutel) then return 'beheer'; end if;
    if exists (select 1 from inm_instelling where sleutel <> 'PLAK' || 'HIER_DE_SLEUTEL'
      and encode(sha256(convert_to('collega:' || sleutel, 'UTF8')), 'hex') = p_sleutel) then return 'collega'; end if;
  end if;
  raise exception 'Sleutel klopt niet. Kopieer de SQL opnieuw vanuit BuildCalc.';
end $$;

create or replace function inm_ok(p_sleutel text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform inm_rol(p_sleutel);
end $$;

create or replace function inm_beheer(p_sleutel text) returns void language plpgsql security definer set search_path = public as $$
begin
  if inm_rol(p_sleutel) <> 'beheer' then raise exception 'Alleen de beheerder kan dit.'; end if;
end $$;

-- Calculator
drop function if exists inm_lijst(text);
create or replace function inm_lijst(p_sleutel text)
returns table(id bigint, adres text, opdrachtgever text, deadline date, status text, ingediend timestamptz, wvb text, email text, door text)
language plpgsql security definer set search_path = public as $$
begin
  perform inm_ok(p_sleutel);
  return query select a.id, a.adres, a.opdrachtgever, a.deadline, a.status, a.ingediend, w.naam, w.email, a.door
    from inm_aanvraag a left join inm_wvb w on w.id = a.wvb_id where a.status <> 'verwijderd' order by a.deadline nulls last, a.id;
end $$;

create or replace function inm_status(p_sleutel text, p_id bigint, p_status text) returns json
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  perform inm_ok(p_sleutel);
  update inm_aanvraag set status = p_status, ingemeten = case when p_status = 'ingemeten' then now() end where id = p_id;
  select a.adres, w.naam, w.email into r from inm_aanvraag a left join inm_wvb w on w.id = a.wvb_id where a.id = p_id;
  return json_build_object('ok', true, 'mail', false, 'email', r.email, 'wvb', r.naam);
end $$;

create or replace function inm_wvb_lijst(p_sleutel text) returns table(naam text, email text, token text)
language plpgsql security definer set search_path = public as $$
begin
  perform inm_beheer(p_sleutel);
  return query select w.naam, w.email, w.token from inm_wvb w order by w.naam;
end $$;

create or replace function inm_wvb_toevoegen(p_sleutel text, p_naam text, p_email text) returns json
language plpgsql security definer set search_path = public as $$
declare t text;
begin
  perform inm_beheer(p_sleutel);
  insert into inm_wvb(naam, email) values (p_naam, nullif(p_email, '')) returning token into t;
  return json_build_object('ok', true, 'token', t);
end $$;

-- Wie meet dit adres in? Leeg = niemand. Een ander kan een adres dat al gepakt is niet overnemen.
create or replace function inm_pak(p_sleutel text, p_id bigint, p_door text) returns json
language plpgsql security definer set search_path = public as $$
declare huidig text;
begin
  perform inm_ok(p_sleutel);
  select door into huidig from inm_aanvraag where id = p_id;
  if coalesce(p_door, '') <> '' and coalesce(huidig, '') <> '' and huidig <> p_door then raise exception '% meet dit al in', huidig; end if;
  update inm_aanvraag set door = nullif(p_door, '') where id = p_id;
  return json_build_object('ok', true);
end $$;

-- Werkvoorbereider (met de token uit zijn link)
create or replace function inm_mijn(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare w inm_wvb;
begin
  select * into w from inm_wvb where token = p_token;
  if w.id is null then raise exception 'Deze link werkt niet (meer). Vraag de calculator om een nieuwe link.'; end if;
  return json_build_object('naam', w.naam, 'items', coalesce((select json_agg(json_build_object('adres', a.adres, 'opdrachtgever', a.opdrachtgever, 'deadline', a.deadline, 'status', a.status) order by a.deadline)
    from inm_aanvraag a where a.wvb_id = w.id and a.status <> 'verwijderd'), '[]'::json));
end $$;

create or replace function inm_indienen(p_token text, p_opdrachtgever text, p_deadline date, p_adressen text[]) returns json
language plpgsql security definer set search_path = public as $$
declare w inm_wvb; n int;
begin
  select * into w from inm_wvb where token = p_token;
  if w.id is null then raise exception 'Deze link werkt niet (meer). Vraag de calculator om een nieuwe link.'; end if;
  if coalesce(array_length(p_adressen, 1), 0) = 0 or array_length(p_adressen, 1) > 500 then raise exception 'Geen of te veel adressen'; end if;
  insert into inm_aanvraag(wvb_id, adres, opdrachtgever, deadline)
    select w.id, trim(x), p_opdrachtgever, p_deadline from unnest(p_adressen) x where trim(x) <> '';
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'aantal', n);
end $$;

revoke execute on function inm_ok(text), inm_rol(text), inm_beheer(text) from public, anon, authenticated;
grant execute on function inm_lijst(text), inm_status(text, bigint, text), inm_pak(text, bigint, text), inm_wvb_lijst(text), inm_wvb_toevoegen(text, text, text),
  inm_mijn(text), inm_indienen(text, text, date, text[]) to anon;
