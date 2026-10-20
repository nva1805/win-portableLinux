param([string]$TargetDirectory = (Split-Path -Parent $PSScriptRoot),
    [switch]$ValidateOnly,[switch]$KeepDownloads,[ValidateRange(10,360)][int]$TimeoutMinutes=90)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $sourceRoot 'tools\Common.ps1')
Assert-PortablePlatform
$root = [IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { throw 'Use a dedicated folder, not a drive root.' }
New-Item -ItemType Directory -Path $root -Force | Out-Null
Set-PortableEnvironment $root
Set-Location -LiteralPath $root
if (-not (Test-Path -LiteralPath (Join-Path $root 'config.json'))) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config.json') -Destination (Join-Path $root 'config.json')
}
$config = Read-PortableConfig $root
$sources = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'sources.json') | ConvertFrom-Json
foreach ($name in @('ubuntu','qemu','sevenZipBootstrap','sevenZip')) {
    $entry = $sources.$name
    if (([uri]$entry.url).Scheme -ne 'https' -or [IO.Path]::GetFileName($entry.file) -ne $entry.file) { throw "Unsafe source entry: $name" }
    $length = if ($entry.algorithm -eq 'SHA512') { 128 } elseif ($entry.algorithm -eq 'SHA256') { 64 } else { throw 'Unsupported hash algorithm' }
    if ($entry.hash -notmatch "^[a-fA-F0-9]{$length}$") { throw "Invalid pinned hash: $name" }
}
if ($ValidateOnly) {
    Write-Output "Source/config validation passed. Target: $root"
    Write-Output 'Pinned HTTPS sources; Ubuntu 24.04 LTS; no installer is executed on Windows.'
    exit 0
}

