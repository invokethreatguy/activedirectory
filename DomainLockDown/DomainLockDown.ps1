<#
.SYNOPSIS
	This script evaluates your domain for vulnerabilities against the most common types of attacks.
	
.DESCRIPTION
	This script uses Group Policy to create a tightly controlled environment 
	for your Domain Controllers (DC) and your Domain Admins (DA). Both DCs and DAs 
	are high value targets for pentesters and hackers alike and, if compromised, basically 
	represent ownage of your domain/network. This script is designed to seriously 
	slow them down, allowing you more time to detect and mitigate internal threats against your AD environment.

	The following checks are performed against your domain:
		1) Check the strength of the password policy for your DAs.
		2) Check the number of Domain Admin (DA) accounts. You need a few (at least 2), but not too many (more than 10).
		3) Check to see where your DAs can login to. Recommend only the Domain Controllers to help mitigate PtH.
		4) Check to see if anyone other than DAs and Enterprise Admins (EAs) are in the builtin Administrators group.
		5) Check to see if enumeration via null sessions is available on your DCs.
		6) Check to see if domain credential caching is enabled.
	
	Specifying the -remediate switch will allow you to fix checks 1,3,5 & 6, and will also allow you to enable
	object level auditing against your DCs.
    
    The following prerequisites are required:
        1) This must be run on a Domain Controllers in the target domain.
        2) This must be run by a Domain Admin.
        3) So far, this has been tested on Windows Server 2008 R2.
        4) The ActiveDirectory and GroupPolicy modules from the RSAT must be installed.
        5) The script will attempt to save rsopdata.xml to $env:tmp. This path must be available for writing.
        
    Log information is saved to the script working directory.
		
.LINK
	- RSAT Download: http://www.microsoft.com/en-us/download/details.aspx?id=7887
	- Password Policy best practices: http://technet.microsoft.com/en-us/magazine/ff741764.aspx
	- Configuring a Password Policy: http://technet.microsoft.com/en-us/library/cc875814.aspx
	
.PARAMETER -evaluate
	The evaluate switch parameter will simply perform read only checks against your domain. Nothing is modified. The checks
    listed in the description are performed. 
    
.PARAMETER -remediate
    If specified, the remediate option will attempt to fix the vulnerabilities specified in checks 1,3,5 and 6 in the description.
    Note that you will be prompted for before fixing each check. For help specific to each fix, enter "?" when prompted. This will 
    tell you exactly what group policies are specified.
    
.PARAMETER -deathblossum
    Beyond the initial confirmation, all fixes are implemented without prompting. This is intended for a quick security
    baseline of a new domain. Use with caution!
    
.EXAMPLE
    ./DomainLockDown.ps1 -evaluate
	
	Runs only an evaluation of your domain's security controls (pertaining to DAs and DCs).
	No action is taken against the domain.
	
.EXAMPLE
    ./DomainLockDown.ps1 -remediate
	
	Implements remediation controls (listed in Description). You are prompted before each control
	is implemented.

.EXAMPLE
    ./DomainLockDown.ps1 -deathblossum
	
	Implements remediation controls. You are not prompted beyond an initial confirmation. 
	USE WITH CAUTION!
	
.EXAMPLE
	./DomainLockDown.ps1 -undo
	
	Removes any objects created by DomainLockDown from your domain. It is up to you
	to run gpupdate /force to immediately active those changes.
    
.NOTES
    Version: 1.0 
    LastModified: 02/03/2014
    For assistance, find me on Twitter: @curi0usJack
	
	Version History:
		02/03/2014	1.0		Initial Release
#>

Param (
	[Parameter(Position = 0)]
	[switch]
	$help,
	
	[Parameter(Position = 0)]
	[switch]
	$evaluate,
	
	[Parameter(Position = 0)]
	[switch]
	$remediate,
	
	[Parameter(Position = 0)]
	[switch]
	$deathblossum,
	
	[Parameter(Position = 0)]
	[switch]
	$undo
)

############### GLOBAL VARS ###############

# Script Title
$title = "DomainLockDown"

#Current User Name
$struser = $env:USERNAME

#Current Domain Name
$strdomain = $env:USERDOMAIN

#Temp Directory
$tmpdir = $env:TEMP

