# Operations/Troubleshooting Guide

This document describes some operations we can do with this solution, starting with submitting a job to distribute your VHDs and create the managed images in Azure to looking at the solution logs and so on. Finally we have a section dedicated to troubleshooting.

## Submitting an image creation job

There are two ways to distribute your custom golden images with this solution, one is from an on-premises located VHD and the other one is from a managed disk that resides in Azure.

### On-premises option 
```powershell
# Authenticating
Add-AzureRmAccount

# Defining some variables and selecting tier 0 subscription
$Tier0SubscriptionId = "<your tier 0 subscription>"
$ConfigStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$ConfigStorageAccountName = "pmctier0sa01"
$ConfigurationTableName="ImageManagementConfiguration"
$imgName = "Windows1709CustomImage-v1.0"
Select-AzureRmSubscription -Subscriptionid $Tier0SubscriptionId

# Changing folder to where you have the Scripts part of this solution
cd \AzureImageManagementAutomation\Scripts

# Executing UploadVHD.ps1 script
.\UploadVHD.ps1 -Description "test submission 01" `
	-Tier0SubscriptionId $Tier0SubscriptionId `
	-ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName `
	-ConfigStorageAccountName $ConfigStorageAccountName `
	-ImageName $imgName `
	-VhdFullPath "C:\Windows1709.vhd" `
	-OsType "Windows"
``` 

### Managed disk option 
```powershell
# Authenticating
Add-AzureRmAccount

# Defining some variables and selecting tier 0 subscription
$Tier0SubscriptionId = "<your tier 0 subscription>"
$ConfigStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$ConfigStorageAccountName = "pmctier0sa01"
$ConfigurationTableName="ImageManagementConfiguration"
$imgName = "Centos7.3-CustomImage-v1.0"
Select-AzureRmSubscription -Subscriptionid $Tier0SubscriptionId

# Changing folder to where you have the Scripts part of this solution
cd \AzureImageManagementAutomation\Scripts

# Executing UploadVHD.ps1 script
.\UploadVHD.ps1 -description "test submission 02" `
	-Tier0SubscriptionId $Tier0SubscriptionId `
	-ConfigStorageAccountResourceGroupName $ConfigStorageAccountResourceGroupName `
	-ConfigStorageAccountName $ConfigStorageAccountName `
	-ImageName $imgName `
	-sourceAzureRmDiskName "centos01_OsDisk_1_28e8cc4091d142ebb3a820a0c703e811" `
	-sourceAzureRmDiskResourceGroup "MyCentosVM-RG" `
	-vhdName "centos-golden-image.vhd" `
	-OsType "Linux"
``` 

## Obtaining information

### Getting reference to the configuration table
Configuration table helps you reference it on most of the exposed cmdlets, makes execution faster since you already go a reference. 

```powershell
$ConfigStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$ConfigStorageAccountName = "pmctier0sa01"
$configurationTableName = "imageManagementConfiguration"
$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
```

### Getting a list of submitted jobs
```powershell
$jobs = Get-AzureRmImgMgmtJob -ConfigurationTable $configurationTable
```

### Getting the last submitted job
```powershell
$jobs = Get-AzureRmImgMgmtJob -ConfigurationTable $configurationTable
$job = ($jobs | sort -Property submissiondate -Descending)[0]
```

### Getting job status
```powershell
$status = Get-AzureRmImgMgmtJobStatus -ConfigurationTable $configurationTable -job $job
$status
```

Output

```
UploadCompletion        : 100
Tier1CopyCompletion     : 100
Tier2CopyCompletion     : 40
ImageCreationCompletion : 0
ErrorCount              : 0
ErrorLog                : {}
JobId                   : 6dba0ed7-feb2-4774-84b6-aea229777cd6
SubmissionDate          : 12/19/2017 4:25:23 PM
Description             :
VhdName                 : Windows1709.vhd
ImageName               : myWindows1709Image-v2
OsType                  : Windows09Image-v2
OsType                  : Windows
```

Checking if it is completed
```powershell
$status.IsCompleted()
```

Output
```
False
```

If there is any error, check the error logs related to this job returned in the ImageMgmtJobStatus objetc
```powershell
$status.ErrorLog
```

Output 

```

```

### Getting specific job logs - specific step
```powershell
# Listing steps enumeration
using module AzureRmImageManagement
[steps].GetEnumNames()
```

Output
```
upload
uploadConcluded
tier1Distribution
tier2Distribution
imageCreation
copyProcessMessage
tier1DistributionCopyConcluded
tier2DistributionCopyConcluded
imageCreationConcluded
```

