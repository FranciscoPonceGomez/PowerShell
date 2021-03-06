$Environment = Get-EnvironmentInformation

$packagingStrings = Import-PowerShellDataFile "$PSScriptRoot\packaging.strings.psd1"
$DebianDistributions = @("ubuntu.14.04", "ubuntu.16.04", "ubuntu.17.04", "debian.8", "debian.9")

function Start-PSPackage {
    [CmdletBinding(DefaultParameterSetName='Version',SupportsShouldProcess=$true)]
    param(
        # PowerShell packages use Semantic Versioning http://semver.org/
        [Parameter(ParameterSetName = "Version")]
        [string]$Version,

        [Parameter(ParameterSetName = "ReleaseTag")]
        [ValidatePattern("^v\d+\.\d+\.\d+(-\w+(\.\d+)?)?$")]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseTag,

        # Package name
        [ValidatePattern("^powershell")]
        [string]$Name = "powershell",

        # Ubuntu, CentOS, Fedora, macOS, and Windows packages are supported
        [ValidateSet("deb", "osxpkg", "rpm", "msi", "zip", "AppImage", "nupkg", "tar", "tar-arm")]
        [string[]]$Type,

        # Generate windows downlevel package
        [ValidateSet("win7-x86", "win7-x64", "win-arm", "win-arm64")]
        [ValidateScript({$Environment.IsWindows})]
        [string] $WindowsRuntime,

        [Switch] $Force,

        [Switch] $SkipReleaseChecks
    )

    DynamicParam {
        if ("zip" -eq $Type) {
            # Add a dynamic parameter '-IncludeSymbols' when the specified package type is 'zip' only.
            # The '-IncludeSymbols' parameter can be used to indicate that the package should only contain powershell binaries and symbols.
            $ParameterAttr = New-Object "System.Management.Automation.ParameterAttribute"
            $Attributes = New-Object "System.Collections.ObjectModel.Collection``1[System.Attribute]"
            $Attributes.Add($ParameterAttr) > $null

            $Parameter = New-Object "System.Management.Automation.RuntimeDefinedParameter" -ArgumentList ("IncludeSymbols", [switch], $Attributes)
            $Dict = New-Object "System.Management.Automation.RuntimeDefinedParameterDictionary"
            $Dict.Add("IncludeSymbols", $Parameter) > $null
            return $Dict
        }
    }

    End {
        $IncludeSymbols = $null
        if ($PSBoundParameters.ContainsKey('IncludeSymbols')) {
            log 'setting IncludeSymbols'
            $IncludeSymbols = $PSBoundParameters['IncludeSymbols']
        }

        # Runtime and Configuration settings required by the package
        ($Runtime, $Configuration) = if ($WindowsRuntime) {
            $WindowsRuntime, "Release"
        } elseif ($Type -eq "tar-arm") {
            New-PSOptions -Configuration "Release" -Runtime "Linux-ARM" -WarningAction SilentlyContinue | ForEach-Object { $_.Runtime, $_.Configuration }
        } else {
            New-PSOptions -Configuration "Release" -WarningAction SilentlyContinue | ForEach-Object { $_.Runtime, $_.Configuration }
        }

        if($Environment.IsWindows) {
            # Runtime will be one of win7-x64, win7-x86, "win-arm" and "win-arm64" on Windows.
            # Build the name suffix for universal win-plat packages.
            switch ($Runtime) {
                "win-arm"   { $NameSuffix = "win-arm32" }
                "win-arm64" { $NameSuffix = "win-arm64" }
                default     { $NameSuffix = $_ -replace 'win\d+', 'win' }
            }
        }

        log "Packaging RID: '$Runtime'; Packaging Configuration: '$Configuration'"

        $Script:Options = Get-PSOptions

        $crossGenCorrect = $false
        if ($Runtime -match "arm") {
            # crossgen doesn't support arm32/64
            $crossGenCorrect = $true
        }
        elseif ($Script:Options.CrossGen) {
            $crossGenCorrect = $true
        }

        $PSModuleRestoreCorrect = $false

        # Require PSModuleRestore for packaging without symbols
        # But Disallow it when packaging with symbols
        if (!$IncludeSymbols.IsPresent -and $Script:Options.PSModuleRestore) {
            $PSModuleRestoreCorrect = $true
        }
        elseif ($IncludeSymbols.IsPresent -and !$Script:Options.PSModuleRestore) {
            $PSModuleRestoreCorrect = $true
        }

        # Make sure the most recent build satisfies the package requirement
        if (-not $Script:Options -or                                ## Start-PSBuild hasn't been executed yet
            -not $crossGenCorrect -or                               ## Last build didn't specify '-CrossGen' correctly
            -not $PSModuleRestoreCorrect -or                        ## Last build didn't specify '-PSModuleRestore' correctly
            $Script:Options.Runtime -ne $Runtime -or                ## Last build wasn't for the required RID
            $Script:Options.Configuration -ne $Configuration -or    ## Last build was with configuration other than 'Release'
            $Script:Options.Framework -ne "netcoreapp2.0")          ## Last build wasn't for CoreCLR
        {
            # It's possible that the most recent build doesn't satisfy the package requirement but
            # an earlier build does.
            # It's also possible that the last build actually satisfies the package requirement but
            # then `Start-PSPackage` runs from a new PS session or `build.psm1` was reloaded.
            #
            # In these cases, the user will be asked to build again even though it's technically not
            # necessary. However, we want it that way -- being very explict when generating packages.
            # This check serves as a simple gate to ensure that the user knows what he is doing, and
            # also ensure `Start-PSPackage` does what the user asks/expects, because once packages
            # are generated, it'll be hard to verify if they were built from the correct content.
            $params = @('-Clean')
            $params += '-CrossGen'
            if (!$IncludeSymbols.IsPresent) {
                $params += '-PSModuleRestore'
            }

            $params += '-Runtime', $Runtime
            $params += '-Configuration', $Configuration

            throw "Please ensure you have run 'Start-PSBuild $params'!"
        }

        if($SkipReleaseChecks.IsPresent) {
            Write-Warning "Skipping release checks."
        }
        elseif(!$Script:Options.RootInfo.IsValid){
            throw $Script:Options.RootInfo.Warning
        }

        # If ReleaseTag is specified, use the given tag to calculate Vesrion
        if ($PSCmdlet.ParameterSetName -eq "ReleaseTag") {
            $Version = $ReleaseTag -Replace '^v'
        }

        # Use Git tag if not given a version
        if (-not $Version) {
            $Version = (git --git-dir="$PSScriptRoot/../../.git" describe) -Replace '^v'
        }

        $Source = Split-Path -Path $Script:Options.Output -Parent

        # If building a symbols package, we add a zip of the parent to publish
        if ($IncludeSymbols.IsPresent)
        {
            $publishSource = $Source
            $buildSource = Split-Path -Path $Source -Parent
            $Source = New-TempFolder
            $symbolsSource = New-TempFolder

            try
            {
                # Copy files which go into the root package
                Get-ChildItem -Path $publishSource | Copy-Item -Destination $Source -Recurse

                # files not to include as individual files.  These files will be included in the root package
                # pwsh.exe is just dotnet.exe renamed by dotnet.exe during the build.
                $toExclude = @(
                    'hostfxr.dll'
                    'hostpolicy.dll'
                    'libhostfxr.so'
                    'libhostpolicy.so'
                    'libhostfxr.dylib'
                    'libhostpolicy.dylib'
                    'Publish'
                    'pwsh.exe'
                    )
                # Copy file which go into symbols.zip
                Get-ChildItem -Path $buildSource | Where-Object {$toExclude -inotcontains $_.Name} | Copy-Item -Destination $symbolsSource -Recurse

                # Zip symbols.zip to the root package
                $zipSource = Join-Path $symbolsSource -ChildPath '*'
                $zipPath = Join-Path -Path $Source -ChildPath 'symbols.zip'
                $Script:Options | ConvertTo-Json -Depth 3 | Out-File -Encoding utf8 -FilePath (Join-Path -Path $source -ChildPath 'psoptions.json')
                Compress-Archive -Path $zipSource -DestinationPath $zipPath
            }
            finally
            {
                Remove-Item -Path $symbolsSource -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        log "Packaging Source: '$Source'"

        # Decide package output type
        if (-not $Type) {
            $Type = if ($Environment.IsLinux) {
                if ($Environment.LinuxInfo.ID -match "ubuntu") {
                    "deb", "nupkg"
                } elseif ($Environment.IsRedHatFamily) {
                    "rpm", "nupkg"
                } else {
                    throw "Building packages for $($Environment.LinuxInfo.PRETTY_NAME) is unsupported!"
                }
            } elseif ($Environment.IsMacOS) {
                "osxpkg", "nupkg"
            } elseif ($Environment.IsWindows) {
                "msi", "nupkg"
            }
            Write-Warning "-Type was not specified, continuing with $Type!"
        }
        log "Packaging Type: $Type"

        # Add the symbols to the suffix
        # if symbols are specified to be included
        if($IncludeSymbols.IsPresent -and $NameSuffix) {
            $NameSuffix = "symbols-$NameSuffix"
        }
        elseif ($IncludeSymbols.IsPresent) {
            $NameSuffix = "symbols"
        }

        switch ($Type) {
            "zip" {
                $Arguments = @{
                    PackageNameSuffix = $NameSuffix
                    PackageSourcePath = $Source
                    PackageVersion = $Version
                    Force = $Force
                }

                if ($PSCmdlet.ShouldProcess("Create Zip Package")) {
                    New-ZipPackage @Arguments
                }
            }
            "msi" {
                $TargetArchitecture = "x64"
                if ($Runtime -match "-x86") {
                    $TargetArchitecture = "x86"
                }

                $Arguments = @{
                    ProductNameSuffix = $NameSuffix
                    ProductSourcePath = $Source
                    ProductVersion = $Version
                    AssetsPath = "$PSScriptRoot\..\..\assets"
                    LicenseFilePath = "$PSScriptRoot\..\..\assets\license.rtf"
                    # Product Code needs to be unique for every PowerShell version since it is a unique identifier for the particular product release
                    ProductCode = New-Guid
                    ProductTargetArchitecture = $TargetArchitecture
                    Force = $Force
                }

                if ($PSCmdlet.ShouldProcess("Create MSI Package")) {
                    New-MSIPackage @Arguments
                }
            }
            "AppImage" {
                if ($IncludeSymbols.IsPresent) {
                    throw "AppImage does not support packaging '-IncludeSymbols'"
                }

                if ($Environment.IsUbuntu14) {
                    $null = Start-NativeExecution { bash -iex "$PSScriptRoot/../appimage.sh" }
                    $appImage = Get-Item powershell-*.AppImage
                    if ($appImage.Count -gt 1) {
                        throw "Found more than one AppImage package, remove all *.AppImage files and try to create the package again"
                    }
                    Rename-Item $appImage.Name $appImage.Name.Replace("-","-$Version-")
                } else {
                    Write-Warning "Ignoring AppImage type for non Ubuntu Trusty platform"
                }
            }
            'nupkg' {
                $Arguments = @{
                    PackageNameSuffix = $NameSuffix
                    PackageSourcePath = $Source
                    PackageVersion = $Version
                    PackageRuntime = $Runtime
                    PackageConfiguration = $Configuration
                    Force = $Force
                }

                if ($PSCmdlet.ShouldProcess("Create NuPkg Package")) {
                    New-NugetPackage @Arguments
                }
            }
            "tar" {
                $Arguments = @{
                    PackageSourcePath = $Source
                    Name = $Name
                    Version = $Version
                    Force = $Force
                }

                if ($PSCmdlet.ShouldProcess("Create tar.gz Package")) {
                    New-TarballPackage @Arguments
                }
            }
            "tar-arm" {
                $Arguments = @{
                    PackageSourcePath = $Source
                    Name = $Name
                    Version = $Version
                    Force = $Force
                    Architecture = "arm32"
                }

                if ($PSCmdlet.ShouldProcess("Create tar.gz Package")) {
                    New-TarballPackage @Arguments
                }
            }
            'deb' {
                $Arguments = @{
                    Type = 'deb'
                    PackageSourcePath = $Source
                    Name = $Name
                    Version = $Version
                    Force = $Force
                }
                foreach ($Distro in $Script:DebianDistributions) {
                    $Arguments["Distribution"] = $Distro
                    if ($PSCmdlet.ShouldProcess("Create DEB Package for $Distro")) {
                        New-UnixPackage @Arguments
                    }
                }
            }
            default {
                $Arguments = @{
                    Type = $_
                    PackageSourcePath = $Source
                    Name = $Name
                    Version = $Version
                    Force = $Force
                }

                if ($PSCmdlet.ShouldProcess("Create $_ Package")) {
                    New-UnixPackage @Arguments
                }
            }
        }

        if($IncludeSymbols.IsPresent)
        {
            # Source is a temporary folder when -IncludeSymbols is present.  So, we should remove it.
            Remove-Item -Path $Source -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-TarballPackage {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory)]
        [string] $PackageSourcePath,

        # Must start with 'powershell' but may have any suffix
        [Parameter(Mandatory)]
        [ValidatePattern("^powershell")]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Version,

        [Parameter()]
        [string] $Architecture = "x64",

        [switch] $Force
    )

    $packageName = "$Name-$Version-{0}-$Architecture.tar.gz"
    if ($Environment.IsWindows) {
        throw "Must be on Linux or macOS to build 'tar.gz' packages!"
    } elseif ($Environment.IsLinux) {
        $packageName = $packageName -f "linux"
    } elseif ($Environment.IsMacOS) {
        $packageName = $packageName -f "osx"
    }

    $packagePath = Join-Path -Path $PWD -ChildPath $packageName
    Write-Verbose "Create package $packageName"
    Write-Verbose "Package destination path: $packagePath"

    if (Test-Path -Path $packagePath) {
        if ($Force -or $PSCmdlet.ShouldProcess("Overwrite existing package file")) {
            Write-Verbose "Overwrite existing package file at $packagePath" -Verbose
            Remove-Item -Path $packagePath -Force -ErrorAction Stop -Confirm:$false
        }
    }

    if (Get-Command -Name tar -CommandType Application -ErrorAction Ignore) {
        if ($Force -or $PSCmdlet.ShouldProcess("Create tarball package")) {
            $options = "-czf"
            if ($PSBoundParameters.ContainsKey('Verbose') -and $PSBoundParameters['Verbose'].IsPresent) {
                # Use the verbose mode '-v' if '-Verbose' is specified
                $options = "-czvf"
            }

            try {
                Push-Location -Path $PackageSourcePath
                tar $options $packagePath .
            } finally {
                Pop-Location
            }

            if (Test-Path -Path $packagePath) {
                log "You can find the tarball package at $packagePath"
                return $packagePath
            } else {
                throw "Failed to create $packageName"
            }
        }
    } else {
        throw "Failed to create the package because the application 'tar' cannot be found"
    }
}

function New-TempFolder
{
    $tempPath = [System.IO.Path]::GetTempPath()

    $tempFolder = Join-Path -Path $tempPath -ChildPath ([System.IO.Path]::GetRandomFileName())
    if(!(Test-Path -Path $tempFolder))
    {
        $null = New-Item -Path $tempFolder -ItemType Directory
    }

    return $tempFolder
}

function New-PSSignedBuildZip
{
    param(
        [Parameter(Mandatory)]
        [string]$BuildPath,
        [Parameter(Mandatory)]
        [string]$SignedFilesPath,
        [Parameter(Mandatory)]
        [string]$DestinationFolder,
        [parameter(HelpMessage='VSTS variable to set for path to zip')]
        [string]$VstsVariableName
    )

    # Replace unsigned binaries with signed
    $signedFilesFilter = Join-Path -Path $signedFilesPath -ChildPath '*'
    Get-ChildItem -path $signedFilesFilter -Recurse -File | Select-Object -ExpandProperty FullName | Foreach-Object -Process {
        $relativePath = $_.Replace($signedFilesPath,'')
        $destination = Join-Path -Path $buildPath -ChildPath $relativePath
        log "replacing $destination with $_"
        Copy-Item -Path $_ -Destination $destination -force
    }

    # Remove '$signedFilesPath' now that signed binaries are copied
    if (Test-Path $signedFilesPath)
    {
        Remove-Item -Recurse -Force -Path $signedFilesPath
    }

    $name = split-path -Path $BuildPath -Leaf
    $zipLocationPath = Join-Path -Path $DestinationFolder -ChildPath "$name-signed.zip"
    Compress-Archive -Path $BuildPath\* -DestinationPath $zipLocationPath
    if ($VstsVariableName)
    {
        # set VSTS variable with path to package files
        log "Setting $VstsVariableName to $zipLocationPath"
        Write-Host "##vso[task.setvariable variable=$VstsVariableName]$zipLocationPath"
    }
    else
    {
        return $zipLocationPath
    }
}

function Expand-PSSignedBuild
{
    param(
        [Parameter(Mandatory)]
        [string]$BuildZip
    )

    $psModulePath = Split-Path -path $PSScriptRoot
    # Expand signed build
    $buildPath = Join-Path -path $psModulePath -childpath 'ExpandedBuild'
    $null = New-Item -path $buildPath -itemtype Directory -force
    Expand-Archive -path $BuildZip -destinationpath $buildPath -Force
    # Remove the zip file that contains only those files from the parent folder of 'publish'.
    # That zip file is used for compliance scan.
    Remove-Item -Path (Join-Path -Path $buildPath -ChildPath '*.zip') -Recurse

    $windowsExecutablePath = (Join-Path $buildPath -ChildPath 'pwsh.exe')

    Restore-PSModuleToBuild -PublishPath $buildPath

    $options = Get-Content -Path (Join-Path $buildPath -ChildPath 'psoptions.json') | ConvertFrom-Json
    $options.PSModuleRestore = $true

    if(Test-Path -Path $windowsExecutablePath)
    {
        $options.Output = $windowsExecutablePath
    }
    else
    {
        throw 'Could not find pwsh'
    }

    Set-PSOptions -Options $options
}

function New-UnixPackage {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("deb", "osxpkg", "rpm")]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$PackageSourcePath,

        # Must start with 'powershell' but may have any suffix
        [Parameter(Mandatory)]
        [ValidatePattern("^powershell")]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Version,

        # Package iteration version (rarely changed)
        # This is a string because strings are appended to it
        [string]$Iteration = "1",

        [Switch]
        $Force
    )

    DynamicParam {
        if ($Type -eq "deb") {
            # Add a dynamic parameter '-Distribution' when the specified package type is 'deb'.
            # The '-Distribution' parameter can be used to indicate which Debian distro this pacakge is targeting.
            $ParameterAttr = New-Object "System.Management.Automation.ParameterAttribute"
            $ValidateSetAttr = New-Object "System.Management.Automation.ValidateSetAttribute" -ArgumentList $Script:DebianDistributions
            $Attributes = New-Object "System.Collections.ObjectModel.Collection``1[System.Attribute]"
            $Attributes.Add($ParameterAttr) > $null
            $Attributes.Add($ValidateSetAttr) > $null

            $Parameter = New-Object "System.Management.Automation.RuntimeDefinedParameter" -ArgumentList ("Distribution", [string], $Attributes)
            $Dict = New-Object "System.Management.Automation.RuntimeDefinedParameterDictionary"
            $Dict.Add("Distribution", $Parameter) > $null
            return $Dict
        }
    }

    End {
        # Validate platform
        $ErrorMessage = "Must be on {0} to build '$Type' packages!"
        switch ($Type) {
            "deb" {
                if (!$Environment.IsUbuntu -and !$Environment.IsDebian) {
                    throw ($ErrorMessage -f "Ubuntu or Debian")
                }

                if ($PSBoundParameters.ContainsKey('Distribution')) {
                    $DebDistro = $PSBoundParameters['Distribution']
                } elseif ($Environment.IsUbuntu14) {
                    $DebDistro = "ubuntu.14.04"
                } elseif ($Environment.IsUbuntu16) {
                    $DebDistro = "ubuntu.16.04"
                } elseif ($Environment.IsUbuntu17) {
                    $DebDistro = "ubuntu.17.04"
                } elseif ($Environment.IsDebian8) {
                    $DebDistro = "debian.8"
                } elseif ($Environment.IsDebian9) {
                    $DebDistro = "debian.9"
                } else {
                    throw "The current Debian distribution is not supported."
                }

                # iteration is "debian_revision"
                # usage of this to differentiate distributions is allowed by non-standard
                $Iteration += ".$DebDistro"
            }
            "rpm" {
                if (!$Environment.IsRedHatFamily) {
                    throw ($ErrorMessage -f "Redhat Family")
                }
            }
            "osxpkg" {
                if (!$Environment.IsMacOS) {
                    throw ($ErrorMessage -f "macOS")
                }
            }
        }

        # Verify dependencies are installed and in the path
        Test-Dependencies

        $Description = $packagingStrings.Description

        # Suffix is used for side-by-side package installation
        $Suffix = $Name -replace "^powershell"
        if (!$Suffix) {
            Write-Verbose "Suffix not given, building primary PowerShell package!"
            $Suffix = $Version
        }

        # Setup staging directory so we don't change the original source directory
        $Staging = "$PSScriptRoot/staging"
        if ($pscmdlet.ShouldProcess("Create staging folder")) {
            New-StagingFolder -StagingPath $Staging
        }

        # Follow the Filesystem Hierarchy Standard for Linux and macOS
        $Destination = if ($Environment.IsLinux) {
            "/opt/microsoft/powershell/$Suffix"
        } elseif ($Environment.IsMacOS) {
            "/usr/local/microsoft/powershell/$Suffix"
        }

        # Destination for symlink to powershell executable
        $Link = if ($Environment.IsLinux) {
            "/usr/bin"
        } elseif ($Environment.IsMacOS) {
            "/usr/local/bin"
        }
        $linkSource = "/tmp/pwsh"

        if($pscmdlet.ShouldProcess("Create package file system"))
        {
            New-Item -Force -ItemType SymbolicLink -Path $linkSource -Target "$Destination/pwsh" >$null

            # Generate After Install and After Remove scripts
            $AfterScriptInfo = New-AfterScripts

            # there is a weird bug in fpm
            # if the target of the powershell symlink exists, `fpm` aborts
            # with a `utime` error on macOS.
            # so we move it to make symlink broken
            $symlink_dest = "$Destination/pwsh"
            $hack_dest = "./_fpm_symlink_hack_powershell"
            if ($Environment.IsMacOS) {
                if (Test-Path $symlink_dest) {
                    Write-Warning "Move $symlink_dest to $hack_dest (fpm utime bug)"
                    Move-Item $symlink_dest $hack_dest
                }
            }

            # Generate gzip of man file
            $ManGzipInfo = New-ManGzip

            # Change permissions for packaging
            Start-NativeExecution {
                find $Staging -type d | xargs chmod 755
                find $Staging -type f | xargs chmod 644
                chmod 644 $ManGzipInfo.GzipFile
                chmod 755 "$Staging/pwsh" # only the executable should be executable
            }
        }

        # Add macOS powershell launcher
        if($Type -eq "osxpkg")
        {
            if($pscmdlet.ShouldProcess("Add macOS launch application"))
            {
                # Generate launcher app folder
                $AppsFolder = New-MacOSLauncher -Version $Version
            }
        }

        $packageDependenciesParams = @{}
        if($DebDistro)
        {
            $packageDependenciesParams['Distribution']=$DebDistro
        }

        # Setup package dependencies
        $Dependencies = @(Get-PackageDependencies @packageDependenciesParams)

        $Arguments = Get-FpmArguments `
            -Name $Name `
            -Version $Version `
            -Iteration $Iteration `
            -Description $Description `
            -Type $Type `
            -Dependencies $Dependencies `
            -AfterInstallScript $AfterScriptInfo.AfterInstallScript `
            -AfterRemoveScript $AfterScriptInfo.AfterRemoveScript `
            -Staging $Staging `
            -Destination $Destination `
            -ManGzipFile $ManGzipInfo.GzipFile `
            -ManDestination $ManGzipInfo.ManFile `
            -LinkSource $LinkSource `
            -LinkDestination $Link `
            -AppsFolder $AppsFolder `
            -ErrorAction Stop

        # Build package
        try {
            if($pscmdlet.ShouldProcess("Create $type package")) {
                $Output = Start-NativeExecution { fpm $Arguments }
            }
        } finally {
            if ($Environment.IsMacOS) {
                if($pscmdlet.ShouldProcess("Cleanup macOS launcher"))
                {
                    Clear-MacOSLauncher
                }

                # this is continuation of a fpm hack for a weird bug
                if (Test-Path $hack_dest) {
                    Write-Warning "Move $hack_dest to $symlink_dest (fpm utime bug)"
                    Move-Item $hack_dest $symlink_dest
                }
            }
            if ($AfterScriptInfo.AfterInstallScript) {
                Remove-Item -erroraction 'silentlycontinue' $AfterScriptInfo.AfterInstallScript -Force
            }
            if ($AfterScriptInfo.AfterRemoveScript) {
                Remove-Item -erroraction 'silentlycontinue' $AfterScriptInfo.AfterRemoveScript -Force
            }
            Remove-Item -Path $ManGzipInfo.GzipFile -Force -ErrorAction SilentlyContinue
        }

        # Magic to get path output
        $createdPackage = Get-Item (Join-Path $PWD (($Output[-1] -split ":path=>")[-1] -replace '["{}]'))

        if ($Environment.IsMacOS) {
            if ($pscmdlet.ShouldProcess("Add distribution information and Fix PackageName"))
            {
                $createdPackage = New-MacOsDistributionPackage -FpmPackage $createdPackage
            }
        }

        if (Test-Path $createdPackage)
        {
            Write-Verbose "Created package: $createdPackage" -Verbose
            return $createdPackage
        }
        else
        {
            throw "Failed to create $createdPackage"
        }
    }
}

