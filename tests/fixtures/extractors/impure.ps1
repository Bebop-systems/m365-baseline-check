param($Response)
$null = Invoke-RestMethod -Uri 'https://example.com/'
[System.IO.File]::ReadAllText('x')
& $Response
return $true