# Fully qualified host name
$hostname = $env:COMPUTERNAME

#Current Domain Object
$domain = $null

#Current User Object
$currentuser = $null

# XML based list of domain GPOs
[xml]$gpos = $null

# XML based RSOP data for both user & computer
[xml]$rsop = $null

# RSOP XML Path
$rsoppath = "$tmpdir\rsopdata.xml"

# Log File
#$log = "{0}\$title-{1}.txt" -f $MyInvocation.MyCommand.Path, (get-date -uformat “%Y%m%d%I%M%S”)
#Add-Type -AssemblyName "System.IO"
$logpath = "$pwd\$title-{1}.log" -f $MyInvocation.MyCommand.Path,(get-date -uformat “%Y%m%d%I%M%S”)
$log = [System.IO.StreamWriter] $logpath
$log.AutoFlush = "True"

# Set debug pref to "Continue" to see all debug messages, "SilentlyContinue" to supress them.
# $DebugPreference = "Continue"

Write-Debug "Log: $log"
Write-Debug "RsopPath: $rsoppath"
Write-Debug "Current User: $struser"
Write-Debug "Domain: $strdomain"
Write-Debug "Hostname: $hostname"
Write-Debug "Temp Dir: $tmpdir"

############### SUPPORTING FUNCTIONS ###############

# Load a module if it's available
Function Get-MyModule { 
	Param([string]$name) 
	if(-not(Get-Module -name $name)) 
	{ 
		if(Get-Module -ListAvailable | 
		Where-Object { $_.name -eq $name }) 
		{ 
			Import-Module -Name $name 
			$true 
		}  
		else { $false } 
		}	 
	else { $true }
}

# Write messages to console. Also appends to log.
Function Write-Message {
	Param(	[string] $message,
			[string] $type)
	switch ($type) {
		"error" {Write-Host "[!] - $message" -ForegroundColor Red}
		"warning" {Write-Host "[!] - $message" -ForegroundColor Yellow}
		"debug" {$Host.UI.WriteDebugLine($message)}
		"success" {Write-Host "[+] - $message" -ForegroundColor Green}
		"prereq" {Write-Host "[+] - PREREQ CHECK: $message" -ForegroundColor Cyan; $message = "PREREQ CHECK: $message"}
		default {Write-Host $message}
	}
	$log.WriteLine("{0} - {1}", (Get-Date -Format g), $message)
}

# Perform Prereq checks and load modules
Function DoPreReqs {
	# Load AD Module
	if ((Get-MyModule -name "ActiveDirectory") -eq $false) {
		Write-Message "ActiveDirectory module not available. Please load the Remote Server Administration Tools from Microsoft." "error"
		Quit
	} else {Write-Message "ActiveDirectory module successfully loaded." "prereq"}

	#Load GPO Module
	if ((Get-MyModule -name "GroupPolicy") -eq $false) {
		Write-Message "GroupPolicy module not available. Please load the Remote Server Administration Tools from Microsoft." "error"
		Quit
	} else {Write-Message "GroupPolicy module successfully loaded." "prereq"}

	# Check if machine is on a domain
	if ([string]::IsNullOrEmpty($env:USERDOMAIN)) {
		Write-Message "Bad news. Looks like this machine is not a member of a domain. Please run from a member server or workstation, or a domain controller" "error"
		Quit
	} else { Write-Message "Machine is member of $strdomain domain." "prereq" }

	$global:domain = Get-ADDomain $strdomain
	$global:currentuser = Get-ADUser $struser -Properties memberOf
	$global:hostname = [System.Net.Dns]::GetHostByName(($env:computerName)) | select -ExpandProperty HostName

	#Domain Admin Check
	if ($global:currentuser.MemberOf | Select-String "CN=Domain Admins") {
		Write-Message "Current user is a Domain Admin." "prereq"
	} else { 
		Write-Message "Bad news. The user running this script must be a Domain Admin. Exiting.." "error"
		Quit
	}
	
	#Domain Controller Check
	if ($global:domain.ReplicaDirectoryServers.Contains($global:hostname)) {
		Write-Message "$title is running on a DC" "prereq"
	} else {
		Write-Message "$title must be running on a DC." "error"
		Quit
	}
	
	# Export all gpo settings to xml
#	try {
#		$gpopath = "$env:TEMP/gpodata.xml"
#		Get-GPOReport -All -Path $gpopath -ReportType Xml
#		[xml]$global:gpos = gc $gpopath
#		Write-Message "Successfully exported GPOs from domain $strdomain" "prereq"
#	} catch [Exception] {
#		$err = $_.Exception.Message
#		Write-Message "Failed to export GPOs from domain $strdomain. Error: $err. Exiting..." "error"
#		Quit
#	}
	
	#Export RSOP data to xml
	try {
		Get-GPResultantSetOfPolicy -Path $rsoppath -ReportType Xml | Out-Null
		[xml]$global:rsop = gc $rsoppath
		Write-Message "Successfully exported RSOP data to $rsoppath." "prereq"
	} catch [Exception] {
		$err = $_.Exception.Message
		Write-Message "Failed to export RSOP data for current user/machine. Error: $err. Exiting..." "error"
		Quit
	}
}

