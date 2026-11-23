local LuaSocket = require("socket")
local Copas = require("copas")

local HostConnections, BackendBusy = {}, {}

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
    local Ok, Decoded, DecompressError = pcall(Decompress, Body, Encoding)

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
    elseif not Ok then
      return nil, Decoded
    elseif not Decoded then
      return nil, DecompressError
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

local Forward = {
  ReadExact = ReadExact,
  ReadResponseHeaders = ReadResponseHeaders,
  ReadUntilClose = ReadUntilClose,
  ReadChunked = ReadChunked,
  ForwardExact = ForwardExact,
  ForwardUntilClose = ForwardUntilClose,
  ForwardChunked = ForwardChunked,
  ForwardResponse = ForwardResponse,
  SendFile = SendFile,
  CreateBackend = CreateBackend,
  GetBackend = GetBackend,
  CloseBackend = CloseBackend,
}

for Key, Value in pairs(Forward) do
  _G[Key] = Value
end

return Forward
