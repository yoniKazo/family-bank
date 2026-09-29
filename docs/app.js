import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

const app = document.getElementById('app');
const dialog = document.getElementById('dialog');
const state = { me: null, names: {} };

// ---------- עזרים ----------

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const moneyFmt = new Intl.NumberFormat('he-IL', { style: 'currency', currency: 'ILS', minimumFractionDigits: 0, maximumFractionDigits: 2 });
const money = (n) => moneyFmt.format(Number(n) || 0);
const signed = (n) => (n > 0 ? '+' : n < 0 ? '−' : '') + money(Math.abs(n));

const dateFmt = new Intl.DateTimeFormat('he-IL', { day: 'numeric', month: 'short', year: 'numeric' });
const fmtDate = (d) => d ? dateFmt.format(new Date(d.length === 10 ? d + 'T12:00:00' : d)) : '';
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jerusalem' }).format(new Date());

const who = (email) => state.names[email] || (email ? email.split('@')[0] : '');

const STATUS = {
  pending:   ['ממתינה', 'pending'],
  approved:  ['אושרה', 'ok'],
  rejected:  ['נדחתה', 'bad'],
  cancelled: ['בוטלה', 'muted'],
};

function toast(msg, kind = 'ok') {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = `show ${kind}`;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.className = ''), 3200);
}

async function q(promise) {
  const { data, error } = await promise;
  if (error) {
    console.error(error);
    toast(error.message || 'משהו השתבש', 'bad');
    throw error;
  }
  return data;
}

const go = (hash) => { if (location.hash === hash) route(); else location.hash = hash; };

// ---------- התחברות ----------

async function boot() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return renderLogin();

  const { data, error } = await sb.rpc('me');
  if (error) { app.innerHTML = shell(`<div class="card">שגיאה: ${esc(error.message)}</div>`); return; }
  if (!data?.length) return renderNotAllowed(session.user.email);

  state.me = data[0];
  if (state.me.role === 'parent') {
    const members = await q(sb.from('members').select('email, display_name, role'));
    state.names = Object.fromEntries(members.filter((m) => m.display_name).map((m) => [m.email, m.display_name]));
  }
  route();
}

sb.auth.onAuthStateChange((event) => {
  // לא לקרוא ל-Supabase מתוך ה-callback עצמו
  if (event === 'SIGNED_OUT') { state.me = null; setTimeout(renderLogin, 0); }
  if (event === 'SIGNED_IN' && !state.me) setTimeout(boot, 0);
});

function renderLogin() {
  app.innerHTML = `
    <section class="login">
      <div class="logo">🏦</div>
      <h1>הבנק המשפחתי</h1>
      <p class="muted">כל החסכונות של המשפחה במקום אחד</p>
      <button class="btn google" data-action="login">
        <svg viewBox="0 0 48 48" width="20" height="20" aria-hidden="true"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"/><path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/><path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"/></svg>
        כניסה עם Google
      </button>
    </section>`;
}

function renderNotAllowed(email) {
  app.innerHTML = `
    <section class="login">
      <div class="logo">🔒</div>
      <h1>אין לך עדיין גישה</h1>
      <p class="muted">החשבון <b dir="ltr">${esc(email)}</b> לא רשום בבנק המשפחתי.<br>בקשו מאבא או אמא להוסיף אותו.</p>
      <button class="btn ghost" data-action="logout">התנתקות</button>
    </section>`;
}

// ---------- מסגרת ----------

function shell(body, { back, tab } = {}) {
  const parent = state.me?.role === 'parent';
  const tabs = parent ? `
    <nav class="tabs">
      <a href="#/" class="${tab === 'home' ? 'on' : ''}">ילדים</a>
      <a href="#/requests" class="${tab === 'requests' ? 'on' : ''}">בקשות <span id="req-badge"></span></a>
      <a href="#/manage" class="${tab === 'manage' ? 'on' : ''}">ניהול</a>
    </nav>` : '';
  return `
    <header class="top">
      ${back ? `<a class="icon-btn" href="${back}" aria-label="חזרה">→</a>` : '<span class="brand">🏦 הבנק המשפחתי</span>'}
      <button class="link" data-action="logout">יציאה</button>
    </header>
    ${tabs}
    <div class="content">${body}</div>`;
}

