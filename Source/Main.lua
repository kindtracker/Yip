local LuaSocket = require("socket")
local Server = assert(LuaSocket.tcp4())

local HostConnections = {}
local Logger = {}

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
  io.stdout:flush()
  io.stderr:write("\27[1;37mYip:\27[0m ")
  io.stderr:write("\27[1;31mFatal Error:\27[0m ")
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
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

function string:split(Pattern)
  Pattern = Pattern or "%s+"
  local Result = {}
  local Start = 1

  for First, Last in self:gmatch("()" .. Pattern .. "()") do
    table.insert(Result, self:sub(Start, First - 1))
    Start = Last
  end

  table.insert(Result, self:sub(Start))
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

local function ReconstructRequest(Headers)
  local Request = {}

  table.insert(Request, Headers.Method .. " " .. Headers.Path .. " " .. Headers.HttpVersion .. "\r\n")

  for Name, Value in pairs(Headers) do
    if
      Name ~= "Method"
      and Name ~= "Path"
      and Name ~= "OriginalPath"
      and Name ~= "ProxyPath"
      and Name ~= "HttpVersion"
    then
      table.insert(Request, Name:kebabcase() .. ": " .. Value .. "\r\n")
    end
  end

  table.insert(Request, "\r\n")
  return table.concat(Request)
end

local function RewriteReferer(Referer)
  if not Referer then
    return nil
  end

  local URL = Referer:match("^https?://[^/]+/(https?://.*)$")

  if not URL then
    return Referer
  end

  return URL
end

local function GetHostFromUrl(Url)
  local Host, Path = Url:match("^https?://([^/]+)(/.*)$")

  if not Host then
    Host = Url:match("^https?://([^/]+)")
    Path = "/"
  end

  return Host, Path
end

local function SendAll(Socket, Data)
  local Index = 1

  while Index <= #Data do
    local Sent, Error, Partial = Socket:send(Data, Index)

    Index = (Sent or Partial or Index - 1) + 1

    if Error then
      return nil, Error
    end
  end

  return true
end

local function ForwardExact(Source, Destination, Count)
  while Count > 0 do
    local Data, Error, Partial = Source:receive(math.min(4096, Count))
    Data = Data or Partial

    if Data and #Data > 0 then
      local Success, SendError = SendAll(Destination, Data)

      if not Success then
        return nil, SendError
      end

      Count = Count - #Data
    end

    if Error then
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

    local Success, SendError = SendAll(Destination, Line .. "\r\n")

    if not Success then
      return nil, SendError
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

        Success, SendError = SendAll(Destination, Trailer .. "\r\n")

        if not Success then
          return nil, SendError
        end

        if Trailer == "" then
          return true
        end
      end
    end

    Success, SendError = ForwardExact(Source, Destination, Size)

    if not Success then
      return nil, SendError
    end

    local CRLF, CRLFError = Source:receive(2)

    if not CRLF then
      return nil, CRLFError
    end

    Success, SendError = SendAll(Destination, CRLF)

    if not Success then
      return nil, SendError
    end
  end
end

local Success, Error = Server:setoption("reuseaddr", true)
Logger:FatalAssert(Success, Error)

Logger:FatalAssert(Server:bind("127.0.0.1", 8000))
Logger:FatalAssert(Server:listen())

Logger:Log("Server is listening on http://localhost:8000/")

