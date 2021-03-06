﻿#region Initialize

function Initialize {
    try {
        # Enum for Ensure
        Add-Type -TypeDefinition @"
        public enum EnsureType
        {
            Present,
            Absent
        }
"@ -ErrorAction SilentlyContinue;

    }
    catch {
        if ($_.FullyQualifiedErrorId -match "TYPE_ALREADY_EXISTS") {
            # enough. I know already imported this type. SHOULD NOT ERROR
            return
        }
        throw
    }
}

. Initialize;

#endregion

#region Message Definition

Data VerboseMessages {
    ConvertFrom-StringData -StringData @"
        BeginGetTarget = Check Platform&OSVersion indicate to run script.
"@
}

Data DebugMessages {
    ConvertFrom-StringData -StringData @"
        PlatformCheck = Checking status for Platform. Current : {0}, Desired {1}
        OSVersionCheck = Checking status for OSVersion. Current : {0}, Desired {1}
        TestScriptCheck = Checking status for TestScript. TestScript : {0}
"@
}

Data ErrorMessages {
    ConvertFrom-StringData -StringData @"
        InvalidTestScript = TestScript should return Boolean but detected return value as null with TestScript : {0}
        UnexpectedWhenValue = Unexpected When Parameter value detected : {0}
"@
}

#endregion

#region *-TargetResource

function Get-TargetResource {
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.String]$Key,

        [System.String]$SetScript,

        [System.String]$TestScript,

        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty,

        [parameter(Mandatory = $true)]
        [System.String]$ExecuteOnPlatform,

        [parameter(Mandatory = $true)]
        [System.String]$ExecuteOnVersion,

        [parameter(Mandatory = $true)]
        [ValidateSet("LessThan", "LessThanEqual", "Equal", "NotEqual", "GreaterThan", "GreaterThanEqual")]
        [System.String]$When
    )

    $returnValue = @{
        Key               = $Key
        SetScript         = $SetScript
        TestScript        = $TestScript
        Credential        = New-CimInstance -ClassName MSFT_Credential -Property @{Username = [string]$Credential.UserName; Password = [string]$null} -Namespace root/microsoft/windows/desiredstateconfiguration -ClientOnly
        ExecuteOnPlatform = $ExecuteOnPlatform
        ExecuteOnVersion  = $ExecuteOnVersion
        When              = $When
    }

    Write-Verbose $VerboseMessages.BeginGetTarget;

    try {
        # System.Environment.OSVersion is only for Full.NET CLR.
        # if DSC is implemented in .NET Core, should use System.Runtime.InteropServices.RuntimeInformation.OSDescription instead.
        $currentVersion = [System.Environment]::OSVersion
        $executeOnVersion = [Version]::Parse($ExecuteOnVersion)

        # Platform check
        Write-Debug ($DebugMessages.PlatformCheck -f $currentVersion.Platform, $ExecuteOnPlatform)
        if ($currentVersion.Platform -ne $ExecuteOnPlatform) {
            $returnValue.Ensure = [EnsureType]::Absent
            return $returnValue
        }

        # OSVersion check
        Write-Debug ($DebugMessages.OSVersionCheck -f $currentVersion.Version, $executeOnVersion)
        switch ($When) {
            "LessThan" {
                if (!($currentVersion.Version -lt $executeOnVersion)) {
                    $returnValue.Ensure = [EnsureType]::Absent
                    return $returnValue
                }
            }
            "LessThanEqual" {
                if (!($currentVersion.Version -le $executeOnVersion)) {
                    $returnValue.Ensure = [EnsureType]::Absent
                    return $returnValue
                }
            }
            "Equal" {
                if (!($currentVersion.Version -eq $executeOnVersion)) {
                    $returnValue.Ensure = [EnsureType]::Absent
                    return $returnValue
                }
            }
            "NotEqual" {
                if (!($currentVersion.Version -ne $executeOnVersion)) {
                    $returnValue.Ensure = [EnsureType]::Absent
                    return $returnValue
                }
            }
            "GreaterThan" {
                if (!($currentVersion.Version -gt $executeOnVersion)) {
                    $returnValue.Ensure = [EnsureType]::Absent
                    return $returnValue
                }
            }
            "GreaterThanEqual" {
                if (!($currentVersion.Version -ge $executeOnVersion)) {
                    $returnValue.Ensure = [EnsureType]::Absent
                    return $returnValue
                }
            }
            Default {
                Write-Error ($ErrorMessages.UnexpectedWhenValue -f $_);
            }
        }

        # TestScript Check
        Write-Debug ($DebugMessages.TestScriptCheck -f $TestScript)
        $testValid = ExecuteTestScriptBlock -ScriptBlockString $TestScript -Credential $Credential
        if ($null -eq $testValid) {
            $errorId = "InvalidTestScript"
            $errorMessage = $ErrorMessages.InvalidTestScript -f $TestScript
            ThrowInvalidDataException -ErrorId $errorId -ErrorMessage $errorMessage
        }
        $returnValue.Ensure = if ($testValid) { [EnsureType]::Present } else { [EnsureType]::Absent }
        return $returnValue;
    }
    catch {
        Write-Error $_;
    }
}

