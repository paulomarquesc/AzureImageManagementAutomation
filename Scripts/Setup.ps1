<#
.SYNOPSIS
    Setup.ps1 - Sample PowerShell script that deploys the image management solution.
.DESCRIPTION
    Setup.ps1 - Sample PowerShell script that deploys the image management solution.
    Image Management Solution helps customers to upload a VHD with a custom image to one subcription and storage account.
    After that gets done, a series of runbooks works to get this image and distribute amongst several other susbcriptions and 
    storage accounts and creates a managed Image so everyone with access to that resource/group would be able to deploy
    a VM from that image. This reduces the burden uploading VHDs on environments and having to distribute manually
    between different Subcriptions.
    This script needs to be executed in an elevated PowerShell command line window.
.PARAMETER configFile
    Configuration file needed for the setup process, basically a json file. Check the solution attached example.
.EXAMPLE
    # Installing the solution with a custom SetupInfo.json file
    .\Setup.ps1 -configFile c:\temp\myNewSetupInfo.json
.EXAMPLE
    # Installing using the default filename in the same folder as the setup script
    .\Setup.ps1
.NOTES
#>

#Requires -Modules AzureAD, AzureRmImageManagement

param
(
    [Parameter(Mandatory=$false)]
    [string]$configFile = (Join-Path $PSScriptRoot "SetupInfo.json")
)

#-----------------------------------------------
# Main
#-----------------------------------------------
$ErrorActionPreference = "Stop"

if (!(test-path $configFile))
{
    throw "Configuration file $configFile could not be found."
}

#-----------------------------------------------
# Reading configuration file contents
#-----------------------------------------------

$config = get-content $configFile -Raw | convertfrom-json

#-----------------------------------------------
# Tier 0 Storage account deployment
#-----------------------------------------------

if ($config.storage.tier0StorageAccount.storageAccountName.ToString().startswith("^"))
{
    throw "Tier 0 storage account name cannot be obtained by evaluation, it needs to be the full literal name"
}
$tier0SaName = $config.storage.tier0StorageAccount.storageAccountName

$tier0StorageAccountRG = Get-ConfigValue $config.storage.tier0StorageAccount.resourceGroup $config
$tier0StorageAccountLocation = Get-ConfigValue $config.storage.tier0StorageAccount.location $config
$tier0subscriptionId = Get-ConfigValue $config.storage.tier0StorageAccount.subscriptionId $config

Write-Verbose "Selecting main (tier0) subscription $tier0subscriptionId"
Select-AzureRmSubscription -SubscriptionId $tier0subscriptionId

# Check if resource group exists, create if not
Write-Verbose "Checking if resource group exists, create it if not." -Verbose
$rg = Get-AzureRmResourceGroup -Name $tier0StorageAccountRG -ErrorAction SilentlyContinue
if ($rg -eq $null)
{
    Write-Verbose "Creating resource group $tier0StorageAccountRG at location $tier0StorageAccountLocation" -Verbose
    New-AzureRmResourceGroup -Name $tier0StorageAccountRG -Location $tier0StorageAccountLocation
}

Write-Verbose "Creating Tier 0 Storage account $tier0SaName if it doesn't exist." -Verbose
$saInfo = Find-AzureRmResource -ResourceNameEquals $tier0SaName -ResourceType Microsoft.Storage/storageAccounts -ResourceGroupNameEquals $tier0StorageAccountRG
if ($saInfo -eq $null)
{
    if ((Get-AzureRmStorageAccountNameAvailability -Name $tier0SaName).NameAvailable)
    {
        Write-Verbose "Tier 0 Storage Account $tier0SaName not found, creating it." -Verbose
        # Create the storage account
        New-AzureRmStorageAccount -ResourceGroupName $tier0StorageAccountRG -Name $tier0SaName -SkuName Standard_LRS -Location $tier0StorageAccountLocation -Kind Storage 
    }
    else
    {
        throw "Storage account name $tier0SaName already exists, please check name conventions in order to produce an available storage account name." 
    }
}

# Adding information to the configuration table

Write-Verbose "Adding Tier 0 Information in the configuration table $(Get-ConfigValue $config.storage.tier0StorageAccount.configurationTableName $config)"

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises)
$configurationTable = Get-AzureStorageTableTable -resourceGroup $tier0StorageAccountRG -storageAccountName $tier0SaName -tableName (Get-ConfigValue $config.storage.tier0StorageAccount.configurationTableName $config)

