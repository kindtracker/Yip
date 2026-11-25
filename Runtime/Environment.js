const NyCuryEvironmentHandler = {
  get(Target, Key) {
    if (Key == "document") {
      return window.document;
    } else {
      return window[Key];
    }
  },
};

window._nycuryenv = new Proxy({}, NyCuryEvironmentHandler);
