// DCRM: foydalanuvchi (menejer yoki admin) qo‘shish va parol o‘rnatish.
// Faqat faol admin chaqira oladi. Brauzerda maxfiy kalit bo‘lmasligi uchun shu yerda bajariladi.
//
// Vercel → Project → Settings → Environment Variables:
//   SUPABASE_URL              (bor)
//   SUPABASE_ANON_KEY         (bor)
//   SUPABASE_SERVICE_ROLE_KEY yoki SUPABASE_SECRET_KEY (Supabase → Project Settings → API Keys → secret)
//   Supabase Vercel orqali ulangan bo‘lsa, SUPABASE_SECRET_KEY allaqachon bor — hech narsa qo‘shish shart emas.

const PERM_KEYS = ['view_all', 'transfer', 'delete', 'export'];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function cleanPerms(p) {
  const out = {};
  PERM_KEYS.forEach(k => { if (p && p[k] === true) out[k] = true; });
  if (out.transfer) out.view_all = true; // o‘tkazish uchun hammasini ko‘rish kerak
  return out;
}

function authMessage(text) {
  if (/already.*registered|already been registered|email_exists|User already/i.test(text)) return 'Bu email bilan foydalanuvchi allaqachon bor';
  if (/password/i.test(text)) return 'Parol talabga javob bermaydi (kamida 8 belgi)';
  return text;
}

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'Faqat POST so‘rov qabul qilinadi' });

  // Vercel Marketplace orqali ulangan Supabase kalitlarni SUPABASE_SECRET_KEY / SUPABASE_PUBLISHABLE_KEY
  // nomi bilan o‘zi qo‘yadi — ikkala nom ham qabul qilinadi.
  const env = process.env;
  const URL = env.SUPABASE_URL || env.NEXT_PUBLIC_SUPABASE_URL;
  const ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY || env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const SERVICE = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SECRET_KEY;
  if (!URL || !ANON || !SERVICE) {
    return res.status(500).json({ ok: false, error: 'Serverda maxfiy kalit yo‘q: Vercel → Settings → Environment Variables’ga SUPABASE_SECRET_KEY (yoki SUPABASE_SERVICE_ROLE_KEY) qo‘shib, Redeploy qiling' });
  }
  const svc = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' };

  // 1) Kim chaqiryapti — faqat faol admin
  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ ok: false, error: 'Tizimga kiring' });
  const who = await fetch(`${URL}/auth/v1/user`, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } });
  if (!who.ok) return res.status(401).json({ ok: false, error: 'Sessiya tugagan, qayta kiring' });
  const me = await who.json();
  const pr = await fetch(`${URL}/rest/v1/profiles?id=eq.${encodeURIComponent(me.id)}&select=role,active`, { headers: svc });
  const rows = pr.ok ? await pr.json() : [];
  if (!rows[0] || rows[0].role !== 'admin' || rows[0].active === false) {
    return res.status(403).json({ ok: false, error: 'Bu amal faqat admin uchun' });
  }

  let body = req.body || {};
  if (typeof body === 'string') { try { body = JSON.parse(body || '{}'); } catch (e) { body = {}; } }

  // 2) Yangi foydalanuvchi
  if (body.action === 'create') {
    const email = String(body.email || '').trim().toLowerCase();
    const password = String(body.password || '');
    const fullName = String(body.full_name || '').trim();
    const role = body.role === 'admin' ? 'admin' : 'manager';
    if (!EMAIL_RE.test(email)) return res.status(400).json({ ok: false, error: 'Email noto‘g‘ri' });
    if (password.length < 8) return res.status(400).json({ ok: false, error: 'Parol kamida 8 belgi bo‘lsin' });
    if (!fullName) return res.status(400).json({ ok: false, error: 'F.I.Sh. kiriting' });

    const cr = await fetch(`${URL}/auth/v1/admin/users`, {
      method: 'POST', headers: svc,
      body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { full_name: fullName } })
    });
    const created = await cr.json().catch(() => ({}));
    if (!cr.ok) return res.status(400).json({ ok: false, error: authMessage(created.msg || created.message || created.error_description || created.error || 'Foydalanuvchini yaratib bo‘lmadi') });
    const user = created.user || created;

    const profile = { id: user.id, email, full_name: fullName, role, perms: role === 'admin' ? {} : cleanPerms(body.perms), active: true };
    const up = await fetch(`${URL}/rest/v1/profiles?on_conflict=id`, {
      method: 'POST', headers: { ...svc, Prefer: 'resolution=merge-duplicates,return=representation' },
      body: JSON.stringify(profile)
    });
    if (!up.ok) return res.status(500).json({ ok: false, error: 'Foydalanuvchi yaratildi, lekin profilini saqlab bo‘lmadi: ' + (await up.text()) });
    const saved = await up.json().catch(() => [profile]);
    return res.status(200).json({ ok: true, profile: Array.isArray(saved) ? saved[0] : saved });
  }

  // 3) Parolni almashtirish
  if (body.action === 'set_password') {
    const id = String(body.id || '');
    const password = String(body.password || '');
    if (!UUID_RE.test(id)) return res.status(400).json({ ok: false, error: 'Foydalanuvchi topilmadi' });
    if (password.length < 8) return res.status(400).json({ ok: false, error: 'Parol kamida 8 belgi bo‘lsin' });
    const r = await fetch(`${URL}/auth/v1/admin/users/${id}`, { method: 'PUT', headers: svc, body: JSON.stringify({ password }) });
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      return res.status(400).json({ ok: false, error: authMessage(j.msg || j.message || 'Parolni o‘zgartirib bo‘lmadi') });
    }
    return res.status(200).json({ ok: true });
  }

  // 4) Foydalanuvchini butunlay o‘chirish: avval bitimlari boshqa odamga o‘tadi, keyin hisob va profil o‘chadi
  if (body.action === 'delete') {
    const id = String(body.id || ''), to = String(body.transfer_to || '');
    if (!UUID_RE.test(id)) return res.status(400).json({ ok: false, error: 'Foydalanuvchi topilmadi' });
    if (!UUID_RE.test(to) || to === id) return res.status(400).json({ ok: false, error: 'Bitimlar kimga o‘tishini tanlang' });
    if (id === me.id) return res.status(400).json({ ok: false, error: 'O‘zingizni o‘chira olmaysiz' });

    const pq = await fetch(`${URL}/rest/v1/profiles?id=in.(${id},${to})&select=*`, { headers: svc });
    const ps = pq.ok ? await pq.json() : [];
    const target = ps.find(p => p.id === id), heir = ps.find(p => p.id === to);
    if (!heir || heir.active === false) return res.status(400).json({ ok: false, error: 'Bitimlarni oladigan foydalanuvchi topilmadi yoki faol emas' });
    if (target && target.role === 'admin' && target.active !== false) {
      const aq = await fetch(`${URL}/rest/v1/profiles?role=eq.admin&active=is.true&id=neq.${id}&select=id`, { headers: svc });
      const admins = aq.ok ? await aq.json() : [];
      if (!admins.length) return res.status(400).json({ ok: false, error: 'Kamida bitta faol admin qolishi kerak' });
    }

    const heirName = heir.full_name || String(heir.email || '').split('@')[0] || 'Menejer';
    const mv = await fetch(`${URL}/rest/v1/deals?owner_id=eq.${id}`, {
      method: 'PATCH', headers: { ...svc, Prefer: 'return=minimal' },
      body: JSON.stringify({ owner_id: to, owner: heirName })
    });
    if (!mv.ok) return res.status(500).json({ ok: false, error: 'Bitimlarni o‘tkazib bo‘lmadi, foydalanuvchi o‘chirilmadi: ' + (await mv.text()) });

    // Avval profil (eski bazada profil hisobga "cascade"siz bog‘langan bo‘lsa ham to‘siq bo‘lmasin), keyin hisob.
    if (target) {
      const dp = await fetch(`${URL}/rest/v1/profiles?id=eq.${id}`, { method: 'DELETE', headers: { ...svc, Prefer: 'return=minimal' } });
      if (!dp.ok) return res.status(500).json({ ok: false, error: 'Profilni o‘chirib bo‘lmadi: ' + (await dp.text()) });
    }
    const del = await fetch(`${URL}/auth/v1/admin/users/${id}`, { method: 'DELETE', headers: svc });
    if (!del.ok && del.status !== 404) {
      const j = await del.json().catch(() => ({}));
      if (target) {   // hisob o‘chmadi — profilni joyiga qaytaramiz
        await fetch(`${URL}/rest/v1/profiles?on_conflict=id`, { method: 'POST', headers: { ...svc, Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(target) });
      }
      return res.status(400).json({ ok: false, error: 'Hisobni o‘chirib bo‘lmadi: ' + (j.msg || j.message || j.error || del.status) });
    }
    return res.status(200).json({ ok: true });
  }

  return res.status(400).json({ ok: false, error: 'Noma’lum amal' });
}
