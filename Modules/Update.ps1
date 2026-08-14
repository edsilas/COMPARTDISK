<#
 COMPARTDISK 1.3.1 - Update.ps1
 Desenvolvido por Edsilas
 Acoes: Status | History | Reset | Cache | Services | Search

 REGRA DO MODULO
 Nenhuma alteracao e aplicada apenas porque "costuma resolver". Toda operacao
 segue: pre-condicao -> justificativa -> execucao -> validacao -> registro ->
 continuacao ou fallback. "Comando executado" nunca e tratado como "problema
 resolvido": o estado final vem sempre de uma releitura do sistema.

 Compativel com Windows 10 / Windows 11 (x64) e com Windows PowerShell 5.1 e
 PowerShell 7.x. Somente componentes nativos do Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'History', 'Reset', 'Cache', 'Services', 'Search')]
    [string]$Action = 'Status',
    [switch]$Quiet,
    # Winsock NAO faz parte do reset do Windows Update. Permanece disponivel como
    # decisao explicita do operador (Network.ps1 -Action Reset e o dono natural).
    [switch]$ResetWinsock,
    # Reregistro das bibliotecas do agente so ocorre quando o agente COM esta
    # comprovadamente inoperante. Este switch forca a etapa mesmo assim.
    [switch]$ForceLibraryRegistration,
    [ValidateRange(30, 1800)][int]$SearchTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

# ==============================================================================
# ESTADO GLOBAL DO MODULO
# Um unico estado, monotonico: OK -> WARN -> ERROR. Nunca regride.
# Uma etapa parcialmente concluida jamais produz OK.
# ==============================================================================
$script:result     = 'OK'
$script:ResultRank = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-UpdateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        # Position explicita: declarar Position em um parametro tira a posicao
        # implicita dos demais e a chamada posicional falharia em tempo de execucao.
        [Parameter(Position = 1)][string]$Reason = ''
    )
    if ($script:ResultRank[$Level] -gt $script:ResultRank[$script:result]) {
        $script:result = $Level
        Write-Log DEBUG ("Resultado do modulo elevado para {0}{1}" -f $Level, $(if ($Reason) { ": $Reason" } else { '' })) -NoConsole
    }
}

# Severidade de finding derivada do estado global, para nunca haver finding OK
# convivendo com log WARN da mesma operacao.
function Get-UpdateFindingSeverity {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) {
        'OK'    { return 'OK' }
        'WARN'  { return 'WARN' }
        default { return 'CRIT' }
    }
}

function Get-UpdateSectionStatus {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) {
        'OK'    { return 'OK' }
        'WARN'  { return 'WARN' }
        default { return 'CRIT' }
    }
}

# ------------------------------------------------------------------------------
# Registro de etapas: o relatorio mostra o que cada operacao realmente produziu.
# ------------------------------------------------------------------------------
$script:Steps = New-Object System.Collections.ArrayList

function Add-UpdateStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Fase,
        [Parameter(Mandatory)][string]$Operacao,
        [string]$Alvo = '',
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERRO', 'IGNORADO', 'INFO')][string]$Resultado,
        [string]$Detalhe = ''
    )
    [void]$script:Steps.Add([pscustomobject]@{
        Fase      = $Fase
        Operacao  = $Operacao
        Alvo      = $Alvo
        Resultado = $Resultado
        Detalhe   = $Detalhe
    })
}

function Write-UpdateTable {
    [CmdletBinding()]
    param([object[]]$Rows, [string[]]$Property)
    if ($script:Quiet) { return }
    $dados = @($Rows)
    if ($dados.Count -eq 0) { return }
    try {
        if ($Property) { $texto = $dados | Select-Object -Property $Property | Format-Table -AutoSize | Out-String -Width 200 }
        else           { $texto = $dados | Format-Table -AutoSize | Out-String -Width 200 }
        foreach ($linha in ($texto -split "`r?`n")) {
            if ($linha.Trim()) { Write-Color ("  " + $linha) }
        }
    } catch {
        Write-Log DEBUG "Falha ao formatar tabela: $($_.Exception.Message)" -NoConsole
    }
}

function Remove-UpdateComObject {
    # Liberacao best-effort: uma falha aqui nao altera o resultado da operacao
    # que ja foi concluida e o objeto sera coletado no encerramento do processo.
    param([AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return }
    try {
        if ([System.Runtime.InteropServices.Marshal]::IsComObject($InputObject)) {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($InputObject)
        }
    } catch {
        Write-Log DEBUG "Liberacao de objeto COM ignorada: $($_.Exception.Message)" -NoConsole
    }
}

function Get-UpdateHResultString {
    # Cadeia de extracao com fallback explicito: COMException.ErrorCode ->
    # Exception.HResult -> string vazia (tratada como "sem codigo" pelo chamador).
    param([AllowNull()][object]$ErrorRecordOrException)
    $ex = $ErrorRecordOrException
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    if ($null -eq $ex) { return '' }
    $codigo = $null
    try { if ($ex -is [System.Runtime.InteropServices.COMException]) { $codigo = $ex.ErrorCode } } catch { $codigo = $null }
    if ($null -eq $codigo) { try { $codigo = $ex.HResult } catch { $codigo = $null } }
    if ($null -eq $codigo) { return '' }
    try { return ('0x{0:X8}' -f [int]$codigo) } catch { return '' }
}

# Codigos observados com frequencia no agente do Windows Update. A traducao evita
# que uma falha de rede ou de diretiva seja reportada como "sistema atualizado".
$script:WuErrorMap = @{
    '0x80240024' = 'Nenhuma atualizacao aplicavel ao sistema.'
    '0x8024001E' = 'Operacao cancelada: o servico foi parado durante a consulta.'
    '0x8024000B' = 'Chamada cancelada pelo agente de atualizacao.'
    '0x80240438' = 'Consulta bloqueada por diretiva de atualizacao (WUfB/MDM).'
    '0x8024500C' = 'Consulta rejeitada pela configuracao de servico gerenciado (WUfB).'
    '0x8024002E' = 'Acesso ao Windows Update publico desabilitado por diretiva (WSUS obrigatorio).'
    '0x80244022' = 'Servidor de atualizacoes indisponivel (HTTP 503).'
    '0x80244021' = 'Gateway invalido ao contatar o servidor de atualizacoes (HTTP 502).'
    '0x80244019' = 'Recurso nao encontrado no servidor de atualizacoes (HTTP 404).'
    '0x8024401C' = 'Tempo limite HTTP ao contatar o servidor de atualizacoes.'
    '0x8024402C' = 'Falha de proxy ou de resolucao de nome ao contatar o servidor.'
    '0x8024402F' = 'Erro externo de cabecalho/CAB retornado pelo servidor.'
    '0x80248014' = 'Servico de atualizacao desconhecido no armazenamento local.'
    '0x80072EE2' = 'Tempo limite de rede (WinHTTP).'
    '0x80072EE7' = 'Nome do servidor nao pode ser resolvido (DNS).'
    '0x80072EFD' = 'Conexao recusada pelo servidor.'
    '0x80072F8F' = 'Erro de seguranca/TLS: verificar data, hora e cadeia de certificados.'
    '0x80070422' = 'Servico do Windows Update desabilitado.'
    '0x80070005' = 'Acesso negado.'
    '0x800705B4' = 'Tempo limite da operacao.'
    '0x80040154' = 'Classe COM do agente de atualizacao nao registrada.'
    '0x80080005' = 'Falha ao iniciar o servidor COM do agente de atualizacao.'
}

function Get-UpdateErrorDescription {
    param([string]$Code, [string]$Fallback = '')
    if (-not [string]::IsNullOrWhiteSpace($Code) -and $script:WuErrorMap.ContainsKey($Code.ToUpper())) {
        return $script:WuErrorMap[$Code.ToUpper()]
    }
    if ($Fallback) { return $Fallback }
    return 'Causa nao identificada.'
}

# ==============================================================================
# CATALOGO DE SERVICOS
# Cada servico tem papel proprio. msiserver (Windows Installer) e DoSvc
# (Delivery Optimization) NAO sao reconfigurados: o primeiro nao pertence ao
# fluxo de atualizacao e o segundo e opcional - o Windows Update funciona sem
# ele e desabilita-lo e uma decisao administrativa legitima. Ambos sao apenas
# observados e reportados.
#   Manage        : o modulo pode alterar o tipo de inicializacao
#   Desired       : tipo de inicializacao padrao do Windows 10/11
#   ExpectRunning : servicos de inicio sob demanda ficam Stopped legitimamente
#   MinBuild      : build a partir da qual o servico existe
# ==============================================================================
$script:UpdateServiceCatalog = [ordered]@{
    'wuauserv'         = @{ Display = 'Windows Update';                Role = 'Nucleo';        Manage = $true;  Desired = 'Manual';    ExpectRunning = $false; DisabledSeverity = 'CRIT'; MissingSeverity = 'CRIT'; MinBuild = 10240; StopForReset = $true;  StopForCache = $true  }
    'bits'             = @{ Display = 'Transferencia Inteligente';     Role = 'Transferencia'; Manage = $true;  Desired = 'Manual';    ExpectRunning = $false; DisabledSeverity = 'CRIT'; MissingSeverity = 'CRIT'; MinBuild = 10240; StopForReset = $true;  StopForCache = $true  }
    'cryptsvc'         = @{ Display = 'Servicos Criptograficos';       Role = 'Criptografia';  Manage = $true;  Desired = 'Automatic'; ExpectRunning = $true;  DisabledSeverity = 'CRIT'; MissingSeverity = 'CRIT'; MinBuild = 10240; StopForReset = $true;  StopForCache = $false }
    # MissingSeverity CRIT: a ausencia em builds antigas ja e tratada por
    # MinBuild/AplicavelNestaBuild, entao "ausente" aqui e realmente um defeito.
    'UsoSvc'           = @{ Display = 'Orquestrador de Atualizacoes';  Role = 'Orquestracao';  Manage = $true;  Desired = 'Manual';    ExpectRunning = $false; DisabledSeverity = 'CRIT'; MissingSeverity = 'CRIT'; MinBuild = 16299; StopForReset = $true;  StopForCache = $true  }
    'DoSvc'            = @{ Display = 'Otimizacao de Entrega';         Role = 'Distribuicao';  Manage = $false; Desired = 'Automatic'; ExpectRunning = $false; DisabledSeverity = 'INFO'; MissingSeverity = 'INFO'; MinBuild = 10586; StopForReset = $true;  StopForCache = $true  }
    'msiserver'        = @{ Display = 'Windows Installer';             Role = 'Instalador';    Manage = $false; Desired = 'Manual';    ExpectRunning = $false; DisabledSeverity = 'WARN'; MissingSeverity = 'WARN'; MinBuild = 10240; StopForReset = $false; StopForCache = $false }
    'TrustedInstaller' = @{ Display = 'Windows Modules Installer';     Role = 'Servicing';     Manage = $false; Desired = 'Manual';    ExpectRunning = $false; DisabledSeverity = 'CRIT'; MissingSeverity = 'CRIT'; MinBuild = 10240; StopForReset = $false; StopForCache = $false }
}
# Mantido para compatibilidade de leitura com o restante do modulo.
$script:servicos = @($script:UpdateServiceCatalog.Keys)

function ConvertFrom-UpdateStartMode {
    param([AllowNull()][object]$Value)
    switch ("$Value") {
        'Auto'      { return 'Automatic' }
        'Automatic' { return 'Automatic' }
        'Manual'    { return 'Manual' }
        'Disabled'  { return 'Disabled' }
        'Boot'      { return 'Boot' }
        'System'    { return 'System' }
        default     {
            if ([string]::IsNullOrWhiteSpace("$Value")) { return 'n/d' }
            return "$Value"
        }
    }
}

function ConvertFrom-UpdateStartValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'n/d' }
    switch ([int]$Value) {
        0 { return 'Boot' }
        1 { return 'System' }
        2 { return 'Automatic' }
        3 { return 'Manual' }
        4 { return 'Disabled' }
        default { return 'n/d' }
    }
}

# Test-WindowsVersion faz consulta CIM + registro: cacheada por sessao do modulo.
$script:WinVer = $null
function Get-UpdateWindowsInfo {
    [CmdletBinding()] param()
    if ($null -eq $script:WinVer) {
        try { $script:WinVer = Test-WindowsVersion }
        catch { $script:WinVer = [pscustomobject]@{ Family = 'n/d'; Build = 0; FullBuild = 'n/d'; IsWindows11 = $false; IsWindows10 = $false; Supported = $false } }
    }
    return $script:WinVer
}

function Test-UpdateServiceNotFound {
    <# $true quando o erro significa "o servico nao existe"; $false quando a
       consulta em si falhou (SCM inacessivel, permissao, RPC). #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    try {
        if ("$($ErrorRecord.FullyQualifiedErrorId)" -like 'NoServiceFoundForGivenName*') { return $true }
        if ($ErrorRecord.CategoryInfo -and "$($ErrorRecord.CategoryInfo.Category)" -eq 'ObjectNotFound') { return $true }
    } catch {
        Write-Log DEBUG "Classificacao de erro de servico indisponivel: $($_.Exception.Message)" -NoConsole
    }
    if ("$($ErrorRecord.Exception.Message)" -match "Cannot find any service|N.o foi poss.vel localizar") { return $true }
    return $false
}

function Get-UpdateServiceRegistryStart {
    param([Parameter(Mandatory)][string]$Name)
    return (Get-CompartDiskRegistryValue ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $Name) 'Start' $null)
}

# ------------------------------------------------------------------------------
# Snapshot unico dos servicos: uma consulta CIM para todos, em vez de varios
# Get-Service repetidos ao longo do modulo. Releituras pontuais usam
# Sync-UpdateServiceItem (Get-Service + registro), que e barato.
# ------------------------------------------------------------------------------
$script:SvcSnapshot = $null

