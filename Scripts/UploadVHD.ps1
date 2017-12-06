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
    .PARAMETER sourceAzureRmDiskName
        This parameter is used when the source VHD is based on a managed disk in Azure, this is the managed disk name.
    .PARAMETER sourceAzureRmDiskResourceGroup
        Resource Group name where the managed disk resides.
    .PARAMETER sourceAzureRmDiskAccessInSeconds
        Optional parameter that tells for how long this script will have access to the VHD, default value is 3600 seconds (1 hour)
    .PARAMETER vhdName
        When getting the source VHD from the managed disk, there is no VHD name, it defaults to abc, this parameter gives the name of the blob that will be copied to
        the tier 0 storage account to start the VHD distribution.
    
    .EXAMPLE
        # Using local VHD
        .\UploadVHD.ps1 -description "test submission 01" `
            -Tier0SubscriptionId $Tier0SubscriptionId `
            -ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName `
            -ConfigStorageAccountName $ConfigStorageAccountName `
            -ImageName $imgName `
            -VhdFullPath "c:\temp\Test2016-Img01.vhd" `
            -OsType "Windows" `
            -ImageResourceGroupName "Images-RG01"

    .EXAMPLE
        # Using managed disk SAS Token based URI
        .\UploadVHD.ps1 -description "test submission 02" `
            -Tier0SubscriptionId $Tier0SubscriptionId `
            -ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName `
            -ConfigStorageAccountName $ConfigStorageAccountName `
            -ImageName $imgName `
            -sourceAzureRmDiskName "centos01_OsDisk_1_28e8cc4091d142ebb3a820a0c703e811" `
            -sourceAzureRmDiskResourceGroup "test" `
            -vhdName "centos-golden-image.vhd" `
            -OsType "Linux" `
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

    [Parameter(Mandatory=$true,ParameterSetName="localVhd")]
    [string] $VhdFullPath,

    [Parameter(Mandatory=$true,ParameterSetName="sasToken")]
    [string] $sourceAzureRmDiskName,

    [Parameter(Mandatory=$true,ParameterSetName="sasToken")]
    [string] $sourceAzureRmDiskResourceGroup,

    [Parameter(Mandatory=$false,ParameterSetName="sasToken")]
    [int] $sourceAzureRmDiskAccessInSeconds=3600,

    [Parameter(Mandatory=$true,ParameterSetName="sasToken")]
    [string] $vhdName,

    [Parameter(Mandatory=$true)]
    [string] $ImageName,

    [Parameter(Mandatory=$true)]
    [string] $ImageResourceGroupName,

    [Parameter(Mandatory=$false,ParameterSetName="localVhd")]
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

Write-Verbose "Getting configuration information" -Verbose

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

# Uploading the VHD
Write-Verbose "Uploading the VHD" -Verbose