function New-MacOsDistributionPackage
{
    param(
        [Parameter(Mandatory,HelpMessage='The FileInfo of the file created by FPM')]
        [System.IO.FileInfo]$FpmPackage
    )

    if(!$Environment.IsMacOS)
    {
        throw 'New-MacOsDistributionPackage is only supported on macOS!'
    }

    $packageName = Split-Path -leaf -Path $FpmPackage

    # Create a temp directory to store the needed files
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tempDir -Force > $null

    $resourcesDir = Join-Path -path $tempDir -childPath 'resources'
    New-Item -ItemType Directory -Path $resourcesDir -Force > $null
    #Copy background file to temp directory
    $backgroundFile = Join-Path $PSScriptRoot "/../../assets/macDialog.png"
    Copy-Item -Path $backgroundFile -Destination $resourcesDir
    # Move the current package to the temp directory
    $tempPackagePath = Join-Path -path $tempDir -ChildPath $packageName
    Move-Item -Path $FpmPackage -Destination $tempPackagePath -Force

    # Add the OS information to the macOS package file name.
    $packageExt = [System.IO.Path]::GetExtension($FpmPackage.Name)
    $packageNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($FpmPackage.Name)

    $newPackageName = "{0}-{1}{2}" -f $packageNameWithoutExt, $script:Options.Runtime, $packageExt
    $newPackagePath = Join-Path $FpmPackage.DirectoryName $newPackageName

    # -Force is not deleting the NewName if it exists, so delete it if it does
    if ($Force -and (Test-Path -Path $newPackagePath))
    {
        Remove-Item -Force $newPackagePath
    }

    # Create the distribution xml
    $distributionXmlPath = Join-Path -Path $tempDir -ChildPath 'powershellDistribution.xml'

    # format distribution template with:
    # 0 - title
    # 1 - version
    # 2 - package path
    # 2 - minimum os version
    $PackagingStrings.OsxDistributionTemplate -f "PowerShell - $Version", $Version, $packageName, '10.12' | Out-File -Encoding ascii -FilePath $distributionXmlPath -Force

    log "Applying distribution.xml to package..."
    Push-Location $tempDir
    try
    {
        # productbuild is an xcode command line tool, and those tools are installed when you install brew
        Start-NativeExecution -sb {productbuild --distribution $distributionXmlPath --resources $resourcesDir $newPackagePath}
    }
    finally
    {
        Pop-Location
        Remove-item -Path $tempDir -Recurse -Force
    }

    return $newPackagePath
}
function Get-FpmArguments
{
    param(
        [Parameter(Mandatory,HelpMessage='Package Name')]
        [String]$Name,

        [Parameter(Mandatory,HelpMessage='Package Version')]
        [String]$Version,

        [Parameter(Mandatory)]
        [String]$Iteration,

        [Parameter(Mandatory,HelpMessage='Package description')]
        [String]$Description,

        # From start-PSPackage without modification, already validated
        # Values: deb, rpm, osxpkg
        [Parameter(Mandatory,HelpMessage='Installer Type')]
        [String]$Type,

        [Parameter(Mandatory,HelpMessage='Staging folder for installation files')]
        [String]$Staging,

        [Parameter(Mandatory,HelpMessage='Install path on target machine')]
        [String]$Destination,

        [Parameter(Mandatory,HelpMessage='The built and gzipped man file.')]
        [String]$ManGzipFile,

        [Parameter(Mandatory,HelpMessage='The destination of the man file')]
        [String]$ManDestination,

        [Parameter(Mandatory,HelpMessage='Symlink to powershell executable')]
        [String]$LinkSource,

        [Parameter(Mandatory,HelpMessage='Destination for symlink to powershell executable')]
        [String]$LinkDestination,

        [Parameter(HelpMessage='Packages required to install this package.  Not applicable for MacOS.')]
        [ValidateScript({
            if (!$Environment.IsMacOS -and $_.Count -eq 0)
            {
                throw "Must not be null or empty on this environment."
            }
            return $true
        })]
        [String[]]$Dependencies,

        [Parameter(HelpMessage='Script to run after the package installation.')]
        [AllowNull()]
        [ValidateScript({
            if (!$Environment.IsMacOS -and !$_)
            {
                throw "Must not be null on this environment."
            }
            return $true
        })]
        [String]$AfterInstallScript,

        [Parameter(HelpMessage='Script to run after the package removal.')]
        [AllowNull()]
        [ValidateScript({
            if (!$Environment.IsMacOS -and !$_)
            {
                throw "Must not be null on this environment."
            }
            return $true
        })]
        [String]$AfterRemoveScript,

        [Parameter(HelpMessage='AppsFolder used to add macOS launcher')]
        [AllowNull()]
        [ValidateScript({
            if ($Environment.IsMacOS -and !$_)
            {
                throw "Must not be null on this environment."
            }
            return $true
        })]
        [String]$AppsFolder
    )

    $Arguments = @(
        "--force", "--verbose",
        "--name", $Name,
        "--version", $Version,
        "--iteration", $Iteration,
        "--maintainer", "PowerShell Team <PowerShellTeam@hotmail.com>",
        "--vendor", "Microsoft Corporation",
        "--url", "https://microsoft.com/powershell",
        "--license", "MIT License",
        "--description", $Description,
        "--category", "shells",
        "-t", $Type,
        "-s", "dir"
    )
    if ($Environment.IsRedHatFamily) {
        $Arguments += @("--rpm-dist", "rhel.7")
        $Arguments += @("--rpm-os", "linux")
    }

    if ($Environment.IsMacOS) {
        $Arguments += @("--osxpkg-identifier-prefix", "com.microsoft")
    }

    foreach ($Dependency in $Dependencies) {
        $Arguments += @("--depends", $Dependency)
    }

    if ($AfterInstallScript) {
        $Arguments += @("--after-install", $AfterInstallScript)
    }

    if ($AfterRemoveScript) {
        $Arguments += @("--after-remove", $AfterRemoveScript)
    }

    $Arguments += @(
        "$Staging/=$Destination/",
        "$ManGzipFile=$ManDestination",
        "$LinkSource=$LinkDestination"
    )

    if($AppsFolder)
    {
        $Arguments += "$AppsFolder=/"
    }

    return $Arguments
}

