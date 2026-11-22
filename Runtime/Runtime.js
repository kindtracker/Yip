const ProxyHost = "localhost";
const ProxyPort = 8000;
const ProxyAddress = `http://${ProxyHost}:${ProxyPort}`;

const UrlAttributes = [
  "href",
  "src",
  "srcset",
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
  "ping",
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
  const Document = Element.contentDocument;
  if (!Document) return;

  RewriteDocument(Document);
  ObserveDocument(Document);
}

function RewriteDocument(Document) {
  RewriteElement(Document.documentElement);

  Document.querySelectorAll("*").forEach(RewriteElement);
}

function ObserveDocument(Document) {
  const Observer = new MutationObserver((MutationsList) => {
    for (const Mutation of MutationsList) {
      if (Mutation.type === "attributes") {
        RewriteElement(Mutation.target);
      }

      for (const Node of Mutation.addedNodes) {
        RewriteElement(Node);
      }
    }
  });

  Observer.observe(Document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: UrlAttributes,
  });

  return Observer;
}

function RewriteElement(Element) {
  if (!(Element instanceof window.Element)) {
    return;
  }

  RewriteUrlProperty(Element, "href");
  for (const UrlAttribute of UrlAttributes) {
    if (!Element.hasAttribute(UrlAttribute)) continue;
    const Attribute = Element.getAttribute(UrlAttribute);

    if (UrlAttribute === "srcset") {
      Element.setAttribute("srcset", RewriteSrcset(Attribute));
    } else if (UrlAttribute === "ping") {
      Element.setAttribute("ping", RewritePing(Attribute));
    } else {
      Element.setAttribute(UrlAttribute, RewriteUrl(Attribute));
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
