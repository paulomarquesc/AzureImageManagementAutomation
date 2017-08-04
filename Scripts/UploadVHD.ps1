<#
    .SYNOPSIS
        Uploads the VHD to Azure Storage account (tier 0 in the image management process) and starts the replication process. 
    .DESCRIPTION
        Uploads the VHD to Azure Storage account (tier 0 in the image management process) and starts the replication process.
        Must be executed by an user account that has at least contributor access to the solution storage accounts, meaning,
        tier 0 storage account and the storage account that has the system configuration tables.
        Images will be created in the same location as the tier 2 storage account in a resource group defined when calling this script.
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name where the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER VhdFullPath
        Full path (path + file name) of the VHD to be uploaded to the tier 0 storage account
    .PARAMETER ImageName
        Name of the Image that will be generated after the VHD is copied to all subscriptions
    .PARAMETER ImageResourceGroupName
        Name of the resource group where the image will be created.
    .PARAMETER UploaderThreadNumber
        Number of threads used by Add-AzureRmVhd cmdlet to speed up the upload process, if not provided, it will default to 10 threads.
    .PARAMETER Overwrite
        Indicates if file must be overwriten or not, default to no if switch is not provided. 
    .PARAMETER Tier0SubscriptionId
        Tier 0 subscription Id, this is the subscription that contains all runbooks, config storage account and receives the VHD upload from on-premises.
    .PARAMETER OsType
        VHD's Operating System type, valid ones are Windows and Linux.  
    .EXAMPLE
        .\UploadVHD.ps1 -Tier0SubscriptionId $Tier0SubscriptionId `
                -ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName `
                -ConfigStorageAccountName $ConfigStorageAccountName `
                -ImageName $imageName `
                -VhdFullPath c:\temp\newvhd.vhd `
                -OsType "Windows"
    
#>
Param
(
    [Parameter(Mandatory=$true)]
    [String] $ConfigStorageAccountResourceGroupName,

    [Parameter(Mandatory=$true)]
    [String] $ConfigStorageAccountName,
    
    [Parameter(Mandatory=$false)]
    [AllowNull()]
    [string]$ConfigurationTableName= "imageManagementConfiguration",

    [Parameter(Mandatory=$true)]
    [String] $VhdFullPath,

    [Parameter(Mandatory=$true)]
    [String] $ImageName,

    [Parameter(Mandatory=$true)]
    [String] $ImageResourceGroupName,

    [Parameter(Mandatory=$false)]
    [String] $UploaderThreadNumber = 10,

    [Parameter(Mandatory=$false)]
    [switch] $Overwrite,

    [Parameter(Mandatory=$true)]
    [string] $Tier0SubscriptionId,

    [Parameter(Mandatory=$true)]
    [ValidateSet("Windows","Linux")]
    [string]$OsType
)
$ErrorActionPreference = "Stop"

Import-Module AzureRmStorageTable
Import-Module AzureRmStorageQueue

Write-Verbose "Starting upload script" -Verbose

Select-AzureRmSubscription -SubscriptionId $Tier0SubscriptionId

# Variables
#$logTableName = "ImageManagementLogs"

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises)
$configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
#$logTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $logTableName

$tier0StorageAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable 
# TODO: Implement log

if ($tier0StorageAccount -eq $null)
{
    # TODO: Implement log
    throw "System configuration table does not contain a configured tier 0 storage account which is where the VHD is uploaded from on-premises and starts the distribution process."
}

# Checking if VHD file exists
if (!(Test-Path $VhdFullPath))
{
    # TODO: Implement log
    throw "VHD file $VhdFullPath not found."
}

# Uploading the VHD

# TODO: Implement log - start
$uri = [string]::Format("https://{0}.blob.core.windows.net/{1}/{2}",$tier0StorageAccount.StorageAccountName,$tier0StorageAccount.container,[system.io.path]::GetFileName($VhdFullPath))
Add-AzureRmVhd `
    -ResourceGroupName $tier0StorageAccount.resourceGroupName `
    -Destination $uri `
    -LocalFilePath $VhdFullPath `
    -NumberOfUploaderThreads $uploaderThreadNumber `
    -OverWrite:$overrite

# TODO: Implement log - end

# TODO: Implement log - start runbook
# Execute runbook to copy VHD to tier 1 storage accounts
# TODO: Implement runbook

# Getting Main Automation Account information
$mainAutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'automationAccount') and (type eq 'main')" -table $configurationTable 

if ($mainAutomationAccount -eq $null)
{
    throw "Main automation account informaiton could not be found at the configuration table."
}

$params = @{"Tier0SubscriptionId"=$tier0StorageAccount.SubscriptionId;
            "ConfigStorageAccountResourceGroupName"=$ConfigStorageAccountResourceGroupName;
            "ConfigStorageAccountName"=$ConfigStorageAccountName;
            "VhdName"=[system.io.path]::GetFileName($VhdFullPath);
            "ConfigurationTableName"=$ConfigurationTableName;
            "StatusCheckInterval"=60}

$job = Start-AzureRmAutomationRunbook  -Name "Start-ImageManagementTier1Distribution" `
                                       -Parameters $params `
                                       -AutomationAccountName $mainAutomationAccount.automationAccountName `
                                       -ResourceGroupName $mainAutomationAccount.resourceGroupName -Wait

# TODO: Implement log - end runbook

# Place message in the copy queue for each subscription

# Going to need the images resource group in each subscription

# TODO: Implement log

$queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

$copyQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                          -storageAccountName  $queueInfo.storageAccountName `
                                          -queueName $queueInfo.copyProcessQueueName

$vhdMessage = @{ "vhdName"=[system.io.path]::GetFileName($VhdFullPath);
                 "imageName"=$ImageName;
                 "osType"=$osType;
                 "imageResourceGroupName"=$ImageResourceGroupName}

Add-AzureRmStorageQueueMessage -queue $copyQueue -message $vhdMessage