$tier0StorageItem = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable

if ($tier0StorageItem -eq $null)
{
    # Create the t0 storage account
    [hashtable]$tier0StorageProperties = @{ "resourceGroupName"=$tier0StorageAccountRG;
                                            "storageAccountName"=$tier0SaName;
                                            "subscriptionId"=$tier0subscriptionId;
                                            "tier"=0;
                                            "container"=Get-ConfigValue $config.storage.tier0StorageAccount.container $config;
                                            "location"=Get-ConfigValue $tier0StorageAccountLocation $config;
                                            "tier1Copies"=Get-ConfigValue $config.storage.tier0StorageAccount.tier1Copies $config}

    Add-AzureStorageTableRow -table $configurationTable -partitionKey "storage" -rowKey ([guid]::NewGuid().guid) -property $tier0StorageProperties 
}

#--------------------------------
# Adding log configuration
#--------------------------------
Write-Verbose "Adding log configuration Information in the configuration table $(Get-ConfigValue $config.storage.tier0StorageAccount.configurationTableName $config)"

$logConfigurationInformation = Get-AzureStorageTableRowByCustomFilter -customFilter "PartitionKey eq 'logConfiguration'" -table $configurationTable

if ($logConfigurationInformation -eq $null)
{
    # Create the t0 storage account
    [hashtable]$logInfoProps = @{ "jobLogTableName"=Get-ConfigValue $config.general.jobLogTableName $config;
                                    "jobTableName"=Get-ConfigValue $config.general.jobTableName $config;
                                    "resourceGroupName"=Get-ConfigValue $config.storage.tier0StorageAccount.resourceGroup $config;
                                    "storageAccountName"=Get-ConfigValue $config.storage.tier0StorageAccount.storageAccountName $config}

    Add-AzureStorageTableRow -table $configurationTable -partitionKey "logConfiguration" -rowKey ([guid]::NewGuid().guid) -property $logInfoProps 
}


# Downloading required modules from PowerShell Gallery and uploading to configuration storage account
Write-Verbose "Downloading required modules from PowerShell Gallery and uploading to configuration storage account" -Verbose

$tier0StorageAccountContext = (Get-AzureRmStorageAccount -ResourceGroupName $tier0StorageAccountRG -Name $tier0SaName).Context

# Creating modules container if does not exist
$container = Get-AzureStorageContainer -Context $tier0StorageAccountContext -Name (Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config) -ErrorAction SilentlyContinue
if ($container -eq $null)
{
    New-AzureStorageContainer -Name (Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config) -Context $tier0StorageAccountContext -Permission Off
}

# Generate the SAS token
$sasToken = New-AzureStorageContainerSASToken -Container (Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config) -Context $tier0StorageAccountContext -Permission r -ExpiryTime (Get-Date).AddDays(30))

foreach ($module in $config.requiredModulesToInstall)
{
    $module = (Get-ConfigValue $module $config)
    Save-Module -Name $module -Path $env:TEMP

    #compressing file
    Add-Type -Assembly System.IO.Compression.FileSystem
    $ArchiveFile = Join-Path $env:TEMP "$module.zip"
    Remove-Item -Path $ArchiveFile -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $env:TEMP $module), $ArchiveFile)

    #uploading to configuration storage account 
    Write-Verbose "Uploading module to tier 0 storage account $tier0SaName" -Verbose
    Set-AzureStorageBlobContent -File $ArchiveFile -Blob "$module.zip" -Container (Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config) -Context $tier0StorageAccountContext -Force
}

#-----------------------------------------------------
# Tier 2 storage setup - On each Tier 1 subscription
#-----------------------------------------------------

Write-Verbose "Tier 2 storage setup - On each Tier 1 subscription" -Verbose

Select-AzureRmSubscription -SubscriptionId (Get-ConfigValue $config.storage.tier0StorageAccount.subscriptionId $config)

Write-Verbose "Creating tier 2 storage accounts" -Verbose

