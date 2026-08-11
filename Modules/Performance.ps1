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

# Erros de cmdlets devem interromper a operacao corrente e chegar ao tratamento
# apropriado. Comandos nativos sao validados explicitamente por ExitCode.
# Nenhuma falha operacional deve ser convertida silenciosamente em sucesso.

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
$script:powerSchemeCache = $null
$script:powerSchemeCacheLoaded = $false

function Set-PerformanceResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('OK', 'WARN', 'ERROR')]
        [string]$Status
    )

    $severity = @{
        OK    = 0
        WARN  = 1
        ERROR = 2
    }

    if ($severity[$Status] -gt $severity[$script:result]) {
        $script:result = $Status
    }
}

function Clear-PowerSchemeCache {
    [CmdletBinding()]
    param()

    $script:powerSchemeCache = $null
    $script:powerSchemeCacheLoaded = $false
}

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

function Get-PowerSchemes {
    [CmdletBinding()]
    param()

    if ($script:powerSchemeCacheLoaded) {
        return @($script:powerSchemeCache)
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
        throw "powercfg /list falhou com codigo $($r.ExitCode). Saida: $($texto.Trim())"
    }

    if ([string]::IsNullOrWhiteSpace($texto)) {
        $script:powerSchemeCache = @()
        $script:powerSchemeCacheLoaded = $true
        return @()
    }

    $guidRegex = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    $schemes = [System.Collections.Generic.List[object]]::new()

    foreach ($linha in ($texto -split "`r?`n")) {
        $guidMatch = [regex]::Match($linha, $guidRegex)
        if (-not $guidMatch.Success) {
            continue
        }

        $guid = $guidMatch.Value.ToLowerInvariant()
        $nameMatch = [regex]::Match($linha, '\(([^()]*)\)\s*$')
        $name = if ($nameMatch.Success) { $nameMatch.Groups[1].Value.Trim() } else { $null }
        $isActive = $linha -match '\*\s*$'

        if (-not ($schemes.Guid -contains $guid)) {
            $schemes.Add([pscustomobject]@{
                Guid     = $guid
                Name     = $name
                IsActive = $isActive
            })
        }
    }

    $script:powerSchemeCache = @($schemes)
    $script:powerSchemeCacheLoaded = $true
    return @($script:powerSchemeCache)
}

function Get-PowerSchemeGuids {
    [CmdletBinding()]
    param()

    return @((Get-PowerSchemes).Guid)
}

function Test-PowerSchemeExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Guid
    )

    return (Get-PowerSchemeGuids) -contains $Guid.ToLowerInvariant()
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
        Set-PerformanceResult -Status WARN
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
        Set-PerformanceResult -Status WARN
        Write-Log WARN "Falha ao consultar processos ativos: $($_.Exception.Message)" -ErrorRecord $_
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
        Set-PerformanceResult -Status WARN
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

            Set-PerformanceResult -Status WARN
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

        Set-PerformanceResult -Status WARN
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

