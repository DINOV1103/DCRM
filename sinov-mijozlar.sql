-- =====================================================================
--  DCRM — 10 000 ta tasodifiy sinov mijoz (bitim) qo‘shish
--  Qayerda: Supabase → SQL Editor → New query → shu faylni to‘liq qo‘yib "Run".
--
--  • Bitimlar barcha FAOL foydalanuvchilarga teng bo‘linadi: har bir menejer o‘zinikini,
--    admin hammasini ko‘radi.
--  • Ismlar, viloyat, manzil, mahsulot, summa, bosqich, vazifa va tarix — tasodifiy.
--  • Bosqichlar bazangizdagi ro‘yxatdan olinadi (Sozlamalar → Bosqichlar).
--  • Telefonlar "+998 00 ..." ko‘rinishida: bunday operator yo‘q, menejer adashib bossa ham
--    begona odamga qo‘ng‘iroq ketmaydi.
--  • Hammasi client.batch = 'sinov-10k' belgisi bilan. O‘chirish uchun (bitta qator):
--      delete from public.deals where client->>'batch' = 'sinov-10k';
-- =====================================================================
do $$
declare
  jami   int     := 10000;   -- nechta bitim qo‘shiladi
  takror boolean := false;   -- ikkinchi marta qo‘shmoqchi bo‘lsangiz: true

  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
  day_ms bigint := 86400000;
  owners uuid[]; onames text[]; n_owners int;
  open_k text[]; won_k text[]; lost_k text[]; first_k text;
  bor int; qoshildi int;

  malef text[] := array['Rustam','Otabek','Jasur','Sardor','Bekzod','Anvar','Shavkat','Ulug''bek','Dilshod','Akmal',
                        'Farrux','Sanjar','Islom','Elyor','Bahodir','Nodir','Sherzod','Azamat','Jamshid','Komil'];
  femf  text[] := array['Dilnoza','Ziyoda','Gulsanam','Madina','Feruza','Shahzoda','Nigora','Kamola','Mohira','Sevara',
                        'Zarina','Lola','Nodira','Barno','Mavluda','Hilola','Nasiba','Dildora','Gulnora','Saodat'];
  sur   text[] := array['Karimov','Ahmedov','Umarov','Mirzayev','Qosimov','Alimov','Yo''ldoshev','Normatov','Qodirov','Sobirov',
                        'Hasanov','Davlatov','Tursunov','Saidov','Ergashev','Nazarov','Jo''rayev','Xolmatov','Abdullayev','Ismoilov',
                        'Raximov','Qurbonov','Yusupov','Sharipov','Tojiboyev'];
  prodn text[] := array['ABIHAYAT 200ml','ABIHAYAT 100ml','ABIHAYAT Premium','ABIHAYAT Kompleks 2x','ABIHAYAT Kompleks 3x',
                        'ABIHAYAT 200ml','ABIHAYAT Kompleks 5x','ABIHAYAT 200ml','ABIHAYAT Ulgurji 10x','ABIHAYAT 100ml'];
  prodp numeric[] := array[1450000,950000,2800000,3100000,4200000,1450000,7200000,1450000,13500000,950000];
  cities text[] := array['Toshkent','Toshkent viloyati','Andijon','Buxoro','Farg''ona','Jizzax','Namangan','Navoiy',
                         'Qashqadaryo','Qoraqalpog''iston','Samarqand','Sirdaryo','Surxondaryo','Xorazm'];
  sources text[] := array['Instagram','Telegram Ads','Tavsiya','Sayt','Qo''ng''iroq'];
  streets text[] := array['Navoiy ko‘chasi','Mustaqillik ko‘chasi','Amir Temur ko‘chasi','Istiqlol ko‘chasi',
                          'Bog‘ishamol ko‘chasi','Do‘stlik mahallasi','Yangi hayot mahallasi','Guliston mahallasi'];