function Test-Distribution
{
    param(
        [String]
        $Distribution
    )

    if ( ($Environment.IsUbuntu -or $Environment.IsDebian) -and !$Distribution )
    {
        throw "$Distribution is required for a Debian based distribution."
    }

    if($Script:DebianDistributions -notcontains $Distribution)
    {
        throw "$Distribution should be one of the following: $Script:DebianDistributions"
    }
    return $true
}
function Get-PackageDependencies
{
    param(
        [String]
        [ValidateScript({Test-Distribution -Distribution $_})]
        $Distribution
    )

    End {
        # These should match those in the Dockerfiles, but exclude tools like Git, which, and curl
        $Dependencies = @()
        if ($Environment.IsUbuntu -or $Environment.IsDebian) {
            $Dependencies = @(
                "libc6",
                "libcurl3",
                "libgcc1",
                "libgssapi-krb5-2",
                "liblttng-ust0",
                "libstdc++6",
                "libunwind8",
                "libuuid1",
                "zlib1g"
            )

            switch ($Distribution) {
                "ubuntu.14.04" { $Dependencies += @("libssl1.0.0", "libicu52") }
                "ubuntu.16.04" { $Dependencies += @("libssl1.0.0", "libicu55") }
                "ubuntu.17.04" { $Dependencies += @("libssl1.0.0", "libicu57") }
                "debian.8" { $Dependencies += @("libssl1.0.0", "libicu52") }
                "debian.9" { $Dependencies += @("libssl1.0.2", "libicu57") }
                default { throw "Debian distro '$Distribution' is not supported." }
            }
        } elseif ($Environment.IsRedHatFamily) {
            $Dependencies = @(
                "libunwind",
                "libcurl",
                "openssl-libs",
                "libicu"
            )
        }

        return $Dependencies
    }
}