async function updateBadge() {
  if (state.me?.role !== 'parent') return;
  const { count } = await sb.from('requests').select('id', { count: 'exact', head: true }).eq('status', 'pending');
  const el = document.getElementById('req-badge');
  if (el) el.innerHTML = count ? `<span class="badge">${count}</span>` : '';
}

// ---------- ניתוב ----------

async function route() {
  if (!state.me) return;
  const [, page, id] = (location.hash.replace(/^#/, '') || '/').split('/');
  try {
    if (state.me.role === 'child') return await childHome();
    if (page === 'child' && id) return await parentChild(id);
    if (page === 'requests') return await parentRequests();
    if (page === 'manage') return await parentManage();
    return await parentHome();
  } catch (e) {
    console.error(e);
  } finally {
    updateBadge();
  }
}
window.addEventListener('hashchange', route);
document.addEventListener('visibilitychange', () => { if (!document.hidden && state.me) route(); });

// ---------- רכיבים משותפים ----------

function txList(txs, { parent }) {
  if (!txs.length) return `<p class="empty">עדיין אין פעולות</p>`;
  return `<ul class="list">${txs.map((t) => `
    <li class="tx ${t.voided ? 'voided' : ''}">
      <div class="tx-main">
        <div class="tx-note">${esc(t.note) || '<span class="muted">ללא הערה</span>'}</div>
        <div class="tx-meta">${fmtDate(t.occurred_on)}${parent ? ` · ${esc(who(t.created_by))}` : ''}${t.request_id ? ' · מבקשה' : ''}${t.voided ? ' · <b>בוטלה</b>' : ''}${parent && t.updated_at ? ` · נערכה ע״י ${esc(who(t.updated_by))}` : ''}</div>
      </div>
      <div class="amt ${t.amount >= 0 ? 'plus' : 'minus'}">${signed(t.amount)}</div>
      ${parent ? `<button class="icon-btn small" data-action="edit-tx" data-id="${t.id}" aria-label="עריכה">✎</button>` : ''}
    </li>`).join('')}</ul>`;
}

function requestItem(r, { parent, childName }) {
  const [label, cls] = STATUS[r.status];
  const kind = r.kind === 'deposit' ? 'הפקדה' : 'משיכה';
  return `
    <li class="req">
      <div class="req-head">
        <div>
          <b>${parent && childName ? esc(childName) + ' · ' : ''}${kind} של ${money(r.amount)}</b>
          <div class="tx-meta">${fmtDate(r.created_at)}${parent && r.decided_by && r.status !== 'pending' ? ` · טופלה ע״י ${esc(who(r.decided_by))}` : ''}</div>
        </div>
        <span class="pill ${cls}">${label}</span>
      </div>
      ${r.note ? `<div class="req-note">״${esc(r.note)}״</div>` : ''}
      ${r.decision_note ? `<div class="req-reply">תשובה: ${esc(r.decision_note)}</div>` : ''}
      ${r.status === 'pending' && parent ? `
        <div class="row">
          <button class="btn ok" data-action="approve" data-id="${r.id}" data-child="${r.child_id}" data-kind="${r.kind}" data-amount="${r.amount}">אישור</button>
          <button class="btn ghost" data-action="reject" data-id="${r.id}">דחייה</button>
        </div>` : ''}
      ${r.status === 'pending' && !parent ? `
        <div class="row"><button class="btn ghost small" data-action="cancel-req" data-id="${r.id}">ביטול הבקשה</button></div>` : ''}
    </li>`;
}

const kindToggle = (name, def = 'deposit') => `
  <div class="seg" role="radiogroup">
    <label><input type="radio" name="${name}" value="deposit" ${def === 'deposit' ? 'checked' : ''}><span>+ הפקדה</span></label>
    <label><input type="radio" name="${name}" value="withdraw" ${def === 'withdraw' ? 'checked' : ''}><span>− משיכה</span></label>
  </div>`;

async function balanceOf(childId) {
  const [b] = await q(sb.from('balances').select('balance').eq('child_id', childId));
  return Number(b?.balance || 0);
}

// ---------- מסכי הורה ----------

async function parentHome() {
  const balances = await q(sb.from('balances').select('*').eq('active', true).order('name'));
  const total = balances.reduce((s, b) => s + Number(b.balance), 0);
  app.innerHTML = shell(`
    <div class="summary"><span class="muted">סה״כ בקופה</span><strong>${money(total)}</strong></div>
    ${balances.length ? `<div class="grid">${balances.map((b) => `
      <a class="child-card" href="#/child/${b.child_id}">
        <span class="avatar">${esc(b.name.trim()[0])}</span>
        <span class="child-name">${esc(b.name)}</span>
        <span class="child-bal ${b.balance < 0 ? 'minus' : ''}">${money(b.balance)}</span>
        <span class="tx-meta">${b.last_activity ? 'פעולה אחרונה ' + fmtDate(b.last_activity) : 'אין פעולות'}</span>
      </a>`).join('')}</div>`
    : `<div class="card empty">עוד אין ילדים. <a href="#/manage">הוסיפו ילד ראשון</a></div>`}
  `, { tab: 'home' });
}

async function parentChild(id) {
  const [[child], txs, reqs] = await Promise.all([
    q(sb.from('balances').select('*').eq('child_id', id)),
    q(sb.from('transactions').select('*').eq('child_id', id).order('occurred_on', { ascending: false }).order('created_at', { ascending: false })),
    q(sb.from('requests').select('*').eq('child_id', id).eq('status', 'pending').order('created_at')),
  ]);
  if (!child) { app.innerHTML = shell('<div class="card">הילד לא נמצא</div>', { back: '#/' }); return; }

  app.innerHTML = shell(`
    <div class="hero">
      <div class="muted">${esc(child.name)}${child.active ? '' : ' (לא פעיל)'}</div>
      <div class="big ${child.balance < 0 ? 'minus' : ''}">${money(child.balance)}</div>
    </div>

    ${reqs.length ? `<h2>בקשות ממתינות</h2><ul class="list">${reqs.map((r) => requestItem(r, { parent: true })).join('')}</ul>` : ''}

    <form class="card form" data-form="add-tx" data-child="${id}" data-balance="${child.balance}">
      <h2>פעולה חדשה</h2>
      ${kindToggle('kind')}
      <div class="row">
        <label class="field grow"><span>סכום</span><input name="amount" type="number" inputmode="decimal" min="0.01" step="0.01" required placeholder="0"></label>
        <label class="field"><span>תאריך</span><input name="date" type="date" value="${today()}" max="${today()}" required></label>
      </div>
      <label class="field"><span>הערה</span><input name="note" maxlength="200" placeholder="למשל: דמי כיס, מתנה מסבתא, קניית ספר"></label>
      <button class="btn primary">שמירה</button>
    </form>

    <h2>היסטוריה</h2>
    ${txList(txs, { parent: true })}
  `, { back: '#/' });
}

async function parentRequests() {
  const [reqs, children] = await Promise.all([
    q(sb.from('requests').select('*').order('created_at', { ascending: false }).limit(60)),
    q(sb.from('children').select('id, name')),
  ]);
  const names = Object.fromEntries(children.map((c) => [c.id, c.name]));
  const pending = reqs.filter((r) => r.status === 'pending');
  const done = reqs.filter((r) => r.status !== 'pending').slice(0, 20);
  app.innerHTML = shell(`
    <h2>ממתינות לאישור</h2>
    ${pending.length ? `<ul class="list">${pending.map((r) => requestItem(r, { parent: true, childName: names[r.child_id] })).join('')}</ul>` : '<p class="empty">אין בקשות פתוחות 🎉</p>'}
    ${done.length ? `<h2>טופלו לאחרונה</h2><ul class="list">${done.map((r) => requestItem(r, { parent: true, childName: names[r.child_id] })).join('')}</ul>` : ''}
  `, { tab: 'requests' });
}

async function parentManage() {
  const [children, members] = await Promise.all([
    q(sb.from('children').select('*').order('active', { ascending: false }).order('name')),
    q(sb.from('members').select('*').eq('role', 'child')),
  ]);
  const emailOf = Object.fromEntries(members.map((m) => [m.child_id, m.email]));
  app.innerHTML = shell(`
    <form class="card form" data-form="add-child">
      <h2>הוספת ילד</h2>
      <label class="field"><span>שם</span><input name="name" required maxlength="40"></label>
      <label class="field"><span>חשבון Google של הילד (לא חובה)</span><input name="email" type="email" dir="ltr" placeholder="name@gmail.com"></label>
      <button class="btn primary">הוספה</button>
    </form>

    <h2>הילדים</h2>
    ${children.length ? `<ul class="list">${children.map((c) => `
      <li>
        <form class="manage-row ${c.active ? '' : 'inactive'}" data-form="save-child" data-id="${c.id}" data-old-email="${esc(emailOf[c.id] || '')}">
          <label class="field"><span>שם</span><input name="name" value="${esc(c.name)}" required maxlength="40"></label>
          <label class="field"><span>Google</span><input name="email" type="email" dir="ltr" value="${esc(emailOf[c.id] || '')}" placeholder="ללא כניסה"></label>
          <label class="check"><input type="checkbox" name="active" ${c.active ? 'checked' : ''}> פעיל</label>
          <button class="btn small">שמירה</button>
        </form>
      </li>`).join('')}</ul>` : '<p class="empty">עוד אין ילדים</p>'}
    <p class="muted small">ילד לא פעיל נעלם מהמסך הראשי ולא יכול להתחבר. ההיסטוריה שלו נשמרת.</p>
  `, { tab: 'manage' });
}

// ---------- מסך ילד ----------

async function childHome() {
  const id = state.me.child_id;
  const [balance, txs, reqs] = await Promise.all([
    balanceOf(id),
    q(sb.from('transactions').select('*').eq('child_id', id).order('occurred_on', { ascending: false }).order('created_at', { ascending: false })),
    q(sb.from('requests').select('*').eq('child_id', id).order('created_at', { ascending: false }).limit(20)),
  ]);
  app.innerHTML = shell(`
    <div class="hero">
      <div class="muted">שלום ${esc(state.me.child_name)}, יש לך</div>
      <div class="big ${balance < 0 ? 'minus' : ''}">${money(balance)}</div>
    </div>

    <form class="card form" data-form="new-request" data-balance="${balance}">
      <h2>בקשה מההורים</h2>
      ${kindToggle('kind', 'withdraw')}
      <label class="field"><span>סכום</span><input name="amount" type="number" inputmode="decimal" min="0.01" step="0.01" required placeholder="0"></label>
      <label class="field"><span>בשביל מה?</span><input name="note" maxlength="200" required placeholder="למשל: לקנות ספר / החזרתי בקבוקים"></label>
      <button class="btn primary">שליחת בקשה</button>
    </form>

    ${reqs.length ? `<h2>הבקשות שלי</h2><ul class="list">${reqs.map((r) => requestItem(r, { parent: false })).join('')}</ul>` : ''}

    <h2>היסטוריה</h2>
    ${txList(txs, { parent: false })}
  `);
}

// ---------- פעולות ----------

const actions = {
  async login() {
    const redirectTo = location.origin + location.pathname;
    await q(sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo, queryParams: { prompt: 'select_account' } } }));
  },

  async logout() {
    await sb.auth.signOut();
    location.hash = '';
  },

  async approve(el) {
    const amount = Number(el.dataset.amount);
    if (el.dataset.kind === 'withdraw') {
      const bal = await balanceOf(el.dataset.child);
      if (bal - amount < 0 && !confirm(`אחרי המשיכה היתרה תהיה ${money(bal - amount)}. לאשר בכל זאת?`)) return;
    }
    const note = prompt('הערה לילד (לא חובה):', '') ?? null;
    if (note === null) return;
    el.disabled = true;
    await q(sb.rpc('decide_request', { p_request_id: el.dataset.id, p_approve: true, p_note: note }));
    toast('הבקשה אושרה ונרשמה');
    route();
  },

  async reject(el) {
    const note = prompt('למה לא? (הילד יראה את זה)', '');
    if (note === null) return;
    el.disabled = true;
    await q(sb.rpc('decide_request', { p_request_id: el.dataset.id, p_approve: false, p_note: note }));
    toast('הבקשה נדחתה');
    route();
  },

  async 'cancel-req'(el) {
    if (!confirm('לבטל את הבקשה?')) return;
    await q(sb.rpc('cancel_request', { p_request_id: el.dataset.id }));
    toast('הבקשה בוטלה');
    route();
  },

  async 'edit-tx'(el) {
    const [t] = await q(sb.from('transactions').select('*').eq('id', el.dataset.id));
    if (!t) return;
    dialog.innerHTML = `
      <form class="form" data-form="save-tx" data-id="${t.id}" method="dialog">
        <h2>עריכת פעולה</h2>
        ${kindToggle('kind', t.amount >= 0 ? 'deposit' : 'withdraw')}
        <div class="row">
          <label class="field grow"><span>סכום</span><input name="amount" type="number" inputmode="decimal" min="0.01" step="0.01" required value="${Math.abs(t.amount)}"></label>
          <label class="field"><span>תאריך</span><input name="date" type="date" required value="${t.occurred_on}" max="${today()}"></label>
        </div>
        <label class="field"><span>הערה</span><input name="note" maxlength="200" value="${esc(t.note)}"></label>
        <label class="check"><input type="checkbox" name="voided" ${t.voided ? 'checked' : ''}> הפעולה מבוטלת (לא נספרת ביתרה)</label>
        <div class="row">
          <button class="btn primary grow">שמירה</button>
          <button type="button" class="btn ghost" data-action="close-dialog">סגירה</button>
        </div>
      </form>`;
    dialog.showModal();
  },

  'close-dialog'() { dialog.close(); },
};

