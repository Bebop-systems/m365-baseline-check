# Read-only by construction (invariant 1). The checks parse src/ with PowerShell's own parser, so they see
# every command call however it is written: through an alias, a quoted name, -Method:POST or an
# abbreviated -Meth. Each rule is also run against deliberately bad code, to show it catches what it claims.

BeforeAll {
    $script:Src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    $script:Files = @(Get-ChildItem -LiteralPath $script:Src -Recurse -Filter '*.ps1' -File)
    # Invoke-MgGraphRequest and every alias Microsoft.Graph.Authentication exports for it.
    $script:GraphCommands = @('Invoke-MgGraphRequest', 'Invoke-GraphRequest', 'Invoke-MgRestMethod')
    $script:WriteMethods = @('POST', 'PUT', 'PATCH', 'DELETE', 'MERGE')
    $script:InvokeMembers = @('Invoke', 'InvokeReturnAsIs', 'InvokeWithContext', 'InvokeScript', 'NewScriptBlock')
    $L = 'System.Management.Automation.Language'

    function script:Get-Ast([string] $Text) { [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null) }
    function script:Get-Commands($Ast) { @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) }

    # The arguments given to parameters that PowerShell would bind to -Method: any prefix of it, either form.
    function script:Get-MethodArguments($Command) {
        $elements = $Command.CommandElements
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $e = $elements[$i]
            if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if (-not 'method'.StartsWith($e.ParameterName.ToLowerInvariant())) { continue }
            if ($e.Argument) { $e.Argument }
            elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] }
            else { $null }
        }
    }

    # Every way a piece of code breaks the Graph rules, as text; nothing means it keeps them.
    function script:Find-GraphViolations([string] $Text, [string] $AllowedFunction) {
        $ast = Get-Ast $Text
        foreach ($c in (Get-Commands $ast)) {
            $name = $c.GetCommandName()
            if (-not $name -or $name -notin $script:GraphCommands) { continue }
            $fn = $c.Parent
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
            if (-not $fn -or $fn.Name -ne $AllowedFunction) { "graph call outside ${AllowedFunction}: $($c.Extent.Text)" }
            if (@($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }).Count) { "splatted graph call: $($c.Extent.Text)" }
            $methods = @(Get-MethodArguments $c)
            if ($methods.Count -ne 1) { "graph call without exactly one -Method: $($c.Extent.Text)" }
            foreach ($m in $methods) {
                if ($m -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $m.Value -cne 'GET') { "graph call whose method isn't a literal GET: $($c.Extent.Text)" }
            }
        }
    }

    function script:Find-WriteMethods([string] $Text) {
        foreach ($c in (Get-Commands (Get-Ast $Text))) {
            foreach ($m in @(Get-MethodArguments $c)) {
                $value = if ($m -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $m.Value } else { $m.Extent.Text.Trim("'", '"') }
                if ($value -in $script:WriteMethods) { "write method: $($c.Extent.Text)" }
            }
        }
    }

    # Calls whose target is computed: & ('Invoke-' + 'X'), & "$name", . (Get-Command x), and .Invoke().
    function script:Find-ComputedCalls([string] $Text) {
        $ast = Get-Ast $Text
        foreach ($c in (Get-Commands $ast)) {
            $first = $c.CommandElements[0]
            $plain = $first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                ($c.InvocationOperator -eq 'Unknown' -or $first.StringConstantType -eq 'BareWord' -or $first.StringConstantType -eq 'SingleQuoted' -or $first.StringConstantType -eq 'DoubleQuoted')
            $variable = $first -is [System.Management.Automation.Language.VariableExpressionAst]
            if (-not ($plain -or $variable)) { "computed call: $($c.Extent.Text)" }
        }
        foreach ($m in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $m.Member.Value -in $script:InvokeMembers) { "invoke member: $($m.Extent.Text)" }
        }
    }

    $script:Texts = foreach ($f in $script:Files) { [pscustomobject]@{ Name = $f.Name; Text = [System.IO.File]::ReadAllText($f.FullName) } }
    $script:Ok = "function Invoke-MbcGraphTransport { param(`$Uri) Invoke-MgGraphRequest -Method GET -Uri `$Uri }"
}