function Test-Dependencies
{
    foreach ($Dependency in "fpm", "ronn") {
        if (!(precheck $Dependency "Package dependency '$Dependency' not found. Run Start-PSBootstrap -Package")) {
            # These tools are not added to the path automatically on OpenSUSE 13.2
            # try adding them to the path and re-tesing first
            [string] $gemsPath = $null
            [string] $depenencyPath = $null
            $gemsPath = Get-ChildItem -Path /usr/lib64/ruby/gems   | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
            if($gemsPath) {
                $depenencyPath  = Get-ChildItem -Path (Join-Path -Path $gemsPath -ChildPath "gems" -AdditionalChildPath $Dependency) -Recurse  | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty DirectoryName
                $originalPath = $env:PATH
                $env:PATH = $ENV:PATH +":" + $depenencyPath
                if((precheck $Dependency "Package dependency '$Dependency' not found. Run Start-PSBootstrap -Package")) {
                    continue
                }
                else {
                    $env:PATH = $originalPath
                }
            }

            throw "Dependency precheck failed!"
        }
    }
}

function New-AfterScripts
{
    if ($Environment.IsRedHatFamily) {
        # add two symbolic links to system shared libraries that libmi.so is dependent on to handle
        # platform specific changes. This is the only set of platforms needed for this currently
        # as Ubuntu has these specific library files in the platform and macOS builds for itself
        # against the correct versions.
        New-Item -Force -ItemType SymbolicLink -Target "/lib64/libssl.so.10" -Path "$Staging/libssl.so.1.0.0" >$null
        New-Item -Force -ItemType SymbolicLink -Target "/lib64/libcrypto.so.10" -Path "$Staging/libcrypto.so.1.0.0" >$null

        $AfterInstallScript = [io.path]::GetTempFileName()
        $AfterRemoveScript = [io.path]::GetTempFileName()
        $packagingStrings.RedHatAfterInstallScript -f "$Link/pwsh" | Out-File -FilePath $AfterInstallScript -Encoding ascii
        $packagingStrings.RedHatAfterRemoveScript -f "$Link/pwsh" | Out-File -FilePath $AfterRemoveScript -Encoding ascii
    }
    elseif ($Environment.IsUbuntu -or $Environment.IsDebian) {
        $AfterInstallScript = [io.path]::GetTempFileName()
        $AfterRemoveScript = [io.path]::GetTempFileName()
        $packagingStrings.UbuntuAfterInstallScript -f "$Link/pwsh" | Out-File -FilePath $AfterInstallScript -Encoding ascii
        $packagingStrings.UbuntuAfterRemoveScript -f "$Link/pwsh" | Out-File -FilePath $AfterRemoveScript -Encoding ascii
    }

    return [PSCustomObject] @{
        AfterInstallScript = $AfterInstallScript
        AfterRemoveScript = $AfterRemoveScript
    }
}

