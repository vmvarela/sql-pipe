$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$version  = $env:ChocolateyPackageVersion

$packageArgs = @{
    packageName    = 'sql-pipe'
    fileFullPath   = Join-Path $toolsDir 'sql-pipe.exe'
    url            = "https://github.com/vmvarela/sql-pipe/releases/download/v${version}/sql-pipe-x86-windows.exe"
    url64bit       = "https://github.com/vmvarela/sql-pipe/releases/download/v${version}/sql-pipe-x86_64-windows.exe"
    checksum       = $env:CHECKSUM_X86
    checksum64     = $env:CHECKSUM_X64
    checksumType   = 'sha256'
}

Get-ChocolateyWebFile @packageArgs