function Get-UpdateServiceSnapshot {
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:SvcSnapshot -and -not $Refresh) { return $script:SvcSnapshot }

    $cim = @()
    try { $cim = @(Get-CompartDiskCim -Class Win32_Service) } catch { $cim = @() }

    $build = 0
    try { $build = [int](Get-UpdateWindowsInfo).Build } catch { $build = 0 }

    $mapa = [ordered]@{}
    foreach ($nome in @($script:UpdateServiceCatalog.Keys)) {
        $meta = $script:UpdateServiceCatalog[$nome]
        $item = [pscustomobject]@{
            Nome                  = $nome
            Descricao             = $meta.Display
            Papel                 = $meta.Role
            Existe                = $false
            Estado                = 'ausente'
            Inicializacao         = 'n/d'
            InicializacaoRegistro = 'n/d'
            AtrasadoAutomatico    = $false
            Gerenciado            = [bool]$meta.Manage
            Desejado              = $meta.Desired
            EsperadoEmExecucao    = [bool]$meta.ExpectRunning
            AplicavelNestaBuild   = $true
            # ConsultaOk separa "servico nao existe" de "nao foi possivel
            # consultar": tratar os dois como ausencia produziria diagnostico falso.
            ConsultaOk            = $true
            Fonte                 = 'n/d'
            UltimoErro            = ''
        }
        if ($build -gt 0 -and [int]$meta.MinBuild -gt $build) { $item.AplicavelNestaBuild = $false }

        $wmi = $null
        foreach ($c in $cim) { if ("$($c.Name)" -eq $nome) { $wmi = $c; break } }

        if ($wmi) {
            $item.Existe        = $true
            $item.Estado        = "$($wmi.State)"
            $item.Inicializacao = ConvertFrom-UpdateStartMode $wmi.StartMode
            $item.Fonte         = 'CIM'
            # DelayedAutoStart nao existe em todos os provedores: ausencia = $false.
            try { $item.AtrasadoAutomatico = [bool]$wmi.DelayedAutoStart } catch { $item.AtrasadoAutomatico = $false }
        } else {
            try {
                $s = Get-Service -Name $nome -ErrorAction Stop
                $item.Existe = $true
                $item.Estado = "$($s.Status)"
                # ServiceController.StartType pode nao estar disponivel: o valor
                # do registro lido logo abaixo e o fallback autoritativo.
                try { $item.Inicializacao = ConvertFrom-UpdateStartMode $s.StartType } catch { $item.Inicializacao = 'n/d' }
                $item.Fonte  = 'Get-Service'
            } catch {
                $item.ConsultaOk = (Test-UpdateServiceNotFound $_)
                $item.Fonte      = $(if ($item.ConsultaOk) { 'Ausente' } else { 'Consulta indisponivel' })
                $item.UltimoErro = $_.Exception.Message
                if (-not $item.ConsultaOk) {
                    Write-Log DEBUG ("Consulta do servico '{0}' falhou: {1}" -f $nome, $_.Exception.Message) -NoConsole
                }
            }
        }

        $reg = Get-UpdateServiceRegistryStart -Name $nome
        if ($null -ne $reg) {
            $item.InicializacaoRegistro = ConvertFrom-UpdateStartValue $reg
            # O registro e a fonte autoritativa do tipo de inicializacao.
            if ($item.Inicializacao -eq 'n/d') { $item.Inicializacao = $item.InicializacaoRegistro }
        }
        $mapa[$nome] = $item
    }

    $script:SvcSnapshot = $mapa
    return $script:SvcSnapshot
}

function Sync-UpdateServiceItem {
    <# Releitura pontual e barata de um servico apos uma alteracao. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $snap = Get-UpdateServiceSnapshot
    if (-not $snap.Contains($Name)) { return $null }
    $item = $snap[$Name]
    try {
        $s = Get-Service -Name $Name -ErrorAction Stop
        $item.Existe = $true
        $item.Estado = "$($s.Status)"
        try { $item.Inicializacao = ConvertFrom-UpdateStartMode $s.StartType } catch { $item.Inicializacao = 'n/d' }
        $item.Fonte      = 'Get-Service'
        $item.ConsultaOk = $true
    } catch {
        $naoExiste          = Test-UpdateServiceNotFound $_
        $item.ConsultaOk    = $naoExiste
        $item.Existe        = $false
        $item.Estado        = $(if ($naoExiste) { 'ausente' } else { 'consulta indisponivel' })
        $item.Inicializacao = 'n/d'
        $item.Fonte         = $(if ($naoExiste) { 'Ausente' } else { 'Consulta indisponivel' })
        $item.UltimoErro    = $_.Exception.Message
        if (-not $naoExiste) {
            Write-Log WARN ("Nao foi possivel consultar o servico '{0}': {1}" -f $Name, $_.Exception.Message)
        }
    }
    $reg = Get-UpdateServiceRegistryStart -Name $Name
    if ($null -ne $reg) {
        $item.InicializacaoRegistro = ConvertFrom-UpdateStartValue $reg
        if ($item.Inicializacao -eq 'n/d') { $item.Inicializacao = $item.InicializacaoRegistro }
    }
    return $item
}

