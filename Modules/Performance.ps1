<#
COMPARTDISK 1.3.1 - Performance.ps1
Desenvolvido por Edsilas

Acoes:
Analyze | Ultimate | Balanced | Startup | Processes | Services

Objetivo:
Diagnostico e gerenciamento de desempenho do Windows.
Nao realiza overclock nem altera parametros de hardware.
#>

[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Ultimate', 'Balanced', 'Startup', 'Processes', 'Services')]
    [string]$Action = 'Analyze',

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Dependencias
# ---------------------------------------------------------------------------

$corePath = Join-Path $PSScriptRoot 'Core.ps1'

if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Dependencia critica nao encontrada: Arquivo Core.ps1 ausente em $PSScriptRoot."
}

. $corePath

# ---------------------------------------------------------------------------
# Estado
# ---------------------------------------------------------------------------

$script:result = 'OK'
$script:PowerSchemeCache = $null

# ---------------------------------------------------------------------------
# PowerCfg
# ---------------------------------------------------------------------------

$powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'

if (-not (Test-Path -LiteralPath $powercfg -PathType Leaf)) {
    throw "Dependencia critica nao encontrada: powercfg.exe ausente em $powercfg."
}

# GUIDs oficiais dos esquemas de energia do Windows
$GUID_ULTIMATE = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$GUID_BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'
$GUID_HIGH     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

# ---------------------------------------------------------------------------
# Funcoes auxiliares
# ---------------------------------------------------------------------------

function Clear-PowerSchemeCache {
    [CmdletBinding()]
    param()

    $script:PowerSchemeCache = $null
}

function Get-PowerSchemes {
    [CmdletBinding()]
    param(
        [switch]$Refresh
    )

    if ($script:PowerSchemeCache -and -not $Refresh) {
        return @($script:PowerSchemeCache)
    }

    $r = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/list') `
        -TimeoutSeconds 30

    $texto = @(
        $r.StdOut
        $r.StdErr
    ) -join "`n"

    if ($r.ExitCode -ne 0) {
        throw "powercfg /list falhou com codigo $($r.ExitCode). $($r.StdErr)"
    }

    if ([string]::IsNullOrWhiteSpace($texto)) {
        throw 'powercfg /list nao retornou nenhum esquema de energia.'
    }

    $guidRegex = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    $schemes = @(
        foreach ($linha in ($texto -split "`r?`n")) {
            $mGuid = [regex]::Match($linha, $guidRegex)

            if (-not $mGuid.Success) {
                continue
            }

            $guid = $mGuid.Value.ToLowerInvariant()
            $name = $null

            if ($linha -match '\(([^()]*)\)\s*$') {
                $name = $Matches[1].Trim()
            }

            [pscustomobject]@{
                Guid = $guid
                Name = $name
            }
        }
    )

    if ($schemes.Count -eq 0) {
        throw 'powercfg /list retornou uma resposta sem GUIDs de esquemas de energia.'
    }

    $script:PowerSchemeCache = @($schemes)
    return @($script:PowerSchemeCache)
}

function Get-PowerSchemeGuids {
    [CmdletBinding()]
    param()

    return @(
        Get-PowerSchemes |
            ForEach-Object { $_.Guid } |
            Select-Object -Unique
    )
}

function Test-PowerSchemeExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Guid
    )

    $normalizedGuid = $Guid.ToLowerInvariant()
    return [bool](
        Get-PowerSchemes |
            Where-Object { $_.Guid -eq $normalizedGuid } |
            Select-Object -First 1
    )
}

function Get-PowerSchemeByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $scheme = Get-PowerSchemes |
        Where-Object { $_.Name -and $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($scheme) {
        return $scheme.Guid
    }

    return $null
}

function Get-InteractiveUserName {
    [CmdletBinding()]
    param()

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop

        if ($computer.UserName) {
            return [string]$computer.UserName
        }
    }
    catch {
        Write-Log WARN "Nao foi possivel identificar o usuario interativo: $($_.Exception.Message)"
    }

    return $null
}

function Test-CurrentUserIsInteractive {
    [CmdletBinding()]
    param()

    try {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $interactiveUser = Get-InteractiveUserName

        if ([string]::IsNullOrWhiteSpace($interactiveUser)) {
            return $false
        }

        return ($currentUser -eq $interactiveUser)
    }
    catch {
        Write-Log WARN "Nao foi possivel validar o contexto do usuario: $($_.Exception.Message)"
        return $false
    }
}

