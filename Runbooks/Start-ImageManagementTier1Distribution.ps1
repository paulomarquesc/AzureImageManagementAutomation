<#
    .SYNOPSIS
        Uploads the VHD to tier 1 storage accounts (storage accounts local to tier 0 storage account. 
    .DESCRIPTION
        Uploads the VHD to tier 1 storage accounts (storage accounts local to tier 0 storage account.
        Main reason tier 1 storage accounts exists is to be able to handle high traffic between main subscription and other subscriptions.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name of the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to imagemanagementconfiguration, which is the preferred name.
    .PARAMETER VhdName
        Name of the VHD to be uploaded to the tier 1 storage accounts
    .PARAMETER StatusCheckInterval
        Time in minutes where that the blob copy jobs are pulled for status, default is 60 minutes. 
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

    [Parameter(Mandatory=$true)]
    [String] $VhdName,

    [Parameter(Mandatory=$false)]
    [String] $ConfigurationTableName="ImageManagementConfiguration",

    [Parameter(Mandatory=$false)]
    [int] $StatusCheckInterval = 15,

    [Parameter(Mandatory=$true)]
    [string] $Tier0SubscriptionId,

    [Parameter(Mandatory=$false)]
    $connectionName="AzureRunAsConnection"
)

# Variables

Write-Output "Authenticating with connection $connectionName" 

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

Write-Output "Selecting Tier 0 subscription $Tier0SubscriptionId" 
Select-AzureRmSubscription -SubscriptionId $Tier0SubscriptionId

# TODO: instantiate log table
#$logTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $logTableName

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD
Write-Output "Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD" 
$configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

$tier0StorageAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable 
# TODO: Implement log

if ($tier0StorageAccount -eq $null)
{
    # TODO: Implement log
    throw "System configuration table does not contain a configured tier 0 storage account which is where the VHD is uploaded from on-premises and starts the distribution process."
}

Write-Output "Getting tier 0 storage account $($tier0StorageAccount.storageAccountName) context from resource group $($tier0StorageAccount.resourceGroupName)" 
$sourceContext = (Get-AzureRmStorageAccount -ResourceGroupName $tier0StorageAccount.resourceGroupName -Name $tier0StorageAccount.storageAccountName).Context
if ($sourceContext -eq $null)
{
    throw "Context object could not be retrieved from tier 0 storage account $($tier0StorageAccount.storageAccountName) at resource group $($tier0StorageAccount.resourceGroupName)"
}

# Start the copy process to tier 1 blobs
$pendingCopies = New-Object System.Collections.Generic.List[System.String]

for ($i=0;$i -lt $tier0StorageAccount.tier1Copies;$i++)
{
    Write-Output "Starting tier 1 blob copy job on tier  0 storage account $($tier0StorageAccount.storageAccountName) - copy # $($i)" 
    $destBlobName = [string]::Format("{0}-tier1-{1}",$VhdName,$i.ToString("000"))
    
    Start-AzureRmImgMgmtVhdCopy -sourceContainer $tier0StorageAccount.container `
        -sourceContext $sourceContext `
        -destContainer $tier0StorageAccount.container `
        -destContext $sourceContext `
        -sourceBlobName $VhdName `
        -destBlobName  $destBlobName `
        -RetryWaitTime 30
 
    $pendingCopies.Add($destBlobName)
}

# Check completion status
$passCount = 1

while ($pendingCopies.count -gt 0)
{
    Write-Output "current status check pass $passcount, pending copies: $($pendingCopies.count)" 

    for ($i=0;$i -lt $tier0StorageAccount.tier1Copies;$i++)
    {
        $destBlobName = [string]::Format("{0}-tier1-{1}",$VhdName,$i.ToString("000"))
        if ($pendingCopies.Contains($destBlobName))
        {
            $state = Get-AzureStorageBlobCopyState -Blob $destBlobName -Container $$tier0StorageAccount.container -Context $sourceContext

            if ($state.Status -ne "pending")
            {
                $pendingCopies.Remove($destBlobName)
            }
        }
    }
    Start-Sleep $StatusCheckInterval
    $passCount++

    # TODO: Implement timeout limit to avoid endless loop, throw exception for timeout to stop further processing also log the error

}

Write-Output "Tier 1 VHD copy succeeded" 

# TODO: Implement Log for copy statuses
