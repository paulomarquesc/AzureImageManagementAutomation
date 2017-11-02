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

$vhdInfo = $VhdDetails | ConvertFrom-Json

Write-Output -InputObject $vhdInfo

try
{
    Select-AzureRmSubscription -SubscriptionId $vhdInfo.subscriptionId
    
    # Check if resource group exists, create if not
    $rg = Get-AzureRmResourceGroup -Name $vhdInfo.imageResourceGroup -ErrorAction SilentlyContinue
    if ($rg -eq $null)
    {
        Write-Output "Creating resource group $($vhdInfo.imageResourceGroup) at location $($vhdInfo.location)"
        New-AzureRmResourceGroup -Name $vhdInfo.imageResourceGroup -Location $vhdInfo.location
    }

    # Appending location to the image name
    $imageName = [string]::Format("{0}.{1}",$vhdInfo.imageName,$vhdInfo.location)

    # Check if image exists, create if not
    $image = Find-AzureRmResource -ResourceGroupName $vhdInfo.imageResourceGroup -Name $vhdInfo.imageName -ResourceType Microsoft.Compute/images
    if ($image -ne $null)
    {
        Write-Output "Image $imageName already exists, deleting image."
        Remove-AzureRmImage -ResourceGroupName $vhdInfo.imageResourceGroup -ImageName $imageName -Force
    }

    Start-Sleep -Seconds 15 # Give some time for the platform replicate the change

    Write-Output "Creating new image $imageName"
    $imageConfig = New-AzureRmImageConfig -Location $vhdInfo.location
    $imageConfig = Set-AzureRmImageOsDisk -Image $imageConfig -OsType $vhdInfo.osType -OsState Generalized -BlobUri $vhdInfo.vhdUri

    New-AzureRmImage -ImageName $imageName -ResourceGroupName $vhdInfo.imageResourceGroup -Image $imageConfig
}
catch
{
    throw "An error occured trying to create an image. VhdDetails: $VhdDetails.`nError: $_"
}

# Selecting tier 0 subscription
Select-AzureRmSubscription -SubscriptionId $tier0SubscriptionId

# Getting the configuration table
$configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

# Increases automation account availability for image creationg
$customFilter = "(PartitionKey eq 'automationAccount') and (automationAccountName eq `'" + $AutomationAccountName + "`')"
$AutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $configurationTable

Update-AzureRmImgMgmtAutomationAccountAvailabilityCount -table $configurationTable -AutomationAccount $AutomationAccount
