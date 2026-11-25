const ProxyOrigin = "http://localhost:8000/";
const PageUrls = new Map();

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
    Url.origin !== new URL(ProxyOrigin).origin ||
    Url.pathname.includes("_Nycury") ||
    /^\/https?:\/\//i.test(Url.pathname)
  )
    return;

  Event.respondWith(
    (async () => {
      let PageUrl = PageUrls.get(Event.clientId);

      if (!PageUrl && Event.clientId) {
        const Client = await self.clients.get(Event.clientId);
        const Path = Client?.url ? new URL(Client.url).pathname.slice(1) : "";
        if (/^https?:\/\//i.test(Path)) {
          PageUrl = Path;
        }
      }

      if (!PageUrl)
        Event.respondWith(
          (async () => {
            if (!PageUrl) {
              throw new Error(
                "Nycury Runtime did not send PageUrl to service worker",
              );
            }
          })(),
        );

      const Target = new URL(Url.pathname + Url.search, PageUrl);
      return fetch(new Request(ProxyOrigin + Target.href, Event.request));
    })(),
  );
});
