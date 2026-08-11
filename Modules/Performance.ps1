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

function Get-PowerSchemeByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $r = Invoke-NativeCommand `
        -FilePath $powercfg `
        -Arguments @('/list') `
        -TimeoutSeconds 30

    $texto = @(
        $r.StdOut
        $r.StdErr
    ) -join "`n"

    if ([string]::IsNullOrWhiteSpace($texto)) {
        return $null
    }

    $guidRegex = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'

    foreach ($linha in ($texto -split "`r?`n")) {
        if ($linha -match $guidRegex) {
            $guid = $Matches[0].ToLowerInvariant()

            if ($linha -match '\(([^()]*)\)\s*$') {
                $nomeEncontrado = $Matches[1].Trim()

                if ($nomeEncontrado -ieq $Name) {
                    return $guid
                }
            }
        }
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

            Write-Log WARN "Configuracao '$Description' nao foi aplicada neste dispositivo (codigo $($r.ExitCode))."
            return $true
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
        return $true
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
                Write-Log ERR "Nao foi possivel validar '$Description'."
                return $false
            }

            Write-Log WARN "Nao foi possivel validar '$Description' neste dispositivo."
            return $true
        }

        $m = [regex]::Match(
            $texto,
            '(?im)^\s*Current AC Power Setting Index:\s*0x([0-9a-f]+)'
        )

        if (-not $m.Success) {
            if ($Required) {
                Write-Log ERR "Valor AC de '$Description' nao foi localizado na consulta."
                return $false
            }

            Write-Log WARN "Valor AC de '$Description' nao foi localizado na consulta."
            return $true
        }

        $actual = [Convert]::ToInt32($m.Groups[1].Value, 16)

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
    # O modulo cria/reutiliza um esquema proprio do CompartDisk.
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

        $customName = 'CompartDisk - Desempenho Maximo'
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
                    $script:result = 'WARN'

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

                if (
                    ($d.ExitCode -eq 0) -and
                    [string]::IsNullOrWhiteSpace($novoGuid)
                ) {
                    $novoGuid = Get-PowerSchemeByName -Name $baseName

                    if ($novoGuid -eq $baseGuid) {
                        $novoGuid = $null
                    }
                }

                if (
                    ($d.ExitCode -ne 0) -or
                    [string]::IsNullOrWhiteSpace($novoGuid) -or
                    (-not (Test-PowerSchemeExists -Guid $novoGuid))
                ) {
                    $script:result = 'WARN'

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

        # Garante nome consistente e deixa claro que o perfil e do CompartDisk.
        $rename = Invoke-NativeCommand `
            -FilePath $powercfg `
            -Arguments @('/changename', $Guid, $customName, 'Perfil de energia otimizado pelo CompartDisk para desempenho maximo em AC.') `
            -TimeoutSeconds 30

        if ($rename.ExitCode -ne 0) {
            Write-Log WARN "Nao foi possivel atualizar o nome/descricao do perfil (codigo $($rename.ExitCode))."
        }
        else {
            $Nome = $customName
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
                $configOk = $false
            }
        }

        if (-not $configOk) {
            $script:result = 'WARN'

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

            $script:result = 'WARN'

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

            $script:result = 'WARN'

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
            -Message 'O comando de ativacao foi executado, mas o esquema ativo nao corresponde ao plano solicitado.' `
            -Recommendation 'Verificar os esquemas de energia ativos e possiveis politicas de grupo.'

        if ($atual.StdOut) {
            Write-Output $atual.StdOut.Trim()
        }

        return
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
                $validationOk = $false
            }
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