function Set-PerformanceVisualEffects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$PerformanceMode
    )

    # HKCU representa o usuario do contexto atual.
    # Se o modulo estiver sendo executado como SYSTEM ou por outro usuario,
    # nao altera a configuracao visual de uma conta diferente da interativa.
    if (-not (Test-CurrentUserIsInteractive)) {
        Write-Log WARN 'Efeitos visuais nao alterados: o contexto atual nao corresponde ao usuario interativo.'
        return $false
    }

    $valor = if ($PerformanceMode) { 2 } else { 0 }

    $mensagem = if ($PerformanceMode) {
        'Efeitos visuais ajustados para melhor desempenho.'
    }
    else {
        'Efeitos visuais restaurados ao controle automatico do Windows.'
    }

    try {
        if (
            Set-CompartDiskRegistryValue `
                -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
                -Name 'VisualFXSetting' `
                -Value $valor `
                -Type DWord
        ) {
            Write-Log OK $mensagem
            return $true
        }

        Write-Log WARN 'Nao foi possivel alterar os efeitos visuais.'
        return $false
    }
    catch {
        Write-Log WARN "Falha ao alterar efeitos visuais: $($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------
# Analise
# ---------------------------------------------------------------------------

function Show-Analysis {
    [CmdletBinding()]
    param()

    # -----------------------------------------------------------------------
    # Energia
    # -----------------------------------------------------------------------

    $energia = Get-CompartDiskPowerInfo

    Write-Color ''
    Write-Color '  ENERGIA' -Color White

    foreach ($k in $energia.Keys) {
        Write-CompartDiskKeyValue $k $energia[$k] -Pad 24
    }

    Add-CompartDiskSection `
        -Title 'Energia' `
        -Status INFO `
        -Pairs $energia

    # -----------------------------------------------------------------------
    # Processos
    # -----------------------------------------------------------------------

    $proc = Get-CompartDiskProcessDiagnostics -Top 12

    Write-Color ''
    Write-Color '  MAIORES CONSUMIDORES DE MEMORIA' -Color White

    $proc |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        Write-Output

    Add-CompartDiskSection `
        -Title 'Processos (top memoria)' `
        -Status INFO `
        -Rows $proc

    # -----------------------------------------------------------------------
    # CPU
    # -----------------------------------------------------------------------

    $cpu = 'n/d'

    try {
        $c = Get-CompartDiskCim `
            -Class Win32_PerfFormattedData_PerfOS_Processor `
            -Filter "Name='_Total'"

        if ($c) {
            $cpu = "$($c.PercentProcessorTime)%"
        }
    }
    catch {
        $script:result = 'WARN'
        Write-Log WARN "Falha ao consultar uso de CPU via CIM: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # Hardware / Memoria
    # -----------------------------------------------------------------------

    $hw = Get-CompartDiskHardwareInfo

    $pares = [ordered]@{
        'CPU (instantaneo)' = $cpu
        'RAM total'         = $hw['RAM total']
        'RAM disponivel'    = $hw['RAM disponivel']
        'RAM em uso (%)'    = $hw['RAM em uso (%)']
        'Processos ativos'  = 'n/d'
    }

    try {
        $pares['Processos ativos'] = @(Get-Process -ErrorAction Stop).Count
    }
    catch {
        $script:result = 'WARN'
        Write-Log WARN "Falha ao consultar processos ativos: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # Arquivo de paginacao
    # -----------------------------------------------------------------------

    try {
        $pf = @(Get-CompartDiskCim -Class Win32_PageFileUsage)

        if ($pf.Count -gt 0) {
            $usoAtual = ($pf | Measure-Object -Property CurrentUsage -Sum).Sum
            $tamanho  = ($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum

            $pares['Arquivo de paginacao'] = "$usoAtual MB de $tamanho MB"
        }
    }
    catch {
        $script:result = 'WARN'
        Write-Log WARN "Falha ao consultar Win32_PageFileUsage: $($_.Exception.Message)"
    }

    Write-Color ''

    foreach ($k in $pares.Keys) {
        Write-CompartDiskKeyValue $k $pares[$k] -Pad 24
    }

    Add-CompartDiskSection `
        -Title 'Carga do sistema' `
        -Status INFO `
        -Pairs $pares

    # -----------------------------------------------------------------------
    # Inicializacao
    # -----------------------------------------------------------------------

    $startup = @(Get-CompartDiskStartupItems)

    if ($startup.Count -gt 0) {

        Write-Color ''
        Write-Color (
            "  ITENS DE INICIALIZACAO: {0}" -f $startup.Count
        ) -Color White

        $startup |
            Select-Object Nome, Local, Usuario |
            Format-Table -AutoSize |
            Out-String -Width 200 |
            Write-Output

        $statusStartup = if ($startup.Count -gt 12) {
            'WARN'
        }
        else {
            'OK'
        }

        Add-CompartDiskSection `
            -Title 'Itens de inicializacao' `
            -Status $statusStartup `
            -Rows $startup `
            -Summary "$($startup.Count) item(ns)"

        if ($startup.Count -gt 12) {
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message "$($startup.Count) programas configurados para iniciar com o Windows." `
                -Recommendation 'Revisar em Gerenciador de Tarefas > Aplicativos de inicializacao.'

            $script:result = 'WARN'
        }
    }
    else {
        Add-CompartDiskSection `
            -Title 'Itens de inicializacao' `
            -Status INFO `
            -Rows @() `
            -Summary 'Nenhum item identificado.'
    }

    # -----------------------------------------------------------------------
    # Servicos
    # -----------------------------------------------------------------------

    $svc = @(Get-CompartDiskServiceDiagnostics)

    $problemas = @(
        $svc |
        Where-Object {
            $_.Diagnostico -ne 'OK'
        }
    )

    $statusServicos = if ($problemas.Count -gt 0) {
        'WARN'
    }
    else {
        'OK'
    }

    if ($problemas.Count -gt 0) {

        Write-Color ''
        $problemas |
            Format-Table -AutoSize |
            Out-String -Width 200 |
            Write-Output

        Add-CompartDiskSection `
            -Title 'Servicos essenciais com desvio' `
            -Status WARN `
            -Rows $problemas

        foreach ($p in $problemas) {
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Servicos' `
                -Message "Servico '$($p.Servico)' esta $($p.Estado) (inicio: $($p.Inicio))." `
                -Recommendation 'Restaurar o tipo de inicializacao padrao e iniciar o servico.'
        }

        $script:result = 'WARN'
    }
    else {
        Add-CompartDiskFinding `
            -Severity OK `
            -Area 'Servicos' `
            -Message 'Todos os servicos essenciais operando normalmente.'
    }

    Add-CompartDiskSection `
        -Title 'Servicos essenciais' `
        -Status $statusServicos `
        -Rows $svc

    Write-Log OK 'Analise de desempenho concluida.'
}

# ---------------------------------------------------------------------------
# Gerenciamento de planos de energia
# ---------------------------------------------------------------------------

function Set-PowerSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubGroup,

        [Parameter(Mandatory)]
        [string]$Setting,

        [Parameter(Mandatory)]
        [int]$Value,

        [Parameter(Mandatory)]
        [string]$Description,

        [switch]$Required
    )

    try {
        $r = Invoke-NativeCommand `
            -FilePath $powercfg `
            -Arguments @('/setacvalueindex', $SchemeGuid, $SubGroup, $Setting, $Value) `
            -TimeoutSeconds 30

        if ($r.ExitCode -ne 0) {
            if ($Required) {
                Write-Log ERR "Falha ao configurar '$Description' (codigo $($r.ExitCode))."
                return $false
            }

            Write-Log WARN "Configuracao '$Description' nao foi aplicada neste dispositivo (codigo $($r.ExitCode))."
            return $false
        }

        Write-Log OK "Configuracao aplicada: $Description = $Value"
        return $true
    }
    catch {
        if ($Required) {
            Write-Log ERR "Falha ao configurar '$Description': $($_.Exception.Message)"
            return $false
        }

        Write-Log WARN "Configuracao '$Description' indisponivel neste dispositivo: $($_.Exception.Message)"
        return $false
    }
}

function Get-PowerSettingCurrentAcValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubGroup,

        [Parameter(Mandatory)]
        [string]$Setting
    )

    # Preferimos a fonte estruturada do Windows (registro de PowerSchemes),
    # pois ela nao depende do idioma nem do formato textual do powercfg /query.
    # O fallback para /query preserva compatibilidade caso a chave nao esteja
    # disponivel no ambiente.
    $settingGuids = @{
        PROCTHROTTLEMIN = '893dee8e-2bef-41e0-89c6-b55d0929964c'
        PROCTHROTTLEMAX = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
        SYSCOOLPOL      = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
        ASPM            = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
        DISKIDLE        = '6738e2c4-e8a5-4a42-b16a-e040e769756e'
        STANDBYIDLE     = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
        HIBERNATEIDLE   = '9d7815a6-7ee4-497e-8888-515a05f02364'
    }

    $subGroupGuids = @{
        SUB_PROCESSOR  = '54533251-82be-4824-96c1-47b60b740d00'
        SUB_PCIEXPRESS = '501a4d13-42af-4429-9fd1-a8218c268e20'
        SUB_DISK       = '0012ee47-9041-4b5d-9b77-535fba8b1442'
        SUB_SLEEP      = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    }

    $normalizedScheme = $SchemeGuid.ToLowerInvariant()
    $settingGuid = $null
    $subGroupGuid = $null

    if ($settingGuids.ContainsKey($Setting)) {
        $settingGuid = $settingGuids[$Setting]
    }

    if ($subGroupGuids.ContainsKey($SubGroup)) {
        $subGroupGuid = $subGroupGuids[$SubGroup]
    }

    if ($settingGuid -and $subGroupGuid) {
        $registryPath = Join-Path `
            'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' `
            "$normalizedScheme\$($subGroupGuid.ToLowerInvariant())\$($settingGuid.ToLowerInvariant())"

        try {
            $property = Get-ItemProperty -LiteralPath $registryPath -Name 'ACSettingIndex' -ErrorAction Stop

            if ($null -ne $property.ACSettingIndex) {
                $raw = $property.ACSettingIndex

                if ($raw -is [byte[]]) {
                    if ($raw.Length -lt 4) {
                        throw "ACSettingIndex de '$Setting' possui tamanho invalido."
                    }

                    $bytes = $raw[0..3]
                    $value = [BitConverter]::ToInt32($bytes, 0)
                }
                else {
                    $value = [Convert]::ToInt64([string]$raw, 10)
                }

                Write-Verbose "Valor AC de '$Setting' obtido do registro: $value."
                return $value
            }
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            # Chave ausente: usar fallback /query.
        }
        catch [System.Management.Automation.PSArgumentException] {
            # Valor ausente/incompativel: usar fallback /query.
        }
        catch {
            Write-Verbose "Registro indisponivel para '$Setting': $($_.Exception.Message)"
        }
    }

    $r = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/query', $SchemeGuid, $SubGroup) `
        -TimeoutSeconds 30

    $texto = @(
        $r.StdOut
        $r.StdErr
    ) -join "`n"

    if ($r.ExitCode -ne 0) {
        $detalhe = if ($r.StdErr) { $r.StdErr.Trim() } else { 'sem mensagem de erro' }
        throw "powercfg /query falhou com codigo $($r.ExitCode): $detalhe"
    }

    if ([string]::IsNullOrWhiteSpace($texto)) {
        throw "powercfg /query retornou uma resposta vazia para '$Setting'."
    }

    # /query pode retornar todo o subgrupo. Primeiro isolamos o bloco da
    # configuracao pelo GUID conhecido; isso evita confundir os indices de
    # outra configuracao com o valor solicitado.
    $settingGuidPattern = [regex]::Escape($settingGuid)
    $blockPattern = '(?is)Power Setting GUID:\s*\{?' + $settingGuidPattern + '\}?\b.*?(?=\r?\n\s*Power Setting GUID:|\r?\n\s*Subgroup GUID:|\z)'
    $blockMatch = [regex]::Match($texto, $blockPattern)

    $bloco = if ($blockMatch.Success) { $blockMatch.Value } else { $texto }

    # O formato textual oficial mostra Current AC/DC como valores hexadecimais.
    # O regex aceita espacos/formatacao intermediaria e permanece independente
    # dos nomes localizados das configuracoes.
    $acPatterns = @(
        '(?im)Current\s+AC\s+Power\s+Setting\s+Index\s*:\s*0x([0-9a-f]+)',
        '(?im)AC\s+Power\s+Setting\s+Index\s*:\s*0x([0-9a-f]+)'
    )

    foreach ($pattern in $acPatterns) {
        $match = [regex]::Match($bloco, $pattern)

        if ($match.Success) {
            try {
                return [Convert]::ToInt64($match.Groups[1].Value, 16)
            }
            catch {
                throw "Indice AC de '$Setting' possui formato invalido: $($match.Groups[1].Value)."
            }
        }
    }

    # Ultimo fallback: em um bloco especifico de configuracao, os dois indices
    # atuais sao os dois ultimos valores 0x..., conforme a estrutura documentada
    # do powercfg. Nunca aplicamos essa heuristica sobre a saida inteira.
    $hexMatches = [regex]::Matches($bloco, '(?i)0x[0-9a-f]+')

    if ($hexMatches.Count -ge 2) {
        try {
            return [Convert]::ToInt64(
                $hexMatches[$hexMatches.Count - 2].Value.Substring(2),
                16
            )
        }
        catch {
            throw "Indice AC de '$Setting' possui formato invalido na resposta do powercfg."
        }
    }

    throw "Indice AC de '$Setting' nao foi localizado de forma deterministica no registro nem na consulta do powercfg."
}

