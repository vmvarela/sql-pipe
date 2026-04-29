$ErrorActionPreference = 'Stop'
$toolsDir = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$version  = $env:ChocolateyPackageVersion

Get-ChocolateyWebFile `
  -PackageName    $env:ChocolateyPackageName `
  -FileFullPath   (Join-Path $toolsDir 'sql-pipe.exe') `
  -Url            "https://github.com/vmvarela/sql-pipe/releases/download/v$version/sql-pipe-x86-windows.exe" `
  -Url64bit       "https://github.com/vmvarela/sql-pipe/releases/download/v$version/sql-pipe-x86_64-windows.exe" `
  -Checksum       $env:CHECKSUM_X86 `
  -ChecksumType   'sha256' `
  -Checksum64     $env:CHECKSUM_X64 `
  -ChecksumType64 'sha256'
