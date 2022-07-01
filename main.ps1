
param()

#region java setup
<#
.SYNOPSIS
get the url to the download page for the right version of Zulu Java for this machine. 
assumes windows os

.PARAMETER Version
filter value for the java version

.PARAMETER Package
filter value for the java package

.OUTPUTS
url to the zulu download page
#>
function Get-AzulDownloadPageUrl(
    [string] [ValidateNotNullOrEmpty()] $Version,
    [string] [ValidateNotNullOrEmpty()] $Package
) {
    # try to find the right architecture for zulu jdk
    $is64Bit = [System.Environment]::Is64BitOperatingSystem
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($is64Bit) {
        # could be amd64 or arm64
        if ($arch -ieq "AMD64") {
            $zuluArch = "x86-64-bit"
        }
        elseif ($arch -ieq "ARM64") {
            $zuluArch = "arm-64-bit"
        }
        else {
            throw "unsupported system architecture: '$arch' is64Bit = $is64Bit"
        }
    }
    else {
        # only x86 is possible
        if ($arch -ieq "x86") {
            $zuluArch = "x86-32-bit"
        }
        else {
            throw "unsupported system architecture: '$arch' is64Bit = $is64Bit"
        }
    }

    # build url to pre- filtered download page
    return "https://www.azul.com/downloads/?version=$Version&os=windows&architecture=$zuluArch&package=$Package"
}

<#
.SYNOPSIS
check if azul jdk is installed.
if the jdk is not installed, guide the user through the setup process

.PARAMETER RootDirectory
java root directory patch

.PARAMETER AzulVersion
filter value for the azul jdk version, eg 'java-18-sts'

.OUTPUTS
full path to the java.exe file
#>
function Test-AzulJDKSetup(
    [string][ValidateNotNullOrEmpty()] $RootDirectory,
    [string] [ValidateNotNullOrEmpty()] $AzulVersion
) {
    # check if java is present
    $javaExePath = [System.IO.Path]::Combine($RootDirectory, "bin", "java.exe")
    if (Test-Path -Path $javaExePath) {
        Write-Debug "azul java found at '$javaExePath'"
        return $javaExePath
    }

    # java not present, guide user to download the right package
    Write-Host @"

Hi there, 
it seems like we're missing the right java version to build revanced!
But don't worry, you can install it in just a few minutes.

First, please visit the following link and download the latest Azul Zulu JDK.
You may have to scroll to the bottom of the page to get to the download button.
Also, please make sure to download the .zip version. 

Download Page: $( Get-AzulDownloadPageUrl -Version $AzulVersion -Package "jdk" )


After you're finished downloading, please drag & drop the zip file into this window and press <Enter>.
"@
    while ($true) {
        $azulZipPath = Read-Host -Prompt "Azul JDK zip"
        if ([string]::IsNullOrEmpty($azulZipPath) -or 
            (-not (Test-Path -Path $azulZipPath -PathType Leaf)) -or
            ([System.IO.Path]::GetExtension($azulZipPath) -ine ".zip")) {
            Write-Host "sorry, but the file you provided could not be found or is not valid. please try again" -ForegroundColor Red
            continue
        }
        break
    }

    # delete any previous installation
    Remove-Item -Path $RootDirectory -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

    # extract the package to the root directory
    Expand-Archive -Path $azulZipPath -DestinationPath $RootDirectory

    # zulu ships their zip with a subdir inside, so we need to unbox that
    if (-not (Test-Path -Path $javaExePath)) {
        Write-Debug "unboxing jdk files"
        $boxedDir = @(Get-ChildItem -Path $RootDirectory -Directory)[0]
        if ($null -eq $boxedDir) {
            throw "failed to unbox jdk files: boxed directory not found"
        }
        Move-Item -Path ([System.IO.Path]::Combine($RootDirectory, $boxedDir, "*")) -Destination $RootDirectory
    }

    return Test-AzulJDKSetup -RootDirectory $RootDirectory -AzulVersion $AzulVersion
}
#endregion

#region ADB binding
<#
.SYNOPSIS
get a list of all attached ADB devices

.PARAMETER ADBExe
path to the adb binary

