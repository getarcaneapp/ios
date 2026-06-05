<div align="center">

  <img src=".github/assets/img/PNG-3.png" alt="Arcane Logo" width="500" />
  <p>Arcane Mobile — Manage your Docker hosts from iOS.</p>

<a href="https://github.com/getarcaneapp/ios/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-BSD--3--Clause-blue.svg" alt="License"></a>
<a href="https://discord.gg/WyXYpdyV3Z"><img src="https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white" alt="Discord"></a>

<br />

</div>

## About

Arcane Mobile is the official iOS companion for [Arcane](https://github.com/getarcaneapp/arcane). It connects to any Arcane manager or agent and lets you browse and operate your Docker environments — containers, images, volumes, networks, and Compose projects — from your phone.

## Documentation

For setup instructions, configuration details, and development guides, visit the **[official documentation site](https://getarcane.app)**.

## Requirements

- iOS 18 or later (the Liquid Glass interface is used on iOS 26+; iOS 18 falls back to materials)
- An Arcane server reachable over HTTPS

## Building

This is a SwiftUI app targeting iOS 18+ in Swift 6 strict-concurrency mode. On iOS 26 and later it adopts Liquid Glass; on iOS 18 those surfaces fall back to materials via the helpers in `Arcane Mobile/Extensions/GlassCompat.swift`.

```sh
open "Arcane Mobile.xcodeproj"
```

The project depends on [`libarcane-swift`](https://github.com/getarcaneapp/libarcane-swift) via Swift Package Manager and resolves its packages automatically on first build.

## Reporting Issues

Found a bug or have a feature request? [Open an issue on GitHub](https://github.com/getarcaneapp/ios/issues).

## Translating

Help translate Arcane on Crowdin: https://crowdin.com/project/arcane-docker-management

Thank you for checking out Arcane Mobile! Your feedback and contributions are always welcome.
