<#
 COMPARTDISK 1.3.1 - Drivers.ps1
 Desenvolvido por Edsilas
 Acoes: List | Problems | Backup | Unsigned | Export

 ESCOPO DESTE MODULO
 Diagnostico somente leitura + exportacao de copia dos pacotes de driver.
 O modulo NAO instala, NAO remove, NAO atualiza drivers e NAO altera
 dispositivos ou suas configuracoes. A unica escrita permitida e a acao
 Backup (copia para o destino) e a geracao dos relatorios.

 Compativel com Windows 10 / Windows 11 (x64), Windows PowerShell 5.1 e
 PowerShell 7.x. Somente componentes nativos do Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('List', 'Problems', 'Backup', 'Unsigned', 'Export')]
    [string]$Action = 'List',
    [string]$Path = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'

# ==============================================================================
# ESTADO GLOBAL
# Estado unico e monotonico: OK -> WARN -> ERROR. Nunca regride, e nenhuma
# funcao pode marcar WARN e o finally terminar em OK.
# ==============================================================================
$script:result     = 'OK'
$script:ResultRank = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-DriverResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Position = 1)][string]$Reason = ''
    )
    if ($script:ResultRank[$Level] -gt $script:ResultRank[$script:result]) {
        $script:result = $Level
        Write-Log DEBUG ("Resultado do modulo elevado para {0}{1}" -f $Level, $(if ($Reason) { ": $Reason" } else { '' })) -NoConsole
    }
}

function Get-DriverSectionStatus {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) { 'OK' { return 'OK' } 'WARN' { return 'WARN' } default { return 'CRIT' } }
}

function Get-DriverFindingSeverity {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) { 'OK' { return 'OK' } 'WARN' { return 'WARN' } default { return 'CRIT' } }
}

# Pior severidade de uma lista (para status de secao proporcional).
function Get-DriverWorstSeverity {
    param([string[]]$Severities)
    $rank = @{ 'OK' = 0; 'INFO' = 1; 'WARN' = 2; 'CRIT' = 3 }
    $pior = 'OK'
    foreach ($s in $Severities) {
        if (-not $rank.ContainsKey("$s")) { continue }
        if ($rank["$s"] -gt $rank[$pior]) { $pior = "$s" }
    }
    return $pior
}

# ------------------------------------------------------------------------------
# Apresentacao: -Quiet reduz APENAS a saida interativa. Logs, findings, sections,
# relatorios e resultado permanecem inalterados.
# ------------------------------------------------------------------------------
function Write-DriverTable {
    [CmdletBinding()]
    param([object[]]$Rows, [string[]]$Property, [int]$First = 0)
    if ($script:Quiet) { return }
    $dados = ConvertTo-DriverArray $Rows
    if ($dados.Count -eq 0) { return }
    if ($First -gt 0) { $dados = @($dados | Select-Object -First $First) }
    try {
        if ($Property) { $texto = $dados | Select-Object -Property $Property | Format-Table -AutoSize | Out-String -Width 220 }
        else           { $texto = $dados | Format-Table -AutoSize | Out-String -Width 220 }
        foreach ($linha in ($texto -split "`r?`n")) {
            if ($linha.Trim()) { Write-Color ("  " + $linha) }
        }
    } catch {
        Write-Log DEBUG "Falha ao formatar tabela para exibicao: $($_.Exception.Message)" -NoConsole
    }
}

