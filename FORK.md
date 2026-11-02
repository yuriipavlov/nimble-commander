# About this fork

A community continuation of [Nimble Commander](https://github.com/mikekazakov/nimble-commander). The original author can no longer maintain it and [welcomed forks](https://github.com/mikekazakov/nimble-commander/discussions/756). This fork is not affiliated with the original author.

Nimble Commander is a great file manager and it deserves to keep growing. We are not abandoning it: development goes on here, and we plan to build a community around it, including a Slack or Discord channel. Everyone is welcome to join in, whether you write code, report bugs, test, translate, improve the docs or tell others about the project.

## Building

There are no signed builds. Build the app yourself with Xcode 27.2 and the `NimbleCommander-Unsigned` scheme, see [Docs/Building.md](Docs/Building.md).
macOS may block an unsigned build on first launch: open it once, then allow it in System Settings > Privacy & Security ("Open Anyway").
Features that need a signed binary, such as Admin Mode, do not work in unsigned builds.

## Contributing

Any participation is welcome. Send pull requests to this repository. [CONTRIBUTING.md](CONTRIBUTING.md) is inherited from the original project and refers to its issue tracker and forum.

## Syncing with the original repository

```bash
git remote add mikekazakov https://github.com/mikekazakov/nimble-commander
git fetch mikekazakov
git merge mikekazakov/main
```

## License

GPLv3, see [LICENSE.md](LICENSE.md). Copyright (C) 2013-2026 Michael Kazakov.
