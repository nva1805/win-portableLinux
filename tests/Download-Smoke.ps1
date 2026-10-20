# Optional live network smoke test; no downloaded program is executed.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools\Common.ps1')
Set-PortableEnvironment $root
$scriptPath=Join-Path $root 'setup\Setup.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VerifiedDownload'},$true)
if(-not $function){throw 'Download function missing'}
. ([scriptblock]::Create($function.Extent.Text))
$manifest=Get-Content -LiteralPath (Join-Path $root 'setup\sources.json') -Raw | ConvertFrom-Json
$cache=Join-Path $root ('.test-runs\download-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$download=Get-VerifiedDownload $manifest.sevenZipBootstrap $cache
if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $manifest.sevenZipBootstrap.hash){throw 'Hash mismatch'}
$cached=Get-VerifiedDownload $manifest.sevenZipBootstrap $cache
if($cached -ne $download){throw 'Verified cache was not reused'}
Write-Host 'PASS live HTTPS download, pinned checksum and verified cache reuse. No binary executed.'
