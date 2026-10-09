#!/bin/bash

# cd 到 example 目录
cd "$(dirname "$0")/.."

../bin/lua tools/run.lua tools/hotfix.lua "$@"
