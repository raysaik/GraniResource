#region Initialize

function Initialize {
    # Enum for Item Type
    Add-Type -TypeDefinition @"
        public enum GraniDonwloadItemTypeEx
        {
            FileInfo,
            DirectoryInfo,
            Other,
            NotExists
        }
"@ -ErrorAction SilentlyContinue

    # Enum for Ensure
    Add-Type -TypeDefinition @"
        public enum GraniDonwloadEnsuretype
        {
            Present,
            Absent
        }
"@ -ErrorAction SilentlyContinue

    # Enum for CheckSum
    Add-Type -TypeDefinition @"
        public enum GraniDonwloadCheckSumtype
        {
            FileHash,
            FileName
        }
"@ -ErrorAction SilentlyContinue
}

Initialize

#endregion

#region Message Definition

$debugMessage = DATA {
    ConvertFrom-StringData -StringData "
        ExecuteScriptBlock = Execute ScriptBlock without Credential. '{0}'
        ExecuteScriptBlockWithCredential = Execute ScriptBlock with Credential. '{0}'
        FileExists = File found from DestinationPath.
        IsCheckSumFileName = CheckSum was '{0}', File already exist in destination path. Complete file checking.
        IsDestinationPathExist = Checking Destination Path is existing and Valid as a FileInfo
        IsDestinationPathAlreadyUpToDate = CheckSum was '{0}', matching FileHash to verify file is already Up-To-Date.
        IsFileAlreadyUpToDate = CurrentFileHash : S3 FileHash -> {0} : {1}
        IsS3ObjectExist = Testing S3 Object is exist or not.
        ItemTypeWasFile = Destination Path found as File : '{0}'
        ItemTypeWasDirectory = Destination Path found but was Directory : '{0}'
        ItemTypeWasOther = Destination Path found but was neither File nor Directory: '{0}'
        ItemTypeWasNotExists = Destination Path not found : '{0}'
        OverrideRegion = Overriding Region : '{0}'
        ValidateS3Bucket = Checking S3 Bucket '{0}' is exist.
        ValidateS3Object = Checking S3 Object Key '{0}' is exist.
        ValidateFilePath = Check DestinationPath '{0}' is FileInfo and Parent Directory already exist.
    "
}

$verboseMessage = DATA {
    ConvertFrom-StringData -StringData "
        AlreadyUpToDate = Current DestinationPath FileHash and S3 FileHash matched. File already Up-To-Date.
        NotUpToDate = Current DestinationPath FileHash and S3 FileHash not matched. Need to download latest file.
        ResultS3Bucket = S3Bucket exist status : S3Bucket {0}, Status : {1}
        ResultS3Object = S3Object exist status : S3Object {0}, Status : {1}
        StartS3Download = Downloading S3 Object.
    "
}
$exceptionMessage = DATA {
    ConvertFrom-StringData -StringData "
        DestinationPathAlreadyExistAsNotFile = Destination Path '{0}' already exist but not a file. Found itemType is {1}. Windows not allowed exist same name item.
        S3BucketNotExistEXception = Desired S3 Bucket not found exception. S3Bucket : {0}
        S3ObjectNotExistEXception = Desired S3 Object not found in S3Bucket exception. S3Bucket : {0}, S3Object : {1}
        ScriptBlockException = Error thrown on ScriptBlock. ScriptBlock : {0}
    "
}

#endregion

#region *-TargetResource

