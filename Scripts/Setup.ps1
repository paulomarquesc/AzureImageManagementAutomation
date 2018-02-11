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
.PARAMETER ConfigFile
    Configuration file needed for the setup process, basically a json file. Check the solution attached example.
.PARAMETER AzureCredential
    This is PSCredential object for the user in Azure AD that has onwer at subscription level or administrator or co-administrator rights in the
    tier 0 subcription (the one that will hold the tier 0 storage account with configuration table and automation accounts).
    An example of how to get this credential is: $cred = Get-Credential
    If this parameter is not provided, you will be prompted to provide the information during the script execution. 
.EXAMPLE
    # Installing the solution with a custom SetupInfo.json file
    .\Setup.ps1 -configFile c:\temp\myNewSetupInfo.json
.EXAMPLE
    # Installing using a custom setup info file with credential object
    $cred = Get-Credential
    .\Setup.ps1 -configFile c:\temp\myNewSetupInfo.json -AzureCredential $cred
.EXAMPLE
    # Installing using the default filename in the same folder as the setup script
    .\Setup.ps1
.NOTES
    1) The user executing this setup script must be owner of all involved subscriptions.
#>

#Requires -Modules AzureAD, AzureRmImageManagement, AzureRm.Compute

param
(
    [Parameter(Mandatory=$false)]
    [string]$configFile = (Join-Path $PSScriptRoot "SetupInfo.json"),
    [Parameter(Mandatory=$false)]
    [PSCredential]$azureCredential
)

#region Sccript Blocks used for PowerShell Jobs

# ScriptBlock that performs storage account creation
[ScriptBlock]$storageAccountCreationScriptBlock = {
    param
    (
        [PSCredential]$cred,
        [string]$StorageAccountName,
        [string]$StorageAccountResourceGroup,
        [string]$Location,
        [string]$imagesResourceGroup,
        [string]$SubscriptionId,
        [bool]$Verbose
    )

    Add-AzureRmAccount -Credential $cred
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId

    New-AzureRmStorageAccount -ResourceGroupName $storageAccountResourceGroup -Name $storageAccountName -SkuName Standard_LRS -Location $location -Kind Storage
}

# ScriptBlock that invokes the Automation Account creation
[ScriptBlock]$automationAccountsScriptBlock = {
    param
    (
        [PSCredential]$cred,
        $automationAccountName,
        $resourceGroupName,
        $location,
        $applicationDisplayName,
        $subscriptionId,
        $modulesContainerUrl,
        $sasToken,
        $runbooks,
        $config,
        $basicTier,
        $localRunbooksPath
    )

    Add-AzureRmAccount -Credential $cred
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId

    New-AzureRmImgMgmtAutomationAccount -automationAccountName $automationAccountName `
        -resourceGroupName $resourceGroupName `
        -location $location `
        -applicationDisplayName $applicationDisplayName `
        -subscriptionId $subscriptionId `
        -modulesContainerUrl $modulesContainerUrl `
        -sasToken $sasToken `
        -runbooks $runbooks `
        -config $config `
        -basicTier:$basicTier `
        -localRunbooksPath $localRunbooksPath
}

