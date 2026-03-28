<#
.SYNOPSIS
    Manages Microsoft 365 self-service group creation policies using the Microsoft Graph PowerShell SDK.

.DESCRIPTION
    This script connects to Microsoft Graph and allows administrators to:
      - Retrieve current tenant-level M365 group settings (e.g., EnableGroupCreation, GroupCreationAllowedGroupId)
      - Create or update the Group.Unified directory setting to restrict or scope self-service group creation

    This is useful when rolling out the updated My Groups (myaccount.microsoft.com/groups) experience
    and you want to ensure group creation policies are correctly configured before end users interact
    with the new interface.

.PARAMETER EnableGroupCreation
    Set to 'true' to allow all users to create M365 groups, or 'false' to restrict creation.
    Defaults to 'false' (restricted).

.PARAMETER GroupCreationAllowedGroupId
    The Object ID of the security group whose members are allowed to create M365 groups.
    Only applies when EnableGroupCreation is 'false'. Leave empty to block all non-admin creation.

.PARAMETER ViewOnly
    If specified, the script only reads and displays current group settings without making changes.

.EXAMPLE
    # View current group settings without making changes
    .\Set-M365GroupCreationPolicy.ps1 -ViewOnly

.EXAMPLE
    # Restrict group creation to members of a specific security group
    .\Set-M365GroupCreationPolicy.ps1 -EnableGroupCreation 'false' -GroupCreationAllowedGroupId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    # Disable self-service group creation for all users
    .\Set-M365GroupCreationPolicy.ps1 -EnableGroupCreation 'false' -GroupCreationAllowedGroupId ''

.NOTES
    Prerequisites:
      - Microsoft Graph PowerShell SDK installed: Install-Module Microsoft.Graph -Scope CurrentUser
      - Caller must have Global Administrator or Groups Administrator role
      - Required Graph scopes: Directory.ReadWrite.All

    References:
      - https://learn.microsoft.com/en-us/microsoft-365/admin/create-groups/manage-creation-of-groups
      - Message Center: MC1262589
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Set to true or false to control group creation.')]
    [ValidateSet('true', 'false')]
    [string]$EnableGroupCreation = 'false',

    [Parameter(Mandatory = $false, HelpMessage = 'Object ID of the security group allowed to create M365 groups. Leave empty to block all.')]
    [string]$GroupCreationAllowedGroupId = '',

    [Parameter(Mandatory = $false, HelpMessage = 'If specified, only read and display current settings without making changes.')]
    [switch]$ViewOnly
)

#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement

# -----------------------------------------------
# STEP 1: Connect to Microsoft Graph
# -----------------------------------------------
Write-Host '[INFO] Connecting to Microsoft Graph...' -ForegroundColor Cyan

try {
    if ($ViewOnly) {
        Connect-MgGraph -Scopes 'Directory.Read.All' -ErrorAction Stop
    } else {
        Connect-MgGraph -Scopes 'Directory.ReadWrite.All' -ErrorAction Stop
    }
    Write-Host '[INFO] Successfully connected to Microsoft Graph.' -ForegroundColor Green
} catch {
    Write-Error "[ERROR] Failed to connect to Microsoft Graph: $_"
    exit 1
}

# -----------------------------------------------
# STEP 2: Retrieve and Display Current Group Settings
# -----------------------------------------------
Write-Host '[INFO] Retrieving current tenant-level group settings...' -ForegroundColor Cyan

try {
    $existingSettings = Get-MgGroupSetting -ErrorAction Stop
} catch {
    Write-Error "[ERROR] Failed to retrieve group settings: $_"
    Disconnect-MgGraph | Out-Null
    exit 1
}

if ($existingSettings) {
    Write-Host '[INFO] Current Group Settings:' -ForegroundColor Yellow
    foreach ($setting in $existingSettings) {
        Write-Host "  Setting ID : $($setting.Id)"
        Write-Host "  Template ID: $($setting.TemplateId)"
        foreach ($val in $setting.Values) {
            Write-Host "    $($val.Name) = $($val.Value)"
        }
        Write-Host ''
    }
} else {
    Write-Host '[INFO] No tenant-level group settings found. A new Group.Unified setting will be created if changes are requested.' -ForegroundColor Yellow
}

