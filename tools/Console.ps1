param([string[]]$QemuArgs, [string]$BundleRoot, [string]$LogDirectory = '')
$ErrorActionPreference = 'Stop'
if (-not $LogDirectory) { $LogDirectory = Join-Path $BundleRoot 'logs' }
if (-not ('PortableLinuxNativeConsole' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PortableLinuxNativeConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
}
'@
}
$outputHandle = [PortableLinuxNativeConsole]::GetStdHandle(-11)
$oldOutputMode = [uint32]0
$hasConsoleMode = [PortableLinuxNativeConsole]::GetConsoleMode($outputHandle, [ref]$oldOutputMode)
if ($hasConsoleMode) { [void][PortableLinuxNativeConsole]::SetConsoleMode($outputHandle, $oldOutputMode -bor 5) }
# A local TCP serial transport provides backpressure for pasted commands.
# It avoids the small receive buffer of QEMU's Windows stdio backend.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$argsForQemu = $QemuArgs + @('-monitor','none','-serial',"tcp:127.0.0.1:$port,server=on,wait=on")
$process = $null
$client = $null
$oldCtrlC = [Console]::TreatControlCAsInput
try {
    $process = Start-Process -FilePath (Join-Path $BundleRoot 'qemu\qemu-system-x86_64.exe') -ArgumentList (Join-NativeArguments $argsForQemu) -WorkingDirectory $BundleRoot -WindowStyle Hidden -RedirectStandardError (Join-Path $LogDirectory 'qemu-error.log') -RedirectStandardOutput (Join-Path $LogDirectory 'qemu-stdout.log') -PassThru
    # Retain the process handle so Windows PowerShell can read ExitCode after exit.
    $processHandle = $process.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $client) {
        if ($process.HasExited) { throw 'QEMU exited during startup. See logs\qemu-error.log.' }
        $attempt = [Net.Sockets.TcpClient]::new()
        try { $attempt.Connect('127.0.0.1', $port); $client = $attempt }
        catch {
            $attempt.Dispose()
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Could not connect to the local Linux console.' }
            Start-Sleep -Milliseconds 100
        }
    }
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $buffer = New-Object byte[] 16384
    $chars = New-Object char[] 16384
    $decoder = [Text.Encoding]::UTF8.GetDecoder()
    [Console]::TreatControlCAsInput = $true
    while (-not $process.HasExited -or $stream.DataAvailable) {
        while ($stream.DataAvailable) {
            $count = $stream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) { break }
            $length = $decoder.GetChars($buffer, 0, $count, $chars, 0, $false)
            [Console]::Write($chars, 0, $length)
        }
        $keys = 0
        while ([Console]::KeyAvailable -and $keys -lt 64 -and -not $process.HasExited) {
            $key = [Console]::ReadKey($true)
            $esc = [string][char]27
            $value = switch ($key.Key) {
                'Enter' { "`r" }
                'Backspace' { [string][char]127 }
                'UpArrow' { $esc + '[A' }
                'DownArrow' { $esc + '[B' }
                'RightArrow' { $esc + '[C' }
                'LeftArrow' { $esc + '[D' }
                'Home' { $esc + '[H' }
                'End' { $esc + '[F' }
                'Delete' { $esc + '[3~' }
                'Insert' { $esc + '[2~' }
                'PageUp' { $esc + '[5~' }
                'PageDown' { $esc + '[6~' }
                default { [string]$key.KeyChar }
            }
            if ($value -and $value -ne [string][char]0) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($value)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            $keys++
        }
        Start-Sleep -Milliseconds 5
    }
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) { throw 'Could not read the QEMU exit status.' }
    return [int]$exitCode
} finally {
    [Console]::TreatControlCAsInput = $oldCtrlC
    if ($hasConsoleMode) { [void][PortableLinuxNativeConsole]::SetConsoleMode($outputHandle, $oldOutputMode) }
    if ($client) { $client.Dispose() }
    if ($process -and -not $process.HasExited -and -not $client) {
        # No serial connection: QEMU is paused before guest execution.
        $process.Kill()
        $process.WaitForExit()
    } elseif ($process -and -not $process.HasExited) {
        Write-Host 'Linux is still running. Waiting for shutdown; do not unplug the SSD.'
        $process.WaitForExit()
    }
}
