#!/bin/bash

# cd 到当前脚本目录的上层目录
cd "$(dirname "$0")/.."

python tools/dist.py
