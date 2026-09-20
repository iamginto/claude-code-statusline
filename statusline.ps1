# Claude Code status line. Renders a single line like:
#
#   5h: 1.0% (21.9%, r:3h54m) | 7d: 8.0% (95.7%, r:0d7h) | ctx: 5% (50.0K/1.0M) | in:53.6K out:3 | cost: $0.665 | Opus 5
#
# Live values come from the status JSON that Claude Code pipes in on stdin; token
# counts are read straight out of the session transcript. No network calls, no API
# requests, no token usage -- this is local file I/O and arithmetic only.
#
# In the parentheses after 5h/7d: how much of that rate-limit window has already
# elapsed, plus when it resets. Quota% well under elapsed% means you are burning slow.
#
# cost is dollars, not plan percentage. Claude Code's total_cost_usd is
# sum(tokens of each kind x that kind's per-model API rate) -- verified against a
# single-call session to four decimal places, and it does price Opus and Sonnet
# turns at their own rates within one session. It covers this session only.

# Turkish (and other non-invariant) locales would otherwise format 53.6 as "53,6".
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

$json = $input | Out-String | ConvertFrom-Json

$e     = [char]27
$reset = "$e[0m"
$dim   = "$e[90m"
$bold  = "$e[1;37m"
$sep   = "$dim|$reset"

$LedgerDir    = Join-Path $env:USERPROFILE '.claude\usage'
$ArchivePath  = Join-Path $LedgerDir 'archive.json'
$CompactAbove = 40      # live session files tolerated before folding old ones away
$CompactOlder = 7       # days; a session idle this long is safe to fold

function Heat([double]$pct) {
    if ($pct -ge 90) { return "$e[1;31m" }  # red
    if ($pct -ge 70) { return "$e[1;33m" }  # yellow
    return "$e[1;32m"                       # green
}

function Tokens([double]$n) {
    if ($n -ge 1000000) { return ('{0:F1}M' -f ($n / 1000000)) }
    if ($n -ge 1000)    { return ('{0:F1}K'  -f ($n / 1000)) }
    return ([int]$n).ToString()
}

# $style: 'hm' -> 3h54m (for the 5h window), 'dh' -> 0d7h (for the 7d window).
function Countdown([double]$seconds, [string]$style) {
    if ($style -eq 'dh') {
        $d = [math]::Floor($seconds / 86400)
        $h = [math]::Floor(($seconds % 86400) / 3600)
        return ('{0}d{1}h' -f $d, $h)
    }
    $h = [math]::Floor($seconds / 3600)
    $m = [math]::Floor(($seconds % 3600) / 60)
    return ('{0}h{1:00}m' -f $h, $m)
}

function Window([string]$label, $limit, [double]$windowSeconds, [string]$style) {
    if ($null -eq $limit -or $null -eq $limit.used_percentage) { return $null }

    $used = [double]$limit.used_percentage
    $part = '{0}{1}: {2:F1}%{3}' -f (Heat $used), $label, $used, $reset

    if ($limit.resets_at) {
        $now  = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $left = [math]::Max(0.0, [math]::Min($windowSeconds, [double]$limit.resets_at - $now))
        $elapsed = (1 - $left / $windowSeconds) * 100
        $part += ' ({0:F1}%, r:{1})' -f $elapsed, (Countdown $left $style)
    }
    return $part
}

