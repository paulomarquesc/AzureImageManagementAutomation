# AzureImageManagementAutomation

For detailed information on how to setup and use this solution, please refer to https://blogs.technet.microsoft.com/paulomarques/2017/08/13/new-azure-automation-solution-azure-image-management-automation/.

## Release Notes

### Release 12/05/2017
* Updated script GenerateTier2StorageJson.ps1 to work with the setup info file directly as the only option and fixed an issue with hard coded storage account prefix, which now is a parameter
* Updated Setup.ps1 script in order to apply Contributor role assigment at the resource group level instead of subscription level

### Release 11/03/2017
* Updated SetupInfo.Json file.
* Replaced dependency on MSOnline to AzureAD module 
* Adding erroraction=stop to runbooks and improved an error message on new-imagemanagementimage and start-imagemanagementtier2distribution
* Implemented a capability of this script to change the setup file directly
* Commented line that contains $GetServicePrincipal on script New-RunAsAccount.ps1 because it is unecessary
* Included #region statements on setup.ps1 script to unclutter it

### Release 10/31/2017
* New-RunAsAccount changed to don't require elevated privileges
* Included code in setup.ps1 script to add the log configuration information to the configuration table
* Setup.ps1 script now checks if the storage account was already created by looking at the "id" attribute of each storage account in the setupinfo.json file.
* Created an auxiliary script called GenerateTier2StorageJson.ps1 that automatically generates the json section for the tier 2 storage accounts for a subscription and regions
* Fixed a bug on Start-ImageManagementTier2Distribution related to a hard coded container  name
* Changed the Image creation process to append the location at the end of the image name and delete the old image if it already exists

### Release 10/30/2017
* Implemented logging capabilities into a log table, two tables were created for that, *imageManagementJobs* and *imageManagementJobLogs*.
* Implemented some enumerations as follows: logLevel, status, steps and storageAccountTier at AzureRmImageManagementCoreHelper.psm1 module
* Implemented a class called StorageAccountName which gives us an unique storage account name based on a prefix
* Implemented a new function called Get-AzureRmImgMgmtLogTable to get the reference to the log table
* Implemented Get-AzureRmImgMgmtLog to get log details of a job
* SetupInfo.json and setup.ps1 script had all storageAccountPrefix renamed to storageAccountName
* Implemented log UPloadVhd.ps1, Start-ImageManagementTier1Distribution.ps1 and Start-ImageManagementTier1Distribution.
* Changed Get-AzureRmImgMgmtAuthToken to take an Microsoft.IdentityModel.Clients.ActiveDirectory.UserIdentifier object as parameter a parameter for promptBehavior which by default does not prompt anymore.
* Due to a bug related to Get-AzureRmRoleAssignment, described on Github https://github.com/Azure/azure-powershell/issues/4828 issue, included a -SilentlyContinue at the line that applies RBAC (New-AzureRmRoleAssignment) on Setup.ps1. Will remove as soon as the fix gets into production.