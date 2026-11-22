const ProxyHost = "localhost";
const ProxyPort = 8000;
const ProxyAddress = `http://${ProxyHost}:${ProxyPort}`;

function RewriteUrl(Url) {
  if (!/^https?:\/\//i.test(Url)) {
    return Url;
  }

  if (Url.startsWith(ProxyAddress)) {
    return Url;
  }

  return `${ProxyAddress}/${Url}`;
}

function RewriteElement(Element) {
  if (Element.href) {
    Element.href = RewriteUrl(Element.href);
  }

  Element.querySelectorAll?.("[href]").forEach((Child) => {
    Child.href = RewriteUrl(Child.href);
  });
}
const Observer = new MutationObserver((MutationsList) => {
  for (const Mutation of MutationsList) {
    for (const Element of Mutation.addedNodes) {
      RewriteElement(Element);
    }
  }
});

Observer.observe(document.documentElement, {
  childList: true,
  subtree: true,
});
