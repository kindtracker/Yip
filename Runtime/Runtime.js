const ProxyHost = "localhost";
const ProxyPort = 8000;
const ProxyAddress = `http://${ProxyHost}:${ProxyPort}`;

const UrlAttributes = [
  "href",
  "src",
  "action",
  "formaction",
  "poster",
  "data",
  "cite",
  "codebase",
  "manifest",
  "longdesc",
  "background",
  "xlink:href",
  "itemid",
  "attributionsrc",
];

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

function RewriteSrcset(Value) {
  return Value.split(",")
    .map((Candidate) => {
      const Parts = Candidate.trim().split(/\s+/);
      Parts[0] = RewriteUrl(Parts[0]);
      return Parts.join(" ");
    })
    .join(", ");
}

function RewritePing(Value) {
  return Value.split(/\s+/).map(RewriteUrl).join(" ");
}

function RewriteSrcdoc(Element) {
  const Document = new DOMParser().parseFromString(Element.srcdoc, "text/html");
  RewriteDocument(Document);
  Element.srcdoc = Document.documentElement.outerHTML;
}

function RewriteDocument(Document) {
  RewriteElement(Document.documentElement);

  Document.querySelectorAll("*").forEach(RewriteElement);
}

function RewriteElement(Element) {
  if (!(Element instanceof Element)) {
    return;
  }

  RewriteUrlProperty(Element, "href");
  for (const UrlAttribute in UrlAttributes) {
    if (!Element.hasAttribute(UrlAttribute)) continue;
    const Attribute = Element.getAttribute(UrlAttribute);

    if (UrlAttribute === "srcset") {
      Element.srcset = RewriteSrcset(Attribute);
    } else if (UrlAttribute === "ping") {
      Element.ping = RewritePing(Attribute);
    } else {
      Element[UrlAttribute] = RewriteUrl(Attribute);
    }
  }

  Element.childNodes.forEach((Child) => {
    RewriteElement(Child);
  });
}
const Observer = new MutationObserver((MutationsList) => {
  for (const Mutation of MutationsList) {
    if (Mutation.type === "attributes") {
      RewriteElement(Mutation.target);
    }

    for (const Element of Mutation.addedNodes ?? []) {
      RewriteElement(Element);
    }
  }
});

Observer.observe(document.documentElement, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: UrlAttributes,
});
