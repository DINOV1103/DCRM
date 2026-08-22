export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Faqat POST so\'rovlar ruxsat etilgan' });
  }

  const URL = process.env.SUPABASE_URL;
  const KEY = process.env.SUPABASE_ANON_KEY;

  const response = await fetch(`${URL}/rest/v1/sdelkalar`, {
    method: 'POST',
    headers: {
      'apikey': KEY,
      'Authorization': `Bearer ${KEY}`,
      'Content-Type': 'application/json',
      'Prefer': 'return=minimal'
    },
    body: JSON.stringify(req.body)
  });

  if (response.ok) {
    return res.status(200).json({ success: true, xabar: "Sdelka muvaffaqiyatli saqlandi!" });
  } else {
    const errorText = await response.text();
    return res.status(400).json({ success: false, xabar: errorText });
  }
}
