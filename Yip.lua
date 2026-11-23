local LuaSocket = require("socket")
local LuaSSL = require("ssl")
local Zlib = require("compress.zlib")
local Brotli = require("compress.brotli")
local Copas = require("copas")

local HostConnections, BackendBusy, Logger = {}, {}, {}
local Server

local RuntimeCode = '<script src="/_yip_runtime.js?_yip=true"></script>'
local ProxyHost, ProxyPort = "localhost", 8000
local ProxyAddress = "http://" .. ProxyHost .. ":" .. ProxyPort

local CompressionFormats = {
  gzip = { format = "gzip" },
  deflate = { format = "zlib" },
}

local Benchmark = false

function Logger:PrintTable(Table, Indent, Seen)
  Indent, Seen = Indent or 0, Seen or {}
  local Prefix = string.rep("  ", Indent)

  if type(Table) ~= "table" then
    print(Prefix .. tostring(Table))
    return
  end

  if Seen[Table] then
    print(Prefix .. "<circular reference>")
    return
  end
  Seen[Table] = true
  print(Prefix .. "{")

  for Key, Value in pairs(Table) do
    io.write(Prefix .. "  [" .. string.format("%q", tostring(Key)) .. "] = ")
    if type(Value) == "table" then
      print()
      self:PrintTable(Value, Indent + 1, Seen)
    else
      print(string.format("%q", tostring(Value)) .. ",")
    end
  end

  print(Prefix .. "}")
  Seen[Table] = nil
end

function Logger:Log(...)
  io.stdout:flush()
  io.stderr:write("\27[1;37mYip:\27[0m \27[1;34mInfo:\27[0m " .. string.format(...) .. "\n")
end

function Logger:Error(...)
  io.stdout:flush()
  io.stderr:write("\27[1;37mYip:\27[0m \27[1;31mError:\27[0m " .. string.format(...) .. "\n")
end

function Logger:FatalError(...)
  self:Error(...)
  os.exit(1)
end

function Logger:Assert(Result, ...)
  if not Result then
    self:Error(...)
  end
  return Result
end

function Logger:FatalAssert(Result, ...)
  if not Result then
    self:FatalError(...)
  end
  return Result
end

function string:pascalcase()
  return self
    :gsub("(%a)([%w]*)", function(A, B)
      return A:upper() .. B:lower()
    end)
    :gsub("[^%w]", "")
end

function string:kebabcase()
  return self
    :gsub("%u", function(C)
      return "-" .. C:lower()
    end)
    :gsub("^-", "")
end

local function SendAll(Socket, Data)
  local Index = 1

  while Index <= #Data do
    local Sent, Error, Partial = Socket:send(Data, Index)
    if Sent then
      Index = Sent + 1
    elseif Partial and Partial >= Index then
      Index = Partial + 1
    else
      return nil, Error
    end
  end

  return true
end

local function SendErrorResponse(Client, Status, Message)
  local Body = Message or Status
  return SendAll(
    Client,
    string.format(
      "HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
      Status,
      #Body,
      Body
    )
  )
end

local function ReadRequest(Client)
  local Headers = {}
  local Line, Error = Client:receive("*l")
  if not Line then
    return nil, Error
  end

  Headers.Method, Headers.Path, Headers.HttpVersion = Line:match("^(%S+)%s+(%S+)%s+(%S+)$")
  if not Headers.Method then
    return nil, "Invalid request line"
  end

  while true do
    Line, Error = Client:receive("*l")
    if not Line then
      return nil, Error
    end
    if Line == "" then
      break
    end

    local Name, Value = Line:match("^([^:]+):%s*(.*)$")
    if Name then
      Headers[Name:pascalcase()] = Value
    end
  end

  return Headers
end

local function GetHostFromUrl(Url)
  local Scheme, Authority, Path = Url:match("^(https?)://([^/%?#]+)(.*)$")
  if not Authority then
    return nil
  end

  local Host, Port
  if Authority:sub(1, 1) == "[" then
    Host, Port = Authority:match("^(%b[]):?(%d*)$")
  else
    Host, Port = Authority:match("^([^:]+):?(%d*)$")
  end

  Path = Path == "" and "/" or Path:sub(1, 1) == "?" and "/" .. Path or Path
  return Scheme:lower(), Host or Authority, Path, tonumber(Port)
end

local function RewriteReferer(Referer)
  return Referer and Referer:match("^https?://[^/]+/(https?://[^#]+)")
end

local function ResolveDestination(Headers)
  local Url = Headers.Path:match("^/(https?://.+)$") or RewriteReferer(Headers.Referer)
  local Scheme, Host, Path, Port

  if Url then
    Scheme, Host, Path, Port = GetHostFromUrl(Url)
    if not Headers.Path:match("^/https?://") then
      Path = Headers.Path
    end
  end

  if not Host then
    return nil, "Could not determine destination host"
  end

  return {
    Scheme = Scheme,
    Host = Host,
    Path = Path,
    Port = Port or (Scheme == "https" and 443 or 80),
  }