function Test-PowerSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubGroup,

        [Parameter(Mandatory)]
        [string]$Setting,

        [Parameter(Mandatory)]
        [int]$ExpectedValue,

        [Parameter(Mandatory)]
        [string]$Description,

        [switch]$Required
    )

    try {
        $actual = Get-PowerSettingCurrentAcValue `
            -SchemeGuid $SchemeGuid `
            -SubGroup $SubGroup `
            -Setting $Setting

        if ($actual -ne $ExpectedValue) {
            if ($Required) {
                Write-Log ERR "Validacao falhou: $Description esperado=$ExpectedValue atual=$actual."
            }
            else {
                Write-Log WARN "Validacao parcial: $Description esperado=$ExpectedValue atual=$actual."
            }

            return $false
        }

        Write-Log OK "Validado: $Description = $actual"
        return $true
    }
    catch {
        if ($Required) {
            Write-Log ERR "Falha na validacao de '$Description': $($_.Exception.Message)"
        }
        else {
            Write-Log WARN "Falha ao validar '$Description': $($_.Exception.Message)"
        }

        return $false
    }
}

function Invoke-PowerCfgChangeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Description
    )

    # O Core pode encapsular argumentos nativos de forma diferente entre
    # versoes do modulo. O /changename aceita nomes com espacos, portanto esta
    # operacao usa ProcessStartInfo diretamente para garantir que o nome seja
    # transmitido como um unico argumento.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powercfg
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $quote = {
        param([string]$Value)

        if ($null -eq $Value) {
            return '""'
        }

        # Escapamento compatível com a regra de argumentos da API do Windows.
        $escaped = $Value -replace '(\\*)"', '$1$1\\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        return '"' + $escaped + '"'
    }

    $arguments = @(
        (& $quote '/changename')
        (& $quote $SchemeGuid)
        (& $quote $Name)
    )

    if (-not [string]::IsNullOrEmpty($Description)) {
        $arguments += (& $quote $Description)
    }

    $psi.Arguments = $arguments -join ' '

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw 'Nao foi possivel iniciar o powercfg para alterar o nome do perfil.'
        }

        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { }
            throw 'Tempo limite excedido ao atualizar o nome do perfil de energia.'
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Remove-RedundantPerformanceSchemes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$KeepGuid
    )

    $keepGuid = $KeepGuid.ToLowerInvariant()
    $protectedGuids = @(
        $GUID_ULTIMATE.ToLowerInvariant()
        $GUID_HIGH.ToLowerInvariant()
        $GUID_BALANCED.ToLowerInvariant()
        $keepGuid
    ) | Select-Object -Unique

    $removableNames = @(
        'CompartDisk - Desempenho Maximo'
        'compartdisk desempenho maximo'
        'CompartDisk Desempenho Maximo'
        'Desempenho Maximo'
        'Desempenho Máximo'
    )

    $schemes = @(Get-PowerSchemes -Refresh)
    $candidates = @(
        $schemes | Where-Object {
            $_.Guid -ne $keepGuid -and
            $_.Name -and
            ($removableNames -contains $_.Name -or
             $_.Name -ieq 'Desempenho Maximo' -or
             $_.Name -ieq 'Desempenho Máximo')
        }
    )

    foreach ($scheme in $candidates) {
        if ($protectedGuids -contains $scheme.Guid) {
            continue
        }

        $delete = Invoke-NativeCommand `
            -FilePath $powercfg `
            -Arguments @('/delete', $scheme.Guid) `
            -TimeoutSeconds 30

        if ($delete.ExitCode -eq 0) {
            Write-Log OK "Perfil redundante removido: $($scheme.Name) [$($scheme.Guid)]."
            Clear-PowerSchemeCache
        }
        else {
            $detalhe = if ($delete.StdErr) { $delete.StdErr.Trim() } else { "codigo=$($delete.ExitCode)" }
            Write-Log WARN "Nao foi possivel remover o perfil redundante '$($scheme.Name)' [$($scheme.Guid)]: $detalhe"
            $script:result = 'WARN'
        }
    }
}