if ($PSCmdlet.ParameterSetName -eq "localVhd")
{
    $msg = "Using the local vhd upload option"
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    # Checking if local VHD file exists
    $msg = "Checking if local VHD file ($VhdFullPath) exists"
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    if (!(Test-Path $VhdFullPath))
    {
        $msg = "VHD file $VhdFullPath not found."
        Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
        throw $msg
    }

    $vhdName =[system.io.path]::GetFileName($VhdFullPath)

    $uri = [string]::Format("https://{0}.blob.core.windows.net/{1}/{2}",$tier0StorageAccount.StorageAccountName,$tier0StorageAccount.container,[system.io.path]::GetFileName($VhdFullPath))

    $msg = "Starting uploading VHD to $uri"
    Write-Verbose $msg -Verbose
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
        Write-Verbose $msg -Verbose
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

}
else
{
    $msg = "Copying VHD from managed disk option (directly in Azure)"
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    # Getting mananaged disk SAS token based URL
    try
    {
        $msg = "Getting mananaged disk SAS token based URL"
        Write-Verbose $msg -Verbose
        Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
        $sas = Grant-AzureRmDiskAccess -Access Read -DurationInSecond $sourceAzureRmDiskAccessInSeconds -ResourceGroupName $sourceAzureRmDiskResourceGroup -DiskName $sourceAzureRmDiskName

        $msg = "SAS Token based URL: $($sas.AccessSAS)"
        Write-Verbose $msg -Verbose
        Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    }
    catch  [Microsoft.Azure.Commands.Compute.Automation.GrantAzureRmDiskAccess]
    {
        $msg = "Disk $sourceAzureRmDiskName is currently attached to a VM in running state.`nError details: $_" 
        Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

        throw "Disk $sourceAzureRmDiskName is currently attached to a VM in running state.`nError details: $_"    
    }
    catch
    {
        $msg = "An error ocurred trying to get access to the managed disk VHD.`nError details: $_" 
        Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)

        throw $_
    }
    
    # Checking if VHD URL is accesible
    $msg = "Checking if VHD URL is accesible" 
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $HTTP_Request = [System.Net.WebRequest]::Create($sas.AccessSAS)
    $HTTP_Response = $HTTP_Request.GetResponse()
    $HTTP_Status = [int]$HTTP_Response.StatusCode
    $HTTP_Response.Close()

    if ($HTTP_Status -gt 200)
    {
        $msg = "Could not access managed disk using URI: $($sas.AccessSAS)"
        Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
        throw "Could not access managed disk using URI: $($sas.AccessSAS)"
    }

    # Getting tier 0 (destination) context
    $msg = "Getting tier 0 (destination) context"
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $destContext = (Get-AzureRmStorageAccount -ResourceGroupName $tier0StorageAccount.resourceGroupName -Name $tier0StorageAccount.storageAccountName).Context

    # Check if destination container exists
    $destContainer = Get-AzureStorageContainer -Name $tier0StorageAccount.container -Context $destContext -ErrorAction SilentlyContinue

    if ($destContainer -eq $null)
    {
        $msg = "Creating destination container $($tier0StorageAccount.container) on storage account $($tier0StorageAccount.storageAccountName) located in resource group $($tier0StorageAccount.resourceGroupName)"
        Write-Verbose $msg -Verbose
        Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
    
        New-AzureStorageContainer -Name $tier0StorageAccount.container -Context $destContext -Permission Off
    }
    
    $msg = "Starting copy process using Start-AzureStorageBlobCopy"
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    Start-AzureStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestContainer $tier0StorageAccount.container -DestBlob $vhdName -DestContext $destContext -Force

    $msg = "Wait for copy completion"
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $state = Get-AzureStorageBlobCopyState -Blob $vhdName -Container $tier0StorageAccount.container -Context $destContext -WaitForComplete

    $msg = "VHD Copy from managed disk to tier 0 storage account completed. Bytes copied $($state.bytesCopied) out of total $($state.TotalBytes)"
    Write-Verbose $msg -Verbose
    Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

}

# Getting Main Automation Account information
Write-Verbose "Initiating process to create the tier 1 copies (multiple copies of the blob in tier 0 storage account)" -Verbose
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
            "VhdName"=$vhdName;
            "ConfigurationTableName"=$ConfigurationTableName;
            "StatusCheckInterval"=60;
            "jobId"=$jobId}

$msg = "Starting tier1 distribution. Runbook Start-ImageManagementTier1Distribution with parameters: $($params | convertTo-json -Compress)"
Write-Verbose $msg -Verbose
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
        
try
{
    $job = Start-AzureRmAutomationRunbook  -Name "Start-ImageManagementTier1Distribution" `
                                           -Parameters $params `
                                           -AutomationAccountName $mainAutomationAccount.automationAccountName `
                                           -ResourceGroupName $mainAutomationAccount.resourceGroupName -Wait
    
    $msg = "Tier1 distribution completed"
    Write-Verbose $msg -Verbose
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

$vhdMessage = @{ "vhdName"=$vhdName;
                 "imageName"=$ImageName;
                 "osType"=$osType;
                 "imageResourceGroupName"=$ImageResourceGroupName;
                 "jobId"=$jobId}

$msg = "Placing message in the queue for tier2 distribution process (VHD copy to each subscription and related regions)."
Write-Verbose $msg -Verbose
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

$msg = $vhdMessage | convertTo-json -Compress
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::copyProcessMessage) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
                 
Add-AzureRmStorageQueueMessage -queue $copyQueue -message $vhdMessage

$msg = "Upload script execution completed."
Write-Verbose $msg -Verbose
Add-AzureRmImgMgmtLog -logTable $log -jobId $jobId -step ([steps]::upload) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
