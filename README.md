# claude-code-statusline

A single-file PowerShell script that shows, in Claude Code's status line, how
much plan quota and money the current session has used. It runs on Windows,
has no dependencies, makes no network requests and uses no tokens itself.

```
5h: 1.0% (21.9%, r:3h54m) | 7d: 8.0% (95.7%, r:0d7h) | ctx: 5% (50.0K/1.0M) | in:53.6K out:3 | cost: $0.665 | Opus 5
```

## Installation

Requirements: Windows 10 or 11 and Claude Code. Windows PowerShell 5.1 ships
with the system; PowerShell 7 works as well.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1
```

The installer copies `statusline.ps1` to `%USERPROFILE%\.claude\` and points the
`statusLine` command in that folder's `settings.json` at it. Other settings are
left untouched, and a backup named `settings.json.yedek` is written before the
file is changed. The status line appears once open Claude Code sessions are
restarted.

To install manually, put `statusline.ps1` wherever you like and add this entry
to `%USERPROFILE%\.claude\settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\<user>\\.claude\\statusline.ps1\""
  }
}
```

To uninstall:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1 -Kaldir
```

This removes the `statusLine` setting. The script and the accumulated counters
(`.claude\usage`) stay in place and can be deleted by hand.

## Fields

| field | meaning |
|---|---|
| `5h: 1.0%` | plan quota used in the 5-hour window |
| `(21.9%, r:3h54m)` | how much of the window has elapsed, and the time until it resets |
| `7d: 8.0% (95.7%, r:0d7h)` | the same for the 7-day window |
| `ctx: 5% (50.0K/1.0M)` | context window: percentage, tokens used / window size |
| `in:53.6K out:3` | total input / output tokens for this session so far |
| `cost: $0.665` | the session's cost in US dollars |
| `Opus 5` | model name |

Percentages turn yellow at 70% and red at 90%.

The second percentage in parentheses is the one to watch. If quota usage stays
well below the elapsed share of the window, you are using it slowly; if it runs
ahead, you will hit the limit before the window resets.

`cost` is not charged against your plan. It shows what the same work would
have cost through the API. Claude Code reports `total_cost_usd` as the sum of
each token type multiplied by that model's unit price. Within one session,
Opus and Sonnet turns are counted separately at their own prices, and the
figure resets for each session.

`in` and `out` are computed separately because the status JSON from Claude
Code only carries figures for the current request: `total_input_tokens` is the
current context size, not a session total. The session totals are therefore
read from the transcript.

## How it works

On every redraw, Claude Code passes a status JSON to the script on stdin, and
the script prints one line. There are no network requests or API calls, only
local file reads and arithmetic.

- **Incremental transcript reading.** Reading the whole transcript on every
  redraw would be wasteful, so the script remembers a byte offset and parses
  only what has been appended since the last read. A single API call writes
  several lines to the transcript (one per content block), all carrying the
  same `usage` object and always adjacent, so repeated `requestId` values are
  skipped. The file is opened with `FileShare::ReadWrite` and never blocks
  Claude Code from writing to it. If the transcript has become shorter, it has
  been rewritten, and the count starts over.
- **One counter file per session.** Each session writes only to its own
  `usage\<session_id>.json`, so Claude Code tabs open at the same time do not
  overwrite each other. Writes go to a temporary file that is then moved into
  place atomically, so a half-written file is never read.
- **Resumed sessions.** When a session is continued with `--resume`, the cost
  counter it receives may start from zero again. If the value drops, the
  previous amount is carried into `baseCost` so the total never goes backwards.
  Tokens are recomputed from the transcript and need no such handling.
- **Compaction.** Once more than 40 session files have accumulated, those
  untouched for 7 days are merged into a single `archive.json` and deleted, so
  the folder does not grow without limit over the months. This runs under a
  named mutex, which keeps two sessions from compacting at the same time.
- **Number format.** The thread culture is pinned to `InvariantCulture`;
  otherwise a Turkish locale would print `53,6` instead of `53.6`.
- **Failure handling.** All counter work runs inside `try/catch`. If something
  fails, only that field is left out and the rest of the line is still printed.

Fields read from the status JSON: `session_id`, `transcript_path`,
`model.display_name`, `cost.total_cost_usd`, `context_window` and
`rate_limits.five_hour` / `.seven_day`. If Claude Code omits one of them (plan
limits are not sent when using an API key, for example), that part of the line
is skipped.

## Data locations

| | |
|---|---|
| `%USERPROFILE%\.claude\usage\<session_id>.json` | per-session counter state: offset, last `requestId`, tokens per model, cost |
| `%USERPROFILE%\.claude\usage\archive.json` | totals of merged older sessions |

The script never connects to the internet and sends nothing anywhere. It reads
only the `usage` figures from the transcript; conversation content is neither
read nor written anywhere. To reset the counters, delete the `usage` folder.
Claude Code is not affected.

## License

[MIT](LICENSE).
