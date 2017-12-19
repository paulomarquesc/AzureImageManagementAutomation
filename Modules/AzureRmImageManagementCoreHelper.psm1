<#
.SYNOPSIS
    AzureRmImageManagementCoreHelper.psm1 - Sample PowerShell Module that contains core functions related to the image management solution.
.DESCRIPTION
    AzureRmImageManagementCoreHelper.psm1 - PowerShell Module that contains internal functions related to the image management solution.
    Image Management Solution helps customers to upload a VHD with a custom image to one subcription and storage account.
    After that gets done, a series of runbooks works to get this image and distribute amongst several other susbcriptions and 
    storage accounts and creates a managed Image so everyone with access to that resource/group would be able to deploy
    a VM from that image. This reduces the burden uploading VHDs on environments and having to distribute manually
    between different Subcriptions.
.NOTES
#>

#Requires -Modules AzureAD, AzureRmStorageTable, AzureRmStorageQueue

#region Enums
enum logLevel
{
    All
    Informational
    Warning
    Error
    Status
}

enum status
{
    NotStarted
    InProgress
    Completed
}

enum steps
{
    upload
    uploadConcluded
    tier1Distribution
    tier2Distribution
    imageCreation
    copyProcessMessage
    tier1DistributionCopyConcluded
    tier2DistributionCopyConcluded
    imageCreationConcluded
}

enum storageAccountTier
{
    tier0
    tier2
    none
}
#endregion

#region Classes

class ImageMgmtLog
{
    [string]$jobId
    [dateTime]$timeStamp
    [string]$step
    [string]$moduleName
    [string]$logLevel
    [string]$message
  
    ImageMgmtLog() {}

    ImageMgmtLog( [string]$JobId, [dateTime]$TimeStamp, [string]$Step, [string]$ModuleName, [string]$LogLevel, [string]$Message ) {
        $this.jobId = $JobId
        $this.timeStamp = $TimeStamp
        $this.step = $Step
        $this.moduleName = $ModuleName
        $this.logLevel = $LogLevel
        $this.message = $Message
    }
}

class ImageMgmtJob
{
    [string]$JobId
    [dateTime]$SubmissionDate
    [string]$Description
    [string]$VhdName
    [string]$ImageName
    [string]$OsType
  
    ImageMgmtJob() {}

    ImageMgmtJob( [string]$jobId, [dateTime]$submissionDate, [string]$description, [string]$vhdName, [string]$imageName, [string]$osType ) {
        $this.jobId = $jobId
        $this.submissionDate = $submissionDate
        $this.description = $description
        $this.vhdName = $vhdName
        $this.imageName = $imageName
        $this.osType = $osType
    }
}

class ImageMgmtJobStatus : ImageMgmtJob
{
    [int]$UploadCompletion
    [int]$Tier1CopyCompletion
    [int]$Tier2CopyCompletion
    [int]$ImageCreationCompletion
    [int]$ErrorCount
    [System.Collections.ArrayList]$ErrorLog

    ImageMgmtJobStatus() {
        $this.ErrorLog = New-Object 'System.Collections.ArrayList'
    }

    ImageMgmtJobStatus([string]$jobId, [dateTime]$submissionDate, [string]$description, [string]$vhdName, [string]$imageName, [string]$osType, [int]$uploadCompletion, [int]$tier1CopyCompletion,  [int]$tier2CopyCompletion, [int]$imageCreationCompletion, [int]$errorCount) {
        $this.jobId = $jobId
        $this.submissionDate = $submissionDate
        $this.vhdName = $vhdName
        $this.imageName = $imageName
        $this.osType = $osType
        $this.uploadCompletion = $uploadCompletion
        $this.tier1CopyCompletion = $tier1CopyCompletion
        $this.tier2CopyCompletion = $tier2CopyCompletion
        $this.imageCreationCompletion = $imageCreationCompletion
        $this.errorCount = $errorCount
        $this.ErrorLog = New-Object 'System.Collections.ArrayList'
    }

    [bool] isCompleted() {
       if ( ($this.uploadCompletion -eq 100) -and `
            ($this.tier1CopyCompletion -eq 100) -and `
            ($this.tier2CopyCompletion -eq 100) -and `
            ($this.imageCreationCompletion -eq 100) -and `
            ($this.errorCount -eq 0) )
        {
            return $true
        }
        else
        {
            return $false    
        }
    }
}

class StorageAccountName
{
    # usage example
    # $saname = ([StorageAccountName]::new("pmcglobal",[storageAccountTier]::tier2)).GetSaName()

    [string] $namePrefix = [string]::Empty
    [storageAccountTier] $tier = [storageAccountTier]::none
    [int] $padCount = 5
    [int] $retries = 5

    hidden [int] $_retryCount = 0

    StorageAccountName() {}

    StorageAccountName([string]$prefix) {
        $this.namePrefix = $prefix
    }

    StorageAccountName([string]$prefix, [storageAccountTier] $saTier) {
        $this.namePrefix = $prefix
        $this.tier = $saTier
    }

    StorageAccountName([string]$prefix, [storageAccountTier] $saTier, [int]$padCount) {
        $this.namePrefix = $prefix
        $this.tier = $saTier
        $this.padCount = $padCount
    }

    StorageAccountName([string]$prefix, [storageAccountTier] $saTier, [int]$padCount, [int]$retries) {
        $this.namePrefix = $prefix
        $this.tier = $saTier
        $this.padCount = $padCount
        $this.retries = $retries
    }

    hidden [string] _getName()
    {
        $rnd = get-random -Minimum 1 -Maximum 10000

        if ($this.tier -ne [storageAccountTier]::none)
        {
            return ([string]::Format("{0}{1}{2}",$this.namePrefix,$rnd.toString().padleft($this.padCount,"0"),$this.tier))
        }
        else
        {
            return ([string]::Format("{0}{1}",$this.namePrefix,$rnd.toString().padleft($this.padCount,"0")))
        }
    }

    hidden [object] _testName([string]$saName)
    {
        return (Get-AzureRmStorageAccountNameAvailability -Name $saName)
    } 

    [string] GetSaName([bool]$validateName) {
        if ([string]::IsNullOrEmpty($this.namePrefix))
        {
            return $null
        }
        else
        {
            $saName = $this._getName()
            
            if ($validateName)
            {
                if ($this._testName($saName).NameAvailable -ne $true)
                {
                    do
                    {
                        $this._retryCount++ 
                        $saName = $this._getName()
                        
                        if ($this._retryCount -gt $this.retries)
                        {
                            throw "Couldn't find an unused name for the storage account prefix $($this.namePrefix)"
                        }
                    }
                    Until ($this._testName($saName).NameAvailable -eq $true)  
                }
            }

            return $saName
        }
    }
}