# ------------------------------------------------------------------------------
# Alteracao do tipo de inicializacao com pre-condicao, execucao e RELEITURA.
# "Set-Service executou" nao e o mesmo que "StartType alterado".
# ------------------------------------------------------------------------------
function Set-UpdateServiceStartType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartType
    )
    $out = [pscustomobject]@{
        Servico = $Name; Antes = 'n/d'; Depois = 'n/d'
        Alterado = $false; Confirmado = $false; Motivo = ''; Erro = ''
    }
    $item = Sync-UpdateServiceItem -Name $Name
    if ($null -eq $item -or -not $item.Existe) {
        $out.Motivo = $(if ($null -ne $item -and -not $item.ConsultaOk) {
            'Servico nao pode ser consultado (SCM indisponivel ou permissao insuficiente)'
        } else { 'Servico inexistente neste sistema' })
        if ($null -ne $item) { $out.Erro = $item.UltimoErro }
        return $out
    }
    $out.Antes = $item.Inicializacao
    if ($item.Inicializacao -eq $StartType) {
        $out.Confirmado = $true
        $out.Depois     = $item.Inicializacao
        $out.Motivo     = 'Ja no tipo desejado (nenhuma alteracao aplicada)'
        return $out
    }

    $r = Invoke-SafeCommand { Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop } `
            -Activity ("Configurar inicializacao de {0} para {1}" -f $Name, $StartType) -Silent
    $depois = Sync-UpdateServiceItem -Name $Name
    $out.Depois = $(if ($depois) { $depois.Inicializacao } else { 'n/d' })

    if (-not $r.Success) {
        $out.Erro   = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        $out.Motivo = 'Alteracao recusada (permissao, ACL do servico ou diretiva de grupo)'
        return $out
    }
    $out.Alterado   = $true
    $out.Confirmado = ($out.Depois -eq $StartType)
    if (-not $out.Confirmado) {
        $out.Motivo = 'Comando aceito, mas a releitura nao confirmou o tipo solicitado'
    }
    return $out
}

# ------------------------------------------------------------------------------
# Start/Stop com pre-condicao e confirmacao de ESTADO (distinto de StartType).
# ------------------------------------------------------------------------------
function Invoke-UpdateServiceTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action,
        [int]$TimeoutSeconds = 45,
        # Servicos do fluxo de atualizacao sao de inicio por gatilho: o
        # Orquestrador religa wuauserv logo apos a parada. Uma nova tentativa
        # curta resolve o religamento pontual sem prolongar a fase quando o
        # servico realmente nao para.
        [int]$RetryOnRestart = 2
    )
    $alvo      = $(if ($Action -eq 'Stop') { 'Stopped' } else { 'Running' })
    $res       = New-Object System.Collections.ArrayList
    $pendentes = New-Object System.Collections.ArrayList

    foreach ($n in $Name) {
        $item = Sync-UpdateServiceItem -Name $n
        $reg  = [pscustomobject]@{
            Servico = $n; Operacao = $Action; Existe = $false
            Antes = 'ausente'; Depois = 'ausente'
            Confirmado = $false; JaNoEstado = $false; Detalhe = ''
        }
        if ($null -eq $item -or -not $item.Existe) {
            $reg.Detalhe = $(if ($null -ne $item -and -not $item.ConsultaOk) {
                ('Consulta indisponivel: {0}' -f $item.UltimoErro)
            } else { 'Servico inexistente' })
            [void]$res.Add($reg); continue
        }
        $reg.Existe = $true
        $reg.Antes  = $item.Estado
        $reg.Depois = $item.Estado

        if ($item.Estado -eq $alvo) {
            $reg.JaNoEstado = $true
            $reg.Confirmado = $true
            $reg.Detalhe    = ('Ja {0}' -f $alvo)
            [void]$res.Add($reg); continue
        }
        if ($Action -eq 'Start' -and $item.Inicializacao -eq 'Disabled') {
            # Pre-condicao ausente: iniciar um servico Disabled falha sempre.
            $reg.Detalhe = 'Inicializacao Disabled: start nao tentado sem reconfiguracao previa'
            [void]$res.Add($reg); continue
        }
        [void]$pendentes.Add($n)
        [void]$res.Add($reg)
    }

    if ($pendentes.Count -gt 0) {
        $core = @(Set-CompartDiskServiceState -Name @($pendentes) -Action $Action -TimeoutSeconds $TimeoutSeconds)
        foreach ($r in $res) {
            if (@($pendentes) -notcontains $r.Servico) { continue }
            $c       = $core | Where-Object { $_.Service -eq $r.Servico } | Select-Object -First 1
            $detCore = $(if ($c) { "$($c.Detail)" } else { '' })
            $okCore  = [bool]($c -and $c.Success)

            $novo         = Sync-UpdateServiceItem -Name $r.Servico
            $r.Depois     = $(if ($novo) { $novo.Estado } else { 'n/d' })
            $r.Confirmado = ($r.Depois -eq $alvo)

            # EVIDENCIA: no reset de 13/08/2026 20:19 a Fase 2 registrou
            # "Servico 'wuauserv' nao parou: Parado" - a parada foi observada
            # pelo Core e a releitura seguinte encontrou o servico de novo em
            # execucao, religado pelo Orquestrador de Atualizacoes. O veredito
            # virava definitivo e a Fase 3 recusava renomear SoftwareDistribution,
            # transformando um religamento momentaneo em ERROR do modulo.
            $tentativas = 0
            if (-not $r.Confirmado -and $Action -eq 'Stop' -and $r.Depois -eq 'Running') {
                while ($tentativas -lt $RetryOnRestart -and -not $r.Confirmado) {
                    $tentativas++
                    Write-Log DEBUG ("Servico '{0}' voltou a Running apos a parada; nova tentativa {1}/{2}." -f $r.Servico, $tentativas, $RetryOnRestart) -NoConsole
                    $re = @(Set-CompartDiskServiceState -Name @($r.Servico) -Action Stop -TimeoutSeconds 15)
                    $cr = $re | Where-Object { $_.Service -eq $r.Servico } | Select-Object -First 1
                    if ($cr) { $detCore = "$($cr.Detail)"; $okCore = [bool]$cr.Success }
                    $novo         = Sync-UpdateServiceItem -Name $r.Servico
                    $r.Depois     = $(if ($novo) { $novo.Estado } else { 'n/d' })
                    $r.Confirmado = ($r.Depois -eq $alvo)
                }
            }

            if ($r.Confirmado) {
                $r.Detalhe = $detCore
                if ($tentativas -gt 0) {
                    $r.Detalhe = ('{0} (confirmado apos {1} nova(s) tentativa(s): o servico havia sido religado)' -f $detCore, $tentativas)
                }
                continue
            }

            # Sem confirmacao o detalhe passa a descrever o estado observado, e
            # nao o que o comando disse ter feito: eram justamente esses dois
            # fatos que se contradiziam no log.
            if ($okCore -and -not [string]::IsNullOrWhiteSpace($detCore)) {
                $r.Detalhe = ('o comando concluiu ("{0}"), mas a releitura encontrou {1}' -f $detCore, $r.Depois)
            } elseif (-not [string]::IsNullOrWhiteSpace($detCore)) {
                $r.Detalhe = ('{0} (estado observado: {1})' -f $detCore, $r.Depois)
            } else {
                $r.Detalhe = ('Estado permaneceu {0}' -f $r.Depois)
            }
            if ($tentativas -gt 0) {
                $r.Detalhe = ('{0}; {1} nova(s) tentativa(s) de parada sem efeito' -f $r.Detalhe, $tentativas)
            }
        }
    }
    return @($res)
}

function Get-UpdateRunningDependents {
    <# Stop-Service -Force derruba dependentes. Registra-los antes permite
       restaura-los depois, mantendo a operacao reversivel. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string[]]$Name)
    $out = New-Object System.Collections.ArrayList
    foreach ($n in $Name) {
        try {
            $s = Get-Service -Name $n -ErrorAction Stop
            foreach ($d in @($s.DependentServices)) {
                if ("$($d.Status)" -ne 'Running') { continue }
                if (@($Name) -contains "$($d.Name)") { continue }
                if (@($out) -notcontains "$($d.Name)") { [void]$out.Add("$($d.Name)") }
            }
        } catch {
            Write-Log DEBUG ("Dependentes de '{0}' nao puderam ser enumerados: {1}" -f $n, $_.Exception.Message) -NoConsole
        }
    }
    return @($out)
}

# ==============================================================================
# DIRETIVAS CORPORATIVAS (WSUS / WUfB / MDM)
# O modulo nunca tenta contornar uma diretiva: apenas a detecta e a reporta,
# para que um "falhou" causado por politica nao seja lido como componente
# corrompido.
# ==============================================================================
$script:PolicyInfo = $null

function Get-UpdatePolicyInfo {
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:PolicyInfo -and -not $Refresh) { return $script:PolicyInfo }

    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

    $info = [pscustomobject]@{
        Gerenciado    = $false
        WSUS          = $false
        WUServer      = ''
        UseWUServer   = $null
        NoAutoUpdate  = $null
        AcessoBloqueado = $false
        SemInternet   = $false
        TargetRelease = ''
        MDM           = $false
        Resumo        = 'Nenhuma diretiva de atualizacao detectada'
        Detalhes      = @()
    }
    $detalhes = New-Object System.Collections.ArrayList

    try {
        $info.WUServer      = "$(Get-CompartDiskRegistryValue $wu 'WUServer' '')"
        $info.TargetRelease = "$(Get-CompartDiskRegistryValue $wu 'TargetReleaseVersionInfo' '')"
        $bloqueio           = Get-CompartDiskRegistryValue $wu 'DisableWindowsUpdateAccess' $null
        $semNet             = Get-CompartDiskRegistryValue $wu 'DoNotConnectToWindowsUpdateInternetLocations' $null
        $info.UseWUServer   = Get-CompartDiskRegistryValue $au 'UseWUServer' $null
        $info.NoAutoUpdate  = Get-CompartDiskRegistryValue $au 'NoAutoUpdate' $null

        if (-not [string]::IsNullOrWhiteSpace($info.WUServer)) {
            $info.WSUS = $true
            [void]$detalhes.Add("Servidor WSUS configurado: $($info.WUServer)")
        }
        if ($null -ne $info.UseWUServer -and [int]$info.UseWUServer -eq 1) {
            $info.WSUS = $true
            [void]$detalhes.Add('AU\UseWUServer=1 (cliente direcionado ao servidor interno)')
        }
        if ($null -ne $bloqueio -and [int]$bloqueio -eq 1) {
            $info.AcessoBloqueado = $true
            [void]$detalhes.Add('Acesso do usuario ao Windows Update desabilitado por diretiva')
        }
        if ($null -ne $semNet -and [int]$semNet -eq 1) {
            $info.SemInternet = $true
            [void]$detalhes.Add('Conexao aos servidores publicos do Windows Update bloqueada por diretiva')
        }
        if ($null -ne $info.NoAutoUpdate -and [int]$info.NoAutoUpdate -eq 1) {
            [void]$detalhes.Add('Atualizacoes automaticas desabilitadas por diretiva (AU\NoAutoUpdate=1)')
        }
        if (-not [string]::IsNullOrWhiteSpace($info.TargetRelease)) {
            [void]$detalhes.Add("Versao alvo fixada por diretiva: $($info.TargetRelease)")
        }
    } catch {
        Write-Log DEBUG "Leitura de diretivas do Windows Update: $($_.Exception.Message)" -NoConsole
    }

    try {
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update') {
            $info.MDM = $true
            [void]$detalhes.Add('Configuracao de atualizacao aplicada por MDM/Intune (PolicyManager)')
        }
    } catch {
        Write-Log DEBUG "Leitura de PolicyManager (MDM) indisponivel: $($_.Exception.Message)" -NoConsole
    }

    $info.Detalhes   = @($detalhes)
    $info.Gerenciado = ($info.WSUS -or $info.AcessoBloqueado -or $info.SemInternet -or $info.MDM -or $detalhes.Count -gt 0)
    if ($info.Gerenciado) {
        $info.Resumo = ('Sim ({0})' -f ($detalhes -join ' | '))
    } else {
        $info.Resumo = 'Nao (configuracao local, Microsoft Update publico)'
    }
    $script:PolicyInfo = $info
    return $script:PolicyInfo
}

# ==============================================================================
# AGENTE COM DO WINDOWS UPDATE
# Verificacao estritamente somente-leitura: instanciar a sessao, criar o
# pesquisador e ler o total de historico (consulta local, sem rede).
# ==============================================================================
$script:AgentInfo = $null

function Test-UpdateAgent {
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:AgentInfo -and -not $Refresh) { return $script:AgentInfo }

    $out = [pscustomobject]@{
        SessionOk        = $false
        SearcherOk       = $false
        HistoryCount     = -1
        AutoUpdateOk     = $false
        UltimaBusca      = $null
        UltimaInstalacao = $null
        HResult          = ''
        Erro             = ''
        Descricao        = ''
        Resumo           = 'indisponivel'
    }

    $session = $null; $searcher = $null
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $out.SessionOk = $true
        $searcher = $session.CreateUpdateSearcher()
        $out.SearcherOk = $true
        try { $out.HistoryCount = [int]$searcher.GetTotalHistoryCount() } catch { $out.HistoryCount = -1 }
    } catch {
        $out.HResult   = Get-UpdateHResultString $_
        $out.Erro      = $_.Exception.Message
        $out.Descricao = Get-UpdateErrorDescription -Code $out.HResult -Fallback $out.Erro
        Write-Log DEBUG "Agente COM do Windows Update indisponivel: $($_.Exception.Message)" -NoConsole
    } finally {
        Remove-UpdateComObject $searcher
        Remove-UpdateComObject $session
    }

    $au = $null
    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $out.AutoUpdateOk     = $true
        $out.UltimaBusca      = $au.Results.LastSearchSuccessDate
        $out.UltimaInstalacao = $au.Results.LastInstallationSuccessDate
    } catch {
        Write-Log DEBUG "Microsoft.Update.AutoUpdate indisponivel: $($_.Exception.Message)" -NoConsole
    } finally {
        Remove-UpdateComObject $au
    }

    if ($out.SessionOk -and $out.SearcherOk) { $out.Resumo = 'operacional' }
    elseif ($out.SessionOk)                  { $out.Resumo = 'parcial (sessao criada, pesquisador indisponivel)' }
    else                                     { $out.Resumo = 'inoperante' }

    $script:AgentInfo = $out
    return $script:AgentInfo
}

# ==============================================================================
# PESQUISA DE ATUALIZACOES (somente leitura) COM TEMPO LIMITE
# A chamada COM Search() e sincrona e pode bloquear por minutos. Ela roda em um
# runspace proprio para que o modulo tenha um tempo limite real. Se o runspace
# nao puder ser criado, a busca ocorre em processo e a ausencia de tempo limite
# e registrada explicitamente - nunca silenciada.
# ==============================================================================
# NOTA: este bloco roda em um runspace proprio, sem acesso a Write-Log nem as
# demais funcoes do modulo. Cada try/catch interno protege a leitura de UMA
# propriedade COM opcional e define explicitamente o valor de fallback; a falha
# da operacao como um todo e capturada no catch externo, que preenche HResult e
# Mensagem devolvidos ao chamador.
$script:UpdateSearchBody = {
    param([string]$Criteria, [bool]$IncluirOcultas)

    $out = [pscustomobject]@{
        Ok = $false; HResult = ''; Mensagem = ''
        Updates = @(); Ocultas = -1; OcultasOk = $false
        ServerSelection = -1; ResultCode = -1
    }
    $session = $null; $searcher = $null
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        try { $out.ServerSelection = [int]$searcher.ServerSelection } catch { }

        $res = $searcher.Search($Criteria)
        try { $out.ResultCode = [int]$res.ResultCode } catch { }

        $lista = New-Object System.Collections.ArrayList
        $col   = $res.Updates
        $n     = 0
        try { $n = [int]$col.Count } catch { $n = 0 }
        for ($i = 0; $i -lt $n; $i++) {
            $u  = $col.Item($i)
            $kb = ''
            try {
                $ids = New-Object System.Collections.ArrayList
                for ($k = 0; $k -lt [int]$u.KBArticleIDs.Count; $k++) { [void]$ids.Add('KB' + $u.KBArticleIDs.Item($k)) }
                $kb = (@($ids) -join ', ')
            } catch { $kb = '' }

            $importante = $false
            try { $importante = ([bool]$u.AutoSelectOnWebSites -or [bool]$u.IsMandatory) } catch { }
            $reinicio = $false
            try { $reinicio = ([int]$u.InstallationBehavior.RebootBehavior -ne 0) } catch { }
            $tamanho = 0
            try { $tamanho = [double]$u.MaxDownloadSize } catch { }
            $tipoNum = 1
            try { $tipoNum = [int]$u.Type } catch { $tipoNum = 1 }

            [void]$lista.Add([pscustomobject]@{
                Titulo       = "$($u.Title)"
                Tipo         = $(if ($tipoNum -eq 2) { 'Driver' } else { 'Software' })
                Classe       = $(if ($importante) { 'Importante' } else { 'Opcional' })
                Severidade   = $(if ($u.MsrcSeverity) { "$($u.MsrcSeverity)" } else { 'n/d' })
                Obrigatoria  = $(try { [bool]$u.IsMandatory } catch { $false })
                Baixada      = $(try { [bool]$u.IsDownloaded } catch { $false })
                ExigeReinicio = $reinicio
                TamanhoBytes = $tamanho
                KB           = $kb
            })
        }
        $out.Updates = @($lista)
        $out.Ok      = $true

        if ($IncluirOcultas) {
            # Consulta local (Online=$false): usa o cache do agente, sem rede.
            $s2 = $null
            try {
                $s2 = $session.CreateUpdateSearcher()
                $s2.Online = $false
                $r2 = $s2.Search("IsInstalled=0 and IsHidden=1")
                $out.Ocultas   = [int]$r2.Updates.Count
                $out.OcultasOk = $true
            } catch {
                $out.OcultasOk = $false
            } finally {
                if ($s2) { try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($s2) } catch { } }
            }
        }
    } catch {
        $out.Ok = $false
        $ex = $_.Exception
        $codigo = $null
        try { if ($ex -is [System.Runtime.InteropServices.COMException]) { $codigo = $ex.ErrorCode } } catch { }
        if ($null -eq $codigo) { try { $codigo = $ex.HResult } catch { } }
        if ($null -ne $codigo) { try { $out.HResult = ('0x{0:X8}' -f [int]$codigo) } catch { } }
        $out.Mensagem = $ex.Message
    } finally {
        if ($searcher) { try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($searcher) } catch { } }
        if ($session)  { try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($session) }  catch { } }
    }
    return $out
}

function Invoke-UpdateSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Criteria,
        [int]$TimeoutSeconds = 300,
        [switch]$IncludeHidden
    )
    $saida = [pscustomobject]@{
        Executada = $false; Ok = $false; TempoLimite = $false; Segundos = 0
        Updates = @(); Ocultas = -1; OcultasOk = $false
        HResult = ''; Mensagem = ''; Descricao = ''
        ServerSelection = -1; Metodo = 'n/d'; TimeoutAplicado = $false
    }
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    $rs = $null; $ps = $null; $expirou = $false

    try {
        $rs = [runspacefactory]::CreateRunspace()
        # ApartmentState/ThreadOptions sao otimizacoes: quando o host nao as
        # aceita, o runspace continua valido com os padroes.
        try { $rs.ApartmentState = 'STA' } catch { Write-Log DEBUG "ApartmentState STA indisponivel: $($_.Exception.Message)" -NoConsole }
        try { $rs.ThreadOptions = 'ReuseThread' } catch { Write-Log DEBUG "ThreadOptions indisponivel: $($_.Exception.Message)" -NoConsole }
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:UpdateSearchBody.ToString()).AddArgument($Criteria).AddArgument([bool]$IncludeHidden)

        $saida.Metodo          = 'Runspace isolado'
        $saida.TimeoutAplicado = $true
        $handle = $ps.BeginInvoke()

        if ($handle.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSeconds))) {
            $bruto = @($ps.EndInvoke($handle))
            $obj = $bruto | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Ok' } | Select-Object -First 1
            if ($obj) {
                $saida.Executada       = $true
                $saida.Ok              = [bool]$obj.Ok
                $saida.Updates         = @($obj.Updates)
                $saida.Ocultas         = [int]$obj.Ocultas
                $saida.OcultasOk       = [bool]$obj.OcultasOk
                $saida.HResult         = "$($obj.HResult)"
                $saida.Mensagem        = "$($obj.Mensagem)"
                $saida.ServerSelection = [int]$obj.ServerSelection
            } else {
                $saida.Mensagem = 'A consulta nao retornou resultado utilizavel.'
                if ($ps.Streams -and $ps.Streams.Error.Count -gt 0) {
                    $saida.Mensagem = "$($ps.Streams.Error[0].Exception.Message)"
                }
            }
        } else {
            $expirou            = $true
            $saida.Executada    = $true
            $saida.TempoLimite  = $true
            $saida.Mensagem     = ('A consulta excedeu o tempo limite de {0}s e foi abandonada.' -f $TimeoutSeconds)
            # BeginStop nao bloqueia: uma chamada COM travada nao pode segurar o
            # modulo. O runspace expirado nao e descartado de proposito - Dispose
            # bloquearia ate o COM retornar. Ele morre com o processo.
            try { [void]$ps.BeginStop($null, $null) } catch { Write-Log DEBUG "Cancelamento da busca ignorado: $($_.Exception.Message)" -NoConsole }
        }
    } catch {
        Write-Log DEBUG "Runspace de busca indisponivel: $($_.Exception.Message)" -NoConsole
        # Fallback em processo: preserva a funcionalidade, sem tempo limite.
        $saida.Metodo          = 'Em processo (sem tempo limite aplicavel)'
        $saida.TimeoutAplicado = $false
        try {
            $obj = & $script:UpdateSearchBody $Criteria ([bool]$IncludeHidden)
            $saida.Executada       = $true
            $saida.Ok              = [bool]$obj.Ok
            $saida.Updates         = @($obj.Updates)
            $saida.Ocultas         = [int]$obj.Ocultas
            $saida.OcultasOk       = [bool]$obj.OcultasOk
            $saida.HResult         = "$($obj.HResult)"
            $saida.Mensagem        = "$($obj.Mensagem)"
            $saida.ServerSelection = [int]$obj.ServerSelection
        } catch {
            $saida.Executada = $true
            $saida.HResult   = Get-UpdateHResultString $_
            $saida.Mensagem  = $_.Exception.Message
        }
    } finally {
        $cron.Stop()
        $saida.Segundos = [math]::Round($cron.Elapsed.TotalSeconds, 1)
        if (-not $expirou) {
            try { if ($ps) { $ps.Dispose() } } catch { Write-Log DEBUG "Dispose do pipeline de busca: $($_.Exception.Message)" -NoConsole }
            try { if ($rs) { $rs.Dispose() } } catch { Write-Log DEBUG "Dispose do runspace de busca: $($_.Exception.Message)" -NoConsole }
        }
    }

    if (-not $saida.Ok) {
        $saida.Descricao = Get-UpdateErrorDescription -Code $saida.HResult -Fallback $saida.Mensagem
    }
    return $saida
}

# ==============================================================================
# SOLICITACAO DE NOVA DETECCAO
# Envia a solicitacao ao agente. NUNCA afirma que uma busca terminou nem que
# atualizacoes foram encontradas: o retorno cobre apenas o envio.
# ==============================================================================
function Request-UpdateDetection {
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Solicitada = $false; Metodo = 'n/d'; Detalhe = ''; ExitCode = $null }

    # 1) API COM documentada e suportada em Windows 10 e 11.
    $au = $null
    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $au.DetectNow()
        $out.Solicitada = $true
        $out.Metodo     = 'Microsoft.Update.AutoUpdate.DetectNow'
        $out.Detalhe    = 'Solicitacao de nova deteccao enviada ao agente.'
    } catch {
        $out.Detalhe = ('DetectNow indisponivel: {0}' -f $_.Exception.Message)
        Write-Log DEBUG "AutoUpdate.DetectNow falhou: $($_.Exception.Message)" -NoConsole
    } finally {
        Remove-UpdateComObject $au
    }
    if ($out.Solicitada) { return $out }

    # 2) UsoClient existe a partir do Windows 10 1709. O verbo StartScan foi
    #    descontinuado em builds recentes: o codigo de retorno e conferido e o
    #    resultado e reportado como envio, nao como varredura concluida.
    $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
    if (Test-Path -LiteralPath $uso) {
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $uso -Arguments @('StartScan') -TimeoutSeconds 60 } -Activity 'UsoClient StartScan' -Silent
        if ($r.Success -and $r.Value) {
            $out.ExitCode = $r.Value.ExitCode
            if ([int]$r.Value.ExitCode -eq 0) {
                $out.Solicitada = $true
                $out.Metodo     = 'UsoClient.exe StartScan'
                $out.Detalhe    = 'Solicitacao enviada (verbo sujeito a descontinuacao em builds recentes).'
            } else {
                $out.Detalhe = ('UsoClient retornou {0}. {1}' -f $r.Value.ExitCode, "$($r.Value.StdErr)".Trim())
            }
        } else {
            $out.Detalhe = ('UsoClient nao pode ser executado: {0}' -f $(if ($r.Error) { $r.Error.Exception.Message } else { 'motivo desconhecido' }))
        }
        if ($out.Solicitada) { return $out }
    }

    # 3) wuauclt /detectnow: valido apenas em builds anteriores a 1709. Em
    #    Windows 10 1709+ e Windows 11 o executavel existe mas ignora o verbo,
    #    entao nao e usado - executa-lo produziria um sucesso falso.
    # Build 0 = versao indeterminada: o fallback legado NAO e usado (mais seguro
    # do que executa-lo em uma build onde o verbo seria ignorado).
    $build = 0
    try { $build = [int](Get-UpdateWindowsInfo).Build } catch { $build = 0 }
    $wuauclt = Join-Path $env:SystemRoot 'System32\wuauclt.exe'
    if ($build -gt 0 -and $build -lt 16299 -and (Test-Path -LiteralPath $wuauclt)) {
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $wuauclt -Arguments @('/detectnow') -TimeoutSeconds 60 } -Activity 'wuauclt /detectnow' -Silent
        if ($r.Success -and $r.Value -and [int]$r.Value.ExitCode -eq 0) {
            $out.Solicitada = $true
            $out.Metodo     = 'wuauclt.exe /detectnow'
            $out.Detalhe    = 'Solicitacao enviada (mecanismo legado, build anterior a 1709).'
        }
        if ($r.Value) { $out.ExitCode = $r.Value.ExitCode }
    } elseif (-not $out.Solicitada) {
        $out.Detalhe += ' Nenhum mecanismo de deteccao aplicavel a esta build.'
    }
    return $out
}

# ==============================================================================
# REREGISTRO DAS BIBLIOTECAS DO AGENTE
# Pre-condicao: o agente COM esta comprovadamente inoperante (ou -Force).
# Escopo: apenas os servidores COM do proprio agente. A lista classica inclui
# componentes protegidos pelo WRP (shell32, ole32, oleaut32, urlmon, mshtml,
# msxml, wintrust, rsaenh...) que sao registrados pelo servicing do Windows e
# nao precisam - nem devem - ser reregistrados em Windows 10/11.
# A quantidade de DLLs registradas nao e metrica de sucesso.
# ==============================================================================
function Register-UpdateAgentLibraries {
    [CmdletBinding()] param([switch]$Force)

    $out = [pscustomobject]@{
        Executada = $false; Motivo = ''
        Total = 0; Sucesso = 0; Falha = 0; Ausente = 0
        AgenteAntes = 'n/d'; AgenteDepois = 'n/d'; Detalhes = @()
    }
    $agente = Test-UpdateAgent
    $out.AgenteAntes = $agente.Resumo

    if (-not $Force -and $agente.SessionOk -and $agente.SearcherOk) {
        $out.Motivo = 'Agente COM instanciavel: reregistro dispensavel e por isso nao executado.'
        Add-UpdateStep -Fase 'Fase 4' -Operacao 'Reregistro de bibliotecas' -Alvo 'agente do Windows Update' -Resultado 'IGNORADO' -Detalhe $out.Motivo
        return $out
    }
    $out.Motivo = $(if ($Force) { 'Solicitado explicitamente (-ForceLibraryRegistration).' } else { 'Agente COM inoperante: reregistro justificado.' })

    $regsvr = Join-Path $env:SystemRoot 'System32\regsvr32.exe'
    if (-not (Test-Path -LiteralPath $regsvr)) {
        $out.Motivo = 'regsvr32.exe ausente: etapa nao executada.'
        Add-UpdateStep -Fase 'Fase 4' -Operacao 'Reregistro de bibliotecas' -Alvo 'regsvr32.exe' -Resultado 'WARN' -Detalhe $out.Motivo
        return $out
    }

    $dlls     = @('wuapi.dll', 'wuaueng.dll', 'wups.dll', 'wups2.dll', 'wucltux.dll', 'wuwebv.dll')
    $detalhes = New-Object System.Collections.ArrayList
    $out.Executada = $true

    foreach ($d in $dlls) {
        $caminho = Join-Path $env:SystemRoot "System32\$d"
        $out.Total++
        if (-not (Test-Path -LiteralPath $caminho)) {
            $out.Ausente++
            [void]$detalhes.Add([pscustomobject]@{ Biblioteca = $d; Resultado = 'Ausente'; ExitCode = 'n/d'; Detalhe = 'Nao presente nesta build' })
            continue
        }
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $regsvr -Arguments @('/s', "`"$caminho`"") -TimeoutSeconds 30 } -Activity "regsvr32 $d" -Silent
        if ($r.Success -and $r.Value -and [int]$r.Value.ExitCode -eq 0) {
            $out.Sucesso++
            [void]$detalhes.Add([pscustomobject]@{ Biblioteca = $d; Resultado = 'Registrada'; ExitCode = 0; Detalhe = '' })
        } else {
            $out.Falha++
            $code = $(if ($r.Value) { $r.Value.ExitCode } else { 'n/d' })
            $msg  = ''
            if ($r.Value -and "$($r.Value.StdErr)".Trim()) { $msg = "$($r.Value.StdErr)".Trim() }
            elseif ($r.Error) { $msg = $r.Error.Exception.Message }
            [void]$detalhes.Add([pscustomobject]@{ Biblioteca = $d; Resultado = 'Falha'; ExitCode = $code; Detalhe = $msg })
        }
    }
    $out.Detalhes = @($detalhes)

    # A validacao real nao e a contagem de DLLs, e o agente voltar a instanciar.
    $depois = Test-UpdateAgent -Refresh
    $out.AgenteDepois = $depois.Resumo

    $status = $(if ($out.Falha -eq 0 -and $out.Sucesso -gt 0) { 'OK' } elseif ($out.Sucesso -gt 0) { 'WARN' } else { 'ERRO' })
    Add-UpdateStep -Fase 'Fase 4' -Operacao 'Reregistro de bibliotecas' -Alvo ("{0} biblioteca(s)" -f $out.Total) -Resultado $status `
        -Detalhe ("{0} registrada(s), {1} com falha, {2} ausente(s). Agente: {3} -> {4}" -f $out.Sucesso, $out.Falha, $out.Ausente, $out.AgenteAntes, $out.AgenteDepois)
    return $out
}

# ==============================================================================
# DIAGNOSTICO DOS SERVICOS
# Estado (Running/Stopped) e Inicializacao (Automatic/Manual/Disabled) sao
# propriedades distintas e permanecem separadas no relatorio. Um servico de
# inicio sob demanda parado NAO e problema.
# ==============================================================================
function Get-UpdateServiceDiagnostics {
    [CmdletBinding()] param([switch]$Refresh)
    $snap  = Get-UpdateServiceSnapshot -Refresh:$Refresh
    $linhas = New-Object System.Collections.ArrayList

    foreach ($nome in @($snap.Keys)) {
        $s    = $snap[$nome]
        $meta = $script:UpdateServiceCatalog[$nome]
        $diag = 'OK'
        $obs  = 'Em execucao'

        if (-not $s.Existe) {
            if (-not $s.ConsultaOk) {
                # Consulta falhou: nao afirmar ausencia sem evidencia.
                $diag = 'WARN'; $obs = ('Consulta indisponivel: {0}' -f $s.UltimoErro)
            } elseif (-not $s.AplicavelNestaBuild) {
                $diag = 'INFO'; $obs = 'Nao existe nesta versao do Windows'
            } else {
                $diag = "$($meta.MissingSeverity)"; $obs = 'Servico ausente do sistema'
            }
        } elseif ($s.Inicializacao -eq 'Disabled') {
            $diag = "$($meta.DisabledSeverity)"; $obs = 'Inicializacao desabilitada'
        } elseif ($s.EsperadoEmExecucao -and $s.Estado -ne 'Running') {
            $diag = 'WARN'; $obs = 'Esperado em execucao e esta parado'
        } elseif ($s.Estado -ne 'Running') {
            $diag = 'OK';   $obs = 'Parado (inicio sob demanda: comportamento normal)'
        } elseif ($s.Gerenciado -and $s.Inicializacao -ne $s.Desejado -and $s.Inicializacao -ne 'Automatic') {
            $diag = 'INFO'; $obs = ('Em execucao, inicializacao {0} (padrao {1})' -f $s.Inicializacao, $s.Desejado)
        }

        [void]$linhas.Add([pscustomobject]@{
            Servico       = $s.Nome
            Descricao     = $s.Descricao
            Papel         = $s.Papel
            Estado        = $s.Estado
            Inicializacao = $s.Inicializacao
            Registro      = $s.InicializacaoRegistro
            Gerenciado    = $(if ($s.Gerenciado) { 'Sim' } else { 'Nao (somente observado)' })
            Diagnostico   = $diag
            Observacao    = $obs
        })
    }
    return @($linhas)
}

# ==============================================================================
# ACAO: STATUS  (somente consulta - nao modifica o sistema)
# ==============================================================================
function Show-UpdateStatus {
    Write-Log INFO 'Coletando estado do Windows Update...'

    $info   = Get-CompartDiskWindowsUpdateInfo
    $diag   = Get-UpdateServiceDiagnostics -Refresh
    $pol    = Get-UpdatePolicyInfo
    $agente = Test-UpdateAgent

    # Pares de exibicao: as chaves "Servico *" saem daqui porque a tabela de
    # servicos abaixo e mais precisa (estado e inicializacao separados).
    $pares = [ordered]@{}
    foreach ($k in $info.Keys) {
        if ("$k" -like 'Servico *') { continue }
        $pares["$k"] = $info[$k]
    }
    $pares['Agente do Windows Update'] = $agente.Resumo
    if (-not $agente.SearcherOk -and $agente.Descricao) { $pares['Agente - diagnostico'] = $agente.Descricao }
    $pares['Gerenciado por diretiva'] = $pol.Resumo

    foreach ($k in $pares.Keys) {
        $cor = 'Gray'
        $v   = "$($pares[$k])"
        if ($k -eq 'Reinicio pendente' -and $v -eq 'SIM')       { $cor = 'Yellow' }
        if ($k -eq 'Agente do Windows Update' -and $v -ne 'operacional') { $cor = 'Yellow' }
        Write-CompartDiskKeyValue $k $pares[$k] -Color $cor
    }
    Write-Color ''
    Write-UpdateTable -Rows $diag -Property @('Servico', 'Estado', 'Inicializacao', 'Diagnostico', 'Observacao')

    # ---------------- analise ----------------
    $criticos = @($diag | Where-Object { $_.Diagnostico -eq 'CRIT' })
    $alertas  = @($diag | Where-Object { $_.Diagnostico -eq 'WARN' })
    $reboot   = ("$($info['Reinicio pendente'])" -eq 'SIM')

    foreach ($c in $criticos) {
        $rec = 'Executar este modulo com -Action Services para reconfigurar e validar os servicos.'
        if ($c.Observacao -eq 'Servico ausente do sistema') {
            $rec = 'Servico ausente: avaliar reparo de componentes (DISM/SFC) antes de qualquer reset do Windows Update.'
        }
        Add-CompartDiskFinding -Severity CRIT -Area 'Windows Update' `
            -Message ("Servico '{0}' ({1}): {2}." -f $c.Servico, $c.Descricao, $c.Observacao) -Recommendation $rec
    }
    foreach ($a in $alertas) {
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
            -Message ("Servico '{0}' ({1}): {2}." -f $a.Servico, $a.Descricao, $a.Observacao) `
            -Recommendation 'Validar com -Action Services; verificar diretiva de grupo caso persista.'
    }
    if ($criticos.Count -gt 0 -or $alertas.Count -gt 0) {
        Set-UpdateResult 'WARN' 'servicos do Windows Update fora do estado esperado'
    }

    if ($reboot) {
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
            -Message 'Reinicio pendente aguardando conclusao de atualizacoes.' `
            -Recommendation 'Reiniciar o computador. Operacoes de reset ficam incompletas enquanto o reinicio nao ocorre.'
        Set-UpdateResult 'WARN' 'reinicio pendente'
    }

    if (-not $agente.SearcherOk) {
        Add-CompartDiskFinding -Severity CRIT -Area 'Windows Update' `
            -Message ("Agente COM do Windows Update inoperante ({0}): {1}" -f $(if ($agente.HResult) { $agente.HResult } else { 'sem codigo' }), $agente.Descricao) `
            -Recommendation 'Executar -Action Reset. O reset reregistra as bibliotecas do agente quando o COM esta inoperante.'
        Set-UpdateResult 'WARN' 'agente COM indisponivel'
    }

    if ($pol.Gerenciado) {
        Add-CompartDiskFinding -Severity INFO -Area 'Windows Update' `
            -Message ('Atualizacoes controladas por diretiva corporativa: {0}' -f ($pol.Detalhes -join ' | ')) `
            -Recommendation 'Alteracoes locais podem ser revertidas pela diretiva. Tratar com a equipe responsavel pela gestao.'
    }

    if ($criticos.Count -eq 0 -and $alertas.Count -eq 0 -and -not $reboot -and $agente.SearcherOk) {
        Add-CompartDiskFinding -Severity OK -Area 'Windows Update' `
            -Message 'Servicos, agente e estado de reinicio do Windows Update conformes.'
    }

    Add-CompartDiskSection -Title 'Windows Update' -Status (Get-UpdateSectionStatus $script:result) -Pairs $pares `
        -Summary ("Servicos: {0} critico(s), {1} alerta(s) | Agente: {2} | Reinicio pendente: {3}" -f `
            $criticos.Count, $alertas.Count, $agente.Resumo, $(if ($reboot) { 'SIM' } else { 'Nao' }))
    Add-CompartDiskSection -Title 'Servicos do Windows Update' -Status (Get-UpdateSectionStatus $script:result) `
        -Rows $diag -Summary ("{0} servico(s) avaliado(s)" -f @($diag).Count)

    Write-Log OK 'Status do Windows Update coletado (consulta somente leitura).'
}

# ==============================================================================
# ACAO: HISTORY  (somente consulta)
# Historico vazio NAO e falha: pode ser sistema recem-instalado ou historico
# limpo. Consulta indisponivel e outra coisa - e distinguida abaixo.
# ==============================================================================
function Show-UpdateHistory {
    Write-Log INFO 'Consultando historico de atualizacoes (API COM nativa)...'
    $hist   = @(Get-CompartDiskUpdateHistory -Max 60)
    $agente = Test-UpdateAgent

    if ($hist.Count -eq 0) {
        # Distingue "sem historico" de "consulta indisponivel".
        if (-not $agente.SearcherOk) {
            Write-Log WARN ('Consulta de historico indisponivel: {0}' -f $agente.Descricao)
            Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
                -Message ('Historico de atualizacoes nao pode ser consultado ({0}).' -f $agente.Resumo) `
                -Recommendation 'Validar o agente com -Action Status; considerar -Action Reset se o agente estiver inoperante.'
            Add-CompartDiskSection -Title 'Historico de atualizacoes' -Status WARN -Summary 'Consulta indisponivel'
            Set-UpdateResult 'WARN' 'consulta de historico indisponivel'
        } elseif ($agente.HistoryCount -eq 0) {
            Write-Log OK 'O agente respondeu: nao ha registros de historico neste sistema.'
            Add-CompartDiskFinding -Severity INFO -Area 'Windows Update' `
                -Message 'Historico de atualizacoes vazio (agente respondeu, sem registros).' `
                -Recommendation 'Normal em sistema recem-instalado, apos reset do repositorio ou apos limpeza do historico.'
            Add-CompartDiskSection -Title 'Historico de atualizacoes' -Status INFO -Summary 'Sem registros (consulta bem-sucedida)'
        } else {
            Write-Log WARN 'O agente informou registros, mas nenhum pode ser lido.'
            Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
                -Message ("O agente informa {0} registro(s) de historico, porem a leitura nao retornou dados." -f $agente.HistoryCount) `
                -Recommendation 'Repetir a consulta; se persistir, avaliar integridade do repositorio (DataStore) com -Action Reset.'
            Add-CompartDiskSection -Title 'Historico de atualizacoes' -Status WARN -Summary 'Leitura incompleta'
            Set-UpdateResult 'WARN' 'leitura de historico incompleta'
        }
        return
    }

    # Get-CompartDiskUpdateHistory recorre a Win32_QuickFixEngineering quando a
    # API COM falha. Nesse caso todos os registros vem sem codigo e como
    # 'Instalado' - o relatorio precisa dizer que a fonte foi o inventario.
    $viaQfe = ($agente.SearcherOk -eq $false) -or (@($hist | Where-Object { "$($_.Codigo)" -ne 'n/d' }).Count -eq 0)
    $fonte  = $(if ($viaQfe) { 'Inventario de hotfixes (Win32_QuickFixEngineering)' } else { 'API COM do Windows Update' })

    Write-UpdateTable -Rows (@($hist) | Select-Object -First 25)

    $falhas    = @($hist | Where-Object { "$($_.Resultado)" -eq 'Falha' })
    $parciais  = @($hist | Where-Object { "$($_.Resultado)" -eq 'SucessoComErros' })
    $cancelados= @($hist | Where-Object { "$($_.Resultado)" -eq 'Cancelado' })

    $status = 'INFO'
    if ($falhas.Count -gt 0) { $status = 'WARN' }
    Add-CompartDiskSection -Title 'Historico de atualizacoes' -Status $status -Rows @($hist) `
        -Summary ("{0} registro(s) | fonte: {1} | {2} falha(s), {3} parcial(is), {4} cancelada(s)" -f `
            $hist.Count, $fonte, $falhas.Count, $parciais.Count, $cancelados.Count)

    if ($viaQfe) {
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
            -Message 'Historico obtido pelo inventario de hotfixes: a API de historico do Windows Update nao respondeu.' `
            -Recommendation 'O inventario nao registra falhas de instalacao. Validar o agente com -Action Status.'
        Set-UpdateResult 'WARN' 'historico obtido apenas por fallback'
    }

    if ($falhas.Count -eq 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Windows Update' `
            -Message ("Nenhuma falha registrada nos {0} registro(s) mais recentes do historico." -f $hist.Count)
        Write-Log OK ("Historico consultado: {0} registro(s), nenhuma falha." -f $hist.Count)
    } else {
        Set-UpdateResult 'WARN' 'falhas registradas no historico'

        # Agrupa por codigo: um unico finding consolidado em vez de dezenas iguais.
        $grupos = $falhas | Group-Object -Property Codigo | Sort-Object -Property Count -Descending
        $resumo = New-Object System.Collections.ArrayList
        foreach ($g in $grupos) {
            $exemplo = $g.Group | Select-Object -First 1
            [void]$resumo.Add([pscustomobject]@{
                Codigo     = "$($g.Name)"
                Ocorrencias= $g.Count
                Descricao  = (Get-UpdateErrorDescription -Code "$($g.Name)" -Fallback 'Codigo nao mapeado: consultar a base de erros do Windows Update.')
                Exemplo    = "$($exemplo.Titulo)"
                DataRecente= "$($exemplo.Data)"
            })
        }
        Add-CompartDiskSection -Title 'Falhas de atualizacao por codigo' -Status WARN -Rows @($resumo) `
            -Summary ("{0} falha(s) em {1} codigo(s) distinto(s)" -f $falhas.Count, @($resumo).Count)
        Write-UpdateTable -Rows @($resumo)

        $topo = ($resumo | Select-Object -First 5 | ForEach-Object { ('{0} x{1}' -f $_.Codigo, $_.Ocorrencias) }) -join ', '
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
            -Message ("{0} atualizacao(oes) com falha no historico. Codigos mais frequentes: {1}." -f $falhas.Count, $topo) `
            -Recommendation ('Na ordem: 1) identificar o codigo de erro; 2) verificar conectividade e proxy; ' +
                             '3) verificar espaco livre no volume do sistema; 4) verificar reinicio pendente; ' +
                             '5) verificar o servicing (DISM /RestoreHealth e SFC); somente entao considerar -Action Reset.')
        Write-Log WARN ("{0} atualizacao(oes) com falha no historico ({1} codigo(s) distinto(s))." -f $falhas.Count, @($resumo).Count)
    }

    if ($parciais.Count -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
            -Message ("{0} atualizacao(oes) concluida(s) com erros (SucessoComErros)." -f $parciais.Count) `
            -Recommendation 'Verificar o log CBS e reexecutar a atualizacao apos reiniciar.'
        Set-UpdateResult 'WARN' 'atualizacoes com sucesso parcial'
    }
}

# ==============================================================================
# ACAO: SEARCH  (somente consulta - nao instala nada)
# ==============================================================================
function Search-PendingUpdates {
    $pol    = Get-UpdatePolicyInfo
    $agente = Test-UpdateAgent

    if ($pol.Gerenciado) {
        Write-Log INFO ('Diretiva de atualizacao detectada: {0}' -f ($pol.Detalhes -join ' | '))
    }
    if (-not $agente.SearcherOk) {
        Write-Log WARN ('Agente do Windows Update inoperante: {0}' -f $agente.Descricao)
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
            -Message ('Busca nao realizada: o agente do Windows Update esta {0}.' -f $agente.Resumo) `
            -Recommendation 'Executar -Action Status para diagnostico e -Action Reset se o agente permanecer inoperante.'
        Add-CompartDiskSection -Title 'Atualizacoes pendentes' -Status WARN -Summary 'Consulta nao realizada (agente inoperante)'
        Set-UpdateResult 'WARN' 'agente indisponivel para busca'
        return
    }

    Write-Log INFO ("Procurando atualizacoes pendentes (tempo limite de {0}s)..." -f $script:SearchTimeoutSeconds)
    $busca = Invoke-UpdateSearch -Criteria "IsInstalled=0 and Type='Software' and IsHidden=0" `
                                 -TimeoutSeconds $script:SearchTimeoutSeconds -IncludeHidden

    $origem = switch ([int]$busca.ServerSelection) {
        0 { 'Padrao do cliente' }
        1 { 'Servidor gerenciado (WSUS/ConfigMgr)' }
        2 { 'Windows Update publico' }
        3 { 'Servico de terceiros' }
        default { 'n/d' }
    }

    $pares = [ordered]@{
        'Consulta'              = $busca.Metodo
        'Tempo limite aplicado' = $(if ($busca.TimeoutAplicado) { "Sim ($script:SearchTimeoutSeconds s)" } else { 'Nao (execucao em processo)' })
        'Duracao'               = ('{0} s' -f $busca.Segundos)
        'Origem das atualizacoes' = $origem
        'Gerenciado por diretiva' = $pol.Resumo
    }

    # ---------------- consulta falhou ou expirou ----------------
    if (-not $busca.Ok) {
        $motivo = $(if ($busca.TempoLimite) { $busca.Mensagem } else { $busca.Descricao })
        $pares['Resultado'] = 'Consulta nao concluida'
        $pares['Codigo']    = $(if ($busca.HResult) { $busca.HResult } else { 'n/d' })
        $pares['Detalhe']   = $motivo

        Write-Log WARN ('Busca por atualizacoes nao concluida: {0}' -f $motivo)
        Add-CompartDiskSection -Title 'Atualizacoes pendentes' -Status WARN -Pairs $pares -Summary 'Consulta nao concluida'

        $rec = 'Validar conectividade e proxy, o servico wuauserv e o horario do sistema; repetir a consulta.'
        if ($pol.WSUS)        { $rec = 'Cliente direcionado a servidor interno (WSUS): validar disponibilidade do servidor e a diretiva aplicada.' }
        if ($pol.SemInternet) { $rec = 'Diretiva bloqueia os servidores publicos do Windows Update: a consulta depende da infraestrutura interna.' }
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
            -Message ('Busca por atualizacoes nao concluida ({0}): {1}' -f $(if ($busca.HResult) { $busca.HResult } else { 'sem codigo' }), $motivo) `
            -Recommendation $rec
        Set-UpdateResult 'WARN' 'busca por atualizacoes nao concluida'
        return
    }

    # ---------------- consulta concluida ----------------
    $updates = @($busca.Updates)
    if ($busca.OcultasOk -and $busca.Ocultas -gt 0) { $pares['Atualizacoes ocultas'] = $busca.Ocultas }

    if ($updates.Count -eq 0) {
        $pares['Resultado'] = 'Nenhuma atualizacao pendente'
        Write-Log OK 'Consulta concluida: nenhuma atualizacao pendente para este sistema.'
        Add-CompartDiskSection -Title 'Atualizacoes pendentes' -Status OK -Pairs $pares -Summary 'Nenhuma pendente'
        $msg = 'Consulta concluida com sucesso: nenhuma atualizacao pendente.'
        if ($pol.Gerenciado) { $msg += ' O escopo do que e oferecido e definido pela diretiva vigente.' }
        Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message $msg
        if ($busca.OcultasOk -and $busca.Ocultas -gt 0) {
            Add-CompartDiskFinding -Severity INFO -Area 'Windows Update' `
                -Message ("{0} atualizacao(oes) estao ocultas e por isso nao aparecem como pendentes." -f $busca.Ocultas) `
                -Recommendation 'Reexibir pelo Windows Update caso a ocultacao nao seja intencional.'
        }
        return
    }

    $exibicao = @($updates | ForEach-Object {
        [pscustomobject]@{
            Titulo     = $_.Titulo
            Classe     = $_.Classe
            Severidade = $_.Severidade
            Tamanho    = (ConvertTo-CompartDiskSize $_.TamanhoBytes)
            Baixada    = $(if ($_.Baixada) { 'Sim' } else { 'Nao' })
            Reinicio   = $(if ($_.ExigeReinicio) { 'Possivel' } else { 'Nao' })
            KB         = $_.KB
        }
    })
    $importantes = @($updates | Where-Object { $_.Classe -eq 'Importante' })
    $opcionais   = @($updates | Where-Object { $_.Classe -eq 'Opcional' })
    $bytes       = 0
    foreach ($u in $updates) { $bytes += [double]$u.TamanhoBytes }

    $pares['Resultado']   = ('{0} atualizacao(oes) pendente(s)' -f $updates.Count)
    $pares['Importantes'] = $importantes.Count
    $pares['Opcionais']   = $opcionais.Count
    $pares['Download total estimado'] = (ConvertTo-CompartDiskSize $bytes)

    Write-UpdateTable -Rows $exibicao
    Add-CompartDiskSection -Title 'Atualizacoes pendentes' -Status WARN -Rows @($exibicao) -Pairs $pares `
        -Summary ("{0} pendente(s): {1} importante(s), {2} opcional(is)" -f $updates.Count, $importantes.Count, $opcionais.Count)
    Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
        -Message ("{0} atualizacao(oes) pendente(s): {1} importante(s) e {2} opcional(is), {3} de download estimado." -f `
            $updates.Count, $importantes.Count, $opcionais.Count, (ConvertTo-CompartDiskSize $bytes)) `
        -Recommendation 'Instalar por Configuracoes > Windows Update. Este modulo nao instala atualizacoes.'
    Set-UpdateResult 'WARN' 'atualizacoes pendentes encontradas'
    Write-Log WARN ("{0} atualizacao(oes) pendente(s)." -f $updates.Count)
}

# ==============================================================================
# ACAO: SERVICES
# Conservadora e idempotente: so altera o tipo de inicializacao quando ele esta
# Disabled, e apenas nos servicos que pertencem ao fluxo de atualizacao.
# msiserver (Windows Installer) e DoSvc (Otimizacao de Entrega) sao observados,
# nunca reconfigurados. Toda alteracao e reconferida por releitura.
# ==============================================================================
function Repair-UpdateServices {
    [CmdletBinding()] param([switch]$AsPhase)

    Write-Log INFO 'Validando servicos do Windows Update...'
    $snap = Get-UpdateServiceSnapshot -Refresh
    $pol  = Get-UpdatePolicyInfo

    $resumo = [pscustomobject]@{
        Avaliados = 0; Gerenciados = 0; JaConformes = 0; Reconfigurados = 0
        NaoReconfigurados = 0; Ausentes = 0; SobDiretiva = 0
        Iniciados = 0; NaoIniciados = 0; Observados = 0
        Operacoes = @(); Nivel = 'OK'
    }
    $ops          = New-Object System.Collections.ArrayList
    $reabilitados = New-Object System.Collections.ArrayList
    $fase         = $(if ($AsPhase) { 'Fase 1.5' } else { 'Services' })

    foreach ($nome in @($snap.Keys)) {
        $s    = $snap[$nome]
        $meta = $script:UpdateServiceCatalog[$nome]
        $resumo.Avaliados++

        if (-not $meta.Manage) {
            $resumo.Observados++
            $obs = $(if ($s.Existe) { ('{0} / {1}' -f $s.Estado, $s.Inicializacao) } else { 'ausente' })
            [void]$ops.Add([pscustomobject]@{
                Servico = $nome; Acao = 'Somente observado'; Antes = $obs; Depois = $obs
                Resultado = 'INFO'; Detalhe = 'Fora do escopo de reconfiguracao deste modulo'
            })
            continue
        }

        $resumo.Gerenciados++

        if (-not $s.Existe) {
            $resumo.Ausentes++
            $det = 'Servico ausente do sistema'
            $rst = 'ERRO'
            if (-not $s.ConsultaOk)              { $det = ('Consulta indisponivel: {0}' -f $s.UltimoErro); $rst = 'ERRO' }
            elseif (-not $s.AplicavelNestaBuild) { $det = 'Nao existe nesta versao do Windows';            $rst = 'INFO' }
            if ($rst -eq 'ERRO') { $resumo.NaoReconfigurados++ }
            [void]$ops.Add([pscustomobject]@{
                Servico = $nome; Acao = 'Reconfigurar'; Antes = 'ausente'; Depois = 'ausente'
                Resultado = $rst; Detalhe = $det
            })
            Add-UpdateStep -Fase $fase -Operacao 'Reconfigurar servico' -Alvo $nome -Resultado $rst -Detalhe $det
            continue
        }

        if ($s.Inicializacao -ne 'Disabled') {
            $resumo.JaConformes++
            $det = 'Nenhuma alteracao necessaria'
            if ($s.Inicializacao -ne $meta.Desired) {
                $det = ('Inicializacao {0} difere do padrao {1}, mas e funcional: preservada' -f $s.Inicializacao, $meta.Desired)
            }
            [void]$ops.Add([pscustomobject]@{
                Servico = $nome; Acao = 'Nenhuma'; Antes = $s.Inicializacao; Depois = $s.Inicializacao
                Resultado = 'OK'; Detalhe = $det
            })
            continue
        }

        # Pre-condicao atendida: servico do fluxo de atualizacao esta Disabled.
        $r = Set-UpdateServiceStartType -Name $nome -StartType $meta.Desired
        if ($r.Confirmado) {
            $resumo.Reconfigurados++
            [void]$reabilitados.Add($nome)
            [void]$ops.Add([pscustomobject]@{
                Servico = $nome; Acao = 'Reconfigurar'; Antes = $r.Antes; Depois = $r.Depois
                Resultado = 'OK'; Detalhe = 'Tipo de inicializacao confirmado por releitura'
            })
            Write-Log OK ("Servico '{0}': inicializacao {1} -> {2} (confirmado)." -f $nome, $r.Antes, $r.Depois)
            Add-UpdateStep -Fase $fase -Operacao 'Reconfigurar servico' -Alvo $nome -Resultado 'OK' -Detalhe ("{0} -> {1}" -f $r.Antes, $r.Depois)
        } else {
            $resumo.NaoReconfigurados++
            $diretiva = ($pol.Gerenciado -or "$($r.Erro)" -match 'nega|denied|0x5\b')
            if ($diretiva) { $resumo.SobDiretiva++ }
            $det = $r.Motivo
            if ($r.Erro) { $det = ('{0} ({1})' -f $r.Motivo, $r.Erro) }
            [void]$ops.Add([pscustomobject]@{
                Servico = $nome; Acao = 'Reconfigurar'; Antes = $r.Antes; Depois = $r.Depois
                Resultado = 'ERRO'; Detalhe = $det
            })
            Write-Log WARN ("Servico '{0}' permaneceu {1}: {2}" -f $nome, $r.Depois, $det)
            Add-UpdateStep -Fase $fase -Operacao 'Reconfigurar servico' -Alvo $nome -Resultado 'ERRO' -Detalhe $det
        }
    }

    # Validacao de execucao: servicos que devem estar em execucao e servicos que
    # acabaram de ser reabilitados (para provar que realmente iniciam).
    $paraIniciar = New-Object System.Collections.ArrayList
    foreach ($nome in @($snap.Keys)) {
        $s = $snap[$nome]
        if (-not $s.Existe -or -not $s.Gerenciado) { continue }
        if ($s.Inicializacao -eq 'Disabled') { continue }
        if ($s.EsperadoEmExecucao -and $s.Estado -ne 'Running') { [void]$paraIniciar.Add($nome); continue }
        if (@($reabilitados) -contains $nome -and $s.Estado -ne 'Running') { [void]$paraIniciar.Add($nome) }
    }

    if ($paraIniciar.Count -gt 0) {
        $tr = Invoke-UpdateServiceTransition -Name @($paraIniciar) -Action Start
        foreach ($t in $tr) {
            if ($t.Confirmado) {
                $resumo.Iniciados++
                Write-Log OK ("Servico '{0}' em execucao (confirmado)." -f $t.Servico)
                Add-UpdateStep -Fase $fase -Operacao 'Iniciar servico' -Alvo $t.Servico -Resultado 'OK' -Detalhe $t.Detalhe
            } else {
                $resumo.NaoIniciados++
                Write-Log WARN ("Servico '{0}' nao iniciou: {1}" -f $t.Servico, $t.Detalhe)
                Add-UpdateStep -Fase $fase -Operacao 'Iniciar servico' -Alvo $t.Servico -Resultado 'ERRO' -Detalhe $t.Detalhe
            }
            [void]$ops.Add([pscustomobject]@{
                Servico = $t.Servico; Acao = 'Iniciar'; Antes = $t.Antes; Depois = $t.Depois
                Resultado = $(if ($t.Confirmado) { 'OK' } else { 'ERRO' }); Detalhe = $t.Detalhe
            })
        }
    }

    $resumo.Operacoes = @($ops)
    if ($resumo.Gerenciados -eq 0) { $resumo.Nivel = 'ERROR' }
    elseif ($resumo.NaoReconfigurados -gt 0 -or $resumo.NaoIniciados -gt 0) { $resumo.Nivel = 'WARN' }

    # Mensagem construida sobre evidencia, nunca um "reconfigurados" generico.
    $partes = New-Object System.Collections.ArrayList
    [void]$partes.Add(("{0} servico(s) do fluxo de atualizacao avaliado(s)" -f $resumo.Gerenciados))
    if ($resumo.JaConformes -gt 0)       { [void]$partes.Add(("{0} ja conforme(s)" -f $resumo.JaConformes)) }
    if ($resumo.Reconfigurados -gt 0)    { [void]$partes.Add(("{0} reconfigurado(s) e validado(s)" -f $resumo.Reconfigurados)) }
    if ($resumo.NaoReconfigurados -gt 0) { [void]$partes.Add(("{0} nao reconfigurado(s)" -f $resumo.NaoReconfigurados)) }
    if ($resumo.SobDiretiva -gt 0)       { [void]$partes.Add(("{0} possivelmente sob diretiva corporativa" -f $resumo.SobDiretiva)) }
    if ($resumo.Iniciados -gt 0)         { [void]$partes.Add(("{0} iniciado(s) e confirmado(s)" -f $resumo.Iniciados)) }
    if ($resumo.NaoIniciados -gt 0)      { [void]$partes.Add(("{0} nao iniciado(s)" -f $resumo.NaoIniciados)) }
    if ($resumo.Ausentes -gt 0)          { [void]$partes.Add(("{0} ausente(s)" -f $resumo.Ausentes)) }
    [void]$partes.Add(("{0} apenas observado(s) (Windows Installer e Otimizacao de Entrega nao sao alterados)" -f $resumo.Observados))
    $mensagem = (($partes -join '; ') + '.')

    if (-not $AsPhase) {
        Write-UpdateTable -Rows @($ops)
        Set-UpdateResult $resumo.Nivel 'resultado da reconfiguracao de servicos'
        Add-CompartDiskSection -Title 'Servicos do Windows Update' -Status (Get-UpdateSectionStatus $resumo.Nivel) `
            -Rows @($ops) -Summary $mensagem
        Add-CompartDiskFinding -Severity (Get-UpdateFindingSeverity $resumo.Nivel) -Area 'Windows Update' `
            -Message $mensagem `
            -Recommendation $(if ($resumo.Nivel -eq 'OK') { '' } else { 'Verificar diretiva de grupo que force o tipo de inicializacao e as permissoes do servico; reexecutar apos reiniciar.' })
        if ($resumo.Nivel -eq 'OK') { Write-Log OK $mensagem } else { Write-Log WARN $mensagem }
    }
    return $resumo
}

