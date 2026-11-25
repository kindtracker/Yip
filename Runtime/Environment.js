const OriginalDocument = window.document;

function Unproxy(Url) {
  return Url.startsWith(window._NycuryProxy) &&
    /^https?:\/\//i.test(Url.slice(window._NycuryProxy.length))
    ? Url.slice(window._NycuryProxy.length)
    : Url;
}

const BaseUrl = Unproxy(location.href);
const NycuryDocument = new Proxy(
  {},
  {
    get(Target, Key) {
      if (Key === "URL") {
        return BaseUrl;
      }

      return window.document[Key];
    },

    set(Target, Key, Value) {
      window.document[Key] = Value;
      return true;
    },

    has(Target, Key) {
      return Key in window.document;
    },

    deleteProperty(Target, Key) {
      return delete window.document[Key];
    },

    defineProperty(Target, Key, Descriptor) {
      Object.defineProperty(window.document, Key, Descriptor);
      return true;
    },

    getOwnPropertyDescriptor(Target, Key) {
      return Object.getOwnPropertyDescriptor(window.document, Key);
    },

    getPrototypeOf(Target) {
      return Object.getPrototypeOf(window.document);
    },

    setPrototypeOf(Target, Prototype) {
      Object.setPrototypeOf(window.document, Prototype);
      return true;
    },

    isExtensible(Target) {
      return Object.isExtensible(window.document);
    },

    preventExtensions(Target) {
      return Object.preventExtensions(window.document);
    },

    ownKeys(Target) {
      return Object.keys(window.document);
    },
  },
);

window._nycuryenv = new Proxy(
  {},
  {
    get(Target, Key) {
      if (Key === "document") {
        return NycuryDocument;
      }

      return window[Key];
    },

    set(Target, Key, Value) {
      window[Key] = Value;
      return true;
    },

    has(Target, Key) {
      return Key in window;
    },

    deleteProperty(Target, Key) {
      return delete window[Key];
    },
  },
);

window._nycuryenv = new Proxy(
  {},
  {
    get(Target, Key) {
      if (Key === "document") {
        return NycuryDocument;
      }

      return window[Key];
    },

    set(Target, Key, Value) {
      window[Key] = Value;
      return true;
    },

    has(Target, Key) {
      return Key in window;
    },

    deleteProperty(Target, Key) {
      return delete window[Key];
    },
  },
);