foreach ($t2Storage in $config.storage.tier2StorageAccounts)
{
    # Check configuration table for an existing Id
    $customQuery = [string]::Format("(PartitionKey eq 'storage') and (tier eq 2) and (id eq '{0}')",$t2Storage.id)
    $tier2StorageItem = Get-AzureStorageTableRowByCustomFilter -customFilter $customQuery -table $configurationTable

    if ($tier2StorageItem -eq $null)
    {
        # Getting some values
        $saName = Get-ConfigValue $t2Storage.storageAccountName $config
        Write-Verbose "Tier 2 Storage Account name $saname" -Verbose

        $tier2subscriptionId = Get-ConfigValue $t2Storage.subscriptionId $config
        Write-Verbose "Subscription $tier2subscriptionId" -Verbose

        Select-AzureRmSubscription -SubscriptionId $tier2subscriptionId

        Write-Verbose "Working on tier 2 storage account $saName at subscription $tier2subscriptionId" -Verbose
        
        # create resource group for storage account if not found
        # Waiting 10 seconds
        Start-Sleep -Seconds 10

        $rg = Get-AzureRmResourceGroup -Name (Get-ConfigValue $t2Storage.resourceGroup $config) -ErrorAction SilentlyContinue
        if ($rg -eq $null)
        {
            Write-Verbose "Creating rerource group $(Get-ConfigValue $t2Storage.resourceGroup $config)" -Verbose
            New-AzureRmResourceGroup -Name (Get-ConfigValue $t2Storage.resourceGroup $config) -Location (Get-ConfigValue $t2Storage.location $config)
        }

        # Create the storage account
        try
        {
            New-AzureRmStorageAccount -ResourceGroupName (Get-ConfigValue $t2Storage.resourceGroup $config) -Name $saName -SkuName Standard_LRS -Location (Get-ConfigValue $t2Storage.location $config) -Kind Storage 
            
            [hashtable]$tier2StorageProperties = @{ "id"=(Get-ConfigValue $t2Storage.id $config).ToString();
                                                    "resourceGroupName"=Get-ConfigValue $t2Storage.resourceGroup $config;
                                                    "storageAccountName"=$saName;
                                                    "subscriptionId"=Get-ConfigValue $t2Storage.subscriptionId $config;
                                                    "tier"=2;
                                                    "container"=Get-ConfigValue $t2Storage.container $config;
                                                    "location"=Get-ConfigValue $t2Storage.location $config}

            Add-AzureStorageTableRow -table $configurationTable -partitionKey "storage" -rowKey ([guid]::NewGuid().guid) -property $tier2StorageProperties 
        }
        catch
        {
            throw "Error creating tier 2 storage account: $($t2Storage.id) in resource group $($t2Storage.resourceGroupName) at subscription $($t2Storage.subscriptionId). `nError Details: $_"
        }
    }
    else
    {
        Write-Verbose "Tier 2 Storage id $($t2Storage.id) in resource group $($t2Storage.resourceGroupName) at subscription $($t2Storage.subscriptionId) already exists"    
    }
}

#-------------------------------------------------------
# Setting up Main Automation Account and RunAs Accounts
#-------------------------------------------------------

Write-Verbose "Setting up Main Automation Account and RunAs Account" -Verbose
$tier0subscriptionId = Get-ConfigValue $config.storage.tier0StorageAccount.subscriptionId $config
Select-AzureRmSubscription -SubscriptionId $tier0subscriptionId

