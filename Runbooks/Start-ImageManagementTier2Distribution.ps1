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

# TODO: instantiate log table
#$logTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $logTableName

# Getting the configuration table
$configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD
Write-Output "Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD" 

$tier0StorageAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable 
# TODO: Implement log

if ($tier0StorageAccount -eq $null)
{
    # TODO: Implement log
    throw "System configuration table does not contain a configured tier 0 storage account which is where the VHD is uploaded from on-premises and starts the distribution process."
}

# Obtaining the tier 2 storage accounts that are the final destination of the VHDs 
write-output "Obtaining the tier 2 storage accounts that are the final destination of the VHDs" 
$tier2StorageAccountList = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 2)" -table $configurationTable
# TODO: Implement log

if ($tier2StorageAccountList -eq $null)
{
    # TODO: Implement log
    throw "System configuration table does not contain tier 2 storage accounts."
}

# Get a VHD to process
$queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

$copyQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                          -storageAccountName  $queueInfo.storageAccountName `
                                          -queueName $queueInfo.copyProcessQueueName

# Getting source storage (tier0) account context
Write-Verbose " Getting source storage (tier0) account context" -Verbose

$sourceContext = (Get-AzureRmStorageAccount -ResourceGroupName $tier0StorageAccount.resourceGroupName -Name $tier0StorageAccount.storageAccountName).Context

$vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $copyQueue

$exitMainLoop = $false

while (($vhdToProcess -ne $null) -and !$exitMainLoop)
{
    write-output "processing message $($vhdToProcess.AsString)"
    # Getting list of source blobs
    $vhdInfo = $vhdToProcess.AsString | ConvertFrom-Json
    $blobList = Get-AzureStorageBlob -Container vhd -Blob "$($vhdInfo.vhdName)-tier1*" -Context $sourceContext
    # Randomizing blob list
    $blobList = $blobList | Get-Random -Count $blobList.Count

    # Invoke a runbook copy process for each tier 2 storage

    # Start a copy runbook job for each tier 2 storage account
    for ($i=0;$i -lt $tier2StorageAccountList.count;$i++)
    {
        $sourceBlobIndex = ($i % $blobList.count)

        try
        {
            Write-Output "Getting available automation accounts"
            Write-Output "Before getting the list - automation account count $($automationAccount.count)"
            Write-Output -InputObject $automationAccount
            $automationAccount = Get-AzureRmImgMgmtAvailableAutomationAccount -table $configurationTable -AutomationAccountType "copyDedicated" 
            Write-Output "automation account count $($automationAccount.count)"
        }
        catch
        {
            # An error occured, placing message back into the queue for later processing
            Update-AzureRmStorageQueueMessage -queue $copyQueue -message $vhdToProcess -visibilityTimeout 0
            write-output "There is no available automation account at this moment: `n$_"
            $exitMainLoop = $true

            break
        }
        
        write-output "Start job for tier 2 storageaccount $($tier2StorageAccountList[$i].StorageAccountName) getting data from storage account $($blobList[$sourceBlobIndex].Context.StorageAccountName), blobName $($blobList[$sourceBlobIndex].Name))"  
        write-output "Job will be started at $($automationAccount.automationAccountName)"  

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
                    "Tier0SubscriptionId"=$tier0SubscriptionId}

        Write-Output "Data being passed to Start-ImageManagementVhdCopyTier2 runbook:"
        Write-Output -InputObject $automationAccount

        Start-AzureRmAutomationRunbook -Name "Start-ImageManagementVhdCopyTier2" `
                                              -Parameters $params `
                                              -AutomationAccountName $automationAccount.automationAccountName `
                                              -ResourceGroupName $automationAccount.resourceGroupName
        
        write-output "Current available jobs for automation account $($automationAccount.availableJobsCount)"

        # Decrease availableJobs at the automation account
        write-output "Updating automation account availability" 
        Update-AzureRmImgMgmtAutomationAccountAvailabilityCount -table $configurationTable -AutomationAccount $automationAccount -Decrease
    }

    # TODO: Implement Log for copy statuses

    # Get next message in the queue
    if (!$exitMainLoop)
    {
        Start-Sleep -Seconds 30
        $vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $copyQueue
    }
}