class ImageMgmtStorageAccount
{
    [string]$StorageAccountName = [string]::Empty
    [string]$ResourceGroupName = [string]::Empty
    [string]$SubscriptionId = [string]::Empty
    [string]$Location = [string]::Empty
    [string]$Container = [string]::Empty
    [string]$ImagesResourceGroup = [string]::Empty
    [int] $Tier = 0

    ImageMgmtStorageAccount() {}

    ImageMgmtStorageAccount([string]$StorageAccountName,[string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$Container, [string]$ImagesResourceGroup, [int]$Tier ) {
        $this.StorageAccountName = $StorageAccountName
        $this.ResourceGroupName = $ResourceGroupName
        $this.SubscriptionId = $SubscriptionId
        $this.Location = $Location
        $this.Container = $Container
        $this.ImagesResourceGroup = $ImagesResourceGroup
        $this.Tier = $tier
    }
}

class ImageMgmtTier0StorageAccount : ImageMgmtStorageAccount
{
    [int]$Tier1Copies = 0
  
    ImageMgmtTier0StorageAccount() {}

    ImageMgmtTier0StorageAccount([string]$StorageAccountName,[string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$Container, [string]$ImagesResourceGroup, [int]$Tier, [int]$Tier1Copies  ) {
        $this.StorageAccountName = $StorageAccountName
        $this.ResourceGroupName = $ResourceGroupName
        $this.SubscriptionId = $SubscriptionId
        $this.Location = $Location
        $this.Container = $Container
        $this.ImagesResourceGroup = $ImagesResourceGroup
        $this.Tier = $tier
        $this.Tier1Copies = $Tier1Copies
    }
}

class ImageMgmtTier2StorageAccount : ImageMgmtStorageAccount
{
    [string]$Id = [string]::Empty
    [bool]$Enabled = 0
  
    ImageMgmtTier2StorageAccount() {}

    ImageMgmtTier2StorageAccount([string]$StorageAccountName,[string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location,  [string]$Container, [string]$ImagesResourceGroup, [int]$Tier, [string]$Id, [bool]$Enabled ) {
        $this.StorageAccountName = $StorageAccountName
        $this.ResourceGroupName = $ResourceGroupName
        $this.SubscriptionId = $SubscriptionId
        $this.Location = $Location
        $this.Container = $Container
        $this.ImagesResourceGroup = $ImagesResourceGroup
        $this.Tier = $tier
        $this.Id = $Id
        $this.Enabled = [bool]$Enabled
    }

    Enable($configurationTable) {
        if (-not ([string]::IsNullOrEmpty($this.StorageAccountName)))
        {
            $filter = "(storageAccountName eq '$($this.StorageAccountName)')" 

            $result = Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $configurationTable 
        
            if ($result -ne $null)
            {
                $result.Enabled = $true
                Update-AzureStorageTableRow -table $configurationTable -entity $result
            }
            else
            {
                throw "Storage account named $($this.StorageAccountName) could not be found on Configuration table"    
            }
        }
        else
        {
            throw "Storage account name is empty, please provide a storage account name before enabling it."    
        }
    }
    
    Enable($ConfigStorageAccountResourceGroupName,$ConfigStorageAccountName,$ConfigurationTableName="imageManagementConfiguration") {
        if (-not ([string]::IsNullOrEmpty($this.StorageAccountName)))
        {
            $configurationTable = Get-AzureRmImgMgmtTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

            $filter = "(storageAccountName eq '$($this.StorageAccountName)')" 

            $result = Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $configurationTable 
        
            if ($result -ne $null)
            {
                $result.Enabled = $true
                Update-AzureStorageTableRow -table $configurationTable -entity $result
            }
            else
            {
                throw "Storage account named $($this.StorageAccountName) could not be found on Configuration table"    
            }
        }
        else
        {
            throw "Storage account name is empty, please provide a storage account name before enabling it."    
        }
    }
    
    Disable($configurationTable) {
        if (-not ([string]::IsNullOrEmpty($this.StorageAccountName)))
        {
            $filter = "(storageAccountName eq '$($this.StorageAccountName)')" 

            $result = Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $configurationTable 
        
            if ($result -ne $null)
            {
                $result.Enabled = $false
                Update-AzureStorageTableRow -table $configurationTable -entity $result
            }
            else
            {
                throw "Storage account named $($this.StorageAccountName) could not be found on Configuration table"    
            }
        }
        else
        {
            throw "Storage account name is empty, please provide a storage account name before enabling it."    
        }
    }
    
    Disable($ConfigStorageAccountResourceGroupName,$ConfigStorageAccountName,$ConfigurationTableName="imageManagementConfiguration") {
        if (-not ([string]::IsNullOrEmpty($this.StorageAccountName)))
        {
            $configurationTable = Get-AzureRmImgMgmtTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

            $filter = "(storageAccountName eq '$($this.StorageAccountName)')" 

            $result = Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $configurationTable 
        
            if ($result -ne $null)
            {
                $result.Enabled = $false
                Update-AzureStorageTableRow -table $configurationTable -entity $result
            }
            else
            {
                throw "Storage account named $($this.StorageAccountName) could not be found on Configuration table"    
            }
        }
        else
        {
            throw "Storage account name is empty, please provide a storage account name before enabling it."    
        }
    }

}
#endregion

#region Module Functions
function Wait-ModuleImport
{
    param
    (
        [string]$resourceGroupName,
        [string]$moduleName,
        [string]$automationAccountName
    )

    do
    {
        $module = Get-AzurermAutomationModule -ResourceGroupName $resourceGroupName -Name $moduleName -AutomationAccountName $automationAccountName
        Write-Verbose "Module $moduleName provisiong state: $($module.ProvisioningState)" -Verbose
        Start-Sleep -Seconds 10
    }
    until (($module.ProvisioningState -eq "Succeeded") -or ($module.ProvisioningState -eq "Failed"))

    Write-Verbose "Provisioning of module $moduleName completed with status $($module.ProvisioningState)" -Verbose
}

function Start-AzureRmImgMgmtVhdCopy
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$sourceContainer,