# Adding main automation account
$result = Find-AzureRmResource -ResourceGroupName  (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ResourceNameEquals (Get-ConfigValue $config.automationAccount.automationAccountNamePrefix $config)

if ($result -eq $null)
{
    # create resource group for main automation account if does not exist
    $rg = Get-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ErrorAction SilentlyContinue
    if ($rg -eq $null)
    {
        Write-Verbose "Creating rerource group $(Get-ConfigValue $config.automationAccount.resourceGroup $config)" -Verbose
        New-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -Location (Get-ConfigValue $config.storage.tier0StorageAccount.location $config)
    }

    New-AzureRmImgMgmtAutomationAccount -automationAccountName (Get-ConfigValue $config.automationAccount.automationAccountNamePrefix $config) `
        -resourceGroupName (Get-ConfigValue $config.automationAccount.resourceGroup $config) `
        -location (Get-ConfigValue $config.automationAccount.location $config) `
        -applicationDisplayName (Get-ConfigValue $config.automationAccount.applicationDisplayNamePrefix $config) `
        -subscriptionId (Get-ConfigValue $config.automationAccount.subscriptionId $config) `
        -modulesContainerUrl ([string]::Format("{0}{1}",$tier0StorageAccountContext.BlobEndPoint,(Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config))) `
        -sasToken $sasToken `
        -runbooks $config.automationAccount.runbooks.mainAutomationAccount `
        -config $config `
        -basicTier

    # Adding the main automation account info in the configuration table
    [hashtable]$mainAutomationAccountProps = @{ "automationAccountName"=Get-ConfigValue $config.automationAccount.automationAccountNamePrefix $config;
                                        "resourceGroupName"=Get-ConfigValue $config.automationAccount.resourceGroup $config;
                                        "subscriptionId"=Get-ConfigValue $config.automationAccount.subscriptionId $config;
                                        "applicationDisplayName"=Get-ConfigValue $config.automationAccount.applicationDisplayNamePrefix $config;
                                        "type"="main";
                                        "location"=Get-ConfigValue $config.automationAccount.location $config;
                                        "connectionName"=Get-ConfigValue $config.automationAccount.connectionName $config}

    Add-AzureStorageTableRow -table $configurationTable -partitionKey "automationAccount" -rowKey ([guid]::NewGuid().guid) -property $mainAutomationAccountProps 
}


# Adding Copy Process automation account(s)
Write-Verbose "Setting up Copy Process Automation Account(s) and RunAs Account(s)" -Verbose

for ($i=1;$i -le (Get-ConfigValue $config.automationAccount.workerAutomationAccountsCount $config);$i++)
{
    $copyAutomationAccountName = [string]::Format("{0}-Copy{1}",(Get-ConfigValue $config.automationAccount.automationAccountNamePrefix $config),$i.ToString("000"))
    $copyApplicationDisplayName = [string]::Format("{0}-Copy{1}",(Get-ConfigValue $config.automationAccount.applicationDisplayNamePrefix $config),$i.ToString("000"))

    $result = Find-AzureRmResource -ResourceGroupName  (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ResourceNameEquals $copyAutomationAccountName

    if ($result -eq $null)
    {
        # create resource group for copy automation account if does not exist
        $rg = Get-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ErrorAction SilentlyContinue
        if ($rg -eq $null)
        {
            Write-Verbose "Creating rerource group $(Get-ConfigValue $config.automationAccount.resourceGroup $config)" -Verbose
            New-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -Location (Get-ConfigValue $config.storage.tier0StorageAccount.location $config)
        }

        New-AzureRmImgMgmtAutomationAccount -automationAccountName $copyAutomationAccountName `
            -resourceGroupName (Get-ConfigValue $config.automationAccount.resourceGroup $config) `
            -location (Get-ConfigValue $config.automationAccount.location $config) `
            -applicationDisplayName $copyApplicationDisplayName `
            -subscriptionId (Get-ConfigValue $config.automationAccount.subscriptionId $config) `
            -modulesContainerUrl ([string]::Format("{0}{1}",$tier0StorageAccountContext.BlobEndPoint,(Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config))) `
            -sasToken $sasToken `
            -runbooks $config.automationAccount.runbooks.copyProcessAutomationAccount `
            -config $config `
            -basicTier

        # Adding the main automation account info in the configuration table
        [hashtable]$copyAutomationAccountProps = @{ "automationAccountName"=$copyAutomationAccountName;
                                            "resourceGroupName"=Get-ConfigValue $config.automationAccount.resourceGroup $config;
                                            "subscriptionId"=Get-ConfigValue $config.automationAccount.subscriptionId $config;
                                            "applicationDisplayName"=$copyApplicationDisplayName;
                                            "type"="copyDedicated";
                                            "availableJobsCount"=Get-ConfigValue $config.automationAccount.availableDedicatedCopyJobs $config;
                                            "maxJobsCount"=Get-ConfigValue $config.automationAccount.maxDedicatedCopyJobs $config;
                                            "location"=Get-ConfigValue $config.automationAccount.location $config;
                                            "connectionName"=Get-ConfigValue $config.automationAccount.connectionName $config}

        Add-AzureStorageTableRow -table $configurationTable -partitionKey "automationAccount" -rowKey ([guid]::NewGuid().guid) -property $copyAutomationAccountProps 
    }
}

