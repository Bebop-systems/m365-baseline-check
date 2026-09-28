# Read-only by construction (invariant 1). The checks parse src/ with PowerShell's own parser: an alias,
# a quoted name, -Method:POST or an abbreviated -Meth all look the same to them. The routes to a command
# that a parser can't follow (looking it up at run time, aliases, module prefixes, default parameter
# values, other HTTP clients) are confined to named functions or banned outright. These checks catch
# mistakes and make a deliberate way round them conspicuous in a diff; they aren't a proof against a
# hostile contributor, which only review is. A variable is called as a command only when it is provably a
# script block or a command object, so a command name can't arrive from data. Each rule is also run
# against deliberately bad code. The root module is scanned with src/; its loader's dot-source is the one
# allowed.

BeforeAll {
    $script:Src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    $script:Files = @(Get-ChildItem -LiteralPath $script:Src -Recurse -Filter '*.ps1' -File) + @(Get-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'M365BaselineCheck.psm1'))
    $script:LoaderDotSource = 'M365BaselineCheck.psm1: dot-sourcing: . $file.FullName'
    # PowerShell's built-in aliases, so gcm is seen as Get-Command and sal as Set-Alias.
    $script:AliasOf = @{}
    foreach ($a in (Get-Alias -ErrorAction SilentlyContinue)) { $script:AliasOf[$a.Name] = [string]$a.Definition }
    # Invoke-MgGraphRequest and every alias Microsoft.Graph.Authentication exports for it.
    $script:GraphCommands = @('Invoke-MgGraphRequest', 'Invoke-GraphRequest', 'Invoke-MgRestMethod')
    $script:WriteMethods = @('POST', 'PUT', 'PATCH', 'DELETE', 'MERGE')
    $script:InvokeMembers = @('Invoke', 'InvokeReturnAsIs', 'InvokeWithContext', 'InvokeScript', 'NewScriptBlock')
    # Commands that reach other commands, and the only functions allowed to call them.
    $script:Confined = [ordered]@{
        'Invoke-MbcCmdletRunner'    = @('Invoke-MbcCmdletGet')
        'Resolve-MbcSessionCommand' = @('Invoke-MbcCmdletGet')
        'Get-Command'               = @('Resolve-MbcSessionCommand', 'Get-MbcExchangeConnections', 'Invoke-MbcDisconnectAll')
        'Import-Module'             = @('Import-MbcSourceModule')
        'Set-Alias'                 = @()
        'New-Alias'                 = @()
        # Writes to a variable by name, which the callable proof below can't see.
        'Set-Variable'              = @()
        'New-Variable'              = @()
        'Tee-Object'                = @()
    }
    # Text that means reaching a command, or the network, by a route the parser can't follow.
    $script:Indirection = @(
        'InvokeCommand', 'GetScriptBlock', 'Parser]::Parse', 'PSDefaultParameterValues', 'Get-Variable',
        'Alias:', 'Function:', 'ExportedCmdlets', 'ExportedCommands', 'ExportedFunctions', 'CmdletInfo', 'GraphRequestMethod',
        'Net.Http', 'SocketsHttpHandler', 'HttpMessage', 'TcpClient', 'Net.Sockets'
    )

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

    function script:Get-EnclosingFunction($Node) {
        $fn = $Node.Parent
        while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
        if ($fn) { $fn.Name } else { '' }
    }

    # Calls whose target is computed (& ('Invoke-' + 'X'), & "$name", . (Get-Command x)), dot-sourcing,
    # .Invoke(), and a command held in a variable given a write method, even by position.
    function script:Find-ComputedCalls([string] $Text) {
        $ast = Get-Ast $Text
        foreach ($c in (Get-Commands $ast)) {
            $first = $c.CommandElements[0]
            if ($c.InvocationOperator -eq 'Dot') { "dot-sourcing: $($c.Extent.Text)"; continue }
            $plain = $first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $first.StringConstantType -ne 'DoubleQuoted'
            $block = $first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
            $variable = $first -is [System.Management.Automation.Language.VariableExpressionAst]
            if (-not ($plain -or $block -or $variable)) { "computed call: $($c.Extent.Text)"; continue }
            if ($variable) {
                foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                    if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $e.Value -in $script:WriteMethods) { "write verb given to a command in a variable: $($c.Extent.Text)" }
                }
                # Any -Method at all: its value can be computed, or a number (DELETE is 4 in Graph's enum).
                if (@(Get-MethodArguments $c).Count) { "-Method given to a command in a variable: $($c.Extent.Text)" }
                # The runner's own parameters: a variable holding its name would reach it from anywhere.
                foreach ($e in @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })) {
                    $p = $e.ParameterName.ToLowerInvariant()
                    if ($p.Length -ge 3 -and ('command'.StartsWith($p) -or 'parameters'.StartsWith($p))) { "runner parameter given to a command in a variable: $($c.Extent.Text)" }
                }
            }
        }
        foreach ($m in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $m.Member.Value -in $script:InvokeMembers) { "invoke member: $($m.Extent.Text)" }
        }
    }

    # Commands that reach other commands, called from anywhere but their allowed functions, or in a way
    # that widens them: Get-Command by verb, noun or wildcard; Import-Module with a prefix.
    function script:Find-Unconfined([string] $Text) {
        foreach ($c in (Get-Commands (Get-Ast $Text))) {
            $name = $c.GetCommandName()
            if (-not $name) { continue }
            # Microsoft.PowerShell.Core\Get-Command is Get-Command; so is gcm.
            $name = $name.Substring($name.LastIndexOf('\') + 1)
            if ($script:AliasOf.ContainsKey($name)) { $name = $script:AliasOf[$name] }
            $key = @($script:Confined.Keys | Where-Object { $_ -ieq $name })
            if ($key.Count -eq 0) { continue }
            $in = Get-EnclosingFunction $c
            if ($in -notin $script:Confined[$key[0]]) { "$name called from '$in': $($c.Extent.Text)" }
            $params = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName.ToLowerInvariant() })
            if ($key[0] -eq 'Get-Command') {
                if (@($params | Where-Object { 'verb'.StartsWith($_) -or 'noun'.StartsWith($_) }).Count) { "Get-Command by verb or noun: $($c.Extent.Text)" }
                foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                    if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and ($e.Value.Contains('*') -or $e.Value.Contains('?'))) { "Get-Command with a wildcard: $($c.Extent.Text)" }
                }
            }
            if ($key[0] -eq 'Import-Module' -and @($params | Where-Object { $_.Length -ge 2 -and 'prefix'.StartsWith($_) }).Count) { "Import-Module with a prefix: $($c.Extent.Text)" }
        }
    }

    # Every variable called as a command must be provably a script block or a CommandInfo, never a name.
    # PowerShell's scoping decides what "provably" takes:
    # - a parameter counts only in the call's own function or an enclosing script block, and must be
    #   typed [scriptblock] or [CommandInfo]; an untyped one there fails;
    # - every assignment to the name anywhere in the function is checked, since a child scope makes a new,
    #   untyped variable and a script block can run in the caller's scope. It must be a { } literal, a
    #   [scriptblock] cast (PowerShell refuses a string), another proven variable, or sit in the same
    #   scope as a typed parameter of that name, which converts it;
    # - any other write fails: [ref], multiple assignment, a foreach variable, -OutVariable and the like.
    $script:TypedCallable = @('scriptblock', 'System.Management.Automation.ScriptBlock', 'CommandInfo', 'System.Management.Automation.CommandInfo')

    function script:Get-NearestScriptBlock($Node) {
        $n = $Node.Parent
        while ($n -and $n -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $n = $n.Parent }
        $n
    }

    function script:Test-ProvenCallable($Site, [string] $Name, [int] $Depth = 0) {
        if ($Depth -gt 5) { return $false }
        $root = $Site.Parent
        while ($root -and $root -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $root = $root.Parent }
        if (-not $root) { $root = $Site; while ($root.Parent) { $root = $root.Parent } }
        $isName = { param($v) $v -is [System.Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.UserPath -ieq $Name }

        # Parameters of the call's own function and enclosing script blocks; that chain is also where an
        # assignment has to be for the variable to exist at the call. One made only in a child or sibling
        # block leaves the call reading whatever its caller had (dynamic scope).
        $typedScopes = [System.Collections.Generic.List[object]]::new()
        $chain = [System.Collections.Generic.List[object]]::new()
        $sb = Get-NearestScriptBlock $Site
        while ($sb) {
            $chain.Add($sb)
            $params = @()
            if ($sb.ParamBlock) { $params += @($sb.ParamBlock.Parameters) }
            if ($sb.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $sb.Parent.Parameters) { $params += @($sb.Parent.Parameters) }
            foreach ($p in $params) {
                if (-not (& $isName $p.Name)) { continue }
                $types = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | ForEach-Object { $_.TypeName.FullName })
                if (@($types | Where-Object { $_ -in $script:TypedCallable }).Count -eq 0) { return $false }
                $typedScopes.Add($sb)
            }
            if ($sb.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
            $sb = Get-NearestScriptBlock $sb
        }

        $writes = 0
        foreach ($a in $root.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $left = $a.Left
            if ($left -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                if (@($left.Elements | Where-Object { (& $isName $_) -or ($_ -is [System.Management.Automation.Language.ConvertExpressionAst] -and (& $isName $_.Child)) }).Count) { return $false }
                continue
            }
            $cast = $null
            if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $cast = $left.Type.TypeName.FullName; $left = $left.Child }
            if (-not (& $isName $left)) { continue }
            if ($chain.Contains((Get-NearestScriptBlock $a))) { $writes++ }
            if ($cast -in $script:TypedCallable) { continue }
            if ($typedScopes.Contains((Get-NearestScriptBlock $a))) { continue }
            $right = $a.Right
            if ($right -is [System.Management.Automation.Language.PipelineAst] -and $right.PipelineElements.Count -eq 1) { $right = $right.PipelineElements[0] }
            $expr = if ($right -is [System.Management.Automation.Language.CommandExpressionAst]) { $right.Expression } else { $null }
            if ($expr -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            if ($expr -is [System.Management.Automation.Language.VariableExpressionAst] -and (Test-ProvenCallable $a $expr.VariablePath.UserPath ($Depth + 1))) { continue }
            return $false
        }
        # [ref]$name, a foreach loop variable, and -OutVariable name (or any -*Variable) are writes too.
        foreach ($r in $root.FindAll({ $args[0] -is [System.Management.Automation.Language.ConvertExpressionAst] -and $args[0].Type.TypeName.Name -ieq 'ref' }, $true)) {
            if (& $isName $r.Child) { return $false }
        }
        foreach ($f in $root.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            if (& $isName $f.Variable) { return $false }
        }
        foreach ($c in $root.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $elements = $c.CommandElements
            for ($i = 1; $i -lt $elements.Count; $i++) {
                $e = $elements[$i]
                if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $pn = $e.ParameterName.ToLowerInvariant()
                if (-not ($pn.EndsWith('variable') -or $pn -in 'ov', 'pv', 'ev', 'wv', 'iv')) { continue }
                $arg = if ($e.Argument) { $e.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
                if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $arg.Value.TrimStart('+') -ieq $Name) { return $false }
            }
        }
        return ($typedScopes.Count -gt 0 -or $writes -gt 0)
    }

    function script:Find-UnprovenCallables([string] $Text) {
        foreach ($c in (Get-Commands (Get-Ast $Text))) {
            $first = $c.CommandElements[0]
            if ($c.InvocationOperator -eq 'Dot' -or $first -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $name = $first.VariablePath.UserPath
            if (-not (Test-ProvenCallable $c $name)) { "`$$name may hold a command name, not a script block: $($c.Extent.Text)" }
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

    It 'never calls a command by a computed name, or through .Invoke(); dot-sources only in the loader' {
        @(foreach ($t in $script:Texts) { Find-ComputedCalls $t.Text | ForEach-Object { "$($t.Name): $_" } }) | Should -Be @($script:LoaderDotSource)
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

    It 'calls a variable only when it is provably a script block or a command object, never a name' {
        @(foreach ($t in $script:Texts) { Find-UnprovenCallables $t.Text | ForEach-Object { "$($t.Name): $_" } }) | Should -BeNullOrEmpty
    }

    It 'keeps the commands that reach other commands inside their named functions' {
        @(foreach ($t in $script:Texts) { Find-Unconfined $t.Text | ForEach-Object { "$($t.Name): $_" } }) | Should -BeNullOrEmpty
    }

    It 'uses no route to a command or the network that the parser cannot follow' {
        foreach ($c in $script:Indirection) {
            @($script:Texts | Where-Object { $_.Text.IndexOf($c, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object Name) | Should -BeNullOrEmpty -Because "$c must not appear"
        }
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
    It 'catches a call by computed name, dot-sourcing, .Invoke(), and a write verb given to a command in a variable' {
        foreach ($code in "& ('Invoke-' + 'MgGraphRequest') -Method POST", '& "Invoke-$x" -Method POST', '. (Get-Command Invoke-MgGraphRequest)', '. $path', '$c.Invoke()',
            '$ExecutionContext.InvokeCommand.InvokeScript("x")', '& $c DELETE $u', '& $c -Uri $u PATCH', '& $n -Method $v -Uri $u', '& $n -Method 4 -Uri $u', '& $n -Meth:$m', '& $r -Command $c -Parameters @{ Method = ''DELETE'' }', '& $r -Comm $c') {
            Find-ComputedCalls $code | Should -Not -BeNullOrEmpty -Because $code
        }
        Find-ComputedCalls '& { param($x) $x } 1; & $say ''done''' | Should -BeNullOrEmpty -Because 'a script block or a variable called with ordinary arguments is fine'
    }
    It 'catches the runtime routes to a command: the runner or Get-Command outside their functions, aliases, prefixes' {
        foreach ($code in @(
                'function Other { Invoke-MbcCmdletRunner -Command $c -Parameters @{ Method = ''DELETE'' } }',
                'function Other { Resolve-MbcSessionCommand -Name x -Module y }',
                'function Other { Get-Command Get-Thing }',
                'function Resolve-MbcSessionCommand { Get-Command -Verb Invoke -Noun MgGraphRequest }',
                'function Resolve-MbcSessionCommand { Get-Command -Name ''Invoke-MgGraph*'' }',
                'function Import-MbcSourceModule { Import-Module Microsoft.Graph.Authentication -Prefix Zz }',
                'function Other { Import-Module x }',
                'function Other { Set-Alias mbcx ("Invoke-MgGraph" + "Request") }',
                'function Other { New-Alias mbcx x }',
                'function Other { gcm -Verb Invoke -Noun MgGraphRequest }',
                'function Other { Microsoft.PowerShell.Core\Get-Command Get-Thing }',
                'function Import-MbcSourceModule { ipmo Microsoft.Graph.Authentication -Prefix Zz }',
                'function Other { sal mbcx x }'
            )) { Find-Unconfined $code | Should -Not -BeNullOrEmpty -Because $code }
        Find-Unconfined 'function Resolve-MbcSessionCommand { Get-Command -Name $Name -Module $Module -CommandType Function, Cmdlet }' | Should -BeNullOrEmpty
    }
    It 'catches a variable called as a command when it could hold a name, and accepts proven script blocks' {
        foreach ($code in @(
                'function Format-MbcD1 { param($Item) $formatter = $Item.Formatter; & $formatter $Item.Style $Item.Target }',
                'function F { param([string] $Handler) & $Handler x }',
                'function F { param($Handler) & $Handler x }',
                'function F { $n = "Invoke-MgGraph" + "Request"; & $n DELETE $u }',
                'function F { $r = { 1 }; $r = $State.Hook; & $r }',
                'function F { & $undefined }',
                'function F { $a = $b; & $a }',
                'function F { param($Item) $handler = { }; [void]$Handlers.TryGetValue($Item.Kind, [ref]$handler); & $handler $Item.Style $Item.Target }',
                'function F { param([scriptblock] $OnTick, $Item) $each = { param($row) $OnTick = $row.Hook; & $OnTick $row.Style $row.Target }; & $each $Item }',
                'function F { param($Item) $g = { param([scriptblock] $fmt) & $fmt }; $fmt = $Item.Formatter; & $fmt $Item.Style }',
                'function F { param($Item) $fmt, $v = $Item.Formatter, 1; & $fmt $v }',
                'function F { param($Item) $reset = { $fmt = $Item.F }; $fmt = { }; & $reset; & $fmt }',
                'function F { foreach ($s in $Item.Steps) { & $s } }',
                'function F { $h = { }; Get-Thing -OutVariable h; & $h }',
                'function F { $h = { }; Get-Thing -ov +h; & $h }',
                'function Format-MbcE8 { param($Style, $Target) $reset = { $fmt = { } }; & $fmt $Style $Target }'
            )) { Find-UnprovenCallables $code | Should -Not -BeNullOrEmpty -Because $code }
        foreach ($code in @(
                'function F { param($Item) Set-Variable -Name fmt -Value $Item.F }',
                'function F { param($Item) sv fmt $Item.F }',
                'function F { param($Item) New-Variable fmt $Item.F }',
                'function F { Get-Thing | Tee-Object -Variable h }'
            )) { Find-Unconfined $code | Should -Not -BeNullOrEmpty -Because $code }
        foreach ($code in @(
                'function F { param([scriptblock] $OnTick) & $OnTick }',
                'function F { param([System.Management.Automation.CommandInfo] $Command) & $Command @p }',
                'function F { $say = { param($t) $t }; & $say hi }',
                'function F { param([scriptblock] $OnResult) $streamTo = $OnResult; & $streamTo 1 }',
                'function F { [scriptblock]$seam = $State.Seams.Fetch; & $seam 1 }',
                'function F { $add = { 1 }; $add = { 2 }; & $add }',
                'function F { param([scriptblock] $Fetch) if (-not $Fetch) { $Fetch = { 1 } }; & $Fetch }',
                'function F { param([scriptblock] $Fetch) $Fetch = $State.Other; & $Fetch }',
                'function F { $say = { param($t) $t }; $each = { param($x) & $say $x }; & $each 1 }'
            )) { Find-UnprovenCallables $code | Should -BeNullOrEmpty -Because $code }
    }
    It 'names the text routes it bans' {
        foreach ($code in @(
                '$ExecutionContext.InvokeCommand.GetCommand("x", "Cmdlet")',
                '[System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$null).GetScriptBlock()',
                '$PSDefaultParameterValues["Invoke-MgG*:Method"] = "DELETE"',
                '[System.Net.Http.HttpMessageInvoker]::new([System.Net.Http.SocketsHttpHandler]::new())',
                'Set-Item Alias:mbcx -Value x',
                '(Get-Module Microsoft.Graph.Authentication).ExportedCmdlets["Invoke-MgGraphRequest"]',
                '[System.Management.Automation.CmdletInfo]::new("Get-Thing", [object])',
                'Get-Variable PSDefault* -ValueOnly',
                '-Method ([Microsoft.Graph.PowerShell.Authentication.Models.GraphRequestMethod]::DELETE)'
            )) { @($script:Indirection | Where-Object { $code.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count | Should -BeGreaterThan 0 -Because $code }
    }
}