function Get-TargetResource {
    [OutputType([System.Collections.Hashtable])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.String]$S3BucketName,

        [parameter(Mandatory = $false)]
        [System.String]$Key,

        [parameter(Mandatory = $true)]
        [System.String]$DestinationPath,

        [parameter(Mandatory = $false)]
        [System.String]$PreAction = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.String]$PostAction = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty,

        [parameter(Mandatory = $false)]
        [ValidateSet("FileHash", "FileName")]
        [System.String]$CheckSum = [GraniDonwloadCheckSumtype]::FileHash.ToString(),

        [parameter(Mandatory = $false)]
        [System.String]$Region = [string]::Empty
    )

    # Initialize return values
    # Header and OAuth2Token will never return as TypeConversion problem
    $returnHash = @{
        S3BucketName    = $S3BucketName
        Key             = $Key
        DestinationPath = $DestinationPath
        Ensure          = [GraniDonwloadEnsuretype]::Absent.ToString()
        PreAction       = $PreAction
        PostAction      = $PostAction
        Credential      = New-CimInstance -ClassName MSFT_Credential -Property @{Username = [string]$Credential.UserName; Password = [string]$null} -Namespace root/microsoft/windows/desiredstateconfiguration -ClientOnly
        CheckSum        = $CheckSum
        Region          = $Region
    }

    try {
        # Fail fast S3Bucket and S3Object existance.
        $isBucketExist = TestS3Bucket -BucketName $S3BucketName -Region $Region
        if (-not $isBucketExist) {        
            Write-Verbose -Message ($verboseMessage.ResultS3Bucket -f $S3BucketName, $isBucketExist);
            return $returnHash
        }
        $isObjectExist = TestS3Object -BucketName $S3BucketName -Key $Key -Region $Region;
        if (-not $isObjectExist) {        
            Write-Verbose -Message ($verboseMessage.ResultS3Object -f $Key, $isObjectExist);
            return $returnHash
        }

        # Start checking destination Path check if S3Bucket and S3Object exists
        Write-Debug -Message $debugMessage.IsDestinationPathExist
        $itemType = GetPathItemType -Path $DestinationPath

        $fileExists = $false
        switch ($itemType.ToString()) {
            ([GraniDonwloadItemTypeEx]::FileInfo.ToString()) {
                Write-Debug -Message ($debugMessage.ItemTypeWasFile -f $DestinationPath)
                $fileExists = $true
            }
            ([GraniDonwloadItemTypeEx]::DirectoryInfo.ToString()) {
                Write-Debug -Message ($debugMessage.ItemTypeWasDirectory -f $DestinationPath)
            }
            ([GraniDonwloadItemTypeEx]::Other.ToString()) {
                Write-Debug -Message ($debugMessage.ItemTypeWasOther -f $DestinationPath)
                return $returnHash
            }
            ([GraniDonwloadItemTypeEx]::NotExists.ToString()) {
                Write-Debug -Message ($debugMessage.ItemTypeWasNotExists -f $DestinationPath)
                return $returnHash
            }
        }

        # Already Up-to-date Check
        if ($fileExists -eq $true) {
            Write-Debug -Message $debugMessage.FileExists
            switch ($CheckSum) {
                ([GraniDonwloadCheckSumtype]::FileHash.ToString()) {
                    Write-Debug -Message ($debugMessage.IsDestinationPathAlreadyUpToDate -f $CheckSum)
                    $currentFileHash = GetFileHash -Path $DestinationPath
                    $s3ObjectCache = GetS3ObjectHash -BucketName $S3BucketName -Key $Key -Region $Region

                    Write-Debug -Message ($debugMessage.IsFileAlreadyUpToDate -f $currentFileHash, $s3ObjectCache)
                    if ($currentFileHash -eq $s3ObjectCache) {
                        Write-Verbose -Message $verboseMessage.AlreadyUpToDate
                        $returnHash.Ensure = [GraniDonwloadEnsuretype]::Present.ToString()
                    }
                    else {
                        Write-Verbose -Message $verboseMessage.NotUpToDate
                    }
                }
                ([GraniDonwloadCheckSumtype]::FileName.ToString()) {
                    # FileName only check : Is destination file exists or not.
                    Write-Debug -Message ($debugMessage.IsCheckSumFileName -f $CheckSum)
                    $returnHash.Ensure = [GraniDonwloadEnsuretype]::Present.ToString()
                }
            }
        }
    }
    catch {
        Write-Error $_
    }
    
    return $returnHash
}


