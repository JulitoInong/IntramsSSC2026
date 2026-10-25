const CACHE_NAME = 'ssc-intramurals-shell-v20261025-mobile-fix1';
const CDN_CACHE = 'ssc-intramurals-cdn-v20261025-resilient2';

const APP_FILES = [
  './',
  './index.html',
  './styles.css',
  './app.js',
  './manifest.webmanifest',
  './icons/ssc_logo.png',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './student.html',
  './student.css',
  './student.js'
];

function getCleanUrl(url) {
  try {
    const u = new URL(url);
    u.search = '';
    u.hash = '';
    return u.toString();
  } catch {
    return url;
  }
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_FILES))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => ![CACHE_NAME, CDN_CACHE].includes(key))
          .map((key) => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // 1. External Supabase CDN Cache Handling
  if (url.hostname === 'cdn.jsdelivr.net' && url.pathname.includes('/@supabase/supabase-js@')) {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response && response.ok) {
            const copy = response.clone();
            caches.open(CDN_CACHE).then((cache) => cache.put(request, copy)).catch(() => {});
          }
          return response;
        })
        .catch(async () => {
          return (await caches.match(request, { ignoreSearch: true })) || Response.error();
        })
    );
    return;
  }

  // Only handle same-origin local assets
  if (url.origin !== self.location.origin) return;

  // 2. Same-Origin Assets: Network First with Query-Agnostic Offline Fallback
  event.respondWith(
    fetch(request)
      .then((response) => {
        if (response && response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copy)).catch(() => {});
        }
        return response;
      })
      .catch(async () => {
        // Query-agnostic match: matches cached asset even if version query string changes (e.g., ?v=2026)
        const cachedResponse = await caches.match(request, { ignoreSearch: true });
        if (cachedResponse) {
          return cachedResponse;
        }

        // Only return HTML fallback for actual document/navigation requests (never for missing CSS/JS)
        if (request.mode === 'navigate' || request.destination === 'document' || url.pathname.endsWith('.html') || url.pathname.endsWith('/')) {
          if (url.pathname.includes('student.html')) {
            const studentShell = await caches.match('./student.html', { ignoreSearch: true });
            if (studentShell) return studentShell;
          }
          const adminShell = await caches.match('./index.html', { ignoreSearch: true });
          if (adminShell) return adminShell;
        }

        // For non-navigation requests (missing CSS, JS, images), do NOT return index.html
        return Response.error();
      })
  );
});