Function OptionYesNo {
	Param ( [string] $title,
			[string] $description,
			[string] $yeshelp,
			[string] $nohelp)
			
	$yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", $yeshelp

	$no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", $nohelp

	$options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)

	$result = $host.ui.PromptForChoice($title, $description, $options, 0) 

	return $result
}

Function OptionNumber {
	Param ( [string] $title,
			[string] $description,
			[string] $defaulthelp )
			
	$default = New-Object System.Management.Automation.Host.ChoiceDescription "&12", $defaulthelp

	#$no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", $nohelp

	$options = [System.Management.Automation.Host.ChoiceDescription[]]($defaulthelp)

	$result = $host.ui.PromptForChoice($title, $description, $options, 0) 

	return $result
}

Function EvalDAs {
	#DA Password Reset Check
	Write-Host "`n`n"
	$sec = $global:rsop.Rsop.ComputerResults.ExtensionData | ?{$_.Name."#text" -eq "Security"} | select Extension
	$minpwdage = $sec.Extension.Account | ?{$_.Name -eq "MinimumPasswordAge"} | select -ExpandProperty SettingNumber
	$lockoutcount = $sec.Extension.Account | ?{$_.Name -eq "LockoutBadCount"} | select -ExpandProperty SettingNumber
	$minpwdlength = $sec.Extension.Account | ?{$_.Name -eq "MinimumPasswordLength"} | select -ExpandProperty SettingNumber
	$pwdcomplexity = $sec.Extension.Account | ?{$_.Name -eq "PasswordComplexity"} | select -ExpandProperty SettingBoolean
	$pwdhistory = $sec.Extension.Account | ?{$_.Name -eq "PasswordHistorySize"} | select -ExpandProperty SettingNumber
	
	$das = Get-ADGroupMember "Domain Admins" | Get-ADUser -Properties LogonWorkstations
	
	Write-Debug "Minimum Password Age: $minpwdage"
	Write-Debug "LockoutCount: $lockoutcount"
	Write-Debug "Minimum Password Length: $minpwdlength"
	Write-Debug "Complexity Enabled: $pwdcomplexity"
	Write-Debug "Password History Count: $pwdhistory"
	
	#Count DAs
	if ($das.Count -lt 2) { Write-Message "You have less than 2 DAs. What will the company do if something bad happens to you? Each domain needs at least 2 DAs (but not many more)." "warning" }
	elseif ($das.Count -gt 10) {Write-Message "You have more than 10 DAs. This most likely is due to insufficient delegated permissions. Consider delegating perms to some of your DAs, then removing their rights." "warning" }
	else {Write-Message "DA count looks good. Not too many, not too few." "success"}
	
	#Password History Check
	if ($pwdhistory -lt $lockoutcount) {Write-Message "The password history count ($pwdhistory) is less than the lockout threshold ($lockoutcount). This means an attacker has a greater chance of guessing your password without you knowing about it. Your lockout threshold should be higher than your minimum password age." "warning"}
	elseif ($pwdhistory -lt 10) {Write-Message "Your password history ($pwdhistory passwords remembered) is less than 10. This makes it easier for users to rotate though fewer passwords and is a greater security risk. Up this number to be on the safe side." "warning"}
	else {Write-Message "Your password history count ($pwdhistory passwords remembered) looks good for DAs." "success" }
	
	#Lockout Count Check
	if ($lockoutcount -eq 0) {Write-Message "The Lockout Count is set to 0. This means that accounts can never be locked out. no no NO!" "error"}
	elseif ($lockoutcount -gt 10) {Write-Message "The Lockout Count is set to $lockoutcount. Really? Tighten this up to somewhere between 3-8 to be on the safe side" "warning"}
	else {Write-Message "The Lockout Count is set to $lockoutcount. Looks good." "success" }
	
	#Password Complexity Check
	if ($pwdcomplexity -eq $true) {Write-Message "Password complexity is enabled." "success"}
	else {Write-Message "Password complexity is not enabled. Consider enabling it. This makes passwords harder to attack." "warning"}
	
	#Password Length Check
	if ($minpwdlength -lt 9) {Write-Message "Your minimum password length for DAs (Minimum $minpwdlength characters) is way too weak. Recommend a minimum of 12 characters." "error" }
	elseif ($minpwdlength -lt 11) {Write-Message "Your minimum password length for DAs (Minimum $minpwdlength characters) is better than most but not strong enough. Recommend a minimum of 12 characters." "warning" }
	else {Write-Message "Your minimum password length for DAs (Minimum $minpwdlength characters) is good." "success"}
	
	#Logon Workstation Check
	$baddalogon = @()
	$unuseddas = @()
	$dcsnetbios = $global:domain.ReplicaDirectoryServers | %{$_.Trim($global:domain.DNSRoot)}
	foreach ($da in $das) {
		if (!$da.LogonWorkstations) {$baddalogon += $da.samAccountName}
		elseif (compare $da.LogonWorkstations $dcsnetbios) { $baddalogon += $da.samAccountName }
	}
	
	if ($baddalogon) {
		$dacsv = $baddalogon -join ","
		Write-Message "The following DAs are allowed to logon to non-DCs: $dacsv. This finding is crucial as it allows attackers to pull DA password hashes from those machines. Best practice is to restrict DA logins to just DCs." "error" }
	else {Write-Message "DA logons are restricted to just DCs. Awesome!" "success"}
}

