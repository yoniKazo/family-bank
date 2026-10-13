-- ============================================================
--  הבנק המשפחתי — סכמת Supabase
--  להרצה פעם אחת ב-SQL Editor של Supabase.
--  בסוף הקובץ: להחליף את כתובות המייל של ההורים.
-- ============================================================

-- ---------- עזרי זמן וזהות ----------

-- "היום" לפי שעון ישראל (השרת של Supabase עובד ב-UTC)
create or replace function public.local_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Jerusalem')::date
$$;

-- המייל של המשתמש המחובר (מתוך ה-JWT של Google)
create or replace function public.current_email()
returns text language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

-- ---------- טבלאות ----------

-- כל משפחה רואה ומנהלת רק את הילדים שלה
create table if not exists public.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  created_at  timestamptz not null default now()
);

create table if not exists public.children (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
-- סדר התצוגה (קטן קודם; בשוויון — לפי שם)
alter table public.children add column if not exists sort_order int not null default 0;
alter table public.children add column if not exists family_id uuid references public.families(id);

-- רשימת ההרשאות: רק מי שמופיע כאן יכול לראות משהו
create table if not exists public.members (
  email        text primary key check (email = lower(trim(email)) and email like '%@%'),
  role         text not null check (role in ('parent', 'child')),
  child_id     uuid unique references public.children(id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now(),
  check ((role = 'child') = (child_id is not null))
);
alter table public.members add column if not exists family_id uuid references public.families(id);

-- מנהלי המערכת (מוסיפים משפחות). מוגדרים ב-SQL בלבד
create table if not exists public.admins (
  email text primary key references public.members(email) on delete cascade
);

create table if not exists public.transactions (
  id           uuid primary key default gen_random_uuid(),
  child_id     uuid not null references public.children(id),
  amount       numeric(12,2) not null check (amount <> 0),   -- חיובי = הפקדה, שלילי = משיכה
  occurred_on  date not null default public.local_today(),
  note         text not null default '',
  voided       boolean not null default false,               -- ביטול רך במקום מחיקה
  request_id   uuid,
  created_by   text not null default '',
  created_at   timestamptz not null default now(),
  updated_by   text,
  updated_at   timestamptz
);
create index if not exists transactions_child_idx on public.transactions (child_id, occurred_on desc, created_at desc);

create table if not exists public.requests (
  id             uuid primary key default gen_random_uuid(),
  child_id       uuid not null references public.children(id),
  kind           text not null check (kind in ('deposit', 'withdraw')),
  amount         numeric(12,2) not null check (amount > 0),
  note           text not null default '',
  status         text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  created_by     text not null default '',
  created_at     timestamptz not null default now(),
  decided_by     text,
  decided_at     timestamptz,
  decision_note  text,
  transaction_id uuid references public.transactions(id)
);
-- מתי נשלחה התראת push להורים (נקבע רק ע״י ה-Edge Function, פעם אחת)
alter table public.requests add column if not exists notified_at timestamptz;
create index if not exists requests_child_idx on public.requests (child_id, created_at desc);
create index if not exists requests_pending_idx on public.requests (status) where status = 'pending';

-- מנויי Web Push של ההורים (מכשיר = endpoint)
create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  email      text not null default public.current_email() references public.members(email) on delete cascade,
  keys       jsonb not null,                                -- {p256dh, auth} מ-PushSubscription.toJSON()
  created_at timestamptz not null default now()
);

alter table public.transactions
  drop constraint if exists transactions_request_fk,
  add constraint transactions_request_fk foreign key (request_id) references public.requests(id);

-- ---------- פונקציות הרשאה ----------

create or replace function public.is_parent()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where email = current_email() and role = 'parent')
$$;

create or replace function public.my_child_id()
returns uuid language sql stable security definer set search_path = public as $$
  select child_id from members where email = current_email() and role = 'child'
$$;

create or replace function public.my_family_id()
returns uuid language sql stable security definer set search_path = public as $$
  select family_id from members where email = current_email()
$$;

-- הורה של המשפחה שהילד הזה שייך אליה
create or replace function public.is_parent_of(p_child_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from members m join children c on c.family_id = m.family_id
                 where m.email = current_email() and m.role = 'parent' and c.id = p_child_id)
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where email = current_email())
$$;

-- ילד / חבר חדש שייך למשפחה של מי שהוסיף אותו
alter table public.children alter column family_id set default public.my_family_id();
alter table public.members  alter column family_id set default public.my_family_id();

-- מי אני? (האפליקציה קוראת לזה אחרי התחברות)
drop function if exists public.me();
create function public.me()
returns table (email text, role text, child_id uuid, child_name text, display_name text, is_admin boolean)
language sql stable security definer set search_path = public as $$
  select m.email, m.role, m.child_id, c.name, m.display_name, is_admin()
  from members m left join children c on c.id = m.child_id
  where m.email = current_email()
    and (m.role = 'parent' or c.active)