# ScriptBlock that performs RBAC assigments 
[scriptBlock]$rbacAssignmentScriptBlock = {
    param
    (
        [PSCredential]$cred,
        [string]$subscriptionID,
        [string]$resourceGroup,
        [string]$imagesResourceGroup,
        $servicePrincipalList
    )

    Add-AzureRmAccount -Credential $cred
    Select-AzureRmSubscription -SubscriptionId $subscriptionID

    $scope =  "/subscriptions/$subscriptionID/resourceGroups/$resourceGroup"
    $imagesScope =  "/subscriptions/$subscriptionID/resourceGroups/$imagesResourceGroup"
    
    # Register Microsoft.Compute if not already registered
    $computeResourceProvider = Get-AzureRmResourceProvider -ProviderNamespace Microsoft.Compute | Where-Object {$_.RegistrationState -eq "Registered"} `
                                                                                                | Select-Object -ExpandProperty ResourceTypes `
                                                                                                | Where-Object {$_.ResourceTypeName -eq "disks"}

    if ($computeResourceProvider -eq $null)
    {
        Register-AzureRmResourceProvider -ProviderNamespace "Microsoft.Compute"
    }

    # Adding role assignment for both resource groups
    foreach ($servicePrincipal in $servicePrincipalList)
    {
        $roleAssignmentSolutionRg = Get-AzureRmRoleAssignment -ServicePrincipalName $servicePrincipal.AppID -RoleDefinitionName Contributor -Scope $scope -ErrorAction SilentlyContinue
        if ($roleAssignmentSolutionRg -eq $null)
        {
            New-AzureRmRoleAssignment -ServicePrincipalName $servicePrincipal.AppID -RoleDefinitionName "Contributor" -Scope $scope
        }

        $roleAssignmentImagesRg = Get-AzureRmRoleAssignment -ServicePrincipalName $servicePrincipal.AppID -RoleDefinitionName Contributor -Scope $imagesScope -ErrorAction SilentlyContinue
        if ($roleAssignmentImagesRg -eq $null)
        {
            New-AzureRmRoleAssignment -ServicePrincipalName $servicePrincipal.AppID -RoleDefinitionName "Contributor" -Scope $imagesScope
        }
    }
}

#endregion

#region Gathering Information
$ErrorActionPreference = "Stop"

if ($azureCredential -eq $null)
{
    $azureCredential = Get-Credential -Message "Plese, enter the username and password of an Azure AD Account that has been assigned Owner role at subscription level of all subsrciptions involved in this setup."
}

Add-AzureRmAccount -Credential $azureCredential

if (!(test-path $configFile))
{
    throw "Configuration file $configFile could not be found."
}

$scriptPath = [system.io.path]::GetDirectoryName($PSCommandPath)

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
#endregion

#region Check if resource group and tier 0 storage account exists, create if don't 
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
#endregion

#region Adding information to the configuration table

Write-Verbose "Adding Tier 0 Information in the configuration table $(Get-ConfigValue $config.storage.tier0StorageAccount.configurationTableName $config)"

# Obtaining the tier 0 storage account (the one that receives the vhd from on-premises)
$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $tier0StorageAccountRG -StorageAccountName $tier0SaName -tableName (Get-ConfigValue $config.storage.tier0StorageAccount.configurationTableName $config)

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
                                            "tier1Copies"=Get-ConfigValue $config.storage.tier0StorageAccount.tier1Copies $config;
                                            "imagesResourceGroup"=Get-ConfigValue $config.storage.tier0StorageAccount.imagesResourceGroup $config}

    Add-AzureStorageTableRow -table $configurationTable -partitionKey "storage" -rowKey ([guid]::NewGuid().guid) -property $tier0StorageProperties 
}

#endregion

#region Adding log configuration
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
#endregion

#region Downloading required modules from PowerShell Gallery and uploading to configuration storage account
Write-Verbose "Downloading required modules from PowerShell Gallery and uploading to configuration storage account" -Verbose

$tier0StorageAccountContext = (Get-AzureRmStorageAccount -ResourceGroupName $tier0StorageAccountRG -Name $tier0SaName).Context

# Creating modules container if does not exist
$container = Get-AzureStorageContainer -Context $tier0StorageAccountContext -Name (Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config) -ErrorAction SilentlyContinue
if ($container -eq $null)
{
    New-AzureStorageContainer -Name (Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config) -Context $tier0StorageAccountContext -Permission Off
}

# Generate the SAS token
$sasToken = New-AzureStorageContainerSASToken -Container (Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config) -Context $tier0StorageAccountContext -Permission r -ExpiryTime (Get-Date).AddDays(30)

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
#endregion

#region Tier 2 storage setup - On each Tier 1 subscription

$storageAccountPSJobs = @()
$storageAccountsCheckList = @()

Write-Verbose "Tier 2 storage setup - On each Tier 1 subscription" -Verbose

Select-AzureRmSubscription -SubscriptionId (Get-ConfigValue $config.storage.tier0StorageAccount.subscriptionId $config)

