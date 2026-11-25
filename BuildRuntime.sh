npx esbuild \
  Runtime/Bundle.js \
  --bundle \
  --format=iife \
  --target=es2020 \
  --outfile=Runtime/Runtime.min.js

npx esbuild \
  --format=iife \
  --target=es2020 \
  Runtime/ServiceWorker.js \
  --outfile=Runtime/ServiceWorker.min.js
