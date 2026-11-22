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

function RewriteUrlProperty(Element, PropertyName) {
  const Property = Element[PropertyName];
  if (Property) {
    Element[PropertyName] = RewriteUrl(Property);
  }
}

function RewriteElement(Element) {
  RewriteUrlProperty(Element, "href");
  RewriteUrlProperty(Element, "action");
  RewriteUrlProperty(Element, "formaction");
  RewriteUrlProperty(Element, "formaction");
  RewriteUrlProperty(Element, "src");
  RewriteUrlProperty(Element, "srcset");
  RewriteUrlProperty(Element, "srcdoc");
  RewriteUrlProperty(Element, "data");
  RewriteUrlProperty(Element, "poster");
  RewriteUrlProperty(Element, "cite");

  Element.childNodes.forEach((Child) => {
    RewriteElement(Child);
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