foreach ($t2Storage in $config.storage.tier2StorageAccounts)
{
    # Check configuration table for an existing storage account Id
    $storageId = (Get-ConfigValue $t2Storage.id $config).ToString()
    $customQuery = [string]::Format("(PartitionKey eq 'storage') and (tier eq 2) and (id eq '{0}')",$storageId)
    $tier2StorageItem = Get-AzureStorageTableRowByCustomFilter -customFilter $customQuery -table $configurationTable

    if ($tier2StorageItem -eq $null)
    {
        $subscriptionId = Get-ConfigValue $t2Storage.subscriptionId $config
        $saName = Get-ConfigValue $t2Storage.storageAccountName $config
        $resourceGroup = Get-ConfigValue $t2Storage.resourceGroup $config
        $location = Get-ConfigValue $t2Storage.location $config
        $imagesResourceGroup = Get-ConfigValue $t2Storage.imagesResourceGroup $config

        Select-AzureRmSubscription -SubscriptionId $SubscriptionId

        # Creating Tier 2 storage account resource group if it doesn't exist
        $rg = Get-AzureRmResourceGroup -Name $resourceGroup -ErrorAction SilentlyContinue
        if ($rg -eq $null)
        {
            Write-Verbose "Creating solution rerource group $resourceGroup" -Verbose
            New-AzureRmResourceGroup -Name $resourceGroup -Location $location -Force
            Start-Sleep -Seconds 10
        }
    
        # Creating Image resource group if it doesn't exist
        $rg1 = Get-AzureRmResourceGroup -Name $imagesResourceGroup -ErrorAction SilentlyContinue
        if ($rg1 -eq $null)
        {
            Write-Verbose "Creating images resource group $imagesResourceGroup" -Verbose
            New-AzureRmResourceGroup -Name $imagesResourceGroup -Location $location -Force
        }

        Write-Verbose "Submitting PS Job to create tier 2 storage account account $saName" -Verbose

        $storageAccountPSJobs += Start-Job -ScriptBlock $storageAccountCreationScriptBlock -ArgumentList $azureCredential,  `
                                                                                                         $saName, `
                                                                                                         $resourceGroup, `
                                                                                                         $location, `
                                                                                                         $imagesResourceGroup, `
                                                                                                         $subscriptionId, `
                                                                                                         $true

        $storageAccountsCheckList += New-Object -TypeName PSObject -Property  @{ "id"=$storageId;
                                                                                 "resourceGroupName"=$resourceGroup;
                                                                                 "storageAccountName"=$saName;
                                                                                 "subscriptionId"=$subscriptionId;
                                                                                 "tier"=2;
                                                                                 "container"=(Get-ConfigValue $t2Storage.container $config);
                                                                                 "location"=$location;
                                                                                 "imagesResourceGroup"=$imagesResourceGroup;
                                                                                 "enabled"=(Get-ConfigValue $t2Storage.enabled $config) }
    }
}

# Checking all storage account creation jobs for completion
$saErrorList = Wait-AzureRmImgMgmtConfigPsJob -jobList $storageAccountPSJobs -timeOutInHours 1 -waitTimeBetweenChecksInSeconds 60

# Checking for errors and stop setup if any
if ($saErrorList.Count -gt 0)
{
    throw "An error ocurred while creating the storage accounts. Error messages:`n$saErrorList"
}

# Removing all jobs
Get-Job | Remove-Job

# Checking each storage account and creating the configuration table entries
Write-Verbose "Checking each storage account and creating the configuration table entries" -Verbose