function New-ManGzip
{
    # run ronn to convert man page to roff
    $RonnFile = Join-Path $PSScriptRoot "/../../assets/pwsh.1.ronn"
    $RoffFile = $RonnFile -replace "\.ronn$"

    # Run ronn on assets file
    # Run does not play well with files named powershell6.0.1, so we generate and then rename
    Start-NativeExecution { ronn --roff $RonnFile }

    # gzip in assets directory
    $GzipFile = "$RoffFile.gz"
    Start-NativeExecution { gzip -f $RoffFile }

    $ManFile = Join-Path "/usr/local/share/man/man1" (Split-Path -Leaf $GzipFile)

    return [PSCustomObject ] @{
        GZipFile = $GzipFile
        ManFile = $ManFile
    }
}
function New-MacOSLauncher
{
    param(
        [Parameter(Mandatory)]
        [String]$Version
    )

    # Define folder for launch application.
    $macosapp = "$PSScriptRoot/macos/launcher/ROOT/Applications/Powershell.app"

    # Update icns file.
    $iconfile = "$PSScriptRoot/../../assets/Powershell.icns"
    $iconfilebase = (Get-Item -Path $iconfile).BaseName

    # Create Resources folder, ignore error if exists.
    New-Item -Force -ItemType Directory -Path "$macosapp/Contents/Resources" | Out-Null
    Copy-Item -Force -Path $iconfile -Destination "$macosapp/Contents/Resources"

    # Set values in plist.
    $plist = "$macosapp/Contents/Info.plist"
    Start-NativeExecution {
        defaults write $plist CFBundleIdentifier com.microsoft.powershell
        defaults write $plist CFBundleVersion $Version
        defaults write $plist CFBundleShortVersionString $Version
        defaults write $plist CFBundleGetInfoString $Version
        defaults write $plist CFBundleIconFile $iconfilebase
    }

    # Convert to XML plist, needed because defaults native
    # app auto converts it to binary format when it modify
    # the plist file.
    Start-NativeExecution {
        plutil -convert xml1 $plist
    }

    # Set permissions for plist and shell script. Note that
    # defaults native app sets 700 when writing to the plist
    # file from above. Both of these will be reset post fpm.
    $shellscript = "$macosapp/Contents/MacOS/PowerShell.sh"
    Start-NativeExecution {
        chmod 644 $plist
        chmod 755 $shellscript
    }

    # Add app folder to fpm paths.
    $appsfolder = (Resolve-Path -Path "$macosapp/..").Path

    return $appsfolder
}