Function EvalDCs {
	# Check for null sessions
	# SMB Signing
	# Anon SID check?
	# DC Local Logon
	# Local Administrator check
	# Debug Users Priv Check
	$sec = $global:rsop.Rsop.ComputerResults.ExtensionData | ?{$_.Name."#text" -eq "Security"} | select Extension
	
	# Null Session Check
	if (-not (gc $rsoppath | Select-String "RestrictNullSessAccess")) {
		Write-Message "You are allowing null sessions to your DCs. This allows anonymous domain enumeration." "error"
	}
	else {
		$nullsess = $sec.Extension.SecurityOptions | ?{$_.KeyName -like "*RestrictNullSessAccess"} | select -ExpandProperty SettingNumber
		if ($nullsess -eq "1") {
			Write-Message "Null sessions are disabled. Awesome." "success"
		} else { Write-Message "You are *purposely* allowing null sessions to your DCs. If you have 'Security' in your job title, please escort yourself out now." "error" }
	}
	
	# Credential Caching Check
	
	# Anonymous SID Check
	if (-not (gc $rsoppath | Select-String "LSAAnonymousNameLookup")) {
		Write-Message "You are allowing anonymous SID name translation. This allows domain enumeration techniques like RID cycling." "warning"
	}
	else {
		$anonsid = $sec.Extension.SecurityOptions | ?{$_.KeyName -like "LSAAnonymousNameLookup"} | select -ExpandProperty SettingNumber
		if ($anonsid -eq "0") {
			Write-Message "Anonymous SID translation is disabled." "success"
		} else { Write-Message "You are purposely allowing anonymous SID translation. This allows domain enumeration techniques like RID cycling." "warning" }
	}
	
	# Local Administrator Check. Checks to see if there are non DA or EA accounts in the BuiltIn Administrators group.
	$badmins = @()
	foreach ($admin in Get-ADGroupMember "Administrators") {
		if (($admin.Name.Contains("Domain Admins") -eq $false) -and $admin.Name.Contains("Enterprise Admins") -eq $false) {
			if ($admin.SID.Value -notlike "*-500") {
				$admingroupscount = (Get-ADUser $admin.DistinguishedName -Properties memberOf | `
									select -ExpandProperty memberOf |`
									?{$_.Contains("Domain Admins") -or $_.Contains("Enterprise Admins")})
				if ($admingroupscount -eq $null){
					# The user is not a DA, EA, or the local Administrator account.
					$badmins += $admin.samAccountName
				}
			}
		}
	}
	
	if ($badmins.Count -gt 0) {
		$badminscsv = $badmins -join ","
		Write-Message "The following accounts are in the builtin Admins group and are not EAs, DAs, or the local admin account: $badminscsv. Be sure this is necessary!" "warning"
	} else { Write-Message "Builtin Administrator group member check: Passed" "success" }
}