foreach ($storageAccount in $storageAccountsCheckList)
{
    Select-AzureRmSubscription -SubscriptionId $storageAccount.subscriptionId

    $result = Find-AzureRmResource -ResourceGroupName  $storageAccount.resourceGroupName -ResourceNameEquals $storageAccount.storageAccountName
    
    if ($result -ne $null)
    {
        $customFilter = "(PartitionKey eq 'storage') and (storageAccountName eq '$($storageAccount.storageAccountName)')"
        $configQueryResult = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $configurationTable
    
        if ($configQueryResult -eq $null)
        {
            # Adding the storage account info in the configuration table
            [hashtable]$tier2StorageProperties = @{ "id"=$storageAccount.Id;
                                                    "resourceGroupName"=$storageAccount.resourceGroupName;
                                                    "storageAccountName"=$storageAccount.storageAccountName;
                                                    "subscriptionId"=$storageAccount.subscriptionId;
                                                    "tier"=$storageAccount.tier;
                                                    "container"=$storageAccount.container;
                                                    "location"=$storageAccount.location;
                                                    "imagesResourceGroup"=$storageAccount.imagesResourceGroup;
                                                    "enabled"=$storageAccount.enabled}

            Add-AzureStorageTableRow -table $configurationTable -partitionKey "storage" -rowKey ([guid]::NewGuid().guid) -property $tier2StorageProperties 
        }
    }
    else
    {
        $saErrorList += "Storage account $($storageAccount.storageAccountName) in resource group $($storageAccount.resourceGroupName) at subscription $($storageAccount.subscriptionId) could not be found."
    }
}

if ($saErrorList.Count -gt 0)
{
    throw "An error ocurred during the process of creating the storage accounts while adding its information to the configuration table. Error messages:`n$saErrorList"
}


#endregion

#region Setting up Automation and RunAs Accounts
$automationAccountPSJobs = @()
$automationAccountsCheckList = @()

Write-Verbose "Setting up Automation and RunAs Accounts" -Verbose
Select-AzureRmSubscription -SubscriptionId $tier0subscriptionId

# Adding Main automation account
$mainAutomationAccountName = Get-ConfigValue $config.automationAccount.automationAccountNamePrefix $config
$result = Find-AzureRmResource -ResourceGroupName  (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ResourceNameEquals $mainAutomationAccountName

if ($result -eq $null)
{
    # create resource group for main automation account if does not exist
    $rg = Get-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ErrorAction SilentlyContinue
    if ($rg -eq $null)
    {
        Write-Verbose "Creating rerource group $(Get-ConfigValue $config.automationAccount.resourceGroup $config)" -Verbose
        New-AzureRmResourceGroup -Name (Get-ConfigValue $config.automationAccount.resourceGroup $config) -Location (Get-ConfigValue $config.storage.tier0StorageAccount.location $config)
    }

    Write-Verbose "Submitting PS Job to create main automation account $mainAutomationAccountName" -Verbose
    $automationAccountPSJobs += Start-Job -ScriptBlock $automationAccountsScriptBlock -ArgumentList $azureCredential,  `
                                                                         $mainAutomationAccountName, `
                                                                         (Get-ConfigValue $config.automationAccount.resourceGroup $config), `
                                                                         (Get-ConfigValue $config.automationAccount.location $config), `
                                                                         (Get-ConfigValue $config.automationAccount.applicationDisplayNamePrefix $config), `
                                                                         (Get-ConfigValue $config.automationAccount.subscriptionId $config), `
                                                                         ([string]::Format("{0}{1}",$tier0StorageAccountContext.BlobEndPoint,(Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config))), `
                                                                         $sasToken, `
                                                                         $config.automationAccount.runbooks.mainAutomationAccount, `
                                                                         $config, `
                                                                         $true, `
                                                                         $scriptPath
                                                    
    $automationAccountsCheckList += New-Object -TypeName PSObject -Property @{"name"=$mainAutomationAccountName;"type"="main"}
}

# Copy Process Automation Accounts
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

        Write-Verbose "Submitting PS Job to create copy process automation account $copyAutomationAccountName" -Verbose
        $automationAccountPSJobs += Start-Job -ScriptBlock $automationAccountsScriptBlock -ArgumentList $azureCredential,  `
                                                                            $copyAutomationAccountName, `
                                                                            (Get-ConfigValue $config.automationAccount.resourceGroup $config), `
                                                                            (Get-ConfigValue $config.automationAccount.location $config), `
                                                                            $copyApplicationDisplayName, `
                                                                            (Get-ConfigValue $config.automationAccount.subscriptionId $config), `
                                                                            ([string]::Format("{0}{1}",$tier0StorageAccountContext.BlobEndPoint,(Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config))), `
                                                                            $sasToken, `
                                                                            $config.automationAccount.runbooks.copyProcessAutomationAccount, `
                                                                            $config, `
                                                                            $true, `
                                                                            $scriptPath
        
        $automationAccountsCheckList += New-Object -TypeName PSObject -Property @{"name"=$copyAutomationAccountName;"type"="copyDedicated";"maxJobsCount"=(Get-ConfigValue $config.automationAccount.maxDedicatedCopyJobs $config)}
    }
}

