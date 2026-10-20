Set-StrictMode -Version 2

function Assert-PortablePlatform {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Windows x64 is required.' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
        throw 'This bundle targets Intel/AMD x64 Windows, not ARM64 Windows.'
    }
}

function Set-PortableEnvironment([string]$Root) {
    foreach ($name in @('temp','home','appdata','localappdata','cache','config','data','logs')) {
        New-Item -ItemType Directory -Path (Join-Path $Root "runtime\$name") -Force | Out-Null
    }
    $env:TEMP = Join-Path $Root 'runtime\temp'
    $env:TMP = $env:TEMP
    $env:HOME = Join-Path $Root 'runtime\home'
    $env:USERPROFILE = $env:HOME
    $env:APPDATA = Join-Path $Root 'runtime\appdata'
    $env:LOCALAPPDATA = Join-Path $Root 'runtime\localappdata'
    $env:XDG_CACHE_HOME = Join-Path $Root 'runtime\cache'
    $env:XDG_CONFIG_HOME = Join-Path $Root 'runtime\config'
    $env:XDG_DATA_HOME = Join-Path $Root 'runtime\data'
}

function Read-PortableConfig([string]$Root) {
    $config = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
    foreach ($name in @('MemoryMB','CPUs','DiskSizeGiB','DisplayWidth','DisplayHeight')) {
        if ($null -eq $config.$name -or [double]$config.$name -ne [int]$config.$name) { throw "Invalid integer setting: $name" }
    }
    if ($config.MemoryMB -lt 1024 -or $config.MemoryMB -gt 16384) { throw 'MemoryMB must be 1024..16384.' }
    if ($config.CPUs -lt 1 -or $config.CPUs -gt 8) { throw 'CPUs must be 1..8.' }
    if ($config.DiskSizeGiB -lt 12 -or $config.DiskSizeGiB -gt 512) { throw 'DiskSizeGiB must be 12..512.' }
    if ($config.Accelerator -notin @('auto','tcg')) { throw 'Accelerator must be auto or tcg.' }
    if (($config.DisplayWidth -eq 0) -ne ($config.DisplayHeight -eq 0)) { throw 'Set both display dimensions or leave both zero for automatic.' }
    if ($config.DisplayWidth -ne 0 -and ($config.DisplayWidth -lt 800 -or $config.DisplayWidth -gt 3840 -or $config.DisplayHeight -lt 600 -or $config.DisplayHeight -gt 2160)) { throw 'Display size must be 800x600..3840x2160.' }
    return $config
}

function Get-PortableDisplaySize($Config) {
    if ($Config.DisplayWidth -gt 0) { return @([int]$Config.DisplayWidth, [int]$Config.DisplayHeight) }
    try {
        if (-not ('PortableLinuxDpi' -as [type])) {
            Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class PortableLinuxDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
        }
        [PortableLinuxDpi]::SetProcessDPIAware() | Out-Null
        Add-Type -AssemblyName System.Windows.Forms
        $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
        return @([math]::Max(800,[math]::Min(3840,$bounds.Width)), [math]::Max(600,[math]::Min(2160,$bounds.Height)))
    } catch { return @(1280,800) }
}

function Get-PortableQemuArguments($Config, [string]$Mode = 'Terminal') {
    $size = Get-PortableDisplaySize $Config
    $display = if ($Mode -eq 'Desktop') { 'gtk,gl=off,window-close=off,zoom-to-fit=off,clipboard=off' } else { 'none' }
    $arguments = @('-name','PortableUbuntu','-machine','pc','-cpu','max',
        '-smp',"$($Config.CPUs)",'-m',"$($Config.MemoryMB)",'-display',$display,
        '-vga','none','-device',"virtio-vga,xres=$($size[0]),yres=$($size[1])",
        '-smbios',"type=1,product=PortableUbuntu-$Mode",'-global','isa-fdc.fdtypeA=none',
        '-drive','file=disks/ubuntu.qcow2,format=qcow2,if=virtio',
        '-nic','user,model=virtio-net-pci','-boot','order=c','-rtc','base=utc')
    if ($Config.Accelerator -eq 'auto') { $arguments += @('-accel','whpx,kernel-irqchip=off') }
    $arguments += @('-accel','tcg,thread=multi,tb-size=128')
    if ($Mode -eq 'Desktop') { $arguments += @('-device','qemu-xhci','-device','usb-tablet') }
    return $arguments
}

function Join-NativeArguments([string[]]$Arguments) {
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -ne '' -and $argument -notmatch '[\s"]') { $argument; continue }
        '"' + (($argument -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1') + '"'
    }
    return ($quoted -join ' ')
}

function Enter-PortableLock([string]$Root) {
    try { return [IO.File]::Open((Join-Path $Root 'runtime\ubuntu.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Another setup or Ubuntu session is active. Shut it down first.' }
}

function Assert-ManagedPath([string]$Parent, [string]$Path) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($parentFull+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside managed directory: $full" }
    $cursor = $full
    while ($cursor -and $cursor.Length -ge $parentFull.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse points are not permitted here: $cursor" }
        }
        if ($cursor -eq $parentFull) { break }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}

function Get-FreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Invoke-PortableQmp([int]$Port, [string]$Command, [hashtable]$Arguments = @{}) {
    $client = [Net.Sockets.TcpClient]::new('127.0.0.1',$Port)
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    try {
        $stream = $client.GetStream()
        $reader = [IO.StreamReader]::new($stream)
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $null = $reader.ReadLine()
        $writer.WriteLine('{"execute":"qmp_capabilities","id":"capabilities"}')
        do { $reply = $reader.ReadLine() | ConvertFrom-Json } while (-not $reply.PSObject.Properties['id'] -or $reply.id -ne 'capabilities')
        $request = @{execute=$Command;id='command'}
        if ($Arguments.Count) { $request.arguments = $Arguments }
        $writer.WriteLine(($request | ConvertTo-Json -Depth 10 -Compress))
        do { $reply = $reader.ReadLine() | ConvertFrom-Json } while (-not $reply.PSObject.Properties['id'] -or $reply.id -ne 'command')
        if ($reply.PSObject.Properties['error']) { throw ($reply.error | ConvertTo-Json -Compress) }
        return $reply
    } finally { $client.Dispose() }
}