function Write-SetupState($State) {
    $json = $State | ConvertTo-Json -Depth 6
    $file = Join-Path $root 'runtime\setup-state.json'
    $temp = $file+'.tmp'
    [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $file -Force
}

function Get-VerifiedDownload($Source,[string]$Cache) {
    $file = Assert-ManagedPath $Cache (Join-Path $Cache $Source.file)
    if (Test-Path -LiteralPath $file) {
        if ((Get-FileHash -LiteralPath $file -Algorithm $Source.algorithm).Hash -eq $Source.hash) {
            Write-Host "Verified cache: $($Source.file)"
            return $file
        }
        $quarantine = $file+'.bad-'+[guid]::NewGuid().ToString('N')
        Move-Item -LiteralPath $file -Destination $quarantine
        Write-Host "Invalid cached download preserved as $quarantine"
    }
    $part = $file+'.part'
    for ($attempt=1; $attempt -le 3; $attempt++) {
        Write-Host "Downloading $($Source.file), attempt $attempt/3"
        $response = $null; $output = $null; $input = $null
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $request = [Net.HttpWebRequest]::Create($Source.url)
            $request.UserAgent = 'win-portableLinux/1.0'
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            $response = $request.GetResponse()
            if ($response.ResponseUri.Scheme -ne 'https') { throw 'Refusing a non-HTTPS redirect.' }
            $input = $response.GetResponseStream()
            $output = [IO.File]::Open($part,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $buffer = New-Object byte[] (1024*1024)
            $received = [long]0
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while (($count=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                $output.Write($buffer,0,$count)
                $received += $count
                if ($timer.Elapsed.TotalSeconds -ge 5) {
                    Write-Host ('  {0}: {1:N1} MiB downloaded' -f $Source.file,($received/1MB))
                    $timer.Restart()
                }
            }
            $output.Dispose(); $output=$null
            if ((Get-FileHash -LiteralPath $part -Algorithm $Source.algorithm).Hash -ne $Source.hash) {
                throw "Checksum mismatch for $($Source.file). No downloaded program was executed."
            }
            Move-Item -LiteralPath $part -Destination $file
            Write-Host "Checksum OK: $($Source.file)"
            return $file
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Host "Download failed: $($_.Exception.Message). Retrying."
        } finally {
            if ($output) { $output.Dispose() }
            if ($input) { $input.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}

function Invoke-CheckedNative([string]$Executable,[string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Executable @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    foreach ($line in $output) { Write-Host ([string]$line) }
    if ($code -ne 0) { throw "Native command failed with exit $code : $Executable" }
}

function Clear-OwnedSetupCache([string]$Cache) {
    $validated = Assert-ManagedPath (Join-Path $root 'runtime') $Cache
    if ((Get-Content -LiteralPath (Join-Path $validated '.managed-cache') -Raw).Trim() -ne 'win-portableLinux-setup-v1') { throw 'Cache ownership marker mismatch.' }
    foreach ($item in @(Get-ChildItem -LiteralPath $validated -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing cache cleanup through a reparse point.' }
    }
    Remove-Item -LiteralPath $validated -Recurse -Force
    Write-Host 'Removed verified setup downloads and temporary extraction files. Source seed and logs are retained.'
}

$guard = Enter-PortableLock $root
$process = $null; $qmpPort=0; $transcript=$false
try {
    $log = Join-Path $root ('runtime\logs\setup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
    Start-Transcript -LiteralPath $log | Out-Null
    $transcript=$true
    $disk = Join-Path $root 'disks\ubuntu.qcow2'
    $statePath = Join-Path $root 'runtime\setup-state.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    if (Test-Path -LiteralPath $disk) {
        if (-not $state -or $state.Owner -ne 'win-portableLinux' -or $state.ImageHash -ne $sources.ubuntu.hash) {
            throw 'An existing Ubuntu disk was found without matching setup state. It will NOT be overwritten or provisioned. Use a fresh folder.'
        }
        if ($state.Stage -eq 'Ready') {
            Write-Host 'Ubuntu is already installed. No data was changed. Use START-UBUNTU-DESKTOP.cmd or START-UBUNTU-TERMINAL.cmd.'
            exit 0
        }
        Write-Host 'Resuming a previously created setup disk; not replacing its data.'
    } elseif ($state -and $state.Stage -eq 'Ready') {
        throw 'Setup state says Ready but the disk is missing. Restore the disk or use a fresh folder; no automatic replacement.'
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    if ($drive.DriveFormat -eq 'FAT32') { throw 'FAT32 cannot hold growing QCOW2 files. Use an NTFS or exFAT SSD folder.' }
    if ($drive.AvailableFreeSpace -lt 10GB) { throw 'Keep at least 10 GiB free for initial setup (24+ GiB recommended for use).' }
    if (-not $state) {
        $state = [pscustomobject]@{Owner='win-portableLinux';InstanceId=('portable-'+[guid]::NewGuid().ToString('N'));ImageHash=$sources.ubuntu.hash;Stage='Preparing'}
        Write-SetupState $state
    }
    $cache = Join-Path $root 'runtime\setup-cache'
    $null = Assert-ManagedPath (Join-Path $root 'runtime') $cache
    $ownership = Join-Path $cache '.managed-cache'
    if ((Test-Path -LiteralPath $cache) -and -not (Test-Path -LiteralPath $ownership) -and @(Get-ChildItem -LiteralPath $cache -Force).Count) { throw 'Existing setup-cache has no ownership marker. It will not be adopted or deleted.' }
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    if (-not (Test-Path -LiteralPath $ownership)) { [IO.File]::WriteAllText($ownership,'win-portableLinux-setup-v1') }
    if ((Get-Content -LiteralPath $ownership -Raw).Trim() -ne 'win-portableLinux-setup-v1') { throw 'Unexpected cache ownership marker.' }

    $qemuDirectory = Join-Path $root 'qemu'
    $stamp = Join-Path $qemuDirectory '.portable-source.sha512'
    if (Test-Path -LiteralPath $qemuDirectory) {
        if (-not (Test-Path -LiteralPath $stamp) -or (Get-Content -LiteralPath $stamp -Raw).Trim() -ne $sources.qemu.hash) { throw 'Existing QEMU directory is not managed by this recipe. Use a fresh folder; it will not be overwritten.' }
    } else {
        $bootstrap = Get-VerifiedDownload $sources.sevenZipBootstrap $cache
        $archive = Get-VerifiedDownload $sources.sevenZip $cache
        $extractorDirectory = Join-Path $cache '7zip'
        Invoke-CheckedNative $bootstrap @('x',$archive,"-o$extractorDirectory",'-y')
        $extractor = Join-Path $extractorDirectory '7z.exe'
        $qemuArchive = Get-VerifiedDownload $sources.qemu $cache
        $staging = Join-Path $cache ('qemu-'+[guid]::NewGuid().ToString('N'))
        Invoke-CheckedNative $extractor @('x',$qemuArchive,"-o$staging",'-y')
        foreach ($name in @('qemu-system-x86_64.exe','qemu-system-x86_64w.exe','qemu-img.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $staging $name))) { throw "QEMU extraction did not produce $name" }
        }
        [IO.File]::WriteAllText((Join-Path $staging '.portable-source.sha512'),$sources.qemu.hash)
        Move-Item -LiteralPath $staging -Destination $qemuDirectory
    }
    $qemu = Join-Path $qemuDirectory 'qemu-system-x86_64.exe'
    $qemuImg = Join-Path $qemuDirectory 'qemu-img.exe'
    Invoke-CheckedNative $qemu @('--version')
    if (-not (Test-Path -LiteralPath $disk)) {
        $image = Get-VerifiedDownload $sources.ubuntu $cache
        New-Item -ItemType Directory -Path (Join-Path $root 'disks') -Force | Out-Null
        $newDisk = Join-Path $root ('disks\setup-'+[guid]::NewGuid().ToString('N')+'.qcow2')
        Copy-Item -LiteralPath $image -Destination $newDisk
        Invoke-CheckedNative $qemuImg @('resize',$newDisk,"$($config.DiskSizeGiB)G")
        Move-Item -LiteralPath $newDisk -Destination $disk
        $state.Stage='Created'; Write-SetupState $state
    }
    $seedDirectory = Join-Path $cache ('seed-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $seedDirectory | Out-Null
    $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'seed\user-data') -Raw
    $provision = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'seed\provision.sh')).Replace("`r`n","`n")
    $scriptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($provision))
    $wallpaperBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'assets\phim-tat-ubuntu.png')))
    $userData = $template.Replace('__PROVISION_BASE64__',$scriptBase64).Replace('__WALLPAPER_BASE64__',$wallpaperBase64).Replace("`r`n","`n")
    [IO.File]::WriteAllText((Join-Path $seedDirectory 'user-data'),$userData,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $seedDirectory 'meta-data'),"instance-id: $($state.InstanceId)`nlocal-hostname: portable-ubuntu`n",[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'seed\network-config') -Destination $seedDirectory
    $seedIso = Join-Path $cache ('seed-'+[guid]::NewGuid().ToString('N')+'.iso')
    & (Join-Path $PSScriptRoot 'New-SeedIso.ps1') -SourceDirectory $seedDirectory -OutputFile $seedIso | Out-Null

    $qmpPort = Get-FreeLoopbackPort
    $relativeSeed = $seedIso.Substring($root.Length+1).Replace('\','/')
    $qargs = @(Get-PortableQemuArguments $config 'Setup')
    $qargs += @('-monitor','none','-serial','file:runtime/logs/setup-serial.log',
        '-drive',"file=$relativeSeed,format=raw,media=cdrom,readonly=on",'-qmp',"tcp:127.0.0.1:$qmpPort,server=on,wait=off")
    $serialPath = Join-Path $root 'runtime\logs\setup-serial.log'
    $state.Stage='Provisioning'; Write-SetupState $state
    Write-Host 'Installing Ubuntu + XFCE inside the VM. Downloads may take a while; do not unplug the SSD.'
    Write-Host 'WHPX is used if already available; TCG fallback can be much slower. No Windows feature is installed/enabled.'
    $process = Start-Process -FilePath $qemu -ArgumentList (Join-NativeArguments $qargs) -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardError (Join-Path $root 'runtime\logs\setup-qemu-error.log') -RedirectStandardOutput (Join-Path $root 'runtime\logs\setup-qemu-stdout.log') -PassThru
    $processHandle = $process.Handle
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $lastProgress=''; $lastNotice=[DateTime]::UtcNow; $success=$false; $failure=$false; $shutdownRequested=$false
    while (-not $process.HasExited) {
        if (Test-Path -LiteralPath $serialPath) {
            $tail = (Get-Content -LiteralPath $serialPath -Tail 120 -ErrorAction SilentlyContinue) -join "`n"
            if ($tail -match 'PORTABLE_LINUX_SETUP_SUCCESS') { $success=$true }
            if ($tail -match 'PORTABLE_LINUX_GUEST_READY') {
                $success=$true
                if (-not $shutdownRequested) {
                    Write-Host 'Guest reports it was already provisioned. Requesting a clean shutdown to finalize host setup state.'
                    $null=Invoke-PortableQmp $qmpPort 'system_powerdown'
                    $shutdownRequested=$true
                }
            }
            if ($tail -match 'PORTABLE_LINUX_SETUP_FAILED') { $failure=$true }
            $matches = [regex]::Matches($tail,'PORTABLE_LINUX_STAGE:[^\r\n]+')
            if ($matches.Count) {
                $progress=$matches[$matches.Count-1].Value
                if ($progress -ne $lastProgress) { Write-Host $progress; $lastProgress=$progress }
            }
        }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Setup timeout. Requesting safe shutdown; keep the SSD connected. Rerun SETUP.cmd to resume.' }
        if (([DateTime]::UtcNow-$lastNotice).TotalSeconds -ge 30) {
            Write-Host ('  Setup VM running; last stage: '+$(if($lastProgress){$lastProgress}else{'booting Ubuntu/cloud-init'}))
            $lastNotice=[DateTime]::UtcNow
        }
        Start-Sleep -Seconds 2
    }
    $process.WaitForExit()
    if (Test-Path -LiteralPath $serialPath) {
        $tail = Get-Content -LiteralPath $serialPath -Raw
        $success = $tail -match 'PORTABLE_LINUX_SETUP_SUCCESS|PORTABLE_LINUX_GUEST_READY'
        $failure = $tail -match 'PORTABLE_LINUX_SETUP_FAILED'
    }
    if ($process.ExitCode -ne 0 -or -not $success -or $failure) { throw 'Guest setup did not report success. See runtime\logs. Fix the cause and rerun SETUP.cmd; the disk is kept.' }
    Invoke-CheckedNative $qemuImg @('check',$disk)
    $info = & $qemuImg info --output=json $disk | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $info.format -ne 'qcow2' -or $info.PSObject.Properties['backing-filename']) { throw 'Expected an independent QCOW2 disk.' }
    $state.Stage='Ready'; Write-SetupState $state
    if (-not $KeepDownloads) { Clear-OwnedSetupCache $cache }
    Write-Host 'SETUP COMPLETE. Start with START-UBUNTU-DESKTOP.cmd or START-UBUNTU-TERMINAL.cmd.'
    Write-Host 'Local account: ubuntu (automatic login). Set your own password in Ubuntu: sudo passwd ubuntu'
} finally {
    if ($process -and -not $process.HasExited) {
        Write-Host 'Ubuntu setup is still running. Requesting ACPI shutdown; keep the SSD connected.'
        try { $null=Invoke-PortableQmp $qmpPort 'system_powerdown' } catch { Write-Warning 'Could not send ACPI shutdown. Do not kill QEMU or unplug the SSD.' }
        while (-not $process.HasExited) { Start-Sleep -Seconds 2 }
    }
    if ($transcript) { Stop-Transcript | Out-Null }
    $guard.Dispose()
}
