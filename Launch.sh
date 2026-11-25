#!/bin/sh

node Server/JavaScript/Main.js &
sleep 0.5 # Lua is too fast for anode.js

if command -v luajit >/dev/null 2>&1; then
  luajit -O2 Server/Main.lua
else
  lua Server/Main.lua
fi
