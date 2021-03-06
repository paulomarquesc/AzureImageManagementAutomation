
# Release Notes

### Release 2/06/2018
* Increased total wait time for Application and Service Principal to 30 minutes, being checked every 60 seconds
* Fixed a bug related to function Get-AzureRmImgMgmtStorageContext that was returning System.Object insted of Storage Context Object.

### Release 1/24/2018
* Implementation of a feature to ignore runbook schedules and perform the VHD distribution and image creation as quick as possible
* Fixed a setup.ps1 issue where the attribute of maxJobsCount was not being added to the automation accounts, leading to an automation account not being able to be selected for tier 2 VHD distribution or image creation processes 
* Identified and Fixed issue related to System.Object[] value as application id of the run as connection object 

### Release 1/17/2018
* Created an internal function in order to wait for the PS jobs for completion and reduce the amount of code in the setup.ps1 file.
* Renamed some of the module functions to be more in accordance with PowerShell cmdlet standards
* Included a missing requirement on setup guide

### Release 1/11/2017
* Implemented the same parallel execution applied to the Automation Accounts for tier 2 storage account configuration.
* Optimized the RBAC role associations based on tier 2 storage account list by removing duplications

### Release 1/10/2017
* Setup time drastically reduced when creating more than one worker automation accounts, all automation accounts setup now are executed in parallel.
* Tier 2 storage accounts are now of Kind "Blob Storage" only

### Release 12/21/2017
* Included a test during setup phase to check if Microsoft.Compute resource provider is registered and perform registration if not

### Release 12/18/2017
* Implemented a way to control which tier 2 storage accounts will receive the VHD, now there is boolean attribute called "enabled" on tier 2 storage account configuration in the configuration table and the Start-ImageManagementTier2Distribution runbook will take into consideration only enabled storage accounts in order to make the tier 2 copies.
* Implemented solution storage account classes: ImageMgmtStorageAccount (base), ImageMgmtTier0StorageAccount, ImageMgmtTier2StorageAccount
* Implemented a new cmdlet to get Tier2 Storage Account objects from configuration table, called Get-AzureRmImgMgmtTier2StorageAccount 
* Tier 2 Storage Accounts can now be enabled or disabled throught the implemented method called Enable() or Disable(), which can be triggered from the objects returned from the Get-AzureRmImgMgmtTier2StorageAccount cmdlet. For examples, please see [Operations Guide - Troubleshooting Section](docs/OperationsGuide.md)
* Making tier 1 copies distributed amongst different sources
* Fixed a bug on Get-AzureRmImgMgmtLog where the returned job id was the row key of each log entry instead of the partition key of the log entry
* ImageMgmtJobStatus class was not updating the Description propoerty
* New-ImageManagement.ps1 runbook was not selecting tier 0 subscription, causing errors to be logged 
* Remove-AzureRmImgMgmtJobBlob does not cause stopping error since multiple jobs may try to remove blobs at the same time 

### Release 12/17/2017
* Implemented cmdlet Remove-AzureRmImgMgmtJobBlob to remove all blobs related to a specific job
* Changed New-ImageManagementImage.ps1 runbook so it now tests if the job is completed and invokes Remove-AzureRmImgMgmtJobBlob for clean up

### Release 12/15/2017
* Fixed 15 seconds delay each time a table is referenced
* Implemented job status retrieval capability with  cmdlet Get-AzureRmImgMgmtJobStatus
* Increasing retries to 10 every 30 seconds by default on Get-AzureRmImgMgmtStorageContext and Get-AzureRmImgMgmtTable
* Placed a null test inside the loop when getting the context on Get-AzureRmImgMgmtStorageContext so there is no wait if the context is already obtained
* Job Status object ImageMgmtJobStatus now have a list of errors at ErrorLog property

### Release 12/14/2017
* Changed the output of Get-AzureRmImgMgmtLog to return JobId and Timestamp as propoerty names instead of PartitionKey and TableTimestamp
* Created a cmdlet to get submitted jobs called Get-AzureRmImgMgmtJob

### Release 12/13/2017
* Improved control over how many jobs are running/about to run under an automation account
* Removed the option to place back the messages in the queue in case of an error, this process should be a controlled process to avoid loops
* Create a function called Get-AzureRmImgMgmtStorageContext in order to retry getting the storage context
* Error 409 was not caught while starting the VHD copy 
* Deleting messages from queue after they are dequeued, we don't want the messages randomly back to the queue if an error happens during processing
* Created a new function to retry getting a table in this shared environment to increase reliability called Get-AzureRmImgMgmtTable
* Included some more output on New-ImageManagementImage.ps1 runbook 
* Included new parameter in the setup info file called  startTimeOffset (in minutes) related to each runbook where schedule applies, this will tell when to start, so Tier 2 copy will start 30 minutes before Image Creation, if attribute is missing it will default to 0 minutes

### Release 12/07/2017
* Upated the UploadVHD.ps1 file to allow the VHD upload to the tier 0 storage account directly from a managed disk
* Updated troubleshoot guide due to the change in AzureRmStorageTable related to system default entity attribute called Timestamp that was renamed to TableTimestamp due to conflicts when customers already have a custom attribute with same name
* To be more exact regarding Job Ids, just a single item is fetched from the queue and processed at a given scheduled execution 
* Included new cmdlets in AzureRmImageManagement module to update logs with temporary job id and to clean up empty job id items
* Fixed a typo on steps enumeration, correct item is imageCreationConcluded
* Implemented log capabilities on remaining runbooks

### Release 12/05/2017
* Updated script GenerateTier2StorageJson.ps1 to work with the setup info file directly as the only option and fixed an issue with hard coded storage account prefix, which now is a parameter
* Updated Setup.ps1 script in order to apply Contributor role assigment at the resource group level instead of subscription level

### Release 11/03/2017
* Updated SetupInfo.Json file.
* Replaced dependency on MSOnline to AzureAD module 
* Adding erroraction=stop to runbooks and improved an error message on new-imagemanagementimage and start-imagemanagementtier2distribution
* Implemented a capability of this script to change the setup file directly
* Commented line that contains $GetServicePrincipal on script New-AzureRmImgMgmtRunAsAccount.ps1 because it is unecessary
* Included #region statements on setup.ps1 script to unclutter it

### Release 10/31/2017
* New-AzureRmImgMgmtRunAsAccount changed to don't require elevated privileges
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