<#
.SYNOPSIS
    GenerateTier2StorageJson.ps1 - This sample script generates a storage account to be onboarded.
.DESCRIPTION
    GenerateTier2StorageJson.ps1 - This sample script generates a storage account to be onboarded. This is meant to be executed when a new subscription needs to be onboarded
    in the image process solution, it requires a subscription Id, which regions to create the storage accounts and an individual starting Id for each storage account, the output
    will be one storage account per region per subscription. This output is a JSON file with the individual tier 2 storage account entries, which needs to be copied excluding the []'s,
    into the SetupInfoHON.json file at the end of the section tier2StorageAccounts, please remember that this is a JSON file and needs to be JSON compliant so extra attention is needed
    regarding commas, brakets and curly brakets.

    This script just generates the output necessary to be copied inside the SetupInfoHON.json file, it does not create any resource in Azure. After the setup file is updated with 
    the new content, it is required to execute the Setup.ps1 script again, in order to add the storage accounts to support a new subscription(s)/region(s).

.PARAMETER subscriptionId
    Individual subscription id to be onboarded, meaning that the storage account(s) json definitions will be generated there. Quantity of storage accounts will depend on the number of regions
    supported by this subscription.
.PARAMETER subscriptionListFile
    Subscription id list file to be onboarded, meaning that the storage account(s) json definitions will be generated there. Quantity of storage accounts will depend on the number of regions
    supported by each subscription inside of the file.
.PARAMETER regionList
    Array of regions supported by the subscription, if there is one region, only one storage account item definition will be generated, if there is two, two storage accounts and so on.
.PARAMETER startingIdNumber
    Since this solution supports expansions, an unique Id for each storage account to be created is required, this is because the Setup.ps1 script checks this Id agains the Configuration Table,
    if this Id is there, the creation of that storage account will be skipped because that means that it was previously created. Best practice is to open the SetupInfoHON.json file,
    look at the tier2StorageAccounts section and look the last number used, add one to that number and then you will have the necessary sequence to just append to the file.
.PARAMETER outputFile
    This is the JSON file containing the output for the storage accounts, as mentioned in the description, copy the contents to the correct section of the setup file and execute
    the setup script again in order to have the new storage accounts in the target regions and subcription.
.EXAMPLE
    Single Subscription
    .\GenerateTier2StorageJson.ps1 -subscriptionId "123456" -regionList "westus","eastus","brazilsouth" -startingIdNumber 20 -outputFile .\test1.json
.EXAMPLE
    Subscription list from file
    .\GenerateTier2StorageJson.ps1 -subscriptionListFile .\subs.csv -regionList "westus","eastus","brazilsouth" -startingIdNumber 20 -outputFile .\test2.json
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true,ParameterSetName="subscriptionId")]
    [string]$subscriptionId,

    [Parameter(Mandatory=$true,ParameterSetName="subscriptionFile")]
    [string]$subscriptionListFile,

    [string[]]$regionList,
    [int]$startingIdNumber,
    [string]$outputFile = "onboardStorageAccounts.json"
)

$onboardStorageAccounts = @()

switch ($PSCmdlet.ParameterSetName)
{
    "subscriptionId"
    {
        foreach ($region in $regionList)
        {
            $onboardStorageAccounts += New-Object -typename PSObject -Property @{"id"="$startingIdNumber";
                                                                                    "storageAccountName"='^([StorageAccountName]::new(\"honosimg\",[storageAccountTier]::tier2)).GetSaName($true)';
                                                                                    "resourceGroup"='^$config.storage.tier0StorageAccount.resourceGroup';
                                                                                    "location"=$region;
                                                                                    "container"='^$config.storage.tier0StorageAccount.container';
                                                                                    "subscriptionId"="$subscriptionId"}
            $startingIdNumber += 1
        }
    }

    "subscriptionFile"
    {
        if (!(Test-Path $subscriptionListFile))
        {
            throw "Subscription file $subscriptionListFile not found."
        }

        $subscriptions = Get-Content $subscriptionListFile

        foreach ($sub in $subscriptions)
        {
            foreach ($region in $regionList)
            {
                $onboardStorageAccounts += New-Object -typename PSObject -Property @{"id"="$startingIdNumber";
                                                                                     "storageAccountName"='^([StorageAccountName]::new(\"honosimg\",[storageAccountTier]::tier2)).GetSaName($true)';
                                                                                     "resourceGroup"='^$config.storage.tier0StorageAccount.resourceGroup';
                                                                                     "location"=$region;
                                                                                     "container"='^$config.storage.tier0StorageAccount.container';
                                                                                     "subscriptionId"="$sub"}
                $startingIdNumber += 1
            }
        }
    }
}


$onboardStorageAccounts | ConvertTo-Json  | % {$_.replace("\\\","\")} | Out-File $outputFile