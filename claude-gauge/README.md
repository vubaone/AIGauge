# ClaudeGauge (CLI)

A small command-line tool that reports your Claude app usage as JSON. It's the
Claude backend for [AIGauge](../README.md), which bundles it to drive the
menu-bar meter.

## Attribution

This is a **CLI-only fork** of
[decryptu/claude-gauge](https://github.com/decryptu/claude-gauge) (MIT), stripped
down to its usage/refresh core with the original app's GUI removed. All the
cookie-decryption cleverness is theirs. The upstream copyright is retained in
[LICENSE](LICENSE) alongside VUBA's modifications.

## Build & run

```bash
swift build -c release
./.build/release/ClaudeGauge usage --json
```

Common subcommands (add `--json` for machine-readable output):
`usage`, `usage --all`, `accounts list`, `sources`, `refresh`.

## License

MIT — original © 2025 ClaudeMeter Contributors; modifications © 2026 VUBA
(dev@vuba.one). See [LICENSE](LICENSE).
