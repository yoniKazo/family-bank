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

create table if not exists public.children (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- רשימת ההרשאות: רק מי שמופיע כאן יכול לראות משהו
create table if not exists public.members (
  email        text primary key check (email = lower(trim(email)) and email like '%@%'),
  role         text not null check (role in ('parent', 'child')),
  child_id     uuid unique references public.children(id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now(),
  check ((role = 'child') = (child_id is not null))
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
create index if not exists requests_child_idx on public.requests (child_id, created_at desc);
create index if not exists requests_pending_idx on public.requests (status) where status = 'pending';

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

-- מי אני? (האפליקציה קוראת לזה אחרי התחברות)
create or replace function public.me()
returns table (email text, role text, child_id uuid, child_name text, display_name text)
language sql stable security definer set search_path = public as $$
  select m.email, m.role, m.child_id, c.name, m.display_name
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
  return new;
end $$;

drop trigger if exists requests_insert on public.requests;
create trigger requests_insert before insert on public.requests
  for each row execute function public.tg_requests_insert();

-- ---------- יתרות ----------

create or replace view public.balances with (security_invoker = true) as
  select c.id as child_id, c.name, c.active,
         coalesce(sum(t.amount) filter (where not t.voided), 0)::numeric(12,2) as balance,
         max(t.occurred_on) filter (where not t.voided) as last_activity
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
  if not found then raise exception 'הבקשה לא נמצאה'; end if;
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
     and (child_id = my_child_id() or is_parent())
  returning * into r;
  if not found then raise exception 'אי אפשר לבטל את הבקשה הזו'; end if;
  return r;
end $$;

-- ---------- Row Level Security ----------

alter table public.children     enable row level security;
alter table public.members      enable row level security;
alter table public.transactions enable row level security;
alter table public.requests     enable row level security;

-- ילדים
drop policy if exists children_select on public.children;
create policy children_select on public.children for select to authenticated
  using (is_parent() or id = my_child_id());
drop policy if exists children_insert on public.children;
create policy children_insert on public.children for insert to authenticated
  with check (is_parent());
drop policy if exists children_update on public.children;
create policy children_update on public.children for update to authenticated
  using (is_parent()) with check (is_parent());

-- חברים: הורים מנהלים רק שורות של ילדים. שורות הורים מוגדרות ב-SQL בלבד.
drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using (is_parent() or email = current_email());
drop policy if exists members_insert on public.members;
create policy members_insert on public.members for insert to authenticated
  with check (is_parent() and role = 'child');
drop policy if exists members_update on public.members;
create policy members_update on public.members for update to authenticated
  using (is_parent() and role = 'child') with check (is_parent() and role = 'child');
drop policy if exists members_delete on public.members;
create policy members_delete on public.members for delete to authenticated
  using (is_parent() and role = 'child');

-- תנועות: ילד רואה רק את שלו ורק פעולות שלא בוטלו; אין מחיקה בכלל
drop policy if exists transactions_select on public.transactions;
create policy transactions_select on public.transactions for select to authenticated
  using (is_parent() or (child_id = my_child_id() and not voided));
drop policy if exists transactions_insert on public.transactions;
create policy transactions_insert on public.transactions for insert to authenticated
  with check (is_parent());
drop policy if exists transactions_update on public.transactions;
create policy transactions_update on public.transactions for update to authenticated
  using (is_parent()) with check (is_parent());

-- בקשות: ילד יוצר בקשה רק לעצמו; שינויי סטטוס רק דרך ה-RPC
drop policy if exists requests_select on public.requests;
create policy requests_select on public.requests for select to authenticated
  using (is_parent() or child_id = my_child_id());
drop policy if exists requests_insert on public.requests;
create policy requests_insert on public.requests for insert to authenticated
  with check (child_id = my_child_id());

-- ---------- הרשאות ----------

revoke all on public.children, public.members, public.transactions, public.requests, public.balances from anon;
revoke update, delete on public.requests from authenticated;
revoke delete on public.transactions, public.children from authenticated;
grant select, insert, update on public.children, public.transactions to authenticated;
grant select, insert, update, delete on public.members to authenticated;
grant select, insert on public.requests to authenticated;
grant select on public.balances to authenticated;

revoke execute on function public.decide_request(uuid, boolean, text), public.cancel_request(uuid),
                           public.me(), public.is_parent(), public.my_child_id() from public, anon;
grant  execute on function public.decide_request(uuid, boolean, text), public.cancel_request(uuid),
                           public.me(), public.is_parent(), public.my_child_id() to authenticated;

-- ============================================================
--  ההורים — להחליף למיילים האמיתיים (Gmail) ולהריץ
-- ============================================================
insert into public.members (email, role, display_name) values
  ('yonu.kazokin@gmail.com', 'parent', 'אבא'),
  ('yonuka3@gmail.com', 'parent', 'אמא')
on conflict (email) do update set role = 'parent', display_name = excluded.display_name;
