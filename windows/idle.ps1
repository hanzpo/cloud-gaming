# Runs every 5 min as SYSTEM. Shuts Windows down (and so stops the instance,
# since shutdown behavior is "stop") after 30 min with <25MB of network traffic
# per 5 min. Counting in+out means Steam downloads and active streams both
# keep the machine up.
$f = 'C:\gaming\idle.json'
$stats = Get-NetAdapterStatistics
$bytes = ($stats | Measure-Object -Property ReceivedBytes -Sum).Sum + ($stats | Measure-Object -Property SentBytes -Sum).Sum
$s = if (Test-Path $f) { Get-Content $f | ConvertFrom-Json } else { [pscustomobject]@{ bytes = $bytes; idle = 0 } }
$deltaMB = ($bytes - $s.bytes) / 1MB
$idle = if ($deltaMB -ge 0 -and $deltaMB -lt 25) { $s.idle + 1 } else { 0 }
@{ bytes = $bytes; idle = $idle; deltaMB = [math]::Round($deltaMB, 1); at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $f
if ($idle -ge 6) { Remove-Item $f; Stop-Computer -Force }