function Clear-MacOSLauncher
{
    # This is needed to prevent installer from picking up
    # the launcher app in the build structure and updating
    # it which locks out subsequent package builds due to
    # increase permissions.
    $macosapp = "$PSScriptRoot/macos/launcher/ROOT/Applications/Powershell.app"
    $plist = "$macosapp/Contents/Info.plist"
    $tempguid = (New-Guid).Guid
    Start-NativeExecution {
        defaults write $plist CFBundleIdentifier $tempguid
        plutil -convert xml1 $plist
    }

    # Restore default permissions.
    $shellscript = "$macosapp/Contents/MacOS/PowerShell.sh"
    Start-NativeExecution {
        chmod 644 $shellscript
        chmod 644 $plist
    }
}

function New-StagingFolder
{
    param(
        [Parameter(Mandatory)]
        [string]
        $StagingPath
    )

    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $StagingPath
    Copy-Item -Recurse $PackageSourcePath $StagingPath
}

# Function to create a zip file for Nano Server and xcopy deployment
function New-ZipPackage
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (

        # Name of the Product
        [ValidateNotNullOrEmpty()]
        [string] $PackageName = 'PowerShell',

        # Suffix of the Name
        [string] $PackageNameSuffix,

        # Version of the Product
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageVersion,

        # Source Path to the Product Files - required to package the contents into an Zip
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageSourcePath,

        [switch] $Force
    )

    $ProductSemanticVersion = Get-PackageSemanticVersion -Version $PackageVersion

    $zipPackageName = $PackageName + "-" + $ProductSemanticVersion
    if ($PackageNameSuffix) {
        $zipPackageName = $zipPackageName, $PackageNameSuffix -join "-"
    }

    Write-Verbose "Create Zip for Product $zipPackageName"

    $zipLocationPath = Join-Path $PWD "$zipPackageName.zip"

    if($Force.IsPresent)
    {
        if(Test-Path $zipLocationPath)
        {
            Remove-Item $zipLocationPath
        }
    }

    If(Get-Command Compress-Archive -ErrorAction Ignore)
    {
        if($pscmdlet.ShouldProcess("Create zip package"))
        {
            Compress-Archive -Path $PackageSourcePath\* -DestinationPath $zipLocationPath
        }

        if (Test-Path $zipLocationPath)
        {
            log "You can find the Zip @ $zipLocationPath"
            $zipLocationPath
        }
        else
        {
            throw "Failed to create $zipLocationPath"
        }
    }
    #TODO: Use .NET Api to do compresss-archive equivalent if the pscmdlet is not present
    else
    {
        Write-Error -Message "Compress-Archive cmdlet is missing in this PowerShell version"
    }
}


