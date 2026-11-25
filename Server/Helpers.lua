local Brotli = require("compress.brotli")
local Zlib = require("compress.zlib")

local Logger = {}

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
  io.stderr:write("\27[1;37mNycury:\27[0m \27[1;34mInfo:\27[0m " .. string.format(...) .. "\n")
end

function Logger:Error(...)
  io.stdout:flush()
  io.stderr:write("\27[1;37mNycury:\27[0m \27[1;31mError:\27[0m " .. string.format(...) .. "\n")
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
  local Body = {}

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

  local TransferEncoding = (Headers.TransferEncoding or ""):lower()
  local Length = tonumber(Headers.ContentLength)
  if TransferEncoding:find("chunked", 1, true) then
    Body, Error = ReadChunked(Client)
  elseif Length then
    Body, Error = ReadExact(Client, Length)
  end

  if Error then
    return nil, Error
  end

  if type(Body) ~= "string" then
    Body = table.concat(Body)
  end
  return Headers, Body
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

local function ReconstructRequest(Headers, Body)
  local Request = { Headers.Method .. " " .. Headers.Path .. " " .. Headers.HttpVersion .. "\r\n" }
  local Internal = { Method = true, Path = true, HttpVersion = true, OriginalPath = true, ProxyPath = true }

  for Name, Value in pairs(Headers) do
    if not Internal[Name] then
      Request[#Request + 1] = Name:kebabcase() .. ": " .. Value .. "\r\n"
    end
  end

  Request[#Request + 1] = "\r\n"
  Request[#Request + 1] = Body or ""
  return table.concat(Request)
end

local function Decompress(Body, Encoding)
  Encoding = (Encoding or ""):lower()
  if Encoding == "gzip" or Encoding == "deflate" then
    local Format = Encoding == "deflate" and "zlib" or Encoding
    return Zlib.decompress(Body, { format = Format })
  elseif Encoding == "br" then
    return Brotli.decompress(Body)
  elseif Encoding == "" or Encoding == "identity" then
    return Body
  end
  return nil, "Unsupported content encoding: " .. Encoding
end

local function Compress(Body, Encoding, Level)
  Encoding = (Encoding or ""):lower()

  if Encoding == "gzip" or Encoding == "deflate" then
    Level = Level or DefaultZlibCompressionLevel

    local Format = Encoding == "deflate" and "zlib" or Encoding
    return Zlib.compress(Body, {
      format = Format,
      level = Level,
    })
  elseif Encoding == "br" then
    Level = Level or DefaultBrotliCompressionLevel

    return Brotli.compress(Body, {
      quality = Level,
    })
  end
  if Encoding == "" or Encoding == "identity" then
    return Body
  end
  return nil, "Unsupported content encoding: " .. Encoding
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
  if Body:find("_NycuryRuntime.js", 1, true) then
    return Body
  end
  local Result, Count = Body:gsub("(<head[^>]*>)", "%1" .. RuntimeCode, 1)
  return Count == 0 and RuntimeCode .. Body or Result
end

local function RewriteJavaScript(JavaScriptClient, RequestId, Source)
  local Payload = string.char(1) .. Uint32(RequestId) .. Source
  local Message = Uint32(#Payload) .. Payload
  SendAll(JavaScriptClient, Message)

  local Header, Error = JavaScriptClient:receive(4)
  if not Header then
    return nil, Error
  end

  local Length = ReadUint32(Header, 1)
  if Length < 5 or Length > 16 * 1024 * 1024 then
    return nil, "Invalid message size"
  end

  local Response, Error = JavaScriptClient:receive(Length)
  if not Response then
    return nil, Error
  end

  local Type = Response:byte(1)
  local ResponseId = ReadUint32(Response, 2)
  local Result = Response:sub(6)

  if ResponseId ~= RequestId then
    return nil, "Request Id mismatch"
  end
  if Type == 3 then
    return nil, Result
  end

  return Result
end

local function Uint32(Value)
  return string.char(
    bit.band(bit.rshift(Value, 24), 0xFF),
    bit.band(bit.rshift(Value, 16), 0xFF),
    bit.band(bit.rshift(Value, 8), 0xFF),
    bit.band(Value, 0xFF)
  )
end

local function ReadUint32(Data, Offset)
  local A, B, C, D = Data:byte(Offset, Offset + 3)

  return A * 16777216 + B * 65536 + C * 256 + D
end

local Helpers = {
  Logger = Logger,
  SendAll = SendAll,
  SendErrorResponse = SendErrorResponse,
  ReadRequest = ReadRequest,
  GetHostFromUrl = GetHostFromUrl,
  RewriteReferer = RewriteReferer,
  ResolveDestination = ResolveDestination,
  ReconstructRequest = ReconstructRequest,
  Decompress = Decompress,
  Compress = Compress,
  RewriteLocation = RewriteLocation,
  ReconstructResponse = ReconstructResponse,
  InjectRuntime = InjectRuntime,
  RewriteJavaScript = RewriteJavaScript,
  Uint32 = Uint32,
  ReadUint32 = ReadUint32,
}

for Key, Value in pairs(Helpers) do
  _G[Key] = Value
end

return Helpers
