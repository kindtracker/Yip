self.addEventListener("message", (Event) => {
  if (Event.data?.Type === "SetPageUrl" && Event.source?.id)
    PageUrls.set(Event.source.id, Event.data.Value);
});

self.addEventListener("install", (Event) =>
  Event.waitUntil(self.skipWaiting()),
);
self.addEventListener("activate", (Event) =>
  Event.waitUntil(self.clients.claim()),
);

self.addEventListener("fetch", (Event) => {
  const Url = new URL(Event.request.url);

  if (
    Url.origin !== Origin ||
    Url.pathname.includes("_Nycury") ||
    /^\/https?:\/\//i.test(Url.pathname)
  )
    return;

  Event.respondWith(
    (async () => {
      let Base = Bases.get(Event.clientId);

      if (!Base && Event.clientId) {
        const Client = await self.clients.get(Event.clientId);
        const Path = new URL(Client?.url || "http://invalid").pathname.slice(1);

        if (/^https?:\/\//i.test(Path)) Base = Path;
      }

      if (!Base) return fetch(Event.request);

      const Target = new URL(Url.pathname + Url.search, Base);
      return fetch(new Request(Proxy + Target.href, Event.request));
    })(),
  );
});
