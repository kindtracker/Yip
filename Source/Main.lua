local LuaSocket = require("socket")
local LuaSSL = require("ssl")
local Zlib = require("compress.zlib")
local Brotli = require("compress.brotli")

local Server = assert(LuaSocket.tcp4())

local HostConnections = {}
local Logger = {}

local RuntimeCode = '<script src="/_yip_runtime.js?_yip=true"></script>'
local ProxyHost = "localhost"
local ProxyPort = 8000
local ProxyAddress = "http://" .. ProxyHost .. ":" .. ProxyPort

function Logger:PrintTable(Table, Indent, Seen)
  Indent = Indent or 0
  Seen = Seen or {}

  if type(Table) ~= "table" then
    print(string.rep("  ", Indent) .. tostring(Table))
    return
  end

  if Seen[Table] then
    print(string.rep("  ", Indent) .. "<circular reference>")
    return
  end

  Seen[Table] = true

  local Prefix = string.rep("  ", Indent)

  print(Prefix .. "{")

  for Key, Value in pairs(Table) do
    io.write(Prefix .. "  [" .. string.format("%q", Key) .. "] = ")

    if type(Value) == "table" then
      print()
      Logger:PrintTable(Value, Indent + 1, Seen)
    else
      print(string.format("%q", Value) .. ",")
    end
  end

  print(Prefix .. "}")

  Seen[Table] = nil
end

function Logger:Log(...)
  io.stdout:flush()
  io.stderr:write("\27[1;37mYip:\27[0m ")
  io.stderr:write("\27[1;34mInfo:\27[0m ")
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
end

function Logger:Error(...)
  io.stdout:flush()
  io.stderr:write("\27[1;37mYip:\27[0m ")
  io.stderr:write("\27[1;31mError:\27[0m ")
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
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
    :gsub("(%a)([%w]*)", function(First, Rest)
      return First:upper() .. Rest:lower()
    end)
    :gsub("[^%w]", "")
end

function string:kebabcase()
  return self
    :gsub("%u", function(Character)
      return "-" .. Character:lower()
    end)
    :gsub("^-", "")
end

local function SendAll(Socket, Data)
  local Index = 1

  while Index <= #Data do
    local Sent, Error, Partial = Socket:send(Data, Index)

    Index = (Sent or Partial or (Index - 1)) + 1

    if not Sent and Index == 1 then
      return nil, Error
    end
  end

  return true
end

local function SendErrorResponse(Client, Status, Message)
  local Body = Message or Status

  local Response = string.format(
    "HTTP/1.1 %s\r\n"
      .. "Content-Type: text/plain\r\n"
      .. "Content-Length: %d\r\n"
      .. "Connection: close\r\n"
      .. "\r\n%s",
    Status,
    #Body,
    Body
  )

  SendAll(Client, Response)
end

local function ReadRequest(Client)
  local Headers = {}

  local Line, Error = Client:receive("*l")

  if not Line then
    return nil, Error
  end

  local Method, Path, Version = Line:match("^(%S+)%s+(%S+)%s+(%S+)$")

  if not Method then
    return nil, "Invalid request line"
  end

  Headers.Method = Method
  Headers.Path = Path
  Headers.HttpVersion = Version

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
  local Scheme, Host, Path = Url:match("^(https?)://([^/%?#]+)(.*)$")

  if not Host then
    return nil
  end

  if Path == "" then
    Path = "/"
  elseif Path:sub(1, 1) == "?" then
    Path = "/" .. Path
  end

  return Scheme:lower(), Host, Path
end

local function RewriteReferer(Referer)
  if not Referer then
    return nil
  end

  return Referer:match("^https?://[^/]+/(https?://[^#]+)")
end

local function ResolveDestination(Headers)
  local IncomingPath = Headers.Path
  local TargetUrl = IncomingPath:match("^/(https?://.+)$")

  local Scheme, Host, Path

  if TargetUrl then
    Scheme, Host, Path = GetHostFromUrl(TargetUrl)
  else
    local RefererUrl = RewriteReferer(Headers.Referer)

    if RefererUrl then
      Scheme, Host = GetHostFromUrl(RefererUrl)
      Path = IncomingPath
    end
  end

  if not Host then
    return nil, "Could not determine destination host"
  end

  return {
    Scheme = Scheme,
    Host = Host,
    Path = Path,
    Port = Scheme == "https" and 443 or 80,
  }
end

local function ReconstructRequest(Headers)
  local Request = {}

  table.insert(Request, Headers.Method .. " " .. Headers.Path .. " " .. Headers.HttpVersion .. "\r\n")

  local InternalHeaders = {
    Method = true,
    Path = true,
    HttpVersion = true,
    OriginalPath = true,
    ProxyPath = true,
  }

  for Name, Value in pairs(Headers) do
    if not InternalHeaders[Name] then
      table.insert(Request, Name:kebabcase() .. ": " .. Value .. "\r\n")
    end
  end

  table.insert(Request, "\r\n")

  return table.concat(Request)