# Image Creation Process Automation Accounts
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

        Write-Verbose "Submitting PS Job to create image creation process automation account $imgAutomationAccountName" -Verbose
        $automationAccountPSJobs += Start-Job -ScriptBlock $automationAccountsScriptBlock -ArgumentList $azureCredential,  `
                                                                             $imgAutomationAccountName, `
                                                                             (Get-ConfigValue $config.automationAccount.resourceGroup $config), `
                                                                             (Get-ConfigValue $config.automationAccount.location $config), `
                                                                             $imgApplicationDisplayName, `
                                                                             (Get-ConfigValue $config.automationAccount.subscriptionId $config), `
                                                                             ([string]::Format("{0}{1}",$tier0StorageAccountContext.BlobEndPoint,(Get-ConfigValue $config.storage.tier0StorageAccount.modulesContainer $config))), `
                                                                             $sasToken, `
                                                                             $config.automationAccount.runbooks.imageCreationProcessAutomationAccount, `
                                                                             $config, `
                                                                             $true, `
                                                                             $scriptPath

        $automationAccountsCheckList += New-Object -TypeName PSObject -Property @{"name"=$imgAutomationAccountName;"type"="ImageCreationDedicated";"maxJobsCount"=(Get-ConfigValue $config.automationAccount.maxDedicatedImageCreationJobs $config)}
    }
}

# Checking all storage account creation jobs for completion
$aaErrorList = Wait-AzureRmImgMgmtConfigPsJob -jobList $automationAccountPSJobs -timeOutInHours 3 -waitTimeBetweenChecksInSeconds 300 -Verbose

# Checking for errors and stop setup if any
if ($aaErrorList.Count -gt 0)
{
    throw "An error ocurred while creating the automation accounts. Error messages:`n$aaErrorList"
}

# Removing all jobs
Get-Job | Remove-Job

# Checking each automation account and creating the configuration table entries

foreach ($automationAccount in $automationAccountsCheckList)
{
    $result = Find-AzureRmResource -ResourceGroupName  (Get-ConfigValue $config.automationAccount.resourceGroup $config) -ResourceNameEquals $automationAccount.name
    
    if ($result -ne $null)
    {
        $customFilter = "(PartitionKey eq 'automationAccount') and (automationAccountName eq '$($automationAccount.name)')"
        $configQueryResult = Get-AzureStorageTableRowByCustomFilter -customFilter $customFilter -table $configurationTable
    
        if ($configQueryResult -eq $null)
        {
            # Adding the automation account info in the configuration table
            [hashtable]$automationAccountProps = @{ "automationAccountName"=$automationAccount.name;
                                                        "resourceGroupName"=Get-ConfigValue $config.automationAccount.resourceGroup $config;
                                                        "subscriptionId"=Get-ConfigValue $config.automationAccount.subscriptionId $config;
                                                        "applicationDisplayName"=Get-ConfigValue $config.automationAccount.applicationDisplayNamePrefix $config;
                                                        "type"=$automationAccount.type;
                                                        "location"=Get-ConfigValue $config.automationAccount.location $config;
                                                        "connectionName"=Get-ConfigValue $config.automationAccount.connectionName $config}

            if (($automationAccount.type -eq "copyDedicated") -or ($automationAccount.type -eq "ImageCreationDedicated"))
            {
                $automationAccountProps["maxJobsCount"]=$automationAccount.maxJobsCount
            }
    
            Add-AzureStorageTableRow -table $configurationTable -partitionKey "automationAccount" -rowKey ([guid]::NewGuid().guid) -property $automationAccountProps    
        }
    }
    else
    {
        $aaErrorList += "Automation account $($automationAccount.name) of type $($automationAccount.type) could not be found."
    }
}