.OUTPUTS
an array of attached devices [{name,kind}]
#>
function Get-ADBDevices(
    [string] [ValidateNotNullOrEmpty()] $ADBExe
) {
    # invoke 'adb devices' 
    # create process information
    Write-Debug "running adb devices"
    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName = $ADBExe
    $procInfo.Arguments = "devices"
    $procInfo.RedirectStandardError = $true
    $procInfo.RedirectStandardOutput = $true
    $procInfo.UseShellExecute = $false

    # create the process and start it
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $procInfo
    $proc.Start() | Out-Null
    $proc.WaitForExit()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    Write-Debug "RC = $($proc.ExitCode)"
    Write-Debug "STDOUT = $stdout"
    Write-Debug "STDERR = $stderr"

    # find all devices listed
    $devices = @()
    ("$stdout `n $stderr").Split(@("`r`n", "`r", "`n"), [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
        # on each line, check for output format
        Write-Debug "parse line '$_'"
        if ($_.Trim() -match "^([\w-]+)\s*((?:device)|(?:unauthorized)|(?:offline))$") {
            $name = $Matches[1]
            $kind = $Matches[2]
            if ((-not [string]::IsNullOrWhiteSpace($name)) -and (-not [string]::IsNullOrWhiteSpace($kind))) {
                $devices += [PSCustomObject]@{
                    name = $name
                    kind = $kind
                }
            }
        }
    }

    return $devices
}
#endregion

#region ReVanced setup
<#
.SYNOPSIS
get information about a release on a public github repository using the github api

.PARAMETER Repository
the slug of the respository, eg. 'torvalds/linux'

.PARAMETER Tag
tag of the release to get, or 'latest' to get the latest release.
Tag name must match exactly

.OUTPUTS
response object, see https://docs.github.com/en/rest/releases/releases#get-a-release
#>
function Get-GithubReleaseInfo(
    [string] [ValidateNotNullOrEmpty()] $Repository, 
    [string] [ValidateNotNullOrEmpty()] $Tag = "latest"
) {
    # prepare target url
    if ($Tag -ieq "latest") {
        $url = "https://api.github.com/repos/$Repository/releases/latest"
    }
    else {
        $url = "https://api.github.com/repos/$Repository/releases/tags/$Tag"
    }

    # query api response
    Write-Debug "get release info from '$url'"
    $response = Invoke-RestMethod -Uri $url -ErrorAction Stop
    if ($null -eq $response) {
        throw "no release info was returned by github api"
    }

    Write-Debug "found info for relese tag $($response.tag_name)"
    return $response
}

<#
.SYNOPSIS
Get the download url for a github release assets matching a given name pattern

.PARAMETER ReleaseInfo
release information, from Get-GithubReleaseInfo

.PARAMETER Pattern
pattern to match agains the asset name

.OUTPUTS
the download url found
#>
function Find-GithubReleaseAssetUrl(
    [Parameter(ValueFromPipeline)] [ValidateNotNull()] $ReleaseInfo,
    [regex] [ValidateNotNull()] $Pattern
) {
    return @($ReleaseInfo.assets | Where-Object {
            return (
            (-not [string]::IsNullOrEmpty($_.name)) -and
            (-not [string]::IsNullOrEmpty($_.browser_download_url)) -and
            ($_.name -match $Pattern)
            )
        })[0].browser_download_url
}

<#
.SYNOPSIS
Download and save a file

.PARAMETER Url
the url to download from

.PARAMETER FilePath
the path to save the file to. if the file exists, it will be overwritten.
must be a full path, including file name and extension
#>
function Save-FileTo(
    [string] [Parameter(ValueFromPipeline)] [ValidateNotNullOrEmpty()] $Url,
    [string][ValidateNotNullOrEmpty()] $FilePath
) {
    # delete file before download
    if (Test-Path -Path $FilePath -PathType Leaf) {
        Remove-Item -Path $FilePath -Force -ErrorAction Stop
    }

    # download the file
    Write-Debug "save $Url to $FilePath"
    (New-Object System.Net.WebClient).DownloadFile($Url, $FilePath)
}

<#
.SYNOPSIS
download the lastest revanced prebuilds from github releases

.PARAMETER RootDirectory
root directory for the downloaded files to be saved to

.PARAMETER Vendor
vendor of the revanced assemblies == the name of the github account or organisation

.OUTPUTS
a object containing the full paths to the downloaded files: {cli, integrations, patches}
#>
function Get-ReVancedLatest(
    [string][ValidateNotNullOrEmpty()] $RootDirectory,
    [string][ValidateNotNullOrEmpty()] $Vendor = "revanced"
) {
    # helper function to log tag of version to console from pipeline
    function Write-ReleaseTag([Parameter(ValueFromPipeline)] [ValidateNotNull()] $ReleaseInfo) {
        Write-Host ($ReleaseInfo.tag_name)
        return $ReleaseInfo
    }

    # prepare root dir
    if (-not (Test-Path -Path $RootDirectory -PathType Container)) {
        New-Item -Path $RootDirectory -ItemType Directory -ErrorAction Stop | Out-Null
    }

    # prepare download paths
    $cliPath = [System.IO.Path]::Combine($RootDirectory, "revanced-cli.jar")
    $integrationsPath = [System.IO.Path]::Combine($RootDirectory, "revanced-integrations.apk")
    $patchesPath = [System.IO.Path]::Combine($RootDirectory, "revanced-patches.jar")

    # download revanced cli, integrations and patches
    Write-Host "downloading $Vendor/revanced-cli... " -NoNewline
    Get-GithubReleaseInfo -Repository "$Vendor/revanced-cli" `
    | Write-ReleaseTag `
    | Find-GithubReleaseAssetUrl -Pattern "revanced-cli.*\.jar" `
    | Save-FileTo -FilePath $cliPath

    Write-Host "downloading $Vendor/revanced-integrations... " -NoNewline
    Get-GithubReleaseInfo -Repository "$Vendor/revanced-integrations" `
    | Write-ReleaseTag `
    | Find-GithubReleaseAssetUrl -Pattern ".*\.apk" `
    | Save-FileTo -FilePath $integrationsPath

    Write-Host "downloading $Vendor/revanced-patches... " -NoNewline
    Get-GithubReleaseInfo -Repository "$Vendor/revanced-patches" `
    | Write-ReleaseTag `
    | Find-GithubReleaseAssetUrl -Pattern "revanced-patches.*\.jar" `
    | Save-FileTo -FilePath $patchesPath

    # validate all files are downloaded
    if ((Test-Path -Path $cliPath -PathType Leaf) -and
        (Test-Path -Path $integrationsPath -PathType Leaf) -and
        (Test-Path -Path $patchesPath -PathType Leaf) ) {
        return [PSCustomObject]@{
            cli          = $cliPath
            integrations = $integrationsPath
            patches      = $patchesPath
        }
    }
    else {
        throw "some files were not found after the download finished"
    }
}
#endregion

#region ReVanced CLI binding
<#
.SYNOPSIS
parse available patches from the output of revanced-cli --list option 

.DESCRIPTION
Long description

.PARAMETER CliOutput
output of the cli with --list option

.OUTPUTS
a array of available patches: [{name,description}]
#>
function Get-AvailablePatches(
    [string] [Parameter(ValueFromPipeline)] [ValidateNotNullOrEmpty()] $CliOutput
) {
    # split output into lines, process line- by- line
    $patches = @()
    $CliOutput.Split(@("`r`n", "`r", "`n"), [StringSplitOptions]::None) | ForEach-Object {
        # on each line, check for output format
        Write-Debug "parse line '$_'"
        if ($_ -match "INFORMATION: ?([\w-]+): ?([\w .,()`"]+)") {
            $name = $Matches[1]
            $desc = $Matches[2]
            if ((-not [string]::IsNullOrWhiteSpace($name)) -and (-not [string]::IsNullOrWhiteSpace($desc))) {
                $patches += [PSCustomObject]@{
                    name        = $name
                    description = $desc
                }
            }
        }
    }

    return $patches
}