# Exit early if ViewOnly switch is set
if ($ViewOnly) {
    Write-Host '[INFO] ViewOnly mode — no changes made.' -ForegroundColor Cyan
    Disconnect-MgGraph | Out-Null
    exit 0
}

# -----------------------------------------------
# STEP 3: Retrieve the Group.Unified Setting Template ID
# -----------------------------------------------
Write-Host '[INFO] Retrieving Group.Unified directory setting template...' -ForegroundColor Cyan

try {
    $template = Get-MgDirectorySettingTemplate | Where-Object { $_.DisplayName -eq 'Group.Unified' }
} catch {
    Write-Error "[ERROR] Failed to retrieve directory setting templates: $_"
    Disconnect-MgGraph | Out-Null
    exit 1
}

if (-not $template) {
    Write-Error '[ERROR] Could not find the Group.Unified setting template. Ensure you have the correct permissions.'
    Disconnect-MgGraph | Out-Null
    exit 1
}

$templateId = $template.Id
Write-Host "[INFO] Found Group.Unified Template ID: $templateId" -ForegroundColor Green

# -----------------------------------------------
# STEP 4: Build the Settings Parameter Object
# -----------------------------------------------
$settingValues = @(
    @{ name = 'EnableGroupCreation';         value = $EnableGroupCreation },
    @{ name = 'GroupCreationAllowedGroupId'; value = $GroupCreationAllowedGroupId }
)

$params = @{
    templateId = $templateId
    values     = $settingValues
}

Write-Host '[INFO] Settings to apply:' -ForegroundColor Yellow
Write-Host "  EnableGroupCreation         = $EnableGroupCreation"
Write-Host "  GroupCreationAllowedGroupId = $(if ($GroupCreationAllowedGroupId) { $GroupCreationAllowedGroupId } else { '(empty — all non-admins blocked)' })"
Write-Host ''

# -----------------------------------------------
# STEP 5: Create or Update the Group.Unified Setting
# -----------------------------------------------
$unifiedSetting = $existingSettings | Where-Object { $_.TemplateId -eq $templateId }

if ($unifiedSetting) {
    # Update existing setting
    Write-Host '[INFO] Updating existing Group.Unified setting...' -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess('Group.Unified tenant setting', 'Update')) {
        try {
            Update-MgGroupSetting -GroupSettingId $unifiedSetting.Id -BodyParameter $params -ErrorAction Stop
            Write-Host '[SUCCESS] Group.Unified setting updated successfully.' -ForegroundColor Green
        } catch {
            Write-Error "[ERROR] Failed to update Group.Unified setting: $_"
            Disconnect-MgGraph | Out-Null
            exit 1
        }
    }
} else {
    # Create new setting
    Write-Host '[INFO] No existing Group.Unified setting found. Creating a new one...' -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess('Group.Unified tenant setting', 'Create')) {
        try {
            New-MgGroupSetting -BodyParameter $params -ErrorAction Stop
            Write-Host '[SUCCESS] Group.Unified setting created successfully.' -ForegroundColor Green
        } catch {
            Write-Error "[ERROR] Failed to create Group.Unified setting: $_"
            Disconnect-MgGraph | Out-Null
            exit 1
        }
    }
}

# -----------------------------------------------
# STEP 6: Verify Applied Settings
# -----------------------------------------------
Write-Host '[INFO] Verifying applied settings...' -ForegroundColor Cyan

try {
    $verifiedSettings = Get-MgGroupSetting -ErrorAction Stop
    $verifiedUnified  = $verifiedSettings | Where-Object { $_.TemplateId -eq $templateId }

    if ($verifiedUnified) {
        Write-Host '[INFO] Verified Group.Unified Settings:' -ForegroundColor Yellow
        foreach ($val in $verifiedUnified.Values) {
            Write-Host "  $($val.Name) = $($val.Value)"
        }
    }
} catch {
    Write-Warning "[WARN] Could not verify settings after applying: $_"
}

# -----------------------------------------------
# STEP 7: Disconnect
# -----------------------------------------------
Write-Host '[INFO] Disconnecting from Microsoft Graph.' -ForegroundColor Cyan
Disconnect-MgGraph | Out-Null
Write-Host '[DONE] Script completed.' -ForegroundColor Green
