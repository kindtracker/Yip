local LuaSocket = require("socket")
local Copas = require("copas")

local Server

local function HandleClient(Client)
  local ClientStartTime = LuaSocket.gettime()
  local StartTime = 0

  Client = Copas.wrap(Client)
  Client:settimeout(10)

  StartTime = LuaSocket.gettime()

  local Headers, Body = ReadRequest(Client)
  local Error = Body
  if not Headers then
    Logger:Error("Failed to read request: %s", Error)
    Client:close()
    return
  end

  if Benchmark then
    Logger:Log("Read request took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
  end
  StartTime = LuaSocket.gettime()

  Headers.OriginalPath = Headers.Path

  local LocalFiles = {
    ["/_YipRuntime.js"] = "Runtime/Runtime.js",
    ["/_YipServiceWorker.js"] = "Runtime/ServiceWorker.js",
  }

  if LocalFiles[Headers.OriginalPath] then
    local Success, FileError = SendFile(Client, LocalFiles[Headers.OriginalPath])
    if not Success then
      Logger:Error("Failed to send file: %s", FileError)
    end
    Client:close()
    return
  end

  local Destination
  Destination, Error = ResolveDestination(Headers)

  if not Destination then
    Logger:Error("%s: %s", Error, Headers.Path)
    SendErrorResponse(Client, "400 Bad Request")
    Client:close()
    return
  end

  Headers.Path, Headers.Host, Headers.Connection = Destination.Path, Destination.Host, "keep-alive"

  local DisplayPath = Headers.OriginalPath
  local DisplayDestinationPath =
    string.format("%s://%s%s [%s]", Destination.Scheme, Destination.Host, Destination.Path, Headers.HttpVersion)

  if DisplayPath:match("^/https?://") then
    DisplayPath = DisplayPath:sub(2)
  end

  if #DisplayPath > 64 then
    DisplayPath = DisplayPath:sub(1, 61) .. "..."
  end

  if #DisplayDestinationPath > 64 then
    DisplayDestinationPath = DisplayDestinationPath:sub(1, 61) .. "..."
  end

  Logger:Log("%s %s -> %s", Headers.Method, DisplayPath, DisplayDestinationPath)

  if Benchmark then
    Logger:Log("Rewrite request took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
  end
  StartTime = LuaSocket.gettime()

  local Backend, Key = GetBackend(Destination)
  if not Backend then
    Logger:Error("%s connection failed: %s", Destination.Host, Key)
    SendErrorResponse(Client, "502 Bad Gateway")
    Client:close()
    return
  end

  if Benchmark then
    Logger:Log("Get backend took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
  end
  StartTime = LuaSocket.gettime()

  local Success
  Success, Error = SendAll(Backend, ReconstructRequest(Headers, Body))

  if not Success then
    Logger:Error("Failed to send request: %s", Error)
    CloseBackend(Backend, Key)
    SendErrorResponse(Client, "502 Bad Gateway")
    Client:close()
    return
  end

  if Benchmark then
    Logger:Log("Send request took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
  end
  StartTime = LuaSocket.gettime()

  local Result, ResponseError, KeepAlive = ForwardResponse(Backend, Client, Headers.Method)

  if not Result then
    Logger:Error("Failed to forward response: %s", ResponseError)
    CloseBackend(Backend, Key)
  elseif not KeepAlive then
    CloseBackend(Backend, Key)
  end

  if Benchmark then
    Logger:Log("Forward response took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
  end

  if Benchmark then
    Logger:Log("Handle client took %.3f ms", (LuaSocket.gettime() - ClientStartTime) * 1000)
  end

  Client:close()
end

local function StartServer()
  local Error

  Server, Error = LuaSocket.tcp4()
  Logger:FatalAssert(Server, Error)

  local Success, Error = Server:setoption("reuseaddr", true)
  Logger:FatalAssert(Success, Error)

  Success, Error = Server:bind("127.0.0.1", ProxyPort)
  Logger:FatalAssert(Success, Error)

  Success, Error = Server:listen()
  Logger:FatalAssert(Success, Error)

  Logger:Log("Server is listening on %s/", ProxyAddress)
end

local function RunServer()
  StartServer()
  Copas.addserver(Server, HandleClient)
  Copas.loop()
end

local ServerTable = {
  HandleClient = HandleClient,
  StartServer = StartServer,
  RunServer = RunServer,
}

for Key, Value in pairs(ServerTable) do
  _G[Key] = Value
end

return ServerTable
