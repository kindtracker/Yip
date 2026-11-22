const Proxy = "http://localhost:8000/";
const Attributes = [
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

const Bases = new WeakMap();
const Observers = new WeakMap();
const Frames = new WeakSet();

function Unproxy(Url) {
  return Url.startsWith(Proxy) && /^https?:\/\//i.test(Url.slice(Proxy.length))
    ? Url.slice(Proxy.length)
    : Url;
}

function Base(Document) {
  return Bases.get(Document) || Unproxy(Document.location.href);
}

function Rewrite(Url, BaseUrl) {
  Url = Url.trim();

  if (!Url || Url.startsWith("#") || Url.startsWith(Proxy)) return Url;

  try {
    const Result = new URL(Url, BaseUrl);
    return /^https?:$/.test(Result.protocol) ? Proxy + Result.href : Url;
  } catch {
    return Url;
  }
}

function RewriteList(Value, BaseUrl) {
  return Value.split(/\s+/)
    .map((Url) => Rewrite(Url, BaseUrl))
    .join(" ");
}

function RewriteSrcset(Value, BaseUrl) {
  return Value.replace(
    /(\S+)(\s+\d+[wx])?/g,
    (_, Url, Size = "") => Rewrite(Url.replace(/,$/, ""), BaseUrl) + Size,
  );
}

function RewriteValue(Attribute, Value, BaseUrl) {
  if (["srcset", "imagesrcset"].includes(Attribute))
    return RewriteSrcset(Value, BaseUrl);

  if (["ping", "attributionsrc"].includes(Attribute))
    return RewriteList(Value, BaseUrl);

  return Rewrite(Value, BaseUrl);
}

function RewriteElement(Element) {
  if (!(Element instanceof Element.ownerDocument.defaultView.Element)) return;

  const Document = Element.ownerDocument;
  const BaseUrl = Base(Document);

  for (const Attribute of Attributes) {
    if (!Element.hasAttribute(Attribute)) continue;

    const Value = Element.getAttribute(Attribute);
    const Result = RewriteValue(Attribute, Value, BaseUrl);

    if (Value !== Result) Element.setAttribute(Attribute, Result);
  }

  if (
    Element.localName === "meta" &&
    Element.httpEquiv?.toLowerCase() === "refresh"
  ) {
    Element.content = Element.content.replace(
      /(url\s*=\s*)(['"]?)([^'"]+)\2/i,
      (_, Prefix, Quote, Url) => Prefix + Quote + Rewrite(Url, BaseUrl) + Quote,
    );
  }

  if (Element instanceof Document.defaultView.HTMLIFrameElement)
    ObserveFrame(Element);
}

function RewriteTree(Node) {
  if (!(Node instanceof Node.ownerDocument.defaultView.Element)) return;

  RewriteElement(Node);
  Node.querySelectorAll("*").forEach(RewriteElement);
}

function ObserveFrame(Frame) {
  if (Frames.has(Frame)) return;
  Frames.add(Frame);

  Frame.addEventListener("load", () => {
    try {
      const Document = Frame.contentDocument;
      if (Document)
        InitializeDocument(Document, Unproxy(Document.location.href));
    } catch {}
  });
}

function InstallOverrides(Document) {
  const Window = Document.defaultView;
  if (!Window) return;

  const Groups = {
    HTMLAnchorElement: ["href"],
    HTMLAreaElement: ["href"],
    HTMLLinkElement: ["href"],
    HTMLScriptElement: ["src"],
    HTMLImageElement: ["src", "srcset"],
    HTMLSourceElement: ["src", "srcset"],
    HTMLMediaElement: ["src"],
    HTMLVideoElement: ["poster"],
    HTMLIFrameElement: ["src"],
    HTMLFormElement: ["action"],
    HTMLInputElement: ["src", "formAction"],
    HTMLButtonElement: ["formAction"],
    HTMLObjectElement: ["data"],
    HTMLQuoteElement: ["cite"],
    HTMLBaseElement: ["href"],
    HTMLTrackElement: ["src"],
  };

  for (const [Name, Properties] of Object.entries(Groups)) {
    const Prototype = Window[Name]?.prototype;
    if (!Prototype) continue;

    for (const Property of Properties) {
      const Descriptor = Object.getOwnPropertyDescriptor(Prototype, Property);
      if (!Descriptor?.set || !Descriptor.configurable) continue;

      Object.defineProperty(Prototype, Property, {
        ...Descriptor,
        set(Value) {
          return Descriptor.set.call(
            this,
            typeof Value === "string"
              ? RewriteValue(
                  Property.toLowerCase(),
                  Value,
                  Base(this.ownerDocument),
                )
              : Value,
          );
        },
      });
    }
  }

  const Original = Window.Element.prototype.setAttribute;

  Window.Element.prototype.setAttribute = function (Name, Value) {
    Name = String(Name).toLowerCase();

    if (Attributes.includes(Name))
      Value = RewriteValue(Name, String(Value), Base(this.ownerDocument));

    return Original.call(this, Name, Value);
  };
}

function InitializeDocument(Document, BaseUrl) {
  if (!Document?.documentElement) return;

  Bases.set(Document, BaseUrl);
  InstallOverrides(Document);
  RewriteTree(Document.documentElement);

  if (Observers.has(Document)) return;

  const Observer = new Document.defaultView.MutationObserver((Mutations) => {
    for (const Mutation of Mutations) {
      if (Mutation.type === "attributes") RewriteElement(Mutation.target);
      else Mutation.addedNodes.forEach(RewriteTree);
    }
  });

  Observer.observe(Document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: [...Attributes, "content"],
  });

  Observers.set(Document, Observer);
}

async function Initialize() {
  const BaseUrl = Unproxy(location.href);
  InitializeDocument(document, BaseUrl);

  if (!("serviceWorker" in navigator)) return;

  try {
    await navigator.serviceWorker.register("/_yip_service_worker.js?_yip=true");
    const Registration = await navigator.serviceWorker.ready;

    const SendBase = () =>
      navigator.serviceWorker.controller?.postMessage({
        Type: "SetBaseUrl",
        BaseUrl,
      });

    SendBase();
    navigator.serviceWorker.addEventListener("controllerchange", SendBase);
  } catch {}
}

Initialize();
