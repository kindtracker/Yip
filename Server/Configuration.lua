local Configuration = {
  ProxyHost = "localhost",
  ProxyPort = 8000,
  DefaultZlibCompressionLevel = 5,
  DefaultBrotliCompressionLevel = 6,
  RuntimeCode = '<script src="/_NycuryRuntime.js"></script>',
  Benchmark = false,
}

Configuration.ProxyAddress = "http://" .. Configuration.ProxyHost .. ":" .. Configuration.ProxyPort

for Key, Value in pairs(Configuration) do
  _G[Key] = Value
end

return Configuration