# ------------------------------------------------------------------------------
# Datas de driver: DriverDate chega como DateTime (CIM) ou string (WMI/texto).
# Ordenar 'yyyy-MM-dd' como texto coloca 'n/d' antes de qualquer data quando
# descendente, e [datetime]::Parse depende da cultura. Conversao explicita.
# ------------------------------------------------------------------------------
function ConvertTo-DriverDate {
    [CmdletBinding()] param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $texto = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($texto) -or $texto -eq 'n/d') { return $null }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $formatos = @('yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss', 'dd/MM/yyyy', 'MM/dd/yyyy', 'yyyyMMdd')
    foreach ($f in $formatos) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($texto, $f, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($texto, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    if ([datetime]::TryParse($texto, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    return $null
}

function Get-DriverSortKey {
    param([AllowNull()][object]$Value)
    $d = ConvertTo-DriverDate $Value
    if ($null -eq $d) { return [datetime]::MinValue }
    return $d
}

function Sort-DriverRows {
    <# Ordenacao deterministica: data real desc, datas desconhecidas por ultimo,
       desempate estavel por nome do dispositivo. #>
    param([object[]]$Rows)
    return @((ConvertTo-DriverArray $Rows) | Sort-Object -Property `
        @{ Expression = { Get-DriverSortKey $_.Data }; Descending = $true }, `
        @{ Expression = { "$($_.Dispositivo)" };       Descending = $false })
}

function ConvertTo-DriverArray {
    <# Uma funcao que devolve @() entrega $null ao chamador (o PowerShell
       desenrola a colecao vazia), e @($null) tem Count 1 - um item fantasma.
       Este e o unico ponto de conversao de retorno para colecao. #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    return @(@($Value) | Where-Object { $null -ne $_ })
}

function Get-DriverSafeText {
    param([AllowNull()][object]$Value, [string]$Default = 'n/d')
    if ($null -eq $Value) { return $Default }
    $t = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
    return $t
}

# ==============================================================================
# INVENTARIO
# Fonte canonica: Get-CompartDiskDriverInfo (Core). Consultado UMA vez por
# execucao e cacheado - List, Unsigned e Export compartilham o mesmo retrato.
#
# Enriquecimento: Get-CompartDiskDriverInfo colapsa IsSigned $null em 'NAO',
# o que transforma "assinatura desconhecida" em "sem assinatura". Uma consulta
# complementar com projecao de propriedades recupera IsSigned bruto, Signer,
# DeviceClass, Description e Status. Ela e executada sob demanda (List,
# Unsigned e Export) e nunca para Problems ou Backup.
# ==============================================================================
$script:InventarioCache  = $null
$script:ProblemasCache   = $null
$script:EnriquecimentoOk = $null

function Test-DriverRepositorioWmi {
    <# Distingue "consulta devolveu zero" de "consulta falhou": sonda barata,
       executada apenas quando o inventario vem vazio. #>
    [CmdletBinding()] param()
    try {
        $cs = Get-CompartDiskCim -Class Win32_ComputerSystem
        return ($null -ne $cs)
    } catch {
        Write-Log DEBUG "Sonda do repositorio WMI falhou: $($_.Exception.Message)" -NoConsole
        return $false
    }
}

function Get-DriverEnriquecimento {
    <# Mapa DeviceName|InfName|Versao -> dados brutos de assinatura/classe. #>
    [CmdletBinding()] param()
    if ($null -ne $script:EnriquecimentoOk) { return $script:EnriquecimentoOk }

    $mapa = @{}
    $ok   = $false
    $consulta = 'SELECT DeviceName, InfName, DriverVersion, IsSigned, Signer, DeviceClass, Description, Status FROM Win32_PnPSignedDriver'
    try {
        $linhas = Get-CompartDiskCim -Query $consulta
        if ($null -ne $linhas) {
            $ok = $true
            foreach ($l in (ConvertTo-DriverArray $linhas)) {
                $chave = ('{0}|{1}|{2}' -f "$($l.DeviceName)", "$($l.InfName)", "$($l.DriverVersion)").ToLowerInvariant()
                if ($mapa.ContainsKey($chave)) { continue }
                $mapa[$chave] = $l
            }
        }
    } catch {
        Write-Log WARN 'Nao foi possivel obter os detalhes de assinatura dos drivers.' -ErrorRecord $_
    }

    $script:EnriquecimentoOk = [pscustomobject]@{ Ok = $ok; Mapa = $mapa; Total = $mapa.Count }
    return $script:EnriquecimentoOk
}

function ConvertTo-DriverAssinatura {
    <# Tres estados honestos. IsSigned $null NAO e o mesmo que $false: a
       primeira e "nao foi possivel determinar", a segunda e "sem assinatura". #>
    param([AllowNull()][object]$Bruto, [string]$FallbackCore = '')
    $out = [pscustomobject]@{ Assinatura = 'Desconhecida'; Signatario = 'n/d' }
    if ($null -ne $Bruto) {
        $signer = Get-DriverSafeText $Bruto.Signer
        $out.Signatario = $signer
        if ($null -eq $Bruto.IsSigned) {
            # Alguns provedores nao populam IsSigned; um Signer presente e
            # evidencia suficiente de assinatura.
            if ($signer -ne 'n/d') { $out.Assinatura = 'Assinado' } else { $out.Assinatura = 'Desconhecida' }
        } elseif ([bool]$Bruto.IsSigned) {
            $out.Assinatura = 'Assinado'
        } else {
            $out.Assinatura = $(if ($signer -ne 'n/d') { 'Assinado' } else { 'Nao assinado' })
        }
        return $out
    }
    # Sem enriquecimento: o valor do Core so permite afirmar "assinado".
    if ($FallbackCore -eq 'Sim') { $out.Assinatura = 'Assinado' } else { $out.Assinatura = 'Desconhecida' }
    return $out
}

function Get-DriverInventory {
    <# Retorna { Ok, Status, Detalhe, Rows, Total, Enriquecido }.
       Status: 'Completo' | 'Parcial' | 'Vazio' | 'Falhou'. #>
    [CmdletBinding()] param([switch]$SemEnriquecimento)
    if ($script:InventarioCache) { return $script:InventarioCache }

    $inv = [pscustomobject]@{
        Ok = $false; Status = 'Falhou'; Detalhe = ''; Rows = @(); Total = 0; Enriquecido = $false
    }

    $r = Invoke-SafeCommand { Get-CompartDiskDriverInfo } -Activity 'Inventario de drivers (Win32_PnPSignedDriver)' -Silent
    if (-not $r.Success) {
        $inv.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        Write-Log ERR 'A consulta de inventario de drivers falhou.' -ErrorRecord $r.Error
        $script:InventarioCache = $inv
        return $inv
    }

    $base = ConvertTo-DriverArray $r.Value
    if ($base.Count -eq 0) {
        # Zero itens nao e o mesmo que falha de coleta.
        if (Test-DriverRepositorioWmi) {
            $inv.Ok = $true; $inv.Status = 'Vazio'
            $inv.Detalhe = 'O repositorio WMI respondeu, porem nenhum driver foi devolvido pela consulta.'
        } else {
            $inv.Status  = 'Falhou'
            $inv.Detalhe = 'O repositorio WMI nao respondeu: o inventario nao pode ser coletado.'
        }
        $script:InventarioCache = $inv
        return $inv
    }

    $enr = $null
    if (-not $SemEnriquecimento) { $enr = Get-DriverEnriquecimento }
    $inv.Enriquecido = ($null -ne $enr -and $enr.Ok)

    $rows = New-Object System.Collections.ArrayList
    foreach ($b in $base) {
        $bruto = $null
        if ($inv.Enriquecido) {
            $chave = ('{0}|{1}|{2}' -f "$($b.Dispositivo)", "$($b.InfName)", "$($b.Versao)").ToLowerInvariant()
            if ($enr.Mapa.ContainsKey($chave)) { $bruto = $enr.Mapa[$chave] }
        }
        $ass = ConvertTo-DriverAssinatura -Bruto $bruto -FallbackCore ("$($b.Assinado)")

        [void]$rows.Add([pscustomobject]@{
            Dispositivo = (Get-DriverSafeText $b.Dispositivo)
            Descricao   = (Get-DriverSafeText $(if ($bruto) { $bruto.Description } else { $null }))
            Fabricante  = (Get-DriverSafeText $b.Fabricante)
            Provedor    = (Get-DriverSafeText $b.Provedor)
            Versao      = (Get-DriverSafeText $b.Versao)
            Data        = (Get-DriverSafeText $b.Data)
            Assinatura  = $ass.Assinatura
            Signatario  = $ass.Signatario
            Estado      = (Get-DriverSafeText $(if ($bruto) { $bruto.Status } else { $null }))
            Classe      = (Get-DriverSafeText $(if ($bruto) { $bruto.DeviceClass } else { $null }))
            InfName     = (Get-DriverSafeText $b.InfName)
        })
    }

    $inv.Rows  = @($rows)
    $inv.Total = $rows.Count
    $inv.Ok    = $true
    if ($inv.Enriquecido) {
        $inv.Status  = 'Completo'
        $inv.Detalhe = 'Inventario coletado com detalhamento de assinatura, classe e estado.'
    } else {
        $inv.Status  = 'Parcial'
        $inv.Detalhe = 'Inventario coletado, porem os detalhes de assinatura/classe nao puderam ser obtidos.'
    }
    $script:InventarioCache = $inv
    return $inv
}

# ==============================================================================
# DISPOSITIVOS COM PROBLEMA
# ==============================================================================
# Severidade proporcional ao codigo. Um dispositivo desabilitado por decisao
# administrativa ou um hardware desconectado NAO sao falhas criticas.
$script:CodigoSeveridade = @{
    1  = 'CRIT'; 3  = 'CRIT'; 10 = 'CRIT'; 12 = 'CRIT'; 19 = 'CRIT'; 31 = 'CRIT'; 39 = 'CRIT'; 41 = 'CRIT'
    14 = 'WARN'; 18 = 'WARN'; 24 = 'WARN'; 28 = 'WARN'; 32 = 'WARN'; 35 = 'WARN'; 37 = 'WARN'; 38 = 'WARN'
    40 = 'WARN'; 42 = 'WARN'; 43 = 'CRIT'; 44 = 'WARN'; 47 = 'WARN'; 48 = 'WARN'; 49 = 'WARN'; 52 = 'WARN'
    21 = 'INFO'; 22 = 'INFO'; 45 = 'INFO'; 46 = 'INFO'
}
$script:CodigoRecomendacao = @{
    1  = 'Dispositivo mal configurado: obter o driver correto junto ao fabricante/OEM.'
    3  = 'Driver corrompido ou memoria insuficiente: validar integridade do sistema antes de substituir o driver.'
    10 = 'O dispositivo nao inicia: verificar driver do fabricante e integridade fisica do hardware.'
    12 = 'Conflito de recursos: revisar a configuracao do firmware/BIOS do equipamento.'
    14 = 'Reiniciar o computador para concluir a instalacao do driver.'
    18 = 'Reinstalacao do driver indicada pelo proprio Windows: usar o pacote do fabricante/OEM.'
    19 = 'Configuracao do driver corrompida no registro: avaliar restauracao do sistema.'
    21 = 'Remocao em andamento: condicao transitoria, reavaliar apos reiniciar.'
    22 = 'Dispositivo desabilitado: confirmar se a desativacao foi intencional antes de reativar.'
    24 = 'Dispositivo ausente ou com falha: confirmar presenca fisica e conexao.'
    28 = 'Driver nao instalado: identificar o hardware e obter o driver do fabricante/OEM.'
    31 = 'O Windows nao pode carregar o driver: validar compatibilidade e assinatura do pacote.'
    43 = 'O dispositivo foi interrompido por reportar problemas: verificar hardware e versao do driver.'
    45 = 'Dispositivo nao conectado: normal para hardware removido; verificar a conexao caso devesse estar presente.'
}

function Get-DriverProblemSeverity {
    param([AllowNull()][object]$Codigo)
    $n = -1
    try { $n = [int]$Codigo } catch { $n = -1 }
    if ($n -lt 0) { return 'WARN' }
    if ($script:CodigoSeveridade.ContainsKey($n)) { return $script:CodigoSeveridade[$n] }
    return 'WARN'
}

function Get-DriverProblemRecommendation {
    param([AllowNull()][object]$Codigo)
    $n = -1
    try { $n = [int]$Codigo } catch { $n = -1 }
    if ($n -ge 0 -and $script:CodigoRecomendacao.ContainsKey($n)) { return $script:CodigoRecomendacao[$n] }
    # Sem mapeamento nao se inventa explicacao: informa-se o codigo bruto.
    return ("Codigo {0} sem interpretacao mapeada: consultar a documentacao do Gerenciador de Dispositivos para este codigo." -f $n)
}

function Get-DriverProblems {
    <# Retorna { Ok, Status, Detalhe, Rows, Total }. #>
    [CmdletBinding()] param()
    if ($script:ProblemasCache) { return $script:ProblemasCache }

    $out = [pscustomobject]@{ Ok = $false; Status = 'Falhou'; Detalhe = ''; Rows = @(); Total = 0 }
    $r = Invoke-SafeCommand { Get-CompartDiskDriverInfo -OnlyProblems } -Activity 'Dispositivos com codigo de erro (Win32_PnPEntity)' -Silent
    if (-not $r.Success) {
        $out.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        Write-Log ERR 'A consulta de dispositivos com problema falhou.' -ErrorRecord $r.Error
        $script:ProblemasCache = $out
        return $out
    }

    $base = ConvertTo-DriverArray $r.Value
    if ($base.Count -eq 0) {
        if (Test-DriverRepositorioWmi) {
            $out.Ok = $true; $out.Status = 'Vazio'
            $out.Detalhe = 'Consulta concluida: nenhum dispositivo com codigo de erro diferente de zero.'
        } else {
            $out.Detalhe = 'O repositorio WMI nao respondeu: nao foi possivel verificar dispositivos com problema.'
        }
        $script:ProblemasCache = $out
        return $out
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($p in $base) {
        $sev = Get-DriverProblemSeverity $p.CodigoErro
        [void]$rows.Add([pscustomobject]@{
            Dispositivo = (Get-DriverSafeText $p.Dispositivo)
            Fabricante  = (Get-DriverSafeText $p.Fabricante)
            Classe      = 'n/d'
            CodigoErro  = (Get-DriverSafeText $p.CodigoErro)
            Descricao   = (Get-DriverSafeText $p.Descricao)
            Estado      = (Get-DriverSafeText $p.Status)
            Severidade  = $sev
            Acao        = (Get-DriverProblemRecommendation $p.CodigoErro)
            DeviceID    = (Get-DriverSafeText $p.DeviceID)
        })
    }
    $out.Rows = @($rows); $out.Total = $rows.Count; $out.Ok = $true; $out.Status = 'Completo'
    $out.Detalhe = ("{0} dispositivo(s) com codigo de erro." -f $rows.Count)
    $script:ProblemasCache = $out
    return $out
}

# ==============================================================================
# ANALISES COMPARTILHADAS (usadas por List, Unsigned e Export)
# ==============================================================================
function Test-DriverInbox {
    <# Driver que acompanha o proprio Windows. Nao e candidato natural a
       "atualizar pelo fabricante". #>
    param([object]$Row)
    $prov = "$($Row.Provedor)"
    $sig  = "$($Row.Signatario)"
    if ($prov -match '^\s*Microsoft') { return $true }
    if ($sig  -match 'Microsoft Windows') { return $true }
    return $false
}

function Get-DriverAgeAnalysis {
    <# Idade e indicador SECUNDARIO: nunca gera CRIT/WARN por si so. #>
    param([object[]]$Rows, [int]$Anos = 5)
    $limite = (Get-Date).AddYears(-$Anos)
    $antigos = New-Object System.Collections.ArrayList
    $semData = 0
    foreach ($r in (ConvertTo-DriverArray $Rows)) {
        $d = ConvertTo-DriverDate $r.Data
        if ($null -eq $d) { $semData++; continue }
        if ($d -lt $limite) { [void]$antigos.Add($r) }
    }
    $terceiros = @(@($antigos) | Where-Object { -not (Test-DriverInbox $_) })
    return [pscustomobject]@{
        Limite = $limite; Antigos = @($antigos); Total = @($antigos).Count
        Terceiros = $terceiros; TotalTerceiros = $terceiros.Count; SemData = $semData
    }
}

function Get-DriverSignatureAnalysis {
    param([object[]]$Rows)
    $todos = ConvertTo-DriverArray $Rows
    $naoAssinados = @($todos | Where-Object { $_.Assinatura -eq 'Nao assinado' })
    $desconhecidos = @($todos | Where-Object { $_.Assinatura -eq 'Desconhecida' })
    $assinados = @($todos | Where-Object { $_.Assinatura -eq 'Assinado' })
    return [pscustomobject]@{
        Assinados = $assinados; NaoAssinados = $naoAssinados; Desconhecidos = $desconhecidos
        TotalAssinados = $assinados.Count; TotalNaoAssinados = $naoAssinados.Count
        TotalDesconhecidos = $desconhecidos.Count
    }
}

function Get-DriverCorrelacao {
    <# Correlaciona sinais: um dispositivo com codigo de erro cujo driver
       tambem nao esta assinado tem prioridade sobre um driver antigo saudavel. #>
    param([object[]]$Problemas, [object[]]$NaoAssinados)
    $cruz = New-Object System.Collections.ArrayList
    foreach ($p in (ConvertTo-DriverArray $Problemas)) {
        foreach ($n in (ConvertTo-DriverArray $NaoAssinados)) {
            if ("$($p.Dispositivo)" -eq "$($n.Dispositivo)") {
                [void]$cruz.Add([pscustomobject]@{
                    Dispositivo = $p.Dispositivo; CodigoErro = $p.CodigoErro
                    Descricao = $p.Descricao; Assinatura = $n.Assinatura
                    Provedor = $n.Provedor; InfName = $n.InfName
                })
                break
            }
        }
    }
    return @($cruz)
}

function Add-DriverInventorySection {
    <# Secao unica de inventario, com status derivado do estado real da coleta. #>
    param([object]$Inventario, [object]$Assinatura)
    $status = 'OK'
    if ($Inventario.Status -ne 'Completo') { $status = 'WARN' }
    elseif ($Assinatura -and $Assinatura.TotalNaoAssinados -gt 0) { $status = 'WARN' }

    $pares = [ordered]@{
        'Drivers enumerados'   = $Inventario.Total
        'Estado da coleta'     = $Inventario.Status
        'Detalhamento'         = $(if ($Inventario.Enriquecido) { 'assinatura, classe e estado disponiveis' } else { 'apenas dados basicos disponiveis' })
    }
    if ($Assinatura) {
        $pares['Assinados']              = $Assinatura.TotalAssinados
        $pares['Sem assinatura']         = $Assinatura.TotalNaoAssinados
        $pares['Assinatura desconhecida']= $Assinatura.TotalDesconhecidos
    }
    Add-CompartDiskSection -Title 'Drivers instalados' -Status $status -Rows (Sort-DriverRows $Inventario.Rows) -Pairs $pares `
        -Summary ("{0} driver(s) | coleta: {1}" -f $Inventario.Total, $Inventario.Status)
}

# ==============================================================================
# ACAO: LIST  (somente consulta)
# ==============================================================================
function Show-Drivers {
    Write-Log INFO 'Coletando inventario de drivers...'
    $inv = Get-DriverInventory

    if (-not $inv.Ok) {
        Write-Log ERR ('Inventario de drivers indisponivel: {0}' -f $inv.Detalhe)
        Add-CompartDiskSection -Title 'Drivers instalados' -Status CRIT -Summary 'Consulta nao concluida'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel enumerar os drivers: {0}' -f $inv.Detalhe) `
            -Recommendation 'Validar o repositorio WMI (winmgmt) e reexecutar a consulta.'
        Set-DriverResult 'ERROR' 'inventario de drivers indisponivel'
        return
    }
    if ($inv.Status -eq 'Vazio') {
        Write-Log WARN 'A consulta concluiu sem devolver nenhum driver.'
        Add-CompartDiskSection -Title 'Drivers instalados' -Status WARN -Summary 'Consulta concluida sem registros'
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message 'A consulta de drivers concluiu sem devolver registros (resultado inconclusivo).' `
            -Recommendation 'Situacao atipica: validar o repositorio WMI e o provedor Win32_PnPSignedDriver.'
        Set-DriverResult 'WARN' 'inventario vazio e inconclusivo'
        return
    }

    $ordenado  = Sort-DriverRows $inv.Rows
    $assinatura = Get-DriverSignatureAnalysis $inv.Rows

    Write-DriverTable -Rows $ordenado -First 40 `
        -Property @('Dispositivo', 'Fabricante', 'Versao', 'Data', 'Assinatura', 'Classe', 'Estado')
    if (-not $script:Quiet) {
        Write-Color ("`n  Total de drivers enumerados: {0}" -f $inv.Total) -Color White
        Write-Color ("  Assinados: {0} | Sem assinatura: {1} | Assinatura desconhecida: {2}" -f `
            $assinatura.TotalAssinados, $assinatura.TotalNaoAssinados, $assinatura.TotalDesconhecidos) -Color Gray
    }

    Add-DriverInventorySection -Inventario $inv -Assinatura $assinatura

    if ($inv.Status -eq 'Parcial') {
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message 'Inventario coletado sem os detalhes de assinatura, classe e estado.' `
            -Recommendation 'A classificacao de assinatura fica inconclusiva nesta execucao; revalidar o provedor WMI Win32_PnPSignedDriver.'
        Set-DriverResult 'WARN' 'inventario parcial'
    }

    # Idade: indicador secundario, sempre INFO e nunca sozinho como problema.
    $idade = Get-DriverAgeAnalysis -Rows $inv.Rows -Anos 5
    if ($idade.Total -gt 0) {
        Write-Log INFO ("{0} driver(s) com data anterior a {1} ({2} fora do conjunto inbox do Windows)." -f $idade.Total, $idade.Limite.Year, $idade.TotalTerceiros)
        Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
            -Message ("{0} driver(s) com data anterior a {1}; {2} nao pertencem ao conjunto inbox do Windows." -f $idade.Total, $idade.Limite.Year, $idade.TotalTerceiros) `
            -Recommendation 'Idade isolada nao indica defeito: drivers inbox e hardware legado permanecem estaveis por anos. Avaliar apenas os de hardware dedicado que apresentem sintoma ou codigo de erro.'
    }
    if ($idade.SemData -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
            -Message ("{0} driver(s) sem data de driver legivel." -f $idade.SemData) `
            -Recommendation 'Campo nao populado pelo provedor: nao indica defeito por si so.'
    }

    Write-Log OK ("{0} driver(s) inventariado(s)." -f $inv.Total)
}

# ==============================================================================
# ACAO: UNSIGNED  (somente consulta)
# ==============================================================================
function Show-Unsigned {
    Write-Log INFO 'Verificando assinatura digital dos drivers...'
    $inv = Get-DriverInventory

    if (-not $inv.Ok) {
        Write-Log ERR ('Verificacao de assinatura indisponivel: {0}' -f $inv.Detalhe)
        Add-CompartDiskSection -Title 'Assinatura digital dos drivers' -Status CRIT -Summary 'Consulta nao concluida'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel verificar a assinatura dos drivers: {0}' -f $inv.Detalhe) `
            -Recommendation 'Validar o repositorio WMI (winmgmt) e reexecutar a consulta.'
        Set-DriverResult 'ERROR' 'verificacao de assinatura indisponivel'
        return
    }
    if ($inv.Status -eq 'Vazio') {
        Write-Log WARN 'A consulta concluiu sem devolver nenhum driver: assinatura inconclusiva.'
        Add-CompartDiskSection -Title 'Assinatura digital dos drivers' -Status WARN -Summary 'Consulta concluida sem registros'
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message 'Verificacao de assinatura inconclusiva: a consulta nao devolveu drivers.' `
            -Recommendation 'Validar o repositorio WMI e o provedor Win32_PnPSignedDriver.'
        Set-DriverResult 'WARN' 'assinatura inconclusiva'
        return
    }

    $a = Get-DriverSignatureAnalysis $inv.Rows
    $pares = [ordered]@{
        'Drivers avaliados'       = $inv.Total
        'Assinados'               = $a.TotalAssinados
        'Sem assinatura'          = $a.TotalNaoAssinados
        'Assinatura desconhecida' = $a.TotalDesconhecidos
        'Base da verificacao'     = $(if ($inv.Enriquecido) { 'IsSigned + Signer (Win32_PnPSignedDriver)' } else { 'somente IsSigned consolidado pelo Core' })
    }

    $status = 'OK'
    if ($a.TotalNaoAssinados -gt 0)      { $status = 'WARN' }
    elseif ($a.TotalDesconhecidos -gt 0) { $status = 'INFO' }

    $linhas = @()
    if ($a.TotalNaoAssinados -gt 0 -or $a.TotalDesconhecidos -gt 0) {
        $linhas = Sort-DriverRows (@($a.NaoAssinados) + @($a.Desconhecidos))
        Write-DriverTable -Rows $linhas -Property @('Dispositivo', 'Fabricante', 'Provedor', 'Versao', 'Data', 'Assinatura', 'Classe')
    }

    Add-CompartDiskSection -Title 'Assinatura digital dos drivers' -Status $status -Rows $linhas -Pairs $pares `
        -Summary ("{0} assinado(s), {1} sem assinatura, {2} inconclusivo(s)" -f $a.TotalAssinados, $a.TotalNaoAssinados, $a.TotalDesconhecidos)

    # Sem o detalhamento, 'NAO' do Core nao distingue "sem assinatura" de
    # "nao determinado": a verificacao esta degradada e nao pode terminar em OK.
    if ($inv.Status -eq 'Parcial') {
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message 'Verificacao de assinatura degradada: os detalhes de assinatura nao puderam ser obtidos e nenhum driver pode ser classificado como comprovadamente sem assinatura.' `
            -Recommendation 'Revalidar o provedor WMI Win32_PnPSignedDriver e repetir a verificacao antes de concluir sobre a assinatura dos drivers.'
        Set-DriverResult 'WARN' 'verificacao de assinatura degradada'
    }

    if ($a.TotalNaoAssinados -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ("{0} driver(s) sem assinatura digital." -f $a.TotalNaoAssinados) `
            -Recommendation 'Verificar origem, fabricante, necessidade e integridade de cada pacote antes de qualquer substituicao. Driver sem assinatura pode ser legado, corporativo ou especializado: a ausencia de assinatura por si so nao caracteriza comprometimento.'
        Set-DriverResult 'WARN' 'drivers sem assinatura digital'
        Write-Log WARN ("{0} driver(s) sem assinatura digital." -f $a.TotalNaoAssinados)
    }
    if ($a.TotalDesconhecidos -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
            -Message ("{0} driver(s) com estado de assinatura nao determinado." -f $a.TotalDesconhecidos) `
            -Recommendation 'O provedor nao informou o estado de assinatura destes pacotes. Nao e possivel afirmar que estao assinados nem que nao estao.'
        Write-Log INFO ("{0} driver(s) com assinatura nao determinada." -f $a.TotalDesconhecidos)
    }
    if ($a.TotalNaoAssinados -eq 0 -and $a.TotalDesconhecidos -eq 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
            -Message ("Os {0} driver(s) enumerados apresentam assinatura digital confirmada." -f $inv.Total)
        Write-Log OK ("Os {0} driver(s) enumerados apresentam assinatura confirmada." -f $inv.Total)
    } elseif ($a.TotalNaoAssinados -eq 0) {
        Write-Log OK ("Nenhum driver sem assinatura; {0} permanecem inconclusivos." -f $a.TotalDesconhecidos)
    }
}

# ==============================================================================
# ACAO: PROBLEMS  (somente consulta)
# ==============================================================================
function Show-Problems {
    Write-Log INFO 'Verificando dispositivos com codigo de erro...'
    $prob = Get-DriverProblems

    if (-not $prob.Ok) {
        Write-Log ERR ('Consulta de dispositivos com problema indisponivel: {0}' -f $prob.Detalhe)
        Add-CompartDiskSection -Title 'Dispositivos com problema' -Status CRIT -Summary 'Consulta nao concluida'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel verificar dispositivos com problema: {0}' -f $prob.Detalhe) `
            -Recommendation 'Validar o repositorio WMI (winmgmt) e reexecutar a consulta.'
        Set-DriverResult 'ERROR' 'consulta de problemas indisponivel'
        return
    }
    if ($prob.Total -eq 0) {
        Write-Log OK 'Consulta concluida: nenhum dispositivo com codigo de erro.'
        Add-CompartDiskSection -Title 'Dispositivos com problema' -Status OK -Summary 'Nenhum dispositivo com codigo de erro'
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
            -Message 'Consulta concluida: nenhum dispositivo com codigo de erro no Gerenciador de Dispositivos.' `
            -Recommendation 'A ausencia de codigo de erro nao garante que todos os drivers estejam na versao ideal, apenas que nenhum dispositivo esta sinalizando falha.'
        return
    }

    $crit = @($prob.Rows | Where-Object { $_.Severidade -eq 'CRIT' })
    $warn = @($prob.Rows | Where-Object { $_.Severidade -eq 'WARN' })
    $info = @($prob.Rows | Where-Object { $_.Severidade -eq 'INFO' })

    $ordenado = @($prob.Rows | Sort-Object -Property `
        @{ Expression = { switch ("$($_.Severidade)") { 'CRIT' { 0 } 'WARN' { 1 } default { 2 } } } }, `
        @{ Expression = { "$($_.Dispositivo)" } })

    Write-DriverTable -Rows $ordenado -Property @('Severidade', 'Dispositivo', 'CodigoErro', 'Descricao', 'Estado')

    $statusSecao = Get-DriverWorstSeverity @($prob.Rows | ForEach-Object { $_.Severidade })
    Add-CompartDiskSection -Title 'Dispositivos com problema' -Status $statusSecao -Rows $ordenado `
        -Pairs ([ordered]@{
            'Dispositivos com codigo de erro' = $prob.Total
            'Criticos'                        = $crit.Count
            'Em atencao'                      = $warn.Count
            'Informativos'                    = $info.Count
        }) `
        -Summary ("{0} dispositivo(s): {1} critico(s), {2} em atencao, {3} informativo(s)" -f $prob.Total, $crit.Count, $warn.Count, $info.Count)

    # Um finding por dispositivo relevante, com severidade e acao do proprio codigo.
    foreach ($d in (@($crit) + @($warn) | Select-Object -First 15)) {
        Add-CompartDiskFinding -Severity $d.Severidade -Area 'Drivers' `
            -Message ("{0} - codigo {1}: {2}" -f $d.Dispositivo, $d.CodigoErro, $d.Descricao) `
            -Recommendation $d.Acao
    }
    if ($info.Count -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
            -Message ("{0} dispositivo(s) em condicao esperada (desabilitado, desconectado ou em remocao)." -f $info.Count) `
            -Recommendation 'Confirmar se a desativacao ou a ausencia do hardware sao intencionais antes de qualquer acao.'
    }
    if ((@($crit).Count + @($warn).Count) -gt 15) {
        Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
            -Message ("Exibidos os 15 primeiros de {0} dispositivos acionaveis; a lista completa esta na secao do relatorio." -f (@($crit).Count + @($warn).Count))
    }

    if ($crit.Count -gt 0) {
        Set-DriverResult 'WARN' 'dispositivos com falha critica'
        Write-Log WARN ("{0} dispositivo(s) com falha critica, {1} em atencao, {2} informativo(s)." -f $crit.Count, $warn.Count, $info.Count)
    } elseif ($warn.Count -gt 0) {
        Set-DriverResult 'WARN' 'dispositivos com problema'
        Write-Log WARN ("{0} dispositivo(s) em atencao, {1} informativo(s)." -f $warn.Count, $info.Count)
    } else {
        Write-Log OK ("{0} dispositivo(s) com codigo de erro, todos em condicao esperada (desabilitado/desconectado)." -f $info.Count)
    }
}

# ==============================================================================
# ACAO: BACKUP
# Unica acao que escreve. Exporta copia dos pacotes do repositorio de drivers
# via pnputil. Nao instala, nao remove e nao altera nada no sistema.
# ==============================================================================
function Resolve-DriverBackupBase {
    <# Normaliza e valida o destino: relativo, absoluto, UNC, caracteres
       invalidos e comprimento. Sem concatenacao fragil. #>
    [CmdletBinding()] param([string]$Path)
    $out = [pscustomobject]@{ Ok = $false; Base = ''; Unc = $false; Detalhe = '' }

    $bruto = "$Path".Trim().Trim('"').Trim()
    if ([string]::IsNullOrWhiteSpace($bruto)) {
        $raiz = $Global:CompartDisk.OutDir
        if ([string]::IsNullOrWhiteSpace($raiz)) { $raiz = $env:TEMP }
        $out.Base = Join-Path $raiz 'Backup_Drivers'
        $out.Ok = $true
        $out.Detalhe = 'Destino padrao da sessao'
        return $out
    }

    foreach ($c in [System.IO.Path]::GetInvalidPathChars()) {
        if ($bruto.IndexOf($c) -ge 0) {
            $out.Detalhe = 'O caminho informado contem caracteres invalidos.'
            return $out
        }
    }

    try {
        if ($bruto.StartsWith('\\')) {
            $out.Unc = $true
            $completo = $bruto.TrimEnd('\')
        } elseif ([System.IO.Path]::IsPathRooted($bruto)) {
            $completo = [System.IO.Path]::GetFullPath($bruto)
        } else {
            # Relativo: ancorado no diretorio atual do provedor, nao no CWD do processo.
            $atual = (Get-Location).ProviderPath
            $completo = [System.IO.Path]::GetFullPath((Join-Path $atual $bruto))
        }
    } catch {
        $out.Detalhe = ('Caminho invalido: {0}' -f $_.Exception.Message)
        return $out
    }

    if ($completo.Length -gt 200) {
        $out.Detalhe = ('Caminho longo demais ({0} caracteres): os subdiretorios criados pelo pnputil podem exceder o limite do sistema de arquivos.' -f $completo.Length)
        return $out
    }

    $out.Base = $completo
    $out.Ok = $true
    $out.Detalhe = 'Destino informado pelo operador'
    return $out
}

function Get-DriverFreeSpace {
    <# Espaco livre do volume de destino. Nunca falha em silencio: quando nao
       for possivel determinar, devolve Ok=$false com o motivo. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$FullPath, [switch]$Unc)
    $out = [pscustomobject]@{ Ok = $false; Bytes = 0; Metodo = 'n/d'; Detalhe = '' }

    if ($Unc) {
        $out.Detalhe = 'Caminho UNC: o espaco livre do compartilhamento remoto nao pode ser determinado localmente.'
        return $out
    }

    $raiz = ''
    try { $raiz = [System.IO.Path]::GetPathRoot($FullPath) } catch { $raiz = '' }
    if ([string]::IsNullOrWhiteSpace($raiz)) {
        $out.Detalhe = 'Nao foi possivel identificar o volume do destino.'
        return $out
    }
    $letra = $raiz.TrimEnd('\')

    try {
        $disco = Get-CompartDiskCim -Class Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $letra)
        $d = @($disco) | Select-Object -First 1
        if ($d -and $null -ne $d.FreeSpace) {
            $out.Ok = $true; $out.Bytes = [long]$d.FreeSpace; $out.Metodo = 'Win32_LogicalDisk'
            return $out
        }
        $out.Detalhe = ("Win32_LogicalDisk nao devolveu espaco livre para {0}." -f $letra)
    } catch {
        $out.Detalhe = ('Consulta Win32_LogicalDisk falhou: {0}' -f $_.Exception.Message)
        Write-Log DEBUG "Win32_LogicalDisk: $($_.Exception.Message)" -NoConsole
    }

    try {
        $di = New-Object System.IO.DriveInfo($raiz)
        if ($di.IsReady) {
            $out.Ok = $true; $out.Bytes = [long]$di.AvailableFreeSpace; $out.Metodo = 'System.IO.DriveInfo'
            $out.Detalhe = ''
            return $out
        }
        $out.Detalhe += ' O volume nao esta pronto.'
    } catch {
        $out.Detalhe += (' DriveInfo falhou: {0}' -f $_.Exception.Message)
    }
    return $out
}

function Get-DriverStoreEstimate {
    <# Limite SUPERIOR do volume a exportar: o FileRepository contem tambem os
       pacotes inbox, que o pnputil normalmente nao exporta. E estimativa
       declarada como tal, nunca apresentada como valor exato. #>
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Ok = $false; Bytes = 0; Arquivos = 0; Segundos = 0; Detalhe = '' }
    $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    if (-not (Test-Path -LiteralPath $repo)) {
        $out.Detalhe = 'Repositorio de drivers nao localizado para estimativa.'
        return $out
    }
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $tam = Get-CompartDiskFolderSize -Path $repo
        $cron.Stop()
        $out.Segundos = [math]::Round($cron.Elapsed.TotalSeconds, 1)
        if ($null -eq $tam -or -not $tam.Exists) {
            $out.Detalhe = 'Nao foi possivel medir o repositorio de drivers.'
            return $out
        }
        $bytes = 0; $arquivos = 0
        try { $bytes = [long]$tam.Bytes } catch { $bytes = 0 }
        try { $arquivos = [int]$tam.Files } catch { $arquivos = 0 }
        if ($bytes -le 0) {
            $out.Detalhe = 'A medicao do repositorio de drivers devolveu tamanho zero.'
            return $out
        }
        $out.Ok = $true; $out.Bytes = $bytes; $out.Arquivos = $arquivos
        $out.Detalhe = 'Limite superior: inclui pacotes inbox que normalmente nao sao exportados.'
    } catch {
        $cron.Stop()
        $out.Detalhe = ('Estimativa indisponivel: {0}' -f $_.Exception.Message)
        Write-Log WARN 'Nao foi possivel estimar o tamanho do repositorio de drivers.' -ErrorRecord $_
    }
    return $out
}

function Get-DriverExpectedPackages {
    <# Contagem esperada a partir de 'pnputil /enum-drivers'. Os nomes oemNN.inf
       nao sao localizados, entao a contagem independe do idioma do Windows. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$PnpUtil)
    $out = [pscustomobject]@{ Ok = $false; Total = 0; Detalhe = '' }
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $PnpUtil -Arguments @('/enum-drivers') -TimeoutSeconds 300
    } -Activity 'pnputil /enum-drivers' -Silent

    if (-not $r.Success -or $null -eq $r.Value) {
        $out.Detalhe = ('Nao foi possivel enumerar os pacotes publicados: {0}' -f $(if ($r.Error) { $r.Error.Exception.Message } else { 'sem detalhe' }))
        return $out
    }
    if ([int]$r.Value.ExitCode -ne 0) {
        $out.Detalhe = ('pnputil /enum-drivers retornou codigo {0}.' -f $r.Value.ExitCode)
        return $out
    }
    try {
        $set = @{}
        foreach ($m in [regex]::Matches("$($r.Value.StdOut)", '(?i)\boem\d+\.inf\b')) {
            $set[$m.Value.ToLowerInvariant()] = $true
        }
        $out.Ok = $true; $out.Total = $set.Count
        $out.Detalhe = ('{0} pacote(s) publicado(s) no repositorio de drivers.' -f $set.Count)
    } catch {
        $out.Detalhe = ('Falha ao interpretar a saida de /enum-drivers: {0}' -f $_.Exception.Message)
    }
    return $out
}

function Test-DriverBackupIntegrity {
    <# "pnputil terminou" nao e prova de backup. Confirma diretorios, arquivos
       .inf, tamanho e legibilidade real de pelo menos um pacote. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Destino)
    $out = [pscustomobject]@{
        Existe = $false; Pacotes = 0; Infs = 0; Bytes = 0; Arquivos = 0
        Legivel = $false; Detalhe = ''
    }
    if (-not (Test-Path -LiteralPath $Destino)) {
        $out.Detalhe = 'O diretorio de destino nao existe apos a exportacao.'
        return $out
    }
    $out.Existe = $true

    try { $out.Pacotes = @(Get-ChildItem -LiteralPath $Destino -Directory -ErrorAction Stop).Count }
    catch {
        $out.Detalhe = ('Nao foi possivel listar os pacotes exportados: {0}' -f $_.Exception.Message)
        Write-Log WARN 'Falha ao listar os diretorios do backup.' -ErrorRecord $_
        return $out
    }

    $infs = @()
    try { $infs = @(Get-ChildItem -LiteralPath $Destino -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue) }
    catch { Write-Log DEBUG "Enumeracao de .inf: $($_.Exception.Message)" -NoConsole }
    $out.Infs = $infs.Count

    $tam = Get-CompartDiskFolderSize -Path $Destino
    if ($null -ne $tam) {
        try { $out.Bytes = [long]$tam.Bytes } catch { $out.Bytes = 0 }
        try { $out.Arquivos = [int]$tam.Files } catch { $out.Arquivos = 0 }
    }

    if ($infs.Count -gt 0) {
        try {
            $amostra = $infs[0]
            $fs = [System.IO.File]::OpenRead($amostra.FullName)
            try {
                $buf = New-Object byte[] 64
                $lidos = $fs.Read($buf, 0, 64)
                $out.Legivel = ($lidos -gt 0)
            } finally { $fs.Dispose() }
            if (-not $out.Legivel) { $out.Detalhe = 'O arquivo .inf de amostra esta vazio.' }
        } catch {
            $out.Detalhe = ('Nao foi possivel ler o .inf de amostra: {0}' -f $_.Exception.Message)
            Write-Log WARN 'Falha ao validar a leitura de um pacote exportado.' -ErrorRecord $_
        }
    } else {
        $out.Detalhe = 'Nenhum arquivo .inf encontrado no destino.'
    }
    return $out
}

