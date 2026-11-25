const RewriteJavaScript = require("./Rewriter");
const Net = require("node:net");
const Fs = require("node:fs");

const PingMessage = 0;
const RewriteMessage = 1;
const ResultMessage = 2;
const ErrorMessage = 3;

const Logger = {
  _Log(Level, Color, ...Args) {
    process.stdout.write("\x1b[1;37mYip:\x1b[0m ");
    process.stderr.write(
      `\x1b[1;${Color}m${Level}:\x1b[0m ${Args.join(" ")}\n`,
    );
  },

  Log(...Args) {
    this._Log("Info", 34, ...Args);
  },

  Error(...Args) {
    this._Log("Error", 31, ...Args);
  },
};

const Server = Net.createServer((Socket) => {
  let Data = Buffer.alloc(0);

  Socket.on("data", (Chunk) => {
    Data = Buffer.concat([Data, Chunk]);

    while (Data.length >= 4) {
      const Length = Data.readUInt32BE(0);

      if (Length < 5 || Length > 16 * 1024 * 1024) {
        Logger.Error(
          "Lua server message exceeds maximum allowed size or is smaller than the minimum allowed size",
        );
        Socket.destroy();
        return;
      }

      if (Data.length < Length + 4) break;

      const Type = Data.readUInt8(4);
      const Id = Data.readUInt32BE(5);
      const Payload = Data.subarray(9, Length + 4);

      Data = Data.subarray(Length + 4);

      let ResponseType = ResultMessage;
      let ResponsePayload;

      try {
        if (Type === RewriteMessage) {
          ResponsePayload = Buffer.from(
            RewriteJavaScript(Payload.toString("utf8")),
          );
        } else if (Type === PingMessage) {
          ResponseType = PingMessage;
          ResponsePayload = Buffer.alloc(0);
        }
      } catch (Error) {
        Logger.Error("Failed to respond to message:", Error.message);

        ResponseType = ResultMessage;
        ResponsePayload = Buffer.from(Error.message);
      }

      const Response = Buffer.alloc(9 + ResponsePayload.length);

      Response.writeUInt32BE(5 + ResponsePayload.length, 0);
      Response.writeUInt8(ResponseType, 4);
      Response.writeUInt32BE(Id, 5);
      ResponsePayload.copy(Response, 9);

      Socket.write(Response);
    }
  });
});

try {
  Fs.unlinkSync("/tmp/Yip.sock");
} catch (Error) {
  if (Error.code !== "ENOENT") throw Error;
}

Server.listen("/tmp/Yip.sock", () => {
  Logger.Log("JavaScript Server is listening on", "/tmp/Yip.sock");
});
