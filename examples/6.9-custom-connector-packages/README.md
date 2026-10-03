# Custom Connector Packages for Login Enterprise 6.9

Build and upload a Custom Connector Package using PowerShell. Store connector
files centrally on the Appliance instead of copying them to each Launcher.

`Publish-CustomConnectorPackage.ps1` accepts either:

- A folder: creates a ZIP containing the folder's contents at the archive root.
- An existing ZIP: uploads it directly without changing its layout.

It creates a new package by default. Supply `PackageId` to replace an existing
package's contents and metadata. After upload, it retrieves and verifies the
stored metadata and returns the package ID, name, version, ZIP path, and operation.

## Scope

This example demonstrates packaging and Public API upload. The included
`sample-files/HelloWorld.txt` is a demonstration file, not a working connector.

The script does not configure or start Tests, execute a connector, install
dependencies, or validate connector compatibility. Build and validate your
connector using the [Custom Connector documentation](https://docs.loginvsi.com/login-enterprise/6.9/custom-connector).

This workflow is separate from the Windows 365 connector-script management
examples elsewhere in this repository.

## Requirements

- Windows PowerShell 5.1.
- Login Enterprise 6.9 with the v8-preview Public API.
- An Appliance HTTPS certificate trusted by the machine running the script.
- A System Access Token with permission to manage and read connector packages.
- A nonempty source folder or valid, unencrypted ZIP, no larger than 256 MB.

Using a package in an actual Test requires Launcher 6.9 or later. Package upload
itself does not require a Launcher.

## Try the demonstration

Run from this example directory. The script prompts for your token without
displaying it.

```powershell
$params = @{
    ApplianceUrl           = 'https://YOUR_APPLIANCE'
    SourcePath             = '.\sample-files'
    Name                   = 'Hello World Package Demo'
    Version                = '1.0.0'
    Description            = 'Packaging and upload demonstration only.'
    DefaultCommandTemplate = 'cmd.exe /c exit 1'
}

$result = .\Publish-CustomConnectorPackage.ps1 @params
$result | Format-List
```

The demonstration command intentionally exits with a failure code. Do not use
this sample as a connector in a running Test.

To upload an existing ZIP, set `SourcePath` to its path. The script preserves
the ZIP's existing folder structure.

## Publish your connector files

Replace the demonstration inputs with your validated connector files and
connection command. For example, if your connector's entry point is
`Connect.ps1` at the ZIP root:

```powershell
$params = @{
    ApplianceUrl           = 'https://YOUR_APPLIANCE'
    SourcePath             = 'C:\ConnectorFiles'
    Name                   = 'My Custom Connector'
    Version                = '1.0.0'
    Description            = 'Files for my validated custom connector.'
    DefaultCommandTemplate = 'powershell.exe -NoProfile -File "{packageRoot}\Connect.ps1"'
}

$result = .\Publish-CustomConnectorPackage.ps1 @params
$result
```

`Connect.ps1` is an illustrative filename; this repository does not supply it.
Use the command and arguments required by your own connector.

You can then select the uploaded package in a Test's Custom Connector settings.
Use `{packageRoot}` to reference its extracted directory on the Launcher.

## Replace an existing package

Use the package's existing ID explicitly:

```powershell
$params.PackageId = $result.PackageId
$params.SourcePath = 'C:\ConnectorFiles-v2.zip'
$params.Version = '1.0.1'

$result = .\Publish-CustomConnectorPackage.ps1 @params
$result
```

Replacing a package affects subsequent runs of Tests referencing it. Review
those Test assignments before replacement. A package cannot be edited while
a Test using it is running, or deleted while assigned to any Test.

## Behavior and validation

- Folder input gets a unique ZIP in the Windows temporary directory. The ZIP
  is retained, and its path is returned.
- Existing ZIP input is not modified.
- Local checks confirm ZIP structure, presence of files, and the size limit.
  The Appliance performs its own upload validation.
- The script verifies stored metadata; it does not validate connector behavior.
- Failures throw a terminating error. HTTP client and file resources are disposed.
- If verification fails after an upload, inspect the reported package ID before
  retrying; the upload may already have succeeded.
- Folder and existing-ZIP upload paths were validated on Login Enterprise 6.9.2
  using Windows PowerShell 5.1. Separate API checks verified replacement,
  package download integrity, and deletion. Real connector execution is outside
  this example's scope.

For actual Test use, install connector runtimes and dependencies on the Launcher
separately. Initial package downloads, including downloads after changes,
contribute to login time; account for those runs when comparing results.

## Documentation

- [Custom Connector Packages](https://docs.loginvsi.com/login-enterprise/6.9/custom-connector-packages)
- [Custom Connector](https://docs.loginvsi.com/login-enterprise/6.9/custom-connector)
- [Using the Public API](https://docs.loginvsi.com/login-enterprise/6.9/using-the-public-api)
