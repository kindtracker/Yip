local LuaSocket = require("socket")
local Server = assert(LuaSocket.tcp4())

local Success, Error = Server:setoption("reuseaddr", true)
assert(Success, Error)

assert(Server:bind("127.0.0.1", 8000))
assert(Server:listen())

print("Server is listening on http://localhost:8000/")

while true do
	local Client = assert(Server:accept())

	print("Client connected")

	local Headers = {}
	while true do
		local Message, Error = Client:receive("*l")

		if not Message then
			print("Client disconnected")
			break
		end

		if #Message == 0 then
			Headers = table.concat(Headers, "\n")
			print(Headers)
		else
			table.insert(Headers, Message)
		end
	end

	Client:close()
end
