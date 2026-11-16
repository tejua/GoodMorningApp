#!/bin/bash
# Rebuilds "Good Morning.app" on the Desktop from main.swift
set -e
cd "$(dirname "$0")"
APP="$HOME/Desktop/Good Morning.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
pkill -x GoodMorning || true
swiftc -parse-as-library -O main.swift -o "$APP/Contents/MacOS/GoodMorning"
codesign --force --deep -s - "$APP"
open "$APP"