<#
.SYNOPSIS
create a new cli process

.PARAMETER JavaExePath
path of the java.exe to use

.PARAMETER BaseApkPath
path to the base apk path

.PARAMETER OutputApkPath
path the patched apk is output to

.PARAMETER TempDirectory
path to the temporary directory the cli should use

.PARAMETER ReVancedPaths
revanced binaries paths. {cli,patches,integrations}

.PARAMETER ExtraArguments
a list of extra arguments to append to the argument list

.OUTPUTS
a reference to the cli process, but not yet started
#>
function New-CliProcess(
    [string] [ValidateNotNullOrEmpty()] $JavaExePath,
    [string] [ValidateNotNullOrEmpty()] $BaseApkPath,
    [string] [ValidateNotNullOrEmpty()] $OutputApkPath,
    [string] [ValidateNotNullOrEmpty()] $TempDirectory,
    [ValidateNotNull()] $ReVancedPaths,
    [string] [ValidateNotNull()] $ExtraArguments = ""
) {
    # build argument list
    $procArgs = (@(
            "--show-version",
            "-jar `"$($ReVancedPaths.cli)`"",
            "--apk `"$BaseApkPath`"",
            "--out `"$OutputApkPath`"",
            "--bundles `"$($ReVancedPaths.patches)`"",
            "--merge `"$($ReVancedPaths.integrations)`"",
            "--temp-dir `"$TempDirectory`"", 
            "--clean",
            $ExtraArguments
        ) -join " ")

    # create process information
    Write-Debug "cli cmdline = '$JavaExePath $procArgs'"
    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName = $JavaExePath
    $procInfo.Arguments = $procArgs
    $procInfo.RedirectStandardError = $true
    $procInfo.RedirectStandardOutput = $true
    $procInfo.UseShellExecute = $false

    # create the process without starting
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $procInfo
    return $proc
}