function New-NugetPackage
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (

        # Name of the Product
        [ValidateNotNullOrEmpty()]
        [string] $PackageName = 'powershell',

        # Suffix of the Name
        [string] $PackageNameSuffix,

        # Version of the Product
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageVersion,

        # Runtime of the Product
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageRuntime,

        # Configuration of the Product
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageConfiguration,


        # Source Path to the Product Files - required to package the contents into an Zip
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageSourcePath,

        [Switch]
        $Force
    )

    log "PackageVersion: $PackageVersion"
    $nugetSemanticVersion = Get-NugetSemanticVersion -Version $PackageVersion
    log "nugetSemanticVersion: $nugetSemanticVersion"

    $nugetFolder = New-SubFolder -Path $PSScriptRoot -ChildPath 'nugetOutput' -Clean

    $nuspecPackageName = $PackageName
    if($PackageNameSuffix)
    {
        $nuspecPackageName += '-' + $PackageNameSuffix
    }

    # Setup staging directory so we don't change the original source directory
    $stagingRoot = New-SubFolder -Path $PSScriptRoot -ChildPath 'nugetStaging' -Clean
    $contentFolder = Join-Path -path $stagingRoot -ChildPath 'content'
    if ($pscmdlet.ShouldProcess("Create staging folder")) {
        New-StagingFolder -StagingPath $contentFolder
    }

    $projectFolder = Join-Path $PSScriptRoot -ChildPath 'project'

    $arguments = @('pack')
    $arguments += @('--output',$nugetFolder)
    $arguments += @('--configuration',$PackageConfiguration)
    $arguments += @('--runtime',$PackageRuntime)
    $arguments += "/p:StagingPath=$stagingRoot"
    $arguments += "/p:RID=$PackageRuntime"
    $arguments += "/p:SemVer=$nugetSemanticVersion"
    $arguments += "/p:PackageName=$nuspecPackageName"
    $arguments += $projectFolder

    log "Running dotnet $arguments"
    log "Use -verbose to see output..."
    Start-NativeExecution -sb {dotnet $arguments} | Foreach-Object {Write-Verbose $_}

    $nupkgFile = "${nugetFolder}\${nuspecPackageName}-${packageRuntime}.${nugetSemanticVersion}.nupkg"
    if (Test-Path $nupkgFile)
    {
        Get-ChildItem $nugetFolder\* | Select-Object -ExpandProperty FullName
    }
    else
    {
        throw "Failed to create $nupkgFile"
    }
}

