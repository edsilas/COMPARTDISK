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

function Get-PowerSchemeGuids {
    [CmdletBinding()]
    param()

    $r = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/list') `
        -TimeoutSeconds 30

    $texto = @(
        $r.StdOut
        $r.StdErr
    ) -join "`n"

    if ([string]::IsNullOrWhiteSpace($texto)) {
        return @()
    }

    $regex = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'

    return @(
        [regex]::Matches($texto, $regex) |
        ForEach-Object { $_.Value.ToLowerInvariant() } |
        Select-Object -Unique
    )
}

function Test-PowerSchemeExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Guid
    )

    $guids = Get-PowerSchemeGuids

    return $guids -contains $Guid.ToLowerInvariant()
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
        'Processos ativos'  = @(
            Get-Process -ErrorAction SilentlyContinue
        ).Count
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
    # Ultimate Performance
    # -----------------------------------------------------------------------

    if ($requestedGuid -eq $GUID_ULTIMATE) {

        if (-not (Test-PowerSchemeExists -Guid $GUID_ULTIMATE)) {

            Write-Log INFO 'Plano Desempenho Maximo ausente. Tentando duplicar o modelo do Windows.'

            $antes = @(Get-PowerSchemeGuids)

            $d = Invoke-NativeCommand `
                -FilePath $powercfg `
                -Arguments @('-duplicatescheme', $GUID_ULTIMATE) `
                -TimeoutSeconds 60

            $novoGuid = $null

            # Primeiro tenta capturar o GUID diretamente da saida.
            $textoDuplicacao = @(
                $d.StdOut
                $d.StdErr
            ) -join "`n"

            if ($textoDuplicacao -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b') {
                $novoGuid = $Matches[0].ToLowerInvariant()
            }

            # Se nao encontrou na saida, compara a lista antes/depois.
            if (
                ($d.ExitCode -eq 0) -and
                [string]::IsNullOrWhiteSpace($novoGuid)
            ) {
                $depois = @(Get-PowerSchemeGuids)

                $novos = @(
                    $depois |
                    Where-Object {
                        $antes -notcontains $_ -and
                        $_ -ne $GUID_ULTIMATE
                    }
                )

                if ($novos.Count -eq 1) {
                    $novoGuid = $novos[0]
                }
                elseif ($novos.Count -gt 1) {
                    Write-Log WARN 'Mais de um novo esquema foi identificado; nao foi possivel determinar com seguranca o plano criado.'
                }
            }

            if (
                ($d.ExitCode -eq 0) -and
                -not [string]::IsNullOrWhiteSpace($novoGuid) -and
                (Test-PowerSchemeExists -Guid $novoGuid)
            ) {
                $Guid = $novoGuid
                $Nome = 'Desempenho Maximo'
                $performanceMode = $true

                Write-Log OK "Plano Desempenho Maximo criado com GUID $Guid."
            }
            else {
                Write-Log WARN 'Este dispositivo nao expoe o plano Desempenho Maximo.'
                Write-Log INFO 'Tentando aplicar o plano Alto Desempenho como alternativa nativa.'

                $Guid = $GUID_HIGH
                $Nome = 'Alto Desempenho'
                $requestedGuid = $GUID_HIGH
                $performanceMode = $true
            }
        }
        else {
            $Guid = $GUID_ULTIMATE
            $Nome = 'Desempenho Maximo'
            $performanceMode = $true

            Write-Log INFO 'Plano Desempenho Maximo ja esta disponivel.'
        }
    }

    # -----------------------------------------------------------------------
    # Alto Desempenho
    # -----------------------------------------------------------------------

    if ($Guid -eq $GUID_HIGH) {

        if (-not (Test-PowerSchemeExists -Guid $GUID_HIGH)) {

            $script:result = 'WARN'

            Write-Log WARN 'O plano Alto Desempenho tambem nao esta disponivel neste dispositivo.'

            Add-CompartDiskFinding `
                -Severity WARN `
                -Area 'Desempenho' `
                -Message 'Nao foi possivel localizar o plano Desempenho Maximo nem o plano Alto Desempenho.' `
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
    # Ativacao
    # -----------------------------------------------------------------------

    $r = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/setactive', $Guid) `
        -TimeoutSeconds 30

    if ($r.ExitCode -ne 0) {

        $script:result = 'WARN'

        Write-Log WARN "Nao foi possivel ativar o plano '$Nome' (codigo $($r.ExitCode))."

        Add-CompartDiskFinding `
            -Severity WARN `
            -Area 'Desempenho' `
            -Message "Falha ao aplicar o plano de energia '$Nome'." `
            -Recommendation 'Politicas de grupo corporativas podem bloquear a alteracao do plano.'

        return
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

    if (
        $activeText -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    ) {
        $activeGuid = $Matches[0].ToLowerInvariant()
    }

    if (
        [string]::IsNullOrWhiteSpace($activeGuid) -or
        $activeGuid -ne $Guid.ToLowerInvariant()
    ) {
        $script:result = 'WARN'

        Write-Log WARN "O Windows nao confirmou o plano '$Nome' como esquema ativo."

        Add-CompartDiskFinding `
            -Severity WARN `
            -Area 'Desempenho' `
            -Message "O comando de ativacao foi executado, mas o esquema ativo nao corresponde ao plano solicitado." `
            -Recommendation 'Verificar os esquemas de energia ativos e possiveis politicas de grupo.'

        if ($atual.StdOut) {
            Write-Output $atual.StdOut.Trim()
        }

        return
    }

    # -----------------------------------------------------------------------
    # Sucesso
    # -----------------------------------------------------------------------

    Write-Log OK "Plano de energia ativo: $Nome"

    Add-CompartDiskFinding `
        -Severity OK `
        -Area 'Desempenho' `
        -Message "Plano de energia definido como '$Nome'." `
        -Recommendation 'Em notebooks, planos de alto desempenho podem reduzir a autonomia da bateria.'

    # -----------------------------------------------------------------------
    # Efeitos visuais
    # -----------------------------------------------------------------------

    $visualOk = Set-PerformanceVisualEffects -PerformanceMode $performanceMode

    if (-not $visualOk) {
        $script:result = 'WARN'

        Write-Log WARN 'O plano de energia foi aplicado, mas os efeitos visuais nao puderam ser ajustados.'
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