<#
.SYNOPSIS
invoke the cli, list all available patches, and return a list of patches

.PARAMETER JavaExePath
path of the java.exe to use

.PARAMETER BaseApkPath
path to the base apk path

.PARAMETER TempDirectory
path to the temporary directory the cli should use

.PARAMETER ReVancedPaths
revanced binaries paths. {cli,patches,integrations}

.OUTPUTS
a array of available patches: [{name,description}]
#>
function Invoke-GetAvailablePatches(
    [string] [ValidateNotNullOrEmpty()] $JavaExePath,
    [string] [ValidateNotNullOrEmpty()] $BaseApkPath,
    [string] [ValidateNotNullOrEmpty()] $TempDirectory,
    [ValidateNotNull()] $ReVancedPaths
) {
    # the cli always requires a output path, so we create a dummy in temp
    $outputApkDummy = [System.IO.Path]::Combine($TempDirectory, "dummy-out.apk")

    # create cli process with --list option
    $proc = New-CliProcess -JavaExePath $JavaExePath `
        -BaseApkPath $BaseApkPath `
        -OutputApkPath $outputApkDummy `
        -TempDirectory $TempDirectory `
        -ReVancedPaths $ReVancedPaths `
        -ExtraArguments "--list"
    
    # start the process and capture output
    $proc.Start() | Out-Null
    $proc.WaitForExit()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    Write-Debug "RC = $($proc.ExitCode)"
    Write-Debug "STDOUT = $stdout"
    Write-Debug "STDERR = $stderr"

    # parse patches from stdout and stderr
    return ("$stdout `n $stderr" | Get-AvailablePatches)
}

<#
.SYNOPSIS
invoke the cli, and apply all selected patches

.PARAMETER JavaExePath
path of the java.exe to use

.PARAMETER BaseApkPath
path to the base apk path

.PARAMETER OutputApkPath
path the patched apk is output to

.PARAMETER TempDirectory
path to the temporary directory the cli should use

.PARAMETER ReVancedPaths
revanced binaries paths. {cli,patches,integrations}

.PARAMETER ExcludedPatches
a array of the patches to exclude

.PARAMETER DeployDeviceName
adb name of the device to deploy on. if null, will not deploy

