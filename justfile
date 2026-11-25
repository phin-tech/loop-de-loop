set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Run the LoupedeckKit and LoopCore tests (headless)
test:
    swift test

# Regenerate LoopDeLoop.xcodeproj from project.yml
gen:
    xcodegen generate --use-cache

# Build the macOS app (Debug)
build: gen
    xcodebuild -project LoopDeLoop.xcodeproj -scheme LoopDeLoop -allowProvisioningUpdates -quiet build

# Build and launch the app
run: build
    -osascript -e 'quit app id "tech.phin.LoopDeLoop"' 2>/dev/null
    open "$(xcodebuild -project LoopDeLoop.xcodeproj -scheme LoopDeLoop -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/LoopDeLoop.app"

# Build Release and install to ~/Applications, linking loopctl into ~/.local/bin
install: gen
    xcodebuild -project LoopDeLoop.xcodeproj -scheme LoopDeLoop -configuration Release -derivedDataPath build/DerivedData -allowProvisioningUpdates -quiet build
    -osascript -e 'quit app id "tech.phin.LoopDeLoop"' 2>/dev/null; sleep 1
    mkdir -p ~/Applications ~/.local/bin
    rm -rf ~/Applications/LoopDeLoop.app
    cp -R build/DerivedData/Build/Products/Release/LoopDeLoop.app ~/Applications/
    ln -sf ~/Applications/LoopDeLoop.app/Contents/Helpers/loopctl ~/.local/bin/loopctl
    @echo "Installed ~/Applications/LoopDeLoop.app and ~/.local/bin/loopctl"

# Build the loopctl command-line tool (release, SwiftPM)
cli:
    swift build -c release --product loopctl

# Direct-to-hardware probe tool (ldl list|info|listen|demo|stress …); quit the app first, it holds the port
ldl *args:
    swift run -c release ldl {{args}}

# Remove build artifacts and the generated Xcode project
clean:
    rm -rf .build build DerivedData Generated LoopDeLoop.xcodeproj

# The release recipes (release-check, doctor, bump, ship and the rest): app-release, in release.just, which
# apple-template keeps up to date
import 'release.just'

# Make the app icon set from square artwork (art/icon-raw.png by default)
icon src="art/icon-raw.png":
    swift scripts/make-icon.swift {{src}}