const forms = {
  async 'add-tx'(f, d) {
    const amount = Number(d.get('amount'));
    const value = d.get('kind') === 'withdraw' ? -amount : amount;
    const after = Number(f.dataset.balance) + value;
    if (after < 0 && !confirm(`אחרי הפעולה היתרה תהיה ${money(after)}. להמשיך?`)) return;
    await q(sb.from('transactions').insert({
      child_id: f.dataset.child, amount: value, occurred_on: d.get('date'), note: d.get('note').trim(),
    }));
    toast(value > 0 ? 'ההפקדה נרשמה' : 'המשיכה נרשמה');
    route();
  },

  async 'save-tx'(f, d) {
    const amount = Number(d.get('amount'));
    await q(sb.from('transactions').update({
      amount: d.get('kind') === 'withdraw' ? -amount : amount,
      occurred_on: d.get('date'),
      note: d.get('note').trim(),
      voided: d.get('voided') === 'on',
    }).eq('id', f.dataset.id));
    dialog.close();
    toast('נשמר');
    route();
  },

  async 'new-request'(f, d) {
    const amount = Number(d.get('amount'));
    const kind = d.get('kind');
    if (kind === 'withdraw' && amount > Number(f.dataset.balance) &&
        !confirm(`יש לך רק ${money(f.dataset.balance)}. לשלוח בכל זאת?`)) return;
    await q(sb.from('requests').insert({ child_id: state.me.child_id, kind, amount, note: d.get('note').trim() }));
    toast('הבקשה נשלחה להורים');
    route();
  },

  async 'add-child'(f, d) {
    const email = d.get('email').trim().toLowerCase();
    const [child] = await q(sb.from('children').insert({ name: d.get('name').trim() }).select());
    if (email) await q(sb.from('members').insert({ email, role: 'child', child_id: child.id, display_name: child.name }));
    toast(`${child.name} נוסף/ה`);
    route();
  },

  async 'save-child'(f, d) {
    const id = f.dataset.id;
    const name = d.get('name').trim();
    const email = d.get('email').trim().toLowerCase();
    await q(sb.from('children').update({ name, active: d.get('active') === 'on' }).eq('id', id));
    if (email !== f.dataset.oldEmail) {
      await q(sb.from('members').delete().eq('child_id', id));
      if (email) await q(sb.from('members').insert({ email, role: 'child', child_id: id, display_name: name }));
    }
    toast('נשמר');
    route();
  },
};

document.addEventListener('click', async (e) => {
  const el = e.target.closest('[data-action]');
  if (!el || !actions[el.dataset.action]) return;
  e.preventDefault();
  try { await actions[el.dataset.action](el); } catch { el.disabled = false; }
});

document.addEventListener('submit', async (e) => {
  const f = e.target.closest('[data-form]');
  if (!f || !forms[f.dataset.form]) return;
  e.preventDefault();
  const btns = f.querySelectorAll('button');
  btns.forEach((b) => (b.disabled = true));
  try { await forms[f.dataset.form](f, new FormData(f)); }
  catch { /* ה-toast כבר הוצג */ }
  finally { btns.forEach((b) => (b.disabled = false)); }
});

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

boot();