end

local function ReconstructRequest(Headers)
  local Request = { Headers.Method .. " " .. Headers.Path .. " " .. Headers.HttpVersion .. "\r\n" }
  local Internal = { Method = true, Path = true, HttpVersion = true, OriginalPath = true, ProxyPath = true }

  for Name, Value in pairs(Headers) do
    if not Internal[Name] then
      Request[#Request + 1] = Name:kebabcase() .. ": " .. Value .. "\r\n"
    end
  end

  Request[#Request + 1] = "\r\n"
  return table.concat(Request)
end

local function Decompress(Body, Encoding)
  Encoding = (Encoding or ""):lower()
  if CompressionFormats[Encoding] then
    return Zlib.decompress(Body, CompressionFormats[Encoding])
  end
  if Encoding == "br" then
    return Brotli.decompress(Body)
  end
  if Encoding == "" or Encoding == "identity" then
    return Body
  end
  return nil, "Unsupported content encoding: " .. Encoding
end

local function Compress(Body, Encoding)
  Encoding = (Encoding or ""):lower()
  if CompressionFormats[Encoding] then
    return Zlib.compress(Body, CompressionFormats[Encoding])
  end
  if Encoding == "br" then
    return Brotli.compress(Body)
  end
  if Encoding == "" or Encoding == "identity" then
    return Body
  end
  return nil, "Unsupported content encoding: " .. Encoding
end

local function CreateBackend(Destination)
  local Socket, Error = LuaSocket.tcp4()
  if not Socket then
    return nil, Error
  end

  local SSLParams
  if Destination.Scheme == "https" then
    SSLParams = {
      wrap = {
        mode = "client",
        protocol = "any",
        verify = "peer",
        options = "all",
        cafile = os.getenv("SSL_CERT_FILE") or "/etc/ssl/certs/ca-certificates.crt",
        capath = os.getenv("SSL_CERT_DIR") or "/etc/ssl/certs",
      },
      sni = { names = Destination.Host },
    }
  end

  local Backend = Copas.wrap(Socket, SSLParams)
  Backend:settimeout(10)

  local Success
  Success, Error = Backend:connect(Destination.Host, Destination.Port)
  if not Success then
    Backend:close()
    return nil, Error
  end

  return Backend
end

local function GetBackend(Destination)
  local Key = string.format("%s://%s:%d", Destination.Scheme, Destination.Host, Destination.Port)
  local Pool = HostConnections[Key] or {}
  HostConnections[Key] = Pool

  for _, Backend in ipairs(Pool) do
    if not BackendBusy[Backend] then
      BackendBusy[Backend] = true
      return Backend, Key
    end
  end

  local Backend, Error = CreateBackend(Destination)
  if not Backend then
    return nil, Error
  end

  Pool[#Pool + 1] = Backend
  BackendBusy[Backend] = true
  return Backend, Key
end

local function CloseBackend(Backend, Key)
  BackendBusy[Backend] = nil
  Backend:close()

  local Pool = HostConnections[Key]
  if not Pool then
    return
  end

  for I = #Pool, 1, -1 do
    if Pool[I] == Backend then
      table.remove(Pool, I)
      break
    end
  end

  if #Pool == 0 then
    HostConnections[Key] = nil
  end
end

local function ReadExact(Source, Count)
  local Buffer = {}

  while Count > 0 do
    local Data, Error, Partial = Source:receive(math.min(16384, Count))
    Data = Data or Partial

    if Data and #Data > 0 then
      Buffer[#Buffer + 1] = Data
      Count = Count - #Data
    end

    if Error and Count > 0 then
      return nil, Error
    end
  end

  return table.concat(Buffer)
end

local function ReadUntilClose(Source)
  local Buffer = {}

  while true do
    local Data, Error, Partial = Source:receive(16384)
    Data = Data or Partial
    if Data and #Data > 0 then
      Buffer[#Buffer + 1] = Data
    end

    if Error then
      if Error == "closed" then
        return table.concat(Buffer)
      end
      return nil, Error
    end
  end
end

local function ReadChunked(Source)
  local Buffer = {}

  while true do
    local Line, Error = Source:receive("*l")
    if not Line then
      return nil, Error
    end

    local HexSize = Line:match("^%s*([%da-fA-F]+)")
    local Size = HexSize and tonumber(HexSize, 16)
    if not Size then
      return nil, "Invalid chunk size"
    end

    if Size == 0 then
      repeat
        Line, Error = Source:receive("*l")
        if not Line then
          return nil, Error
        end
      until Line == ""
      return table.concat(Buffer)
    end

    local Data
    Data, Error = ReadExact(Source, Size)
    if not Data then
      return nil, Error
    end
    Buffer[#Buffer + 1] = Data

    local CRLF
    CRLF, Error = Source:receive(2)
    if not CRLF then
      return nil, Error
    end
    if CRLF ~= "\r\n" then
      return nil, "Invalid chunk delimiter"
    end
  end
end

local function ForwardExact(Source, Count, Destination)
  while Count > 0 do
    local Data, Error, Partial = Source:receive(math.min(16384, Count))
    Data = Data or Partial

    if Data and #Data > 0 then
      local Success
      Success, Error = SendAll(Destination, Data)
      if not Success then
        return nil, Error
      end

      Count = Count - #Data
    end

    if Error and Count > 0 then
      return nil, Error
    end
  end

  return true
end

local function ForwardUntilClose(Source, Destination)
  while true do
    local Data, Error, Partial = Source:receive(16384)
    Data = Data or Partial

    if Error or Data == nil then
      if Error == "closed" then
        return true
      end
      return nil, Error
    end

    local Success
    Success, Error = SendAll(Destination, Data)
    if not Success then
      return nil, Error
    end
  end

  return true
end

local function ForwardChunked(Source, Destination)
  while true do
    local Line, Error = Source:receive("*l")
    if not Line then
      return nil, Error
    end

    local Size = tonumber(Line:match("^%s*([%da-fA-F]+)"), 16)
    if not Size then
      return nil, "Invalid chunk size"
    end

    local Success
    Success, Error = SendAll(Destination, Line .. "\r\n")
    if not Success then
      return nil, Error
    end

    if Size == 0 then
      repeat
        Line, Error = Source:receive("*l")
        if not Line then
          return nil, Error
        end

        Success, Error = SendAll(Destination, Line .. "\r\n")
        if not Success then
          return nil, Error
        end
      until Line == ""

      return true
    end

    Success, Error = ForwardExact(Source, Size, Destination)
    if not Success then
      return nil, Error
    end

    local CRLF
    CRLF, Error = Source:receive(2)
    if not CRLF then
      return nil, Error
    end
    if CRLF ~= "\r\n" then
      return nil, "Invalid chunk delimiter"
    end

    Success, Error = SendAll(Destination, CRLF)
    if not Success then
      return nil, Error
    end
  end
end

local function ReadResponseHeaders(Backend)
  local Headers = {}
  local Line, Error = Backend:receive("*l")
  if not Line then
    return nil, Error
  end

  local Version, Status, Message = Line:match("^(%S+)%s+(%d%d%d)%s*(.*)$")
  if not Status then
    return nil, "Invalid response status line"
  end

  Headers.StatusLine, Headers.Status = Line, tonumber(Status)
  Headers.HttpVersion, Headers.StatusMessage = Version, Message

  while true do
    Line, Error = Backend:receive("*l")
    if not Line then
      return nil, Error
    end
    if Line == "" then
      break
    end

    local Name, Value = Line:match("^([^:]+):%s*(.*)$")
    if Name then
      Headers[Name:pascalcase()] = Value
    end
  end

  return Headers
end

local function RewriteUrl(Url)
  return Url:gsub("^(https?://.+)$", ProxyAddress .. "/%1")
end

local function RewriteLocation(Headers)
  if Headers.Location then
    Headers.Location = RewriteUrl(Headers.Location)
  end
end

local function ReconstructResponse(Headers)
  local Response = { Headers.StatusLine .. "\r\n" }
  local Internal = { StatusLine = true, Status = true, HttpVersion = true, StatusMessage = true }

  for Name, Value in pairs(Headers) do
    if not Internal[Name] then
      Response[#Response + 1] = Name:kebabcase() .. ": " .. Value .. "\r\n"
    end
  end

  Response[#Response + 1] = "\r\n"
  return table.concat(Response)
end

local function InjectRuntime(Body)
  if Body:find("_yip_runtime.js", 1, true) then
    return Body
  end
  local Result, Count = Body:gsub("(<head[^>]*>)", "%1" .. RuntimeCode, 1)
  return Count == 0 and RuntimeCode .. Body or Result
end

local function ForwardResponse(Backend, Client, Method)
  local StartTime = 0

  StartTime = LuaSocket.gettime()

  local Headers, Error = ReadResponseHeaders(Backend)
  if not Headers then
    return nil, Error
  end

  Headers.AccessControlAllowOrigin = "*"

  local Status = Headers.Status
  local HasBody = Method ~= "HEAD" and Status ~= 204 and Status ~= 304 and not (Status >= 100 and Status < 200)

  if Benchmark then
    Logger:Log("Read and parse response header took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
  end
  StartTime = LuaSocket.gettime()

  local Connection = (Headers.Connection or ""):lower()
  local KeepAlive = not Connection:find("close", 1, true)
    and (Headers.HttpVersion ~= "HTTP/1.0" or Connection:find("keep-alive", 1, true))
  if not HasBody then
    StartTime = LuaSocket.gettime()
    RewriteLocation(Headers)
    local Success
    Success, Error = SendAll(Client, ReconstructResponse(Headers))

    if Benchmark then
      Logger:Log("Send header took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
    end
    return Success, Error, KeepAlive
  end

  local TransferEncoding = (Headers.TransferEncoding or ""):lower()
  local Length = tonumber(Headers.ContentLength)
  local IsHTML = (Headers.ContentType or ""):lower():find("text/html", 1, true) and Status ~= 206

  if IsHTML then
    StartTime = LuaSocket.gettime()

    local Body

    if TransferEncoding:find("chunked", 1, true) then
      Body, Error = ReadChunked(Backend)
    elseif Length then
      Body, Error = ReadExact(Backend, Length)
    else
      Body, Error = ReadUntilClose(Backend)
      KeepAlive = false
    end

    if not Body then
      return nil, Error
    end

    if Benchmark then
      Logger:Log("Read response took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
    end
    StartTime = LuaSocket.gettime()

    local Encoding = Headers.ContentEncoding or "identity"
    local Ok, Decoded = pcall(Decompress, Body, Encoding)

    if Benchmark then
      Logger:Log("Decompress response and inject runtime took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
    end

    StartTime = LuaSocket.gettime()
    if Ok and Decoded then
      local Modified = InjectRuntime(Decoded)
      local CompressOk, Compressed = pcall(Compress, Modified, Encoding)

      if CompressOk and Compressed then
        Body = Compressed
        Headers.ETag, Headers.ContentMd5 = nil, nil
      end

      if Benchmark then
        Logger:Log("Compress response and inject runtime took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
      end
    else
      return nil, Ok
    end

    StartTime = LuaSocket.gettime()

    Headers.TransferEncoding = nil
    Headers.ContentLength = tostring(#Body)

    RewriteLocation(Headers)

    local Success
    Success, Error = SendAll(Client, ReconstructResponse(Headers))
    if not Success then
      return nil, Error
    end

    Success, Error = SendAll(Client, Body)

    if Benchmark then
      Logger:Log("Send forward response took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
    end

    return Success, Error, KeepAlive
  end

  StartTime = LuaSocket.gettime()

  RewriteLocation(Headers)

  local Success
  Success, Error = SendAll(Client, ReconstructResponse(Headers))
  if not Success then
    return nil, Error
  end

  if TransferEncoding:find("chunked", 1, true) then
    Success, Error = ForwardChunked(Backend, Client)
  elseif Length then
    Success, Error = ForwardExact(Backend, Length, Client)
  else
    Success, Error = ForwardUntilClose(Backend, Client)
    KeepAlive = false
  end

  if Benchmark then
    Logger:Log("Send forward response took %.3f ms", (LuaSocket.gettime() - StartTime) * 1000)
  end

  return Success, Error, KeepAlive
end

local function SendFile(Client, File)
  local FilePtr, Error = io.open(File, "rb")
  if not FilePtr then
    return SendErrorResponse(Client, "500 Internal Server Error", Error)
  end

  local Content = FilePtr:read("*a")
  FilePtr:close()

  return SendAll(
    Client,
    string.format(
      "HTTP/1.1 200 OK\r\nContent-Type: text/javascript; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
      #Content,
      Content
    )
  )
end

local function HandleClient(Client)
  local ClientStartTime = LuaSocket.gettime()
  local StartTime = 0

  Client = Copas.wrap(Client)
  Client:settimeout(10)

  StartTime = LuaSocket.gettime()

  local Headers, Error = ReadRequest(Client)
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
    ["/_yip_runtime.js?_yip=true"] = "Runtime/Runtime.js",
    ["/_yip_service_worker.js?_yip=true"] = "Runtime/ServiceWorker.js",
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

  if tonumber(Headers.ContentLength or "0") > 0 or Headers.TransferEncoding then
    SendErrorResponse(Client, "501 Not Implemented", "Request bodies are not supported yet.")
    Client:close()
    return
  end

  local DisplayPath = Headers.OriginalPath
  if DisplayPath:match("^/https?://") then
    DisplayPath = DisplayPath:sub(2)
  end

  Logger:Log(
    "%s %s -> %s://%s%s [%s]",
    Headers.Method,
    DisplayPath,
    Destination.Scheme,
    Destination.Host,
    Destination.Path,
    Headers.HttpVersion
  )

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
  Success, Error = SendAll(Backend, ReconstructRequest(Headers))

  if not Success then
    Logger:Error("Failed to send request: %s", Error)
    CloseBackend(Destination, Key)
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
    CloseBackend(Destination, Key)
  elseif not KeepAlive then
    CloseBackend(Destination, Key)
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

RunServer()