Getting specific step log
```powershell
$logs = Get-AzureRmImgMgmtLog -ConfigurationTable $configurationTable -jobId $job.jobId -Level All -step tier1DistributionCopyConcluded

```

```powershell
$logs | ft
```
Output
```
jobId                                timeStamp             step                           moduleName                                 logLevel      message
-----                                ---------             ----                           ----------                                 --------      -------
001f2a67-a556-40fb-96fe-affbe97b8056 12/19/2017 4:11:16 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-309
00335dcd-d71a-41a0-b123-a2228e65373f 12/19/2017 4:13:40 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-594
009b906f-99ed-4f16-acd8-c70fc2325574 12/19/2017 4:09:36 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-109
00d70f2c-ee99-4f89-b8c9-66888ccc278d 12/19/2017 4:13:19 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-553
011786fc-626d-4cf3-840b-a84614e939f9 12/19/2017 4:13:51 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-616
...
```

Getting logs for an entire module

```powershell
$logs | sort -Property timestamp | ? { $_.modulename -eq "Start-ImageManagementTier1Distribution.ps1"} | ft
```

Output
```
jobId                                timeStamp             step                           moduleName                                 logLevel      message
-----                                ---------             ----                           ----------                                 --------      -------
22b5b190-923b-4686-ad64-22d09063fca1 12/19/2017 4:01:58 PM tier1Distribution              Start-ImageManagementTier1Distribution.ps1 Informational Obtaining the tier 0 storage account (the one that receives the vhd from on-premises)
4c927adb-3fc0-4316-ab03-14242de53e4e 12/19/2017 4:01:58 PM tier1Distribution              Start-ImageManagementTier1Distribution.ps1 Informational Tier 0 Storage account name: pmctier0sa01
e8395e16-a9c4-48b6-8585-9fcaac14f6ab 12/19/2017 4:01:59 PM tier1Distribution              Start-ImageManagementTier1Distribution.ps1 Informational Getting tier 0 storage account pmctier0sa01 context from resource group PMC-OS-Images-Solution-rg
2721ea4d-0d05-43f7-b4eb-ed533f99ff13 12/19/2017 4:01:59 PM tier1Distribution              Start-ImageManagementTier1Distribution.ps1 Informational Context successfuly obtained.
3f92c3b4-41bf-46d3-ac73-5895a79e618d 12/19/2017 4:02:00 PM tier1Distribution              Start-ImageManagementTier1Distribution.ps1 Informational Starting the copy process to tier 1 blobs
5ee56962-3366-4d5d-a86e-4ef2d6d167d3 12/19/2017 4:08:41 PM tier1Distribution              Start-ImageManagementTier1Distribution.ps1 Informational Checking tier 1 copy completion status
5d0e07b5-5df7-4bee-8f13-174e5e0eac62 12/19/2017 4:08:41 PM tier1Distribution              Start-ImageManagementTier1Distribution.ps1 Informational current status check pass 1, pending copies: 999
583b9d42-454f-4ee3-ade9-4be388dfc736 12/19/2017 4:08:42 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-000
b3ce812f-0045-48f0-8728-5a27319fc9bf 12/19/2017 4:08:42 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-001
8d354042-9079-43f6-a58a-d6ff624fa5fa 12/19/2017 4:08:43 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-002
29124de8-a8af-4ac9-a818-e65a72047cda 12/19/2017 4:08:43 PM tier1DistributionCopyConcluded Start-ImageManagementTier1Distribution.ps1 Informational Completed destination blobCopy: Windows1709.vhd-tier1-003
...

```

## Enabling / Disabling storage accounts for granular job processing

Defining some variables first:
```powershell
$Tier0SubscriptionId = "<subscription id>"
$ConfigStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$ConfigStorageAccountName = "pmctier0sa01"
Select-AzureRmSubscription -Subscriptionid $Tier0SubscriptionId
$ConfigurationTableName="ImageManagementConfiguration"
$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
```

Getting reference to the configuration table
```powershell
$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName
```

Getting the tier 2 storage account objects
```powershell
$saList = Get-AzureRmImgMgmtTier2StorageAccount -configurationTable $configurationTable
```

Disabling storage accounts in East US region
```powershell
$salist | ? {$_.location -eq "eastus"} | % {$_.disable($configurationTable)}
```

Enabling storage accounts in East US region
```powershell
$salist | ? {$_.location -eq "eastus"} | % {$_.enable($configurationTable)}
```

