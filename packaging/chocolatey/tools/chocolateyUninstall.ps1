$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$binary   = Join-Path $toolsDir 'sql-pipe.exe'

if (Test-Path $binary) {
    Remove-Item $binary -Force
}
