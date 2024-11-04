# Import variables from .env file
Get-Content ..\.env | foreach {
    if ($_ -match '^[^#\n\s]') {
        $name, $value = $_.split('=')
        Set-Variable $name $value
    }
}