## Onboarding new subscriptions and/or new regions

<TBD>

## Retrying specific job phases

This solution is comprised of 4 key phases as follows:
1. Tier 0 Upload - process to copy the VHD from on-premises or Azure VM or from a Managed disk to the tier 0 Storage Account
2. Tier 1 VHD Copy - process to create multiple copies of the initial uploaded VHD in the tier 0 Storage Account
3. Tier 2 VHD Copy - process to copy the VHD to the tier 2 Storage Accounts in the same or other subscriptions/regions (sourced from  tier 1 VHDs created in the previous phase) 
4. Image Creation - final process, it creates the managed images in each subscription/region where the tier 2 storage accounts exists and got a copy of the original VHD 

Currently for steps/phases 1 and 2, there is not much to be done, for the other ones, please follow these instructions:

### Tier 2 VHD Copy 
* xyz


### Image Creation
Sometimes we may have an issue during the image creation process, this is an example of an issue that we might have while evaluating the status of a distribution job:

```powershell
# Getting configuration table reference

$configurationTable = Get-AzureRmImgMgmtTable -ResourceGroup $ConfigStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $configurationTableName

# Getting job list

$jobs = Get-AzureRmImgMgmtJob -ConfigurationTable $configurationTable

# Looking at the jobs

$jobs 

```

Result

```
JobId          : a0ed7556-1b5e-4d09-8874-9e175a34078d
SubmissionDate : 2/11/2018 6:48:45 PM
Description    : Test submission 01
VhdName        : centos-golden-image.vhd
ImageName      : Centos7.3-CustomImage-v1.0
OsType         : Linux
```

```powershell
# Getting status of this job

$status = Get-AzureRmImgMgmtJobStatus -ConfigurationTable $configurationTable -job $jobs[0]

# Result
$status

```

```
UploadCompletion        : 100
Tier1CopyCompletion     : 100
Tier2CopyCompletion     : 100
ImageCreationCompletion : 88
ErrorCount              : 1
ErrorLog                : {New-ImageManagementImage.ps1}
JobId                   : a0ed7556-1b5e-4d09-8874-9e175a34078d
SubmissionDate          : 2/11/2018 6:48:45 PM
Description             : Test submission 01
VhdName                 : centos-golden-image.vhd
ImageName               : Centos7.3-CustomImage-v1.0
OsType                  : Linux
```

Here we notice that ErrorCount is greater than 0 and that ImageCreationCompletion is at 88%, this clearly means that something went wrong. The following command line will show the error list for us:

```powershell
$Status.ErrorLog
```

Result

```
jobId      : a0ed7556-1b5e-4d09-8874-9e175a34078d
timeStamp  : 2/11/2018 9:01:23 PM
step       : imageCreation
moduleName : New-ImageManagementImage.ps1
logLevel   : Error
message    : An error occured trying to create an image. VhdDetails: {
                 "jobId":  "a0ed7556-1b5e-4d09-8874-9e175a34078d",
                 "osType":  "Linux",
                 "imagesResourceGroup":  "Images-RG",
                 "imageName":  "Centos7.3-CustomImage-v1.0",
                 "subscriptionId":  "4a49ea85-ce71-4800-b854-5d18e557921e",
                 "location":  "uksouth",
                 "vhdUri":  "https://pmcosimgsa04587tier2.blob.core.windows.net/vhds/centos-golden-image.vhd"
             }.
             Error: The source blob https://pmcosimgsa04587tier2.blob.core.windows.net/vhds/centos-golden-image.vhd does not belong to a storage account in subscription 4c88ebbb-1a1d-4e0a-980c-f76b82743539.
             ErrorCode: InvalidParameter
             ErrorMessage: The source blob https://pmcosimgsa04587tier2.blob.core.windows.net/vhds/centos-golden-image.vhd does not belong to a storage account in subscription
             4c88ebbb-1a1d-4e0a-980c-f76b82743539.
             StatusCode: 400
             ReasonPhrase: Bad Request
             OperationID : 7fb58753-d9ff-4e75-9f30-8acd98ec749c
```

After identifying the error and fixiging whatever it is we can retry only the Image creation process. Notice that the error log contains a field called message, we will reuse part of this content to retry it, in this case we need the original json string and we can for example obtain it with:

```powershell
"{" + $status.errorlog[0].message.tostring().split("{",[System.StringSplitOptions]::RemoveEmptyEntries)[1].split("}",[System.StringSplitOptions]::RemoveEmptyEntries)[0] + "}"
```

Result

