<#
    .SYNOPSIS
        Transfers the VHD file from the tier 1 storage to tier 2 storage. 
    .DESCRIPTION
        Transfers the VHD file from the tier 1 storage to tier 2 storage.
        At the end it will place a message into the Image Creation queue for Images to be created
    .PARAMETER ConfigStorageAccountResourceGroupName
        Resource Group name of the Azure Storage Account that contains the system configuration tables.
    .PARAMETER ConfigStorageAccountName
        Name of the Storage Account that contains the system configuration tables.
    .PARAMETER ConfigurationTableName
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER SourceStorageAccount
        Resource Group name of the Azure Storage Account that contains the system configuration tables.
    .PARAMETER SourceBlobName
        Name of the source blob
    .PARAMETER DestinationStorageAccount
        Name of the Storage Account that contains the system configuration tables.
    .PARAMETER VhdDetails
        Name of the configuration table, default to ImageManagementConfiguration, which is the preferred name.
    .PARAMETER StatusCheckInterval
        Time in minutes where that the tier 2 blob copy jobs are pulled for status, default is 60 minutes. 
    .PARAMETER ConnectionName
        RunAs ccount to be used. 
    .PARAMETER AutomationAccountName
        Name of the current automation account executing the runbook.,
    .PARAMETER Tier0SubscriptionId
        Id of the tier 0 subscription (the one that contains the configuration table). 
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
    $SourceStorageAccount,

    [Parameter(Mandatory=$true)]
    $SourceBlobName,

    [Parameter(Mandatory=$true)]
    $DestinationStorageAccount,

    [Parameter(Mandatory=$true)]
    [String] $VhdDetails,

    [Parameter(Mandatory=$false)]
    $connectionName="AzureRunAsConnection",

    [Parameter(Mandatory=$false)]
    [int] $StatusCheckInterval = 60,
    
    [Parameter(Mandatory=$true)]
    [String] $AutomationAccountName,
        
    [Parameter(Mandatory=$true)]
    [String] $Tier0SubscriptionId
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

Select-AzureRmSubscription -SubscriptionId $SourceStorageAccount.SubscriptionId

# Getting source context object
$sourceContext = (Get-AzureRmStorageAccount -ResourceGroupName $SourceStorageAccount.resourceGroupName -Name $SourceStorageAccount.storageAccountName).Context
if ($sourceContext -eq $null)
{
    throw "Context object could not be retrieved from source storage account $($SourceStorageAccount.storageAccountName) at resource group $($SourceStorageAccount.resourceGroupName) at subscription $($SourceStorageAccount.SubscriptionId)"
}

# Getting destination context
Select-AzureRmSubscription -SubscriptionId $DestinationStorageAccount.SubscriptionId
$destContext = (Get-AzureRmStorageAccount -ResourceGroupName $DestinationStorageAccount.resourceGroupName -Name $DestinationStorageAccount.storageAccountName).Context
if ($destContext -eq $null)
{
    throw throw "Context object could not be retrieved from destination storage account $($DestinationStorageAccount.storageAccountName) at resource group $($DestinationStorageAccount.resourceGroupName) at subscription $($SourceStorageAccount.SubscriptionId)"
}

# Check container and create if does not exist
write-output "Check container and create if does not exist" 
$container = Get-AzureStorageContainer -Context $destContext -Name $DestinationStorageAccount.container -ErrorAction SilentlyContinue

if ($container -eq $null)
{
    write-output "Creating container $($DestinationStorageAccount.container)" 
    New-AzureStorageContainer -Name $DestinationStorageAccount.container -Context $destContext -Permission Off
}

# Start the copy process to tier 2 storage account
$pendingCopies = New-Object System.Collections.Generic.List[System.String]

write-output "Starting tier 2 blob copy job to storage account $($DestinationStorageAccount.storageAccountName) from $($SourceStorageAccount.storageAccountName)" 

$vhdInfo = $VhdDetails | ConvertFrom-Json
$copyStartTime = $([datetime]::UtcNow)