function Get-PowerSchemeByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $scheme = Get-PowerSchemes | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.Name) -and $_.Name -ieq $Name
    } | Select-Object -First 1

    if ($scheme) {
        return $scheme.Guid
    }

    return $null
}

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

            Set-PerformanceResult -Status WARN
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

        Set-PerformanceResult -Status WARN
        Write-Log WARN "Configuracao '$Description' indisponivel neste dispositivo: $($_.Exception.Message)"
        return $false
    }
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
        # O valor AC armazenado pelo Windows e independente do idioma da saida
        # do powercfg. O caminho por GUID e estavel por esquema/subgrupo/configuracao.
        $subGroupGuids = @{
            'SUB_PROCESSOR'   = '54533251-82be-4824-96c1-47b60b740d00'
            'SUB_PCIEXPRESS'  = '501a4d13-42af-4429-9fd1-a8218c268e20'
            'SUB_DISK'        = '0012ee47-9041-4b5d-9b77-535fba8b1442'
            'SUB_SLEEP'       = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
        }

        $settingGuids = @{
            'PROCTHROTTLEMIN' = '893dee8e-2bef-41e0-89c6-b55d0929964c'
            'PROCTHROTTLEMAX' = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
            'SYSCOOLPOL'      = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
            'ASPM'            = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            'DISKIDLE'        = '6738e2c4-e8a5-4a42-b16a-e040e769756e'
            'STANDBYIDLE'     = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
            'HIBERNATEIDLE'   = '9d7815a6-7ee4-497e-8888-515a05f02364'
        }

        $actual = $null
        $registryPath = $null

        if ($subGroupGuids.ContainsKey($SubGroup) -and $settingGuids.ContainsKey($Setting)) {
            $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$SchemeGuid\$($subGroupGuids[$SubGroup])\$($settingGuids[$Setting])"

            try {
                $property = Get-ItemProperty -LiteralPath $registryPath -Name 'ACSettingIndex' -ErrorAction Stop
                $actual = [int]$property.ACSettingIndex
            }
            catch {
                # O Registro e a fonte primaria. Se a chave nao estiver disponivel,
                # usa-se uma consulta pontual ao powercfg como fallback.
                $actual = $null
            }
        }

        if ($null -eq $actual) {
            $r = Invoke-NativeCommand `
                -FilePath $powercfg `
                -Arguments @('/query', $SchemeGuid, $SubGroup, $Setting) `
                -TimeoutSeconds 30

            $texto = @(
                $r.StdOut
                $r.StdErr
            ) -join "`n"

            if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($texto)) {
                if ($Required) {
                    Write-Log ERR "Nao foi possivel validar '$Description' (codigo $($r.ExitCode))."
                    return $false
                }

                Write-Log WARN "Nao foi possivel validar '$Description' neste dispositivo."
                return $true
            }

            # A saida do powercfg e localizada. Nao procurar texto como
            # 'Current AC Power Setting Index'. Em uma consulta especifica,
            # os dois ultimos indices hexadecimais sao AC e DC.
            $indices = @(
                [regex]::Matches($texto, '(?i)0x[0-9a-f]+') |
                ForEach-Object {
                    try {
                        [Convert]::ToInt32($_.Value.Substring(2), 16)
                    }
                    catch {
                        $null
                    }
                } |
                Where-Object { $null -ne $_ }
            )

            if ($indices.Count -lt 2) {
                if ($Required) {
                    Write-Log ERR "Valor AC de '$Description' nao foi localizado na consulta."
                    return $false
                }

                Write-Log WARN "Valor AC de '$Description' nao foi localizado na consulta."
                return $true
            }

            $actual = [int]$indices[$indices.Count - 2]
        }

        if ($actual -ne $ExpectedValue) {
            if ($Required) {
                Write-Log ERR "Validacao falhou: $Description esperado=$ExpectedValue atual=$actual."
                return $false
            }

            Write-Log WARN "Validacao parcial: $Description esperado=$ExpectedValue atual=$actual."
            return $true
        }

        Write-Log OK "Validado: $Description = $actual"
        return $true
    }
    catch {
        if ($Required) {
            Write-Log ERR "Falha na validacao de '$Description': $($_.Exception.Message)"
            return $false
        }

        Write-Log WARN "Falha ao validar '$Description': $($_.Exception.Message)"
        return $true
    }
}

