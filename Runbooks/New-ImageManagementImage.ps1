<#
    .SYNOPSIS
        Creates the image based on a VHD
    .DESCRIPTION
        Transfers the VHD file from the tier 1 storage to tier 2 storage.
        At the end it will place a message into the Image Creation queue for Images to be created
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name of the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables.
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER VhdDetails
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER ConnectionName
        RunAs ccount to be used. 
    .PARAMETER AutomationAccountName
        Name of the current automation account executing the runbook. 
    .PARAMETER Tier0SubscriptionId
        Name of the tier 0 subscription (the one that contains the configuration table). 
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
    [String] $VhdDetails,

    [Parameter(Mandatory=$false)]
    $connectionName="AzureRunAsConnection",
    
    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,
    
    [Parameter(Mandatory=$true)]
    [String] $Tier0SubscriptionId
)

$ErrorActionPreference = "Stop"
$moduleName = "New-ImageManagementImage.ps1"

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

# Selecting tier 0 subscription
Write-Output "Selecting tier 0 subscription $tier0SubscriptionId"
Select-AzureRmSubscription -SubscriptionId $tier0SubscriptionId

# Getting the configuration table
Write-Output "Getting the configuration table, resource group $ConfigStorageAccountResourceGroupName, storage account $configStorageAccountName, table name $configurationTableName"

$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

Write-Output "VHD Details: $VhdDetails"
$vhdInfo = $VhdDetails | ConvertFrom-Json

# Getting the Job Log table
Write-Output "Getting the Job Log table"
$log =  Get-AzureRmImgMgmtLogTable -configurationTable $configurationTable

$msg = "VHD information to create the image: $VhdDetails"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

try
{
    $msg = "Selecting tier 2 subscription $($vhdInfo.subscriptionId)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    Select-AzureRmSubscription -SubscriptionId $vhdInfo.subscriptionId
    
    # Check if resource group exists, throw an error if not
    $rg = Get-AzureRmResourceGroup -Name $vhdInfo.imagesResourceGroup -ErrorAction SilentlyContinue
    if ($rg -eq $null)
    {
        $msg = "Resource group $($vhdInfo.subscriptionId) is missing, please create it and make sure to assign Contributor role to service principal $($servicePrincipalConnection.ApplicationId)"
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
        
        throw $msg
    }

    # Appending location to the image name
    $imageName = [string]::Format("{0}.{1}",$vhdInfo.imageName,$vhdInfo.location)

    $msg = "Final image name is $imageName"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId  -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    # Check if image exists, create if not
    $image = Find-AzureRmResource -ResourceGroupName $vhdInfo.imagesResourceGroup -Name $vhdInfo.imageName -ResourceType Microsoft.Compute/images
    if ($image -ne $null)
    {
        $msg = "Image $imageName already exists, deleting image before proceeding."
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId  -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
        Remove-AzureRmImage -ResourceGroupName $vhdInfo.imagesResourceGroup -ImageName $imageName -Force
    }

    Start-Sleep -Seconds 15 # Give some time for the platform replicate the change

    $msg = "Creating new image $imageName"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId  -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $imageConfig = New-AzureRmImageConfig -Location $vhdInfo.location
    $imageConfig = Set-AzureRmImageOsDisk -Image $imageConfig -OsType $vhdInfo.osType -OsState Generalized -BlobUri $vhdInfo.vhdUri

    New-AzureRmImage -ImageName $imageName -ResourceGroupName $vhdInfo.imagesResourceGroup -Image $imageConfig

    $msg = "Image sucessfully create: $imageName"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId  -step ([steps]::imageCreationConcluded) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $msg = "Cleaning up blobs from storage accounts if job is concluded"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId  -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $job = Get-AzureRmImgMgmtJob -configurationTable $configurationTable -JobId $vhdInfo.JobId  
    $status = Get-AzureRmImgMgmtJobStatus -configurationTable $configurationTable -job $job
    if ($status.isCompleted())
    {
        $msg = "Job ($vhdInfo.JobId) is completed, performing clean up."
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId  -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
        Remove-AzureRmImgMgmtJobBlob -configurationTable $configurationTable -job $job
    }
}
catch
{
    $msg = "An error occured trying to create an image. VhdDetails: $VhdDetails.`nError: $_"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $vhdInfo.JobId  -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
    throw 
}