Describe 'Read-only by construction (invariant 1)' {
    It 'calls Graph once, from the transport, with a literal GET and nothing splatted' {
        @(foreach ($t in $script:Texts) { Find-GraphViolations $t.Text 'Invoke-MbcGraphTransport' }) | Should -BeNullOrEmpty
        $calls = @(foreach ($t in $script:Texts) { Get-Commands (Get-Ast $t.Text) | Where-Object { $_.GetCommandName() -in $script:GraphCommands } | ForEach-Object { $t.Name } })
        $calls | Should -Be @('Graph.ps1')
    }

    It 'never names the Graph request command, or an alias of it, anywhere but that call' {
        $mentions = @(foreach ($t in $script:Texts) { foreach ($n in $script:GraphCommands) {
                    $at = 0
                    while (($at = $t.Text.IndexOf($n, $at, [StringComparison]::OrdinalIgnoreCase)) -ge 0) { "$($t.Name): $n"; $at += $n.Length }
                } })
        $mentions | Should -Be @('Graph.ps1: Invoke-MgGraphRequest')
    }

    It 'never gives any command a write method, in any parameter form' {
        @(foreach ($t in $script:Texts) { Find-WriteMethods $t.Text }) | Should -BeNullOrEmpty
    }

    It 'never calls a command by a computed name, or through .Invoke()' {
        @(foreach ($t in $script:Texts) { Find-ComputedCalls $t.Text | ForEach-Object { "$($t.Name): $_" } }) | Should -BeNullOrEmpty
    }

    It 'runs a command held in a variable with splatted arguments in exactly one place: the guarded runner' {
        $calls = @(foreach ($t in $script:Texts) {
                foreach ($c in (Get-Commands (Get-Ast $t.Text))) {
                    if ($c.InvocationOperator -eq 'Unknown' -or $c.CommandElements[0] -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                    if (@($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }).Count) { "$($t.Name): $($c.Extent.Text)" }
                }
            })
        $calls | Should -Be @('Cmdlet.ps1: & $Command @Parameters -ErrorAction Stop 3>$null')
    }

    It 'never uses another HTTP client' {
        foreach ($c in 'Invoke-RestMethod', 'Invoke-WebRequest', 'HttpClient', 'WebClient', 'HttpWebRequest', 'WebRequest]::Create', 'Net.Sockets') {
            @($script:Texts | Where-Object { $_.Text.IndexOf($c, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object Name) | Should -BeNullOrEmpty -Because "$c must not appear"
        }
    }

    It 'knows every alias of the Graph request command, where the module is installed' {
        $module = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) { Set-ItResult -Skipped -Because 'Microsoft.Graph.Authentication is not installed here'; return }
        $aliases = @($module.ExportedAliases.Values | Where-Object { $_.ResolvedCommandName -eq 'Invoke-MgGraphRequest' -or $_.Definition -eq 'Invoke-MgGraphRequest' } | ForEach-Object Name)
        foreach ($a in $aliases) { $script:GraphCommands | Should -Contain $a }
    }
}

Describe 'The read-only checks catch what they claim' {
    It 'accepts the one allowed call' {
        Find-GraphViolations $script:Ok 'Invoke-MbcGraphTransport' | Should -BeNullOrEmpty
        Find-ComputedCalls $script:Ok | Should -BeNullOrEmpty
    }
    It 'catches a Graph call through an alias, a quoted name, or outside the transport' {
        Find-GraphViolations 'function Invoke-MbcGraphTransport { Invoke-GraphRequest -Method GET -Uri $u }' 'X' | Should -Not -BeNullOrEmpty
        Find-GraphViolations 'function Other { Invoke-MgRestMethod -Method GET -Uri $u }' 'Invoke-MbcGraphTransport' | Should -BeLike '*outside*'
        Find-GraphViolations "function Other { & 'Invoke-MgGraphRequest' -Method GET -Uri `$u }" 'Invoke-MbcGraphTransport' | Should -BeLike '*outside*'
    }
    It 'catches a method that is not a literal GET, in every parameter form' {
        foreach ($m in '-Method POST', '-Method:POST', '-Meth PATCH', '-M DELETE', '-Method $verb', '-Method ("G" + "ET")', '-Method "$verb"') {
            $code = "function Invoke-MbcGraphTransport { Invoke-MgGraphRequest $m -Uri `$u }"
            Find-GraphViolations $code 'Invoke-MbcGraphTransport' | Should -Not -BeNullOrEmpty -Because $m
        }
        Find-GraphViolations 'function Invoke-MbcGraphTransport { Invoke-MgGraphRequest -Uri $u }' 'Invoke-MbcGraphTransport' | Should -BeLike '*exactly one -Method*'
        Find-GraphViolations 'function Invoke-MbcGraphTransport { Invoke-MgGraphRequest -Method GET -Method POST -Uri $u }' 'Invoke-MbcGraphTransport' | Should -Not -BeNullOrEmpty
    }
    It 'catches splatting that could carry a method into the Graph call' {
        Find-GraphViolations 'function Invoke-MbcGraphTransport { Invoke-MgGraphRequest -Method GET @more }' 'Invoke-MbcGraphTransport' | Should -BeLike '*splatted*'
    }
    It 'catches a write method given to any command' {
        foreach ($m in "-Method:'DELETE'", '-Meth PUT', '-Method POST') { Find-WriteMethods "Some-Command $m" | Should -Not -BeNullOrEmpty -Because $m }
    }
    It 'catches a call by computed name, and .Invoke()' {
        foreach ($code in "& ('Invoke-' + 'MgGraphRequest') -Method POST", '& "Invoke-$x" -Method POST', '. (Get-Command Invoke-MgGraphRequest)', '$c.Invoke()', '$ExecutionContext.InvokeCommand.InvokeScript("x")') {
            Find-ComputedCalls $code | Should -Not -BeNullOrEmpty -Because $code
        }
    }
}
