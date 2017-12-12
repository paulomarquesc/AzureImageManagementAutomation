<#
    .SYNOPSIS
        Starts the job that creates the images. 
    .DESCRIPTION
        Starts the job that creates the images. 
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
$moduleName = "Start-ImageManagementImageCreation.ps1"

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

# Getting the configuration table
$configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

# Getting the Job Log table
$log =  Get-AzureRmImgMgmtLogTable -configurationTable $configurationTable

$msg = " Getting a VHD to process"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

# Getting a VHD to process
$queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

$imgQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                          -storageAccountName  $queueInfo.storageAccountName `
                                          -queueName $queueInfo.imageCreationQueueName

$vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $imgQueue

while ($vhdToProcess -ne $null)
{
    $msg = "Processing image queue message message $($vhdToProcess.AsString)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    try
    {
        $msg = "Getting available automation accounts"
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

        $automationAccount = Get-AzureRmImgMgmtAvailableAutomationAccount -table $configurationTable -AutomationAccountType "ImageCreationDedicated" 
    }
    catch
    {
        $msg = "An error ocurred: $_"
        Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Error)
        break
    }

    $msg = "Using automation account $($automationAccount.automationAccountName)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    # Parameters to be passed on to the runbook
    $params = @{"VhdDetails"=$vhdToProcess.AsString;
                "ConnectionName"=$automationAccount.connectionName;
                "ConfigStorageAccountResourceGroupName"=$ConfigStorageAccountResourceGroupName;
                "ConfigStorageAccountName"=$ConfigStorageAccountName;
                "ConfigurationTableName"=$ConfigurationTableName;
                "AutomationAccountName"=$automationAccount.automationAccountName;
                "Tier0SubscriptionId"=$tier0SubscriptionId}

    $msg = "Data being passed to New-ImageManagementImage runbook: $($params | convertto-json -Compress)"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $msg = "Starting runbook New-ImageManagementImage "
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    Start-AzureRmAutomationRunbook -Name "New-ImageManagementImage" `
                                    -Parameters $params `
                                    -AutomationAccountName $automationAccount.automationAccountName `
                                    -ResourceGroupName $automationAccount.resourceGroupName

    # Get next message in the queue
    Start-Sleep -Seconds 30

    $msg = "Get next message in the queue"
    Add-AzureRmImgMgmtLog -output -logTable $log -jobId $tempJobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)

    $vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $imgQueue
}

$msg = "Runbook execution completed"
Add-AzureRmImgMgmtLog -output -logTable $log -jobId $jobId -step ([steps]::imageCreation) -moduleName $moduleName -message $msg -Level ([logLevel]::Informational)