end

local function Decompress(Body, Encoding)
  Encoding = (Encoding or ""):lower()

  if Encoding == "gzip" then
    return Zlib.decompress(Body, { format = "gzip" })
  elseif Encoding == "deflate" then
    return Zlib.decompress(Body, { format = "zlib" })
  elseif Encoding == "br" then
    return Brotli.decompress(Body)
  elseif Encoding == "" or Encoding == "identity" then
    return Body
  end

  return nil, "Unsupported content encoding: " .. Encoding
end

local function Compress(Body, Encoding)
  Encoding = (Encoding or ""):lower()

  if Encoding == "gzip" then
    return Zlib.compress(Body, { format = "gzip" })
  elseif Encoding == "deflate" then
    return Zlib.compress(Body, { format = "zlib" })
  elseif Encoding == "br" then
    return Brotli.compress(Body)
  elseif Encoding == "" or Encoding == "identity" then
    return Body
  end

  return nil, "Unsupported content encoding: " .. Encoding
end

local function CreateBackend(Destination)
  local Backend, Error = LuaSocket.tcp4()

  if not Backend then
    return nil, Error
  end

  Backend:settimeout(10)

  local Success
  Success, Error = Backend:connect(Destination.Host, Destination.Port)

  if not Success then
    Backend:close()
    return nil, Error
  end

  if Destination.Scheme == "https" then
    local TLSBackend

    TLSBackend, Error = LuaSSL.wrap(Backend, {
      mode = "client",
      protocol = "any",
      verify = "peer",
      options = "all",
      cafile = os.getenv("SSL_CERT_FILE") or "/etc/ssl/certs/ca-certificates.crt",
      capath = os.getenv("SSL_CERT_DIR") or "/etc/ssl/certs",
    })

    if not TLSBackend then
      Backend:close()
      return nil, Error
    end

    TLSBackend:settimeout(10)
    TLSBackend:sni(Destination.Host)

    Success, Error = TLSBackend:dohandshake()

    if not Success then
      TLSBackend:close()
      return nil, Error
    end

    Backend = TLSBackend
  end

  return Backend
end

local function GetBackend(Destination, Client)
  local Key = Destination.Scheme .. "://" .. Destination.Host .. ":" .. Destination.Port

  local Backend = HostConnections[Key]

  if Backend then
    local Data, Error = Client:settimeout(0.0001)

    if not Error then
      return Backend, Key
    end

    Backend:close()
    HostConnections[Key] = nil
  end

  local Error

  Backend, Error = CreateBackend(Destination)

  if not Backend then
    return nil, Error
  end

  HostConnections[Key] = Backend

  return Backend, Key
end

local function CloseBackend(Key)
  local Backend = HostConnections[Key]

  if Backend then
    Backend:close()
    HostConnections[Key] = nil
  end
end

