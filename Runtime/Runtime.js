const ProxyHost = "localhost";
const ProxyPort = 8000;
const ProxyAddress = `http://${ProxyHost}:${ProxyPort}`;
const ProxyPrefix = `${ProxyAddress}/`;

const UrlAttributes = [
  "href",
  "src",
  "srcset",
  "imagesrcset",
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
  "profile",
  "usemap",
];

const DocumentObservers = new WeakMap();
const DocumentBases = new WeakMap();
const ObservedFrames = new WeakSet();

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

function GetPageUrl(Document) {
  return (
    DocumentBases.get(Document) ||
    UnproxyUrl(Document.location?.href || window.location.href)
  );
}

function GetDocumentBase(Document) {
  const PageUrl = GetPageUrl(Document);
  const BaseElement = Document.querySelector("base[href]");
  if (!BaseElement) {
    return PageUrl;
  }

  const BaseUrl = UnproxyUrl(BaseElement.getAttribute("href"));
  try {
    return new URL(BaseUrl, PageUrl).href;
  } catch {
    return PageUrl;
  }
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

function RewriteAttribute(Element, Attribute, Value) {
  if (Element.getAttribute(Attribute) === Value) {
    return;
  }

  Element.setAttribute(Attribute, Value);
}

function RewriteSrcset(Value, BaseUrl) {
  const Candidates = [];
  let Position = 0;

  while (Position < Value.length) {
    while (
      Position < Value.length &&
      (Value[Position] === "," || /\s/.test(Value[Position]))
    ) {
      Position++;
    }
    if (Position >= Value.length) {
      break;
    }

    const Start = Position;
    while (Position < Value.length && !/\s/.test(Value[Position])) {
      Position++;
    }

    let Url = Value.slice(Start, Position);
    const HasTrailingComma = Url.endsWith(",");
    while (Url.endsWith(",")) {
      Url = Url.slice(0, -1);
    }

    let Descriptor = "";
    if (!HasTrailingComma) {
      while (Position < Value.length && /\s/.test(Value[Position])) {
        Position++;
      }

      const DescriptorStart = Position;
      while (Position < Value.length && Value[Position] !== ",") {
        Position++;
      }

      Descriptor = Value.slice(DescriptorStart, Position).trim();
    }

    if (Url) {
      const Rewritten = RewriteUrl(Url, BaseUrl);
      Candidates.push(Descriptor ? `${Rewritten} ${Descriptor}` : Rewritten);
    }

    if (Value[Position] === ",") {
      Position++;
    }
  }

  return Candidates.join(", ");
}

function RewriteUrlList(Value, BaseUrl) {
  return Value.trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((Url) => RewriteUrl(Url, BaseUrl))
    .join(" ");
}

function RewriteRefresh(Value, BaseUrl) {
  return Value.replace(
    /^(\s*\d+\s*;\s*url\s*=\s*)(.*)$/i,
    (Match, Prefix, Url) => {
      const Quote = Url.match(/^(['"])(.*)\1$/);
      if (Quote) {
        return Prefix + Quote[1] + RewriteUrl(Quote[2], BaseUrl) + Quote[1];
      }

      return Prefix + RewriteUrl(Url, BaseUrl);
    },
  );
}

function RewriteSrcdoc(Element) {
  try {
    const FrameDocument = Element.contentDocument;
    if (!FrameDocument) {
      return;
    }
    InitializeDocument(FrameDocument, GetDocumentBase(Element.ownerDocument));
  } catch {}
}

function ObserveFrame(Element) {
  if (ObservedFrames.has(Element)) {
    return;
  }

  ObservedFrames.add(Element);
  Element.addEventListener("load", () => {
    try {
      const FrameDocument = Element.contentDocument;
      if (!FrameDocument) {
        return;
      }
      const BaseUrl = Element.hasAttribute("srcdoc")
        ? GetDocumentBase(Element.ownerDocument)
        : UnproxyUrl(FrameDocument.location.href);

      InitializeDocument(FrameDocument, BaseUrl);
    } catch {}
  });

  if (Element.contentDocument?.readyState === "complete") {
    RewriteSrcdoc(Element);
  }
}

function RewriteElement(Element) {
  if (!(Element instanceof Element.ownerDocument.defaultView.Element)) {
    return;
  }

  const Document = Element.ownerDocument;
  const BaseUrl =
    Element.localName === "base"
      ? GetPageUrl(Document)
      : GetDocumentBase(Document);
  for (const Attribute of UrlAttributes) {
    if (!Element.hasAttribute(Attribute)) {
      continue;
    }

    const Value = Element.getAttribute(Attribute);

    let Rewritten;
    switch (Attribute) {
      case "srcset":
      case "imagesrcset":
        Rewritten = RewriteSrcset(Value, BaseUrl);
        break;
      case "ping":
      case "attributionsrc":
        Rewritten = RewriteUrlList(Value, BaseUrl);
        break;
      default:
        Rewritten = RewriteUrl(Value, BaseUrl);
        break;
    }

    RewriteAttribute(Element, Attribute, Rewritten);
  }

  if (
    Element.localName === "meta" &&
    Element.httpEquiv?.toLowerCase() === "refresh"
  ) {
    RewriteAttribute(
      Element,
      "content",
      RewriteRefresh(Element.content, BaseUrl),
    );
  }

  if (Element instanceof Document.defaultView.HTMLIFrameElement) {
    ObserveFrame(Element);
  }
}

function RewriteSubtree(Node) {
  if (!(Node instanceof Node.ownerDocument.defaultView.Element)) {
    return;
  }

  RewriteElement(Node);
  Node.querySelectorAll("*").forEach(RewriteElement);
}

function RewriteDocument(Document) {
  if (!Document.documentElement) {
    return;
  }

  RewriteSubtree(Document.documentElement);
}

function InstallUrlOverrides(Document) {
  const Window = Document.defaultView;
  if (!Window) return;

  const Patched = new WeakSet();

  function PatchSetter(Prototype, Property, Attribute = Property) {
    if (!Prototype) return;

    const Descriptor = Object.getOwnPropertyDescriptor(Prototype, Property);

    if (!Descriptor?.set || !Descriptor.configurable) return;

    Object.defineProperty(Prototype, Property, {
      ...Descriptor,

      set(Value) {
        if (typeof Value === "string") {
          const BaseUrl = GetDocumentBase(this.ownerDocument);

          switch (Attribute) {
            case "srcset":
            case "imagesrcset":
              Value = RewriteSrcset(Value, BaseUrl);
              break;

            case "ping":
            case "attributionsrc":
              Value = RewriteUrlList(Value, BaseUrl);
              break;

            default:
              Value = RewriteUrl(Value, BaseUrl);
              break;
          }
        }

        return Descriptor.set.call(this, Value);
      },
    });
  }

  function PatchSetAttribute(Prototype) {
    if (!Prototype || Patched.has(Prototype)) return;
    Patched.add(Prototype);

    const Original = Prototype.setAttribute;

    Prototype.setAttribute = function (Name, Value) {
      const Attribute = String(Name).toLowerCase();

      if (UrlAttributes.includes(Attribute)) {
        const BaseUrl = GetDocumentBase(this.ownerDocument);

        switch (Attribute) {
          case "srcset":
          case "imagesrcset":
            Value = RewriteSrcset(String(Value), BaseUrl);
            break;

          case "ping":
          case "attributionsrc":
            Value = RewriteUrlList(String(Value), BaseUrl);
            break;

          default:
            Value = RewriteUrl(String(Value), BaseUrl);
            break;
        }
      }

      if (
        Attribute === "content" &&
        this.localName === "meta" &&
        this.httpEquiv?.toLowerCase() === "refresh"
      ) {
        Value = RewriteRefresh(
          String(Value),
          GetDocumentBase(this.ownerDocument),
        );
      }

      return Original.call(this, Name, Value);
    };
  }

  const PropertyGroups = [
    [Window.HTMLAnchorElement, ["href"]],
    [Window.HTMLAreaElement, ["href"]],
    [Window.HTMLLinkElement, ["href"]],
    [Window.HTMLScriptElement, ["src"]],
    [Window.HTMLImageElement, ["src", "srcset"]],
    [Window.HTMLSourceElement, ["src", "srcset"]],
    [Window.HTMLMediaElement, ["src"]],
    [Window.HTMLVideoElement, ["poster"]],
    [Window.HTMLIFrameElement, ["src"]],
    [Window.HTMLFormElement, ["action"]],
    [Window.HTMLInputElement, ["src", "formAction"]],
    [Window.HTMLButtonElement, ["formAction"]],
    [Window.HTMLObjectElement, ["data"]],
    [Window.HTMLQuoteElement, ["cite"]],
    [Window.HTMLBaseElement, ["href"]],
    [Window.HTMLTrackElement, ["src"]],
  ];

  for (const [Constructor, Properties] of PropertyGroups) {
    if (!Constructor) continue;

    for (const Property of Properties) {
      const Attribute = Property.toLowerCase();

      PatchSetter(Constructor.prototype, Property, Attribute);
    }

    PatchSetAttribute(Constructor.prototype);
  }

  PatchSetAttribute(Window.Element.prototype);
}

async function RegisterServiceWorker() {
  if (!("serviceWorker" in navigator)) {
    console.warn("Yip: Service Workers are unsupported");
    return;
  }

  try {
    const Registration = await navigator.serviceWorker.register(
      "/_yip_service_worker.js?_yip=true",
      {
        scope: "/",
      },
    );

    console.log("Yip Service Worker registered:", Registration.scope);
  } catch (Error) {
    console.error("Yip: Failed to register Service Worker:", Error);
  }
}

function ObserveDocument(Document) {
  if (DocumentObservers.has(Document)) {
    return DocumentObservers.get(Document);
  }

  const Observer = new Document.defaultView.MutationObserver(
    (MutationsList) => {
      for (const Mutation of MutationsList) {
        if (Mutation.type === "attributes") {
          RewriteElement(Mutation.target);
          continue;
        }

        for (const Node of Mutation.addedNodes) {
          RewriteSubtree(Node);
        }
      }
    },
  );

  Observer.observe(Document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: [...UrlAttributes, "content"],
  });

  DocumentObservers.set(Document, Observer);
  return Observer;
}

function InitializeDocument(Document, BaseUrl) {
  if (!Document || !Document.documentElement) {
    return;
  }

  if (!DocumentBases.has(Document)) {
    DocumentBases.set(Document, BaseUrl);
  }

  InstallUrlOverrides(Document);
  RewriteDocument(Document);
  ObserveDocument(Document);
}

async function Initialize() {
  InitializeDocument(document, UnproxyUrl(window.location.href));

  await RegisterServiceWorker();
  const Registration = await navigator.serviceWorker.ready;
  Registration.active.postMessage({
    Type: "SetBaseUrl",
    BaseUrl: UnproxyUrl(window.location.href),
  });
}

Initialize();
