const ProxyHost = "localhost";
const ProxyPort = 8000;
const ProxyAddress = `http://${ProxyHost}:${ProxyPort}`;
const ProxyPrefix = `${ProxyAddress}/`;

const ClientBaseUrls = new Map();

self.addEventListener("message", (Event) => {
  if (Event.data?.Type !== "SetBaseUrl") {
    return;
  }

  if (Event.source?.id) {
    ClientBaseUrls.set(Event.source.id, Event.data.BaseUrl);
  }
});

self.addEventListener("install", (Event) => {
  Event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (Event) => {
  Event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (Event) => {
  const RequestUrl = new URL(Event.request.url);
  if (RequestUrl.origin !== ProxyAddress) {
    return;
  }

  if (RequestUrl.pathname.includes("?_yip=true")) {
    return;
  }

  if (/^\/https?:\/\//i.test(RequestUrl.pathname)) {
    return;
  }

  const BaseUrl = ClientBaseUrls.get(Event.clientId);
  if (!BaseUrl) {
    console.warn("Yip: No BaseUrl registered for client:", Event.clientId);
    return;
  }

  const TargetUrl = new URL(RequestUrl.pathname + RequestUrl.search, BaseUrl);
  const ProxyUrl = `${ProxyPrefix}${TargetUrl.href}`;

  console.log("Yip intercepted:", Event.request.url);
  console.log("Yip destination:", ProxyUrl);

  const ProxyRequest = new Request(ProxyUrl, Event.request);
  Event.respondWith(fetch(ProxyRequest));
});