function ReadJson([string]$path) {
    try { return [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
}

# Writes via a temp file + atomic replace, so another session summing the ledger
# mid-write never sees a half-written file (which would make the total flicker).
function WriteJson([string]$path, $obj) {
    $tmp = "$path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json $obj -Depth 5 -Compress))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# Cache reads and cache writes are input-side tokens, so they count towards "in".
function ModelTotals($models) {
    $t = @{ inTok = 0.0; outTok = 0.0 }
    foreach ($k in $models.Keys) {
        $m = $models[$k]
        $t.inTok  += $m.inp + $m.read + $m.w
        $t.outTok += $m.out
    }
    return $t
}

# Claude Code's status JSON only reports the CURRENT request's token counts
# (total_input_tokens is the live context size, not a session running total), so
# cumulative tokens have to come from the transcript. Reading it whole on every
# render would be wasteful, so we remember a byte offset and parse only what was
# appended since. One API call writes several transcript lines -- one per content
# block -- all carrying the same message-level usage object, and those lines are
# always contiguous, so skipping repeats of the last requestId deduplicates them.
function ScanTranscript([string]$path, $prev) {
    $state = @{ offset = 0L; lastReq = ''; models = @{} }

    if ($prev -and $prev.src -eq $path -and $prev.models) {
        $state.offset  = [long]$prev.offset
        $state.lastReq = [string]$prev.lastReq
        foreach ($p in $prev.models.PSObject.Properties) {
            $state.models[$p.Name] = @{
                inp  = [double]$p.Value.inp; out = [double]$p.Value.out
                read = [double]$p.Value.read; w  = [double]$p.Value.w
            }
        }
    }

    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $state }

    # FileShare::ReadWrite so this never blocks Claude Code from appending.
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($state.offset -gt $fs.Length) {   # transcript shrank: rewritten, so recount
            $state.offset = 0L; $state.lastReq = ''; $state.models = @{}
        }
        $todo = $fs.Length - $state.offset
        if ($todo -le 0) { return $state }

        $fs.Position = $state.offset
        $buf = New-Object byte[] $todo
        $got = 0
        while ($got -lt $todo) {
            $n = $fs.Read($buf, $got, $todo - $got)
            if ($n -le 0) { break }
            $got += $n
        }

        # Stop at the last newline: the tail may be a line still being written.
        $end = [Array]::LastIndexOf($buf, [byte]10, $got - 1)
        if ($end -lt 0) { return $state }
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $end + 1)
        $state.offset += $end + 1
    } finally {
        $fs.Dispose()
    }

    foreach ($line in $text.Split("`n")) {
        if ($line.IndexOf('"usage"') -lt 0) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $u = $o.message.usage
        if ($null -eq $u) { continue }

        $req = $o.requestId
        if (-not $req) { $req = $o.uuid }
        if ($req -eq $state.lastReq) { continue }
        $state.lastReq = $req

        $name = $o.message.model
        if (-not $name) { $name = 'unknown' }
        if (-not $state.models.ContainsKey($name)) {
            $state.models[$name] = @{ inp = 0.0; out = 0.0; read = 0.0; w = 0.0 }
        }
        $m = $state.models[$name]
        $m.inp  += [double]$u.input_tokens
        $m.out  += [double]$u.output_tokens
        $m.read += [double]$u.cache_read_input_tokens
        $m.w    += [double]$u.cache_creation_input_tokens
    }
    return $state
}

