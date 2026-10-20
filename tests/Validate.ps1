$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$failures=[Collections.Generic.List[string]]::new()
$passed=0
function Test-Check([string]$Name,[scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failures.Add("$Name : $($_.Exception.Message)"); Write-Host "FAIL $Name" }
}
function Assert-True($Condition,[string]$Message) { if(-not $Condition){throw $Message} }

Test-Check 'PowerShell parses without errors' {
    foreach($folder in @('setup','tools','tests')) {
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $root $folder) -Filter *.ps1 -Recurse) {
            $tokens=$null; $errors=$null
            $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            Assert-True ($errors.Count -eq 0) ($file.Name+': '+($errors -join '; '))
        }
    }
}
. (Join-Path $root 'tools\Common.ps1')
Test-Check 'Default config is valid' { $null=Read-PortableConfig $root }
Test-Check 'Only expected user launchers exist' {
    $names=@(Get-ChildItem -LiteralPath $root -Filter *.cmd | ForEach-Object {$_.Name} | Sort-Object)
    Assert-True (($names -join ',') -eq 'SETUP.cmd,START-UBUNTU-DESKTOP.cmd,START-UBUNTU-TERMINAL.cmd') 'Unexpected root CMD files'
    foreach($name in $names) {
        $body=Get-Content -LiteralPath (Join-Path $root $name) -Raw
        Assert-True ($body.Contains('%~dp0')) 'Launcher must be relative to its own location'
        Assert-True (-not $body.Contains('F:\')) 'Launcher must not be fixed to F:'
    }
}
Test-Check 'Sources use HTTPS and pinned hash lengths' {
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $root 'setup\sources.json') | ConvertFrom-Json
    foreach($name in @('ubuntu','qemu','sevenZipBootstrap','sevenZip')) {
        $item=$manifest.$name
        Assert-True (([uri]$item.url).Scheme -eq 'https') 'HTTPS required'
        $length=if($item.algorithm -eq 'SHA512'){128}else{64}
        Assert-True ($item.hash -match "^[a-f0-9]{$length}$") 'Missing pinned checksum'
        Assert-True ([IO.Path]::GetFileName($item.file) -eq $item.file) 'Filename traversal'
    }
    Assert-True ($manifest.ubuntu.url.Contains('/release-20261017/')) 'Ubuntu must not use a mutable current URL'
}
Test-Check 'Seed includes every generated payload placeholder exactly once' {
    $seed=Get-Content -Raw -LiteralPath (Join-Path $root 'setup\seed\user-data')
    foreach($token in @('__PROVISION_BASE64__','__WALLPAPER_BASE64__')) {
        Assert-True ([regex]::Matches($seed,$token).Count -eq 1) "Invalid payload marker $token"
    }
    Assert-True ($seed.StartsWith('#cloud-config')) 'Missing cloud-config header'
    Assert-True ($seed.Contains('lock_passwd: true')) 'No shared default password allowed'
    Assert-True ($seed.Contains('portable-provision.service')) 'Missing resumable provisioning service'
}
Test-Check 'Provision recipe contains fixes and verification before success' {
    $body=Get-Content -Raw -LiteralPath (Join-Path $root 'setup\seed\provision.sh')
    foreach($required in @('librsvg2-common','AccelMethod','portable-display-auto','value="64"','sudo -n /sbin/poweroff','dpkg --audit','apt-get check','cloud-init.disabled','PORTABLE_LINUX_GUEST_READY')) {
        Assert-True ($body.Contains($required)) "Missing recipe feature $required"
    }
    Assert-True ($body.IndexOf('dpkg --audit') -lt $body.IndexOf("report 'PORTABLE_LINUX_SETUP_SUCCESS'")) 'Success marker precedes package audit'
    Assert-True (-not $body.Contains('passwd ubuntu:')) 'Do not embed a shared password'
}
Test-Check 'Runtime arguments do not share host drives, SSH or clipboard' {
    $config=Read-PortableConfig $root
    $config.DisplayWidth=1920;$config.DisplayHeight=1080
    $arguments=@(Get-PortableQemuArguments $config 'Desktop') -join ' '
    Assert-True ($arguments.Contains('zoom-to-fit=off')) 'Do not stretch guest pixels'
    Assert-True ($arguments.Contains('clipboard=off')) 'Clipboard must be disabled'
    Assert-True ($arguments.Contains('virtio-vga,xres=1920,yres=1080')) 'Missing display EDID size'
    Assert-True ($arguments.Contains('whpx,kernel-irqchip=off')) 'Missing WHPX workaround'
    Assert-True (-not ($arguments -match 'hostfwd|virtfs|fsdev|ext4.vhdx')) 'Unexpected incoming port or host drive'
    $config.Accelerator='tcg'
    $arguments=@(Get-PortableQemuArguments $config 'Terminal') -join ' '
    Assert-True (-not $arguments.Contains('whpx')) 'Forced TCG still includes WHPX'
}
Test-Check 'Windows native quoting handles spaces and trailing slash' {
    Assert-True ((Join-NativeArguments @('hello','two words')) -eq 'hello "two words"') 'Space quoting'
    Assert-True ((Join-NativeArguments @('')) -eq '""') 'Empty argument quoting'
    Assert-True ((Join-NativeArguments @('two words\')) -eq '"two words\\"') 'Trailing slash quoting'
}
Test-Check 'Managed paths reject parent traversal and root removal' {
    $parent=Join-Path $root 'runtime'
    $good=Join-Path $parent 'setup-cache'
    Assert-True ((Assert-ManagedPath $parent $good) -eq $good) 'Valid managed path rejected'
    $rejected=$false
    try {$null=Assert-ManagedPath $parent $parent} catch {$rejected=$true}
    Assert-True $rejected 'Managed parent itself must not be a deletion target'
    $rejected=$false
    try {$null=Assert-ManagedPath $parent (Join-Path $parent '..\disks')} catch {$rejected=$true}
    Assert-True $rejected 'Traversal outside managed area accepted'
}
Test-Check 'Gitignore excludes OS disks and authentication' {
    $ignore=Get-Content -Raw -LiteralPath (Join-Path $root '.gitignore')
    foreach($entry in @('/disks/','/qemu/','/runtime/','/.local-tools/','/.test-runs/','*.qcow2','*.vhdx','hosts.yml','.env')) {
        Assert-True ($ignore.Contains($entry)) "Missing gitignore entry $entry"
    }
}
Test-Check 'No legacy READY directory dependency' {
    $launcher=Get-Content -Raw -LiteralPath (Join-Path $root 'tools\Launcher.ps1')
    Assert-True (-not $launcher.Contains('ubuntu\READY')) 'Legacy dependency remains'
    Assert-True ($launcher.Contains('Enter-PortableLock')) 'Duplicate session guard missing'
}
Write-Host "Tests passed: $passed; failed: $($failures.Count)"
if($failures.Count){$failures | ForEach-Object {Write-Error $_ -ErrorAction Continue};exit 1}
