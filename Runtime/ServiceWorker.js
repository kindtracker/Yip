const ProxyHost = "localhost";
const ProxyPort = 8000;
const ProxyAddress = `http://${ProxyHost}:${ProxyPort}`;
const ProxyPrefix = `${ProxyAddress}/`;

function IsProxyUrl(Value) {
  return Value === ProxyAddress || Value.startsWith(ProxyPrefix);
}

function UnproxyUrl(Value) {
  if (!Value.startsWith(ProxyPrefix)) {
    return Value;
  }

  const Original = Value.slice(ProxyPrefix.length);
  if (/^https?:\/\//i.test(Original)) {
    return Original;
  }

  return Value;
}

function RewriteUrl(Value, BaseUrl) {
  Value = Value.trim();
  if (!Value || Value.startsWith("#")) {
    return Value;
  }

  if (IsProxyUrl(Value)) {
    return Value;
  }

  try {
    const Url = new URL(Value, BaseUrl);
    if (Url.protocol !== "http:" && Url.protocol !== "https:") {
      return Value;
    }

    return `${ProxyPrefix}${Url.href}`;
  } catch {
    return Value;
  }
}

const BaseUrl = UnproxyUrl(window.location.href);

self.addEventListener("install", (Event) => {
  Event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (Event) => {
  Event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (Event) => {
  const ProxyUrl = RewriteUrl(Event.request.ur, BaseUrl);
  Event.respondWith(fetch(ProxyUrl));
});
