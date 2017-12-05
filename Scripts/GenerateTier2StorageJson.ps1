<#
.SYNOPSIS
    GenerateTier2StorageJson.ps1 - This sample script generates a storage account to be onboarded.
.DESCRIPTION
    GenerateTier2StorageJson.ps1 - This sample script generates a storage account to be onboarded. This is meant to be executed when a new subscription needs to be onboarded
    in the image process solution, it requires a subscription Id, which regions to create the storage accounts and an individual starting Id for each storage account, the output
    will be one storage account per region per subscription. This includes the individual tier 2 storage account entries into the setup info json file at the end of the section tier2StorageAccounts.
    This script just generates the output inside of a new setup info json file, it does not create any resource in Azure. After the setup file is updated with 
    the new content, it is required to execute the Setup.ps1 script for the first time or again, in order to add the storage accounts to support a new subscription(s)/region(s).
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
.PARAMETER setupInfoFile
    Points to the setup info file used by the Azure Image Management Automation solution, if this argument is passed, this script will update the file directly and place the additional
    storage entries in the correct section. 
.PARAMETER storageAccountPrefix
    Storage account prefix, maximum length is 14 due to some other unique strings being appeneded during the setup process. 
.EXAMPLE
    Single Subscription using own numbering for storage identification in the config file
    .\GenerateTier2StorageJson.ps1 -subscriptionId "123456" -regionList "westus","eastus","brazilsouth" -startingIdNumber 20 -setupInfoFile .\test1.json
.EXAMPLE
    Subscription list from file using own numbering for storage identification in the config file
    .\GenerateTier2StorageJson.ps1 -subscriptionListFile .\subs.csv -regionList "westus","eastus","brazilsouth" -startingIdNumber 20 -setupInfoFile .\test2.json
.EXAMPLE
    Subscription list from file using a auto generated guid for storage identification in the config file
    .\GenerateTier2StorageJson.ps1 -subscriptionListFile .\subs.csv -regionList "westus","eastus","brazilsouth" setupInfoFile .\test2.json
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true,ParameterSetName="subscriptionId")]
    [string]$subscriptionId,

    [Parameter(Mandatory=$true,ParameterSetName="subscriptionFile")]
    [string]$subscriptionListFile,

    [Parameter(Mandatory=$true)]
    [string]$setupInfoFile,

    [string[]]$regionList,
    
    [Parameter(Mandatory=$false)]
    [int]$startingIdNumber=-1,

    [Parameter(Mandatory=$true)]
    [string]$storageAccountPrefix
    

)

function createStorageAccountEntry
{
    param
    (
        [string]$id,
        [string]$region,
        [string]$subscriptionId,
        [string]$saPrefix
    )

    return New-Object -typename PSObject -Property @{"id"="$id";
                "storageAccountName"='^([StorageAccountName]::new("'+$saPrefix+'",[storageAccountTier]::tier2)).GetSaName($true)';
                "resourceGroup"='^$config.storage.tier0StorageAccount.resourceGroup';
                "location"=$region;
                "container"='^$config.storage.tier0StorageAccount.container';
                "subscriptionId"="$subscriptionId"}

}

$ErrorActionPreference = "Stop"

if ($storageAccountPrefix.Length -gt 14)
{
    throw "Storage Account prefix length cannot be greater then 14 characters."
}

if (!(Test-Path $setupInfoFile))
{
    throw "Setup information $setupInfoFile file not found."
}

$outputFileName = [string]::Format("{0}.New-{1}{2}",[system.io.Path]::GetFileNameWithoutExtension($setupInfoFile),(get-date -Format s).tostring().replace(":","_"),[system.io.Path]::GetExtension($setupInfoFile))
$outputFile = join-path -path ([system.io.Path]::GetDirectoryName($setupInfoFile)) $outputFileName

$onboardStorageAccounts = @()

switch ($PSCmdlet.ParameterSetName)
{
    "subscriptionId"
    {
        foreach ($region in $regionList)
        {
            if ($startingIdNumber -gt -1)
            {
                $onboardStorageAccounts += createStorageAccountEntry -id $startingIdNumber -region $region -subscriptionId $subscriptionId -saPrefix $storageAccountPrefix
                $startingIdNumber += 1
            }
            else
            {
                $onboardStorageAccounts += createStorageAccountEntry -id ([guid]::NewGuid().Guid) -region $region -subscriptionId $subscriptionId -saPrefix $storageAccountPrefix
            }
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
                if ($startingIdNumber -gt -1)
                {
                    $onboardStorageAccounts += createStorageAccountEntry -id $startingIdNumber -region $region -subscriptionId $sub -saPrefix $storageAccountPrefix
                    $startingIdNumber += 1
                }
                else
                {
                    $onboardStorageAccounts += createStorageAccountEntry -id ([guid]::NewGuid().Guid) -region $region -subscriptionId $sub -saPrefix $storageAccountPrefix
                }
            }
        }
    }
}

$config = Get-Content $setupInfoFile -Raw | ConvertFrom-Json

foreach ($storage in $onboardStorageAccounts)
{
    $config.storage.tier2StorageAccounts += $storage
}

# Generating a new SetupInfo file
$config | ConvertTo-Json -Depth 99 | Out-File $outputFile