function Invoke-PowerCfgChangeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Guid,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powercfg
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = '/changename "{0}" "{1}"' -f $Guid, $Name

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw 'Nao foi possivel iniciar o powercfg.exe para renomear o esquema.'
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

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

    # -----------------------------------------------------------------------
    # Desempenho Maximo real
    #
    # O modulo cria/reutiliza um esquema dedicado para desempenho maximo.
    # As alteracoes sao feitas somente no perfil AC (tomada).
    # O plano Equilibrado e os demais esquemas existentes nao sao modificados.
    #
    # Criterio:
    # - CPU minimo AC = 100%
    # - CPU maximo AC = 100%
    # - Resfriamento ativo
    # - PCIe ASPM desligado quando o recurso estiver disponivel
    # - Disco sem desligamento por ociosidade em AC
    # - Suspensao/hibernacao por ociosidade desabilitadas em AC
    #
    # Nao desabilita USB Selective Suspend: a Microsoft recomenda manter
    # esse recurso habilitado. Nao altera drivers, servicos ou hardware.
    # -----------------------------------------------------------------------

    if ($requestedGuid -eq $GUID_ULTIMATE) {

        $customName = 'Desempenho M' + [char]0x00E1 + 'ximo'
        $existingCustomGuid = Get-PowerSchemeByName -Name $customName

        if ($existingCustomGuid) {
            $Guid = $existingCustomGuid
            $Nome = $customName
            $performanceMode = $true

            Write-Log INFO "Plano personalizado ja existente: $Guid."
        }
        else {
            # Reaproveita uma copia antiga criada por versoes anteriores,
            # desde que ela nao seja o esquema oficial do Windows.
            $legacyGuid = Get-PowerSchemeByName -Name 'Desempenho Maximo'

            if (
                $legacyGuid -and
                $legacyGuid -ne $GUID_ULTIMATE
            ) {
                $Guid = $legacyGuid
                $Nome = $customName
                $performanceMode = $true

                Write-Log INFO "Plano personalizado existente reutilizado: $Guid."
            }
            else {
                # Ultimate Performance e o modelo preferencial.
                # Se nao estiver exposto, usa High Performance como base.
                $baseGuid = $null
                $baseName = $null

                if (Test-PowerSchemeExists -Guid $GUID_ULTIMATE) {
                    $baseGuid = $GUID_ULTIMATE
                    $baseName = 'Desempenho Maximo'
                }
                elseif (Test-PowerSchemeExists -Guid $GUID_HIGH) {
                    $baseGuid = $GUID_HIGH
                    $baseName = 'Alto Desempenho'
                    Write-Log WARN 'Ultimate Performance nao esta exposto. Usando Alto Desempenho como base.'
                }
                elseif (Test-PowerSchemeExists -Guid $GUID_BALANCED) {
                    $baseGuid = $GUID_BALANCED
                    $baseName = 'Equilibrado'
                    Write-Log WARN 'Ultimate/Alto Desempenho nao estao disponiveis. Usando Equilibrado como base.'
                }

                if (-not $baseGuid) {
                    Set-PerformanceResult -Status WARN

                    Write-Log WARN 'Nenhum esquema de energia utilizavel foi localizado.'
                    Add-CompartDiskFinding `
                        -Severity WARN `
                        -Area 'Desempenho' `
                        -Message 'Nao foi possivel localizar um esquema de energia para criar o perfil de Desempenho Maximo.' `
                        -Recommendation 'Verificar politicas de energia e suporte do Windows.'

                    return
                }

                Write-Log INFO "Criando perfil '$customName' a partir de '$baseName'."

                $d = Invoke-NativeCommand `
                    -FilePath $powercfg `
                    -Arguments @('/duplicatescheme', $baseGuid) `
                    -TimeoutSeconds 60

                $novoGuid = $null

                $textoDuplicacao = @(
                    $d.StdOut
                    $d.StdErr
                ) -join "`n"

                if (
                    $textoDuplicacao -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
                ) {
                    $novoGuid = $Matches[0].ToLowerInvariant()
                }

                if ($d.ExitCode -eq 0) {
                    Clear-PowerSchemeCache

                    if ([string]::IsNullOrWhiteSpace($novoGuid)) {
                        $novoGuid = @(
                            Get-PowerSchemes |
                            Where-Object {
                                $_.Guid -ne $baseGuid -and
                                -not [string]::IsNullOrWhiteSpace($_.Name) -and
                                $_.Name -ieq $baseName
                            }
                        ) |
                        Select-Object -ExpandProperty Guid -First 1
                    }
                }

                if (
                    ($d.ExitCode -ne 0) -or
                    [string]::IsNullOrWhiteSpace($novoGuid) -or
                    (-not (Test-PowerSchemeExists -Guid $novoGuid))
                ) {
                    Set-PerformanceResult -Status WARN

                    Write-Log WARN 'Nao foi possivel criar o perfil personalizado de Desempenho Maximo.'

                    Add-CompartDiskFinding `
                        -Severity WARN `
                        -Area 'Desempenho' `
                        -Message 'Falha ao criar o perfil personalizado de Desempenho Maximo.' `
                        -Recommendation 'Verificar permissoes administrativas e politicas de energia do Windows.'

                    return
                }

                $Guid = $novoGuid
                $Nome = $customName
                $performanceMode = $true

                Write-Log OK "Perfil criado com GUID $Guid."
            }
        }

        # Atualiza somente o nome. Nao envia descricao personalizada.
        # O /changename e isolado do wrapper nativo porque o log real mostrou
        # falha especifica nessa operacao, enquanto as demais chamadas funcionam.
        $rename = Invoke-PowerCfgChangeName -Guid $Guid -Name $customName

        if ($rename.ExitCode -ne 0) {
            $stderr = if ([string]::IsNullOrWhiteSpace($rename.StdErr)) { 'sem detalhes' } else { $rename.StdErr.Trim() }
            Set-PerformanceResult -Status WARN
            Write-Log WARN "Nao foi possivel atualizar o nome do perfil (codigo $($rename.ExitCode); stderr=$stderr)."
        }
        else {
            $Nome = $customName
            Clear-PowerSchemeCache
            Write-Log OK 'Nome do perfil atualizado.'
        }
    }

    # -----------------------------------------------------------------------
    # Alto Desempenho
    # -----------------------------------------------------------------------

    if ($Guid -eq $GUID_HIGH) {

        if (-not (Test-PowerSchemeExists -Guid $GUID_HIGH)) {

            Set-PerformanceResult -Status WARN

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

            Set-PerformanceResult -Status WARN

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
            [pscustomobject]@{
                SubGroup    = 'SUB_PROCESSOR'
                Setting     = 'PROCTHROTTLEMIN'
                Value       = 100
                Description = 'Estado minimo do processador AC'
                Required    = $true
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_PROCESSOR'
                Setting     = 'PROCTHROTTLEMAX'
                Value       = 100
                Description = 'Estado maximo do processador AC'
                Required    = $true
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_PROCESSOR'
                Setting     = 'SYSCOOLPOL'
                Value       = 1
                Description = 'Politica de resfriamento ativo AC'
                Required    = $true
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_PCIEXPRESS'
                Setting     = 'ASPM'
                Value       = 0
                Description = 'PCI Express Link State Power Management AC'
                Required    = $false
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_DISK'
                Setting     = 'DISKIDLE'
                Value       = 0
                Description = 'Desligamento do disco por ociosidade AC'
                Required    = $false
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_SLEEP'
                Setting     = 'STANDBYIDLE'
                Value       = 0
                Description = 'Suspensao por ociosidade AC'
                Required    = $false
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_SLEEP'
                Setting     = 'HIBERNATEIDLE'
                Value       = 0
                Description = 'Hibernacao por ociosidade AC'
                Required    = $false
            }
        )

        $configOk = $true
        $optionalConfigIssue = $false

        foreach ($setting in $settings) {

            $args = @{
                SchemeGuid  = $Guid
                SubGroup    = $setting.SubGroup
                Setting     = $setting.Setting
                Value       = $setting.Value
                Description = $setting.Description
            }

            if ($setting.Required) {
                $args.Required = $true
            }

            if (-not (Set-PowerSetting @args)) {
                if ($setting.Required) {
                    $configOk = $false
                }
                else {
                    $optionalConfigIssue = $true
                }
            }
        }

        if (-not $configOk) {
            Set-PerformanceResult -Status WARN

            Write-Log WARN 'Uma ou mais configuracoes essenciais de desempenho nao puderam ser aplicadas.'

            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'O perfil foi criado, mas uma ou mais configuracoes essenciais nao puderam ser aplicadas.' `
                -Recommendation 'Verificar suporte do hardware, politicas de energia e permissoes administrativas.'

            return
        }

        # Aplica as alteracoes acumuladas no esquema.
        $apply = Invoke-NativeCommand `
            -FilePath $powercfg `
            -Arguments @('/setactive', $Guid) `
            -TimeoutSeconds 30

        if ($apply.ExitCode -ne 0) {

            Set-PerformanceResult -Status WARN

            Write-Log WARN "Nao foi possivel ativar o perfil configurado (codigo $($apply.ExitCode))."

            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'As configuracoes foram preparadas, mas o Windows nao confirmou a ativacao do perfil.' `
                -Recommendation 'Verificar politicas de energia e permissoes administrativas.'

            return
        }
    }
    else {

        # -------------------------------------------------------------------
        # Ativacao normal de Equilibrado/Alto Desempenho
        # -------------------------------------------------------------------

        $apply = Invoke-NativeCommand `
            -FilePath $powercfg `
            -Arguments @('/setactive', $Guid) `
            -TimeoutSeconds 30

        if ($apply.ExitCode -ne 0) {

            Set-PerformanceResult -Status WARN

            Write-Log WARN "Nao foi possivel ativar o plano '$Nome' (codigo $($apply.ExitCode))."

            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message "Falha ao aplicar o plano de energia '$Nome'." `
                -Recommendation 'Politicas de grupo corporativas podem bloquear a alteracao do plano.'

            return
        }
    }

    # -----------------------------------------------------------------------
    # Validacao pos-ativacao
    # -----------------------------------------------------------------------

    $atual = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/getactivescheme') `
        -TimeoutSeconds 20

    $activeGuid = $null
    $activeText = @(
        $atual.StdOut
        $atual.StdErr
    ) -join "`n"

    if ($atual.ExitCode -ne 0) {
        Set-PerformanceResult -Status WARN
        Write-Log WARN "Nao foi possivel consultar o esquema ativo (codigo $($atual.ExitCode))."
        Add-CompartDiskFinding `
            -Severity WARN `
            -Area 'Desempenho' `
            -Message 'O Windows nao permitiu confirmar o esquema de energia ativo.' `
            -Recommendation 'Verificar permissoes administrativas e politicas de energia.'
        return
    }

    if (
        $activeText -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    ) {
        $activeGuid = $Matches[0].ToLowerInvariant()
    }

    if (
        [string]::IsNullOrWhiteSpace($activeGuid) -or
        $activeGuid -ne $Guid.ToLowerInvariant()
    ) {
        Set-PerformanceResult -Status WARN

        Write-Log WARN "O Windows nao confirmou o plano '$Nome' como esquema ativo."

        Add-CompartDiskFinding `
            -Severity WARN `
            -Area 'Desempenho' `
            -Message 'O comando de ativacao foi executado, mas o esquema ativo nao corresponde ao plano solicitado.' `
            -Recommendation 'Verificar os esquemas de energia ativos e possiveis politicas de grupo.'

        if ($atual.StdOut) {
            Write-Output $atual.StdOut.Trim()
        }

        return
    }

    # -----------------------------------------------------------------------
    # Validacao do nome efetivamente registrado no esquema ativo
    # -----------------------------------------------------------------------
    if ($performanceMode) {
        # O cache e invalidado apos /changename. Consulte novamente o esquema
        # pelo nome canonico para confirmar o estado real sem depender do
        # formato localizado da saida textual do powercfg /list.
        Clear-PowerSchemeCache
        $registeredGuid = Get-PowerSchemeByName -Name $Nome

        if ([string]::IsNullOrWhiteSpace($registeredGuid) -or $registeredGuid -ne $Guid.ToLowerInvariant()) {
            Set-PerformanceResult -Status WARN
            Write-Log WARN "O esquema $Guid esta ativo, mas o nome '$Nome' nao foi confirmado para esse GUID."
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'O perfil foi ativado, mas o nome canonico nao foi confirmado pelo Windows.' `
                -Recommendation 'Verificar a execucao do powercfg /changename e as permissoes administrativas.'
            return
        }
    }

    # -----------------------------------------------------------------------
    # Validacao real das configuracoes de desempenho
    # -----------------------------------------------------------------------

    if ($performanceMode) {

        $validation = @(
            [pscustomobject]@{
                SubGroup    = 'SUB_PROCESSOR'
                Setting     = 'PROCTHROTTLEMIN'
                Value       = 100
                Description = 'Estado minimo do processador AC'
                Required    = $true
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_PROCESSOR'
                Setting     = 'PROCTHROTTLEMAX'
                Value       = 100
                Description = 'Estado maximo do processador AC'
                Required    = $true
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_PROCESSOR'
                Setting     = 'SYSCOOLPOL'
                Value       = 1
                Description = 'Politica de resfriamento ativo AC'
                Required    = $true
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_PCIEXPRESS'
                Setting     = 'ASPM'
                Value       = 0
                Description = 'PCI Express Link State Power Management AC'
                Required    = $false
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_DISK'
                Setting     = 'DISKIDLE'
                Value       = 0
                Description = 'Desligamento do disco por ociosidade AC'
                Required    = $false
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_SLEEP'
                Setting     = 'STANDBYIDLE'
                Value       = 0
                Description = 'Suspensao por ociosidade AC'
                Required    = $false
            }
            [pscustomobject]@{
                SubGroup    = 'SUB_SLEEP'
                Setting     = 'HIBERNATEIDLE'
                Value       = 0
                Description = 'Hibernacao por ociosidade AC'
                Required    = $false
            }
        )

        $validationOk = $true
        $optionalValidationIssue = $false

        foreach ($setting in $validation) {

            $args = @{
                SchemeGuid    = $Guid
                SubGroup      = $setting.SubGroup
                Setting       = $setting.Setting
                ExpectedValue = $setting.Value
                Description   = $setting.Description
            }

            if ($setting.Required) {
                $args.Required = $true
            }

            if (-not (Test-PowerSetting @args)) {
                if ($setting.Required) {
                    $validationOk = $false
                }
                else {
                    $optionalValidationIssue = $true
                }
            }
        }

        if (-not $validationOk) {

            Set-PerformanceResult -Status WARN

            Write-Log WARN 'O perfil foi ativado, mas a validacao das configuracoes de desempenho falhou.'

            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'O Windows ativou o perfil, mas nem todas as configuracoes essenciais foram confirmadas.' `
                -Recommendation 'Consultar as opcoes avancadas do plano e verificar politicas de energia.'

            return
        }

        if ($optionalValidationIssue -or $optionalConfigIssue) {
            Set-PerformanceResult -Status WARN
            Write-Log WARN 'Uma ou mais configuracoes opcionais de desempenho nao puderam ser aplicadas ou confirmadas.'
        }
    }

    # -----------------------------------------------------------------------
    # Sucesso
    # -----------------------------------------------------------------------

    Write-Log OK "Plano de energia ativo: $Nome"

    # -----------------------------------------------------------------------
    # Efeitos visuais
    # -----------------------------------------------------------------------

    $visualOk = Set-PerformanceVisualEffects -PerformanceMode $performanceMode

    if (-not $visualOk) {
        Set-PerformanceResult -Status WARN
        Write-Log WARN 'O plano de energia foi aplicado, mas os efeitos visuais nao puderam ser ajustados.'
    }

    if ($script:result -eq 'OK') {
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
    }
    else {
        if ($performanceMode) {
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message "Perfil '$Nome' aplicado, mas existem avisos de validacao ou configuracao." `
                -Recommendation 'Revise os avisos registrados antes de considerar o perfil totalmente validado.'
        }
        else {
            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message "Plano de energia '$Nome' foi aplicado, mas existem avisos de validacao ou configuracao." `
                -Recommendation 'Revise os avisos registrados para confirmar o estado final.'
        }
    }

    # -----------------------------------------------------------------------
    # Exibe o esquema efetivamente ativo
    # -----------------------------------------------------------------------

    if ($atual.StdOut) {
        Write-Output $atual.StdOut.Trim()
    }
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
        Set-PerformanceResult -Status ERROR
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
                Set-PerformanceResult -Status WARN

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

                Set-PerformanceResult -Status WARN

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

    Set-PerformanceResult -Status ERROR

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