function Set-TargetResource {
    [OutputType([Void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.String]$Key,

        [System.String]$SetScript,

        [System.String]$TestScript,

        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty,

        [parameter(Mandatory = $true)]
        [System.String]$ExecuteOnPlatform,

        [parameter(Mandatory = $true)]
        [System.String]$ExecuteOnVersion,

        [parameter(Mandatory = $true)]
        [ValidateSet("LessThan", "LessThanEqual", "Equal", "NotEqual", "GreaterThan", "GreaterThanEqual")]
        [System.String]$When
    )

    ExecuteScriptBlock -ScriptBlockString $SetScript -Credential $Credential
}


function Test-TargetResource {
    [OutputType([System.Boolean])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.String]$Key,

        [System.String]$SetScript,

        [System.String]$TestScript,

        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty,

        [parameter(Mandatory = $true)]
        [System.String]$ExecuteOnPlatform,

        [parameter(Mandatory = $true)]
        [System.String]$ExecuteOnVersion,

        [parameter(Mandatory = $true)]
        [ValidateSet("LessThan", "LessThanEqual", "Equal", "NotEqual", "GreaterThan", "GreaterThanEqual")]
        [System.String]$When
    )

    $param = @{
        Key               = $Key
        SetScript         = $SetScript
        TestScript        = $TestScript
        Credential        = $Credential
        ExecuteOnPlatform = $ExecuteOnPlatform
        ExecuteOnVersion  = $ExecuteOnVersion
        When              = $When
    }

    return (Get-TargetResource @param).Ensure -eq [EnsureType]::Present
}

#endregion

# ScriptBlock Execute Helper
function ExecuteScriptBlock {
    [OutputType([Void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $false)]
        [System.String]$ScriptBlockString = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty
    )

    if ($ScriptBlockString -eq [string]::Empty) { return; }

    try {
        $scriptBlock = [ScriptBlock]::Create($ScriptBlockString).GetNewClosure()
        if ($Credential -eq [PSCredential]::Empty) {
            Write-Debug ($debugMessage.ExecuteScriptBlock -f $ScriptBlockString)
            $scriptBlock.Invoke() | Out-String -Stream | Write-Debug
        }
        else {
            Write-Debug ($debugMessage.ExecuteScriptBlockWithCredential -f $ScriptBlockString)
            Invoke-Command -ScriptBlock $scriptBlock -Credential $Credential -ComputerName . | Out-String -Stream | Write-Debug
        }
    }
    catch {
        Write-Debug ($exceptionMessage.ScriptBlockException -f $ScriptBlockString)
        throw $_
    }
}

function ExecuteTestScriptBlock {
    [OutputType([Bool])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $false)]
        [System.String]$ScriptBlockString = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty
    )

    if ($ScriptBlockString -eq [string]::Empty) { return $true; }

    try {
        $scriptBlock = [ScriptBlock]::Create($ScriptBlockString).GetNewClosure()
        if ($Credential -eq [PSCredential]::Empty) {
            Write-Debug ($debugMessage.ExecuteScriptBlock -f $ScriptBlockString)
            return $scriptBlock.Invoke()
        }
        else {
            Write-Debug ($debugMessage.ExecuteScriptBlockWithCredential -f $ScriptBlockString)
            return Invoke-Command -ScriptBlock $scriptBlock -Credential $Credential -ComputerName .
        }
    }
    catch {
        Write-Debug ($exceptionMessage.ScriptBlockException -f $ScriptBlockString)
        throw $_
    }
}

# Exception Helper
function ThrowInvalidDataException {
    [OutputType([Void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.String]$ErrorId,

        [parameter(Mandatory = $true)]
        [System.String]$ErrorMessage
    )

    $errorCategory = [System.Management.Automation.ErrorCategory]::InvalidData
    $exception = New-Object System.InvalidOperationException $ErrorMessage
    $errorRecord = New-Object System.Management.Automation.ErrorRecord $exception, $ErrorId, $errorCategory, $null
    throw $errorRecord
}

Export-ModuleMember -Function *-TargetResource
