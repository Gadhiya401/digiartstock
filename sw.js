// Digiart Stock Checker service worker.
// Only here so browsers offer "Install app"; nothing is cached, so the app always loads the
// latest version from the server (and needs internet, like before).
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", e => {
  if (e.request.method !== "GET" || e.request.mode !== "navigate") return;   // everything else: browser as usual
  e.respondWith(fetch(e.request));
});