# Folds sessions idle for a while into a single archive.json, so the per-render cost
# stays bounded no matter how many sessions pile up over months. Held under a mutex
# because the read-modify-write of archive.json is not atomic.
function Compact($files, [string]$keepName) {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeCodeUsageLedger')
    try {
        if (-not $mutex.WaitOne(150)) { return }   # another session is compacting; skip
        $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - ($CompactOlder * 86400)
        $a = ReadJson $ArchivePath
        $cost   = if ($a) { [double]$a.cost }   else { 0.0 }
        $tokens = if ($a) { [double]$a.tokens } else { 0.0 }
        $folded = @()

        foreach ($f in $files) {
            if ($f.Name -eq $keepName) { continue }
            $p = ReadJson $f.FullName
            if ($null -eq $p -or [double]$p.ts -ge $cutoff) { continue }
            $cost += [double]$p.baseCost + [double]$p.curCost
            if ($p.models) {
                foreach ($x in $p.models.PSObject.Properties) {
                    $tokens += [double]$x.Value.inp + [double]$x.Value.out +
                               [double]$x.Value.read + [double]$x.Value.w
                }
            }
            $folded += $f.FullName
        }

        if ($folded.Count) {
            WriteJson $ArchivePath @{ cost = $cost; tokens = $tokens }
            foreach ($path in $folded) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    } catch {
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

# The ledger: one file per session, named <session_id>.json, owned exclusively by
# that session's process -- so concurrent Claude Code tabs never race on a write.
# Cost is cumulative *within* a session, so the file is overwritten rather than
# incremented. A resumed session can restart its own counter from zero; when the
# incoming value drops we roll the previous figure into baseCost so the all-time
# total never regresses. Tokens need no such guard: they are recomputed from the
# transcript, which keeps growing across a resume.
function SessionUsage([string]$sessionId, $cost, [string]$transcript) {
    if (-not (Test-Path $LedgerDir)) { New-Item -ItemType Directory -Path $LedgerDir -Force | Out-Null }

    $meName = $null
    $mine = @{ cost = 0.0; inTok = 0.0; outTok = 0.0 }

    if ($sessionId) {
        $meName = "$sessionId.json"
        $me = Join-Path $LedgerDir $meName
        $prev = ReadJson $me

        $baseCost = 0.0
        if ($prev) {
            $baseCost = [double]$prev.baseCost
            if ([double]$prev.curCost -gt [double]$cost) { $baseCost += [double]$prev.curCost }
        }

        $scan = ScanTranscript $transcript $prev
        $t = ModelTotals $scan.models
        $mine.cost   = $baseCost + [double]$cost
        $mine.inTok  = $t.inTok
        $mine.outTok = $t.outTok

        WriteJson $me @{
            baseCost = $baseCost
            curCost  = [double]$cost
            src      = $transcript
            offset   = $scan.offset
            lastReq  = $scan.lastReq
            models   = $scan.models
            ts       = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }
    }

    $files = @(Get-ChildItem -LiteralPath $LedgerDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ne 'archive.json' })
    if ($files.Count -gt $CompactAbove) {
        Compact $files $meName
        $files = @(Get-ChildItem -LiteralPath $LedgerDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -ne 'archive.json' })
    }

    $totalCost = 0.0; $totalTok = 0.0
    $a = ReadJson $ArchivePath
    if ($a) { $totalCost += [double]$a.cost; $totalTok += [double]$a.tokens }
    foreach ($f in $files) {
        $p = ReadJson $f.FullName
        if ($null -eq $p) { continue }
        $totalCost += [double]$p.baseCost + [double]$p.curCost
        if ($p.models) {
            foreach ($x in $p.models.PSObject.Properties) {
                $totalTok += [double]$x.Value.inp + [double]$x.Value.out +
                             [double]$x.Value.read + [double]$x.Value.w
            }
        }
    }
    return @{ cost = $totalCost; tokens = $totalTok; mine = $mine }
}

$parts = @()

$parts += Window '5h' $json.rate_limits.five_hour   18000  'hm'
$parts += Window '7d' $json.rate_limits.seven_day  604800  'dh'

$cw = $json.context_window
if ($cw) {
    $ctxPct = [double]$cw.used_percentage
    $u      = $cw.current_usage
    $ctxTok = [double]$u.input_tokens + [double]$u.cache_creation_input_tokens +
              [double]$u.cache_read_input_tokens + [double]$u.output_tokens
    $parts += '{0}ctx: {1}%{2} ({3}/{4})' -f (Heat $ctxPct), [math]::Round($ctxPct), $reset,
              (Tokens $ctxTok), (Tokens ([double]$cw.context_window_size))
}

# The ledger must never be able to break the status line; fall back to omitting it.
$total = $null
try { $total = SessionUsage $json.session_id $json.cost.total_cost_usd $json.transcript_path } catch { }

if ($total) {
    $parts += '{0}in:{1} out:{2}{3}' -f $dim, (Tokens $total.mine.inTok), (Tokens $total.mine.outTok), $reset
}

if ($null -ne $json.cost.total_cost_usd) {
    $parts += '{0}cost:{1} {2}${3:F3}{4}' -f $dim, $reset, $bold, [double]$json.cost.total_cost_usd, $reset
}

if ($json.model.display_name) {
    $parts += '{0}{1}{2}' -f $bold, $json.model.display_name, $reset
}

[Console]::Out.Write(($parts | Where-Object { $_ }) -join " $sep ")