while true do
  local Client = assert(Server:accept())

  Logger:Log("Client connected")

  local Headers = {}
  local HeaderText = ""
  local First = true
  while true do
    local Message, Error = Client:receive("*l")

    if not Message then
      Logger:Log("Client disconnected")
      break
    end

    if #Message == 0 then
      break
    end

    if First then
      local Parts = Message:split(" ")
      Headers.Method = Parts[1]
      Headers.Path = Parts[2]
      Headers.HttpVersion = Parts[3]
    end

    local Name, Value = Message:match("^([^:]+):%s*(.*)$")
    if Name then
      Headers[Name:pascalcase()] = Value
    end

    First = false
  end

  Headers.ProxyPath = Headers.Path:sub(2)
  Headers.OriginalPath = Headers.Path
  Headers.Path = Headers.ProxyPath
  Headers.Connection = "keep-alive"

  if Headers.Path:sub(1, 1) ~= "/" then
    Headers.Path = "/" .. Headers.Path
  end

  Logger:PrintTable(Headers)

  local IncomingPath = Headers.Path
  local TargetUrl = IncomingPath:match("^/(https?://.+)$")

  local Host, Path

  if TargetUrl then
    Host, Path = GetHostFromUrl(TargetUrl)
  else
    local RefererUrl = RewriteReferer(Headers.Referer)

    if RefererUrl then
      Host = GetHostFromUrl(RefererUrl)
      Path = IncomingPath
    end
  end

  if not Host then
    Logger:Error("Could not determine destination host from %s", IncomingPath)
    Client:close()
    goto continue
  end

  Headers.Path = Path
  Headers.Host = Host

  local Port = 80
  local Backend

  while true do
    Backend = (HostConnections[Port] or {})[Host]

    if Backend then
      local IP = Backend:getpeername()

      if IP then
        break
      end

      Backend:close()
      HostConnections[Port][Host] = nil
    end

    Backend = Logger:FatalAssert(LuaSocket.tcp4())
    Backend:settimeout(5)

    local Success, Error = Backend:connect(Host, Port)
    if not Success then
      Logger:Error("%s connection failed: %s", Host, Error)
      Backend:close()
      Client:close()
      return
    end

    HostConnections[Port] = HostConnections[Port] or {}
    HostConnections[Port][Host] = Backend

    break
  end

  local HeaderText = ReconstructRequest(Headers)

  local Sent, SendError = Backend:send(HeaderText)
  if not Sent then
    Logger:Error("Failed to send request: %s", SendError)
    Backend:close()
    Client:close()
    return
  end

  local ResponseHeaders = {}
  local First = true

  while true do
    local Line, Error = Backend:receive("*l")

    if not Line then
      Logger:Error("Failed to read response headers: %s", Error)
      break
    end

    if Line == "" then
      break
    end

    if First then
      ResponseHeaders.StatusLine = Line
      First = false
    else
      local Name, Value = Line:match("^([^:]+):%s*(.*)$")

      if Name then
        ResponseHeaders[Name:pascalcase()] = Value
      end
    end
  end

  local Response = {
    ResponseHeaders.StatusLine .. "\r\n",
  }

  for Name, Value in pairs(ResponseHeaders) do
    if Name ~= "StatusLine" then
      table.insert(Response, Name:kebabcase() .. ": " .. Value .. "\r\n")
    end
  end

  table.insert(Response, "\r\n")

  Client:send(table.concat(Response))

  local TransferEncoding = (ResponseHeaders.TransferEncoding or ""):lower()
  local ContentLength = tonumber(ResponseHeaders.ContentLength)

  local Status = tonumber(ResponseHeaders.StatusLine:match("^%S+%s+(%d%d%d)"))

  local HasBody = Headers.Method ~= "HEAD"
    and Status ~= 204
    and Status ~= 304
    and not (Status and Status >= 100 and Status < 200)

  if HasBody then
    if TransferEncoding:match("chunked") then
      local Success, Error = ForwardChunked(Backend, Client)

      if not Success then
        Logger:Error("Failed to forward chunked response: %s", Error)
      end
    elseif ContentLength then
      local Success, Error = ForwardExact(Backend, Client, ContentLength)

      if not Success then
        Logger:Error("Failed to forward response body: %s", Error)
      end
    else
      Logger:Error("Unsupported response body framing")
      Backend:close()
      HostConnections[Port][Host] = nil
    end
  end

  local Ip = Backend:getpeername()
  if not Ip then
    Backend:close()
    HostConnections[Port][Host] = nil
  end

  Client:close()

  ::continue::
end