```
{
    "jobId":  "a0ed7556-1b5e-4d09-8874-9e175a34078d",
    "osType":  "Linux",
    "imagesResourceGroup":  "Images-RG",
    "imageName":  "Centos7.3-CustomImage-v1.0",
    "subscriptionId":  "4a49ea85-ce71-4800-b854-5d18e557921e",
    "location":  "uksouth",
    "vhdUri":  "https://pmcosimgsa04587tier2.blob.core.windows.net/vhds/centos-golden-image.vhd"
}
```

Copy this content, open Storage Explorer (if you don't have it installed, please install from https://azure.microsoft.com/en-us/features/storage-explorer/).

Go to the tier 0 storage account, expand Queues and find image-creation-process-queue.

Click in the "+ Add Message" button and paste the json content and wait for the schedule to kick in.



# Troubleshooting

This guide is a work in progress and will be updated frequently to include new ways to troubleshoot this solution.

## Basic troubleshooting steps (where to look)
<TDB>

## How to restart the copy process starting from Tier 2 distribution

1) Define some variables in Powershell that will help:

```powershell
$configStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$configStorageAccountName = "pmctier0sa01"
$jobsTableName = "imageManagementJobs"
$jobsLogTableName = "imageManagementJobLogs"
```

2) Two options to identify your copy process jobs

	2.1) Identify the Job Id by opening the Configuration Table (usually called imageManagementConfiguration) located at Tier 0 (or Configuration) storage account with Storage Explorer.
		2.1.1) After identifiying which job, copy the content of RowKey (that's the job Id)

		OR

	2.2) Run the following cmdlets to get the list of jobs from Powershell
		
```powershell
$jobTable = Get-AzureStorageTableTable -ResourceGroup $configStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $jobsTableName
Get-AzureStorageTableRowAll -table $jobTable
```

2) Store the rowKey attribute value from the job you wish to restart the tier 2 process, in this example I have the following value:

```powershell
$jobId = "82cb707e-91a5-4c9e-a24f-719971d27109"
```

3) Run the following command line and copy the content of the message that starts with {jobId:
	
```powershell
$log = Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName $configStorageAccountResourceGroupName -ConfigStorageAccountName $configStorageAccountName -jobId $jobId | select rowkey,message | ? { $_.message -like ('*jobId":*')}

$log
```

	Output Example:


| RowKey | message |
| --- | --- |
| 8057f39a-e6c8-43c0-8421-eec416e206df | {"jobId":"82cb707e-91a5-4c9e-a24f-719971d27109","imagesResourceGroupName":"Images-RG01","imageName":"WinServerCore2016-Img01","osType":"Windows","vhdName":"WinServerCore2016-OsDisk.vhd"} |
| 92410572-c00f-4a2e-be89-d884c28613d0 | Starting tier1 distribution. Runbook Start-ImageManagementTier1Distribution with parameters: {"jobId":"82cb707e-91a5-4c9e-a24f-719971d27109","Tier0SubscriptionId":"4a49ea85-ce71-4800-b854-5d18e557921e","ConfigStorageAccountName":"pmctier0sa01","ConfigStorageAccountResourceGroupName":"PMC-OS-Images... |

4) Copy the contents of message attribute that starts with "{jobId"
	
	In this example the content to be copied is:

	{"jobId":"82cb707e-91a5-4c9e-a24f-719971d27109","imagesResourceGroupName":"Images-RG01","imageName":"WinServerCore2016-Img01","osType":"Windows","vhdName":"WinServerCore2016-OsDisk.vhd"}

	If you want to store the message content in a variable, identify which line (starts with 0) and assign to a variable, for example:
	
```powershell
$queueMessage = $log[0].message
```

5) Place this content in the queue using azure Storage Explorer or Powershell and wait or restart the Start-ImageManagementTier2Distribution using the same values for the paramters from the failed job.


## Getting log information from the Tier 2 Distribution Runbook

High level steps to start querying:

1) Sign in to Azure from PowerShell
2) Define some variables 
4) Obtain the job Id
3) Execute the log query cmdlet, in this example we are querying 

Code

```powershell
# Sign in
Add-AzureRmAccount

# Define some variables
$configStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$configStorageAccountName = "pmctier0sa01"
$jobsTableName = "imageManagementJobs"
$jobsLogTableName = "imageManagementJobLogs"

# Obtain the copy vhd job table
$jobTable = Get-AzureStorageTableTable -ResourceGroup $configStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $jobsTableName

# List all jobs
Get-AzureStorageTableRowAll -table $jobTable

# Define the job id to work with
$jobId= "<row key of the job you want to query>"

# Run the query cmdlet
Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName $configStorageAccountResourceGroupName -ConfigStorageAccountName $configStorageAccountName -jobId $jobId -Level All -step tier2Distribution | sort tableTimeStamp | select tableTimeStamp,step,message
```

