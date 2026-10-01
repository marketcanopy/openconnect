[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9-]+$')]
    [string] $Region,

    [Parameter(Mandatory)]
    [string] $ResourceGroup,

    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $NamePrefix = "openconnector-$Region",
    [string] $AdminUsername = 'connectoradmin',
    [string] $SshPublicKeyPath,
    [Parameter(Mandatory)]
    [string] $SshSourceCidr,
    [string] $VnetAddressPrefix = '10.253.0.0/16',
    [string] $VnetIpv6AddressPrefix,
    [string] $SubnetAddressPrefix = '10.253.0.0/24',
    [string] $SubnetIpv6AddressPrefix,
    [string] $VmSize = 'Standard_D4s_v5',
    [string] $ConnectorHostname = 'connector.marketcanopy.com',
    [string] $AcmeEmail = 'help@marketcanopy.com',
    [string] $ConnectorImage = 'ghcr.io/oomol-lab/open-connector@sha256:61e5e29a9ae7d8e817e8050d062ed57134e069cea3e7eef7cb15349c11b7a76d',
    [string] $ConnectorEncryptionKey,
    [string] $ConnectorAdminToken,
    [string] $ConnectorRuntimeToken,
    [switch] $Apply,
    [switch] $Confirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'

if ($Apply -xor $Confirm) {
    throw 'Azure mutation requires both -Apply and -Confirm.'
}
if ([string]::IsNullOrWhiteSpace($VnetIpv6AddressPrefix) -or [string]::IsNullOrWhiteSpace($SubnetIpv6AddressPrefix)) {
    throw 'VnetIpv6AddressPrefix and SubnetIpv6AddressPrefix are required. Use the IPv6 prefix allocated for this Azure VNet.'
}
if ($ConnectorImage -notmatch '^ghcr\.io/oomol-lab/open-connector@sha256:[0-9a-f]{64}$') {
    throw 'ConnectorImage must be pinned to an immutable ghcr.io/oomol-lab/open-connector sha256 digest.'
}
if ($ConnectorHostname -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$') {
    throw 'ConnectorHostname must be a fully-qualified DNS hostname.'
}
if ($AcmeEmail -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
    throw 'AcmeEmail must be a valid email address.'
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AllowEmpty
    )
    # Windows PowerShell 5.1 turns redirected native stderr into throwing
    # ErrorRecords when ErrorActionPreference is Stop; relax it around az.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $result = & az @Arguments 2>&1
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($result -join [Environment]::NewLine)"
    }
    $text = ($result -join [Environment]::NewLine).Trim()
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($text)) {
        throw "az $($Arguments -join ' ') returned no output."
    }
    return $text
}

function New-RandomBytes {
    param([int] $ByteCount = 32)
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return $bytes
}

