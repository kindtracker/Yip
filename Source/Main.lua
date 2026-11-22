local LuaSocket = require("socket")
local Server = assert(LuaSocket.tcp4())

local Clients = {}
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

      if Headers.Path:sub(-1) == "/" then
        Headers.Path = Headers.Path .. "index.html"
      end
    end

    local Parts = Message:split(": ")
    if Parts[1] and Parts[2] then
      Headers[Parts[1]:pascalcase()] = Parts[2]
    end

    First = false
  end

  Headers.ProxyPath = Headers.Path:sub(2)
  Headers.OriginalPath = Headers.Path
  Headers.Path = Headers.ProxyPath
  Headers.Connection = "close"

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

  Headers.OriginalPath = IncomingPath
  Headers.Path = Path
  Headers.Host = Host
  Headers.Connection = "close"

  local Backend = Logger:FatalAssert(LuaSocket.tcp4())
  Backend:settimeout(5)

  local Success, Error = Backend:connect(Host, 80)
  if not Success then
    Logger:Error("%s connection failed: %s", Host, Error)
    Client:close()
    return
  end

  local HeaderText = ReconstructRequest(Headers)

  local Sent, SendError = Backend:send(HeaderText)
  if not Sent then
    Logger:Error("Failed to send request: %s", SendError)
    Backend:close()
    Client:close()
    return
  end

  while true do
    local Data, Error, Partial = Backend:receive("*a")
    Data = Data or Partial

    if Data and #Data > 0 then
      local Sent, SendError = Client:send(Data)

      if not Sent then
        Logger:Error("Client send failed: %s", SendError)
        break
      end
    end

    if Error then
      break
    end
  end

  Backend:close()
  Client:close()

  ::continue::
end
