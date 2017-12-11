<#
    .SYNOPSIS
        Transfers the VHD file from the tier 1 storage to tier 2 storage. 
    .DESCRIPTION
        Transfers the VHD file from the tier 1 storage to tier 2 storage.
        At the end it will place a message into the Image Creation queue for Images to be created
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name of the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables.
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER SourceStorageAccount
        Resource Group name of the Azure Storage Account that contains the system configuration tables.
    .PARAMETER SourceBlobName
        Name of the source blob
    .PARAMETER DestinationStorageAccount
        Name of the Storage Account that contains the system configuration tables.
    .PARAMETER VhdDetails
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER StatusCheckInterval
        Time in minutes where that the tier 2 blob copy jobs are pulled for status, default is 60 minutes. 
    .PARAMETER ConnectionName
        RunAs ccount to be used. 
    .PARAMETER AutomationAccountName
        Name of the current automation account executing the runbook.,
    .PARAMETER Tier0SubscriptionId
        Id of the tier 0 subscription (the one that contains the configuration table). 
    .PARAMETER jobId
        Id of this copy job

    .EXAMPLE
#>
using module AzureRmImageManagement

Param
(
    [Parameter(Mandatory=$true)]
    [String] $ConfigStorageAccountResourceGroupName,

    [Parameter(Mandatory=$true)]
    [String] $ConfigStorageAccountName,

    [Parameter(Mandatory=$false)]
    [String] $ConfigurationTableName="ImageManagementConfiguration",

    [Parameter(Mandatory=$true)]
    $SourceStorageAccount,

    [Parameter(Mandatory=$true)]
    $SourceBlobName,

    [Parameter(Mandatory=$true)]
    $DestinationStorageAccount,

    [Parameter(Mandatory=$true)]
    [String] $VhdDetails,

    [Parameter(Mandatory=$false)]
    $connectionName="AzureRunAsConnection",

    [Parameter(Mandatory=$false)]
    [int] $StatusCheckInterval = 60,
    
    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,
        
    [Parameter(Mandatory=$true)]
    [String] $Tier0SubscriptionId,

    [Parameter(Mandatory=$true)]
    [String] $jobId
)

$ErrorActionPreference = "Stop"
$moduleName = "Start-ImageManagementVhdCopyTier2"

#
# Runbook body
#

write-output "Authenticating with connection $connectionName" 

