@{

# ID used to uniquely identify this module
GUID = '28185603-f789-493d-a17d-7fda8d414890'

# Author of this module
Author = 'Paulo Marques (MSFT)'

# Company or vendor of this module
CompanyName = 'Microsoft Corporation'

# Copyright statement for this module
Copyright = '© Microsoft Corporation. All rights reserved.'

# Description of the functionality provided by this module
Description = 'Sample PowerShell Module that contains core functions related to the image management solution.'

# HelpInfo URI of this module
HelpInfoUri = ''

# Version number of this module
ModuleVersion = '1.0.0.28'

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '5.0'

# Minimum version of the common language runtime (CLR) required by this module
CLRVersion = '2.0'

# Script module or binary module file associated with this manifest
ModuleToProcess = 'AzureRmImageManagementCoreHelper.psm1'

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
NestedModules = ''

FunctionsToExport = @(  'Start-AzureRmImgMgmtVhdCopy',
                        'Get-AzureRmImgMgmtAvailableAutomationAccount',
                        'Update-AzureRmImgMgmtAutomationAccountAvailabilityCount',
                        'New-AzureRmImgMgmtAutomationAccount',
                        'Get-AzureRmImgMgmtAuthToken',
                        'Get-AzureRmImgMgmtAuthHeader',
                        'Get-ConfigValue',
                        'Add-AzureRmRmImgMgmtJob',
                        'Add-AzureRmImgMgmtLog',
                        'Get-AzureRmImgMgmtLog',
                        'Get-AzureRmImgMgmtLogTable',
                        'Update-AzureRmImgMgmtLogJobId',
                        'Remove-AzureRmImgMgmtLogTemporaryJobIdEntry',
                        'Get-AzureRmImgMgmtStorageContext',
                        'Get-AzureRmImgMgmtTable',
                        'Get-AzureRmImgMgmtJob',
                        'Get-AzureRmImgMgmtJobStatus',
                        'Remove-AzureRmImgMgmtJobBlob',
                        'Get-AzureRmImgMgmtTier2StorageAccount',
                        'New-AzureRmImgMgmtTier2StorageAccount',
                        'Wait-AzureRmImgMgmtConfigPsJob',
                        'New-AzureRmImgMgmtRunAsAccount',
                        'New-AzureRmImgMgmtSelfSignedCertificate',
                        'New-AzureRmImgMgmtServicePrincipal',
                        'New-AzureRmImgMgmtAutomationCertificateAsset',
                        'New-AzureRmImgMgmtAutomationConnectionAsset')

VariablesToExport = ''


}