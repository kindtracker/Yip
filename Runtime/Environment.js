const OriginalDocument = window.document;

const Nycury = (() => {
  const Routes = new Map();

  function Route(Context, Operation, Key, Handler) {
    let ContextRoutes = Routes.get(Context);
    if (!ContextRoutes) {
      ContextRoutes = new Map();
      Routes.set(Context, ContextRoutes);
    }

    let OperationRoutes = ContextRoutes.get(Operation);
    if (!OperationRoutes) {
      OperationRoutes = new Map();
      ContextRoutes.set(Operation, OperationRoutes);
    }

    OperationRoutes.set(Key, Handler);
  }

  function Dispatch(Context, Operation, Data) {
    const Handler = Routes.get(Context)?.get(Operation)?.get(Data.Key);
    if (!Handler) return { Handled: false };

    return {
      Handled: true,
      Value: Handler(Data),
    };
  }

  function CreateProxy(Context, Target) {
    return new Proxy(Target, {
      get(Target, Key, Receiver) {
        const Result = Dispatch(Context, "get", {
          Target,
          Key,
          Receiver,
        });
        if (Result.Handled) return Result.Value;
        return Reflect.get(Target, Key, Receiver);
      },

      set(Target, Key, Value, Receiver) {
        const Result = Dispatch(Context, "set", {
          Target,
          Key,
          Value,
          Receiver,
        });
        if (Result.Handled) return Result.Value;
        return Reflect.set(Target, Key, Value, Receiver);
      },

      has(Target, Key) {
        const Result = Dispatch(Context, "has", {
          Target,
          Key,
        });
        if (Result.Handled) return Result.Value;
        return Reflect.has(Target, Key);
      },

      deleteProperty(Target, Key) {
        const Result = Dispatch(Context, "delete", {
          Target,
          Key,
        });
        if (Result.Handled) return Result.Value;
        return Reflect.deleteProperty(Target, Key);
      },

      defineProperty(Target, Key, Descriptor) {
        const Result = Dispatch(Context, "define", {
          Target,
          Key,
          Descriptor,
        });
        if (Result.Handled) return Result.Value;
        return Reflect.defineProperty(Target, Key, Descriptor);
      },
    });
  }

  return {
    Route,
    Dispatch,
    CreateProxy,
  };
})();

const DocumentContext = Symbol("Document");
const EnvironmentContext = Symbol("Environment");

const BaseUrl = Nycury.Unproxy(OriginalDocument.location.href);
Nycury.Route(DocumentContext, "get", "URL", () => BaseUrl);
Nycury.Route(DocumentContext, "get", "documentURI", () => BaseUrl);

const NycuryDocument = Nycury.CreateProxy(DocumentContext, OriginalDocument);
Nycury.Route(EnvironmentContext, "get", "document", () => NycuryDocument);

window._nycuryenv = Nycury.CreateProxy(EnvironmentContext, window);