# ==============================================================================
# ACAO: CACHE
# Limpa apenas os caches de download. PostRebootEventCache.V2 foi retirado dos
# alvos: guarda estado de conclusao pos-reinicio e nao e cache de download.
# Nenhum diretorio e apagado - apenas o conteudo, preservando a raiz.
# ==============================================================================
function Clear-UpdateCache {
    Write-Log INFO 'Limpando cache de downloads do Windows Update...'
    $snap = Get-UpdateServiceSnapshot -Refresh

    $catalogo = @(
        @{ Nome = 'Download';             Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download');             Servicos = @('wuauserv', 'bits'); Justificativa = 'Pacotes baixados pelo agente do Windows Update.' }
        @{ Nome = 'DeliveryOptimization'; Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\DeliveryOptimization'); Servicos = @('DoSvc');            Justificativa = 'Cache da Otimizacao de Entrega.' }
    )

    $alvos = @($catalogo | Where-Object { Test-Path -LiteralPath $_.Path })
    if ($alvos.Count -eq 0) {
        Write-Log OK 'Nenhum diretorio de cache presente: nada a limpar.'
        Add-CompartDiskSection -Title 'Cache do Windows Update' -Status OK -Summary 'Nenhum cache presente' `
            -Pairs ([ordered]@{ 'Espaco liberado' = '0 B'; 'Diretorios avaliados' = $catalogo.Count })
        Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message 'Nenhum cache de download presente: nenhuma alteracao aplicada.'
        return
    }

    # Servicos necessarios e estado anterior, para restaurar exatamente o que havia.
    $necessarios = New-Object System.Collections.ArrayList
    foreach ($a in $alvos) { foreach ($s in $a.Servicos) { if (@($necessarios) -notcontains $s) { [void]$necessarios.Add($s) } } }
    $estadoAnterior = @{}
    foreach ($n in $necessarios) { $estadoAnterior[$n] = $(if ($snap.Contains($n)) { $snap[$n].Estado } else { 'ausente' }) }

    $parados = Invoke-UpdateServiceTransition -Name @($necessarios) -Action Stop
    foreach ($p in $parados) {
        if ($p.Confirmado) { Write-Log OK ("Servico '{0}' parado (confirmado)." -f $p.Servico) }
        else { Write-Log WARN ("Servico '{0}' nao parou: {1}" -f $p.Servico, $p.Detalhe) }
    }
    $paradosOk = @{}
    foreach ($p in $parados) { $paradosOk[$p.Servico] = [bool]$p.Confirmado }

    $linhas    = New-Object System.Collections.ArrayList
    $total     = 0
    $bloqueados= 0
    $ignorados = 0
    $limpos    = 0

    foreach ($a in $alvos) {
        $pendencia = @($a.Servicos | Where-Object { $paradosOk.ContainsKey($_) -and -not $paradosOk[$_] })
        if ($pendencia.Count -gt 0) {
            # Pre-condicao nao atendida: nao se remove cache com o dono ativo.
            $ignorados++
            $det = ('Servico(s) nao parado(s): {0}' -f ($pendencia -join ', '))
            Write-Log WARN ("'{0}' nao foi limpo. {1}" -f $a.Nome, $det)
            [void]$linhas.Add([pscustomobject]@{
                Diretorio = $a.Nome; Resultado = 'IGNORADO'; Removidos = 0; Bloqueados = 0
                Liberado = '0 B'; Detalhe = $det
            })
            Add-UpdateStep -Fase 'Cache' -Operacao 'Limpar cache' -Alvo $a.Nome -Resultado 'IGNORADO' -Detalhe $det
            continue
        }

        $r = Remove-CompartDiskPathSafely -Path $a.Path -KeepRoot
        $total += [long]$r.BytesFreed
        $restante = ''
        if ([int]$r.Failed -gt 0) {
            $bloqueados += [int]$r.Failed
            $pos = Get-CompartDiskFolderSize -Path $a.Path
            $restante = ('{0} restante(s) em {1}' -f $pos.Files, (ConvertTo-CompartDiskSize $pos.Bytes))
        } else {
            $limpos++
        }
        $rst = $(if ([int]$r.Failed -gt 0) { 'WARN' } else { 'OK' })
        [void]$linhas.Add([pscustomobject]@{
            Diretorio = $a.Nome; Resultado = $rst; Removidos = $r.Removed; Bloqueados = $r.Failed
            Liberado = (ConvertTo-CompartDiskSize $r.BytesFreed); Detalhe = $restante
        })
        if ($rst -eq 'OK') {
            Write-Log OK ("{0}: {1} liberados em {2} item(ns)." -f $a.Nome, (ConvertTo-CompartDiskSize $r.BytesFreed), $r.Removed)
        } else {
            Write-Log WARN ("{0}: {1} liberados, {2} item(ns) bloqueado(s) por processo ativo. {3}" -f `
                $a.Nome, (ConvertTo-CompartDiskSize $r.BytesFreed), $r.Failed, $restante)
        }
        Add-UpdateStep -Fase 'Cache' -Operacao 'Limpar cache' -Alvo $a.Nome -Resultado $rst `
            -Detalhe ("{0} liberados, {1} removido(s), {2} bloqueado(s)" -f (ConvertTo-CompartDiskSize $r.BytesFreed), $r.Removed, $r.Failed)
    }

    # Restauracao: cada servico volta ao estado em que estava, nada alem disso.
    $restaurar = @($necessarios | Where-Object { "$($estadoAnterior[$_])" -eq 'Running' })
    $naoRestaurados = @()
    if ($restaurar.Count -gt 0) {
        $tr = Invoke-UpdateServiceTransition -Name @($restaurar) -Action Start
        $naoRestaurados = @($tr | Where-Object { -not $_.Confirmado })
        foreach ($t in $tr) {
            if ($t.Confirmado) { Add-UpdateStep -Fase 'Cache' -Operacao 'Restaurar servico' -Alvo $t.Servico -Resultado 'OK' -Detalhe 'Estado anterior (Running) restaurado' }
            else {
                Write-Log WARN ("Servico '{0}' nao voltou a executar: {1}" -f $t.Servico, $t.Detalhe)
                Add-UpdateStep -Fase 'Cache' -Operacao 'Restaurar servico' -Alvo $t.Servico -Resultado 'ERRO' -Detalhe $t.Detalhe
            }
        }
    }

    $nivel = 'OK'
    if ($ignorados -gt 0 -or $bloqueados -gt 0 -or $naoRestaurados.Count -gt 0) { $nivel = 'WARN' }
    Set-UpdateResult $nivel 'resultado da limpeza de cache'

    $pares = [ordered]@{
        'Diretorios avaliados'   = $catalogo.Count
        'Diretorios presentes'   = $alvos.Count
        'Diretorios limpos'      = $limpos
        'Diretorios nao limpos'  = $ignorados
        'Itens bloqueados'       = $bloqueados
        'Espaco liberado'        = (ConvertTo-CompartDiskSize $total)
        'Servicos parados'       = (@($parados | Where-Object { $_.Confirmado }).Count)
        'Servicos nao parados'   = (@($parados | Where-Object { -not $_.Confirmado }).Count)
        'Servicos restaurados'   = ($restaurar.Count - $naoRestaurados.Count)
        'Servicos nao restaurados' = $naoRestaurados.Count
        'Status final'           = $nivel
    }
    Write-UpdateTable -Rows @($linhas)
    Add-CompartDiskSection -Title 'Cache do Windows Update' -Status (Get-UpdateSectionStatus $nivel) `
        -Rows @($linhas) -Pairs $pares `
        -Summary ("{0} de {1} diretorio(s) limpo(s); {2} liberados" -f $limpos, $alvos.Count, (ConvertTo-CompartDiskSize $total))

    if ($nivel -eq 'OK') {
        $msg = ("Cache de downloads redefinido: {0} liberados em {1} diretorio(s). Uma nova busca de atualizacoes e recomendada." -f (ConvertTo-CompartDiskSize $total), $limpos)
        Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message $msg `
            -Recommendation 'Executar -Action Search para uma nova deteccao. Limpar cache nao corrige, por si so, uma falha de atualizacao.'
        Write-Log OK $msg
    } else {
        $msg = ("Limpeza parcial do cache: {0} liberados; {1} diretorio(s) nao limpo(s), {2} item(ns) bloqueado(s), {3} servico(s) nao restaurado(s)." -f `
            (ConvertTo-CompartDiskSize $total), $ignorados, $bloqueados, $naoRestaurados.Count)
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message $msg `
            -Recommendation 'Reiniciar o computador e repetir a limpeza; arquivos em uso so sao liberados apos o reinicio.'
        Write-Log WARN $msg
    }
}

# ==============================================================================
# ACAO: RESET
# Reset controlado, em fases, com pre-condicao e validacao em cada etapa.
# O que NAO faz por padrao, e por que:
#  - netsh winsock reset : altera toda a pilha de sockets do sistema e nao faz
#    parte do reset do Windows Update. Falha de atualizacao nao e evidencia de
#    Winsock corrompido. Disponivel via -ResetWinsock; Network.ps1 -Action Reset
#    e o dono natural dessa operacao.
#  - reregistro em massa de DLLs : ver Register-UpdateAgentLibraries.
#  - parar o Windows Installer (msiserver) : abortaria instalacoes MSI em curso
#    e nao e necessario para renomear os repositorios do Windows Update.
# ==============================================================================
function Get-UpdateBackupName {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Name)
    $destino = "$Name.old"
    if (Test-Path -LiteralPath (Join-Path $Parent $destino)) {
        # Backup anterior guarda o estado REAL previo a ferramenta: preservado.
        $destino = '{0}.old_{1}' -f $Name, (Get-Date -Format 'yyyyMMdd_HHmmss')
        $i = 1
        while (Test-Path -LiteralPath (Join-Path $Parent $destino)) {
            $destino = '{0}.old_{1}_{2}' -f $Name, (Get-Date -Format 'yyyyMMdd_HHmmss'), $i
            $i++
            if ($i -gt 50) { break }
        }
    }
    return $destino
}

