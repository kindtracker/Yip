local Configuration = {
  ProxyHost = "localhost",
  ProxyPort = 8000,
  DefaultZlibCompressionLevel = 5,
  DefaultBrotliCompressionLevel = 6,
  RuntimeCode = '<script src="/_YipRuntime.js"></script>',
  Benchmark = false,
}

Configuration.ProxyAddress = "http://" .. Configuration.ProxyHost .. ":" .. Configuration.ProxyPort

return Configuration
