# Runs every 5 min as SYSTEM. Shuts Windows down (and so stops the instance,
# since shutdown behavior is "stop") after 30 min of inactivity. Busy means any
# of: >=25MB network in+out since the last run (streams, downloads), disk
# writes >5MB/s (installers unpacking with no network traffic), or CPU >15%.
$f = 'C:\gaming\idle.json'
$stats = Get-NetAdapterStatistics
$bytes = ($stats | Measure-Object -Property ReceivedBytes -Sum).Sum + ($stats | Measure-Object -Property SentBytes -Sum).Sum
$s = if (Test-Path $f) { Get-Content $f | ConvertFrom-Json } else { [pscustomobject]@{ bytes = $bytes; idle = 0 } }
$deltaMB = ($bytes - $s.bytes) / 1MB

$samples = (Get-Counter '\PhysicalDisk(_Total)\Disk Write Bytes/sec', '\Processor(_Total)\% Processor Time' -SampleInterval 3 -MaxSamples 5).CounterSamples
$diskMBs = ($samples | Where-Object Path -like '*disk write bytes*' | Measure-Object CookedValue -Average).Average / 1MB
$cpu = ($samples | Where-Object Path -like '*processor time*' | Measure-Object CookedValue -Average).Average

$quiet = $deltaMB -ge 0 -and $deltaMB -lt 25 -and $diskMBs -lt 5 -and $cpu -lt 15
$idle = if ($quiet) { $s.idle + 1 } else { 0 }
@{
  bytes = $bytes; idle = $idle; at = (Get-Date).ToString('s')
  deltaMB = [math]::Round($deltaMB, 1); diskMBs = [math]::Round($diskMBs, 1); cpu = [math]::Round($cpu, 1)
} | ConvertTo-Json | Set-Content $f
if ($idle -ge 6) { Remove-Item $f; Stop-Computer -Force }
