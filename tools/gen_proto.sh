#!/bin/bash

# cd 到当前脚本目录的上层目录
cd "$(dirname "$0")/.."

mkdir -p ../build/proto
./bin/lua tools/run.lua tools/proto2spb.lua proto/*.sproto proto/*/*.sproto