function New-SubFolder
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [string]
        $Path,

        [String]
        $ChildPath,

        [switch]
        $Clean
    )

    $subFolderPath = Join-Path -Path $Path -ChildPath $ChildPath
    if($Clean.IsPresent -and (Test-Path $subFolderPath))
    {
        Remove-Item -Path $subFolderPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if(!(Test-Path $subFolderPath))
    {
        $null = New-Item -Path $subFolderPath -ItemType Directory
    }
    return $subFolderPath
}

# Builds coming out of this project can have version number as 'a.b.c-stringf.d-e-f' OR 'a.b.c.d-e-f'
# This function converts the above version into semantic version major.minor[.build-quality[.revision]] format
function Get-PackageSemanticVersion
{
    [CmdletBinding()]
    param (
        # Version of the Package
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Version,
        [switch] $NuGet
        )

    Write-Verbose "Extract the semantic version in the form of major.minor[.build-quality[.revision]] for $Version"
    $packageVersionTokens = $Version.Split('.')

    if ($packageVersionTokens.Count -eq 3) {
        # In case the input is of the form a.b.c, we use the same form
        $packageSemanticVersion = $Version
    } elseif ($packageVersionTokens.Count -eq 4) {
        # We have all the four fields
        $packageRevisionTokens = ($packageVersionTokens[3].Split('-'))[0]
        if($NuGet.IsPresent)
        {
            $packageRevisionTokens = $packageRevisionTokens.Replace('.','-')
        }
        $packageSemanticVersion = $packageVersionTokens[0],$packageVersionTokens[1],$packageVersionTokens[2],$packageRevisionTokens -join '.'
    } else {
        throw "Cannot create Semantic Version from the string $Version containing 4 or more tokens"
    }

    $packageSemanticVersion
}

# Builds coming out of this project can have version number as 'a.b.c-stringf.d-e-f' OR 'a.b.c.d-e-f'
# This function converts the above version into semantic version major.minor[.build-quality[-revision]] format needed for nuget
function Get-NugetSemanticVersion
{
    [CmdletBinding()]
    param (
        # Version of the Package
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Version
        )

    $packageVersionTokens = $Version.Split('.')

    Write-Verbose "Extract the semantic version in the form of major.minor[.build-quality[-revision]] for $Version"
    $versionPartTokens = @()
    $identifierPortionTokens = @()
    $inIdentifier = $false
    foreach($token in $packageVersionTokens) {
        $tokenParts = $null
        if($token -match '-') {
            $tokenParts = $token.Split('-')
        }
        elseif($inIdentifier) {
            $tokenParts = @($token)
        }

        # If we don't have token parts, then it's a versionPart
        if(!$tokenParts) {
            $versionPartTokens += $token
        }
        else {
            foreach($idToken in $tokenParts) {
                # The first token after we detect the id Part is still
                # a version part
                if(!$inIdentifier) {
                    $versionPartTokens += $idToken
                    $inIdentifier = $true
                }
                else {
                    $identifierPortionTokens += $idToken
                }
            }
        }
    }

    if($versionPartTokens.Count -gt 3) {
        throw "Cannot create Semantic Version from the string $Version containing 4 or more version tokens"
    }

    $packageSemanticVersion = ($versionPartTokens -join '.')
    if($identifierPortionTokens.Count -gt 0) {
        $packageSemanticVersion += '-' + ($identifierPortionTokens -join '-')
    }

    $packageSemanticVersion
}