local function ReadExact(Source, Count)
  local Buffer = {}

  while Count > 0 do
    local Data, Error, Partial = Source:receive(math.min(4096, Count))
    Data = Data or Partial

    if Data and #Data > 0 then
      Buffer[#Buffer + 1] = Data
      Count = Count - #Data
    end

    if Error then
      return nil, Error
    end
  end

  return table.concat(Buffer)
end

local function ReadUntilClose(Source)
  local Buffer = {}

  while true do
    local Data, Error, Partial = Source:receive(4096)
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
      while true do
        local Trailer, TrailerError = Source:receive("*l")

        if not Trailer then
          return nil, TrailerError
        end

        if Trailer == "" then
          return table.concat(Buffer)
        end
      end
    end

    local Data, DataError = ReadExact(Source, Size)

    if not Data then
      return nil, DataError
    end

    Buffer[#Buffer + 1] = Data

    local CRLF, CRLFError = Source:receive(2)

    if not CRLF then
      return nil, CRLFError
    end

    if CRLF ~= "\r\n" then
      return nil, "Invalid chunk delimiter"
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

  Headers.StatusLine = Line
  Headers.Status = tonumber(Status)
  Headers.HttpVersion = Version
  Headers.StatusMessage = Message

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
  if not Headers.Location then
    return
  end

  Headers.Location = RewriteUrl(Headers.Location)
end

local function ReconstructResponse(Headers)
  local Response = {
    Headers.StatusLine .. "\r\n",
  }

  local InternalHeaders = {
    StatusLine = true,
    Status = true,
    HttpVersion = true,
    StatusMessage = true,
  }

  for Name, Value in pairs(Headers) do
    if not InternalHeaders[Name] then
      table.insert(Response, Name:kebabcase() .. ": " .. Value .. "\r\n")
    end
  end

  table.insert(Response, "\r\n")

  return table.concat(Response)
end

local function InjectRuntime(Body)
  if Body:find("Runtime.js", 1, true) then
    return Body
  end

  local Result, Count = Body:gsub("(<head[^>]*>)", "%1" .. RuntimeCode, 1)
  if Count == 0 then
    Result = RuntimeCode .. Body
  end

  return Result
end

local function ForwardResponse(Backend, Client, Method)
  local Headers, Error = ReadResponseHeaders(Backend)
  if not Headers then
    return nil, Error
  end

  Headers.AccessControlAllowOrigin = "*"

  local Status = Headers.Status
  local HasBody = Method ~= "HEAD" and Status ~= 204 and Status ~= 304 and not (Status >= 100 and Status < 200)

  if not HasBody then
    RewriteLocation(Headers)

    local Response = ReconstructResponse(Headers)
    return SendAll(Client, Response)
  end

  local TransferEncoding = (Headers.TransferEncoding or ""):lower()
  local ContentLength = tonumber(Headers.ContentLength)

  local Body

  if TransferEncoding:match("chunked") then
    Body, Error = ReadChunked(Backend)
  elseif ContentLength then
    Body, Error = ReadExact(Backend, ContentLength)
  else
    Body, Error = ReadUntilClose(Backend)

    Headers.Connection = "close"
  end

  if not Body then
    return nil, Error
  end

  local ContentType = (Headers.ContentType or ""):lower()
  local IsHTML = ContentType:find("text/html", 1, true) ~= nil

  if IsHTML and Status ~= 206 then
    local Encoding = Headers.ContentEncoding or "identity"

    local Ok, Decompressed = pcall(Decompress, Body, Encoding)

    if Ok and Decompressed then
      local Modified = InjectRuntime(Decompressed)

      local CompressOk, Compressed = pcall(Compress, Modified, Encoding)

      if CompressOk and Compressed then
        Body = Compressed
        Headers.ETag = nil
        Headers.ContentMd5 = nil
      end
    end
  end

  Headers.TransferEncoding = nil
  Headers.ContentLength = tostring(#Body)

  RewriteLocation(Headers)

  local Response = ReconstructResponse(Headers)
  local Success
  Success, Error = SendAll(Client, Response)

  if not Success then
    return nil, Error
  end

  return SendAll(Client, Body)
end

local function SendFile(Client, File)
  local FilePtr, Error = io.open(File, "rb")
  if not FilePtr then
    return SendErrorResponse(Client, "500 Internal Server Error", Error)
  end

  local FileContent = FilePtr:read("*a")
  FilePtr:close()

  local Response = string.format(
    "HTTP/1.1 200 OK\r\n"
      .. "Content-Type: text/javascript; charset=utf-8\r\n"
      .. "Content-Length: %d\r\n"
      .. "Connection: close\r\n"
      .. "\r\n%s",
    #FileContent,
    FileContent
  )

  return SendAll(Client, Response)
end

local function HandleClient(Client)
  Client:settimeout(10)

  local Headers, Error = ReadRequest(Client)

  if not Headers then
    Logger:Error("Failed to read request: %s", Error)
    Client:close()
    return
  end

  Headers.OriginalPath = Headers.Path

  if Headers.OriginalPath == "/_yip_runtime.js?_yip=true" then
    local _, Error = SendFile(Client, "Runtime/Runtime.js")
    if Error then
      Logger:Error("Failed to send runtime: %s", Error)
    end

    Client:close()
    return
  elseif Headers.OriginalPath == "/_yip_service_worker.js?_yip=true" then
    local _, Error = SendFile(Client, "Runtime/ServiceWorker.js")
    if Error then
      Logger:Error("Failed to send service worker: %s", Error)
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

  Headers.Path = Destination.Path
  Headers.Host = Destination.Host
  Headers.Connection = "keep-alive"

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

  local Backend, Key = GetBackend(Destination, Client)

  if not Backend then
    Logger:Error("%s connection failed: %s", Destination.Host, Key)

    SendErrorResponse(Client, "502 Bad Gateway")
    Client:close()
    return
  end

  local Request = ReconstructRequest(Headers)

  local Success
  Success, Error = SendAll(Backend, Request)

  if not Success then
    Logger:Error("Failed to send request: %s", Error)
    CloseBackend(Key)
    SendErrorResponse(Client, "502 Bad Gateway")
    Client:close()
    return
  end

  local ResponseResult, ResponseError = ForwardResponse(Backend, Client, Headers.Method)

  if not ResponseResult then
    Logger:Error("Failed to forward response: %s", ResponseError)
    CloseBackend(Key)
  elseif ResponseError == "close" then
    CloseBackend(Key)
  end

  Client:close()
end

local function StartServer()
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

  while true do
    local Client, Error = Server:accept()

    if Client then
      HandleClient(Client)
    else
      Logger:Error("Failed to accept client: %s", Error)
    end
  end
end

RunServer()