function Backup-Drivers {
    [CmdletBinding()] param([string]$Destino)

    # ---------------------------------------------------------- pre-condicoes
    if (-not (Test-Path -LiteralPath $pnputil)) {
        Write-Log ERR 'pnputil.exe nao localizado neste sistema: exportacao nao suportada.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message 'pnputil.exe nao localizado: o backup de drivers nao pode ser executado.' `
            -Recommendation 'Componente nativo ausente: avaliar integridade do Windows com DISM /RestoreHealth e SFC /scannow.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'pnputil.exe indisponivel'
        Set-DriverResult 'ERROR' 'pnputil ausente'
        return
    }

    $base = Resolve-DriverBackupBase -Path $Destino
    if (-not $base.Ok) {
        Write-Log ERR ('Destino de backup invalido: {0}' -f $base.Detalhe)
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Destino de backup invalido: {0}' -f $base.Detalhe) `
            -Recommendation 'Informar um caminho valido em -Path ou omitir o parametro para usar o destino padrao da sessao.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Destino invalido'
        Set-DriverResult 'ERROR' 'destino invalido'
        return
    }

    # Backups anteriores sao preservados: nada e apagado nem sobrescrito.
    $anteriores = 0
    try {
        if (Test-Path -LiteralPath $base.Base) {
            $anteriores = @(Get-ChildItem -LiteralPath $base.Base -Directory -ErrorAction SilentlyContinue).Count
        } else {
            New-Item -ItemType Directory -Path $base.Base -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Log ERR ('Nao foi possivel preparar o diretorio base de backup: {0}' -f $base.Base) -ErrorRecord $_
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel criar ou acessar o diretorio de backup: {0}' -f $base.Base) `
            -Recommendation 'Verificar permissoes de escrita e disponibilidade do volume de destino.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Destino inacessivel'
        Set-DriverResult 'ERROR' 'destino inacessivel'
        return
    }
    if ($anteriores -gt 0) {
        Write-Log INFO ("{0} backup(s) anterior(es) preservado(s) em {1}." -f $anteriores, $base.Base)
    }

    # ------------------------------------------------------------- capacidade
    Write-Log INFO 'Estimando o volume a exportar (leitura do repositorio de drivers)...'
    $estimativa = Get-DriverStoreEstimate
    $espaco     = Get-DriverFreeSpace -FullPath $base.Base -Unc:$base.Unc
    $margem     = 512MB
    $piso       = 4GB
    $necessario = $piso
    $baseCalculo = 'piso conservador (estimativa indisponivel)'
    if ($estimativa.Ok) {
        $necessario  = [long]($estimativa.Bytes + $margem)
        $baseCalculo = 'estimativa do repositorio + margem de 512 MB'
        Write-Log INFO ("Estimativa (limite superior): {0} em {1} arquivo(s), medida em {2}s." -f (ConvertTo-CompartDiskSize $estimativa.Bytes), $estimativa.Arquivos, $estimativa.Segundos)
    } else {
        Write-Log WARN ('Estimativa de tamanho indisponivel: {0}' -f $estimativa.Detalhe)
        Set-DriverResult 'WARN' 'estimativa de tamanho indisponivel'
    }

    if ($espaco.Ok) {
        Write-Log INFO ("Espaco livre no destino: {0} (necessario estimado: {1})." -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario))
        if ($espaco.Bytes -lt $necessario) {
            Write-Log ERR ("Espaco livre insuficiente no destino: {0} disponivel para {1} estimados." -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario))
            Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
                -Message ("Backup nao executado: espaco livre insuficiente ({0} disponivel, {1} estimados como necessarios)." -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario)) `
                -Recommendation 'Liberar espaco no volume de destino ou informar outro destino em -Path.'
            Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Pairs ([ordered]@{
                'Destino'          = $base.Base
                'Espaco livre'     = (ConvertTo-CompartDiskSize $espaco.Bytes)
                'Necessario (est.)'= (ConvertTo-CompartDiskSize $necessario)
                'Base do calculo'  = $baseCalculo
            }) -Summary 'Abortado antes da exportacao por falta de espaco'
            Set-DriverResult 'ERROR' 'espaco insuficiente'
            return
        }
    } else {
        # Consulta de espaco falhou: nao se afirma que ha espaco suficiente.
        Write-Log WARN ('Espaco livre no destino nao pode ser determinado: {0}' -f $espaco.Detalhe)
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('Nao foi possivel verificar o espaco livre do destino antes da exportacao: {0}' -f $espaco.Detalhe) `
            -Recommendation 'A exportacao prosseguiu; conferir o resultado e o espaco do volume manualmente.'
        Set-DriverResult 'WARN' 'espaco livre nao verificado'
    }

    # Subdiretorio exclusivo por execucao: duas execucoes nunca se misturam e
    # nenhum backup anterior e sobrescrito.
    $carimbo = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $destinoRun = Join-Path $base.Base $carimbo
    $sufixo = 1
    while (Test-Path -LiteralPath $destinoRun) {
        $destinoRun = Join-Path $base.Base ('{0}_{1}' -f $carimbo, $sufixo)
        $sufixo++
        if ($sufixo -gt 50) { break }
    }
    try {
        New-Item -ItemType Directory -Path $destinoRun -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Log ERR ('Nao foi possivel criar o diretorio da execucao: {0}' -f $destinoRun) -ErrorRecord $_
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel criar o diretorio de destino desta execucao: {0}' -f $destinoRun) `
            -Recommendation 'Verificar permissoes de escrita no volume de destino.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Destino inacessivel'
        Set-DriverResult 'ERROR' 'destino inacessivel'
        return
    }
    # "New-Item executou" nao e prova: confirma-se por releitura.
    if (-not (Test-Path -LiteralPath $destinoRun -PathType Container)) {
        Write-Log ERR ('O diretorio de destino nao existe apos a criacao: {0}' -f $destinoRun)
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' -Message 'O diretorio de backup nao pode ser confirmado apos a criacao.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Destino nao confirmado'
        Set-DriverResult 'ERROR' 'destino nao confirmado'
        return
    }

    # ------------------------------------------------------- contagem esperada
    $esperado = Get-DriverExpectedPackages -PnpUtil $pnputil
    if ($esperado.Ok) { Write-Log INFO $esperado.Detalhe }
    else { Write-Log WARN ('Contagem esperada indisponivel: {0}' -f $esperado.Detalhe) }

    # ------------------------------------------------------------- exportacao
    Write-Log INFO ("Exportando os pacotes do repositorio de drivers para: {0}" -f $destinoRun)
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $pnputil -Arguments @('/export-driver', '*', "`"$destinoRun`"") -TimeoutSeconds 1800
    } -Activity 'pnputil /export-driver' -Silent
    $cron.Stop()
    $duracao = [math]::Round($cron.Elapsed.TotalSeconds, 1)

    $exitCode = $null
    $stdErr   = ''
    $stdOut   = ''
    $timeout  = $false
    if ($r.Success -and $null -ne $r.Value) {
        $exitCode = [int]$r.Value.ExitCode
        $stdOut   = "$($r.Value.StdOut)"
        $stdErr   = "$($r.Value.StdErr)".Trim()
    } else {
        $msg = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        $timeout = ($msg -match 'Tempo limite excedido')
        $stdErr = $msg
        if ($timeout) { Write-Log ERR ('A exportacao excedeu o tempo limite de 1800s e foi interrompida: {0}' -f $msg) }
        else          { Write-Log ERR ('A exportacao nao pode ser executada: {0}' -f $msg) }
    }
    if ($stdErr) { Write-Log WARN ('pnputil (stderr): {0}' -f ($stdErr -split "`r?`n" | Select-Object -First 3 | Out-String).Trim()) }

    # -------------------------------------------------------------- validacao
    $integridade = Test-DriverBackupIntegrity -Destino $destinoRun

    # Execucao que nao produziu nada nao deixa diretorio vazio acumulando no
    # destino. Remocao condicionada a estar comprovadamente vazio: nenhum
    # conteudo de backup e apagado em hipotese alguma.
    if ($integridade.Existe -and $integridade.Pacotes -eq 0 -and $integridade.Arquivos -eq 0) {
        try {
            $sobra = @(Get-ChildItem -LiteralPath $destinoRun -Force -ErrorAction Stop)
            if ($sobra.Count -eq 0) {
                Remove-Item -LiteralPath $destinoRun -Force -ErrorAction Stop
                Write-Log INFO 'Diretorio desta execucao removido por estar vazio; backups anteriores preservados.'
            }
        } catch {
            Write-Log DEBUG "Diretorio vazio mantido: $($_.Exception.Message)" -NoConsole
        }
    }

    $comparacao = 'nao comparavel'
    $parcial    = $false
    if ($esperado.Ok -and $esperado.Total -gt 0) {
        if ($integridade.Pacotes -ge $esperado.Total) {
            $comparacao = ("{0} de {0} pacote(s) esperado(s)" -f $esperado.Total)
        } else {
            $parcial = $true
            $comparacao = ("{0} de {1} pacote(s) esperado(s)" -f $integridade.Pacotes, $esperado.Total)
        }
    }

    $exportouAlgo = ($integridade.Pacotes -gt 0 -and $integridade.Infs -gt 0 -and $integridade.Bytes -gt 0 -and $integridade.Legivel)
    $codigoOk     = ($null -ne $exitCode -and $exitCode -eq 0)

    $nivel = 'ERROR'
    $situacao = 'falhou'
    if ($codigoOk -and $exportouAlgo -and -not $parcial) {
        $nivel = 'OK'
        $situacao = $(if ($esperado.Ok) { 'confirmado' } else { 'confirmado, completude nao comparavel' })
    }
    elseif ($exportouAlgo)                              { $nivel = 'WARN';  $situacao = 'parcial' }
    elseif ($codigoOk)                                  { $nivel = 'WARN';  $situacao = 'inconclusivo' }

    $pares = [ordered]@{
        'Destino'                  = $destinoRun
        'Backups anteriores'       = $anteriores
        'Codigo de retorno'        = $(if ($null -ne $exitCode) { $exitCode } else { 'n/d (processo nao concluiu)' })
        'Pacotes exportados'       = $integridade.Pacotes
        'Arquivos .inf'            = $integridade.Infs
        'Arquivos totais'          = $integridade.Arquivos
        'Tamanho'                  = (ConvertTo-CompartDiskSize $integridade.Bytes)
        'Pacotes publicados (est.)'= $(if ($esperado.Ok) { $esperado.Total } else { 'n/d' })
        'Comparacao'               = $comparacao
        'Leitura verificada'       = $(if ($integridade.Legivel) { 'Sim' } else { 'Nao' })
        'Espaco livre'             = $(if ($espaco.Ok) { (ConvertTo-CompartDiskSize $espaco.Bytes) } else { 'nao determinado' })
        'Base do calculo'          = $baseCalculo
        'Duracao'                  = ('{0} s' -f $duracao)
        'Situacao'                 = $situacao
    }
    if ($integridade.Detalhe) { $pares['Observacao'] = $integridade.Detalhe }
    if ($timeout)             { $pares['Interrupcao'] = 'Tempo limite de 1800s excedido' }

    Add-CompartDiskSection -Title 'Backup de drivers' -Status (Get-DriverSectionStatus $nivel) -Pairs $pares `
        -Summary ("{0}: {1} pacote(s), {2}" -f $situacao, $integridade.Pacotes, (ConvertTo-CompartDiskSize $integridade.Bytes))

    switch ($nivel) {
        'OK' {
            Write-Log OK ("Backup validado: {0} pacote(s), {1} arquivo(s) .inf, {2}, em {3}s." -f $integridade.Pacotes, $integridade.Infs, (ConvertTo-CompartDiskSize $integridade.Bytes), $duracao)
            Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
                -Message ("Backup validado: {0} pacote(s) exportado(s) e verificados ({1})." -f $integridade.Pacotes, (ConvertTo-CompartDiskSize $integridade.Bytes)) `
                -Recommendation ("Copiar {0} para midia externa antes de reinstalar o Windows." -f $destinoRun)
            if (-not $esperado.Ok) {
                Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
                    -Message 'A completude do backup nao pode ser comparada: a contagem de pacotes publicados nao foi obtida.' `
                    -Recommendation 'Os pacotes exportados foram validados; nao e possivel afirmar que representam a totalidade do repositorio.'
            }
        }
        'WARN' {
            $motivo = $(if ($parcial) { ('exportacao parcial ({0})' -f $comparacao) } elseif (-not $exportouAlgo) { 'nenhum pacote pode ser confirmado no destino' } else { 'validacao incompleta' })
            Write-Log WARN ("Backup {0}: {1}. Pacotes confirmados: {2} ({3})." -f $situacao, $motivo, $integridade.Pacotes, (ConvertTo-CompartDiskSize $integridade.Bytes))
            Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
                -Message ("Backup {0}: {1}. {2} pacote(s) confirmado(s) em {3}." -f $situacao, $motivo, $integridade.Pacotes, $destinoRun) `
                -Recommendation 'Conferir o conteudo do destino antes de considerar o backup utilizavel; reexecutar apos liberar espaco ou fechar processos que bloqueiem o repositorio.'
            Set-DriverResult 'WARN' 'backup parcial ou inconclusivo'
        }
        default {
            Write-Log ERR ("Backup nao concluido. Codigo: {0}. Pacotes no destino: {1}." -f $(if ($null -ne $exitCode) { $exitCode } else { 'n/d' }), $integridade.Pacotes)
            Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
                -Message ("Backup de drivers nao concluido{0}. Nenhum pacote pode ser validado no destino." -f $(if ($timeout) { ' (tempo limite excedido)' } else { '' })) `
                -Recommendation 'Verificar privilegios administrativos, espaco em disco, antivirus e integridade do repositorio de drivers; reexecutar em seguida.'
            Set-DriverResult 'ERROR' 'backup nao concluido'
        }
    }
}

