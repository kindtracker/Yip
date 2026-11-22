local LuaSocket = require("socket")
local Server = assert(LuaSocket.tcp4())

local Logger = {}

function Logger:Log(...)
	io.stdout:flush()
	io.stderr:write("\27[1;37mYip:\27[0m ")
	io.stderr:write("\27[34mInfo:\27[0m ")
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
	return self:gsub("(%a)([%w]*)", function(First, Rest)
		return First:upper() .. Rest:lower()
	end):gsub("[^%w]", "")
end

local Success, Error = Server:setoption("reuseaddr", true)
assert(Success, Error)

assert(Server:bind("127.0.0.1", 8000))
assert(Server:listen())

print("Server is listening on http://localhost:8000/")

while true do
	local Client = assert(Server:accept())

	Logger:Log("Client connected")

	local Headers = {}
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

	Logger:PrintTable(Headers)

	Client:close()
end
