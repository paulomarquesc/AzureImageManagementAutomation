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

# Get an VHD to process
$queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

$imgQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                          -storageAccountName  $queueInfo.storageAccountName `
                                          -queueName $queueInfo.imageCreationQueueName

$vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $imgQueue

while ($vhdToProcess -ne $null)
{
    write-output "processing message $($vhdToProcess.AsString)"

    try
    {
        Write-Output "Getting available automation accounts"
        $automationAccount = Get-AzureRmImgMgmtAvailableAutomationAccount -table $configurationTable -AutomationAccountType "ImageCreationDedicated" 
        Write-Output "automation account count $($automationAccount.count)"
    }
    catch
    {
        # An error occured, placing message back into the queue for later processing
        Update-AzureRmStorageQueueMessage -queue $imgQueue -message $vhdToProcess -visibilityTimeout 0
        write-output "There is no available automation account at this moment: `n$_"
        break
    }
    
    write-output "Starting image creation job at $($automationAccount.automationAccountName)"

    # Parameters to be passed on to the runbook
    $params = @{"VhdDetails"=$vhdToProcess.AsString;
                "ConnectionName"=$automationAccount.connectionName;
                "ConfigStorageAccountResourceGroupName"=$ConfigStorageAccountResourceGroupName;
                "ConfigStorageAccountName"=$ConfigStorageAccountName;
                "ConfigurationTableName"=$ConfigurationTableName;
                "AutomationAccountName"=$automationAccount.automationAccountName;
                "Tier0SubscriptionId"=$tier0SubscriptionId}

    Write-Output "Data being passed to New-ImageManagementImage runbook:"
    Write-Output -InputObject $automationAccount

    Start-AzureRmAutomationRunbook -Name "New-ImageManagementImage" `
                                            -Parameters $params `
                                            -AutomationAccountName $automationAccount.automationAccountName `
                                            -ResourceGroupName $automationAccount.resourceGroupName

    # Decrease availableJobs at the automation account
    write-output "Updating automation account availability" 
    Update-AzureRmImgMgmtAutomationAccountAvailabilityCount -table $configurationTable -AutomationAccount $automationAccount -Decrease
        
    write-output "Current available jobs for automation account $($automationAccount.availableJobsCount)"

    # TODO: Implement Log for copy statuses

    # Get next message in the queue
    Start-Sleep -Seconds 30
    $vhdToProcess = Invoke-AzureRmStorageQueueGetMessage -queue $imgQueue
}
