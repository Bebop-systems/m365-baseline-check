param($Response)
# True when any enabled policy in the response blocks access for everyone.
$blocking = @($Response['value'] | Where-Object {
        $gc = $_['grantControls']
        $_['state'] -eq 'enabled' -and $gc -and (@($gc['builtInControls']) -contains 'block')
    })
return ($blocking.Count -gt 0)
