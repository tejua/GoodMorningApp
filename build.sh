#!/bin/bash
# Rebuilds "Good Morning.app" on the Desktop from main.swift
set -e
cd "$(dirname "$0")"
APP="$HOME/Desktop/Good Morning.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
pkill -x GoodMorning || true
swiftc -parse-as-library -O -target "$(uname -m)-apple-macos15.0" main.swift AvatarView.swift Corrector.swift -Xlinker -weak_framework -Xlinker FoundationModels -o "$APP/Contents/MacOS/GoodMorning"
codesign --force --deep -s - --identifier com.teju.goodmorning "$APP"
open "$APP"