        [Parameter(Mandatory=$true)]
        $sourceContext,

        [Parameter(Mandatory=$true)]
        [string]$destContainer,

        [Parameter(Mandatory=$true)]
        $destContext,

        [Parameter(Mandatory=$true)]
        [string]$sourceBlobName,

        [Parameter(Mandatory=$true)]
        [string]$destBlobName,

        [Parameter(Mandatory=$false)]
        [int]$RetryCountMax = 90,
        
        [Parameter(Mandatory=$false)]
        [int]$RetryWaitTime = 60
    )

    $retryCount = 0

    try
    {
        Start-AzureStorageBlobCopy `
            -SrcContainer $sourceContainer `
            -Context $sourceContext  `
            -DestContainer $destContainer `
            -DestContext $destContext `
            -SrcBlob $sourceBlobName `
            -DestBlob $destBlobName `
            -Force
    }
    catch
    {
        # Error 409 There is currently a pending copy operation.
        if ($_.Exception.InnerException.RequestInformation.HttpStatusCode -eq 409)
        {
            while ($retryCount -le $RetryCountMax)
            {
                write-output "Error 409 - There is currently a pending copy operation error, retry attempt $retryCount " 
                
                # Resubmiting copy job
                try
                {
                    Start-AzureStorageBlobCopy `
                        -SrcContainer $sourceContainer `
                        -Context $sourceContext  `
                        -DestContainer $destContainer `
                        -DestContext $destContext `
                        -SrcBlob $sourceBlobName `
                        -DestBlob $destBlobName `
                        -Force
                    break
                }
                catch
                {
                    Start-Sleep -Seconds $RetryWaitTime
                    $retryCount++
                }
            }
        }
        else
        {
            throw $_
        }
    }
}

function Get-AzureRmImgMgmtAvailableAutomationAccount
{
	param
	(
		[Parameter(Mandatory=$true)]
		$table,

        [Parameter(Mandatory=$true)]
        [string]$AutomationAccountType
    )

    $customFilter = "(PartitionKey eq 'automationAccount') and (type eq `'" + $AutomationAccountType + "`')" 
    $automationAccountList = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $table

    $attempts = 0

    while ($attempts -lt 3)
    {
        Write-Output "Attempt # $attempts to get an available automation account"
        foreach ($automationAccount in $automationAccountList)
        {
            # Getting all four possible status count that will lead to jobs being executed
            $jobCount = 0
            $jobCount += (Get-AzureRmAutomationJob -Status Running -ResourceGroupName $automationAccount.resourceGroupName -AutomationAccountName $automationAccount.automationAccountName).count
            $jobCount += (Get-AzureRmAutomationJob -Status Starting -ResourceGroupName $automationAccount.resourceGroupName -AutomationAccountName $automationAccount.automationAccountName).count
            $jobCount += (Get-AzureRmAutomationJob -Status Queued -ResourceGroupName $automationAccount.resourceGroupName -AutomationAccountName $automationAccount.automationAccountName).count
            $jobCount += (Get-AzureRmAutomationJob -Status Activating -ResourceGroupName $automationAccount.resourceGroupName -AutomationAccountName $automationAccount.automationAccountName).count
            
            Write-Output "Automation account has $jobCount jobs about to run or running."
            # Check if total is less than maxJobsCount of the automation account
            if ($jobCount -le $automationAccount.maxJobsCount)
            {
                Write-Output "Automation account $($automationAccount.automationAccountName) has $jobCount jobs about to run or running."
                return $automationAccount
            }
        }

        Start-Sleep -Seconds 600
        $attempts++
    }

    throw "Could not find any automation account of type $(AutomationAccountType) available at this time. If this error is becoming regular, it means it is time to increase the number of worker automation accounts."

}

function Update-AzureRmImgMgmtAutomationAccountAvailabilityCount
{
    param
    (
        [Parameter(Mandatory=$true)]
        $table,

        [Parameter(Mandatory=$true)]
        $AutomationAccount,

        [switch]$Decrease
    )
 
    Write-Output "Number of objects on automation account $($AutomationAccount.count)"

    Write-Output "Object AutomationAccount contents:"
    Write-Output -InputObject $AutomationAccount

    Write-Output "Changing current value of availableJobsCount, current value is $($AutomationAccount.availableJobsCount)"
    # Changing current value
    if ($Decrease)
    {
        Write-Output "Decreasing value"
        $AutomationAccount.availableJobsCount = $AutomationAccount.availableJobsCount - 1
    }
    else
    {
        Write-Output "Increasing value"
        $AutomationAccount.availableJobsCount =  $AutomationAccount.availableJobsCount + 1
    }

    Write-Output "New value of availableJobsCount, current value is $($AutomationAccount.availableJobsCount)"

    # Persisting change in the table
    try
    {
        if ($AutomationAccount.availableJobsCount -lt 0) {$AutomationAccount.availableJobsCount=0}
        if ($AutomationAccount.availableJobsCount -gt $AutomationAccount.maxJobsCount) {$AutomationAccount.availableJobsCount=$AutomationAccount.maxJobsCount}
        Update-AzureStorageTableRow -table $table -entity $AutomationAccount
    }
    catch
    {
        if ($_.Exception.InnerException.RequestInformation.HttpStatusCode -eq 412)
        {
            Write-Output "Http Status Code => 412"
            $retryCount = 0
            while ($retryCount -lt 5)
            {
                write-host "error 412, retry attempt $retryCount "
                $customFilter = "(PartitionKey eq 'automationAccount') and (automationAccountName eq `'" + $AutomationAccount.automationAccountName + "`')"
                $AutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $table
                write-host "Updated availableJobsCount is $($AutomationAccount.availableJobsCount), changing value..."

                if ($Decrease)
                {
                    $AutomationAccount.availableJobsCount = $AutomationAccount.availableJobsCount - 1
                }
                else
                {
                    $AutomationAccount.availableJobsCount =  $AutomationAccount.availableJobsCount + 1
                }

                write-host "Attempt new availableJobsCount is $($AutomationAccount.availableJobsCount), updating table value..."

                try
                {
                    if ($AutomationAccount.availableJobsCount -lt 0) {$AutomationAccount.availableJobsCount=0}
                    if ($AutomationAccount.availableJobsCount -gt $AutomationAccount.maxJobsCount) {$AutomationAccount.availableJobsCount=$AutomationAccount.maxJobsCount}
                    Update-AzureStorageTableRow -table $table -entity $AutomationAccount
                    write-host "update done."
                    break
                }
                catch
                {
                    write-host "retrying."
                    Start-Sleep -Seconds (Get-random -Minimum 1 -Maximum 15) 
                    $retryCount++
                }
            }
        }
        else
        {
            throw $_    
        }
    }
}

