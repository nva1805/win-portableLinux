param([switch]$Desktop,[switch]$Terminal,[switch]$CheckOnly,[switch]$Diagnostic,
    [ValidateRange(1024,65535)][int]$SerialPort=19385,[ValidateRange(1024,65535)][int]$QmpPort=19386)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
Assert-PortablePlatform
Set-PortableEnvironment $root
$config = Read-PortableConfig $root
if ($Desktop -and $Terminal) { throw 'Choose desktop OR terminal.' }
$mode = if ($Terminal) { 'Terminal' } else { 'Desktop' }
$qargs = @(Get-PortableQemuArguments $config $mode)
$exe = Join-Path $root 'qemu\qemu-system-x86_64.exe'
$disk = Join-Path $root 'disks\ubuntu.qcow2'
$logDirectory = Join-Path $root 'runtime\logs'
if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $disk)) {
    throw 'Ubuntu is not installed here. Run SETUP.cmd first; keep the complete folder on the SSD.'
}
if ($CheckOnly) {
    Write-Output "Bundle: $root | Mode: $mode | RAM: $($config.MemoryMB) MB | CPUs: $($config.CPUs)"
    Write-Output ('QEMU arguments: '+(Join-NativeArguments $qargs))
    & $exe --version
    exit $LASTEXITCODE
}
$statePath = Join-Path $root 'runtime\setup-state.json'
if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($state.Stage -ne 'Ready') { throw 'Setup is incomplete. Run SETUP.cmd again to resume; do not replace the disk.' }
}
$guard = Enter-PortableLock $root
try {
    Write-Host 'Portable Ubuntu | user: ubuntu | work: ~/work'
    Write-Host 'Safe shutdown in Ubuntu: sudo poweroff'
    Write-Host 'Keep this launcher open (you can minimize it). Eject the SSD only after both windows exit.'
    if ($mode -eq 'Desktop') { Write-Host 'Full screen: Ctrl+Alt+F | Release input: Ctrl+Alt+G | Original size: Ctrl+Alt+0' }
    if ($Diagnostic) {
        $qargs += @('-monitor','none','-serial',"tcp:127.0.0.1:$SerialPort,server=on,wait=on",'-qmp',"tcp:127.0.0.1:$QmpPort,server=on,wait=off")
        $ErrorActionPreference = 'Continue'
        & $exe @qargs 2>> (Join-Path $logDirectory 'diagnostic-error.log')
        $result = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
    } elseif ($mode -eq 'Desktop') {
        $qargs += @('-monitor','none','-serial','file:runtime/logs/desktop-serial.log')
        $process = Start-Process -FilePath (Join-Path $root 'qemu\qemu-system-x86_64w.exe') -ArgumentList (Join-NativeArguments $qargs) -WorkingDirectory $root -WindowStyle Normal -RedirectStandardError (Join-Path $logDirectory 'desktop-error.log') -RedirectStandardOutput (Join-Path $logDirectory 'desktop-stdout.log') -PassThru
        $processHandle = $process.Handle
        try { $process.WaitForExit() } finally {
            if (-not $process.HasExited) { Write-Host 'Ubuntu is still running. Waiting for safe shutdown.'; $process.WaitForExit() }
        }
        $result = $process.ExitCode
    } else {
        $result = & (Join-Path $PSScriptRoot 'Console.ps1') -QemuArgs $qargs -BundleRoot $root -LogDirectory $logDirectory
    }
    if ($null -eq $result) { throw 'Could not read QEMU exit status.' }
    if ($result -ne 0) { Write-Host "QEMU reported an error. See $logDirectory. If WHPX fails, try Accelerator: tcg in config.json." }
} finally { $guard.Dispose() }
exit $result
