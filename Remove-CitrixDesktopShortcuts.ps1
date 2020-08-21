<#
.NOTES
    Name:    Remove-CitrixDesktopShortcuts.ps1
    Author:  Andy Simmons
    Version: 1.0.5
    URL:     https://github.com/andysimmons/ssp-cleanup
    
.SYNOPSIS
    Removes desktop shortcuts generated by the Citrix Self Service Plugin.

.DESCRIPTION
    This script was written to work around a bug where the Citrix Self
    Service Plugin (SSP) creates shortcuts on a user's desktop, and RES 
    Workspace Manager then saves the SSP shortcuts in their persistent profile.

    At logoff, RES WM performs its final profile sync, and then Citrix SSP removes
    the shortcuts from the desktop, resulting in duplicate shortcuts that accumulate
    with each successive logon.

    This script can be invoked at logon to remove the leftover shortcuts before
    SSP creates additional copies of them.

.PARAMETER StupidTargetPattern
    Regular expression used to determine (by target path) if a shortcut was created
    by the Citrix Self-Service Plugin.

.PARAMETER ShortcutPath
    One or more directories to be searched (non-recursively) and purged of 
    SSP shortcuts.

.PARAMETER SkipRefresh
    Prevents the script from polling via the Self-Service Plugin after
    execution (which could re-create Citrix application shortcuts).

.PARAMETER LogFile
    Log file location.
    
.EXAMPLE
    Remove-CitrixDesktopShortcuts.ps1

    Deletes any .lnk files in the specified directories that were generated
    by the Citrix SSP plugin.

.EXAMPLE
    Remove-CitrixDesktopShortcuts.ps1 -WhatIf

    Shows which shortcut files would be deleted, but doesn't actually remove them.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param 
(
    [regex]
    $StupidTargetPattern = 'Citrix.*ICA.*SelfServicePlugin',

    [IO.DirectoryInfo[]]
    #$ShortcutPath = [Environment]::GetFolderPath('DesktopDirectory'),
    $ShortcutPath = @(
        "F:\Desktop"
        "C:\Users\${env:USERNAME}\Desktop"
        "C:\Users\${env:USERNAME}\OneDrive - stlukes\Desktop"
        "C:\Users\${env:USERNAME}\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        "C:\Users\${env:USERNAME}\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Epic"
    ),

    [IO.FileInfo]
    $LogFile = 'C:\Logs\CitrixSSPCleanup.log',

    [switch]
    $SkipRefresh
)

$startTime = [DateTime]::Now

# This is a login script, we'll be explicit with modules to keep it snappy.
$PSModuleAutoLoadingPreference = 'None'

$scriptModules = @(
    'Microsoft.PowerShell.Host',
    'Microsoft.PowerShell.Management',
    'Microsoft.PowerShell.Security',
    'Microsoft.PowerShell.Utility'
)
$scriptModules | Import-Module

# Try the cool/newer Start-Transcript if we can
try { 
    Start-Transcript -IncludeInvocationHeader $LogFile
    $isTranscribing = $true
}
catch { 
    try { 
        Start-Transcript $LogFile
        $isTranscribing = $true 
    }
    catch { 
        Write-Warning "Couldn't write to log file '${LogFile}'. Continuing without logging."
        Write-Warning $_.Exception.Message
        $isTranscribing = $false
    }
}

# make sure at least one of the the shortcut directories exist
$ShortcutPath = foreach ($sp in $ShortcutPath) {
    if (-not $sp.Exists) {
        Write-Warning "No such directory: '$sp'. Skipping."
    }
    else { $sp }
}

if (-not $ShortcutPath) {
    Write-Error -Message "None of the provided shortcut directories exist. Nothing to do." -Category ObjectNotFound
    exit 1
}

[IO.FileInfo[]] $lnkFiles = $ShortcutPath | ForEach-Object {
    Get-ChildItem -Path $_ -Filter '*.lnk' -ErrorAction Stop
}
Write-Verbose "Found $($lnkFiles.Length) '.lnk' files in '${ShortcutPath}'"

if (-not $lnkFiles) { exit }

# Spawn a WSH shell (.Net doesn't have a native shortcut handler).
$wshShell = New-Object -ComObject WScript.Shell 

foreach ($lnkFile in $lnkFiles) {
    try {
        # instantiate a shortcut (COM object) from each file. 
        $shortcut = $wshShell.CreateShortcut($lnkFile.FullName) 
    }
    catch {
        Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo
        $shortcut = $null
        continue
    }

    if ($shortcut.TargetPath -match $StupidTargetPattern) {
        Write-Verbose "SSP Shortcut: '$($lnkFile.BaseName)' -> '$($shortcut.TargetPath)'"
        if ($PSCmdlet.ShouldProcess($lnkFile, 'Delete')) {
            try {
                $lnkFile.Delete()
                "SSP Shortcut Removed: $lnkFile"
            }
            catch {
                Write-Warning "Delete FAILED for SSP Shortcut: $lnkFile"
                Write-Warning $_.Exception.Message
            }
        }
    }
}

if (-not $SkipRefresh) {
    # If the self-service plugin is currently running, invoke a poll to refresh
    # Citrix apps and create shortcuts appropriately
    $sspProcess = Get-Process -ProcessName 'SelfServicePlugin' | Select-Object -First 1
    if ($sspProcess) {
        Write-Verbose "Refreshing Citrix application details, and recreating shortcuts where appropriate."
    
        $sspDir = ([IO.FileInfo] $sspProcess.Path).Directory
        $ssExe = [IO.FileInfo] "$sspDir\SelfService.exe"

        if ($ssExe.Exists) {
            try {
                Invoke-Expression -Command "& '$ssExe' -poll" -ErrorAction 'Stop'
                Write-Verbose "Citrix apps/shortcuts refresh invoked successfully. Shortcuts should reappear within a few seconds."
            }
            catch {
                Write-Warning "Error refreshing Citrix shortcuts!"
                Write-Warning $_.Exception.Message
            }
        }
        else {
            Write-Warning "SelfService.exe not found in '$sspDir'. Citrix Receiver/Workspace Install may be corrupted."
            Write-Warning "Error refreshing Citrix shortcuts!"
        }
    }
    else { Write-Verbose "Self-Service Plugin isn't currently running, skipping Citrix shortcut refresh." }
}

$elapsed = [int]([DateTime]::Now - $startTime).TotalMilliseconds
"Execution finished in $elapsed ms."

if ($isTranscribing) { Stop-Transcript }