## Setup.ps1 script intermitently get the Connection AzureRunAsConnection with a wrong Application Id with value System.Object[]

Setup.ps1 script may generate issues in the Automation Accounts and the initial Update runbook will fail due to Connections on the Automation Account may be generating random System.Object[] application id instead of the real application ID.
Workaround today is:
* Go to the Automation Account that has the Update-ModulesInAutomationToLatestVersion runbook job failed
* Go to Connections, click on “AzureRunAsConnection”
* Check the field “ApplicationID”
* If the content looks like: System.Object[] please follow these steps to obtain the Application ID:
* On your Setup Info json file, get the value of automationAccount. applicationDisplayNamePrefix (e.g. pmcPMCOSImg-SP)
* Using Portal
	* Take note of the Automation Account Name (e.g. pmcPMCOSImg-AA-Copy001) 
	* Go to Azure AD
	* Click on App Registrations
	* In the “Search by name or AppId”, paste the value obtained on the first step
	* Click in the Application that most matches your Automation Account Name (in my example: pmcPMCOSImg-SP-Copy001, remember that there will be one app registration/service principal per automation account the setup script creates)
	* Copy the value of Application ID
	* Go back to your automation account/connection/AzureRunAsConnection and paste the content in the ApplicationID field and save it
* Partially Using PowerShell
	* Take note of the Automation Account Name (e.g. pmcPMCOSImg-AA-Copy001) 
	* Open Powershell and execute the following cmdlets

	```powershell
	Connect-AzureAD
	$appDisplayName = “<value obtained on first step>”
	Get-AzureAdServicePrincipal -SearchString $appDisplayName
	```

	* This will output your service principals created by the setup scripts:

	```
	ObjectId                             AppId                                DisplayName
	--------                             -----                                -----------
	8573b393-d34d-4c50-8693-a4a310ca287b c812c395-57f7-425a-9623-de54cf1087f3 pmcPMCOSImg-SP
	4fe21ffc-6235-4f2c-835a-fb5261753953 57f526fe-f655-43f1-9dd1-0e54b5326401 pmcPMCOSImg-SP-Copy001
	```

	* Copy the Application ID that most matches your Automation Account Name (in my example: pmcPMCOSImg-SP-Copy001, remember that there will be one app registration/service principal per automation account the setup script creates)
	* In the portal, go to your Automation Account/connection/AzureRunAsConnection and paste the content in the ApplicationID field and save it

## UploadVHD.ps1 - After MD5 hash calculation finishes during the upload process an error occurs

THe following error message appears after the MD5 phase of Add-AzureRmVHD cmdlet used inside of UploadVHD.ps1 script:

```
Add-AzureRmVhd : The pipeline was not run because a pipeline is already running. Pipelines cannot be run concurrently.
At C:\AzureImageManagementAutomation-master\Scripts\UploadVHD.ps1:187 char:9
+         Add-AzureRmVhd `
+         ~~~~~~~~~~~~~~~~
    + CategoryInfo          : CloseError: (:) [Add-AzureRmVhd], PSInvalidOperationException
    + FullyQualifiedErrorId : Microsoft.Azure.Commands.Compute.StorageServices.AddAzureVhdCommand
```

This may be caused because Azure Storage Explorer is opened and using the Configuration Storage Account (tier0 Storage Account), so please just close Azure Storage Explorer and retry the upload.

## UploadVHD.ps1 - During the data transfer phase of Add-AzureRmVHD you get a generic error message from a VM running the script in Azure

Uploading a VHD from a VM in Azure may raise the following error message:

Add-AzureRmVhd : One or more errors occurred.
At C:\AzureImageManagementAutomation-master\Scripts\UploadVHD.ps1:187 char:9
+         Add-AzureRmVhd `
+         ~~~~~~~~~~~~~~~~
    + CategoryInfo          : CloseError: (:) [Add-AzureRmVhd], AggregateException
    + FullyQualifiedErrorId : Microsoft.Azure.Commands.Compute.StorageServices.AddAzureVhdCommand


This may be caused due to the number of default upload threads, which is 10, retry the operation using the parameter  -UploaderThreadNumber to a number lower than 10 which is the default value.