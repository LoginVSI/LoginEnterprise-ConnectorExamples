#Requires -Version 5.1
<#
.SYNOPSIS
Builds and publishes a Login Enterprise custom connector package.

.DESCRIPTION
Accepts a folder or existing ZIP. Folder contents are zipped at the archive
root. Creates a package, or replaces one when PackageId is supplied.
Uses the v8-preview Public API and requires trusted HTTPS.

This script manages package files and metadata. It does not configure or
run Tests, install connector dependencies, or validate connector behavior.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [uri]$ApplianceUrl,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DefaultCommandTemplate,

    [string]$Description = '',
    [string]$Token = '',
    [guid]$PackageId = [guid]::Empty
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem

$client = $null
$form = $null
$stream = $null
$request = $null
$response = $null
$metadataResponse = $null
$previousTls = [Net.ServicePointManager]::SecurityProtocol

try {
    if (-not $ApplianceUrl.IsAbsoluteUri -or $ApplianceUrl.Scheme -ne 'https') {
        throw 'ApplianceUrl must be an absolute HTTPS URL.'
    }
    if ($ApplianceUrl.Query -or $ApplianceUrl.Fragment -or $ApplianceUrl.UserInfo) {
        throw 'ApplianceUrl must not contain credentials, a query, or a fragment.'
    }

    $base = $ApplianceUrl.AbsoluteUri.TrimEnd('/') + '/publicApi/v8-preview'
    $method = 'POST'
    $endpoint = "$base/connector-packages"

    if ($PackageId -ne [guid]::Empty) {
        $method = 'PUT'
        $endpoint += "/$PackageId"
    }

    $source = Get-Item -LiteralPath $SourcePath
    if ($source.PSProvider.Name -ne 'FileSystem') {
        throw 'SourcePath must be a filesystem folder or ZIP.'
    }

    if ($source.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $source.FullName -File -Recurse -Force)
        if (-not $files.Count) {
            throw 'Source folder contains no files.'
        }

        $zipPath = Join-Path ([IO.Path]::GetTempPath()) (
            'LE-ConnectorPackage-' + [guid]::NewGuid().ToString('N') + '.zip'
        )
        $sourcePrefix = $source.FullName.TrimEnd('\') + '\'
        if ($zipPath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The temporary ZIP location must be outside the source folder.'
        }

        [IO.Compression.ZipFile]::CreateFromDirectory(
            $source.FullName,
            $zipPath,
            [IO.Compression.CompressionLevel]::Optimal,
            $false
        )
        Write-Verbose "Created ZIP: $zipPath"
    }
    else {
        if ($source.Extension -ne '.zip') {
            throw 'SourcePath must be a folder or a .zip file.'
        }
        $zipPath = $source.FullName
        Write-Verbose "Using existing ZIP: $zipPath"
    }

    if ((Get-Item -LiteralPath $zipPath).Length -gt 256MB) {
        throw 'ZIP exceeds the 256 MB package limit.'
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $fileEntries = @($archive.Entries | Where-Object { $_.Name })
        if (-not $fileEntries.Count) {
            throw 'ZIP contains no files.'
        }
    }
    finally {
        $archive.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        $secureToken = Read-Host 'System access token' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        try {
            $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            $secureToken.Dispose()
        }
    }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'A System Access Token is required.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    $client.DefaultRequestHeaders.Authorization =
        [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)

    $form = [Net.Http.MultipartFormDataContent]::new()
    $fields = @{
        Name                   = $Name
        Description            = $Description
        Version                = $Version
        DefaultCommandTemplate = $DefaultCommandTemplate
    }
    foreach ($field in $fields.GetEnumerator()) {
        $form.Add([Net.Http.StringContent]::new([string]$field.Value), $field.Key)
    }

    $stream = [IO.File]::OpenRead($zipPath)
    $fileContent = [Net.Http.StreamContent]::new($stream)
    $fileContent.Headers.ContentType =
        [Net.Http.Headers.MediaTypeHeaderValue]::new('application/zip')
    $form.Add($fileContent, 'file', [IO.Path]::GetFileName($zipPath))

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::new($method), $endpoint
    )
    $request.Content = $form

    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $expectedStatus = if ($method -eq 'POST') { 201 } else { 200 }

    if ([int]$response.StatusCode -ne $expectedStatus) {
        throw "$method returned HTTP $([int]$response.StatusCode): $responseText"
    }
    if ($method -eq 'POST') {
        $created = ConvertFrom-Json -InputObject $responseText
        $PackageId = [guid]$created.id
        if ($PackageId -eq [guid]::Empty) {
            throw 'Create response did not return a valid package ID.'
        }
    }

    Write-Verbose "Uploaded package: $PackageId"

    $metadataResponse = $client.GetAsync(
        "$base/connector-packages/$PackageId"
    ).GetAwaiter().GetResult()

    $metadataText = $metadataResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $metadataResponse.IsSuccessStatusCode) {
        throw "Metadata retrieval returned HTTP $([int]$metadataResponse.StatusCode): $metadataText"
    }

    $stored = ConvertFrom-Json -InputObject $metadataText
    if ($stored.name -ne $Name -or
        $stored.version -ne $Version -or
        $stored.description -ne $Description -or
        $stored.defaultCommandTemplate -ne $DefaultCommandTemplate) {
        throw 'Stored metadata does not match the uploaded values.'
    }

    [pscustomobject]@{
        PackageId = $PackageId
        Name      = $stored.name
        Version   = $stored.version
        ZipPath   = $zipPath
        Operation = if ($method -eq 'POST') { 'Create' } else { 'Replace' }
    }
}
catch {
    $messages = @()
    $exception = $_.Exception
    while ($null -ne $exception) {
        $messages += $exception.Message
        $exception = $exception.InnerException
    }
    $message = $messages -join ' -> '
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $message = $message.Replace($Token, '[REDACTED]')
    }
    if ($PackageId -ne [guid]::Empty) {
        $message += " Package ID: $PackageId. Review its state before retrying."
    }
    throw $message
}
finally {
    try {
        if ($metadataResponse) { $metadataResponse.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($form) { $form.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
        $Token = $null
    }
}
