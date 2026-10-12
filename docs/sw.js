self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});

self.addEventListener('push', (e) => {
  const { title, body } = e.data.json();
  e.waitUntil(self.registration.showNotification(title, { body, lang: 'he', dir: 'rtl' }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window' }).then(([c]) => c ? c.focus() : self.clients.openWindow('./#/requests')));
});
