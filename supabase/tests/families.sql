-- ============================================================
--  בדיקת הפרדה בין משפחות והוספת משפחה ע״י המנהל
--  להרצה ב-SQL Editor אחרי schema.sql. הכול בתוך טרנזקציה
--  שמתבטלת בסוף — לא נשאר שום נתון.
--  הצלחה = "Success". כישלון = שגיאה עם תיאור הבעיה.
-- ============================================================
begin;

-- ---------- הכנה: משפחה A (ההורה שלה הוא גם מנהל) ----------
insert into public.families (id, name) values ('aaaaaaaa-0000-0000-0000-000000000001', 'בדיקה A');
insert into public.children (id, name, family_id) values
  ('aaaaaaaa-0000-0000-0000-0000000000c1', 'ילד A', 'aaaaaaaa-0000-0000-0000-000000000001');
insert into public.members (email, role, display_name, family_id, child_id) values
  ('parent-a@test.local', 'parent', 'הורה A', 'aaaaaaaa-0000-0000-0000-000000000001', null),
  ('child-a@test.local',  'child',  'ילד A',  'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-0000000000c1');
insert into public.admins (email) values ('parent-a@test.local');
insert into public.transactions (id, child_id, amount) values
  ('aaaaaaaa-0000-0000-0000-0000000000f1', 'aaaaaaaa-0000-0000-0000-0000000000c1', 10);
insert into public.requests (id, child_id, kind, amount) values
  ('aaaaaaaa-0000-0000-0000-0000000000e1', 'aaaaaaaa-0000-0000-0000-0000000000c1', 'withdraw', 3),
  ('aaaaaaaa-0000-0000-0000-0000000000e2', 'aaaaaaaa-0000-0000-0000-0000000000c1', 'deposit', 4);

set local role authenticated;

-- ---------- המנהל מוסיף את משפחה B ----------
set local request.jwt.claims = '{"email": "parent-a@test.local"}';
do $$
declare
  f  public.families;
  ok boolean;
begin
  assert (select is_admin from public.me()), 'המנהל לא מסומן כמנהל ב-me()';

  f := public.add_family(' בדיקה B ', '[{"email": " Parent-B@Test.local ", "display_name": "הורה B"}]');
  assert f.name = 'בדיקה B', 'שם המשפחה לא נשמר כמו שצריך';
  assert (select family_id from public.members where email = 'parent-b@test.local' and role = 'parent') = f.id,
         'ההורה של המשפחה החדשה לא נוסף (או שהמנהל לא רואה אותו)';
  assert (select count(*) from public.families where id = f.id) = 1, 'המנהל לא רואה את המשפחות';

  -- אותו שם משפחה מותר
  perform public.add_family('בדיקה B', '[{"email": "parent-b2@test.local"}]');

  -- מייל שכבר רשום — נכשל עם הודעה בעברית
  begin
    perform public.add_family('כפולה', '[{"email": "child-a@test.local"}]');
    ok := false;
  exception when others then ok := sqlerrm like '%כבר רשום%';
  end;
  assert ok, 'הוספת משפחה עם מייל שכבר רשום לא נכשלה כמו שצריך';
end $$;

-- ---------- הורה B: רואה ומנהל רק את שלו ----------
set local request.jwt.claims = '{"email": "parent-b@test.local"}';
do $$
declare
  ok    boolean;
  n     int;
  my_f  uuid;
  c_b   public.children;