try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName

    # Logging in to Azure using service principal
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch
{
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else
    {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

Select-AzureRmSubscription -SubscriptionId $SourceStorageAccount.SubscriptionId

# Getting the configuration table
$configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

if ($configurationTable -eq $null)
{
    throw "Configuration table $configurationTableName could not be found at resourceGroup $ConfigStorageAccountResourceGroupName, Storage Account $configStorageAccountName, subscription $Tier0SubscriptionId"
}

# Getting the Job Log table
$log =  Get-AzureRmImgMgmtLogTable -configurationTable $configurationTable 

$msg = "Getting source context object for tier 2 copy -> Subscription: $($SourceStorageAccount.SubscriptionId) SourceStorageAccount: $($SourceStorageAccount.storageAccountName) SourceStorageAccountResourceGroup $($SourceStorageAccount.resourceGroupName)"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

# Getting source context object
$sourceContext = (Get-AzureRmStorageAccount -ResourceGroupName $SourceStorageAccount.resourceGroupName -Name $SourceStorageAccount.storageAccountName).Context
if ($sourceContext -eq $null)
{
    $msg = "An error ocurred. Context object could not be retrieved from source storage account $($SourceStorageAccount.storageAccountName) at resource group $($SourceStorageAccount.resourceGroupName) at subscription $($SourceStorageAccount.SubscriptionId)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

    throw "Context object could not be retrieved from source storage account $($SourceStorageAccount.storageAccountName) at resource group $($SourceStorageAccount.resourceGroupName) at subscription $($SourceStorageAccount.SubscriptionId)"
}

# Getting destination context

try
{
    Select-AzureRmSubscription -SubscriptionId $DestinationStorageAccount.SubscriptionId 

    $msg = "Getting destination context object for tier 2 copy -> Subscription: $($DestinationStorageAccount.SubscriptionId) DestStorageAccount: $($DestinationStorageAccount.storageAccountName) DestStorageAccountResourceGroup $($DestinationStorageAccount.resourceGroupName)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $destContext = (Get-AzureRmStorageAccount -ResourceGroupName $DestinationStorageAccount.resourceGroupName -Name $DestinationStorageAccount.storageAccountName).Context
    if ($destContext -eq $null)
    {
        $msg = "An error occured. Context object could not be retrieved from destination storage account $($DestinationStorageAccount.storageAccountName) at resource group $($DestinationStorageAccount.resourceGroupName) at subscription $($SourceStorageAccount.SubscriptionId)"
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    
        throw "Context object could not be retrieved from destination storage account $($DestinationStorageAccount.storageAccountName) at resource group $($DestinationStorageAccount.resourceGroupName) at subscription $($SourceStorageAccount.SubscriptionId)"
    }
}
catch
{
    $msg = "An error occured selecting the destination subscription or getting the storage context.`nDetails of this copy process:$VhdDetails`nDestination Subscription: $($DestinationStorageAccount.SubscriptionId), Destination Storage Account: $($DestinationStorageAccount.storageAccountName), Dest. Storage Account RG: $($DestinationStorageAccount.resourceGroupName)`nError: $_"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

    throw "An error occured selecting the destination subscription or getting the storage context.`nDetails of this copy process:$VhdDetails`nDestination Subscription: $($DestinationStorageAccount.SubscriptionId), Destination Storage Account: $($DestinationStorageAccount.storageAccountName), Dest. Storage Account RG: $($DestinationStorageAccount.resourceGroupName)`nError: $_"
}

# Check container and create if does not exist
$msg = "Check container and create if does not exist" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$container = Get-AzureStorageContainer -Context $destContext -Name $DestinationStorageAccount.container -ErrorAction SilentlyContinue

if ($container -eq $null)
{
    $msg = "Creating container $($DestinationStorageAccount.container)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    New-AzureStorageContainer -Name $DestinationStorageAccount.container -Context $destContext -Permission Off
}

# Start the copy process to tier 2 storage account
$msg = "Starting tier 2 blob copy job to storage account $($DestinationStorageAccount.storageAccountName) from $($SourceStorageAccount.storageAccountName)" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$vhdInfo = $VhdDetails | ConvertFrom-Json
$copyStartTime = $([datetime]::UtcNow)

$msg = "VHD Details: $vhdDetails"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

try
{
    $msg = "Calling Start-AzureRmImgMgmtVhdCopy with the parameters: sourceContainer $($SourceStorageAccount.container), sourceContext $sourceContext, destContainer $($DestinationStorageAccount.container), destContext $destContext, sourceBlobName $SourceBlobName, destBlobName $($vhdInfo.vhdName)" 
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    Start-AzureRmImgMgmtVhdCopy -sourceContainer $SourceStorageAccount.container `
        -sourceContext $sourceContext `
        -destContainer $DestinationStorageAccount.container `
        -destContext $destContext `
        -sourceBlobName $SourceBlobName `
        -destBlobName $vhdInfo.vhdName

    $msg = "Wait copy completion"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $state = Get-AzureStorageBlobCopyState -Blob $vhdInfo.vhdName -Container $DestinationStorageAccount.container -Context $destContext -WaitForComplete

    $elapsedTime = $((New-TimeSpan ($CopyStartTime) $($state.CompletionTime.DateTime)).minutes)
    $msg = "Tier 2 Copy concluded for VHD $($vhdInfo.vhdName) on destination SA $($destContext.StorageAccount). Elapsed time in minutes: $elapsedTime "
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2DistributionCopyConcluded) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    # Add info in the queue to create the images
    $msg = "Add message in the images queue to create the images"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    Select-AzureRmSubscription -SubscriptionId $tier0SubscriptionId

    $queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

    $imageCreationQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                            -storageAccountName  $queueInfo.storageAccountName `
                                            -queueName $queueInfo.imageCreationQueueName

    $vhdMessage = @{ "location"=$DestinationStorageAccount.location;
                    "imageName"=$vhdInfo.imageName;
                    "imagesResourceGroup"=$DestinationStorageAccount.imagesResourceGroup;
                    "osType"=$vhdInfo.osType;
                    "subscriptionId"=$DestinationStorageAccount.subscriptionId;
                    "vhdUri"=[string]::Format("{0}{1}/{2}",$destContext.BlobEndPoint,$DestinationStorageAccount.container,$vhdInfo.vhdName);
                    "jobId"=$vhdInfo.jobId}
                    
    Add-AzureRmStorageQueueMessage -queue $imageCreationQueue -message $vhdMessage
}
catch
{
    # Making the Automation Account available again and stopping further processing
    $msg = "An error occured. Making the Automation Account available again and stopping further processing next scheduled time.`nError Details:`n$_"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

     # Increases automation account availability
    $customFilter = "(PartitionKey eq 'automationAccount') and (automationAccountName eq `'" + $AutomationAccountName + "`')"
    $AutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $configurationTable

    Update-AzureRmImgMgmtAutomationAccountAvailabilityCount -table $configurationTable -AutomationAccount $AutomationAccount

    throw $_
}

# Increases automation account availability
$msg = "Increases automation account availability"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$customFilter = "(PartitionKey eq 'automationAccount') and (automationAccountName eq `'" + $AutomationAccountName + "`')"
$AutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $configurationTable

Update-AzureRmImgMgmtAutomationAccountAvailabilityCount -table $configurationTable -AutomationAccount $AutomationAccount

$msg = "$module execution completed" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)


