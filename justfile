#https://just.systems/man/en/


# WalkieTalkie iOS development commands
#
# Layout:
#
#   justfile
#   WalkieTalkie/
#     WalkieTalkie.xcodeproj
#     ...
#

set working-directory := "WalkieTalkie"

project := "WalkieTalkie.xcodeproj"
scheme := "WalkieTalkie"
configuration := "Debug"
simulator := "iPhone 17"


# Show available commands
help:
    @just --list


# Open the project in Xcode
open:
    open {{project}}


# Build for the iOS Simulator
build:
    xcodebuild \
        -project {{project}} \
        -scheme {{scheme}} \
        -configuration {{configuration}} \
        -sdk iphonesimulator \
        build


# Build a Release configuration
release:
    xcodebuild \
        -project {{project}} \
        -scheme {{scheme}} \
        -configuration Release \
        -sdk iphonesimulator \
        build


# Run unit/UI tests
test:
    xcodebuild \
        -project {{project}} \
        -scheme {{scheme}} \
        -destination 'platform=iOS Simulator,name={{simulator}}' \
        test


# Clean Xcode build products
clean:
    xcodebuild -project {{project}} -scheme {{scheme}} clean


# Remove DerivedData for this project
clean-derived:
    rm -rf ~/Library/Developer/Xcode/DerivedData/WalkieTalkie-*


# Clean everything
clean-all: clean clean-derived


# List available Xcode schemes
schemes:
    xcodebuild -project {{project}} -list


# List available simulators
simulators:
    xcrun simctl list devices available


# Boot the configured simulator
boot:
    xcrun simctl boot '{{simulator}}' || true
    open -a Simulator


# Shut down all running simulators
shutdown:
    xcrun simctl shutdown all


# Print basic project/build settings
settings:
    xcodebuild \
        -project {{project}} \
        -scheme {{scheme}} \
        -showBuildSettings