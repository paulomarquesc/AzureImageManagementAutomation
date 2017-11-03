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

# Enums
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
    tier1Distribution
    tier2Distribution
    imageCreation
    copyProcessMessage
    tier1DistributionCopyConcluded
    tier2DistributionCopyConcluded
    imgageCreationConcluded
}

enum storageAccountTier
{
    tier0
    tier2
    none
}

# # Classes
# class JobStatus
# {
#     [int]$expectedItems=0
#     [status]$uploadStatus=[status]::NotStarted
#     [status]$tier1Distribution=[status]::NotStarted
#     [status]$tier2Distribution=[status]::NotStarted
#     [status]$imageCreation=[status]::NotStarted
#     [dateTime]$uploadCompletionTimeUTC
#     [dateTime]$tier1DistributionCompletionTimeUTC
#     [dateTime]$tier2DistributionCompletionTimeUTC
#     [double]$totalJobElapsedTime=0
# }

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

# Module Functions

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
        [int]$RetryCountMax = 180,
        
        [Parameter(Mandatory=$false)]
        [int]$RetryWaitTime = 60
    )

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
    catch [Microsoft.WindowsAzure.Storage.StorageException]
    {
        # Error 409 There is currently a pending copy operation.
        if ($_.Exception.InnerException.RequestInformation.HttpStatusCode -eq 409)
        {
            while ($retryCount -le $RetryCountMax) # Maximum 3 hours retry time to avoid endless loop
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
    catch 
    {
        Write-Output "Error not caught:`n $_"
        throw $_
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

    $customFilter = "(PartitionKey eq 'automationAccount') and (type eq `'" + $AutomationAccountType + "`') and (availableJobsCount gt 0)" 
    $copyAutomationAccountList = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $table

    if ($copyAutomationAccountList -eq $null)
    {
        throw "System configuration table does not contain dedicated copy Automation Accounts information or there is no available automation accounts at this momement to process the job."
    }

    # returning the most available automation account
    return ($copyAutomationAccountList | Sort-Object availableJobsCount -Descending)[0]
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
    catch [Microsoft.WindowsAzure.Storage.StorageException]
    {
        Write-Output "Exception Microsoft.WindowsAzure.Storage.StorageException caught"
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
    catch
    {
        Write-Output "Error not caught:`n $_"
        throw $_
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
            $result = Get-AzureRmAutomationSchedule -Name (Get-ConfigValue $rb.scheduleName $config) -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -ErrorAction SilentlyContinue
            if ($result -eq $null)
            {
                # creating schedule
                Write-Verbose "Creating schedule named $(Get-ConfigValue $rb.scheduleName $config)" -Verbose
                New-AzureRmAutomationSchedule -AutomationAccountName $automationAccountName -Name (Get-ConfigValue $rb.scheduleName $config) -StartTime $(Get-Date).AddMinutes(10) -HourInterval (Get-ConfigValue $rb.scheduleHourInterval $config) -ResourceGroupName $resourceGroupName
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
        $jobsTable
    )

    # Creating job submission information
    [hashtable]$jobProps = @{ "description"=$description;
                         "submissionDate"=$submissionDate}

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

# function Update-AzureRmRmImgMgmtJob
# {
#     param
#     (
#         [string]$jobId,
#         [JobStatus]$status,
#         $jobsTable
#     )


# }

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
        $configurationTable,
        
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
        $configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
    }
  
    # Getting appropriate log table
    $logTableInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "PartitionKey eq 'logConfiguration'" -table $configurationTable

    if ($logTableInfo -eq $null)
    {
        throw "System configuration table does not contain configuartion item for job logging."
    }

    # Getting the Job Log table
    $log = Get-AzureStorageTableTable -resourceGroup $logTableInfo.resourceGroupName -StorageAccountName $logTableInfo.storageAccountName -tableName $logTableInfo.jobLogTableName

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

    return (Get-AzureStorageTableRowByCustomFilter -customFilter $filter -table $log)

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
    return (Get-AzureStorageTableTable -resourceGroup $jobTablesInfo.resourceGroupName -StorageAccountName $jobTablesInfo.storageAccountName -tableName $jobTablesInfo.jobLogTableName)

}