Function GetDCGPO {
	$dcpath = $global:domain.DomainControllersContainer
	try {
		$dcgpo = Get-GPO -Name "$title-DCs" -ErrorAction Stop
		Write-Message "Found existing $title-DCs GPO..." "success"
	}
	catch [System.Exception] {
		$dcgpo = New-GPO "$title-DCs" -Comment "This GPO was created by the $title script. It restricts null session access to your DCs." | `
				New-GPLink -Target $dcpath
		Write-Message "Successfully created $title-DCs GPO and linked it to $dcpath. Continuing..." "success"
	}
	return $dcgpo
}

Function Remediate { Param ([bool]$confirm = $true)
	#Create Password Policy
	if ($confirm) {
		$createpwdpol = OptionYesNo "Do you want to create a password policy for your DAs?" "" "This will create a password policy object that will be applied directly and only to your Domain Admins group. This policy will take precedence over any other password policy applied to your DAs. The following settings will be applied:
				Minimum Password Length: 	12 characters
				Maximum Password Age:		30 Days
				Complexity Enabled: 		Yes
				Lockout Attempts:			5 Bad Attempts in 24 Hours.
				Lockout Duration:			Forever
				Password Remembered:		10
				Minimum Password Age:		3 Days
				" "Skip this option. No action will be taken."
	} else { $createpwdpol = 0 }
	if ($createpwdpol -eq 0) {
		$pwdpoltitle = "$title-DomainAdminsPasswordPolicy"
		New-ADFineGrainedPasswordPolicy `
			-Name $pwdpoltitle `
			-ComplexityEnabled $true `
			-Description " Domain Admins Password Policy" `
			-DisplayName "Domain Admins Password Policy" `
			-LockoutDuration "9999" `
			-LockoutObservationWindow "1.0:00:00" `
			-Precedence 1 `
			-LockoutThreshold 5 `
			-MaxPasswordAge "30.00:00:00" `
			-MinPasswordAge "0.00:30:00" `
			-MinPasswordLength 12 `
			-PasswordHistoryCount 10 `
			-ReversibleEncryptionEnabled $false
			
		Write-Message "Password policy object $pwdpoltitle created." "success"
		
		if ($confirm) {
			$apply = OptionYesNo "Do you want to apply this policy to your Domain Admins?" "" "Apply this policy." "Do not apply the poicy and delete the new passsword policy object."
		} else {$apply = 0}
		
		if ($apply -eq 0) {
			Add-ADFineGrainedPasswordPolicySubject $pwdpoltitle -Subjects 'Domain Admins'
			Write-Message "$pwdpoltitle object has been successfully applied to Domain Admins." "success"
		} else {
			Write-Message "Enter Y below to remove $pwdpoltitle from the domain." "warning"
			Remove-ADFineGrainedPasswordPolicy -Identity $pwdpoltitle
			Write-Message "$pwdpoltitle has been deleted. :-(" "success"
		}
	} else { Write-Message "Skipping step to create a DA password policy." }
		
	#Restring DA Logon Access
	if ($confirm) {
		$restrictlogon = OptionYesNo "Do you want to restrict your DAs to only be able to long to DCs (first timers: read the help on this one)?" "" "This will restrict all users in the Domain Admins group from logging on (in any way) to machines other than Domain Controllers. This is a huge win for security but could have negative ramifications on your environment if you have DA service accounts that need to login on other machines. You will be prompted to confirm the change for each DA." "Do nothing and skip this option"
	} else { $restrictlogon =  0}
	if ($restrictlogon -eq 0) {
		$das = Get-ADGroupMember "Domain Admins" | Get-ADUser -Properties LogonWorkstations
		$dcs = $global:domain.ReplicaDirectoryServers -join ","
		foreach ($da in $das) {
			$sam = $da.samAccountName
			if ($confirm) {Set-ADUser $da -LogonWorkstations $dcs -Confirm}
			else {Set-ADUser $da -LogonWorkstations $dcs}
			Write-Message "Successfully restricted logon access for DA: $sam" "success"
		}
	} else { Write-Message "Skipping step to restrict DA logon access." }
	
	#Restrict Null Sessions
	if ($confirm) {
		$restrictnullsessions = OptionYesNo "Do you want to restrict null sessions to your DCs?" "" "If it doesn't exist, a new GPO - $title-DCs - will be created and applied to your Domain Controllers OU. It will include the following settings:
			In Computer Configuration > Policies > Windows Settings > Security Settings > Security Options:
				Network access: Restrict anonymous access to Named Pipes and Shares - ENABLED
				Network access: Allow anonymous SID/name translation - DISABLED
				Network access: Do not allow anonymous enumeration of SAM accounts and shares - ENABLED`n
				Important to note that these settings will probably show up as 'Extra Registry Settings' under Admin Templates in the GPO.`n
				" "Skip this step. No action will be taken."
	} else { $restrictnullsessions = 0 }
	
	if ($restrictnullsessions -eq 0) {
		$dcgpo = GetDCGPO
		Set-GPRegistryValue -Name $dcgpo.DisplayName -Key "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\LanManServer\Parameters" -ValueName "RestrictNullSessAccess" -Type DWord -Value 1 | Out-Null
		Set-GPRegistryValue -Name $dcgpo.DisplayName -Key "HKLM\System\CurrentControlSet\Control\Lsa" -ValueName "RestrictAnonymousSAM" -Type DWord -Value 1 | Out-Null
		
		#Restrict Anonymous SID/Name Translation
		#
		# NOTE: This doesn't work because of a cosmetic bug in AD 2008/2012. When adding registry values that are known to
		# a valid ADM/ADMX file, they show up under Computer Settings > Administrative Templates > Extra Registry Settings instead of
		# in their normal locations in the GPO. There's no known way to work around this. The LSAAnonymousNameLookcup setting below
		# is not a known registry setting, but one that simply exists in the GptTmpl.inf file. This file doesn't get created when
		# the only settings that are applied are in "Extra Registry Settings", therefore there's no safe way to set the anonymous sid/name
		# translation setting safely in a production environment. Recommend doing it manually through the GUI. That said, if there
		# were a way to create the GptTmpl.inf file safely (though the addition of some other magical setting), the below code could
		# be uncommented and should work.
		#
		#$dcgpoguid = ($dcgpo.GpoId | select -ExpandProperty Guid).ToUpper()
		#$sysvoldir = (Get-ItemProperty -path HKLM:\system\currentcontrolset\services\netlogon\parameters -name "SysVol").SysVol
		#$sysvoldir = $sysvoldir.Substring(0,$sysvoldir.LastIndexOf('\'))
		#$gptmplfile = "$sysvoldir\domain\Policies\{$dcgpoguid}\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
		#Add-Content $gptmplfile -Value "[System Access]`nLSAAnonymousNameLookup = 0"
		
		Write-Message "Successfully applied null session restriction to $title-DCs GPO" "success"
	}
	
	#Restrict DC Credential Caching
	if ($confirm) {
		$restrictcredcache = OptionYesNo "Do you want to restrict caching of credentials on your DCs?" "" "If it doesn't exist, a new GPO - DomainLockDown-DCs - will be created and applied to your Domain Controllers OU. It will include the following settings:
			In Computer Configuration > Policies > Windows Settings > Security Settings > Security Options:
				Network access: Do not allow storage of passwords and credentials for network authentication - ENABLED
			" "Skip this step. No action will be taken."
	} else { $restrictcredcache = 0 }
	
	if ($restrictcredcache -eq 0) {
		$dcgpo = GetDCGPO
		Set-GPRegistryValue -Name $dcgpo.DisplayName -Key "HKLM\System\CurrentControlSet\Control\Lsa" -ValueName "DisableDomainCreds" -Type DWord -Value 1 | Out-Null
		Write-Message "Successfully applied credential cache restrictions to $title-DCs GPO" "success"
	}
	
#		#Backup Default DC Policy if it exists
#		if ($newgpo -eq $false) {
#			$dcgpobackuppath = "{0}\DCGPOBackup" -f [Environment]::CurrentDirectory
#			if ((Test-Path $dcgpobackuppath -PathType Container) -eq $false) { New-Item $dcgpobackuppath -ItemType Container }
#			Backup-GPO -Guid $dcgpo.Id -Path $dcgpobackuppath
#			Write-Message "Successfully backed up Default Domain Controllers Policy to $dcgpobackuppath" "success"
#		}
		
		#Change Settings
}

