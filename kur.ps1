# claude-code-statusline kurucusu.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File kur.ps1 -Kaldir
#
# Script'i %USERPROFILE%\.claude\statusline.ps1 olarak kopyalar ve ayni klasordeki
# settings.json icinde statusLine komutunu ona baglar. Ayar dosyasinin geri kalanina
# dokunulmaz; yazmadan once settings.json.yedek olarak bir kopyasi alinir.
#
# Dosya bilerek saf ASCII: Windows PowerShell 5.1, BOM'suz bir .ps1 icindeki
# Turkce harfleri ANSI sanip bozuyor.

[CmdletBinding()]
param([switch]$Kaldir)

$ErrorActionPreference = 'Stop'

$ClaudeDizini = Join-Path $env:USERPROFILE '.claude'
$AyarYolu     = Join-Path $ClaudeDizini 'settings.json'
$Hedef        = Join-Path $ClaudeDizini 'statusline.ps1'
$Kaynak       = Join-Path $PSScriptRoot 'statusline.ps1'

function AyarOku([string]$yol) {
    if (-not (Test-Path -LiteralPath $yol)) { return [pscustomobject]@{} }
    $ham = [IO.File]::ReadAllText($yol)
    if ([string]::IsNullOrWhiteSpace($ham)) { return [pscustomobject]@{} }
    try {
        $o = $ham | ConvertFrom-Json
    } catch {
        throw "$yol gecerli JSON degil. Once onu duzelt; dosyaya dokunulmadi."
    }
    if ($null -eq $o) { return [pscustomobject]@{} }
    if ($o -isnot [psobject] -or $o -is [array]) {
        throw "$yol bir JSON nesnesi degil. Dosyaya dokunulmadi."
    }
    return $o
}

# PS 5.1'in ConvertTo-Json ciktisi kaydiralarak hizalanir; ayni JSON'u 2 boslukla
# yeniden girintiler. Yalnizca dizelerin DISINA bosluk ekler, hicbir karakteri
# degistirmez.
function Girintile([string]$sikisik) {
    $sb = New-Object Text.StringBuilder
    $derinlik = 0
    for ($i = 0; $i -lt $sikisik.Length; $i++) {
        $ch = $sikisik[$i]
        if ($ch -eq '"') {                       # dizeyi oldugu gibi gecir
            $j = $i + 1
            while ($j -lt $sikisik.Length) {
                if ($sikisik[$j] -eq '\') { $j += 2; continue }
                if ($sikisik[$j] -eq '"') { break }
                $j++
            }
            [void]$sb.Append($sikisik.Substring($i, [Math]::Min($j, $sikisik.Length - 1) - $i + 1))
            $i = $j
            continue
        }
        switch -CaseSensitive ($ch) {
            { $_ -eq '{' -or $_ -eq '[' } {
                [void]$sb.Append($ch)
                if ($i + 1 -lt $sikisik.Length -and ($sikisik[$i+1] -eq '}' -or $sikisik[$i+1] -eq ']')) {
                    [void]$sb.Append($sikisik[$i+1]); $i++      # bos {} / [] tek satirda
                } else {
                    $derinlik++
                    [void]$sb.Append("`n" + ('  ' * $derinlik))
                }
            }
            { $_ -eq '}' -or $_ -eq ']' } {
                $derinlik--
                [void]$sb.Append("`n" + ('  ' * $derinlik) + $ch)
            }
            ',' { [void]$sb.Append(",`n" + ('  ' * $derinlik)) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

# UTF-8, BOM'suz, LF. Girintileme bozulursa ham ConvertTo-Json ciktisina donulur.
function AyarYaz([string]$yol, $ayar) {
    $sikisik = ConvertTo-Json $ayar -Depth 20 -Compress
    $metin = Girintile $sikisik
    try {
        if ((ConvertTo-Json ($metin | ConvertFrom-Json) -Depth 20 -Compress) -ne $sikisik) {
            $metin = ConvertTo-Json $ayar -Depth 20
        }
    } catch {
        $metin = ConvertTo-Json $ayar -Depth 20
    }
    [IO.File]::WriteAllText($yol, ($metin -replace "`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
}

$ayar = AyarOku $AyarYolu
if (Test-Path -LiteralPath $AyarYolu) {
    Copy-Item -LiteralPath $AyarYolu -Destination "$AyarYolu.yedek" -Force
}

if ($Kaldir) {
    if ($ayar.PSObject.Properties['statusLine']) {
        $ayar.PSObject.Properties.Remove('statusLine')
        AyarYaz $AyarYolu $ayar
        Write-Host "statusLine ayari kaldirildi: $AyarYolu"
    } else {
        Write-Host "statusLine ayari zaten yok: $AyarYolu"
    }
    Write-Host "Script ve sayaclar yerinde duruyor; istersen elle sil:"
    Write-Host "  $Hedef"
    Write-Host "  $(Join-Path $ClaudeDizini 'usage')"
    return
}

if (-not (Test-Path -LiteralPath $Kaynak)) {
    throw "statusline.ps1 bulunamadi: $Kaynak"
}
if (-not (Test-Path -LiteralPath $ClaudeDizini)) {
    New-Item -ItemType Directory -Path $ClaudeDizini -Force | Out-Null
}

Copy-Item -LiteralPath $Kaynak -Destination $Hedef -Force

$komut = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Hedef
$ayar | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]@{
    type    = 'command'
    command = $komut
}) -Force
AyarYaz $AyarYolu $ayar

Write-Host "Kuruldu."
Write-Host "  script : $Hedef"
Write-Host "  ayar   : $AyarYolu"
if (Test-Path -LiteralPath "$AyarYolu.yedek") { Write-Host "  yedek  : $AyarYolu.yedek" }
Write-Host "Durum satiri, acik Claude Code oturumlari yeniden baslatilinca gorunur."
