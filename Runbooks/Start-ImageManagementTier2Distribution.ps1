<#
    .SYNOPSIS
        Starts the job that uploads the VHD to tier 2 storage accounts (storage accounts located in other subscriptions or that will be used to create an image from.. 
    .DESCRIPTION
        Starts the job that uploads the VHD to tier 2 storage accounts (storage accounts located in other subscriptions or that will be used to create an image from.
        Tier 2 storage accounts are the ones that will be used as source for the image creation in each subscription.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name of the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables.
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER Tier0SubscriptionId
        Tier 0 subscription Id, this is the subscription that contains all runbooks, config storage account and receives the VHD upload from on-premises. 
    .PARAMETER connectionName
        RunAs account to be used. 

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
    [string] $Tier0SubscriptionId,

    [Parameter(Mandatory=$false)]
    $connectionName="AzureRunAsConnection"
)

$ErrorActionPreference = "Stop"
$moduleName = "Start-ImageManagementTier2Distribution"

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

write-output "Selecting Tier 0 subscription $Tier0SubscriptionId" 
Select-AzureRmSubscription -SubscriptionId $Tier0SubscriptionId

$tempJobId = [guid]::newGuid().guid

# Getting the configuration table
$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

if ($configurationTable -eq $null)
{
    throw "Configuration table $configurationTableName could not be found at resourceGroup $ConfigStorageAccountResourceGroupName, Storage Account $configStorageAccountName, subscription $Tier0SubscriptionId"
}

# Getting the Job Log table
$log =  Get-AzureRmImgMgmtLogTable -configurationTable $configurationTable 

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD
$msg = "Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$tier0StorageAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable 

if ($tier0StorageAccount -eq $null)
{
    $msg = "System configuration table does not contain a configured tier 0 storage account which is where the VHD is uploaded from on-premises and starts the distribution process."
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    throw $msg
}
else
{
    $msg = "Tier 0 Storage account name: $($tier0StorageAccount.StorageAccountName)"
    
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
}

# Obtaining the tier 2 storage accounts that are the final destination of the VHDs 
$msg = "Obtaining the tier 2 storage accounts that are the final destination of the VHDs" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$tier2StorageAccountList = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 2)" -table $configurationTable
$msg = "Tier2 Storage Account count: $($tier2StorageAccountList.count)" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

if ($tier2StorageAccountList -eq $null)
{
    $msg = "System configuration table does not contain tier 2 storage accounts."
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    throw $msg
}

# Getting copy process queue information
$msg = "# Getting copy process queue information" 

Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

if ($queueInfo -eq $null)
{
    $msg = "Queue information could not be retrieved from configuration table"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    throw $msg
}
else
{
    $msg = "Queue information -> resourceGroupName $($queueInfo.storageAccountResourceGroupName), storageAccountName $($queueInfo.storageAccountName), queueName $($queueInfo.copyProcessQueueName)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
}

$copyQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                          -storageAccountName  $queueInfo.storageAccountName `
                                          -queueName $queueInfo.copyProcessQueueName

# Getting source storage (tier0) account context
$msg = "Getting source storage (tier0) account context"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

try
{
    $sourceContext = Get-AzureRmImgMgmtStorageContext -ResourceGroupName $tier0StorageAccount.resourceGroupName `
                                                    -StorageAccountName $tier0StorageAccount.storageAccountName
}
catch
{
    $msg = "An error occured getting the storage context.`nError: $_"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

    throw $msg
}

$msg = "Checking queue for a vhd to process"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

# Dequeing a copy job
$vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $copyQueue

while ($vhdToProcess -ne $null)
{
    # Deleting the message from queue - we don't place it back if an error happens
    Remove-AzureRmStorageQueueMessage -queue $copyQueue -message $vhdToProcess

    $msg = "Processing message from queue $($vhdToProcess.AsString)"
    
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
    # Getting list of source blobs
    $vhdInfo = $vhdToProcess.AsString | ConvertFrom-Json
    $jobid = $vhdInfo.JobId

    # Updating all temporary job Ids with the current job Id
    Update-AzureRmImgMgmtLogJobId -tempJobId $tempJobId -finalJobId $jobid -logTable $log

    $msg = "Getting list of source blobs"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
    $blobList = Get-AzureStorageBlob -Container $tier0StorageAccount.container -Blob "$($vhdInfo.vhdName)-tier1*" -Context $sourceContext

    $msg = "Tier 1 blob list count: $($blobList.count). Randomizing this list."
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
    # Randomizing blob list
    $blobList = $blobList | Get-Random -Count $blobList.Count

    # Invoke a runbook copy process for each tier 2 storage

    # Start a copy runbook job for each tier 2 storage account
    $msg = "Start a copy runbook job for each tier 2 storage account"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
    for ($i=0;$i -lt $tier2StorageAccountList.count;$i++)
    {
        $sourceBlobIndex = ($i % $blobList.count)

        try
        {
            $msg = "Getting available automation accounts"
            Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

            $automationAccount = Get-AzureRmImgMgmtAvailableAutomationAccount -table $configurationTable -AutomationAccountType "copyDedicated" 

            $msg = "Automation account count $($automationAccount.count)"
            Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

            $msg = "Start job for tier 2 storageaccount $($tier2StorageAccountList[$i].StorageAccountName) getting data from storage account $($blobList[$sourceBlobIndex].Context.StorageAccountName), blobName $($blobList[$sourceBlobIndex].Name))"  
            Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
            $msg = "Job will be started at $($automationAccount.automationAccountName)"
            Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
            # Parameters to be passed on to the runbook
            $params = @{"SourceStorageAccount"=$tier0StorageAccount;
                        "SourceBlobName"=$blobList[$sourceBlobIndex].Name;
                        "DestinationStorageAccount"=$tier2StorageAccountList[$i];
                        "VhdDetails"=$vhdToProcess.AsString;
                        "ConnectionName"=$automationAccount.connectionName;
                        "ConfigStorageAccountResourceGroupName"=$ConfigStorageAccountResourceGroupName;
                        "ConfigStorageAccountName"=$ConfigStorageAccountName;
                        "ConfigurationTableName"=$ConfigurationTableName;
                        "AutomationAccountName"=$automationAccount.automationAccountName;
                        "Tier0SubscriptionId"=$tier0SubscriptionId;
                        "jobId"=$jobId}
            
            $msg = "Data being passed to Start-ImageManagementVhdCopyTier2 runbook:"
            Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
                
            $msg = $params | convertTo-json -Compress
            Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
            
            try
            {
                Start-AzureRmAutomationRunbook -Name "Start-ImageManagementVhdCopyTier2" `
                    -Parameters $params `
                    -AutomationAccountName $automationAccount.automationAccountName `
                    -ResourceGroupName $automationAccount.resourceGroupName
            }
            catch
            {
                $msg = "An error ocurred starting Start-ImageManagementVhdCopyTier2."
                Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error) 
            
                $msg = "Error Details: $_"
                Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
            
                throw $_
            }
        }
        catch
        {
            $msg = "An error occured: `n$_"
            Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

            # Removing temporary job id entries if any
            Remove-AzureRmImgMgmtLogTemporaryJobIdEntry -tempJobId $tempJobId -logTable $log

            throw $_
        }
    }

    $msg = "Checking queue for new vhd copy process job"
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    Start-Sleep -Seconds 60
    $vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $copyQueue
}

$msg = "Runbook execution completed"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier2Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

# Removing temporary job id entries if any
Remove-AzureRmImgMgmtLogTemporaryJobIdEntry -tempJobId $tempJobId -logTable $log