function Set-TargetResource {
    [OutputType([Void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.String]$S3BucketName,

        [parameter(Mandatory = $false)]
        [System.String]$Key,

        [parameter(Mandatory = $true)]
        [System.String]$DestinationPath,

        [parameter(Mandatory = $false)]
        [System.String]$PreAction = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.String]$PostAction = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty,

        [parameter(Mandatory = $false)]
        [ValidateSet("FileHash", "FileName")]
        [System.String]$CheckSum = [GraniDonwloadCheckSumtype]::FileHash.ToString(),

        [parameter(Mandatory = $false)]
        [System.String]$Region = [string]::Empty
    )

    # validate S3 Bucket is exist
    ValidateS3Bucket -BucketName $S3BucketName -Region $Region
    ValidateS3Object -BucketName $S3BucketName -Key $Key -Region $Region

    # validate DestinationPath is valid
    ValidateFilePath -Path $DestinationPath

    # PreAction
    ExecuteScriptBlock -ScriptBlockString $PreAction -Credential $Credential

    # Start Download
    Write-Verbose $verboseMessage.StartS3Download
    ReadS3Object -BucketName $S3BucketName -Key $Key -File $DestinationPath -Region $Region

    # PostAction
    ExecuteScriptBlock -ScriptBlockString $PostAction -Credential $Credential
}


function Test-TargetResource {
    [OutputType([System.Boolean])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [System.String]$S3BucketName,

        [parameter(Mandatory = $false)]
        [System.String]$Key,

        [parameter(Mandatory = $true)]
        [System.String]$DestinationPath,

        [parameter(Mandatory = $false)]
        [System.String]$PreAction = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.String]$PostAction = [string]::Empty,

        [parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential = [PSCredential]::Empty,

        [parameter(Mandatory = $false)]
        [ValidateSet("FileHash", "FileName")]
        [System.String]$CheckSum = [GraniDonwloadCheckSumtype]::FileHash.ToString(),

        [parameter(Mandatory = $false)]
        [System.String]$Region = [string]::Empty
    )

    $param = @{
        S3BucketName    = $S3BucketName
        Key             = $Key
        DestinationPath = $DestinationPath
        PreAction       = $PreAction
        PostAction      = $PostAction
        CheckSum        = $CheckSum
        Region          = $Region
    }
    return (Get-TargetResource @param).Ensure -eq [GraniDonwloadEnsuretype]::Present.ToString()
}

#endregion

#region S3 Helper

# Test
function TestS3Bucket {
    [OutputType([Boolean])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$BucketName,

        [parameter(Mandatory = $false)]
        [string]$Region
    )

    if ([string]::IsNullOrWhiteSpace($Region)) {
        return Test-S3Bucket -BucketName $BucketName
    }
    else {
        Write-Debug -Message ($debugMessage.OverrideRegion -f $Region)
        return Test-S3Bucket -BucketName $BucketName -Region $Region
    }
}
function TestS3Object {
    [OutputType([Boolean])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$BucketName,

        [parameter(Mandatory = $true)]
        [string]$Key,

        [parameter(Mandatory = $false)]
        [string]$Region
    )
    
    Write-Debug -Message ($debugMessage.IsS3ObjectExist)
    if ([string]::IsNullOrWhiteSpace($Region)) {
        $objects = Get-S3Object -BucketName $BucketName
    }
    else {
        Write-Debug -Message ($debugMessage.OverrideRegion -f $Region)
        $objects = Get-S3Object -BucketName $BucketName -Region $Region
    }

    $result = $null
    $dic = New-Object "System.Collections.Generic.Dictionary[[string], [string]]"
    $objects | Foreach-Object { $dic.Add($_.Key, $_.Etag) }
    return $dic.TryGetValue($Key, [ref]$result)
}

