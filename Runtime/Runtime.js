const Nycury = (() => {
  const ProxyOrigin = "http://localhost:8000/";

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

  const AttributeSet = new Set(Attributes);

  const Observers = new WeakMap();
  const Frames = new WeakSet();
  const InstalledDocuments = new WeakSet();
  const InstalledWindows = new WeakSet();

  function Unproxy(Url) {
    if (
      Url.startsWith(ProxyOrigin) &&
      /^https?:\/\//i.test(Url.slice(ProxyOrigin.length))
    ) {
      return Url.slice(ProxyOrigin.length);
    }

    return Url;
  }

  function RewriteUrl(State, Url) {
    Url = String(Url).trim();

    if (!Url || Url.startsWith(ProxyOrigin)) return Url;

    try {
      const Result = new URL(Url, State.PageUrl);

      if (!/^https?:$/.test(Result.protocol)) return Url;

      return ProxyOrigin + Result.href;
    } catch {
      return Url;
    }
  }

  function RewriteList(State, Value) {
    return Value.split(/\s+/)
      .map((Url) => RewriteUrl(State, Url))
      .join(" ");
  }

  function RewriteSrcset(State, Value) {
    return Value.replace(
      /(\S+)(\s+\d+[wx])?/g,
      (_, Url, Size = "") => RewriteUrl(State, Url.replace(/,$/, "")) + Size,
    );
  }

  function RewriteValue(State, Attribute, Value) {
    if (Attribute === "srcset" || Attribute === "imagesrcset") {
      return RewriteSrcset(State, Value);
    }

    if (Attribute === "ping" || Attribute === "attributionsrc") {
      return RewriteList(State, Value);
    }

    return RewriteUrl(State, Value);
  }

  function RewriteElement(State, Element) {
    const Document = Element.ownerDocument;
    const View = Document?.defaultView;

    if (!View || !(Element instanceof View.Element)) return;

    if (
      Element.tagName === "SCRIPT" &&
      Element.getAttribute("src")?.includes("_NycuryRuntime.js")
    ) {
      Element.remove();
      return;
    }

    for (const Attribute of Attributes) {
      if (!Element.hasAttribute(Attribute)) continue;

      const Value = Element.getAttribute(Attribute);
      const Result = RewriteValue(State, Attribute, Value);

      if (Value !== Result) {
        Element.setAttribute(Attribute, Result);
      }
    }

    if (
      Element.localName === "meta" &&
      Element.httpEquiv?.toLowerCase() === "refresh"
    ) {
      Element.content = Element.content.replace(
        /(url\s*=\s*)(['"]?)([^'"]+)\2/i,
        (_, Prefix, Quote, Url) =>
          Prefix + Quote + RewriteUrl(State, Url) + Quote,
      );
    }

    if (Element instanceof View.HTMLIFrameElement) {
      ObserveFrame(Element);
    }
  }

  function RewriteTree(State, Node) {
    const View = Node.ownerDocument?.defaultView;
    if (!View || !(Node instanceof View.Element)) return;

    RewriteElement(State, Node);
    Node.querySelectorAll("*").forEach((Element) => {
      RewriteElement(State, Element);
    });
  }

  function ObserveFrame(Frame) {
    if (Frames.has(Frame)) return;
    Frames.add(Frame);

    Frame.addEventListener("load", () => {
      try {
        const Document = Frame.contentDocument;
        if (!Document) return;

        const State = {
          PageUrl: Unproxy(Document.location.href),
        };
        InitializeDocument(State, Document);
        InstallXhr(State, Document.defaultView);
      } catch {}
    });
  }

  function InstallOverrides(State, Document) {
    const Window = Document.defaultView;
    if (!Window || InstalledDocuments.has(Document)) return;
    InstalledDocuments.add(Document);

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
            if (typeof Value === "string") {
              Value = RewriteValue(State, Property.toLowerCase(), Value);
            }

            return Descriptor.set.call(this, Value);
          },
        });
      }
    }

    const Original = Window.Element.prototype.setAttribute;
    Window.Element.prototype.setAttribute = function (Name, Value) {
      Name = String(Name).toLowerCase();
      if (AttributeSet.has(Name)) {
        Value = RewriteValue(State, Name, String(Value));
      }

      return Original.call(this, Name, Value);
    };
  }

  function InstallObserver(State, Document) {
    if (Observers.has(Document)) return;

    const Observer = new Document.defaultView.MutationObserver((Mutations) => {
      for (const Mutation of Mutations) {
        if (Mutation.type === "attributes") {
          RewriteElement(State, Mutation.target);
        } else {
          Mutation.addedNodes.forEach((Node) => {
            RewriteTree(State, Node);
          });
        }
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

  function InitializeDocument(State, Document) {
    if (!Document?.documentElement) return;

    InstallOverrides(State, Document);
    RewriteTree(State, Document.documentElement);
    InstallObserver(State, Document);
  }

  function InstallXhr(State, Window) {
    if (!Window || InstalledWindows.has(Window)) return;
    InstalledWindows.add(Window);

    const OriginalXhr = Window.XMLHttpRequest;
    class NycuryXhr extends OriginalXhr {
      open(Method, Url, ...Arguments) {
        Url = RewriteUrl(State, Url);
        return super.open(Method, Url, ...Arguments);
      }
    }

    Window.XMLHttpRequest = NycuryXhr;
  }

  async function InstallServiceWorker(State) {
    const Navigator = State.Document.defaultView.navigator;
    if (!("serviceWorker" in Navigator)) {
      return "Service Worker isn't supported by browser";
    }

    try {
      await Navigator.serviceWorker.register("/_NycuryServiceWorker.js");
      await Navigator.serviceWorker.ready;

      const SendState = () => {
        Navigator.serviceWorker.controller?.postMessage({
          Type: "State",
          Value: {
            PageUrl: State.PageUrl,
          },
        });
      };

      SendState();
      Navigator.serviceWorker.addEventListener("controllerchange", SendState);
    } catch (Error) {
      return `Service Worker: ${Error.message}`;
    }
  }

  async function Initialize() {
    if (window.Nycury.Initialized) return;
    window.Nycury.Initialized = true;

    const Document = window.document;
    const State = {
      Document,
      PageUrl: Unproxy(Document.location.href),
    };

    InstallXhr(State, window);
    InitializeDocument(State, Document);
    await InstallServiceWorker(State);
    return State;
  }

  return {
    Proxy: ProxyOrigin,
    Unproxy,
    RewriteUrl,
    RewriteValue,
    Initialize,
    InitializeDocument,
    InstallXhr,
    InstallOverrides,
  };
})();

window.Nycury = Nycury;
Nycury.Initialize();
