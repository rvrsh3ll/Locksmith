﻿function Find-ESC4 {
    <#
    .SYNOPSIS
        This script finds AD CS (Active Directory Certificate Services) objects that have the ESC4 vulnerability.

    .DESCRIPTION
        The script takes an array of ADCS objects as input and filters them based on the specified conditions.
        For each matching object, it creates a custom object with properties representing various information about
        the object, such as Forest, Name, DistinguishedName, IdentityReference, ActiveDirectoryRights, Issue, Fix, Revert, and Technique.

    .PARAMETER ADCSObjects
        Specifies the array of ADCS objects to be processed. This parameter is mandatory.

    .PARAMETER DangerousRights
        Specifies the list of dangerous rights that should not be assigned to users. This parameter is mandatory.

    .PARAMETER SafeUsers
        Specifies the list of SIDs of safe users who are allowed to have specific rights on the objects. This parameter is mandatory.

    .PARAMETER SafeObjectTypes
        Specifies a list of ObjectTypes which are not a security concern. This parameter is mandatory.

    .OUTPUTS
        The script outputs an array of custom objects representing the matching ADCS objects and their associated information.

    .EXAMPLE
        $ADCSObjects = Get-ADCSObject -Targets (Get-Target)

        # GenericAll, WriteDacl, and WriteOwner all permit full control of an AD object.
        # WriteProperty may or may not permit full control depending the specific property and AD object type.
        $DangerousRights = @('GenericAll', 'WriteProperty', 'WriteOwner', 'WriteDacl')

        # -512$ = Domain Admins group
        # -519$ = Enterprise Admins group
        # -544$ = Administrators group
        # -18$  = SYSTEM
        # -517$ = Cert Publishers
        # -500$ = Built-in Administrator
        $SafeOwners = '-512$|-519$|-544$|-18$|-517$|-500$'

        # -512$    = Domain Admins group
        # -519$    = Enterprise Admins group
        # -544$    = Administrators group
        # -18$     = SYSTEM
        # -517$    = Cert Publishers
        # -500$    = Built-in Administrator
        # -516$    = Domain Controllers
        # -521$    = Read-Only Domain Controllers
        # -9$      = Enterprise Domain Controllers
        # -526$    = Key Admins
        # -527$    = Enterprise Key Admins
        # S-1-5-10 = SELF
        $SafeUsers = '-512$|-519$|-544$|-18$|-517$|-500$|-516$|-521$|-498$|-9$|-526$|-527$|S-1-5-10'

        # The well-known GUIDs for Enroll and AutoEnroll rights on AD CS templates.
        $SafeObjectTypes = '0e10c968-78fb-11d2-90d4-00c04f79dc55|a05b8cc2-17bc-4802-a710-e7c15ab866a2'

        # Set output mode
        $Mode = 1

        $Results = Find-ESC4 -ADCSObjects $ADCSObjects -DangerousRights $DangerousRights -SafeOwners $SafeOwners -SafeUsers $SafeUsers -SafeObjectTypes $SafeObjectTypes -Mode $Mode
        $Results
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Microsoft.ActiveDirectory.Management.ADEntity[]]$ADCSObjects,
        [Parameter(Mandatory)]
        [string]$DangerousRights,
        [Parameter(Mandatory)]
        [string]$SafeOwners,
        [Parameter(Mandatory)]
        [string]$SafeUsers,
        [Parameter(Mandatory)]
        [string]$SafeObjectTypes,
        [Parameter(Mandatory)]
        [int]$Mode,
        [Parameter(Mandatory)]
        [string]$UnsafeUsers,
        [switch]$SkipRisk
    )
    $ADCSObjects | Where-Object objectClass -eq 'pKICertificateTemplate' | ForEach-Object {
        if ($_.Name -ne '' -and $null -ne $_.Name) {
            $Principal = [System.Security.Principal.NTAccount]::New($_.nTSecurityDescriptor.Owner)
            if ($Principal -match '^(S-1|O:)') {
                $SID = $Principal
            } else {
                $SID = ($Principal.Translate([System.Security.Principal.SecurityIdentifier])).Value
            }
        }

        if ($SID -notmatch $SafeOwners) {
            $Issue = [pscustomobject]@{
                Forest                = $_.CanonicalName.split('/')[0]
                Name                  = $_.Name
                DistinguishedName     = $_.DistinguishedName
                IdentityReference     = $_.nTSecurityDescriptor.Owner
                IdentityReferenceSID  = $SID
                ActiveDirectoryRights = 'Owner'
                Enabled               = $_.Enabled
                EnabledOn             = $_.EnabledOn
                Issue                 = @"
$($_.nTSecurityDescriptor.Owner) has Owner rights on this template and can
modify it into a template that can create ESC1, ESC2, and ESC3 templates.

More info:
  - https://posts.specterops.io/certified-pre-owned-d95910965cd2

"@
                Fix                   = @"
`$Owner = New-Object System.Security.Principal.SecurityIdentifier('$PreferredOwner')
`$ACL = Get-Acl -Path 'AD:$($_.DistinguishedName)'
`$ACL.SetOwner(`$Owner)
Set-ACL -Path 'AD:$($_.DistinguishedName)' -AclObject `$ACL
"@
                Revert                = @"
`$Owner = New-Object System.Security.Principal.SecurityIdentifier('$($_.nTSecurityDescriptor.Owner)')
`$ACL = Get-Acl -Path 'AD:$($_.DistinguishedName)'
`$ACL.SetOwner(`$Owner)
Set-ACL -Path 'AD:$($_.DistinguishedName)' -AclObject `$ACL
"@
                Technique             = 'ESC4'
            }
            if ($SkipRisk -eq $false) {
                Set-RiskRating -ADCSObjects $ADCSObjects -Issue $Issue -SafeUsers $SafeUsers -UnsafeUsers $UnsafeUsers
            }
            $Issue
        }

        foreach ($entry in $_.nTSecurityDescriptor.Access) {
            if ($_.Name -ne '' -and $null -ne $_.Name) {
                $Principal = New-Object System.Security.Principal.NTAccount($entry.IdentityReference)
                if ($Principal -match '^(S-1|O:)') {
                    $SID = $Principal
                } else {
                    $SID = ($Principal.Translate([System.Security.Principal.SecurityIdentifier])).Value
                }
            }

            if ( ($SID -notmatch $SafeUsers) -and
                ($entry.AccessControlType -eq 'Allow') -and
                ($entry.ActiveDirectoryRights -match $DangerousRights) -and
                ($entry.ObjectType -notmatch $SafeObjectTypes)
            ) {
                $Issue = [pscustomobject]@{
                    Forest                = $_.CanonicalName.split('/')[0]
                    Name                  = $_.Name
                    DistinguishedName     = $_.DistinguishedName
                    IdentityReference     = $entry.IdentityReference
                    IdentityReferenceSID  = $SID
                    ActiveDirectoryRights = $entry.ActiveDirectoryRights
                    Enabled               = $_.Enabled
                    EnabledOn             = $_.EnabledOn
                    Issue                 = @"
$($entry.IdentityReference) has been granted $($entry.ActiveDirectoryRights) rights on this template.

$($entry.IdentityReference) can likely modify this template into an ESC1 template.

More info:
  - https://posts.specterops.io/certified-pre-owned-d95910965cd2

"@
                    Fix                   = @"
`$ACL = Get-Acl -Path 'AD:$($_.DistinguishedName)'
foreach ( `$ace in `$ACL.access ) {
    if ( (`$ace.IdentityReference.Value -like '$($Principal.Value)' ) -and ( `$ace.ActiveDirectoryRights -notmatch '^ExtendedRight$') ) {
        `$ACL.RemoveAccessRule(`$ace) | Out-Null
    }
}
Set-Acl -Path 'AD:$($_.DistinguishedName)' -AclObject `$ACL
"@
                    Revert                = '[TODO]'
                    Technique             = 'ESC4'
                }

                if ( $Mode -in @(1, 3, 4) ) {
                    Update-ESC4Remediation -Issue $Issue
                }
                if ($SkipRisk -eq $false) {
                    Set-RiskRating -ADCSObjects $ADCSObjects -Issue $Issue -SafeUsers $SafeUsers -UnsafeUsers $UnsafeUsers
                }
                $Issue
            }
        }
    }
}