function Reset-UpdateComponents {
    Write-Log INFO '=== RESET CONTROLADO DOS COMPONENTES DO WINDOWS UPDATE ==='

    # ---------------------------------------------------------------- Fase 1
    $win         = Get-UpdateWindowsInfo
    $pol         = Get-UpdatePolicyInfo
    $agenteAntes = Test-UpdateAgent
    $rebootAntes = Test-CompartDiskPendingReboot
    $snap        = Get-UpdateServiceSnapshot -Refresh

    $existentes = @()
    foreach ($n in @($snap.Keys)) { if ($snap[$n].Existe -and $snap[$n].Gerenciado) { $existentes += $n } }

    Write-Log INFO ("Fase 1/6 - Pre-check: {0} build {1} | agente COM: {2} | reinicio pendente: {3}" -f `
        $win.Family, $win.FullBuild, $agenteAntes.Resumo, $(if ($rebootAntes) { 'SIM' } else { 'Nao' }))
    Add-UpdateStep -Fase 'Fase 1' -Operacao 'Pre-check do sistema' -Alvo ("{0} {1}" -f $win.Family, $win.FullBuild) -Resultado 'INFO' `
        -Detalhe ("Agente COM: {0}; reinicio pendente: {1}; diretiva: {2}" -f $agenteAntes.Resumo, $(if ($rebootAntes) { 'sim' } else { 'nao' }), $pol.Resumo)

    if ($existentes.Count -eq 0) {
        Set-UpdateResult 'ERROR' 'nenhum servico do fluxo de atualizacao encontrado'
        Write-Log ERR 'Nenhum servico do fluxo de atualizacao foi encontrado. Reset abortado antes de qualquer alteracao.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Windows Update' `
            -Message 'Reset abortado: nenhum servico do fluxo de atualizacao existe neste sistema.' `
            -Recommendation 'Avaliar a integridade do Windows com DISM /Online /Cleanup-Image /RestoreHealth e SFC /scannow.'
        Add-CompartDiskSection -Title 'Reset do Windows Update' -Status CRIT -Summary 'Abortado no pre-check' -Rows @($script:Steps)
        return
    }
    if ($rebootAntes) {
        Write-Log WARN 'Reinicio pendente detectado ANTES do reset: parte das validacoes so sera conclusiva apos reiniciar.'
    }
    if ($pol.Gerenciado) {
        Write-Log INFO ('Diretiva de atualizacao ativa: {0}' -f ($pol.Detalhes -join ' | '))
    }

    # -------------------------------------------------------------- Fase 1.5
    $svc = Repair-UpdateServices -AsPhase
    # Repair-UpdateServices reconstroi o snapshot: reancorar a referencia local,
    # senao as fases seguintes leriam um retrato anterior a reconfiguracao.
    $snap = Get-UpdateServiceSnapshot

    # ---------------------------------------------------------------- Fase 2
    $paraParar = @()
    foreach ($n in @($snap.Keys)) {
        if (-not $snap[$n].Existe) { continue }
        if ([bool]$script:UpdateServiceCatalog[$n].StopForReset) { $paraParar += $n }
    }
    $estadoAnterior = @{}
    foreach ($n in $paraParar) { $estadoAnterior[$n] = $snap[$n].Estado }

    $dependentes = @()
    $parados     = @()
    $paradosOk   = @{}
    if ($paraParar.Count -gt 0) {
        $dependentes = Get-UpdateRunningDependents -Name $paraParar
        Write-Log INFO ("Fase 2/6 - Parando servicos: {0}" -f ($paraParar -join ', '))
        $parados = Invoke-UpdateServiceTransition -Name $paraParar -Action Stop -TimeoutSeconds 60
        foreach ($p in $parados) {
            $paradosOk[$p.Servico] = [bool]$p.Confirmado
            if ($p.Confirmado) {
                Add-UpdateStep -Fase 'Fase 2' -Operacao 'Parar servico' -Alvo $p.Servico -Resultado 'OK' -Detalhe $p.Detalhe
            } else {
                Write-Log WARN ("Servico '{0}' nao parou: {1}" -f $p.Servico, $p.Detalhe)
                Add-UpdateStep -Fase 'Fase 2' -Operacao 'Parar servico' -Alvo $p.Servico -Resultado 'ERRO' -Detalhe $p.Detalhe
            }
        }
    } else {
        Write-Log WARN 'Fase 2/6 - Nenhum servico elegivel para parada foi encontrado.'
        Add-UpdateStep -Fase 'Fase 2' -Operacao 'Parar servicos' -Alvo 'fluxo de atualizacao' -Resultado 'WARN' -Detalhe 'Nenhum servico elegivel encontrado'
    }
    $naoPararam = @($parados | Where-Object { -not $_.Confirmado })

    # ---------------------------------------------------------------- Fase 3
    Write-Log INFO 'Fase 3/6 - Backup por renomeacao dos repositorios.'
    $repos = @(
        @{ Nome = 'SoftwareDistribution'; Pai = $env:SystemRoot;                                  Requer = @('wuauserv', 'bits'); Critico = $true  }
        @{ Nome = 'catroot2';             Pai = (Join-Path $env:SystemRoot 'System32');           Requer = @('cryptsvc');         Critico = $false }
    )
    $backups   = New-Object System.Collections.ArrayList
    $renomeados = 0
    $bloqueados = 0
    $ignorados  = 0
    $falhaImpeditiva = $false

    foreach ($r in $repos) {
        $origem = Join-Path $r.Pai $r.Nome
        if (-not (Test-Path -LiteralPath $origem)) {
            $ignorados++
            [void]$backups.Add([pscustomobject]@{ Original = $origem; Backup = '-'; Timestamp = (Get-Date -Format 's'); Operacao = 'Renomear'; Resultado = 'IGNORADO'; Detalhe = 'Diretorio inexistente' })
            Add-UpdateStep -Fase 'Fase 3' -Operacao 'Renomear repositorio' -Alvo $r.Nome -Resultado 'IGNORADO' -Detalhe 'Diretorio inexistente'
            continue
        }

        # Idempotencia: um segundo reset seguido nao deve gerar novos backups de
        # uma pasta que ja esta redefinida e vazia.
        if ($r.Nome -eq 'SoftwareDistribution') {
            $edb      = Join-Path $origem 'DataStore\DataStore.edb'
            $download = Join-Path $origem 'Download'
            $vazia    = (-not (Test-Path -LiteralPath $edb))
            if ($vazia -and (Test-Path -LiteralPath $download)) {
                $c = @(Get-ChildItem -LiteralPath $download -Force -ErrorAction SilentlyContinue)
                if ($c.Count -gt 0) { $vazia = $false }
            }
            if ($vazia) {
                $ignorados++
                $det = 'Repositorio ja em estado redefinido (sem DataStore e sem downloads): renomeacao dispensada'
                Write-Log OK ("'{0}': {1}." -f $r.Nome, $det)
                [void]$backups.Add([pscustomobject]@{ Original = $origem; Backup = '-'; Timestamp = (Get-Date -Format 's'); Operacao = 'Renomear'; Resultado = 'IGNORADO'; Detalhe = $det })
                Add-UpdateStep -Fase 'Fase 3' -Operacao 'Renomear repositorio' -Alvo $r.Nome -Resultado 'IGNORADO' -Detalhe $det
                continue
            }
        }

        # A pre-condicao e reavaliada contra o estado real no momento da
        # renomeacao, e nao contra o retrato da Fase 2. EVIDENCIA: em 13/08/2026
        # 20:19 wuauserv foi religado por gatilho logo apos parar, o veredito da
        # Fase 2 ficou congelado e SoftwareDistribution deixou de ser redefinida
        # mesmo quando ja estava liberada - a mesma renomeacao havia funcionado
        # as 20:06. O servico que continuar em execucao segue bloqueando.
        $suspeitos = @($r.Requer | Where-Object { $paradosOk.ContainsKey($_) -and -not $paradosOk[$_] })
        $pendencia = New-Object System.Collections.ArrayList
        foreach ($s in $suspeitos) {
            $atual = Sync-UpdateServiceItem -Name $s
            $est   = $(if ($atual) { $atual.Estado } else { 'n/d' })
            if ($est -eq 'Stopped') {
                Write-Log INFO ("Servico '{0}' esta parado agora: pre-condicao de '{1}' reavaliada e atendida." -f $s, $r.Nome)
                Add-UpdateStep -Fase 'Fase 3' -Operacao 'Reavaliar pre-condicao' -Alvo $s -Resultado 'OK' `
                    -Detalhe ("Estado no momento da renomeacao de {0}: Stopped" -f $r.Nome)
                continue
            }
            [void]$pendencia.Add(('{0} ({1})' -f $s, $est))
        }
        if ($pendencia.Count -gt 0) {
            # Pre-condicao ausente: renomear com o servico ativo falha ou deixa
            # o repositorio em estado inconsistente.
            $bloqueados++
            if ($r.Critico) { $falhaImpeditiva = $true }
            $det = ('Pre-condicao ausente: {0} nao parou' -f (@($pendencia) -join ', '))
            Write-Log WARN ("'{0}' nao foi renomeada. {1}" -f $r.Nome, $det)
            [void]$backups.Add([pscustomobject]@{ Original = $origem; Backup = '-'; Timestamp = (Get-Date -Format 's'); Operacao = 'Renomear'; Resultado = 'IGNORADO'; Detalhe = $det })
            Add-UpdateStep -Fase 'Fase 3' -Operacao 'Renomear repositorio' -Alvo $r.Nome -Resultado 'IGNORADO' -Detalhe $det
            continue
        }

        $destino = Get-UpdateBackupName -Parent $r.Pai -Name $r.Nome
        $alvoAbs = Join-Path $r.Pai $destino
        $op = Invoke-SafeCommand { Rename-Item -LiteralPath $origem -NewName $destino -ErrorAction Stop } -Activity ("Renomear {0}" -f $r.Nome) -Silent

        # Validacao real: a origem deixou de existir E o backup existe.
        $okRename = ((-not (Test-Path -LiteralPath $origem)) -and (Test-Path -LiteralPath $alvoAbs))
        if ($okRename) {
            $renomeados++
            Write-Log OK ("'{0}' redefinida. Backup preservado em: {1}" -f $r.Nome, $alvoAbs)
            [void]$backups.Add([pscustomobject]@{ Original = $origem; Backup = $alvoAbs; Timestamp = (Get-Date -Format 's'); Operacao = 'Renomear'; Resultado = 'OK'; Detalhe = 'Renomeacao confirmada por releitura' })
            Add-UpdateStep -Fase 'Fase 3' -Operacao 'Renomear repositorio' -Alvo $r.Nome -Resultado 'OK' -Detalhe ("Backup: {0}" -f $alvoAbs)
        } else {
            $bloqueados++
            if ($r.Critico) { $falhaImpeditiva = $true }
            $err = $(if ($op.Error) { $op.Error.Exception.Message } else { 'a origem permaneceu no lugar apos a operacao' })
            Write-Log WARN ("'{0}' esta bloqueada por processo ativo e nao foi redefinida: {1}" -f $r.Nome, $err)
            [void]$backups.Add([pscustomobject]@{ Original = $origem; Backup = '-'; Timestamp = (Get-Date -Format 's'); Operacao = 'Renomear'; Resultado = 'ERRO'; Detalhe = $err })
            Add-UpdateStep -Fase 'Fase 3' -Operacao 'Renomear repositorio' -Alvo $r.Nome -Resultado 'ERRO' -Detalhe $err
            Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' `
                -Message ("Repositorio {0} bloqueado durante o reset e nao foi redefinido." -f $r.Nome) `
                -Recommendation 'Reiniciar o computador e repetir o reset: arquivos em uso so sao liberados apos o reinicio.'
        }
    }

    # ---------------------------------------------------------------- Fase 4
    Write-Log INFO 'Fase 4/6 - Operacoes especificas (executadas somente quando justificadas).'
    $libs = Register-UpdateAgentLibraries -Force:$script:ForceLibraryRegistration
    if ($libs.Executada) {
        if ($libs.Falha -eq 0 -and $libs.Sucesso -gt 0) {
            Write-Log OK ("{0} de {1} biblioteca(s) do agente registrada(s) com sucesso." -f $libs.Sucesso, $libs.Total)
        } else {
            Write-Log WARN ("Registro de bibliotecas do agente: {0} com sucesso, {1} com falha, {2} ausente(s)." -f $libs.Sucesso, $libs.Falha, $libs.Ausente)
        }
    } else {
        Write-Log INFO $libs.Motivo
    }

    $winsock = [pscustomobject]@{ Executado = $false; Ok = $false; Detalhe = 'Nao executado (fora do escopo do reset do Windows Update)' }
    if ($script:ResetWinsock) {
        $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
        if (-not (Test-Path -LiteralPath $netsh)) {
            $winsock.Detalhe = 'netsh.exe ausente'
            Add-UpdateStep -Fase 'Fase 4' -Operacao 'Reset do Winsock' -Alvo 'netsh.exe' -Resultado 'WARN' -Detalhe $winsock.Detalhe
        } else {
            Write-Log WARN 'Reset do Winsock solicitado explicitamente: altera a pilha de sockets de TODO o sistema e exige reinicio.'
            $winsock.Executado = $true
            $rw = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netsh -Arguments @('winsock', 'reset') -TimeoutSeconds 120 } -Activity 'netsh winsock reset' -Silent
            if ($rw.Success -and $rw.Value -and [int]$rw.Value.ExitCode -eq 0) {
                $winsock.Ok = $true
                $winsock.Detalhe = 'Catalogo Winsock redefinido. Reinicio obrigatorio para efetivar.'
                Write-Log OK $winsock.Detalhe
                Add-UpdateStep -Fase 'Fase 4' -Operacao 'Reset do Winsock' -Alvo 'catalogo Winsock' -Resultado 'OK' -Detalhe $winsock.Detalhe
            } else {
                $code = $(if ($rw.Value) { $rw.Value.ExitCode } else { 'n/d' })
                $winsock.Detalhe = ('netsh retornou {0}. {1}' -f $code, $(if ($rw.Value) { "$($rw.Value.StdErr)".Trim() } elseif ($rw.Error) { $rw.Error.Exception.Message } else { '' }))
                Write-Log WARN $winsock.Detalhe
                Add-UpdateStep -Fase 'Fase 4' -Operacao 'Reset do Winsock' -Alvo 'catalogo Winsock' -Resultado 'ERRO' -Detalhe $winsock.Detalhe
            }
        }
    } else {
        Add-UpdateStep -Fase 'Fase 4' -Operacao 'Reset do Winsock' -Alvo 'catalogo Winsock' -Resultado 'IGNORADO' `
            -Detalhe 'Nao faz parte do reset do Windows Update. Usar -ResetWinsock ou Network.ps1 -Action Reset quando houver evidencia de problema de rede.'
    }

    # ---------------------------------------------------------------- Fase 5
    Write-Log INFO 'Fase 5/6 - Restauracao dos servicos.'
    $restaurar = New-Object System.Collections.ArrayList
    foreach ($n in $paraParar) {
        $meta = $script:UpdateServiceCatalog[$n]
        if ("$($estadoAnterior[$n])" -eq 'Running') { [void]$restaurar.Add($n); continue }
        if ([bool]$meta.ExpectRunning) { [void]$restaurar.Add($n); continue }
    }
    # wuauserv e iniciado explicitamente quando o repositorio foi redefinido:
    # e o agente que recria SoftwareDistribution. Justificativa registrada.
    if ($renomeados -gt 0 -and @($restaurar) -notcontains 'wuauserv' -and $snap.Contains('wuauserv') -and $snap['wuauserv'].Existe) {
        [void]$restaurar.Add('wuauserv')
        Write-Log INFO 'wuauserv sera iniciado para recriar o repositorio SoftwareDistribution.'
    }

    $iniciados = 0; $naoIniciados = 0
    if ($restaurar.Count -gt 0) {
        $tr = Invoke-UpdateServiceTransition -Name @($restaurar) -Action Start -TimeoutSeconds 60
        foreach ($t in $tr) {
            if ($t.Confirmado) {
                $iniciados++
                Add-UpdateStep -Fase 'Fase 5' -Operacao 'Iniciar servico' -Alvo $t.Servico -Resultado 'OK' -Detalhe $t.Detalhe
            } else {
                $naoIniciados++
                Write-Log WARN ("Servico '{0}' nao iniciou apos o reset: {1}" -f $t.Servico, $t.Detalhe)
                Add-UpdateStep -Fase 'Fase 5' -Operacao 'Iniciar servico' -Alvo $t.Servico -Resultado 'ERRO' -Detalhe $t.Detalhe
            }
        }
    }
    # Dependentes derrubados por Stop-Service -Force voltam ao ar.
    $depNaoRestaurados = 0
    if (@($dependentes).Count -gt 0) {
        $td = Invoke-UpdateServiceTransition -Name @($dependentes) -Action Start -TimeoutSeconds 60
        foreach ($t in $td) {
            if ($t.Confirmado) {
                Add-UpdateStep -Fase 'Fase 5' -Operacao 'Restaurar dependente' -Alvo $t.Servico -Resultado 'OK' -Detalhe $t.Detalhe
            } else {
                $depNaoRestaurados++
                Write-Log WARN ("Servico dependente '{0}' nao voltou a executar: {1}" -f $t.Servico, $t.Detalhe)
                Add-UpdateStep -Fase 'Fase 5' -Operacao 'Restaurar dependente' -Alvo $t.Servico -Resultado 'ERRO' -Detalhe $t.Detalhe
            }
        }
    }

    # ---------------------------------------------------------------- Fase 6
    Write-Log INFO 'Fase 6/6 - Reavaliacao do estado final.'
    $diagFinal   = Get-UpdateServiceDiagnostics -Refresh
    $agenteDepois= Test-UpdateAgent -Refresh
    $rebootDepois= Test-CompartDiskPendingReboot

    $sdRecriado = $null
    if ($renomeados -gt 0) {
        $sd = Join-Path $env:SystemRoot 'SoftwareDistribution'
        for ($i = 0; $i -lt 5; $i++) {
            if (Test-Path -LiteralPath $sd) { break }
            Start-Sleep -Milliseconds 600
        }
        $sdRecriado = (Test-Path -LiteralPath $sd)
        $det = $(if ($sdRecriado) { 'SoftwareDistribution recriada pelo agente' } else { 'SoftwareDistribution ainda nao recriada: sera recriada na proxima deteccao' })
        Add-UpdateStep -Fase 'Fase 6' -Operacao 'Validar repositorio' -Alvo 'SoftwareDistribution' -Resultado $(if ($sdRecriado) { 'OK' } else { 'INFO' }) -Detalhe $det
    }

    $deteccao = Request-UpdateDetection
    if ($deteccao.Solicitada) {
        Write-Log OK ('Solicitacao de nova deteccao enviada ({0}). O resultado da busca nao e conhecido neste momento.' -f $deteccao.Metodo)
        Add-UpdateStep -Fase 'Fase 6' -Operacao 'Solicitar deteccao' -Alvo $deteccao.Metodo -Resultado 'OK' -Detalhe $deteccao.Detalhe
    } else {
        Write-Log WARN ('Nao foi possivel solicitar nova deteccao: {0}' -f $deteccao.Detalhe)
        Add-UpdateStep -Fase 'Fase 6' -Operacao 'Solicitar deteccao' -Alvo 'agente' -Resultado 'ERRO' -Detalhe $deteccao.Detalhe
    }

    $critFinal = @($diagFinal | Where-Object { $_.Diagnostico -eq 'CRIT' })
    $warnFinal = @($diagFinal | Where-Object { $_.Diagnostico -eq 'WARN' })

    # ------------------------------------------------------- Resultado final
    $nivel = 'OK'
    if ($falhaImpeditiva) { $nivel = 'ERROR' }
    elseif ($bloqueados -gt 0 -or $naoPararam.Count -gt 0 -or $naoIniciados -gt 0 -or $depNaoRestaurados -gt 0 -or
            $svc.Nivel -ne 'OK' -or $critFinal.Count -gt 0 -or $warnFinal.Count -gt 0 -or
            (-not $agenteDepois.SearcherOk) -or (-not $deteccao.Solicitada) -or
            ($libs.Executada -and $libs.Falha -gt 0) -or
            ($winsock.Executado -and -not $winsock.Ok)) { $nivel = 'WARN' }

    $reinicioRecomendado = ($renomeados -gt 0 -or $bloqueados -gt 0 -or $rebootDepois -or ($winsock.Executado -and $winsock.Ok))
    Set-UpdateResult $nivel 'resultado consolidado do reset'

    $pares = [ordered]@{
        'Servicos gerenciados'        = $svc.Gerenciados
        'Servicos reconfigurados'     = $svc.Reconfigurados
        'Servicos nao reconfigurados' = $svc.NaoReconfigurados
        'Servicos parados'            = (@($parados | Where-Object { $_.Confirmado }).Count)
        'Servicos nao parados'        = $naoPararam.Count
        'Servicos iniciados'          = $iniciados
        'Servicos nao iniciados'      = $naoIniciados
        'Dependentes nao restaurados' = $depNaoRestaurados
        'Repositorios renomeados'     = $renomeados
        'Repositorios bloqueados'     = $bloqueados
        'Repositorios dispensados'    = $ignorados
        'Backups criados'             = (@($backups | Where-Object { $_.Resultado -eq 'OK' }).Count)
        'Bibliotecas processadas'     = $(if ($libs.Executada) { $libs.Total } else { 0 })
        'Bibliotecas registradas'     = $(if ($libs.Executada) { $libs.Sucesso } else { 0 })
        'Bibliotecas com falha'       = $(if ($libs.Executada) { $libs.Falha } else { 0 })
        'Reregistro de bibliotecas'   = $(if ($libs.Executada) { 'Executado' } else { $libs.Motivo })
        'Reset do Winsock'            = $(if ($winsock.Executado) { $winsock.Detalhe } else { $winsock.Detalhe })
        'Agente COM antes'            = $agenteAntes.Resumo
        'Agente COM depois'           = $agenteDepois.Resumo
        'Deteccao solicitada'         = $(if ($deteccao.Solicitada) { ('Sim ({0})' -f $deteccao.Metodo) } else { ('Nao: {0}' -f $deteccao.Detalhe) })
        'Reinicio pendente'           = $(if ($rebootDepois) { 'SIM' } else { 'Nao' })
        'Reinicio recomendado'        = $(if ($reinicioRecomendado) { 'SIM' } else { 'Nao' })
        'Diretiva corporativa'        = $pol.Resumo
        'Status final'                = $nivel
    }

    Write-UpdateTable -Rows @($script:Steps)
    Add-CompartDiskSection -Title 'Reset do Windows Update' -Status (Get-UpdateSectionStatus $nivel) -Pairs $pares `
        -Summary ("{0} repositorio(s) redefinido(s), {1} bloqueado(s); agente COM: {2}" -f $renomeados, $bloqueados, $agenteDepois.Resumo)
    Add-CompartDiskSection -Title 'Reset - etapas executadas' -Status (Get-UpdateSectionStatus $nivel) -Rows @($script:Steps) `
        -Summary ("{0} etapa(s) registrada(s)" -f @($script:Steps).Count)
    if (@($backups).Count -gt 0) {
        Add-CompartDiskSection -Title 'Reset - backups dos repositorios' -Status INFO -Rows @($backups) `
            -Summary 'Backups sao preservados: nenhum backup anterior e apagado por este modulo'
    }
    Add-CompartDiskSection -Title 'Reset - estado final dos servicos' -Status (Get-UpdateSectionStatus $nivel) -Rows @($diagFinal) `
        -Summary ("{0} critico(s), {1} alerta(s) apos o reset" -f $critFinal.Count, $warnFinal.Count)

    # A mensagem descreve o que foi EXECUTADO e VALIDADO. Nao afirma correcao.
    $msg = ("Reset executado: {0} repositorio(s) redefinido(s), {1} bloqueado(s), {2} dispensado(s); " -f $renomeados, $bloqueados, $ignorados) +
           ("servicos: {0} reconfigurado(s), {1} iniciado(s), {2} nao iniciado(s); " -f $svc.Reconfigurados, $iniciados, $naoIniciados) +
           ("bibliotecas do agente: {0}; " -f $(if ($libs.Executada) { ('{0}/{1} registradas' -f $libs.Sucesso, $libs.Total) } else { 'nao aplicavel' })) +
           ("agente COM apos o reset: {0}. " -f $agenteDepois.Resumo) +
           'A correcao do Windows Update nao esta comprovada por esta execucao.'

    $rec = 'Executar -Action Search para verificar se a deteccao volta a funcionar.'
    if ($reinicioRecomendado) { $rec = 'Reiniciar o computador e, em seguida, executar -Action Search para verificar a deteccao.' }
    if ($nivel -eq 'ERROR')   { $rec = 'Reiniciar o computador e repetir o reset: o repositorio principal nao pode ser redefinido nesta execucao.' }

    Add-CompartDiskFinding -Severity (Get-UpdateFindingSeverity $nivel) -Area 'Windows Update' -Message $msg -Recommendation $rec
    if ($nivel -eq 'OK') { Write-Log OK $msg } elseif ($nivel -eq 'WARN') { Write-Log WARN $msg } else { Write-Log ERR $msg }
}

# ==============================================================================
# DESPACHO
# Status, History e Search sao somente consulta e nao exigem elevacao.
# Reset, Cache e Services alteram o sistema e exigem administrador.
# ==============================================================================
$codigo = $Global:CompartDisk.Exit.ERROR
try {
    $precisaAdmin = @('Reset', 'Cache', 'Services') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Update' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # Sem isto o estado persistido para o Report.ps1 sairia como OK enquanto
        # o modulo devolvia codigo de erro.
        Set-UpdateResult 'ERROR' 'privilegios administrativos ausentes'
    } else {
        switch ($Action) {
            'Status'   { Show-UpdateStatus }
            'History'  { Show-UpdateHistory }
            'Search'   { Search-PendingUpdates }
            'Services' { Repair-UpdateServices | Out-Null }
            'Cache'    { Clear-UpdateCache }
            'Reset'    { Reset-UpdateComponents }
        }
    }
} catch {
    Set-UpdateResult 'ERROR' 'excecao nao tratada'
    Write-Log ERR "Falha nao tratada no modulo Update (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Windows Update' `
        -Message ("Excecao no modulo durante a acao '{0}': {1}" -f $Action, $_.Exception.Message) `
        -Recommendation 'Consultar o log detalhado da sessao para a etapa exata e o codigo do erro.'
} finally {
    $codigo = Stop-CompartDiskModule -Result $script:result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$script:result] }
}
exit ([int]$codigo)