# Validation
function ValidateS3Bucket {
    [OutputType([Void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$BucketName,

        [parameter(Mandatory = $false)]
        [string]$Region
    )

    Write-Debug -Message ($debugMessage.ValidateS3Bucket -f $BucketName)
    if (-not (TestS3Bucket -BucketName $BucketName -Region $Region)) {
        throw New-Object System.NullReferenceException ($exceptionMessage.S3BucketNotExistEXception -f $BucketName)
    }
}

function ValidateS3Object {
    [OutputType([Void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$BucketName,

        [parameter(Mandatory = $true)]
        [string]$Key,

        [parameter(Mandatory = $false)]
        [string]$Region
    )

    Write-Debug -Message ($debugMessage.ValidateS3Object -f $Key)
    if (-not (TestS3Object -BucketName $BucketName -Key $Key -Region $Region)) {
        throw New-Object System.NullReferenceException ($exceptionMessage.S3ObjectNotExistEXception -f $BucketName, $Key)
    }
}

function ValidateFilePath {
    [OutputType([Void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$Path
    )
    
    Write-Debug -Message ($debugMessage.ValidateFilePath -f $Path)
    $itemType = GetPathItemType -Path $Path
    switch ($itemType.ToString()) {
        ([GraniDonwloadItemTypeEx]::FileInfo.ToString()) {
            return;
        }
        ([GraniDonwloadItemTypeEx]::NotExists.ToString()) {
            # Create Parent Directory check
            $parentPath = Split-Path $Path -Parent
            if (-not (Test-Path -Path $parentPath)) {
                [System.IO.Directory]::CreateDirectory($parentPath) > $null
            }
        }
        Default {
            $errorId = "FileValidationFailure"
            $errorMessage = $exceptionMessage.DestinationPathAlreadyExistAsNotFile -f $Path, $itemType.ToString()
            ThrowInvalidDataException -ErrorId $errorId -ErrorMessage $errorMessage
        }
    }
}

# Hash
function GetFileHash {
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -Path $Path -Algorithm MD5).Hash
}

function GetS3ObjectHash {
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$BucketName,

        [parameter(Mandatory = $true)]
        [string]$Key,

        [parameter(Mandatory = $false)]
        [string]$Region
    )

    if ([string]::IsNullOrWhiteSpace($Region)) {
        return (Get-S3Object -BucketName $BucketName -Key $Key | Where-Object Key -eq $Key).ETag.Replace('"', "")
    }
    else {
        Write-Debug -Message ($debugMessage.OverrideRegion -f $Region)
        return (Get-S3Object -BucketName $BucketName -Key $Key -Region $Region | Where-Object Key -eq $Key).ETag.Replace('"', "")
    }
}

# Reader
function ReadS3Object {
    [OutputType([void])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$BucketName,

        [parameter(Mandatory = $true)]
        [string]$Key,

        [parameter(Mandatory = $true)]
        [string]$File,

        [parameter(Mandatory = $false)]
        [string]$Region
    )

    if ([string]::IsNullOrWhiteSpace($Region)) {
        Read-S3Object -BucketName $BucketName -Key $Key -File $File
    }
    else {
        Write-Debug -Message ($debugMessage.OverrideRegion -f $Region)
        Read-S3Object -BucketName $BucketName -Key $Key -File $File -Region $Region
    }
}

#endregion

# ItemType Helper
function GetPathItemType {
    [OutputType([GraniDonwloadItemTypeEx])]
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias("FullName", "LiteralPath", "PSPath")]
        [System.String]$Path = [string]::Empty
    )

    $type = [string]::Empty

    # Check type of the Path Item
    if (-not (Test-Path -Path $Path)) {
        return [GraniDonwloadItemTypeEx]::NotExists
    }
    
    $pathItem = Get-Item -Path $path
    $pathItemType = $pathItem.GetType().FullName
    $type = switch ($pathItemType) {
        "System.IO.FileInfo" {
            [GraniDonwloadItemTypeEx]::FileInfo
        }
        "System.IO.DirectoryInfo" {
            [GraniDonwloadItemTypeEx]::DirectoryInfo
        }
        Default {
            [GraniDonwloadItemTypeEx]::Other
        }
    }

    return $type
}

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