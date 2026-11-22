local LuaSocket = require("socket")
local Server = assert(LuaSocket.tcp())

assert(Server:bind("127.0.0.1", 8000))
assert(Server:listen())

print("Server is listening on port 8000")

while true do
	local Client = Server:accept()

	print("Client connected!")
end
