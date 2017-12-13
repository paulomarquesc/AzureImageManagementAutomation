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
using module AzureRmImageManagement

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
    $connectionName="AzureRunAsConnection",

    [Parameter(Mandatory=$true)]
    $jobId
)

$ErrorActionPreference = "Stop"

# Variables
$moduleName = "Start-ImageManagementTier1Distribution.ps1"

Write-Output $moduleName

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

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD
Write-Output "Obtaining the tier 0 storage account (the one that receives the vhd from on-premises) - Source of recently uploaded VHD" 
$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

if ($configurationTable -eq $null)
{
    throw "Configuration table $configurationTableName could not be found at resourceGroup $ConfigStorageAccountResourceGroupName, Storage Account $configStorageAccountName, subscription $Tier0SubscriptionId"
}

# Getting the Job Log table
$log =  Get-AzureRmImgMgmtLogTable -configurationTable $configurationTable 

$msg = "Obtaining the tier 0 storage account (the one that receives the vhd from on-premises)"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$tier0StorageAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable 

if ($tier0StorageAccount -eq $null)
{
    $msg = "System configuration table does not contain a configured tier 0 storage account which is where the VHD is uploaded from on-premises and starts the distribution process."
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    throw $msg
}
else
{
    $msg = "Tier 0 Storage account name: $($tier0StorageAccount.StorageAccountName)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
}

$msg = "Getting tier 0 storage account $($tier0StorageAccount.storageAccountName) context from resource group $($tier0StorageAccount.resourceGroupName)" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

try
{
    $sourceContext = Get-AzureRmImgMgmtStorageContext -ResourceGroupName $tier0StorageAccount.resourceGroupName `
                                                    -StorageAccountName $tier0StorageAccount.storageAccountName
}
catch
{
    $msg = "An error occured getting the storage context.`nError: $_"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

    throw $msg
}

$msg = "Context successfuly obtained." 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

# Start the copy process to tier 1 blobs
$msg = "Starting the copy process to tier 1 blobs" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$pendingCopies = New-Object System.Collections.Generic.List[System.String]

for ($i=0;$i -lt $tier0StorageAccount.tier1Copies;$i++)
{
    $msg = "Starting tier 1 blob copy job on tier  0 storage account $($tier0StorageAccount.storageAccountName) - copy # $($i)" 
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
    $destBlobName = [string]::Format("{0}-tier1-{1}",$VhdName,$i.ToString("000"))

    $msg = "Tier 1 blob name: $destBlobName "
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
    try
    {
        Start-AzureRmImgMgmtVhdCopy -sourceContainer $tier0StorageAccount.container `
                                    -sourceContext $sourceContext `
                                    -destContainer $tier0StorageAccount.container `
                                    -destContext $sourceContext `
                                    -sourceBlobName $VhdName `
                                    -destBlobName  $destBlobName `
                                    -RetryWaitTime 30
 
        $pendingCopies.Add($destBlobName)
    
    }
    catch
    {
        $msg = "An error ocurred starting tier 1 copy from source blob $VhdName to destination blob $destBlobName on storage account $($sa.context.StorageAccountName)."
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error) 
    
        $msg = "Error Details: $_"
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    
        throw $_
    }
}

# Check completion status
$msg = "Checking tier 1 copy completion status"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
   
$passCount = 1

while ($pendingCopies.count -gt 0)
{
    $msg = "current status check pass $passcount, pending copies: $($pendingCopies.count)" 
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
       
    for ($i=0;$i -lt $tier0StorageAccount.tier1Copies;$i++)
    {
        $destBlobName = [string]::Format("{0}-tier1-{1}",$VhdName,$i.ToString("000"))
        if ($pendingCopies.Contains($destBlobName))
        {
            try
            {
                $state = Get-AzureStorageBlobCopyState -Blob $destBlobName -Container $tier0StorageAccount.container -Context $sourceContext
                
                if ($state.Status -ne "pending")
                {
                    $pendingCopies.Remove($destBlobName)
                    $msg = "Completed destination blobCopy: $destBlobName" 
                    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1DistributionCopyConcluded) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
                }   
            }
            catch
            {
                $msg = "An error ocurred during blobCopyState source status check on $destBlobName on storage account $($sourceContext.StorageAccountName) container $($tier0StorageAccount.container)."
                Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error) 
            
                $msg = "Error Details: $_"
                Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

                $pendingCopies.Remove($destBlobName)
            
                throw $_
            }

        }
    }
    Start-Sleep $StatusCheckInterval
    $passCount++
}

$msg = "Tier 1 VHD copy process concluded" 
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::tier1Distribution) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