$$;

-- ---------- טריגרים: מי יצר/עדכן — לא ניתן לזיוף מהלקוח ----------

create or replace function public.tg_transactions_audit()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := current_email();
    new.created_at := now();
    new.updated_by := null;
    new.updated_at := null;
  else
    new.id         := old.id;
    new.child_id   := old.child_id;      -- לא מעבירים פעולה בין ילדים
    new.request_id := old.request_id;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.updated_by := current_email();
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists transactions_audit on public.transactions;
create trigger transactions_audit before insert or update on public.transactions
  for each row execute function public.tg_transactions_audit();

create or replace function public.tg_requests_insert()
returns trigger language plpgsql as $$
begin
  new.status         := 'pending';
  new.created_by     := current_email();
  new.created_at     := now();
  new.decided_by     := null;
  new.decided_at     := null;
  new.decision_note  := null;
  new.transaction_id := null;
  new.notified_at    := null;
  return new;
end $$;

drop trigger if exists requests_insert on public.requests;
create trigger requests_insert before insert on public.requests
  for each row execute function public.tg_requests_insert();

-- ---------- יתרות ----------

create or replace view public.balances with (security_invoker = true) as
  select c.id as child_id, c.name, c.active,
         coalesce(sum(t.amount) filter (where not t.voided), 0)::numeric(12,2) as balance,
         max(t.occurred_on) filter (where not t.voided) as last_activity,
         c.sort_order
  from public.children c
  left join public.transactions t on t.child_id = c.id
  group by c.id;

-- ---------- פעולות על בקשות (רק דרך RPC) ----------

create or replace function public.decide_request(p_request_id uuid, p_approve boolean, p_note text default null)
returns public.requests language plpgsql security definer set search_path = public as $$
declare
  r    requests;
  t_id uuid;
begin
  if not is_parent() then
    raise exception 'רק הורה יכול לטפל בבקשות' using errcode = '42501';
  end if;

  select * into r from requests where id = p_request_id for update;
  if not found or not is_parent_of(r.child_id) then raise exception 'הבקשה לא נמצאה'; end if;
  if r.status <> 'pending' then raise exception 'הבקשה כבר טופלה'; end if;

  if p_approve then
    insert into transactions (child_id, amount, occurred_on, note, request_id)
    values (r.child_id,
            case when r.kind = 'deposit' then r.amount else -r.amount end,
            local_today(),
            r.note,
            r.id)
    returning id into t_id;
  end if;

  update requests
     set status        = case when p_approve then 'approved' else 'rejected' end,
         decided_by    = current_email(),
         decided_at    = now(),
         decision_note = nullif(trim(coalesce(p_note, '')), ''),
         transaction_id = t_id
   where id = r.id
  returning * into r;

  return r;
end $$;

create or replace function public.cancel_request(p_request_id uuid)
returns public.requests language plpgsql security definer set search_path = public as $$
declare r requests;
begin
  update requests
     set status = 'cancelled', decided_by = current_email(), decided_at = now()
   where id = p_request_id
     and status = 'pending'
     and (child_id = my_child_id() or is_parent_of(child_id))
  returning * into r;
  if not found then raise exception 'אי אפשר לבטל את הבקשה הזו'; end if;
  return r;
end $$;

-- ---------- הוספת משפחה (רק מנהל) ----------

-- p_parents: [{"email": "...", "display_name": "..."}, ...]
create or replace function public.add_family(p_name text, p_parents jsonb)
returns public.families language plpgsql security definer set search_path = public as $$
declare f families;
begin
  if not is_admin() then
    raise exception 'רק מנהל המערכת יכול להוסיף משפחה' using errcode = '42501';
  end if;

  insert into families (name) values (trim(p_name)) returning * into f;
  insert into members (email, role, display_name, family_id)
  select lower(trim(p ->> 'email')), 'parent', nullif(trim(coalesce(p ->> 'display_name', '')), ''), f.id
  from jsonb_array_elements(p_parents) p;

  return f;
exception when unique_violation then
  raise exception 'אחד המיילים כבר רשום במערכת';
end $$;

-- ---------- Row Level Security ----------

alter table public.children     enable row level security;
alter table public.members      enable row level security;
alter table public.transactions enable row level security;
alter table public.requests     enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.families     enable row level security;
alter table public.admins       enable row level security;   -- בלי policies: אין גישה מהאפליקציה

-- משפחות: רק המנהל רואה את הרשימה; הוספה רק דרך add_family
drop policy if exists families_select on public.families;
create policy families_select on public.families for select to authenticated
  using (is_admin());

-- ילדים: הורה רואה ומנהל רק את הילדים של המשפחה שלו
drop policy if exists children_select on public.children;
create policy children_select on public.children for select to authenticated
  using ((is_parent() and family_id = my_family_id()) or id = my_child_id());
