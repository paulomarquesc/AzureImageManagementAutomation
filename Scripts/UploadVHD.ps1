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
        .\UploadVHD.ps1 -description "test submission 01" `
            -Tier0SubscriptionId $Tier0SubscriptionId `
            -ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName `
            -ConfigStorageAccountName $ConfigStorageAccountName `
            -ImageName $imgName `
            -VhdFullPath "c:\temp\Test2016-Img01.vhd" `
            -OsType "Windows" `
            -ImageResourceGroupName "Images-RG01"
    
#>
using module AzureRmImageManagement

Param
(
    [Parameter(Mandatory=$true)]
    [string]$ConfigStorageAccountResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$ConfigStorageAccountName,

    [Parameter(Mandatory=$true)]
    [string]$Description,
    
    [Parameter(Mandatory=$false)]
    [AllowNull()]
    [string]$ConfigurationTableName= "imageManagementConfiguration",

    [Parameter(Mandatory=$true)]
    [string] $VhdFullPath,

    [Parameter(Mandatory=$true)]
    [string] $ImageName,

    [Parameter(Mandatory=$true)]
    [string] $ImageResourceGroupName,

    [Parameter(Mandatory=$false)]
    [string] $UploaderThreadNumber = 10,

    [Parameter(Mandatory=$false)]
    [switch] $Overwrite,

    [Parameter(Mandatory=$true)]
    [string] $Tier0SubscriptionId,

    [Parameter(Mandatory=$true)]
    [ValidateSet("Windows","Linux")]
    [string]$OsType
)

Import-Module AzureRmStorageTable
Import-Module AzureRmStorageQueue

$moduleName = Split-Path $MyInvocation.MyCommand.Definition -Leaf
$ErrorActionPreference = "Stop"

Write-Verbose "Starting upload script" -Verbose

Select-AzureRmSubscription -SubscriptionId $Tier0SubscriptionId

# Getting a reference to the configuration table
$configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

# Getting appropriate job tables
$jobTablesInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "PartitionKey eq 'logConfiguration'" -table $configurationTable

if ($jobTablesInfo -eq $null)
{
    throw "System configuration table does not contain configuartion item for job submission and logging."
}

# Getting the Job Submission and Job Log table
$jobsTable = Get-AzureStorageTableTable -resourceGroup $jobTablesInfo.resourceGroupName -StorageAccountName $jobTablesInfo.storageAccountName -tableName $jobTablesInfo.jobTableName
$log = Get-AzureStorageTableTable -resourceGroup $jobTablesInfo.resourceGroupName -StorageAccountName $jobTablesInfo.storageAccountName -tableName $jobTablesInfo.jobLogTableName

$jobId = [guid]::NewGuid().guid

Write-Verbose "JOB ID: $jobID" -Verbose

# Creating job submission information
$submissionDateUTC = (get-date -date ([datetime]::utcnow) -Format G)
Add-AzureRmRmImgMgmtJob -logTable $log -jobId $jobId -description $Description -submissionDate $submissionDateUTC -status ([status]::InProgress) -jobsTable $jobsTable

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises)
$msg = "Obtaining the tier 0 storage account (the one that receives the vhd from on-premises)"
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$tier0StorageAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable

if ($tier0StorageAccount -eq $null)
{
    $msg = "System configuration table does not contain a configured tier 0 storage account which is where the VHD is uploaded from on-premises and starts the distribution process."
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    throw $msg
}
else
{
    $msg = "Tier 0 Storage account name: $($tier0StorageAccount.StorageAccountName)"
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
}

# Checking if VHD file exists
$msg = "Checking if local VHD file ($VhdFullPath) exists"
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

if (!(Test-Path $VhdFullPath))
{
    $msg = "VHD file $VhdFullPath not found."
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    throw $msg
}

# Uploading the VHD

# TODO: Implement log - start
$uri = [string]::Format("https://{0}.blob.core.windows.net/{1}/{2}",$tier0StorageAccount.StorageAccountName,$tier0StorageAccount.container,[system.io.path]::GetFileName($VhdFullPath))

$msg = "Starting uploading VHD to $uri"
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

try
{
    Add-AzureRmVhd `
        -ResourceGroupName $tier0StorageAccount.resourceGroupName `
        -Destination $uri `
        -LocalFilePath $VhdFullPath `
        -NumberOfUploaderThreads $uploaderThreadNumber `
        -OverWrite:$overrite

    $msg = "Uploading VHD ($VhdFullPath) completed"
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
}
catch
{
    $msg = "An error occured executing Add-AzureRmVhd."
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)   
    
    $msg = "Error Details: $_"
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

    throw $_
}

# Getting Main Automation Account information
$msg = "Getting Main Automation Account information"
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$mainAutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'automationAccount') and (type eq 'main')" -table $configurationTable 

if ($mainAutomationAccount -eq $null)
{
    $msg = "Main automation account informaiton could not be found at the configuration table."
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    
    throw $msg
}

$msg = "Main Automation Account identified as $($mainAutomationAccount.automationAccountName) at resource group $($mainAutomationAccount.resourceGroupName)"
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$params = @{"Tier0SubscriptionId"=$tier0StorageAccount.SubscriptionId;
            "ConfigStorageAccountResourceGroupName"=$ConfigStorageAccountResourceGroupName;
            "ConfigStorageAccountName"=$ConfigStorageAccountName;
            "VhdName"=[system.io.path]::GetFileName($VhdFullPath);
            "ConfigurationTableName"=$ConfigurationTableName;
            "StatusCheckInterval"=60;
            "jobId"=$jobId}

$msg = "Starting tier1 distribution. Runbook Start-ImageManagementTier1Distribution with parameters: $($params | convertTo-json -Compress)"
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
        
try
{
    $job = Start-AzureRmAutomationRunbook  -Name "Start-ImageManagementTier1Distribution" `
                                           -Parameters $params `
                                           -AutomationAccountName $mainAutomationAccount.automationAccountName `
                                           -ResourceGroupName $mainAutomationAccount.resourceGroupName -Wait
    
    $msg = "Tier1 distribution completed"
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
}
catch
{
    $msg = "Tier1 distribution failed, execution of runbook Start-ImageManagementTier1Distribution failed."
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error) 

    $msg = "Error Details: $_"
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

    throw $_
}
# Place message in the copy queue to start tier 2 distribution (VHD copy to each storage account per region/subscription)

$queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

$copyQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                          -storageAccountName  $queueInfo.storageAccountName `
                                          -queueName $queueInfo.copyProcessQueueName

$vhdMessage = @{ "vhdName"=[system.io.path]::GetFileName($VhdFullPath);
                 "imageName"=$ImageName;
                 "osType"=$osType;
                 "imageResourceGroupName"=$ImageResourceGroupName;
                 "jobId"=$jobId}

$msg = "Placing message in the queue for tier2 distribution process (VHD copy to each subscription and related regions)."
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$msg = $vhdMessage | convertTo-json -Compress
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::copyProcessMessage) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
                 
Add-AzureRmStorageQueueMessage -queue $copyQueue -message $vhdMessage

$msg = "Upload script execution completed."
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