.OUTPUTS
a reference to the current cli process
#>
function Invoke-ApplyPatches(
    [string] [ValidateNotNullOrEmpty()] $JavaExePath,
    [string] [ValidateNotNullOrEmpty()] $BaseApkPath,
    [string] [ValidateNotNullOrEmpty()] $OutputApkPath,
    [string] [ValidateNotNullOrEmpty()] $TempDirectory,
    [ValidateNotNull()] $ReVancedPaths,
    [string[]] [ValidateNotNull()] $ExcludedPatches,
    [string] $DeployDeviceName = $null,
    [string] $KeystorePath = $null
) {    
    # create args
    $allArgs = (@($ExcludedPatches | ForEach-Object { "-e $_" }) -join " ")
    if (-not [string]::IsNullOrWhiteSpace($DeployDeviceName)) {
        $allArgs = "$allArgs --deploy-on $DeployDeviceName"
    }
    if (-not [string]::IsNullOrWhiteSpace($KeystorePath)) {
        $allArgs = "$allArgs --keystore `"$KeystorePath`""
    }

    # create cli process with -
    $proc = New-CliProcess -JavaExePath $JavaExePath `
        -BaseApkPath $BaseApkPath `
        -OutputApkPath $OutputApkPath `
        -TempDirectory $TempDirectory `
        -ReVancedPaths $ReVancedPaths `
        -ExtraArguments $allArgs
    
    # start the process
    $proc.Start() | Out-Null
    return $proc
}
#endregion

<#
.SYNOPSIS
guide the user through the patching process

.PARAMETER JavaExePath
path of the java.exe to use

.PARAMETER ADBExe
path to the adb binary

.PARAMETER TempDirectory
path to the temporary directory the cli should use

.PARAMETER ReVancedPaths
revanced binaries paths. {cli,patches,integrations}
#>
function Start-GuidedPatching(
    [string] [ValidateNotNullOrEmpty()] $JavaExePath,
    [string] [ValidateNotNullOrEmpty()] $ADBExe,
    [string] [ValidateNotNullOrEmpty()] $TempDirectory,
    [ValidateNotNull()] $ReVancedPaths
) {

    # get base APK from user
    # check: not empty input + exists + is .apk file
    Write-Host @"

Hey there! 
Before we can get started patching, you'll have to provide a base apk to patch. 
To find the right apk, use your preferred search engine (like google, duckduckgo or even bing) and search for something like 'youtube apk download'.
A good source for apks is A***irror.com, but other sites might work as well. 

Once you found the right page, make sure you download version indicated on the revanced-documentation page (https://github.com/revanced/revanced-documentation/wiki/Prerequisites).
Also, please make sure you download a single .APK, and not something like a .APKS file.

Once you're done downloading, drag&drop the .APK file into this window.
"@
    while ($true) {
        $baseApkPath = Read-Host -Prompt "Base APK"
        if ([string]::IsNullOrEmpty($baseApkPath) -or 
            (-not (Test-Path -Path $baseApkPath -PathType Leaf)) -or
            ([System.IO.Path]::GetExtension($baseApkPath) -ine ".apk")) {
            Write-Host "sorry, but the file you provided could not be found or is not valid. please try again" -ForegroundColor Red
            continue
        }
        break
    }

    # build output path from base
    $outputApkPath = [System.IO.Path]::Combine($PSScriptRoot, [System.IO.Path]::GetFileNameWithoutExtension($baseApkPath) + "_patched.apk")

    # get all available patches, and let user decide what patches to exclude
    $allPatches = Invoke-GetAvailablePatches -JavaExePath $JavaExePath `
        -BaseApkPath $baseApkPath `
        -ReVancedPaths $ReVancedPaths `
        -TempDirectory $TempDirectory
    Write-Debug "got $($allPatches.Length) patches"
    Write-Host "Please select all patches you wish to EXCLUDE, then click OK"
    $excludePatches = @( $allPatches | Out-GridView -Title "select patches to EXCLUDE" -PassThru | ForEach-Object { $_.name } )
    Write-Debug "exclude [ $($excludePatches -join ", ") ]"

    # double- check if microg patch is not selected
    $microGPatchName = "microg-support"
    if ($excludePatches -contains $microGPatchName) {
        Write-Host @"

It looks like you excluded the '$microGPatchName' patch! 
This is fine as long as your phone is rooted.
If installation fails, please retry with the '$microGPatchName' patch included

"@ -ForegroundColor Red
    }

    # let user provide a keystore file
    Write-Host @"

do you have a keystore file you wish to use?
If you don't have one, just press <ENTER>
(ReVanced automatically creates one when patching, so if you still have that one drag&drop it here)
"@
    $keystorePath = Read-Host -Prompt "Keystore File"
    if (([string]::IsNullOrWhiteSpace($keystorePath)) -or (-not (Test-Path -Path $keystorePath -PathType Leaf))) {
        $keystorePath = $null
    }
    
    # let user choose on what device to install on
    $deployTarget = Start-GuidedDeviceSelection -ADBExe $ADBExe

    # start patching
    Write-Host "patching..."
    Invoke-ApplyPatches -JavaExePath $JavaExePath `
        -BaseApkPath $baseApkPath `
        -ReVancedPaths $ReVancedPaths `
        -TempDirectory $TempDirectory `
        -ExcludedPatches $excludePatches `
        -OutputApkPath $outputApkPath `
        -DeployDeviceName $deployTarget `
        -KeystorePath $keystorePath `
    | Write-PatchingStatus
}

<#
.SYNOPSIS
guide the user through adb device selection

.PARAMETER ADBExe
path to the adb binary

.OUTPUTS
the selected device name, or $null if none selected
#>
function Start-GuidedDeviceSelection(
    [string] [ValidateNotNullOrEmpty()] $ADBExe
) {
    Write-Host @"

we're almost ready for patching. 
But before that, do you wish to directly install ReVanced on your phone?
(You'll need to connect your phone to the PC and enable ADB)
"@
    if ((Read-Host -Prompt "Deploy on device? (y/N)").Trim().ToLower().StartsWith("y")) {
        # prompt the user to connect their phone and enable usb debugging
        Write-Host @"

Ok, then please connect your phone to your PC using a USB- Cable. 
If you don't have USB Debugging enabled, please do so now. 
You can find the setting in the developer options. For more detailed instructions, please use your favorite search engine.

Once you connected your phone, the guide will continue automatically
"@
    
        # poll for attached devices, only stop if there is at least one device that is authorized
        Write-Host "Waiting for device" -NoNewline
        while ($true) {
            # get devices
            Start-Sleep -Seconds 2
            Write-Host "." -NoNewline
            $adbDevices = @( Get-ADBDevices -ADBExe $ADBExe )
            
            # if there is at least one device that is online, end the wait
            $authDevices = @( $adbDevices | Where-Object { $_.kind -ieq "device" } )
            if ($authDevices.Count -gt 0) {
                $targetName = $authDevices[0].name
                Write-Host "`nfound device $targetName"
                return $targetName
            }

            # if there are unauthorized devices, tell user to authorize
            #if (@( $adbDevices | Where-Object { $_.kind -ine "device" } ).Count -gt 0) {
            #    Write-Host "`nplease authorize USB Debugging"
            #}
        }
    }
        
    return $null
}

