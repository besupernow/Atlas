param([switch]$Apply)

$shim = "import 'package:plezy/utils/app_platform.dart';"
$files = Get-ChildItem lib -Recurse -Filter *.dart |
  Where-Object { $_.Name -notlike 'app_platform*' -and $_.Name -notlike '*.g.dart' -and $_.Name -notlike '*.freezed.dart' }

$changed = 0
foreach ($f in $files) {
  $text = Get-Content $f.FullName -Raw
  if ($text -notmatch '(?<![\w.])Platform\.') { continue }
  if ($text.Contains($shim)) { continue }
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $new = $text

  if ($new -match "(?m)^import 'dart:io';") {
    $re = [regex]"(?m)^import 'dart:io';"
    $new = $re.Replace($new, "import 'dart:io' hide Platform;$nl$shim", 1)
  }
  elseif ($new -match "(?m)^import 'dart:io' show ([^;]+);") {
    $re = [regex]"(?m)^import 'dart:io' show ([^;]+);"
    $ev = [System.Text.RegularExpressions.MatchEvaluator]{
      param($m)
      $names = @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'Platform' })
      if ($names.Count -gt 0) { "import 'dart:io' show $($names -join ', ');$nl$shim" } else { $shim }
    }
    $new = $re.Replace($new, $ev, 1)
  }
  elseif ($new -match "(?m)^import 'dart:io' hide ([^;]+);") {
    $re = [regex]"(?m)^import 'dart:io' hide ([^;]+);"
    $ev = [System.Text.RegularExpressions.MatchEvaluator]{
      param($m)
      "import 'dart:io' hide $($m.Groups[1].Value.Trim()), Platform;$nl$shim"
    }
    $new = $re.Replace($new, $ev, 1)
  }
  else {
    Write-Host "NEEDS MANUAL: $($f.FullName) uses Platform but has no plain dart:io import"
    continue
  }

  $changed++
  Write-Host "$(if ($Apply) {'UPDATED'} else {'would update'}): $($f.FullName)"
  if ($Apply) { Set-Content -Path $f.FullName -Value $new -NoNewline -Encoding UTF8 }
}
Write-Host "$changed file(s) $(if ($Apply) {'updated'} else {'would change'})"