if ($aaErrorList.Count -gt 0)
{
    throw "An error ocurred during the process of creating the automation accounts while adding its information to the configuration table. Error messages:`n$aaErrorList"
}
#endregion

#region Creating queues
Write-Verbose "Selecting tier 0 subscription $(Get-ConfigValue $config.storage.tier0StorageAccount.subscriptionId $config)" -Verbose
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
#endregion

#region Assign service principal contributor of the t2 involved subscriptions

# Note: To perform this initial assigment the user executing this setup script must be owner of all t2 subscriptions

Select-AzureRmSubscription -SubscriptionId $tier0subscriptionId

Write-Verbose "Getting main automation account information from storage table..." -Verbose
$mainAutomationAccount = Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'automationAccount') and (type eq 'main')" -table $configurationTable

# Obtaining AppID of the service principal
# Getting the authorization token
Write-Verbose "Obtaining a token for the rest api calls against Azure AD" -Verbose
$tenantName = Get-ConfigValue $config.general.tenantName $config
$token = Get-AzureRmImgMgmtAuthToken -TenantName $tenantName -Credential $azureCredential

# Building Rest Api header with authorization token
$authHeader = Get-AzureRmImgMgmtAuthHeader -AuthToken $token 

$uri = "https://graph.windows.net/$($tenantName)/servicePrincipals?`$filter=startswith(displayName,`'" + $mainAutomationAccount.ApplicationDisplayName + "`')&api-version=1.6"
Write-Verbose "Graph Api URI: $uri"

Write-Verbose "Invoking the request" -Verbose
$servicePrincipalList = (Invoke-RestMethod -Uri $uri -Headers $authHeader -Method Get).value

# Adding Subscription from Tier 0 storage to the list as well
$tier2SubscriptionList = @()
$tier2SubscriptionList += Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 0)" -table $configurationTable

Write-Verbose "Getting Tier 2 subscription List" -Verbose
$tier2SubscriptionList += Get-AzureStorageTableRowByCustomFilter -customFilter "(PartitionKey eq 'storage') and (tier eq 2)" -table $configurationTable

# Removing duplicates
if ($tier2SubscriptionList -ne $null)
{
    $tier2SubscriptionList = $tier2SubscriptionList | Select-Object -Property subscriptionId, resourceGroupName, imagesResourceGroup -Unique
}

$rbacPSJobs = @()

if (($servicePrincipalList -ne $null) -and ($tier2SubscriptionList -ne $null) )
{
    foreach ($sub in $tier2SubscriptionList)
    {
        Write-Verbose "Submitting PS Job to apply RBAC for Service Principals on Subscription $($sub.SubscriptionId)" -Verbose

        $rbacPSJobs += Start-Job -ScriptBlock $rbacAssignmentScriptBlock -ArgumentList $azureCredential,  `
                                                                                       $sub.subscriptionID, `
                                                                                       $sub.resourceGroupName, `
                                                                                       $sub.imagesResourceGroup, `
                                                                                       $servicePrincipalList
    }
           
    # Checking all rbac assigments jobs for completion
    $rbacErrorList = Wait-AzureRmImgMgmtConfigPsJob -jobList $rbacPSJobs -timeOutInHours 2 -waitTimeBetweenChecksInSeconds 60
    
    # Checking for errors and stop setup if any
    if ($rbacErrorList.Count -gt 0)
    {
        throw "An error ocurred while applying rbac. Error messages:`n$rbacErrorList"
    }
    
    # Removing all jobs
    Get-Job | Remove-Job
}
else
{
    throw "Service principals with prefix $($mainAutomationAccount.ApplicationDisplayName) not found at Azure AD tenant $($tenantName)"
}
#endregion

Write-Verbose "Setup completed with success" -Verbose