function Set-PowerPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Guid,

        [Parameter(Mandatory)]
        [string]$Nome
    )

    $requestedGuid = $Guid.ToLowerInvariant()
    $performanceMode = $false
    $targetName = 'Desempenho Máximo'

    # -----------------------------------------------------------------------
    # Desempenho Máximo
    #
    # Regra de idempotencia:
    # - se o Ultimate Performance oficial existir, ele e o alvo;
    # - caso contrario, reutiliza um perfil existente de Desempenho Máximo
    #   ou um perfil criado por versoes anteriores do modulo;
    # - somente cria um novo esquema quando nenhum alvo reutilizavel existir;
    # - perfis redundantes criados pelo modulo sao removidos depois que o alvo
    #   estiver configurado e ativo.
    #
    # Perfis oficiais do Windows/OEM nao sao excluidos indiscriminadamente.
    # -----------------------------------------------------------------------

    if ($requestedGuid -eq $GUID_ULTIMATE) {
        $schemes = @(Get-PowerSchemes -Refresh)
        $officialUltimate = $schemes |
            Where-Object { $_.Guid -eq $GUID_ULTIMATE.ToLowerInvariant() } |
            Select-Object -First 1

        if ($officialUltimate) {
            $Guid = $officialUltimate.Guid
            $Nome = $targetName
            $performanceMode = $true
            Write-Log INFO "Perfil oficial de Desempenho Maximo localizado: $Guid."
        }
        else {
            $targetCandidates = @(
                $schemes | Where-Object {
                    $_.Name -and (
                        $_.Name -ieq 'Desempenho Máximo' -or
                        $_.Name -ieq 'Desempenho Maximo' -or
                        $_.Name -ieq 'CompartDisk - Desempenho Maximo' -or
                        $_.Name -ieq 'compartdisk desempenho maximo' -or
                        $_.Name -ieq 'CompartDisk Desempenho Maximo'
                    )
                }
            )

            $reusable = $null
            foreach ($preferredName in @('Desempenho Máximo', 'Desempenho Maximo', 'CompartDisk - Desempenho Maximo', 'compartdisk desempenho maximo', 'CompartDisk Desempenho Maximo')) {
                $reusable = $targetCandidates |
                    Where-Object { $_.Name -ieq $preferredName } |
                    Select-Object -First 1

                if ($reusable) {
                    break
                }
            }

            if ($reusable) {
                $Guid = $reusable.Guid
                $Nome = $targetName
                $performanceMode = $true
                Write-Log INFO "Perfil de desempenho existente reutilizado: $Guid."
            }
            else {
                $baseGuid = $null
                $baseName = $null

                if ($schemes.Guid -contains $GUID_HIGH.ToLowerInvariant()) {
                    $baseGuid = $GUID_HIGH
                    $baseName = 'Alto Desempenho'
                    Write-Log WARN 'Ultimate Performance nao esta disponivel. Usando Alto Desempenho como base.'
                }
                elseif ($schemes.Guid -contains $GUID_BALANCED.ToLowerInvariant()) {
                    $baseGuid = $GUID_BALANCED
                    $baseName = 'Equilibrado'
                    Write-Log WARN 'Ultimate/Alto Desempenho nao estao disponiveis. Usando Equilibrado como base.'
                }

                if (-not $baseGuid) {
                    $script:result = 'WARN'
                    Write-Log WARN 'Nenhum esquema de energia utilizavel foi localizado.'
                    Add-CompartDiskFinding `
                        -Severity WARN `
                        -Area 'Desempenho' `
                        -Message 'Nao foi possivel localizar um esquema de energia para criar o perfil de Desempenho Maximo.' `
                        -Recommendation 'Verificar politicas de energia e suporte do Windows.'
                    return
                }

                Write-Log INFO "Criando perfil '$targetName' a partir de '$baseName'."

                $beforeGuids = @(Get-PowerSchemeGuids)

                $d = Invoke-NativeCommand `
                    -FilePath $powercfg `
                    -Arguments @('/duplicatescheme', $baseGuid) `
                    -TimeoutSeconds 60

                $novoGuid = $null
                $textoDuplicacao = @($d.StdOut, $d.StdErr) -join "`n"

                if ($textoDuplicacao -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b') {
                    $novoGuid = $Matches[0].ToLowerInvariant()
                }

                Clear-PowerSchemeCache

                # Fallback deterministico: se a saida do powercfg nao retornar o
                # GUID, identifica exatamente o novo esquema pela diferenca entre
                # a lista anterior e a lista posterior a /duplicatescheme.
                if (($d.ExitCode -eq 0) -and [string]::IsNullOrWhiteSpace($novoGuid)) {
                    $afterGuids = @(Get-PowerSchemeGuids)
                    $novos = @($afterGuids | Where-Object { $beforeGuids -notcontains $_ })

                    if ($novos.Count -eq 1) {
                        $novoGuid = $novos[0]
                    }
                }

                if (
                    ($d.ExitCode -ne 0) -or
                    [string]::IsNullOrWhiteSpace($novoGuid) -or
                    (-not (Test-PowerSchemeExists -Guid $novoGuid))
                ) {
                    $script:result = 'WARN'
                    $detalhe = if ($d.StdErr) { $d.StdErr.Trim() } else { "codigo=$($d.ExitCode)" }
                    Write-Log WARN "Nao foi possivel criar o perfil de Desempenho Maximo: $detalhe"
                    Add-CompartDiskFinding `
                        -Severity WARN `
                        -Area 'Desempenho' `
                        -Message 'Falha ao criar o perfil de Desempenho Maximo.' `
                        -Recommendation 'Verificar permissoes administrativas e politicas de energia do Windows.'
                    return
                }

                $Guid = $novoGuid
                $Nome = $targetName
                $performanceMode = $true
                Write-Log OK "Perfil criado com GUID $Guid."
            }
        }

        # O nome final e sempre o mesmo. O GUID e a identidade tecnica do perfil.
        $descricaoPerfil = 'Perfil de energia otimizado pelo CompartDisk para desempenho maximo em AC.'
        $rename = Invoke-PowerCfgChangeName `
            -SchemeGuid $Guid `
            -Name $targetName `
            -Description $descricaoPerfil

        if ($rename.ExitCode -eq 0) {
            $Nome = $targetName
            Clear-PowerSchemeCache
            Write-Log OK "Nome e descricao do perfil atualizados."
        }
        else {
            $renameSimple = Invoke-PowerCfgChangeName `
                -SchemeGuid $Guid `
                -Name $targetName

            if ($renameSimple.ExitCode -eq 0) {
                $Nome = $targetName
                Clear-PowerSchemeCache
                Write-Log OK "Nome do perfil atualizado: $targetName."
            }
            else {
                Clear-PowerSchemeCache
                $confirmado = Get-PowerSchemes -Refresh |
                    Where-Object { $_.Guid -eq $Guid.ToLowerInvariant() -and $_.Name -ieq $targetName } |
                    Select-Object -First 1

                if ($confirmado) {
                    $Nome = $targetName
                    Write-Log OK "Nome do perfil confirmado como '$targetName'."
                }
                else {
                    $detalhes = @(
                        if ($rename.StdErr) { "primeiro=$($rename.ExitCode): $($rename.StdErr.Trim())" } else { "primeiro=$($rename.ExitCode)" }
                        if ($renameSimple.StdErr) { "segundo=$($renameSimple.ExitCode): $($renameSimple.StdErr.Trim())" } else { "segundo=$($renameSimple.ExitCode)" }
                    ) -join '; '
                    Write-Log WARN "Nao foi possivel atualizar o nome do perfil: $detalhes"
                    $script:result = 'WARN'
                }
            }
        }
    }

    # -----------------------------------------------------------------------
    # Alto Desempenho
    # -----------------------------------------------------------------------

    if ($Guid -eq $GUID_HIGH) {
        if (-not (Test-PowerSchemeExists -Guid $GUID_HIGH)) {
            $script:result = 'WARN'
            Write-Log WARN 'O plano Alto Desempenho nao esta disponivel neste dispositivo.'
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'O plano solicitado nao esta disponivel.' `
                -Recommendation 'Verificar politicas de energia, configuracao do fabricante e politicas de grupo.'
            return
        }
        $performanceMode = $true
    }

    # -----------------------------------------------------------------------
    # Equilibrado
    # -----------------------------------------------------------------------

    if ($Guid -eq $GUID_BALANCED) {
        if (-not (Test-PowerSchemeExists -Guid $GUID_BALANCED)) {
            $script:result = 'WARN'
            Write-Log WARN 'O plano Equilibrado nao foi localizado neste dispositivo.'
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'O plano Equilibrado nao esta disponivel.' `
                -Recommendation 'Verificar politicas de energia e esquemas disponiveis no Windows.'
            return
        }
        $performanceMode = $false
    }

    # -----------------------------------------------------------------------
    # Aplicacao das configuracoes de desempenho
    # -----------------------------------------------------------------------

    if ($performanceMode) {
        $settings = @(
            [pscustomobject]@{ SubGroup='SUB_PROCESSOR'; Setting='PROCTHROTTLEMIN'; Value=100; Description='Estado minimo do processador AC'; Required=$true }
            [pscustomobject]@{ SubGroup='SUB_PROCESSOR'; Setting='PROCTHROTTLEMAX'; Value=100; Description='Estado maximo do processador AC'; Required=$true }
            [pscustomobject]@{ SubGroup='SUB_PROCESSOR'; Setting='SYSCOOLPOL'; Value=1; Description='Politica de resfriamento ativo AC'; Required=$true }
            [pscustomobject]@{ SubGroup='SUB_PCIEXPRESS'; Setting='ASPM'; Value=0; Description='PCI Express Link State Power Management AC'; Required=$false }
            [pscustomobject]@{ SubGroup='SUB_DISK'; Setting='DISKIDLE'; Value=0; Description='Desligamento do disco por ociosidade AC'; Required=$false }
            [pscustomobject]@{ SubGroup='SUB_SLEEP'; Setting='STANDBYIDLE'; Value=0; Description='Suspensao por ociosidade AC'; Required=$false }
            [pscustomobject]@{ SubGroup='SUB_SLEEP'; Setting='HIBERNATEIDLE'; Value=0; Description='Hibernacao por ociosidade AC'; Required=$false }
        )

        $requiredConfigOk = $true

        foreach ($setting in $settings) {
            $args = @{
                SchemeGuid  = $Guid
                SubGroup    = $setting.SubGroup
                Setting     = $setting.Setting
                Value       = $setting.Value
                Description = $setting.Description
            }

            if ($setting.Required) { $args.Required = $true }

            $settingOk = Set-PowerSetting @args
            if (-not $settingOk) {
                if ($setting.Required) { $requiredConfigOk = $false }
                else { $script:result = 'WARN' }
            }
        }

        if (-not $requiredConfigOk) {
            $script:result = 'WARN'
            Write-Log WARN 'Uma ou mais configuracoes essenciais de desempenho nao puderam ser aplicadas.'
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'O perfil foi criado, mas uma ou mais configuracoes essenciais nao puderam ser aplicadas.' `
                -Recommendation 'Verificar suporte do hardware, politicas de energia e permissoes administrativas.'
            return
        }
    }

    # -----------------------------------------------------------------------
    # Ativacao
    # -----------------------------------------------------------------------

    $apply = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/setactive', $Guid) `
        -TimeoutSeconds 30

    if ($apply.ExitCode -ne 0) {
        $script:result = 'WARN'
        $detalhe = if ($apply.StdErr) { $apply.StdErr.Trim() } else { "codigo=$($apply.ExitCode)" }
        Write-Log WARN "Nao foi possivel ativar o plano '$Nome': $detalhe"
        Add-CompartDiskFinding `
            -Severity WARN `
            -Area 'Desempenho' `
            -Message "Falha ao aplicar o plano de energia '$Nome'." `
            -Recommendation 'Verificar politicas de grupo corporativas e permissoes administrativas.'
        return
    }

    # Depois que o alvo esta ativo, duplicatas do proprio modulo podem ser
    # removidas com seguranca sem correr o risco de excluir o esquema ativo.
    if ($performanceMode -and $Guid -ne $GUID_HIGH -and $Guid -ne $GUID_BALANCED) {
        Remove-RedundantPerformanceSchemes -KeepGuid $Guid
    }

    # -----------------------------------------------------------------------
    # Validacao pos-ativacao
    # -----------------------------------------------------------------------

    $atual = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/getactivescheme') `
        -TimeoutSeconds 20

    if ($atual.ExitCode -ne 0) {
        $script:result = 'WARN'
        $detalhe = if ($atual.StdErr) { $atual.StdErr.Trim() } else { "codigo=$($atual.ExitCode)" }
        Write-Log WARN "Nao foi possivel confirmar o esquema ativo '$Nome': $detalhe"
        return
    }

    $activeText = @($atual.StdOut, $atual.StdErr) -join "`n"
    $activeGuid = $null

    if ($activeText -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b') {
        $activeGuid = $Matches[0].ToLowerInvariant()
    }

    if ([string]::IsNullOrWhiteSpace($activeGuid) -or $activeGuid -ne $Guid.ToLowerInvariant()) {
        $script:result = 'WARN'
        Write-Log WARN "O Windows nao confirmou o plano '$Nome' como esquema ativo."
        Add-CompartDiskFinding `
            -Severity WARN `
            -Area 'Desempenho' `
            -Message 'O comando de ativacao foi executado, mas o esquema ativo nao corresponde ao plano solicitado.' `
            -Recommendation 'Verificar os esquemas de energia ativos e possiveis politicas de grupo.'
        if ($atual.StdOut) { Write-Output $atual.StdOut.Trim() }
        return
    }

    # -----------------------------------------------------------------------
    # Validacao real das configuracoes de desempenho
    # -----------------------------------------------------------------------

    if ($performanceMode) {
        $validation = @(
            [pscustomobject]@{ SubGroup='SUB_PROCESSOR'; Setting='PROCTHROTTLEMIN'; Value=100; Description='Estado minimo do processador AC'; Required=$true }
            [pscustomobject]@{ SubGroup='SUB_PROCESSOR'; Setting='PROCTHROTTLEMAX'; Value=100; Description='Estado maximo do processador AC'; Required=$true }
            [pscustomobject]@{ SubGroup='SUB_PROCESSOR'; Setting='SYSCOOLPOL'; Value=1; Description='Politica de resfriamento ativo AC'; Required=$true }
            [pscustomobject]@{ SubGroup='SUB_PCIEXPRESS'; Setting='ASPM'; Value=0; Description='PCI Express Link State Power Management AC'; Required=$false }
            [pscustomobject]@{ SubGroup='SUB_DISK'; Setting='DISKIDLE'; Value=0; Description='Desligamento do disco por ociosidade AC'; Required=$false }
            [pscustomobject]@{ SubGroup='SUB_SLEEP'; Setting='STANDBYIDLE'; Value=0; Description='Suspensao por ociosidade AC'; Required=$false }
            [pscustomobject]@{ SubGroup='SUB_SLEEP'; Setting='HIBERNATEIDLE'; Value=0; Description='Hibernacao por ociosidade AC'; Required=$false }
        )

        $validationOk = $true

        foreach ($setting in $validation) {
            $args = @{
                SchemeGuid    = $Guid
                SubGroup      = $setting.SubGroup
                Setting       = $setting.Setting
                ExpectedValue = $setting.Value
                Description   = $setting.Description
            }

            if ($setting.Required) { $args.Required = $true }
            if (-not (Test-PowerSetting @args)) { $validationOk = $false }
        }

        if (-not $validationOk) {
            $script:result = 'WARN'
            Write-Log WARN 'O perfil foi ativado, mas a validacao das configuracoes de desempenho falhou.'
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'O Windows ativou o perfil, mas nem todas as configuracoes essenciais foram confirmadas.' `
                -Recommendation 'Consultar as opcoes avancadas do plano e verificar politicas de energia.'
            return
        }
    }

    # -----------------------------------------------------------------------
    # Sucesso
    # -----------------------------------------------------------------------

    Write-Log OK "Plano de energia ativo: $Nome"

    if ($performanceMode) {
        Add-CompartDiskFinding `
            -Severity OK `
            -Area 'Desempenho' `
            -Message "Perfil '$Nome' aplicado e validado para desempenho maximo em AC." `
            -Recommendation 'Use Equilibrado quando a prioridade for menor consumo ou maior autonomia.'
    }
    else {
        Add-CompartDiskFinding `
            -Severity OK `
            -Area 'Desempenho' `
            -Message "Plano de energia definido como '$Nome'." `
            -Recommendation 'Em notebooks, planos de alto desempenho podem reduzir a autonomia da bateria.'
    }

    $visualOk = Set-PerformanceVisualEffects -PerformanceMode $performanceMode
    if (-not $visualOk) {
        $script:result = 'WARN'
        Write-Log WARN 'O plano de energia foi aplicado, mas os efeitos visuais nao puderam ser ajustados.'
    }

    if ($atual.StdOut) { Write-Output $atual.StdOut.Trim() }
}

# ---------------------------------------------------------------------------
# Execucao
# ---------------------------------------------------------------------------

try {

    $precisaAdmin = @(
        'Ultimate',
        'Balanced'
    ) -contains $Action

    if (
        -not (
            Start-CompartDiskModule `
                -Name 'Performance' `
                -Action $Action `
                -RequireAdmin:$precisaAdmin `
                -Quiet:$Quiet
        )
    ) {
        $script:result = 'ERROR'
        throw 'Falha ao iniciar o modulo Performance.'
    }

    switch ($Action) {

        # -------------------------------------------------------------------
        # Analise completa
        # -------------------------------------------------------------------

        'Analyze' {
            Show-Analysis
        }

        # -------------------------------------------------------------------
        # Desempenho Maximo
        # -------------------------------------------------------------------

        'Ultimate' {
            Set-PowerPlan `
                -Guid $GUID_ULTIMATE `
                -Nome 'Desempenho Maximo'
        }

        # -------------------------------------------------------------------
        # Equilibrado
        # -------------------------------------------------------------------

        'Balanced' {
            Set-PowerPlan `
                -Guid $GUID_BALANCED `
                -Nome 'Equilibrado (padrao)'
        }

        # -------------------------------------------------------------------
        # Inicializacao
        # -------------------------------------------------------------------

        'Startup' {

            $s = @(Get-CompartDiskStartupItems)

            $s |
                Format-Table -AutoSize -Wrap |
                Out-String -Width 220 |
                Write-Output

            $status = if ($s.Count -gt 12) {
                'WARN'
            }
            else {
                'OK'
            }

            if ($s.Count -gt 12) {
                $script:result = 'WARN'

                Add-CompartDiskFinding `
                    -Severity WARN `
                    -Area 'Desempenho' `
                    -Message "$($s.Count) programas configurados para iniciar com o Windows." `
                    -Recommendation 'Revisar em Gerenciador de Tarefas > Aplicativos de inicializacao.'
            }

            Add-CompartDiskSection `
                -Title 'Itens de inicializacao' `
                -Status $status `
                -Rows $s `
                -Summary "$($s.Count) item(ns)"
        }

        # -------------------------------------------------------------------
        # Processos
        # -------------------------------------------------------------------

        'Processes' {

            $p = @(Get-CompartDiskProcessDiagnostics -Top 25)

            $p |
                Format-Table -AutoSize |
                Out-String -Width 200 |
                Write-Output

            Add-CompartDiskSection `
                -Title 'Processos' `
                -Status INFO `
                -Rows $p
        }

        # -------------------------------------------------------------------
        # Servicos
        # -------------------------------------------------------------------

        'Services' {

            $s = @(Get-CompartDiskServiceDiagnostics)

            $problemas = @(
                $s |
                Where-Object {
                    $_.Diagnostico -ne 'OK'
                }
            )

            $status = if ($problemas.Count -gt 0) {
                'WARN'
            }
            else {
                'OK'
            }

            if ($problemas.Count -gt 0) {

                $script:result = 'WARN'

                foreach ($p in $problemas) {
                    Add-CompartDiskFinding `
                        -Severity WARN `
                        -Area 'Servicos' `
                        -Message "Servico '$($p.Servico)' esta $($p.Estado) (inicio: $($p.Inicio))." `
                        -Recommendation 'Restaurar o tipo de inicializacao padrao e iniciar o servico.'
                }
            }
            else {
                Add-CompartDiskFinding `
                    -Severity OK `
                    -Area 'Servicos' `
                    -Message 'Todos os servicos essenciais operando normalmente.'
            }

            $s |
                Format-Table -AutoSize |
                Out-String -Width 200 |
                Write-Output

            Add-CompartDiskSection `
                -Title 'Servicos essenciais' `
                -Status $status `
                -Rows $s
        }
    }
}
catch {

    $script:result = 'ERROR'

    Write-Log `
        ERR `
        "Falha nao tratada no modulo Performance (Acao=$Action)." `
        -ErrorRecord $_

    Add-CompartDiskFinding `
        -Severity CRIT `
        -Area 'Desempenho' `
        -Message "Excecao no modulo: $($_.Exception.Message)"
}
finally {

    $codigo = Stop-CompartDiskModule `
        -Result $script:result `
        -Quiet:$Quiet
}

exit $codigo