function New-RandomHex {
    param([int] $ByteCount = 32)
    $bytes = New-RandomBytes -ByteCount $ByteCount
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

function New-RandomBase64 {
    param([int] $ByteCount = 32)
    $bytes = New-RandomBytes -ByteCount $ByteCount
    return [Convert]::ToBase64String($bytes)
}

function Resolve-SshPublicKeyPath {
    param([string] $Candidate)
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) { $candidates += $Candidate }
    $candidates += @(
        (Join-Path $HOME '.ssh\id_ed25519.pub'),
        (Join-Path $HOME '.ssh\id_rsa.pub'),
        'C:\Users\dev\repos\opensips-server-vms\.secrets\opensips-vm-admin.pub'
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    throw 'No SSH public key found. Supply -SshPublicKeyPath explicitly.'
}

function Protect-SecretFile {
    param([Parameter(Mandatory)] [string] $Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
    )
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-EnvContent {
    param(
        [Parameter(Mandatory)] [string] $Hostname,
        [Parameter(Mandatory)] [string] $EncryptionKey,
        [Parameter(Mandatory)] [string] $AdminToken,
        [Parameter(Mandatory)] [string] $RuntimeToken
    )
    return @"
OOMOL_CONNECT_ORIGIN=https://$Hostname
OOMOL_CONNECT_ENCRYPTION_KEY=$EncryptionKey
OOMOL_CONNECT_ADMIN_TOKEN=$AdminToken
OOMOL_CONNECT_RUNTIME_TOKEN=$RuntimeToken
OOMOL_CONNECT_LOG_LEVEL=info
TZ=UTC
"@
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repositoryRoot 'infra\bicep\main.bicep'
$composePath = Join-Path $repositoryRoot 'infra\docker-compose.yml'
$caddyfilePath = Join-Path $repositoryRoot 'infra\Caddyfile'
foreach ($path in @($templatePath, $composePath, $caddyfilePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required deployment file not found: $path" }
}

$sshPublicKeyPath = Resolve-SshPublicKeyPath -Candidate $SshPublicKeyPath
$sshPublicKey = (Get-Content -Raw -LiteralPath $sshPublicKeyPath).Trim()
if ($sshPublicKey -notmatch '^ssh-(rsa|ed25519) ') {
    throw 'SshPublicKeyPath must contain one OpenSSH RSA or Ed25519 public key.'
}

$artifactDirectory = Join-Path $repositoryRoot ".artifacts\$Region"
$null = New-Item -ItemType Directory -Path $artifactDirectory -Force
$secretsPath = Join-Path $artifactDirectory 'openconnector-secrets.json'
$whatIfPath = Join-Path $artifactDirectory 'deployment.whatif.json'
$receiptPath = Join-Path $artifactDirectory 'deployment.receipt.json'
$parameterPath = [IO.Path]::GetTempFileName()
$remoteScriptPath = [IO.Path]::GetTempFileName()

try {
    $existingSecrets = $null
    if (Test-Path -LiteralPath $secretsPath -PathType Leaf) {
        $existingSecrets = Get-Content -Raw -LiteralPath $secretsPath | ConvertFrom-Json
    }

    $resolvedEncryptionKey = if (-not [string]::IsNullOrWhiteSpace($ConnectorEncryptionKey)) {
        $ConnectorEncryptionKey
    } elseif ($null -ne $existingSecrets -and -not [string]::IsNullOrWhiteSpace([string] $existingSecrets.encryptionKey)) {
        [string] $existingSecrets.encryptionKey
    } else {
        New-RandomBase64 -ByteCount 32
    }
    $resolvedAdminToken = if (-not [string]::IsNullOrWhiteSpace($ConnectorAdminToken)) {
        $ConnectorAdminToken
    } elseif ($null -ne $existingSecrets -and -not [string]::IsNullOrWhiteSpace([string] $existingSecrets.adminToken)) {
        [string] $existingSecrets.adminToken
    } else {
        New-RandomHex -ByteCount 32
    }
    $resolvedRuntimeToken = if (-not [string]::IsNullOrWhiteSpace($ConnectorRuntimeToken)) {
        $ConnectorRuntimeToken
    } elseif ($null -ne $existingSecrets -and -not [string]::IsNullOrWhiteSpace([string] $existingSecrets.runtimeToken)) {
        [string] $existingSecrets.runtimeToken
    } else {
        New-RandomHex -ByteCount 32
    }

    try {
        $decodedEncryptionKey = [Convert]::FromBase64String($resolvedEncryptionKey)
    } catch {
        throw 'ConnectorEncryptionKey must be a base64-encoded 32-byte key.'
    }
    if ($decodedEncryptionKey.Length -ne 32) {
        throw 'ConnectorEncryptionKey must decode to exactly 32 bytes.'
    }
    if ($resolvedAdminToken -notmatch '^[A-Za-z0-9._=-]{16,256}$') {
        throw 'ConnectorAdminToken must be 16-256 characters with no whitespace or shell metacharacters.'
    }
    if ($resolvedRuntimeToken -notmatch '^[A-Za-z0-9._=-]{16,256}$') {
        throw 'ConnectorRuntimeToken must be 16-256 characters with no whitespace or shell metacharacters.'
    }

    $secretDocument = [ordered]@{
        schemaVersion = 1
        createdAtUtc = if ($null -ne $existingSecrets -and $existingSecrets.createdAtUtc) { $existingSecrets.createdAtUtc } else { [DateTime]::UtcNow.ToString('o') }
        encryptionKey = $resolvedEncryptionKey
        adminToken = $resolvedAdminToken
        runtimeToken = $resolvedRuntimeToken
    }
    [IO.File]::WriteAllText($secretsPath, ($secretDocument | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    Protect-SecretFile -Path $secretsPath

    $account = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json') | ConvertFrom-Json
    if ($account.id -ne $SubscriptionId) {
        Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) -AllowEmpty | Out-Null
        $account = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json') | ConvertFrom-Json
    }
    if ($account.id -ne $SubscriptionId) {
        throw 'The active Azure account does not match SubscriptionId.'
    }
    $null = Invoke-AzCli -Arguments @('group', 'show', '--name', $ResourceGroup, '--output', 'json') | ConvertFrom-Json
    $null = Invoke-AzCli -Arguments @('bicep', 'build', '--file', $templatePath, '--stdout')

    $parameterValues = [ordered]@{
        location = $Region
        namePrefix = $NamePrefix
        vnetAddressPrefix = $VnetAddressPrefix
        vnetIpv6AddressPrefix = $VnetIpv6AddressPrefix
        subnetAddressPrefix = $SubnetAddressPrefix
        subnetIpv6AddressPrefix = $SubnetIpv6AddressPrefix
        adminUsername = $AdminUsername
        adminSshPublicKey = $sshPublicKey
        sshSourceCidr = $SshSourceCidr
        vmSize = $VmSize
        connectorHostname = $ConnectorHostname
        acmeEmail = $AcmeEmail
        connectorImage = $ConnectorImage
        connectorEncryptionKey = $resolvedEncryptionKey
        connectorAdminToken = $resolvedAdminToken
        connectorRuntimeToken = $resolvedRuntimeToken
    }
    $parameters = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{}
    }
    foreach ($entry in $parameterValues.GetEnumerator()) {
        $parameters.parameters[$entry.Key] = @{ value = $entry.Value }
    }
    [IO.File]::WriteAllText($parameterPath, ($parameters | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    Invoke-AzCli -Arguments @(
        'deployment', 'group', 'validate',
        '--resource-group', $ResourceGroup,
        '--name', "$NamePrefix-validate",
        '--template-file', $templatePath,
        '--parameters', "@$parameterPath",
        '--only-show-errors',
        '--output', 'none'
    ) -AllowEmpty | Out-Null

    $whatIf = Invoke-AzCli -Arguments @(
        'deployment', 'group', 'what-if',
        '--resource-group', $ResourceGroup,
        '--name', $NamePrefix,
        '--template-file', $templatePath,
        '--parameters', "@$parameterPath",
        '--result-format', 'ResourceIdOnly',
        '--no-pretty-print',
        '--output', 'json'
    )
    [IO.File]::WriteAllText($whatIfPath, $whatIf, [Text.UTF8Encoding]::new($false))

    if (-not $Apply) {
        Write-Host "Plan validated. Review $whatIfPath"
        Write-Host "Generated secrets are protected at $secretsPath"
        Write-Host 'No Azure resources were changed.'
        return
    }

    $vmName = "$NamePrefix-vm"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & az vm show --resource-group $ResourceGroup --name $vmName --output none 2>$null
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $vmAlreadyExists = ($LASTEXITCODE -eq 0)
    if (-not $vmAlreadyExists) {
        $deployment = Invoke-AzCli -Arguments @(
            'deployment', 'group', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $NamePrefix,
            '--template-file', $templatePath,
            '--parameters', "@$parameterPath",
            '--only-show-errors',
            '--output', 'json'
        ) | ConvertFrom-Json
        $outputs = $deployment.properties.outputs
        $vmName = [string] $outputs.vmName.value
        $vmResourceId = [string] $outputs.vmResourceId.value
        $publicIpv4ResourceId = [string] $outputs.publicIpv4ResourceId.value
        $publicIpv6ResourceId = [string] $outputs.publicIpv6ResourceId.value
        $publicDnsName = [string] $outputs.publicDnsName.value
    } else {
        $subscriptionPrefix = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.Network/publicIPAddresses"
        $publicIpv4ResourceId = "$subscriptionPrefix/$NamePrefix-pip"
        $publicIpv6ResourceId = "$subscriptionPrefix/$NamePrefix-pip6"
        $vmResourceId = Invoke-AzCli -Arguments @('vm', 'show', '--resource-group', $ResourceGroup, '--name', $vmName, '--query', 'id', '--output', 'tsv')
        $publicDnsName = Invoke-AzCli -Arguments @('network', 'public-ip', 'show', '--ids', $publicIpv4ResourceId, '--query', 'dnsSettings.fqdn', '--output', 'tsv')
        Write-Host "VM '$vmName' already exists; preserving immutable osProfile.customData and reconciling runtime files with Run Command."
    }

    $publicIpv4 = Invoke-AzCli -Arguments @('network', 'public-ip', 'show', '--ids', $publicIpv4ResourceId, '--query', 'ipAddress', '--output', 'tsv')
    $publicIpv6 = Invoke-AzCli -Arguments @('network', 'public-ip', 'show', '--ids', $publicIpv6ResourceId, '--query', 'ipAddress', '--output', 'tsv')
    if ([string]::IsNullOrWhiteSpace($publicIpv4) -or [string]::IsNullOrWhiteSpace($publicIpv6)) {
        throw 'Deployment did not return both public IPv4 and IPv6 addresses.'
    }

    $envContent = Get-EnvContent `
        -Hostname $ConnectorHostname `
        -EncryptionKey $resolvedEncryptionKey `
        -AdminToken $resolvedAdminToken `
        -RuntimeToken $resolvedRuntimeToken
    $envBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($envContent))
    $composeBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($composePath))
    $caddyContent = (Get-Content -Raw -LiteralPath $caddyfilePath).Replace('__ACME_EMAIL__', $AcmeEmail).Replace('__CONNECTOR_HOSTNAME__', $ConnectorHostname)
    $caddyBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($caddyContent))

    $remoteScript = @'
set -eu
install -d -m 0700 /etc/openconnector /var/lib/openconnector /var/lib/openconnector/data /var/lib/openconnector/caddy-data /var/lib/openconnector/caddy-config
for attempt in $(seq 1 90); do
  if test -x /usr/bin/docker && test -f /etc/openconnector/docker-compose.yml && test -f /etc/systemd/system/openconnector.service; then
    break
  fi
  sleep 10
done
test -x /usr/bin/docker
test -f /etc/openconnector/docker-compose.yml
test -f /etc/systemd/system/openconnector.service
printf '%s' '__ENV_BASE64__' | base64 -d > /etc/openconnector/.env
printf '%s' '__COMPOSE_BASE64__' | base64 -d > /etc/openconnector/docker-compose.yml
printf '%s' '__CADDY_BASE64__' | base64 -d > /etc/openconnector/Caddyfile
chown root:root /etc/openconnector/.env /etc/openconnector/docker-compose.yml /etc/openconnector/Caddyfile
chmod 0400 /etc/openconnector/.env
chmod 0444 /etc/openconnector/docker-compose.yml /etc/openconnector/Caddyfile
systemctl daemon-reload
systemctl enable openconnector.service
systemctl start docker.service
systemctl restart openconnector.service
for attempt in $(seq 1 90); do
  if docker compose --env-file /etc/openconnector/.env -f /etc/openconnector/docker-compose.yml exec -T caddy wget --quiet --output-document=- --header 'Authorization: Bearer __OPENCONNECTOR_ADMIN_TOKEN__' http://connector:3000/openapi.json >/dev/null; then
    echo OPENCONNECTOR_BOOTSTRAP_COMPLETE
    exit 0
  fi
  sleep 10
done
docker compose --env-file /etc/openconnector/.env -f /etc/openconnector/docker-compose.yml ps
exit 1
'@
    $remoteScript = $remoteScript.Replace('__ENV_BASE64__', $envBase64).Replace('__COMPOSE_BASE64__', $composeBase64).Replace('__CADDY_BASE64__', $caddyBase64).Replace('__OPENCONNECTOR_ADMIN_TOKEN__', $resolvedAdminToken)
    [IO.File]::WriteAllText($remoteScriptPath, $remoteScript.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $bootstrapResult = Invoke-AzCli -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroup,
        '--name', $vmName,
        '--command-id', 'RunShellScript',
        '--scripts', "@$remoteScriptPath",
        '--output', 'json'
    ) | ConvertFrom-Json
    $bootstrapMessage = ($bootstrapResult.value | ForEach-Object message) -join "`n"
    if ($bootstrapMessage -notmatch 'OPENCONNECTOR_BOOTSTRAP_COMPLETE') {
        throw "OpenConnector bootstrap failed:`n$bootstrapMessage"
    }

    $receipt = [ordered]@{
        schemaVersion = 1
        deployedAtUtc = [DateTime]::UtcNow.ToString('o')
        subscriptionId = $account.id
        resourceGroup = $ResourceGroup
        region = $Region
        deploymentName = $NamePrefix
        vmName = $vmName
        vmResourceId = $vmResourceId
        publicIpv4Address = $publicIpv4
        publicIpv4ResourceId = $publicIpv4ResourceId
        publicIpv6Address = $publicIpv6
        publicIpv6ResourceId = $publicIpv6ResourceId
        publicDnsName = $publicDnsName
        hostname = $ConnectorHostname
        connectorImage = $ConnectorImage
        certificateStatus = 'Caddy will obtain and renew the certificate after the hostname resolves to the reported addresses.'
        vmValidation = 'passed'
        secretsPath = $secretsPath
    }
    [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Host 'OpenConnector VM deployed and validated.'
    Write-Host "A record:     $ConnectorHostname -> $publicIpv4"
    Write-Host "AAAA record:  $ConnectorHostname -> $publicIpv6"
    Write-Host "Web console:  https://$ConnectorHostname"
    Write-Host "Credentials:  $secretsPath"
    Write-Host "Receipt:      $receiptPath"
}
finally {
    Remove-Item -LiteralPath $parameterPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $remoteScriptPath -Force -ErrorAction SilentlyContinue
}
