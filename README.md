# AzureImageManagementAutomation

For detailed information on how to setup and use this solution, please refer to https://blogs.technet.microsoft.com/paulomarques/2017/08/13/new-azure-automation-solution-azure-image-management-automation/.

## Release Notes
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

### Release 10/31/2017
* New-RunAsAccount changed to don't require elevated privileges
* Included code in setup.ps1 script to add the log configuration information to the configuration table