begin
  assert (select role from public.me()) = 'parent', 'הורה B לא מזוהה כהורה';
  assert not (select is_admin from public.me()), 'הורה B מסומן כמנהל';
  my_f := (select family_id from public.members where email = 'parent-b@test.local');

  -- לא רואה כלום של משפחה A
  assert (select count(*) from public.children     where id = 'aaaaaaaa-0000-0000-0000-0000000000c1') = 0, 'הורה B רואה ילד של A';
  assert (select count(*) from public.balances     where child_id = 'aaaaaaaa-0000-0000-0000-0000000000c1') = 0, 'הורה B רואה יתרה של A';
  assert (select count(*) from public.transactions where child_id = 'aaaaaaaa-0000-0000-0000-0000000000c1') = 0, 'הורה B רואה פעולות של A';
  assert (select count(*) from public.requests     where child_id = 'aaaaaaaa-0000-0000-0000-0000000000c1') = 0, 'הורה B רואה בקשות של A';
  assert (select count(*) from public.members      where email in ('parent-a@test.local', 'child-a@test.local')) = 0, 'הורה B רואה חברים של A';
  assert (select count(*) from public.families) = 0, 'הורה רגיל רואה את רשימת המשפחות';

  -- לא יכול לשנות כלום של משפחה A
  begin
    insert into public.transactions (child_id, amount) values ('aaaaaaaa-0000-0000-0000-0000000000c1', 5);
    ok := false;
  exception when others then ok := true;
  end;
  assert ok, 'הורה B הוסיף פעולה לילד של A';

  update public.transactions set amount = 999 where id = 'aaaaaaaa-0000-0000-0000-0000000000f1';
  get diagnostics n = row_count;
  assert n = 0, 'הורה B ערך פעולה של A';

  update public.children set name = 'נפרץ' where id = 'aaaaaaaa-0000-0000-0000-0000000000c1';
  get diagnostics n = row_count;
  assert n = 0, 'הורה B ערך ילד של A';

  update public.members set display_name = 'נפרץ' where email = 'child-a@test.local';
  get diagnostics n = row_count;
  assert n = 0, 'הורה B ערך חבר של A';

  delete from public.members where email = 'child-a@test.local';
  get diagnostics n = row_count;
  assert n = 0, 'הורה B מחק חבר של A';

  begin
    perform public.decide_request('aaaaaaaa-0000-0000-0000-0000000000e1', true);
    ok := false;
  exception when others then ok := true;
  end;
  assert ok, 'הורה B אישר בקשה של A';

  begin
    perform public.cancel_request('aaaaaaaa-0000-0000-0000-0000000000e1');
    ok := false;
  exception when others then ok := true;
  end;
  assert ok, 'הורה B ביטל בקשה של A';

  begin
    insert into public.members (email, role, child_id) values ('thief@test.local', 'child', 'aaaaaaaa-0000-0000-0000-0000000000c1');
    ok := false;
  exception when others then ok := true;
  end;
  assert ok, 'הורה B קישר חשבון לילד של A';

  begin
    insert into public.children (name, family_id) values ('שתול', 'aaaaaaaa-0000-0000-0000-000000000001');
    ok := false;
  exception when others then ok := true;
  end;
  assert ok, 'הורה B הוסיף ילד למשפחה A';

  begin
    perform public.add_family('פולשת', '[{"email": "x@test.local"}]');
    ok := false;
  exception when others then ok := true;
  end;
  assert ok, 'הורה רגיל הוסיף משפחה';

  -- מנהל את שלו (כמו שהאפליקציה עושה — בלי family_id)
  insert into public.children (name) values ('ילד B') returning * into c_b;
  assert c_b.family_id = my_f, 'ילד חדש לא שויך למשפחה של ההורה';
  insert into public.members (email, role, child_id, display_name) values ('child-b@test.local', 'child', c_b.id, 'ילד B');
  insert into public.transactions (child_id, amount) values (c_b.id, 7);
  assert (select balance from public.balances where child_id = c_b.id) = 7, 'הורה B לא רואה את היתרה של הילד שלו';

  begin
    update public.children set family_id = 'aaaaaaaa-0000-0000-0000-000000000001' where id = c_b.id;
    ok := false;
  exception when others then ok := true;
  end;
  assert ok, 'הורה B העביר ילד למשפחה אחרת';
end $$;

-- ---------- הורה A: הכול עובד כמו קודם, ולא רואה את B ----------
set local request.jwt.claims = '{"email": "parent-a@test.local"}';
do $$
begin
  assert (select count(*) from public.children) = 1, 'הורה A לא רואה בדיוק את הילד שלו';
  assert (select balance from public.balances where child_id = 'aaaaaaaa-0000-0000-0000-0000000000c1') = 10, 'היתרה של A השתנתה';
  assert (select count(*) from public.members where role = 'child') = 1, 'הורה A רואה ילדים של משפחה אחרת';
  perform public.decide_request('aaaaaaaa-0000-0000-0000-0000000000e1', true);
  perform public.cancel_request('aaaaaaaa-0000-0000-0000-0000000000e2');
  assert (select balance from public.balances where child_id = 'aaaaaaaa-0000-0000-0000-0000000000c1') = 7, 'אישור בקשה של A לא עדכן יתרה';
end $$;

-- ---------- ילד A: רואה רק את עצמו ----------
set local request.jwt.claims = '{"email": "child-a@test.local"}';
do $$
begin
  assert (select role from public.me()) = 'child', 'ילד A לא מזוהה כילד';
  assert (select count(*) from public.children) = 1, 'ילד A רואה ילדים אחרים';
  assert (select count(*) from public.families) = 0, 'ילד רואה את רשימת המשפחות';
end $$;

rollback;
