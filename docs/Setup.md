# Setup Guide

This document provides all necessary steps to have a quick setup. 

## Requirements

### Software

1. PowerShell 5.0 or greater

2. Following Azure PowerShell modules
    * AzureAD 2.0.0.131 or greater
    * AzureRM.Profile 4.1.1 or greater
    * AzureRM.Resources 5.1.1 or greater
    * AzureRM.Storage 4.1.0 or greater
    * Azure.Storage 4.0.2 or greater
    * AzureRm.Automation 4.0.0 or greater
    * AzureRmStorageQueue 1.0.0.4 or greater
    * AzureRmStorageTable 1.0.0.21 or greater
    * AzureRmImageManagement 1.0.0.25 or greater

### Subscription requirements

The User executing the setup process must have owner role assigned at subscription level of all subscriptions involved in the image distribution because it is the user that will create all assets of this solution, e.g. Automation Accounts, Service Principals in Azure AD, Resource Groups, Storage Accounts, assign permissions, etc.

### Installation

1. Install Required PowerShell modules:

```powershell
Install-Module AzureRm.Storage
Install-Module AzureRm.Profile
Install-Module AzureRm.Resources
Install-Module Azure.Storage
Install-Module AzureAD
Install-Module AzureRm.Automation
Install-Module AzureRmStorageTable
Install-Module AzureRmStorageQueue
Install-Module AzureRmImageManagement
```

2. Download the solution from GitHub (https://github.com/paulomarquesc/AzureImageManagementAutomation/archive/master.zip)

3. The ZIP file will be named **AzureImageManagementAutomation-master.zip**, right-click this file, click properties and make sure you click unblock checkbox

4.  Extract the content to the root of C: drive (if you extract to the default folder it would end up being `<your folder>`\ AzureImageManagementAutomation-master\AzureImageManagementAutomation-master). If that's the case, remove the -master of both levels and make sure thatyou to move the content of the second level to the first folder level, your folder structure would look like this:
```
<your folder>\AzureImageManagementAutomation\Setup
<your folder>\AzureImageManagementAutomation\Modules
<your folder>\AzureImageManagementAutomation\Runbooks

Example

C:\AzureImageManagementAutomation\Setup
C:\AzureImageManagementAutomation\Modules
C:\AzureImageManagementAutomation\Runbooks

```

5. Open the SetupInfo.Json file that is located at `<your folder>\AzureImageManagementAutomation\Setup` and edit the following attributes:

    >**NOTE:**
    >Detailed description of all attributes and sections are located at https://blogs.technet.microsoft.com/paulomarques/2017/08/13/new-azure-automation-solution-azure-image-management-automation/ 
    ---

    * general.tenantName
    * general.imagesResourceGroup
    * storage.tier0StorageAccount.resourceGroup
    * storage.tier0StorageAccount.location
    * storage.tier0StorageAccount.subscriptionId
    * storage.tier0StorageAccount.tier1Copies (if needed)
    * automationAccount.applicationDisplayNamePrefix
    * automationAccount.location (Automation Accounts supported loactions only, obtained with **Get-AzureRmResourceProvider -ProviderNamespace Microsoft.Automation | select -ExpandProperty locations -Unique**)
    * automationAccount.automationAccountNamePrefix
    * automationAccount.workerAutomationAccountsCount - formula to obtain this number is (# Of Subscriptions X # Of Covered Regions X # Of Images) / 150, this will give how many concurrent jobs you will have

6. Save the file

7. Add the content for the storage.tier2StorageAccounts section using the **GenerateTier2StorageJson.ps1** script as follows:
    1. Create a text file in `<your folder>`AzureImageManagementAutomation\Setup folder, e.g. subs.txt
    2. Add all guids of the subscriptions you want to have the manged image created:
        ```
        7d5d709a-fbbe-4bd3-a4d3-03b01d0ce0d2
        31e30218-1c3e-4d40-ada9-748bbd42e0c3
        29abcaaf-1ef3-46a2-a51a-39e1effd5de2
        d58edce4-c3aa-460d-8796-7784803619c5
        d3882bb0-4b61-4d64-9096-a8ea33feb997
        ```
    3. Save the file

8. From `<your folder>`AzureImageManagementAutomation\Setup, execute the script adding the path to the subcription id list file, setup info filem the storage account name prefix and which regions to cover, e.g.
    ```powershell
    .\GenerateTier2StorageJson.ps1 -subscriptionListFile ./subs.txt -setupInfoFile .\SetupInfo.json -regionList eastus, westus, brazilsouth, uksouth -storageAccountPrefix myosimgsa
    ```
9. This will generate a new SetupInfo file with the New and a time stamp appended to it. e.g.
    ```
    SetupInfo.New-2018-01-18T01_36_53.json
    ```
10. Create a PowerShell Credential object
    ```powershell
    $cred = Get-Credential
    ```
11. Execute the setup script using the newly created SetupInfo file and the credential
    ```powershell
    .\Setup.ps1 -configFile .\SetupInfo.New-2018-01-18T01_36_53.json -azureCredential $cred
    ```