<#
.SYNOPSIS
Writes the process output to the console in real-time

.PARAMETER Process
the process to write the status of
#>
function Write-PatchingStatus(
    [System.Diagnostics.Process] [Parameter(ValueFromPipeline)] [ValidateNotNull()] $Process 
) {
    # print process information
    Write-Host "`n`n---- Patching Log ----"
    Write-Host @"

---- Commandline ----
$($Process.StartInfo.FileName) $($Process.StartInfo.Arguments)

---- Patching Log ----

"@

    #TODO currently only outputs stderr output
    do {
        Write-Host $Process.StandardError.ReadLine()
    }
    while (-not $Process.HasExited)

    Write-Host @"

---- Exit Code ----
$($Process.ExitCode)

"@
}

function Main() {
    # adb ships with the script, check if its actually present
    $adbExePath = [System.IO.Path]::Combine($PSScriptRoot, "adb.exe")
    if (-not (Test-Path -Path $adbExePath -PathType Leaf)) {
        throw "could not find adb.exe"
    }

    # setup azul jdk
    Write-Information "setup jdk..."
    $javaExePath = Test-AzulJDKSetup -RootDirectory ([System.IO.Path]::Combine($PSScriptRoot, "data", "jdk")) -AzulVersion "java-18-sts"

    # setup revanced binaries
    Write-Information "setup revanced..."
    $revancedPaths = Get-ReVancedLatest -RootDirectory ([System.IO.Path]::Combine($PSScriptRoot, "data", "revanced"))

    # start guided patching
    Write-Information "start patching..."
    Start-GuidedPatching -JavaExePath $javaExePath -ADBExe $adbExePath -ReVancedPaths $revancedPaths -TempDirectory ([System.IO.Path]::Combine($PSScriptRoot, "data", "temp"))

    # finished
    Write-Host @"

Finished!



"@
}
#$DebugPreference = "continue"
$InformationPreference = "continue"
Main