function New-AzureRmImgMgmtAutomationAccount
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$automationAccountName,

        [Parameter(Mandatory=$true)]
        [string]$resourceGroupName,

        [Parameter(Mandatory=$true)]
        [string]$location,

        [Parameter(Mandatory=$true)]
        [string]$applicationDisplayName,

        [Parameter(Mandatory=$true)]
        [string]$subscriptionId,

        [Parameter(Mandatory=$true)]
        [string]$modulesContainerUrl,

        [Parameter(Mandatory=$true)]
        [string]$sasToken,

        [Parameter(Mandatory=$true)]
        $runbooks,

        [switch]$basicTier,

        [Parameter(Mandatory=$true)]
        $config
    )

    Write-Verbose "Creating automation account $automationAccountName in resource group $resourceGroupName" -Verbose
    if ($basicTier)
    {
        New-AzurermAutomationAccount -Name $automationAccountName -ResourceGroupName $resourceGroupName -Location $location -Plan Basic
    }
    else
    {
        New-AzurermAutomationAccount -Name $automationAccountName -ResourceGroupName $resourceGroupName -Location $location -Plan Free
    }
    
    Write-Verbose "Creating Run As account $applicationDisplayName" -Verbose
    .\New-RunAsAccount.ps1  -ResourceGroup $resourceGroupName `
       -AutomationAccountName $automationAccountName `
       -SubscriptionId $subscriptionId `
       -ApplicationDisplayName $applicationDisplayName `
       -SelfSignedCertPlainPassword ([guid]::NewGuid().guid) `
       -CreateClassicRunAsAccount $false

    # Creating and importing runbooks
    foreach ($rb in $runbooks)
    {
        # Installing requred extra modules
        foreach ($module in $rb.requiredModules)
        {
            Write-Verbose "Installing module $module"
            $moduleUrl = [string]::Format("{0}/{1}.zip{2}",$modulesContainerUrl,(Get-ConfigValue $module $config),$sasToken)
            $moduleName =  Get-ConfigValue $module $config

            $result = Get-AzurermAutomationModule -ResourceGroupName $resourceGroupName -Name $moduleName -AutomationAccountName $automationAccountName -ErrorAction SilentlyContinue
            if ($result -eq $null)
            {
                New-AzureRmAutomationModule -AutomationAccountName $automationAccountName -Name $moduleName  -ContentLink $moduleUrl -ResourceGroupName $resourceGroupName
                Wait-ModuleImport -resourceGroupName $resourceGroupName -moduleName $moduleName -automationAccountName $automationAccountName
            }
        }

        Write-Verbose "Importing runbook $(Get-ConfigValue $rb.name $config)" -Verbose

         # Adding Tier2 Distribution Runbook
        if ($rb.scriptPath.StartsWith("https://"))
        {
            Write-Verbose "Downloading the script file from $(Get-ConfigValue $rb.scriptPath $config) to local path $(Join-Path $env:TEMP ([system.io.path]::GetFileName((Get-ConfigValue $rb.scriptPath $config))))" -Verbose
            Invoke-WebRequest -uri (Get-ConfigValue $rb.scriptPath $config) -OutFile (Join-Path $env:TEMP ([system.io.path]::GetFileName((Get-ConfigValue $rb.scriptPath $config))))
            $rb.scriptPath = (Join-Path $env:TEMP ([system.io.path]::GetFileName((Get-ConfigValue $rb.scriptPath $config))))
        }

        if (!(Test-Path (Get-ConfigValue $rb.scriptPath $config)))
        {
            throw "Script $(Get-ConfigValue $rb.scriptPath $config) to be imported on runbook $(Get-ConfigValue $rb.name $config) not found"
        }
        Import-AzureRMAutomationRunbook -Name (Get-ConfigValue $rb.name $config) -Path (Get-ConfigValue $rb.scriptPath $config) -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Type PowerShell -Published

        # Creating schedule if needed
        if ((Get-ConfigValue $rb.scheduleName $config) -ne $null)
        {
            $startTimeOffset = Get-ConfigValue $rb.startTimeOffset $config
            if ($startTimeOffset -eq $null)
            {
                $startTimeOffset = 0
            }

            $result = Get-AzureRmAutomationSchedule -Name (Get-ConfigValue $rb.scheduleName $config) -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -ErrorAction SilentlyContinue
            if ($result -eq $null)
            {
                # creating schedule
                Write-Verbose "Creating schedule named $(Get-ConfigValue $rb.scheduleName $config)" -Verbose
                New-AzureRmAutomationSchedule -AutomationAccountName $automationAccountName -Name (Get-ConfigValue $rb.scheduleName $config) -StartTime $(Get-Date).AddMinutes($startTimeOffset) -HourInterval (Get-ConfigValue $rb.scheduleHourInterval $config) -ResourceGroupName $resourceGroupName
            }
            
            $runbookParams = @{}
            foreach ($param in $rb.parameters)
            {
                # Adding a parameter to the runbook schedule
                $runbookParams.Add($param.key,(Get-ConfigValue $param.value $config))
            }

            if ($runbookParams.Count -gt 0)
            {
                Register-AzureRmAutomationScheduledRunbook -AutomationAccountName $automationAccountName -Name (Get-ConfigValue $rb.name $config) -ScheduleName (Get-ConfigValue $rb.scheduleName $config) -ResourceGroupName $resourceGroupName -Parameters $runbookParams
            }
            else
            {
                Register-AzureRmAutomationScheduledRunbook -AutomationAccountName $automationAccountName -Name (Get-ConfigValue $rb.name $config) -ScheduleName (Get-ConfigValue $rb.scheduleName $config) -ResourceGroupName $resourceGroupName
            }
        }

        # Check if needs to execute this runbook (usually this happens for the update runbook)
        if ($rb.executeBeforeMoveForward)
        {
            Write-Verbose "Executing runbook $(Get-ConfigValue $rb.name $config)" -Verbose
            $params = @{"resourcegroupname"=$resourceGroupName;"AutomationAccountName"=$automationAccountName}

            Start-AzureRmAutomationRunbook  -Name (Get-ConfigValue $rb.name $config) `
                                            -Parameters $params `
                                            -AutomationAccountName $automationAccountName `
                                            -ResourceGroupName $resourceGroupName `
                                            -Wait
        }
    }
}

function Get-AzureRmImgMgmtAuthToken
{
    # Returns authentication token for Azure AD Graph API access
    param
    (
        [Parameter(Mandatory=$true)]
        $TenantName,
        [Parameter(Mandatory=$false)]
        $endPoint = "https://graph.windows.net",
        [Parameter(Mandatory=$false)]
        [Microsoft.IdentityModel.Clients.ActiveDirectory.UserIdentifier] $userId,
        [Parameter(Mandatory=$false)]
        [Microsoft.IdentityModel.Clients.ActiveDirectory.PromptBehavior]$promptBehavior = [Microsoft.IdentityModel.Clients.ActiveDirectory.PromptBehavior]::Never

    )
    
    $clientId = "1950a258-227b-4e31-a9cf-717495945fc2" 
    $redirectUri = "urn:ietf:wg:oauth:2.0:oob"
    
    $authority = "https://login.windows.net/$TenantName"
    $authContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $authority
    
    if ($userID -eq $null)
    {
        $authResult = $authContext.AcquireToken($endPoint, $clientId,$redirectUri, [Microsoft.IdentityModel.Clients.ActiveDirectory.PromptBehavior]::Auto)
    }
    else
    {
        $authResult = $authContext.AcquireToken($endPoint, $clientId,$redirectUri, $promptBehavior,$userId)    
    }
    
    return $authResult
}

function Get-AzureRmImgMgmtAuthHeader
{
    # Returns authentication token for Azure AD Graph API access
    param
    (
            [Parameter(Mandatory=$true)]
            $AuthToken
    )
    
    return @{
            'Content-Type'='application\json'
            'Authorization'=$AuthToken.CreateAuthorizationHeader()
        }

}

function Get-ConfigValue ($parameter,$config)
{
    if ($parameter -eq $null)
    {
        $evaluatedValue = $null
    }
    elseif ($parameter.ToString().StartsWith("^"))
    {
        $evaluatedValue = (Invoke-Expression $parameter.ToString().Replace("^",$null))
    }
    else
    {
        $evaluatedValue = $parameter
    }
    
    return $evaluatedValue
}

function Add-AzureRmImgMgmtLog
{
    param
    (
        [string]$jobId,
        [steps]$step,
        [string]$moduleName,
        [string]$message,
        [logLevel]$level,
        [switch]$output,
        $logTable
    )

    # Creating job submission information
    $logEntryId = [guid]::NewGuid().Guid
    [hashtable]$logProps = @{ "step"=$step.ToString();
                              "moduleName"=$moduleName;
                              "message"=$message;
                              "logLevel"=$level.ToString()}

    if (($level -eq [logLevel]::Error) -or ($level -eq [logLevel]::Informational) -or ($level -eq [logLevel]::Warning))
    {
        Add-AzureStorageTableRow -table $logTable -partitionKey $jobId -rowKey $logEntryId -property $logProps
        if ($output)
        {
            write-output $msg
        }
    }  
}

function Add-AzureRmRmImgMgmtJob
{
    param
    (
        [string]$jobId,
        [string]$description,
        [string]$submissionDate,
        [string]$vhdInfo,
        $jobsTable
    )

    # Creating job submission information
    [hashtable]$jobProps = @{ "description"=$description;
                              "submissionDate"=$submissionDate;
                              "vhdInfo"=$vhdInfo}

    $job = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'job') and (RowKey eq $jobId)" -table $jobProps

    if ([string]::IsNullOrEmpty($job))
    {
        Add-AzureStorageTableRow -table $jobsTable -partitionKey "job" -rowKey $jobId -property $jobProps
    }
    else
    {
        throw "Job ID $jobId already exists, if you're updating a status, please use Update-AzureRmRmImgMgmtJob or make sure you remove the existing jobId from the table"    
    }
}

function Get-AzureRmImgMgmtLog
{
	<#
	.SYNOPSIS
		Gets log entries for a specified image process Job.
	.DESCRIPTION
		Gets log entries for a specified image process Job.
    .PARAMETER ConfigFile
        Setup config file that contains the configuration resource group, storage account and table name to access the logs.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name where the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER ConfigurationTable
        Configuration table object.
    .PARAMETER jobId
        Job Id to perform the queries on.
    .PARAMETER Level
        This parameter is used to filter specific log levels, if it is defined as Error, only error entries will be part of the result.
        If defined as All or null, all log entries for the specified job Id will be part of the result. This is based on LogLevel enumeration in the module. 
        It can be used as string or as enumm if used as enum, make sure that you load the module with "using module AzureRmImageManagement" command before using the cmdlet so 
        the enumeration gets loaded and you can refer to it as for example ([logLevel]::Error) in the cmdlet.
    .PARAMETER Step
        This parameter is used to filter by a specific step of the image process, e.g. upload. This is based on steps enumeration defined in the module. This is a similar
        case of the Level parameter.
	.EXAMPLE
        Examples
         Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 -jobId fd1fab8c-c742-4285-b059-7c3a846c1643 
         Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 -jobId fd1fab8c-c742-4285-b059-7c3a846c1643 -Level ([loglevel]::informational)
         Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 -jobId fd1fab8c-c742-4285-b059-7c3a846c1643 -Level "informational"
         Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 -jobId fd1fab8c-c742-4285-b059-7c3a846c1643 -Level ([loglevel]::Error)
         Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 -jobId fd1fab8c-c742-4285-b059-7c3a846c1643 -Level ([loglevel]::Error) -step ([steps]::upload)
         Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 -jobId fd1fab8c-c742-4285-b059-7c3a846c1643 -step ([steps]::upload)
         Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 -jobId e8b929f7-8fbd-493d-81af-14877b02f0e3  | sort -Property timestamp
	#>
    param(
        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountResourceGroupName,

        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountName,
        
        [Parameter(Mandatory=$false,ParameterSetName="withConfigSettings")]
        [AllowNull()]
        [string]$ConfigurationTableName= "imageManagementConfiguration",

        [Parameter(Mandatory=$true,ParameterSetName="withConfigTable")]
        $ConfigurationTable,
        
        [Parameter(Mandatory=$true)]
        [string]$jobId,

        [Parameter(Mandatory=$false)]
        [AllowNull()]    
        [logLevel]$Level,

        [Parameter(Mandatory=$false)]
        [AllowNull()]    
        [steps]$step
    )

    if ($PSCmdlet.ParameterSetName -eq "withConfigSettings")
    {
        $configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
    }
  
    # Getting appropriate log table
    $logTableInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "PartitionKey eq 'logConfiguration'" -table $configurationTable

    if ($logTableInfo -eq $null)
    {
        throw "System configuration table does not contain configuartion item for job logging."
    }

    # Getting the Job Log table
    $log = Get-AzureRmImgMgmtTable  -ResourceGroup $logTableInfo.resourceGroupName -StorageAccountName $logTableInfo.storageAccountName -tableName $logTableInfo.jobLogTableName

    $filter = "(PartitionKey eq '$jobId')" 
    
    if ($step -ne $null)
    {
        $filter = $filter + " and (step eq '$($step.ToString())')"
    }

    if ($level -ne $null)
    {
        if ($level -ne [logLevel]::All)
        {
            $filter = $filter + " and (logLevel eq '$($Level.ToString())')"
        }
    }

    $rawResult = @()
    $rawResult += Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $log

    $resultList = @()
    foreach ($result in $rawResult)
    {
        $resultList += [ImageMgmtLog]::New($result.PartitionKey,$result.tableTimestamp.DateTime,$result.step,$result.moduleName,$result.logLevel, $result.message)
    }

    return ,$resultList
}

function Get-AzureRmImgMgmtJob
{
	<#
	.SYNOPSIS
		Gets job information.
	.DESCRIPTION
		Gets job information.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name where the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER ConfigurationTable
        Configuration table object.
    .PARAMETER JobId
        Optional string that represents the JobId, if empty or null all jobs gets returned
  	.EXAMPLE
        # Example
         Get-AzureRmImgMgmtJob -ConfigStorageAccountResourceGroupName imageprocess-rg -ConfigStorageAccountName pmcstorage77tier0 
   	.EXAMPLE
        # Example
         Get-AzureRmImgMgmtJob -ConfigurationTable $configTable
    #>
    
    param(
        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountResourceGroupName,

        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountName,
        
        [Parameter(Mandatory=$false,ParameterSetName="withConfigSettings")]
        [AllowNull()]
        [string]$ConfigurationTableName= "imageManagementConfiguration",

        [Parameter(Mandatory=$true,ParameterSetName="withConfigTable")]
        $ConfigurationTable,

        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]$JobId
    )

    if ($PSCmdlet.ParameterSetName -eq "withConfigSettings")
    {
        $configurationTable = Get-AzureRmImgMgmtTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
    }
     
    # Getting appropriate job table
    $jobTableInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "PartitionKey eq 'logConfiguration'" -table $configurationTable

    if ($jobTableInfo -eq $null)
    {
        throw "System configuration table does not contain configuartion item for job logging."
    }

    # Getting the Job table
    $jobTable = Get-AzureRmImgMgmtTable -resourceGroup $jobTableInfo.resourceGroupName -StorageAccountName $jobTableInfo.storageAccountName -tableName $jobTableInfo.jobTableName

    $rawResult = @()
    if ([string]::IsNullOrEmpty($JobId))
    {
        $rawResult += Get-AzureStorageTableRowAll -table $jobTable
    }
    else
    {
        $filter = "(RowKey eq '$jobId')" 
        $rawResult += Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $jobTable 
    }

    $resultList = @()

    if ($rawResult -ne $null)
    {
        foreach ($result in $rawResult)
        {
            $vhdInfo = $result.vhdInfo | ConvertFrom-Json
            $resultList += [ImageMgmtJob]::New($result.RowKey,$result.submissionDate,$result.description,$vhdInfo.vhdName,$vhdInfo.imageName, $vhdInfo.osType)
        }
    }

    if ([string]::IsNullOrEmpty($JobId))
    {
        return ,$resultList
    }
    else
    {
        return $resultList
    }
    
}
function Get-AzureRmImgMgmtLogTable
{
    param
    (
        [Parameter(Mandatory=$true)]
        $configurationTable
    )

    # Getting appropriate job tables info
    $jobTablesInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "PartitionKey eq 'logConfiguration'" -table $configurationTable

    if ($jobTablesInfo -eq $null)
    {
        throw "System configuration table does not contain configuartion item for job submission and logging."
    }

    # Getting the Job Log table
    return (Get-AzureRmImgMgmtTable -resourceGroup $jobTablesInfo.resourceGroupName -StorageAccountName $jobTablesInfo.storageAccountName -tableName $jobTablesInfo.jobLogTableName)

}
function Update-AzureRmImgMgmtLogJobId
{
    # This function replaces the Partition Key of a given specific Partition Key with a new Partition Key
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$tempJobId,

        [Parameter(Mandatory=$true)]
        [string]$finalJobId,

        $logTable
    )

    $systemProperties = @('PartitionKey','RowKey','TableTimestamp','Etag')

    $customFilter = "PartitionKey eq '"+$tempJobId+"'"
    $tempJobIdItems = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $logTable

    foreach ($item in $tempJobIdItems)
    {
        $RowKey = $item.RowKey

        Remove-AzureStorageTableRow -table $logTable -entity $item

        $newItem = @{}

        $item.psobject.properties | ForEach-Object {
            if (-not ($systemProperties.Contains($_.name))) 
            {
                $newItem[$_.Name] = $_.value
            }
        }

        Add-StorageTableRow -table $logTable -partitionKey $finalJobId -rowKey $RowKey -property $newItem

    }
}
function Remove-AzureRmImgMgmtLogTemporaryJobIdEntry
{
    # This function removes log entries with the temporary Joib Id 
    param
    (
        [string]$tempJobId = [string]::Empty,

        $logTable
    )

    $customFilter = "PartitionKey eq '"+$tempJobId+"'"
    $tempJobIdItems = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $logTable

    foreach ($item in $tempJobIdItems)
    {
        Remove-AzureStorageTableRow -table $logTable -entity $item
    }
}
function Get-AzureRmImgMgmtStorageContext
{
    param
    (
        [string]$ResourceGroupName,
        [string]$StorageAccountName,
        [int]$retry = 30,
        [int]$retryWaitSeconds = 30
    )

    # Performing a loop to get the destination context with 5 attempts
    $retryCount = 0
    while (($context -eq $null) -and ($retryCount -lt $retry))
    {
        try
        {
            $context = (Get-AzureRmStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName).Context
        }
        catch
        { 
            # Avoiding temporary intermittence to make this fail
        }
        
        if ($context -eq $null)
        {
            Start-Sleep -Seconds $retryWaitSeconds
        }
        
        $retryCount++
    }

    if ($context -eq $null)
    {
        $msg = "An error occured. Context object could not be retrieved from storage account $storageAccountName at resource group $resourceGroupName"
        throw $msg
    }

    return $context
}

function Get-AzureRmImgMgmtTable
{
    param
    (
        [string]$ResourceGroup,
        [string]$StorageAccountName,
        [string]$TableName,
        [int]$retry = 10,
        [int]$retryWaitSeconds = 30
    )

    # Performing a loop to get the table
    $retryCount = 0
    while (($table -eq $null) -and ($retryCount -lt $retry))
    {
        try
        {
            $table = Get-AzureStorageTableTable -resourceGroup $ResourceGroup -StorageAccountName $StorageAccountName -tableName $TableName -ErrorAction SilentlyContinue
        }
        catch
        { 
            # Avoiding temporary intermittence to make this fail
        }
        
        if ($table -eq $null)
        {
            Start-Sleep -Seconds $retryWaitSeconds
        }

        $retryCount++
    }

    if ($table -eq $null)
    {
        $msg = "An error occured. Table object could not be retrieved from storage account $storageAccountName at resource group $resourceGroup"
        throw $msg
    }

    return $table
}

function Get-AzureRmImgMgmtJobStatus
{
    <#
	.SYNOPSIS
		Gets job status information.
	.DESCRIPTION
		Gets job status information.
    .PARAMETER ConfigFile
        Setup config file that contains the configuration resource group, storage account and table name to access the logs.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name where the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER ConfigurationTable
        Configuration table object.
    .PARAMETER Job
        Job object obained using Get-AzureRmImgMgmtJob cmdlet.
  	.EXAMPLE
        # Example

        # Getting Job List
        $jobs = Get-AzureRmImgMgmtJob -ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName -ConfigStorageAccountName $ConfigStorageAccountName

        # Getting Job status for the first Job in the returned list
        $status = Get-AzureRmImgMgmtJobStatus -ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName -ConfigStorageAccountName $ConfigStorageAccountName -job $jobs[0]
        $status

        # Output of status ImageMgmtJobStatus object
        #
        # UploadCompletion        : 100
        # Tier1CopyCompletion     : 100
        # Tier2CopyCompletion     : 100
        # ImageCreationCompletion : 100
        # ErrorCount              : 0
        # JobId                   : 0ab871dc-3da2-4502-81e5-64b9ef84c639
        # SubmissionDate          : 12/13/2017 8:30:05 PM
        # Description             : 
        # VhdName                 : centos-golden-image.vhd
        # ImageName               : myCentosImage-v2
        # OsType                  : Linux

        # Is Completed?
        $status.isCompleted()

        # Output
        # True
    #>
    
    param(
        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountResourceGroupName,

        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountName,
        
        [Parameter(Mandatory=$false,ParameterSetName="withConfigSettings")]
        [AllowNull()]
        [string]$ConfigurationTableName= "imageManagementConfiguration",

        [Parameter(Mandatory=$true,ParameterSetName="withConfigTable")]
        $ConfigurationTable,

        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
        $job
    )

    # Validating job object
    if ($job.GetType().Name -ne "ImageMgmtJob")
    {
        throw "Argument Job is not of type 'ImageMgmtJob'. Current type is $($job.GetType().Name)."
    }

    if ($PSCmdlet.ParameterSetName -eq "withConfigSettings")
    {
        $configurationTable = Get-AzureRmImgMgmtTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
    }

    $totalActivities = 7
    $activityCount = 1
    # Retrieve number of Tier 1 blobs
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Status "Retrieving number of tier 1 blobs" -PercentComplete (($activityCount/$totalActivities)*100)
    $tier0StorageAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable
    if ($tier0StorageAccount -eq $null)
    {
        throw "Tier 0 Storage Account could not be retrieved from configuration table: resourceGroup $ConfigStorageAccountResourceGroupName, storageAccount $configStorageAccountName, tableName $configurationTableName"
    }
    [int]$tier1Copies = $tier0StorageAccount.tier1Copies

    # Retrieve tier 2 Storage Accounts - this dictates how many VHD copies and how many images we will have at the end of the process
    $activityCount++
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Status "Retrieving tier 2 Storage Accounts" -PercentComplete (($activityCount/$totalActivities)*100)
    $tier2StorageAccountList = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 2)" -table $configurationTable

    if ($tier2StorageAccountList -eq $null)
    {
        throw "Tier 2 Storage Account list could not be retrieved from configuration table: resourceGroup $ConfigStorageAccountResourceGroupName, storageAccount $configStorageAccountName, tableName $configurationTableName"
    }
    $tier2StorageAccountCt = $tier2StorageAccountList.count

    # Gathering information from log table
    $activityCount++
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Status "Gathering upload information from log table" -PercentComplete (($activityCount/$totalActivities)*100)
    $uploadInfo = Get-AzureRmImgMgmtLog -ConfigurationTable $configurationTable -jobId $job.jobId -Level Informational -step uploadConcluded

    $activityCount++
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Status "Gathering tier1 copy completion information from log table" -PercentComplete (($activityCount/$totalActivities)*100)
    $tier1Info = Get-AzureRmImgMgmtLog -ConfigurationTable $configurationTable -jobId $job.jobId -Level Informational -step tier1DistributionCopyConcluded

    $activityCount++
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Status "Gathering tier2 copy completion information from log table" -PercentComplete (($activityCount/$totalActivities)*100)
    $tier2Info = Get-AzureRmImgMgmtLog -ConfigurationTable $configurationTable -jobId $job.jobId -Level Informational -step tier2DistributionCopyConcluded

    $activityCount++
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Status "Gathering image creation completion information from log table" -PercentComplete (($activityCount/$totalActivities)*100)
    $imageInfo = Get-AzureRmImgMgmtLog -ConfigurationTable $configurationTable -jobId $job.jobId -Level Informational -step imageCreationConcluded

    # Getting error messages count
    $activityCount++
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Status "Gathering error information from log table" -PercentComplete (($activityCount/$totalActivities)*100)
    $errorMessages = Get-AzureRmImgMgmtLog -ConfigurationTable $configurationTable -jobId $job.jobId  -Level Error

    [int]$uploadCompletion =  ($uploadInfo.count/1) * 100
    [int]$tier1CopyCompletion = ($tier1Info.count/$tier1Copies) * 100
    [int]$tier2CopyCompletion = ($tier2Info.count/$tier2StorageAccountCt) * 100
    [int]$imageCreationCompletion = ($imageInfo.count/$tier2StorageAccountCt) * 100

    $result = [ImageMgmtJobStatus]::New($job.jobId, $job.SubmissionDate, $job.Description, $job.VhdName, $job.ImageName, $job.OsType,$uploadCompletion,$tier1CopyCompletion,$tier2CopyCompletion,$imageCreationCompletion, $errorMessages.Count)
    
    if ($errorMessages -ne $null)
    {
        $result.ErrorLog.AddRange($errorMessages)
    }
    
    Write-Progress -Activity "Getting Job Progress Status: Job Id: $($job.JobId)" -Completed
    
    return $result

}

function Remove-AzureRmImgMgmtJobBlob
{
    <#
	.SYNOPSIS
		Removes blobs related to a specified job.
	.DESCRIPTION
		Removes blobs related to a specified job.
    .PARAMETER ConfigFile
        Setup config file that contains the configuration resource group, storage account and table name to access the logs.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name where the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER ConfigurationTable
        Configuration table object.
    .PARAMETER Job
        Job object obained using Get-AzureRmImgMgmtJob cmdlet.
  	.EXAMPLE
        $configTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $ConfigStorageAccountName -TableName imagemanagementconfiguration
        Get-AzureRmImgMgmtJob -ConfigurationTable $configTable 
        $job = Get-AzureRmImgMgmtJob -ConfigurationTable $configTable -JobId "7a9823e9-4b64-4a70-bab6-b13ddef7092b"  
        Remove-AzureRmImgMgmtJobBlob -ConfigurationTable $configTable -job $job
    #>
    
    param(
        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountResourceGroupName,

        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountName,
        
        [Parameter(Mandatory=$false,ParameterSetName="withConfigSettings")]
        [AllowNull()]
        [string]$ConfigurationTableName= "imageManagementConfiguration",

        [Parameter(Mandatory=$true,ParameterSetName="withConfigTable")]
        $ConfigurationTable,

        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
        $job
    )

    # Validating job object
    if ($job.GetType().Name -ne "ImageMgmtJob")
    {
        throw "Argument Job is not of type 'ImageMgmtJob'. Current type is $($job.GetType().Name)."
    }

    if ($PSCmdlet.ParameterSetName -eq "withConfigSettings")
    {
        $configurationTable = Get-AzureRmImgMgmtTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
    }
    
    # Removing blobs

    # Getting all storage accounts
    $storageAccountList = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and ((tier eq 0) or (tier eq 2))" -table $configurationTable | Sort-Object -Property tier

    foreach ($storageAccount in $storageAccountList)
    {
        Select-AzureRmSubscription -SubscriptionId $storageAccount.subscriptionId

        $storageAccountContext = Get-AzureRmImgMgmtStorageContext -ResourceGroupName $storageAccount.resourceGroupName -StorageAccountName $storageAccount.storageAccountName

        try
        {
            if ($storageAccount.tier -eq 0)
            {
                # Removing tier 1 blobs as well
                for ($i=0;$i -lt $storageAccount.tier1Copies;$i++)
                {
                    $blobName = [string]::Format("{0}-tier1-{1}",$job.VhdName,$i.ToString("000"))
                    $blob = Get-AzureStorageBlob -Context $storageAccountContext -Container $storageAccount.container -Blob $blobName -ErrorAction SilentlyContinue
                    if ($blob -ne $null)
                    {
                        Remove-AzureStorageBlob -Context $storageAccountContext -Container $storageAccount.container -Blob $blobName -Force  
                    }
                }
            }

            $blob = Get-AzureStorageBlob -Context $storageAccountContext -Container $storageAccount.container -Blob $job.VhdName -ErrorAction SilentlyContinue
            if ($blob -ne $null)
            {
                Remove-AzureStorageBlob -Context $storageAccountContext -Container $storageAccount.container -Blob $job.VhdName -Force 
            }
        }
        catch
        {
            $msg = "An error ocurred removing blob $vhdFilter from storage account $($storageAccount.storageAccountName) in resource group $($storageAccount.resourceGroupName), subscription $($storageAccount.subscriptionId).`nError Details:$_"
            throw $msg
        }
    }

    # Selecting tier 0 subscription back
    Select-AzureRmSubscription -Subscriptionid $storageAccountList[0].subscriptionId
}

