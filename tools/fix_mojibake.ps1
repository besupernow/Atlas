param([switch]$Apply)
$cp  = [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
$u8  = New-Object Text.UTF8Encoding($false, $true)
$u8w = New-Object Text.UTF8Encoding($false)
$n = 0
foreach ($f in Get-ChildItem lib -Recurse -Filter *.dart) {
  $t = [IO.File]::ReadAllText($f.FullName, $u8w)
  if ($t -cnotmatch '[^\x00-\x7F]') { continue }
  try { $fixed = $u8.GetString($cp.GetBytes($t)) } catch { continue }
  if ($fixed -ceq $t) { continue }
  $n++
  Write-Host "$(if ($Apply) {'FIXED'} else {'would fix'}): $($f.FullName)"
  if ($Apply) { [IO.File]::WriteAllText($f.FullName, $fixed, $u8w) }
}
Write-Host "$n file(s)"