Function Undo {
	# Remove the password policy
	$pwdpoltitle = "$title-DomainAdminsPasswordPolicy"
	$Error.Clear()
	try {
		Remove-ADFineGrainedPasswordPolicy $pwdpoltitle -ErrorAction Stop
		Write-Message "$pwdpoltitle has been successfully deleted." "success"
	}
	catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		Write-Message "$pwdpoltitle not found. There is nothing to delete." "success"
	}
	catch [Exception] {
		Write-Message "An error occurred trying to delete $pwdpoltitle. Error: $error" "error"
		Write-Message "Note, to check if the password policy still exists, open ADUC. View > Advanced Features. Look in the root System folder > Password Settings Container for $pwdpoltitle. Right Click > Delete." "warning"
	}
	
	# Remove the custom GPO
	$Error.Clear()
	try {
		Remove-GPO "$title-DCs" -ErrorAction Stop
		Write-Message "$title-DCs GPO has been successfully deleted." "success"
	} 
	catch [ArgumentException] {
		# I know for a fact that the error being thrown if it can't find the GPO is a System.ArgumentException ($Error[0].Exception.GetType().FullName)
		# but for some reason it is never caught. Add to the known issues list. Powershell version bug?
		Write-Message "$title-DCs was not found in this domain. Nothing to delete." "success"
	}
	catch [Exception] {
		Write-Message "An error occurred trying to delete $title-DCs. Error: $error" "error"
		Write-Message "Note, to check if the GPO still exists, Start > Run > gpmc.msc. Expand Forest > Domains > $strdomain > Group Policy Objects. Look for $title-DCs. Right Click > Delete. Run gpupdate /force to effect the changes." "warning"
	}
	Write-Message "`nDone!`n"
}