drop policy if exists children_insert on public.children;
create policy children_insert on public.children for insert to authenticated
  with check (is_parent() and family_id = my_family_id());
drop policy if exists children_update on public.children;
create policy children_update on public.children for update to authenticated
  using (is_parent() and family_id = my_family_id()) with check (is_parent() and family_id = my_family_id());

-- חברים: הורים מנהלים רק שורות של ילדים במשפחה שלהם. שורות הורים — ב-SQL או ע״י המנהל (add_family).
drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using ((is_parent() and family_id = my_family_id()) or email = current_email() or (role = 'parent' and is_admin()));
drop policy if exists members_insert on public.members;
create policy members_insert on public.members for insert to authenticated
  with check (role = 'child' and family_id = my_family_id() and is_parent_of(child_id));
drop policy if exists members_update on public.members;
create policy members_update on public.members for update to authenticated
  using (is_parent() and role = 'child' and family_id = my_family_id())
  with check (role = 'child' and family_id = my_family_id() and is_parent_of(child_id));
drop policy if exists members_delete on public.members;
create policy members_delete on public.members for delete to authenticated
  using (is_parent() and role = 'child' and family_id = my_family_id());

-- תנועות: ילד רואה רק את שלו ורק פעולות שלא בוטלו; אין מחיקה בכלל
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select to authenticated
  using (is_parent_of(child_id) or (child_id = my_child_id() and not voided));
drop policy if exists transactions_insert on public.transactions;
create policy transactions_insert on public.transactions for insert to authenticated
  with check (is_parent_of(child_id));
drop policy if exists transactions_update on public.transactions;
create policy transactions_update on public.transactions for update to authenticated
  using (is_parent_of(child_id)) with check (is_parent_of(child_id));

-- בקשות: ילד יוצר בקשה רק לעצמו; שינויי סטטוס רק דרך ה-RPC
drop policy if exists requests_select on public.requests;
create policy requests_select on public.requests for select to authenticated
  using (is_parent_of(child_id) or child_id = my_child_id());
drop policy if exists requests_insert on public.requests;
create policy requests_insert on public.requests for insert to authenticated
  with check (child_id = my_child_id());

-- מנויי push: הורה מנהל רק את המכשירים של עצמו
drop policy if exists push_subscriptions_own on public.push_subscriptions;
create policy push_subscriptions_own on public.push_subscriptions for all to authenticated
  using (is_parent() and email = current_email()) with check (is_parent() and email = current_email());

-- ---------- Realtime: הורים מקבלים עדכון מיידי על בקשות (RLS חל גם כאן) ----------

do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'requests') then
    alter publication supabase_realtime add table public.requests;
  end if;
end $$;

-- ---------- הרשאות ----------

revoke all on public.children, public.members, public.transactions, public.requests, public.balances, public.push_subscriptions,
              public.families, public.admins from anon;
revoke all on public.families, public.admins from authenticated;
revoke update, delete on public.requests from authenticated;
revoke delete on public.transactions, public.children from authenticated;
grant select, insert, update on public.children, public.transactions to authenticated;
grant select, insert, update, delete on public.members, public.push_subscriptions to authenticated;
grant select, insert on public.requests to authenticated;
grant select on public.balances, public.families to authenticated;

revoke execute on function public.decide_request(uuid, boolean, text), public.cancel_request(uuid), public.add_family(text, jsonb),
                           public.me(), public.is_parent(), public.my_child_id(), public.my_family_id(),
                           public.is_parent_of(uuid), public.is_admin() from public, anon;
grant  execute on function public.decide_request(uuid, boolean, text), public.cancel_request(uuid), public.add_family(text, jsonb),
                           public.me(), public.is_parent(), public.my_child_id(), public.my_family_id(),
                           public.is_parent_of(uuid), public.is_admin() to authenticated;

-- ============================================================
--  המשפחה שלך וההורים — להחליף למיילים האמיתיים (Gmail) ולהריץ.
--  ההורה הראשון הוא גם מנהל המערכת: רק הוא יכול להוסיף משפחות.
-- ============================================================
do $$
declare f uuid;
begin
  select family_id into f from public.members where email = 'yonu.kazokin@gmail.com';
  if f is null then
    insert into public.families (name) values ('קזוקין') returning id into f;
  end if;

  insert into public.members (email, role, display_name, family_id) values
    ('yonu.kazokin@gmail.com', 'parent', 'אבא', f),
    ('yonuka3@gmail.com',      'parent', 'אמא', f)
  on conflict (email) do update set role = 'parent', display_name = excluded.display_name, family_id = excluded.family_id;

  -- נתונים מלפני שהיו משפחות שייכים למשפחה הזו
  update public.children set family_id = f where family_id is null;
  update public.members  set family_id = f where family_id is null;
end $$;

insert into public.admins (email) values ('yonu.kazokin@gmail.com') on conflict do nothing;

alter table public.children alter column family_id set not null;
alter table public.members  alter column family_id set not null;