function Get-AzureRmImgMgmtTier2StorageAccount
{
	<#
	.SYNOPSIS
		Gets tier 2 storage accounts.
	.DESCRIPTION
		Gets tier 2 storage accounts.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name where the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER ConfigurationTable
        Configuration table object.
  	.EXAMPLE
        $Tier0SubscriptionId = "<subscription id>"
        $ConfigStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
        $ConfigStorageAccountName = "pmctier0sa01"
        Select-AzureRmSubscription -Subscriptionid $Tier0SubscriptionId
        $ConfigurationTableName="ImageManagementConfiguration"

        $configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

        Get-AzureRmImgMgmtTier2StorageAccount -ConfigurationTable $configurationTable
    #>
    
    param(
        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountResourceGroupName,

        [Parameter(Mandatory=$true,ParameterSetName="withConfigSettings")]
        [string]$ConfigStorageAccountName,
        
        [Parameter(Mandatory=$false,ParameterSetName="withConfigSettings")]
        [AllowNull()]
        [string]$ConfigurationTableName= "imageManagementConfiguration",

        [Parameter(Mandatory=$true,ParameterSetName="withConfigTable")]
        $configurationTable
    )

    if ($PSCmdlet.ParameterSetName -eq "withConfigSettings")
    {
        $configurationTable = Get-AzureRmImgMgmtTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
    }
     
    $filter = "(tier eq 2)" 
    $rawResult += Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $configurationTable 

    $resultList = @()

    if ($rawResult -ne $null)
    {
        foreach ($result in $rawResult)
        {
            $resultList += [ImageMgmtTier2StorageAccount]::New($result.storageAccountName,$result.resourceGroupName,$result.subscriptionId,$result.location,$result.container,$result.imagesResourceGroup,$result.tier,$result.id,$result.enabled)
        }
    }

    return ,$resultList
}

#endregion  