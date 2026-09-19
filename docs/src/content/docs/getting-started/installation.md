---
title: Installation
description: Install RayMol on macOS, iPad, and iPhone.
---

The direct macOS build requires macOS 13 or newer on Apple Silicon. The current App Store release requires macOS 14, iOS 17, or iPadOS 17 or newer.

## macOS

### Homebrew (recommended)

The direct build includes the local MCP server and in-app updates:

```sh
brew install --cask javierbq/raymol/raymol
```

### Direct download

Download the latest notarized DMG from [GitHub Releases](https://github.com/javierbq/RayMol/releases/latest). This build also includes MCP support.

### Mac App Store

RayMol is also available from the [App Store](https://apps.apple.com/us/app/raymol/id6781513038). The sandboxed App Store build does not include the local MCP server.

## iPad and iPhone

Install the universal RayMol app from the [App Store](https://apps.apple.com/us/app/raymol/id6781513038). The mobile edition includes the native Metal renderer and touch interface; the local MCP server is a macOS direct-build feature.