begin
  select count(*) into bor from public.deals where client->>'batch' = 'sinov-10k';
  if bor > 0 and not takror then
    raise exception 'Sinov mijozlar allaqachon qo‘shilgan (% ta). Yana qo‘shish uchun yuqorida takror := true qiling.', bor;
  end if;

  select array_agg(id order by full_name, id), array_agg(coalesce(nullif(full_name, ''), split_part(email, '@', 1)) order by full_name, id)
    into owners, onames from public.profiles where active;
  n_owners := coalesce(array_length(owners, 1), 0);
  if n_owners = 0 then raise exception 'Faol foydalanuvchi topilmadi'; end if;

  select array_agg(key order by position) filter (where kind = 'open'),
         array_agg(key order by position) filter (where kind = 'won'),
         array_agg(key order by position) filter (where kind = 'lost')
    into open_k, won_k, lost_k from public.stages;
  if open_k is null then open_k := array['ПЕРВИЧНЫЙ']; end if;
  won_k := coalesce(won_k, open_k); lost_k := coalesce(lost_k, open_k);
  first_k := open_k[1];

  insert into public.deals (name, owner, owner_id, created_ts, funnel, stage, order_date, budget, product, qty,
                            client, tasks, events, updated_at, created_at)
  select
    upper(src) || ' ' || split_part(pr, ' ', 1) || ' ' || upper(fname),
    oname, oid, ts,
    case when qs then 'Qayta sotuv' when price > 10000000 then 'Ulgurji mijozlar' else 'Sotuv varonkasi' end,
    st,
    (to_timestamp(ts / 1000.0) + interval '2 days')::date,
    price, pr, 1,
    jsonb_build_object(
      'name', fullname, 'phone', ph1,
      'phones', case when xp then jsonb_build_array(ph2) else '[]'::jsonb end,
      'city', city, 'addr', street || ', ' || house || '-uy', 'source', src, 'email', '', 'ig', '',
      'batch', 'sinov-10k'),
    case
      when closed then jsonb_build_array(jsonb_build_object('id', 't_s' || g || '_1', 'title', 'Buyurtmani tasdiqlash',
                         'due', to_char(to_timestamp((ts + day_ms) / 1000.0) at time zone 'Asia/Tashkent', 'YYYY-MM-DD HH24:MI'),
                         'done', true, 'owner', oname))
      when tt = 1 then jsonb_build_array(jsonb_build_object('id', 't_s' || g || '_1', 'title', 'Qayta qo‘ng‘iroq qilish',
                         'due', to_char(now() at time zone 'Asia/Tashkent' - ((k4 + 1) * interval '5 hours'), 'YYYY-MM-DD HH24:MI'),
                         'done', false, 'owner', oname))
      when tt = 2 then jsonb_build_array(jsonb_build_object('id', 't_s' || g || '_1', 'title', 'To‘lovni tekshirish',
                         'due', to_char(least(now() at time zone 'Asia/Tashkent' + ((k6 + 1) * interval '1 hour'),
                                              date_trunc('day', now() at time zone 'Asia/Tashkent') + interval '23 hours 59 minutes'), 'YYYY-MM-DD HH24:MI'),
                         'done', false, 'owner', oname))
      when tt <> 0 then jsonb_build_array(jsonb_build_object('id', 't_s' || g || '_1', 'title', 'Buyurtmani tasdiqlash',
                         'due', to_char(now() at time zone 'Asia/Tashkent' + ((k4 + 1) * interval '1 day'), 'YYYY-MM-DD HH24:MI'),
                         'done', false, 'owner', oname))
      else '[]'::jsonb
    end,
    case when st <> first_k
      then jsonb_build_array(
             jsonb_build_object('t', 'event', 'kind', 'stage', 'ts', ts + 1800000, 'by', oname, 'from', first_k, 'to', st),
             jsonb_build_object('t', 'event', 'kind', 'create', 'ts', ts, 'by', oname))
      else jsonb_build_array(jsonb_build_object('t', 'event', 'kind', 'create', 'ts', ts, 'by', oname))
    end,
    to_timestamp((ts + 1800000) / 1000.0),
    to_timestamp(ts / 1000.0)
  from (
    select b.*,
      owners[oi] as oid, onames[oi] as oname,
      case when fem then femf[fi] else malef[fi] end as fname,
      case when fem then femf[fi] || ' ' || sur[si] || 'a' else malef[fi] || ' ' || sur[si] end as fullname,
      prodn[pi] as pr, prodp[pi] as price, cities[ci] as city, sources[sri] as src, streets[sti] as street,
      st, (st = any(won_k) or st = any(lost_k)) as closed
    from (
      select g,
        1 + ((g - 1) % n_owners) as oi,
        random() < 0.5 as fem,
        1 + floor(random() * 20)::int as fi,
        1 + floor(random() * 25)::int as si,
        1 + floor(random() * 10)::int as pi,
        1 + floor(random() * 14)::int as ci,
        1 + floor(random() * 5)::int  as sri,
        1 + floor(random() * 8)::int  as sti,
        1 + floor(random() * 120)::int as house,
        floor(random() * 5)::int as tt,           -- vazifa turi: 0 yo‘q, 1 kechikkan, 2 bugun, 3-4 keyingi kunlar
        floor(random() * 4)::int as k4, floor(random() * 6)::int as k6,
        random() < 1.0 / 6 as xp,                 -- qo‘shimcha raqam
        random() < 1.0 / 9 as qs,                 -- qayta sotuv
        -- ~26 daqiqada bitta: 10 000 ta bitim taxminan oxirgi 6 oyga yoyiladi
        now_ms - g::bigint * 1555000 - floor(random() * 1500000)::bigint as ts,
        random() as r,
        '+998 00 ' || lpad(floor(random() * 1000)::int::text, 3, '0') || ' ' || lpad(floor(random() * 100)::int::text, 2, '0')
                   || ' ' || lpad(floor(random() * 100)::int::text, 2, '0') as ph1,
        '+998 00 ' || lpad(floor(random() * 1000)::int::text, 3, '0') || ' ' || lpad(floor(random() * 100)::int::text, 2, '0')
                   || ' ' || lpad(floor(random() * 100)::int::text, 2, '0') as ph2
      from generate_series(1, jami) g
    ) b
    cross join lateral (
      select case
        when b.g <= 6 then first_k
        -- so‘nggi 3 hafta: asosan jarayonda
        when now_ms - b.ts <= 21 * day_ms then
          case when b.r < 0.70 then open_k[1 + floor(random() * least(array_length(open_k, 1), 5))::int]
               when b.r < 0.82 then won_k[1 + floor(random() * array_length(won_k, 1))::int]
               else lost_k[1 + floor(random() * array_length(lost_k, 1))::int] end
        -- eskilari: asosan yopilgan
        else
          case when b.r < 0.30 then won_k[1 + floor(random() * array_length(won_k, 1))::int]
               when b.r < 0.75 then lost_k[1 + floor(random() * array_length(lost_k, 1))::int]
               else open_k[1 + floor(random() * array_length(open_k, 1))::int] end
      end as st
    ) s
  ) x;

  get diagnostics qoshildi = row_count;
  raise notice 'Qo‘shildi: % ta bitim, % ta foydalanuvchiga bo‘lindi.', qoshildi, n_owners;
end $$;

-- Natija: kimda nechta
select owner as "Menejer", count(*) as "Bitimlar"
from public.deals where client->>'batch' = 'sinov-10k'
group by owner order by 2 desc;
