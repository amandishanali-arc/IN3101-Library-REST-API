$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator, then run this script again.'
}

$mysqlBin = 'C:\Program Files\MySQL\MySQL Server 8.0\bin'
$dataDirectory = Join-Path $mysqlBin '..\data'
$serviceCommand = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\MySQL80').ImagePath
$expectedCommand = '"' + $mysqlBin + '\mysqld.exe" MySQL80'
if ($serviceCommand.Trim() -ne $expectedCommand) {
    throw 'The MySQL service configuration has changed. Check its data directory before resetting.'
}
if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'mysql.ibd'))) {
    throw 'The expected MySQL data directory was not found. No changes made.'
}
$securePassword = Read-Host 'Enter a new MySQL root password' -AsSecureString
$confirmation = Read-Host 'Enter it again' -AsSecureString
$password = [Net.NetworkCredential]::new('', $securePassword).Password
$confirmed = [Net.NetworkCredential]::new('', $confirmation).Password
if ([string]::IsNullOrWhiteSpace($password) -or $password -ne $confirmed) {
    throw 'Passwords are empty or do not match. No changes made.'
}
if ($password.Contains("`r") -or $password.Contains("`n")) {
    throw 'The password must not contain newlines.'
}

$resetDirectory = Join-Path $env:TEMP ('mysql-reset-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $resetDirectory | Out-Null
$acl = Get-Acl -LiteralPath $resetDirectory
$acl.SetAccessRuleProtection($true, $false)
$rule = [Security.AccessControl.FileSystemAccessRule]::new(
    $identity.Name, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $resetDirectory -AclObject $acl
$initFile = Join-Path $resetDirectory 'reset.sql'
$previousPassword = $env:MYSQL_PWD
$resetServer = $null
try {
    $escaped = $password.Replace('\', '\\').Replace("'", "''")
    [IO.File]::WriteAllText($initFile,
        "ALTER USER 'root'@'localhost' IDENTIFIED BY '$escaped';",
        [Text.UTF8Encoding]::new($false))
    Stop-Service -Name MySQL80
    $resetServer = Start-Process -FilePath "$mysqlBin\mysqld.exe" -ArgumentList @(
        '--no-defaults', "--basedir=`"$(Split-Path $mysqlBin)`"",
        "--datadir=`"$dataDirectory`"", "--init-file=`"$initFile`"", '--console'
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput "$resetDirectory\server.log" -RedirectStandardError "$resetDirectory\error.log"
    $env:MYSQL_PWD = $password
    $connected = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds 1
        if ($resetServer.HasExited) { break }
        $ErrorActionPreference = 'Continue'
        try {
            & "$mysqlBin\mysql.exe" --no-defaults --protocol=TCP --host=127.0.0.1 --user=root --connect-timeout=2 --execute='SELECT 1' 2>$null | Out-Null
            $connectionResult = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = 'Stop'
        }
        if ($connectionResult -eq 0) { $connected = $true; break }
    }
    if (-not $connected) {
        Get-Content -LiteralPath "$resetDirectory\error.log" -Tail 20 -ErrorAction SilentlyContinue
        throw "Could not verify the new password. Inspect $resetDirectory for MySQL errors."
    }
    & "$mysqlBin\mysqladmin.exe" --no-defaults --protocol=TCP --host=127.0.0.1 --user=root shutdown
    if ($LASTEXITCODE -ne 0) { throw 'Could not shut down the reset server.' }
    if (-not $resetServer.WaitForExit(30000)) { throw 'MySQL shutdown timed out.' }
    Write-Host 'Root password reset and verified. Use the new password as DB_PASSWORD.'
} finally {
    $env:MYSQL_PWD = $previousPassword
    Remove-Item -LiteralPath $initFile -Force -ErrorAction SilentlyContinue
    if ($null -eq $resetServer -or $resetServer.HasExited) {
        Start-Service -Name MySQL80
    } else {
        Write-Warning 'The reset server is still running. Close it before starting the MySQL80 service.'
    }
    $password = $null
    $confirmed = $null
    $escaped = $null
}