# ==============================================================================
# ACAO: EXPORT  (somente gera relatorio)
# Reaproveita o inventario e a lista de problemas ja cacheados: List, Unsigned,
# Problems e Export enxergam exatamente o mesmo retrato dentro de uma execucao.
# As secoes sao construidas pelas mesmas funcoes de analise, o que impede
# divergencia entre o que aparece no console e o que vai para TXT/CSV/JSON/HTML.
# ==============================================================================
function Export-DriverInventory {
    Write-Log INFO 'Gerando inventario de drivers para relatorio...'

    # Mesma fonte de dados das demais acoes (consultas cacheadas).
    Show-Drivers
    Show-Unsigned
    Show-Problems

    # Correlacao de sinais: dispositivo com codigo de erro cujo driver tambem
    # nao esta assinado tem prioridade sobre um driver antigo saudavel.
    $inv  = Get-DriverInventory
    $prob = Get-DriverProblems
    if ($inv.Ok -and $prob.Ok -and $prob.Total -gt 0) {
        $ass = Get-DriverSignatureAnalysis $inv.Rows
        $cruz = Get-DriverCorrelacao -Problemas $prob.Rows -NaoAssinados $ass.NaoAssinados
        if (@($cruz).Count -gt 0) {
            Add-CompartDiskSection -Title 'Correlacao: problema + assinatura ausente' -Status CRIT -Rows @($cruz) `
                -Summary ("{0} dispositivo(s) com codigo de erro e driver sem assinatura" -f @($cruz).Count)
            Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
                -Message ("{0} dispositivo(s) apresentam simultaneamente codigo de erro e driver sem assinatura digital." -f @($cruz).Count) `
                -Recommendation 'Prioridade de investigacao: identificar o hardware, obter o pacote assinado do fabricante/OEM e criar backup antes de qualquer substituicao.'
            Set-DriverResult 'WARN' 'correlacao entre problema e assinatura ausente'
        }
    }

    # Relatorio a partir dos MESMOS objetos estruturados das secoes: nenhuma
    # tabela pre-formatada como texto entra em CSV/JSON/HTML.
    $dados = [ordered]@{
        Meta     = New-CompartDiskReportMeta
        Sections = @($Global:CompartDisk.Sections)
        Findings = @($Global:CompartDisk.Findings)
    }
    $formatos = @('TXT', 'CSV', 'JSON', 'HTML')
    $arquivos = @()
    $r = Invoke-SafeCommand {
        New-Report -Name 'Inventario_Drivers' -Title 'Inventario de drivers' -Format $formatos -Data $dados
    } -Activity 'Geracao dos relatorios de inventario' -Silent
    if ($r.Success) { $arquivos = ConvertTo-DriverArray $r.Value }

    # "New-Report executou" nao e prova: confirma-se arquivo a arquivo.
    $validos = New-Object System.Collections.ArrayList
    foreach ($a in $arquivos) {
        try {
            $fi = Get-Item -LiteralPath "$a" -ErrorAction Stop
            if ($fi.Length -gt 0) { [void]$validos.Add([pscustomobject]@{ Arquivo = $fi.Name; Bytes = $fi.Length; Caminho = $fi.FullName }) }
            else { Write-Log WARN ("Relatorio gerado vazio: {0}" -f $fi.FullName) }
        } catch {
            Write-Log WARN ("Relatorio declarado mas nao encontrado: {0}" -f $a) -ErrorRecord $_
        }
    }

    Add-CompartDiskSection -Title 'Relatorios de inventario' -Status $(if ($validos.Count -eq $formatos.Count) { 'OK' } else { 'WARN' }) `
        -Rows @($validos) -Pairs ([ordered]@{
            'Formatos solicitados' = ($formatos -join ', ')
            'Arquivos confirmados' = $validos.Count
        }) -Summary ("{0} de {1} formato(s) confirmado(s)" -f $validos.Count, $formatos.Count)

    if (-not $r.Success) {
        Write-Log ERR 'A geracao dos relatorios de inventario falhou.' -ErrorRecord $r.Error
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel gerar os relatorios de inventario: {0}' -f $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })) `
            -Recommendation 'Verificar permissoes de escrita no diretorio de saida da sessao.'
        Set-DriverResult 'ERROR' 'geracao de relatorio falhou'
        return
    }
    if ($validos.Count -eq 0) {
        Write-Log ERR 'Nenhum arquivo de inventario pode ser confirmado no disco.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message 'Nenhum arquivo de inventario foi confirmado no disco apos a geracao.' `
            -Recommendation 'Verificar permissoes de escrita e espaco no diretorio de saida da sessao.'
        Set-DriverResult 'ERROR' 'nenhum relatorio confirmado'
        return
    }
    if ($validos.Count -lt $formatos.Count) {
        Write-Log WARN ("{0} de {1} formato(s) de inventario confirmado(s)." -f $validos.Count, $formatos.Count)
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ("Inventario gerado parcialmente: {0} de {1} formato(s) confirmado(s)." -f $validos.Count, $formatos.Count) `
            -Recommendation 'Conferir o diretorio de saida da sessao e as permissoes de escrita.'
        Set-DriverResult 'WARN' 'relatorio parcial'
        return
    }
    Write-Log OK ("{0} arquivo(s) de inventario gerado(s) e confirmado(s)." -f $validos.Count)
}

# ==============================================================================
# DESPACHO
# List, Problems, Unsigned e Export sao somente leitura e nao exigem elevacao.
# Backup escreve no destino e exige administrador (pnputil /export-driver e
# /enum-drivers dependem de privilegio elevado).
# ==============================================================================
$codigo = $Global:CompartDisk.Exit.ERROR
try {
    $precisaAdmin = @('Backup') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Drivers' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # Sem isto o estado persistido para o Report.ps1 sairia como OK enquanto
        # o modulo devolvia codigo de erro.
        Set-DriverResult 'ERROR' 'privilegios administrativos ausentes'
    } else {
        switch ($Action) {
            'List'     { Show-Drivers }
            'Problems' { Show-Problems }
            'Unsigned' { Show-Unsigned }
            'Backup'   { Backup-Drivers -Destino $Path }
            'Export'   { Export-DriverInventory }
        }
    }
} catch {
    Set-DriverResult 'ERROR' 'excecao nao tratada'
    Write-Log ERR "Falha nao tratada no modulo Drivers (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
        -Message ("Excecao no modulo durante a acao '{0}': {1}" -f $Action, $_.Exception.Message) `
        -Recommendation 'Consultar o log detalhado da sessao para a etapa exata e o codigo do erro.'
} finally {
    $codigo = Stop-CompartDiskModule -Result $script:result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$script:result] }
}
exit ([int]$codigo)
