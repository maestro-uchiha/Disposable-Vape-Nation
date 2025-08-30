const SCOPE = new URL(self.registration.scope);
let REDIRECTS = null;

async function loadRedirects() {
  try {
    const res = await fetch(new URL('redirects.json', SCOPE), { cache: 'no-store' });
    if (!res.ok) return;
    REDIRECTS = await res.json();
  } catch (e) {}
}

self.addEventListener('install', (event) => {
  event.waitUntil(loadRedirects().then(() => self.skipWaiting()));
});
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

function wildcardToRegex(pattern) {
  const esc = pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp('^' + esc.replace(/\*/g, '.*') + '$');
}

function matchPath(relPath) {
  if (!Array.isArray(REDIRECTS)) return null;
  for (const r of REDIRECTS) {
    if (r && r.disabled === true) continue;
    const from = String(r.from || '');
    const to = String(r.to || '');
    const code = Number(r.type || 301);
    if (!from || !to) continue;
    if (wildcardToRegex(from).test(relPath)) return { to, code };
  }
  return null;
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET' || req.mode !== 'navigate') return;

  const url = new URL(req.url);
  const scopePath = SCOPE.pathname.endsWith('/') ? SCOPE.pathname : SCOPE.pathname + '/';

  let rel = url.pathname;
  if (rel.startsWith(scopePath)) rel = rel.substring(scopePath.length - 1); // keep leading '/'

  const m = matchPath(rel);
  if (m) {
    const target = new URL(m.to, SCOPE);
    // preserve query + hash
    target.search = url.search;
    target.hash = url.hash;
    event.respondWith(Response.redirect(target.href, m.code));
  }
});
