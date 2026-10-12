// שולח התראת push להורים על בקשה חדשה.
// הילד קורא לפונקציה אחרי יצירת הבקשה; היא שולחת פעם אחת בלבד לכל בקשה.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

webpush.setVapidDetails(
  'https://yonikazo.github.io/family-bank/',
  Deno.env.get('VAPID_PUBLIC_KEY')!,
  Deno.env.get('VAPID_PRIVATE_KEY')!,
);

const admin = createClient(Deno.env.get('SUPABASE_URL')!, JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS')!).default);

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const money = new Intl.NumberFormat('he-IL', { style: 'currency', currency: 'ILS', minimumFractionDigits: 0, maximumFractionDigits: 2 });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
  const { data: { user } } = await admin.auth.getUser(token);
  if (!user?.email) return new Response('unauthorized', { status: 401, headers: cors });

  const { request_id } = await req.json();

  // תפיסה אטומית: רק הילד שיצר את הבקשה, ורק אם עוד לא נשלחה התראה
  const { data: r } = await admin.from('requests')
    .update({ notified_at: new Date().toISOString() })
    .eq('id', request_id)
    .eq('created_by', user.email.toLowerCase())
    .is('notified_at', null)
    .select('kind, amount, note, children(name)')
    .maybeSingle();
  if (!r) return new Response('nothing to send', { headers: cors });

  const payload = JSON.stringify({
    title: `בקשה מ${r.children.name}`,
    body: `${r.kind === 'deposit' ? 'הפקדה' : 'משיכה'} של ${money.format(r.amount)}${r.note ? ` — ${r.note}` : ''}`,
  });

  const { data: subs } = await admin.from('push_subscriptions').select('endpoint, keys');
  await Promise.all((subs ?? []).map((s) =>
    webpush.sendNotification({ endpoint: s.endpoint, keys: s.keys }, payload).catch((e) =>
      e.statusCode === 404 || e.statusCode === 410
        ? admin.from('push_subscriptions').delete().eq('endpoint', s.endpoint) // המנוי פג
        : console.error(s.endpoint, e))));

  return new Response('sent', { headers: cors });
});
