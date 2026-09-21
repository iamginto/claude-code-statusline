# claude-code-statusline

A Claude Code status line for Windows that shows how much quota and money
your session is burning. One PowerShell file, no dependencies, no network,
zero tokens.

```
5h: 1.0% (21.9%, r:3h54m) | 7d: 8.0% (95.7%, r:0d7h) | ctx: 5% (50.0K/1.0M) | in:53.6K out:3 | cost: $0.665 | Opus 5
```

## Install

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1          # install
powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1 -Kaldir  # uninstall
```

Copies `statusline.ps1` to `%USERPROFILE%\.claude\` and wires it into
`settings.json` (backup kept). Restart Claude Code to see it.

Manual setup:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\<user>\\.claude\\statusline.ps1\""
  }
}
```

## What it shows

| | |
|---|---|
| `5h` / `7d` | plan quota used, % of window elapsed, time to reset |
| `ctx` | context window usage |
| `in` / `out` | session token totals |
| `cost` | what the session would cost on the API |
| `Opus 5` | model |

Yellow at 70%, red at 90%. If quota % runs ahead of elapsed %, you'll hit the
limit before reset.

## How it works

Session token totals come from the transcript, since the status JSON only
has the current request. The script reads it incrementally from a saved
offset and dedupes by `requestId`. Each session keeps its own counter file in
`%USERPROFILE%\.claude\usage\`, so parallel tabs don't clash, and old ones get
merged into `archive.json`. If anything fails, that field is dropped and the
rest still prints.

Only `usage` numbers are read; conversation content is never touched. Delete
the `usage` folder to reset.

## License

[MIT](LICENSE)
