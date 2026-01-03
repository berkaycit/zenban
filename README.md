# Zenban

A macOS application built with SwiftUI.

## Requirements

- macOS 15.6+
- Xcode 26.2+
- Swift 5.0+
- Zig (for building libghostty): `brew install zig`

## Building from Source

```bash
git clone https://github.com/berkaycit/zenban.git
cd zenban

# Build libghostty (universal arm64 + x86_64)
./scripts/build-libghostty.sh

# Open in Xcode and build
open zenban.xcodeproj
```

To rebuild libghostty at a specific commit:
```bash
./scripts/build-libghostty.sh <commit-sha>
```

## Bundle Identifier

`com.berkaycit.zenban`