try
{
    write-output "Calling Start-AzureRmImgMgmtVhdCopy" 

    Start-AzureRmImgMgmtVhdCopy -sourceContainer $SourceStorageAccount.container `
        -sourceContext $sourceContext `
        -destContainer $DestinationStorageAccount.container `
        -destContext $destContext `
        -sourceBlobName $SourceBlobName `
        -destBlobName $vhdInfo.vhdName
}
catch
{
    # Making the Automation Account available again and stopping further processing
    write-output "An error occured.`nError Details:`n$_"

    $customFilter = "(PartitionKey eq 'automationAccount') and (automationAccountName eq `'" + $AutomationAccountName + "`')"
    $AutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $configurationTable

    Update-AzureRmImgMgmtAutomationAccountAvailabilityCount -table $configurationTable -AutomationAccount $AutomationAccount

    throw $_
}

try
{
    # Adding time that copy started to the destination storage object
    write-output "Adding time that copy started to the destination storage object"
    $DestinationStorageAccount | Add-Member -type NoteProperty -name "CopyStartTime" -Value $copyStartTime

    $pendingCopies.Add($DestinationStorageAccount.storageAccountName)

    # Check completion status
    $passCount = 1

    while ($pendingCopies.count -gt 0)
    {
        write-output "current status check pass $passcount, pending copies: $($pendingCopies.count)" 

        if ($pendingCopies.Contains($DestinationStorageAccount.storageAccountName))
        {
            $state = Get-AzureStorageBlobCopyState -Blob $vhdInfo.vhdName -Container $DestinationStorageAccount.container -Context $destContext

            if ($state.Status -ne "pending")
            {
                $DestinationStorageAccount | Add-Member -type NoteProperty -name "CopyEndTime" -Value $($state.CompletionTime)
                $DestinationStorageAccount | Add-Member -type NoteProperty -name "CopyElapsedTimeMinutes" -Value $((New-TimeSpan ($DestinationStorageAccount.CopyStartTime) $DestinationStorageAccount.CopyEndTime.DateTime).minutes)
                $DestinationStorageAccount | Add-Member -type NoteProperty -name "Status" -Value $($state.status)
                $DestinationStorageAccount | Add-Member -type NoteProperty -name "StatusDescription" -Value $($state.StatusDescription)
                $DestinationStorageAccount | Add-Member -type NoteProperty -name "TotalBytes" -Value $($state.TotalBytes)
                $pendingCopies.Remove($DestinationStorageAccount.storageAccountName)
            }
        }

        Start-Sleep $StatusCheckInterval
        $passCount++

        # TODO: Implement timeout limit to avoid endless loop, throw exception for timeout to stop further processing also log the error

    }

    # Add info in the queue to create the images
    Select-AzureRmSubscription -SubscriptionId $tier0SubscriptionId

    $configurationTable = Get-AzureStorageTableTable -resourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

    $queueInfo = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable 

    $imageCreationQueue = Get-AzureRmStorageQueueQueue -resourceGroup $queueInfo.storageAccountResourceGroupName `
                                            -storageAccountName  $queueInfo.storageAccountName `
                                            -queueName $queueInfo.imageCreationQueueName

    $vhdMessage = @{ "location"=$DestinationStorageAccount.location;
                    "imageName"=$vhdInfo.imageName;
                    "imageResourceGroup"=$vhdInfo.imageResourceGroupName;
                    "osType"=$vhdInfo.osType;
                    "subscriptionId"=$DestinationStorageAccount.subscriptionId;
                    "vhdUri"=[string]::Format("{0}{1}/{2}",$destContext.BlobEndPoint,$DestinationStorageAccount.container,$vhdInfo.vhdName)}
                    
    Add-AzureRmStorageQueueMessage -queue $imageCreationQueue -message $vhdMessage
}
catch
{
    throw $_
}

# Increases automation account availability
$customFilter = "(PartitionKey eq 'automationAccount') and (automationAccountName eq `'" + $AutomationAccountName + "`')"
$AutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $configurationTable

Update-AzureRmImgMgmtAutomationAccountAvailabilityCount -table $configurationTable -AutomationAccount $AutomationAccount

write-output "Tier 2 VHD copy succeeded" 


