$User = "amercer"

# 1. Apply attribute updates
Set-ADUser -Identity $User -Title "Intelligence Analyst" -Department "Cybersecurity"

# 2. Query and display updated object properties with timestamp
Get-ADUser -Identity $User -Properties Title, Department, whenChanged | 
    Select-Object Name, UserPrincipalName, Title, Department, whenChanged | 
    Format-List