# Adding Image Creation Process automation account(s)
Write-Verbose "Setting up Image Creation Process Automation Account(s) and RunAs Account(s)" -Verbose

for ($i=1;$i -le (Get-ConfigValue $config.automationAccount.workerAutomationAccountsCount $config);$i++)
{
    $imgAutomationAccountName = [string]::Format("{0}-Img{1}",(Get-ConfigValue $config.automationAccount.automationAccountNamePrefix $config),$i.ToString("000"))
    $imgApplicationDisplayName = [string]::Format("{0}-Img{1}",(Get-ConfigValue $config.automationAccount.applicationDisplayNamePrefix $config),$i.ToString("000"))

    $result = Find-AzureRmResource -ResourceGroupName  (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ResourceNameEquals $imgAutomationAccountName

    if ($result -eq $null)
    {
        # create resource group for copy automation account if does not exist
        $rg = Get-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ErrorAction SilentlyContinue
        if ($rg -eq $null)
        {
            Write-Verbose "Creating rerource group $(Get-ConfigValue $config.automationAccount.resourceGroup $config)" -Verbose
            New-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -Location (Get-ConfigValue $config.storage.tier0StorageAccount.location $config)
        }

        New-AzureRmImgMgmtAutomationAccount -automationAccountName $imgAutomationAccountName `
            -resourceGroupName (Get-ConfigValue $config.automationAccount.resourceGroup $config) `
            -location (Get-ConfigValue $config.automationAccount.location $config) `
            -applicationDisplayName $imgApplicationDisplayName `
            -subscriptionId (Get-ConfigValue $config.automationAccount.subscriptionId $config) `
            -modulesContainerUrl ([string]::Format("{0}{1}",$tier0StorageAccountContext.BlobEndPoint,(Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config))) `
            -sasToken $sasToken `
            -runbooks $config.automationAccount.runbooks.imageCreationProcessAutomationAccount `
            -config $config `
            -basicTier

        # Adding the main automation account info in the configuration table
        [hashtable]$imgAutomationAccountProps = @{ "automationAccountName"=$imgAutomationAccountName;
                                            "resourceGroupName"=Get-ConfigValue $config.automationAccount.resourceGroup $config;
                                            "subscriptionId"=Get-ConfigValue $config.automationAccount.subscriptionId $config;
                                            "applicationDisplayName"=$imgApplicationDisplayName;
                                            "type"="ImageCreationDedicated";
                                            "availableJobsCount"=Get-ConfigValue $config.automationAccount.availableDedicatedImageCreationJobs $config;
                                            "maxJobsCount"=Get-ConfigValue $config.automationAccount.maxDedicatedImageCreationJobs $config;
                                            "location"=Get-ConfigValue $config.automationAccount.location $config;
                                            "connectionName"=Get-ConfigValue $config.automationAccount.connectionName $config}

        Add-AzureStorageTableRow -table $configurationTable -partitionKey "automationAccount" -rowKey ([guid]::NewGuid().guid) -property $imgAutomationAccountProps 
    }
}

#--------------------------------
# Creating queues
#--------------------------------

Write-Verbose "Selecting tier 0 subscription $(Get-ConfigValue $config.storage.tier0StorageAccount.subscriptionId $config)" -Verbose
$tier0subscriptionId = Get-ConfigValue $config.storage.tier0StorageAccount.subscriptionId $config
Select-AzureRmSubscription -SubscriptionId $tier0subscriptionId

$result = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'queueConfig')" -table $configurationTable

if ($result -eq $null)
{
    [hashtable]$QueueProperties = @{ "storageAccountResourceGroupName"=Get-ConfigValue $config.storage.tier0StorageAccount.resourceGroup $config;
                                    "storageAccountName"=$tier0SaName;
                                    "copyProcessQueueName"=Get-ConfigValue $config.general.copyProcessQueueName $config;
                                    "imageCreationQueueName"=Get-ConfigValue $config.general.imageCreationQueueName $config;
                                    "location"=Get-ConfigValue $config.storage.tier0StorageAccount.location $config}

    Write-Verbose "Creating queue $($QueueProperties.copyProcessQueueName)" -Verbose
    Get-AzureRmStorageQueueQueue -resourceGroup $QueueProperties.storageAccountResourceGroupName `
                                    -storageAccountName  $QueueProperties.storageAccountName `
                                    -queueName $QueueProperties.copyProcessQueueName

    Write-Verbose "Creating queue $($QueueProperties.imageCreationQueueName)" -Verbose
    Get-AzureRmStorageQueueQueue -resourceGroup $QueueProperties.storageAccountResourceGroupName `
                                    -storageAccountName  $QueueProperties.storageAccountName `
                                    -queueName $QueueProperties.imageCreationQueueName

                                Write-Verbose "Adding queue information into the configuration table" -Verbose
    Add-AzureStorageTableRow -table $configurationTable -partitionKey "queueConfig" -rowKey ([guid]::NewGuid().guid) -property $QueueProperties
}

Write-Verbose "End of script execution" -Verbose

#------------------------------------------------------------------------------------------------------------------------
# Assign service principal contributor of the t2 involved subscriptions
# Note: To perform this initial assigment the user executing this setup script must be owner of all t2 subscriptions
#------------------------------------------------------------------------------------------------------------------------
Write-Verbose "Getting main automation account information from storage table..." -Verbose
$mainAutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'automationAccount') and (type eq 'main')" -table $configurationTable

# Obtaining AppID of the service principal
# Getting the authorization token
Write-Verbose "Obtaining a token for the rest api calls against Azure AD" -Verbose
$tenantName = Get-ConfigValue $config.general.tenantName $config

$currentUserid = [Microsoft.IdentityModel.Clients.ActiveDirectory.UserIdentifier]::New((Get-AzureRmContext).Account.Id,[Microsoft.IdentityModel.Clients.ActiveDirectory.UserIdentifierType]::RequiredDisplayableId)

if ($currentUserId.Id.Contains("@"))
{
    # Based on UPN
    $token = Get-AzureRmImgMgmtAuthToken -TenantName $tenantName -userId $currentUserId -promptBehavior ([Microsoft.IdentityModel.Clients.ActiveDirectory.PromptBehavior]::Never)
}
else
{
    # based on guid
    $token = Get-AzureRmImgMgmtAuthToken -TenantName $tenantName -promptBehavior ([Microsoft.IdentityModel.Clients.ActiveDirectory.PromptBehavior]::Auto)
}

# Building Rest Api header with authorization token
$authHeader = Get-AzureRmImgMgmtAuthHeader -AuthToken $token 

$uri = "https://graph.windows.net/$($tenantName)/servicePrincipals?`$filter=startswith(displayName,`'" + $mainAutomationAccount.ApplicationDisplayName + "`')&api-version=1.6"
Write-Verbose "Graph Api URI: $uri"

Write-Verbose "Invoking the request" -Verbose
$servicePrincipalList = (Invoke-RestMethod -Uri $uri -Headers $authHeader -Method Get).value

if ($servicePrincipalList -ne $null)
{
    Write-Verbose "Getting Tier 2 subscription List" -Verbose
    $tier2SubscriptionList = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 2)" -table $configurationTable
    foreach ($sub in $tier2SubscriptionList)
    {
        Write-Verbose "Working on tier 2 subscription $(Get-ConfigValue $sub.SubscriptionID $config)" -Verbose
        $subscriptionId =  Get-ConfigValue $sub.SubscriptionID $config
        Select-AzureRmSubscription -SubscriptionId $subscriptionId

        foreach ($servicePrincipal in $servicePrincipalList)
        {
            $roleAssignment = Get-AzureRmRoleAssignment -ServicePrincipalName $servicePrincipal.AppID -RoleDefinitionName Contributor -Scope "/subscriptions/$subscriptionId" -ErrorAction SilentlyContinue
            if ($roleAssignment -eq $null)
            {
                Write-Verbose "Performing contributor role assigment to service principal $($servicePrincipal.AppID)" -Verbose
                New-AzureRmRoleAssignment -ServicePrincipalName $servicePrincipal.AppID -RoleDefinitionName Contributor -Scope "/subscriptions/$subscriptionId" -ErrorAction SilentlyContinue
            }
        }
    }
}
else
{
    throw "Service principal $($mainAutomationAccount.ApplicationDisplayName) not found at Azure AD tenant $($tenantName)"
}