function Quit {
	$log.Flush()
	$log.Dispose()
	exit
}

############### MAIN SCRIPT ###############

if (!$help -and !$evaluate -and !$remediate -and !$deathblossum -and !$undo) {
	Write-Host "You must pass a switch to $title. Use Get-Help $title.ps1 for assistance."
	$log.Dispose()
	Remove-Item $logpath
	exit
}

if ($help) {
	Write-Host "Use get-help $title.ps1 instead."
	Quit
}

DoPreReqs

if ($undo) {
	Undo
	Quit
}

if ($evaluate) {
	EvalDAs
	EvalDCs
	
	Write-Host "`n"
	Write-Host "If you see any " -NoNewline 
	Write-Host "yellow" -ForegroundColor Yellow -NoNewline
	Write-Host " or " -NoNewline 
	Write-Host "red" -ForegroundColor Red -NoNewline
	Write-Host ", you should consider running the script with the -remediate option.`n"
	Write-Message "Done!`n"
	Quit
}

if ($remediate) {
	Remediate
}

if ($deathblossum) {
	Write-Host "`nYou selected the death blossum option. No confirmations beyond this one will be given. YOUR DOMAIN WILL BE MODIFIED! A safer option is to run with the -remediate switch which will prompt you for each change. If you have not read the help, please exit the script and do so now. You have been warned."
	$confirm = Read-Host "`nType YES if you wish to continue"
	if ($confirm -ceq "YES") {
		Write-Host "`n"
		Write-Message "Running script in deathblossum mode. Good luck!`n" "warning"
		Remediate $false
	} else {
		Write-Host "`nGoodbye.`n"
		Quit
	}
}

if ($remediate -or $deathblossum) {
	Write-Message "`nNote that any changes will not take effect until the next group policy refresh. Run `gpupdate /force` to force the update."
	Write-Message "Done!`n"
}




	



					

