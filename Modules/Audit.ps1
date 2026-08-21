<#
 COMPARTDISK 1.4.6 - Audit.ps1  (revisao cirurgica)
 Desenvolvido por Edsilas
 Acoes: Full | Quick | Events | Software | License

 -NoReport  nao gera arquivos de relatorio.
 -NoOpen    gera o relatorio mas nao abre.
 -Quiet     reduz a saida visual (nao reduz logs nem dados coletados).

 REGRA MAXIMA: MODULO SOMENTE LEITURA.
 Nenhum comando deste arquivo altera registro, servicos, tarefas, usuarios,
 firewall, Defender, Windows Update, AppX, energia ou arquivos de sistema.
 A unica escrita permitida e a geracao dos arquivos de relatorio, delegada a
 New-Report do Core e desativavel por -NoReport.

 Contrato de estado:
   Global : OK < WARN < ERROR   (monotonico, nunca regride)
   Secao  : OK < INFO < WARN < CRIT
   "Nao foi possivel consultar" NUNCA e representado como OK.
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Quick', 'Events', 'Software', 'License')]
    [string]$Action = 'Full',
    [int]$Days = 7,
    [switch]$NoReport,
    [switch]$NoOpen,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# 0. CARGA DO CORE (protegida)
# ============================================================================
# Codigos de saida usados apenas se o Core nao expuser $Global:CompartDisk.Exit.
$script:ExitFallback = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

$script:CorePath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Core.ps1' } else { 'Core.ps1' }
try {
    if (-not (Test-Path -LiteralPath $script:CorePath)) {
        throw "Core.ps1 nao encontrado em '$script:CorePath'."
    }
    . $script:CorePath
} catch {
    # Sem Core nao ha Write-Log, Write-Color nem tabela de saida: falha explicita.
    try {
        Write-Host ("[ERRO ] Audit: falha ao carregar o Core - {0}" -f $_.Exception.Message) -ForegroundColor Red
    } catch { }
    exit $script:ExitFallback['ERROR']
}

# ============================================================================
# 1. ESTADO GLOBAL (mecanismo unico e deterministico)
# ============================================================================
$script:Result        = 'OK'
$script:ResultRank    = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }
$script:StatusRank    = @{ 'OK' = 0; 'INFO' = 1; 'WARN' = 2; 'CRIT' = 3 }
$script:ResultReasons = New-Object System.Collections.ArrayList
$script:Findings      = [ordered]@{ 'OK' = 0; 'INFO' = 0; 'WARN' = 0; 'CRIT' = 0 }
$script:Areas         = [ordered]@{}
$script:Steps         = New-Object System.Collections.ArrayList
$script:ModuleStarted = $false
$script:IsAdmin       = $false
$script:SlowSeconds   = 45
$script:Watch         = [System.Diagnostics.Stopwatch]::StartNew()

# Caches de coleta (evitam consultas repetidas entre Quick e Full).
$script:Cache = @{}

function Update-AuditResult {
    <# Eleva o resultado global. Nunca regride: um WARN jamais desaparece. #>
    param(
        [ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        [string]$Reason
    )
    if ($script:ResultRank[$Level] -gt $script:ResultRank[$script:Result]) {
        $script:Result = $Level
    }
    if ($Level -ne 'OK' -and $Reason) {
        [void]$script:ResultReasons.Add(("[{0}] {1}" -f $Level, $Reason))
    }
}

function Update-AuditArea {
    <# Registra a cobertura real de cada area para o relatorio final. #>
    param(
        [string]$Name,
        [ValidateSet('Pendente', 'Verificado', 'Parcial', 'Nao verificado', 'Nao aplicavel')]
        [string]$State,
        [string]$Detail = ''
    )
    if (-not $Name) { return }
    # 'Pendente' nunca sobrescreve um estado ja definido.
    if ($State -eq 'Pendente' -and $script:Areas.Contains($Name)) { return }
    $script:Areas[$Name] = [pscustomobject]@{ Area = $Name; Estado = $State; Detalhe = $Detail }
}

function Get-AuditExitCode {
    param([string]$Name)
    try {
        if ($Global:CompartDisk -and $Global:CompartDisk.Exit) {
            $v = $Global:CompartDisk.Exit.$Name
            if ($null -ne $v) { return [int]$v }
        }
    } catch { }
    return $script:ExitFallback[$Name]
}

# ============================================================================
# 2. UTILITARIOS DE SAIDA (respeitam -Quiet sem perder log)
# ============================================================================
$script:HasWriteColor = [bool](Get-Command -Name 'Write-Color'                -ErrorAction SilentlyContinue)
$script:HasKeyValue   = [bool](Get-Command -Name 'Write-CompartDiskKeyValue'  -ErrorAction SilentlyContinue)
$script:HasSafeCmd    = [bool](Get-Command -Name 'Invoke-SafeCommand'         -ErrorAction SilentlyContinue)

function Write-AuditLine {
    param([string]$Text = '', [string]$Color = '')
    if ($Quiet) { return }
    try {
        if ($script:HasWriteColor) {
            if ($Color) { Write-Color $Text -Color $Color } else { Write-Color $Text }
        } else {
            if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
        }
    } catch {
        try { Write-Host $Text } catch { }
    }
}

function Write-AuditLog {
    <# Log sempre ocorre, mesmo em -Quiet (o Core decide o destino). #>
    param([string]$Level, [string]$Message, $ErrorRecord = $null)
    try {
        if ($ErrorRecord) { Write-Log $Level $Message -ErrorRecord $ErrorRecord }
        else              { Write-Log $Level $Message }
    } catch { }
}

function Write-AuditPair {
    param([string]$Key, $Value, [int]$Pad = 18)
    if ($Quiet) { return }
    try {
        if ($script:HasKeyValue) { Write-CompartDiskKeyValue $Key $Value -Pad $Pad; return }
    } catch { }
    Write-AuditLine ("  {0} : {1}" -f $Key.PadRight($Pad), $Value)
}

function Write-AuditPairs {
    param($Pairs, [int]$Pad = 18)
    if ($Quiet -or $null -eq $Pairs) { return }
    if ($Pairs -is [System.Collections.IDictionary]) {
        foreach ($k in @($Pairs.Keys)) { Write-AuditPair "$k" $Pairs[$k] $Pad }
    }
}

function Write-AuditTable {
    <# Renderiza tabela para o console sem vazar objetos no stream de sucesso. #>
    param($Rows, [string[]]$Property = @(), [int]$Width = 160, [int]$First = 0)
    if ($Quiet) { return }
    $list = @($Rows | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return }
    if ($First -gt 0 -and $list.Count -gt $First) { $list = @($list | Select-Object -First $First) }

    # Hashtables viram objetos para nao imprimir colunas Key/Value.
    if ($list[0] -is [System.Collections.IDictionary]) {
        $list = @($list | ForEach-Object { [pscustomobject]$_ })
    }
    $have = @()
    try { $have = @($list[0].PSObject.Properties.Name) } catch { }
    $use = @($Property | Where-Object { $have -contains $_ })

    $txt = ''
    try {
        if ($use.Count -gt 0) { $txt = $list | Format-Table $use -AutoSize | Out-String -Width $Width }
        else                  { $txt = $list | Format-Table -AutoSize      | Out-String -Width $Width }
    } catch {
        try { $txt = $list | Out-String -Width $Width } catch { return }
    }
    foreach ($linha in ($txt -split "`r?`n")) {
        if ("$linha".Trim() -ne '') { Write-AuditLine ("$linha".TrimEnd()) }
    }
}

# ============================================================================
# 3. LEITURA DEFENSIVA DE DADOS (nunca assume que a propriedade existe)
# ============================================================================
function Get-AuditNormalKey {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = "$Text"
    try {
        $s = $s.Normalize([System.Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder
        foreach ($c in $s.ToCharArray()) {
            if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($c)
            }
        }
        $s = $sb.ToString()
    } catch { }
    return (($s -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
}

function Get-AuditValue {
    <#
      Le uma chave/propriedade tolerando variacao de nome, acento, espaco e caixa.
      Retorna $Default quando ausente ou vazio - jamais lanca excecao.
    #>
    param($Source, [string[]]$Name, $Default = $null)
    if ($null -eq $Source) { return $Default }
    $alvos = @($Name | ForEach-Object { Get-AuditNormalKey $_ })

    try {
        if ($Source -is [System.Collections.IDictionary]) {
            foreach ($alvo in $alvos) {
                foreach ($k in @($Source.Keys)) {
                    if ((Get-AuditNormalKey "$k") -eq $alvo) {
                        $v = $Source[$k]
                        if ($null -ne $v -and "$v".Trim() -ne '') { return $v }
                    }
                }
            }
            foreach ($alvo in $alvos) {
                foreach ($k in @($Source.Keys)) {
                    $nk = Get-AuditNormalKey "$k"
                    if ($nk -like "*$alvo*") {
                        $v = $Source[$k]
                        if ($null -ne $v -and "$v".Trim() -ne '') { return $v }
                    }
                }
            }
            return $Default
        }

        $props = @($Source.PSObject.Properties)
        foreach ($alvo in $alvos) {
            foreach ($p in $props) {
                if ((Get-AuditNormalKey $p.Name) -eq $alvo) {
                    $v = $p.Value
                    if ($null -ne $v -and "$v".Trim() -ne '') { return $v }
                }
            }
        }
        foreach ($alvo in $alvos) {
            foreach ($p in $props) {
                if ((Get-AuditNormalKey $p.Name) -like "*$alvo*") {
                    $v = $p.Value
                    if ($null -ne $v -and "$v".Trim() -ne '') { return $v }
                }
            }
        }
    } catch { }
    return $Default
}

$script:TrueWords = @(
    'true', '1', 'sim', 's', 'yes', 'y', 'on', 'ativo', 'ativa', 'ativado', 'ativada',
    'habilitado', 'habilitada', 'enabled', 'enable', 'ligado', 'protegido', 'protegida',
    'running', 'emexecucao', 'iniciado', 'encrypted', 'fullyencrypted', 'presente', 'ok'
)
$script:FalseWords = @(
    'false', '0', 'nao', 'n', 'no', 'off', 'inativo', 'inativa', 'desativado', 'desativada',
    'desabilitado', 'desabilitada', 'disabled', 'desligado', 'desprotegido', 'desprotegida',
    'stopped', 'parado', 'parada', 'decrypted', 'fullydecrypted', 'ausente'
)

function ConvertTo-AuditTriState {
    <#
      Converte qualquer representacao em 'True' / 'False' / 'Unknown'.
      Corrige o bug de comparar texto localizado com 'True'/'False' literais,
      que gerava tanto falso CRIT quanto falso negativo silencioso.
    #>
    param($Value)
    if ($null -eq $Value) { return 'Unknown' }
    if ($Value -is [bool]) { if ($Value) { return 'True' } else { return 'False' } }
    $n = Get-AuditNormalKey "$Value"
    if ($n -eq '') { return 'Unknown' }
    if ($script:TrueWords  -contains $n) { return 'True' }
    if ($script:FalseWords -contains $n) { return 'False' }
    if ($n -match 'naosuportad|notsupported|naoaplicav|notapplicable') { return 'Unknown' }
    if ($n -match 'desconhecid|unknown|indisponiv|naoverificad|naoconsultad|erro|error|na') { return 'Unknown' }
    return 'Unknown'
}

function ConvertTo-AuditNumber {
    <#
      Conversao numerica robusta: aceita vazio, '%', unidades, virgula ou ponto
      decimal e separador de milhar. Retorna $null quando nao for numero.
      Corrige o crash de [double]'85,3' / [double]'' que abortava a etapa inteira.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [decimal] -or $Value -is [single]) { return [double]$Value }

    $t = ("$Value").Trim()
    if ($t -eq '') { return $null }
    $t = $t -replace '[^0-9\.,\-]', ''
    if ($t -eq '' -or $t -eq '-') { return $null }

    if ($t.Contains(',') -and $t.Contains('.')) {
        if ($t.LastIndexOf(',') -gt $t.LastIndexOf('.')) { $t = ($t -replace '\.', '') -replace ',', '.' }
        else { $t = $t -replace ',', '' }
    } elseif ($t.Contains(',')) {
        $t = $t -replace ',', '.'
    }

    [double]$out = 0
    if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$out)) {
        return $out
    }
    return $null
}

function Get-AuditCount {
    <# Contagem segura: $null -> 0, objeto unico -> 1, colecao -> Count. #>
    param($Value)
    if ($null -eq $Value) { return 0 }
    return @($Value | Where-Object { $null -ne $_ }).Count
}

function Get-AuditText {
    param($Value, [string]$Default = 'nao informado', [int]$MaxLength = 0)
    if ($null -eq $Value) { return $Default }
    $s = ("$Value" -replace '\s+', ' ').Trim()
    if ($s -eq '') { return $Default }
    if ($MaxLength -gt 0 -and $s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength) + '...' }
    return $s
}

# ============================================================================
# 4. PRIVACIDADE (mascaramento antes de qualquer saida)
# ============================================================================
function Protect-AuditSecret {
    param([string]$Key, $Value)
    if ($null -eq $Value) { return $Value }
    $s = "$Value"
    if ($s.Trim() -eq '') { return $Value }

    # Chave de produto completa (5x5) nunca sai do modulo.
    if ($s -match '^\s*[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}\s*$') {
        return ('*****-*****-*****-*****-' + $s.Trim().Substring($s.Trim().Length - 5))
    }

    $nk = Get-AuditNormalKey $Key
    if ($nk -match 'parcial|ultimos|last') { return $Value }   # ja e um fragmento
    if ($nk -match 'chave|productkey|prodkey|senha|password|token|credencial|credential|digitalid|installationid|numerodeserie|numeroserie|serialnumber|serial|uuid') {
        $t = $s.Trim()
        if ($t.Length -le 4) { return '****' }
        return (('*' * [Math]::Min(12, $t.Length - 4)) + $t.Substring($t.Length - 4))
    }
    return $Value
}

function Protect-AuditPairs {
    param($Pairs)
    if ($null -eq $Pairs -or -not ($Pairs -is [System.Collections.IDictionary])) { return $Pairs }
    $out = [ordered]@{}
    foreach ($k in @($Pairs.Keys)) { $out["$k"] = Protect-AuditSecret "$k" $Pairs[$k] }
    return $out
}

# ============================================================================
# 5. SECOES E FINDINGS (ponto unico de classificacao)
# ============================================================================
function Resolve-AuditStatus {
    param([string[]]$Levels)
    $pior = 'OK'
    foreach ($l in @($Levels)) {
        if ($l -and $script:StatusRank.ContainsKey($l) -and $script:StatusRank[$l] -gt $script:StatusRank[$pior]) { $pior = $l }
    }
    return $pior
}

function Add-AuditSection {
    <#
      Encapsula Add-CompartDiskSection: monta o splat apenas com o que existe e
      degrada o status com aviso explicito caso o Core nao aceite o valor,
      preservando a informacao no Summary em vez de perde-la.
    #>
    param(
        [string]$Title,
        [ValidateSet('OK', 'INFO', 'WARN', 'CRIT')][string]$Status = 'INFO',
        $Pairs = $null,
        $Rows = $null,
        [string]$Summary = ''
    )
    $splat = @{ 'Title' = $Title; 'Status' = $Status }
    if ($null -ne $Pairs -and $Pairs -is [System.Collections.IDictionary] -and $Pairs.Count -gt 0) {
        $splat['Pairs'] = (Protect-AuditPairs $Pairs)
    }
    $lista = @($Rows | Where-Object { $null -ne $_ })
    if ($lista.Count -gt 0) { $splat['Rows'] = $lista }
    if ($Summary) { $splat['Summary'] = $Summary }

    try {
        Add-CompartDiskSection @splat | Out-Null
        return
    } catch {
        $erro = $_.Exception.Message
        $degrade = @{ 'CRIT' = 'INFO'; 'WARN' = 'INFO'; 'INFO' = 'OK'; 'OK' = 'OK' }
        $alt = $degrade[$Status]
        if ($alt -ne $Status) {
            $splat['Status']  = $alt
            $splat['Summary'] = ("[{0}] {1}" -f $Status, $Summary).Trim()
            try {
                Add-CompartDiskSection @splat | Out-Null
                Write-AuditLog 'WARN' ("Secao '{0}': status '{1}' recusado pelo Core, registrado como '{2}'." -f $Title, $Status, $alt)
                return
            } catch { $erro = $_.Exception.Message }
        }
        Write-AuditLog 'WARN' ("Falha ao registrar a secao '{0}': {1}" -f $Title, $erro)
        Update-AuditResult 'WARN' ("Secao '$Title' nao pode ser registrada no relatorio.")
    }
}

function Add-AuditFinding {
    <#
      Ponto unico de emissao de achados: conta severidades e eleva o estado
      global. Um CRIT/WARN de auditoria nunca convive com resultado global OK.
    #>
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'CRIT')][string]$Severity,
        [string]$Area,
        [string]$Message,
        [string]$Recommendation = ''
    )
    $script:Findings[$Severity] = [int]$script:Findings[$Severity] + 1

    $splat = @{ 'Severity' = $Severity; 'Area' = $Area; 'Message' = $Message }
    if ($Recommendation) { $splat['Recommendation'] = $Recommendation }
    try {
        Add-CompartDiskFinding @splat | Out-Null
    } catch {
        Write-AuditLog 'WARN' ("Falha ao registrar achado em '{0}': {1}" -f $Area, $_.Exception.Message)
        Update-AuditResult 'WARN' "Achado de auditoria nao pode ser registrado."
    }

    if ($Severity -eq 'CRIT' -or $Severity -eq 'WARN') {
        # ERROR e reservado a falha estrutural do modulo; achado grave eleva a WARN.
        Update-AuditResult 'WARN' ("{0}: {1}" -f $Area, $Message)
    }
}

# ============================================================================
# 6. COLETA (DETECTAR -> CONSULTAR -> VALIDAR -> CLASSIFICAR -> REGISTRAR)
# ============================================================================
function Invoke-AuditCollect {
    <#
      Executa UMA consulta e devolve o estado real dela.
      Estados: Ok | Vazio | Falhou | Indisponivel
      Granularidade menor que Invoke-SafeCommand (que trata a etapa inteira):
      permite que uma consulta falhe sem contaminar as demais da mesma etapa.
    #>
    param(
        [string]$Name,
        [scriptblock]$Script,
        [string]$Requires = '',
        [switch]$Cache
    )

    if ($Cache -and $script:Cache.ContainsKey($Name)) { return $script:Cache[$Name] }

    $res = [pscustomobject]@{
        Name     = $Name
        State    = 'Falhou'
        Data     = $null
        Items    = @()
        Count    = 0
        Error    = ''
        Seconds  = 0.0
    }

    if ($Requires -and -not (Get-Command -Name $Requires -ErrorAction SilentlyContinue)) {
        $res.State = 'Indisponivel'
        $res.Error = "Funcao '$Requires' nao existe nesta versao do Core."
        Write-AuditLog 'WARN' ("Coleta '{0}' indisponivel: {1}" -f $Name, $res.Error)
        if ($Cache) { $script:Cache[$Name] = $res }
        return $res
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $dados = & $Script
        $sw.Stop()
        $res.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $res.Data    = $dados
        $res.Items   = @($dados | Where-Object { $null -ne $_ })
        $res.Count   = $res.Items.Count

        $vazio = $false
        if ($null -eq $dados) { $vazio = $true }
        elseif ($dados -is [System.Collections.IDictionary]) { if ($dados.Count -eq 0) { $vazio = $true } }
        elseif ($res.Count -eq 0) { $vazio = $true }

        if ($vazio) { $res.State = 'Vazio' } else { $res.State = 'Ok' }
    } catch {
        $sw.Stop()
        $res.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        $res.State   = 'Falhou'
        $res.Error   = $_.Exception.Message
        if ($_.Exception -is [System.Management.Automation.CommandNotFoundException]) { $res.State = 'Indisponivel' }
        Write-AuditLog 'WARN' ("Coleta '{0}' falhou: {1}" -f $Name, $res.Error)
    }

    if ($res.Seconds -gt $script:SlowSeconds) {
        Write-AuditLog 'WARN' ("Coleta '{0}' demorou {1}s (limite de referencia {2}s)." -f $Name, $res.Seconds, $script:SlowSeconds)
    }
    if ($Cache) { $script:Cache[$Name] = $res }
    return $res
}

function Add-AuditNotCollected {
    <#
      Traduz uma coleta malsucedida em secao + achado honestos.
      Nunca usa OK: "nao consegui consultar" nao e "esta tudo certo".
    #>
    param(
        [object]$Collect,
        [string]$Title,
        [string]$Area,
        [string]$Impact = '',
        [ValidateSet('INFO', 'WARN')][string]$Severity = 'WARN'
    )
    $motivo = switch ($Collect.State) {
        'Indisponivel' { "consulta indisponivel nesta maquina ({0})" -f (Get-AuditText $Collect.Error '' 160) }
        'Falhou'       { "consulta falhou ({0})" -f (Get-AuditText $Collect.Error 'erro nao detalhado' 160) }
        'Vazio'        { 'consulta concluiu sem retornar dados' }
        default        { 'estado de coleta indeterminado' }
    }
    $resumo = ("Nao verificado: {0}." -f $motivo)
    if ($Impact) { $resumo += " Impacto: $Impact" }

    $st = 'INFO'
    if ($Severity -eq 'WARN') { $st = 'WARN' }
    Add-AuditSection -Title $Title -Status $st -Summary $resumo
    Add-AuditFinding -Severity $Severity -Area $Area `
        -Message ("{0}: estado nao determinado ({1})." -f $Title, $motivo) `
        -Recommendation 'Reexecutar com privilegios administrativos ou verificar manualmente. Ausencia de dados nao equivale a ausencia de problema.'
    Update-AuditArea $Area 'Nao verificado' $motivo
    Update-AuditResult 'WARN' ("{0} nao pode ser verificado." -f $Title)
}

function Invoke-Etapa {
    <#
      Executa uma etapa completa. Preserva o comportamento de Invoke-SafeCommand
      (quando existe) sem duplicar sua logica, e garante que uma etapa que falha
      nao aborte as demais nem deixe areas marcadas como verificadas.
    #>
    param(
        [string]$Nome,
        [scriptblock]$Bloco,
        [string[]]$Areas = @()
    )
    Write-AuditLine ''
    Write-AuditLine ("  >> {0}" -f $Nome) 'DarkCyan'
    foreach ($a in $Areas) { Update-AuditArea $a 'Pendente' }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $erro = ''
    $valor = $null

    if ($script:HasSafeCmd) {
        $r = $null
        try {
            $r = Invoke-SafeCommand -ScriptBlock $Bloco -Activity $Nome
        } catch {
            $ok = $false; $erro = $_.Exception.Message
        }
        if ($null -ne $r) {
            $p = $null
            try { $p = $r.PSObject.Properties['Success'] } catch { }
            if ($p) { $ok = [bool]$p.Value }
            try { $valor = $r.Value } catch { }
            if (-not $ok) {
                $erro = Get-AuditText (Get-AuditValue $r @('Error') | ForEach-Object { $_.Exception.Message }) 'erro nao detalhado'
                if ($erro -eq 'erro nao detalhado') { $erro = Get-AuditText (Get-AuditValue $r @('Error')) 'erro nao detalhado' 200 }
            }
        }
    } else {
        try { $valor = & $Bloco } catch { $ok = $false; $erro = $_.Exception.Message }
    }
    $sw.Stop()

    # Os blocos imprimem por Write-Audit*; o stream de sucesso so deve conter
    # texto residual. Apenas strings sao ecoadas, para nao poluir com objetos.
    foreach ($linha in @($valor)) {
        if ($linha -is [string] -and $linha.Trim() -ne '') { Write-AuditLine ($linha.TrimEnd()) }
    }

    if (-not $ok) {
        Write-AuditLog 'WARN' ("Etapa '{0}' incompleta: {1}" -f $Nome, $erro)
        Update-AuditResult 'WARN' ("Etapa '{0}' incompleta." -f $Nome)
        Write-AuditLine ("     etapa incompleta: {0}" -f (Get-AuditText $erro 'erro nao detalhado' 160)) 'Yellow'
    }
    if ($sw.Elapsed.TotalSeconds -gt $script:SlowSeconds) {
        Write-AuditLog 'WARN' ("Etapa '{0}' levou {1}s." -f $Nome, [Math]::Round($sw.Elapsed.TotalSeconds, 1))
    }

    # Area que ficou 'Pendente' significa bloco interrompido antes de classificar.
    foreach ($a in $Areas) {
        if ($script:Areas.Contains($a) -and $script:Areas[$a].Estado -eq 'Pendente') {
            Update-AuditArea $a 'Nao verificado' ('Etapa interrompida: ' + (Get-AuditText $erro 'motivo nao detalhado' 120))
        }
    }

    [void]$script:Steps.Add([pscustomobject]@{
        Etapa    = $Nome
        Resultado = $(if ($ok) { 'Concluida' } else { 'Incompleta' })
        Segundos = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        Detalhe  = (Get-AuditText $erro '' 200)
    })
}

# ============================================================================
# 7. CONTEXTO DE EXECUCAO
# ============================================================================
function Test-AuditAdministrator {
    if (Get-Command -Name 'Test-Administrator' -ErrorAction SilentlyContinue) {
        try { return [bool](Test-Administrator) } catch { }
    }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return [bool]$pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Add-AuditContextSection {
    param([string]$Modo)
    $script:IsAdmin = Test-AuditAdministrator

    $pares = [ordered]@{
        'Modulo'            = 'Audit 1.4.6'
        'Acao'              = $Action
        'Modo'              = $Modo
        'Janela de eventos' = ("$Days dia(s)")
        'Data/hora'         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        'Maquina'           = $env:COMPUTERNAME
        'Elevacao'          = $(if ($script:IsAdmin) { 'Administrador' } else { 'Usuario padrao (sem elevacao)' })
        'PowerShell'        = ("{0} ({1})" -f $PSVersionTable.PSVersion.ToString(), $(if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }))
        'Processo'          = $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' })
        'Relatorios'        = $(if ($NoReport) { 'Desativados (-NoReport)' } else { 'TXT, CSV, JSON, HTML' })
    }
    Add-AuditSection -Title 'Contexto da execucao' -Status 'INFO' -Pairs $pares
    Write-AuditPairs $pares 18

    if (-not $script:IsAdmin) {
        Write-AuditLog 'WARN' 'Execucao sem privilegios administrativos: areas dependentes de elevacao podem ficar parciais.'
        Add-AuditFinding -Severity 'INFO' -Area 'Execucao' `
            -Message 'Auditoria executada sem elevacao. Areas tipicamente afetadas: Defender, BitLocker, copias de sombra, log de Seguranca e parte dos perfis de firewall.' `
            -Recommendation 'Para cobertura completa, reexecutar em console elevado. Os dados coletados continuam validos, porem parciais nas areas citadas.'
    } else {
        Add-AuditFinding -Severity 'OK' -Area 'Execucao' -Message 'Auditoria executada com privilegios administrativos.'
    }
    Update-AuditArea 'Execucao' 'Verificado' ''
}

# ============================================================================
# 8. ETAPAS DE AUDITORIA
# ============================================================================

# ---------------------------------------------------------------- sistema ---
function Add-AuditSystem {
    $c = Invoke-AuditCollect -Name 'SystemInfo' -Requires 'Get-CompartDiskSystemInfo' -Cache -Script { Get-CompartDiskSystemInfo }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Sistema operacional' -Area 'Sistema' -Impact 'identificacao do SO nao confirmada.'
    } else {
        Write-AuditPairs $c.Data 18
        Add-AuditSection -Title 'Sistema operacional' -Status 'OK' -Pairs $c.Data
        Update-AuditArea 'Sistema' 'Verificado' ''
    }

    $w = Invoke-AuditCollect -Name 'WindowsVersion' -Requires 'Test-WindowsVersion' -Cache -Script { Test-WindowsVersion }
    if ($w.State -ne 'Ok') {
        Add-AuditFinding -Severity 'INFO' -Area 'Sistema' `
            -Message ('Versao do Windows nao pode ser validada: ' + (Get-AuditText $w.Error 'consulta sem retorno' 160)) `
            -Recommendation 'Confirmar build e edicao manualmente (winver).'
        Update-AuditArea 'Sistema' 'Parcial' 'Validacao de versao indisponivel.'
        return
    }

    $familia   = Get-AuditText (Get-AuditValue $w.Data @('Family', 'Familia', 'Nome', 'Caption'))          'Windows'
    $display   = Get-AuditText (Get-AuditValue $w.Data @('DisplayVersion', 'Versao', 'Release'))           'versao nao informada'
    $build     = Get-AuditText (Get-AuditValue $w.Data @('FullBuild', 'Build', 'BuildNumber'))             'build nao informado'
    $edicao    = Get-AuditText (Get-AuditValue $w.Data @('Edition', 'Edicao', 'SKU'))                      ''
    $arq       = Get-AuditText (Get-AuditValue $w.Data @('Architecture', 'Arquitetura', 'OSArchitecture')) ''
    $suportado = ConvertTo-AuditTriState (Get-AuditValue $w.Data @('Supported', 'Suportado'))

    $detalhe = "$familia $display build $build"
    if ($edicao) { $detalhe += " | edicao $edicao" }
    if ($arq)    { $detalhe += " | $arq" }

    switch ($suportado) {
        'True'  { Add-AuditFinding -Severity 'OK' -Area 'Sistema' -Message ('Sistema identificado: ' + $detalhe + '.') }
        'False' {
            # WARN e nao CRIT: "fora da faixa suportada pela ferramenta" nao e,
            # por si so, prova de sistema sem suporte do fabricante.
            Add-AuditFinding -Severity 'WARN' -Area 'Sistema' `
                -Message ('Build fora da faixa suportada por esta ferramenta: ' + $detalhe + '.') `
                -Recommendation 'Confirmar o ciclo de vida da build junto a Microsoft antes de tratar como pendencia de atualizacao.'
        }
        default {
            Add-AuditFinding -Severity 'INFO' -Area 'Sistema' `
                -Message ('Suporte da build nao determinado. ' + $detalhe + '.') `
                -Recommendation 'Verificar manualmente o ciclo de vida da build.'
        }
    }
}

# --------------------------------------------------------------- hardware ---
function Add-AuditHardware {
    $c = Invoke-AuditCollect -Name 'Hardware' -Requires 'Get-CompartDiskHardwareInfo' -Cache -Script { Get-CompartDiskHardwareInfo }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Hardware' -Area 'Hardware' -Impact 'inventario fisico nao confirmado.'
        return
    }

    $pares = $c.Data
    $preenchidos = 0
    if ($pares -is [System.Collections.IDictionary]) {
        foreach ($k in @($pares.Keys)) {
            $v = "$($pares[$k])".Trim()
            if ($v -ne '' -and $v -notmatch '^(?i)(n/?a|desconhecid[oa]|unknown|null)$') { $preenchidos++ }
        }
    }

    Write-AuditPairs $pares 18

    # Ausencia de um componente (TPM, GPU dedicada, chassi em VM) nao e erro.
    $esperados = @('Fabricante', 'Modelo', 'CPU', 'RAM', 'Placa-mae', 'BIOS', 'TPM', 'GPU')
    $faltando = @()
    foreach ($e in $esperados) {
        if ($null -eq (Get-AuditValue $pares @($e))) { $faltando += $e }
    }

    if ($preenchidos -eq 0) {
        Add-AuditSection -Title 'Hardware' -Status 'WARN' -Pairs $pares -Summary 'Consulta retornou estrutura sem valores utilizaveis.'
        Add-AuditFinding -Severity 'WARN' -Area 'Hardware' -Message 'Inventario de hardware retornou vazio.' `
            -Recommendation 'Validar o servico WMI/CIM (Winmgmt) e reexecutar.'
        Update-AuditArea 'Hardware' 'Nao verificado' 'Sem valores utilizaveis.'
        return
    }

    $resumo = "$preenchidos item(ns) coletado(s)."
    $status = 'OK'
    if ($faltando.Count -gt 0) {
        $resumo += (" Sem dado para: {0} (pode ser ausencia real do componente, virtualizacao ou consulta restrita)." -f ($faltando -join ', '))
        Update-AuditArea 'Hardware' 'Parcial' ("Sem dado para: " + ($faltando -join ', '))
    } else {
        Update-AuditArea 'Hardware' 'Verificado' ''
    }
    Add-AuditSection -Title 'Hardware' -Status $status -Pairs $pares -Summary $resumo
}

# ------------------------------------------------------- discos e volumes ---
function Get-AuditVolumeKind {
    <# Classifica o volume para evitar recomendacao indevida em particao especial. #>
    param($Volume)
    $letra  = Get-AuditText (Get-AuditValue $Volume @('Volume', 'Letra', 'DriveLetter', 'Unidade')) ''
    $rotulo = Get-AuditText (Get-AuditValue $Volume @('Rotulo', 'Label', 'FriendlyName', 'Nome'))   ''
    $tipo   = Get-AuditText (Get-AuditValue $Volume @('Tipo', 'DriveType', 'Midia'))                ''
    $fs     = Get-AuditText (Get-AuditValue $Volume @('SistemaDeArquivos', 'FileSystem', 'FS'))     ''
    $todos  = Get-AuditNormalKey ("$letra $rotulo $tipo $fs")

    if ($todos -match 'removivel|removable|usb|pendrive') { return 'Removivel' }
    if ($todos -match 'recovery|recuperacao|winre|reservad|efi|system|oem|restaur') { return 'Especial' }
    if ($fs -match '(?i)fat32' -and $letra -eq '')                                  { return 'Especial' }
    if ($letra -eq '')                                                              { return 'Especial' }

    $sysDrive = "$env:SystemDrive".TrimEnd('\')
    if (-not $sysDrive) { $sysDrive = 'C:' }
    if ($letra.ToUpperInvariant().StartsWith($sysDrive.ToUpperInvariant())) { return 'Sistema' }
    return 'Dados'
}

function Add-AuditDisks {
    # ---- discos fisicos ----
    $c = Invoke-AuditCollect -Name 'DiskInfo' -Requires 'Get-CompartDiskDiskInfo' -Cache -Script { Get-CompartDiskDiskInfo }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Discos fisicos' -Area 'Disco' -Impact 'saude dos discos nao verificada.'
    } else {
        $niveis = @()
        $degradados = 0; $avisos = 0; $desconhecidos = 0
        foreach ($x in $c.Items) {
            $modelo = Get-AuditText (Get-AuditValue $x @('Modelo', 'Model', 'FriendlyName')) 'disco sem identificacao'
            $bruto  = Get-AuditValue $x @('Saude', 'Health', 'HealthStatus', 'Status')
            $texto  = Get-AuditNormalKey "$bruto"

            if     ($texto -match 'unhealthy|insalubre|failed|falha|bad|critical')       { $classe = 'Degradado' }
            elseif ($texto -match 'warning|aviso|degraded|degradad|predict')             { $classe = 'Aviso' }
            elseif ($texto -match 'healthy|saudavel|ok|normal|good')                     { $classe = 'Saudavel' }
            elseif ($texto -eq '' -or $texto -match 'unknown|desconhecid|indisponiv')    { $classe = 'Desconhecido' }
            else                                                                        { $classe = 'Desconhecido' }

            switch ($classe) {
                'Degradado' {
                    $degradados++
                    $niveis += 'CRIT'
                    Add-AuditFinding -Severity 'CRIT' -Area 'Disco' `
                        -Message ("Disco '{0}' reportado pelo subsistema de armazenamento como '{1}'." -f $modelo, (Get-AuditText $bruto 'estado nao textual')) `
                        -Recommendation 'Evidencia de degradacao: priorizar backup dos dados e confirmar com SMART/ferramenta do fabricante antes de decidir substituicao.'
                }
                'Aviso' {
                    $avisos++
                    $niveis += 'WARN'
                    Add-AuditFinding -Severity 'WARN' -Area 'Disco' `
                        -Message ("Disco '{0}' em estado de aviso ('{1}')." -f $modelo, (Get-AuditText $bruto 'estado nao textual')) `
                        -Recommendation 'Coletar atributos SMART e historico de eventos de disco antes de qualquer conclusao sobre falha fisica.'
                }
                'Desconhecido' {
                    $desconhecidos++
                    $niveis += 'INFO'
                }
                default { $niveis += 'OK' }
            }
        }
        if ($desconhecidos -gt 0) {
            Add-AuditFinding -Severity 'INFO' -Area 'Disco' `
                -Message ("{0} disco(s) sem estado de saude legivel (comum em controladoras RAID, virtualizacao e USB)." -f $desconhecidos) `
                -Recommendation 'Consultar a ferramenta do fabricante/controladora para obter a saude real.'
        }
        if ($degradados -eq 0 -and $avisos -eq 0 -and $desconhecidos -eq 0 -and $c.Count -gt 0) {
            Add-AuditFinding -Severity 'OK' -Area 'Disco' -Message ("{0} disco(s) fisico(s) reportado(s) como saudavel(is)." -f $c.Count)
        }
        Add-AuditSection -Title 'Discos fisicos' -Status (Resolve-AuditStatus $niveis) -Rows $c.Items `
            -Summary ("{0} disco(s) | degradados: {1} | avisos: {2} | sem leitura de saude: {3}" -f $c.Count, $degradados, $avisos, $desconhecidos)
        Write-AuditTable $c.Items @('Modelo', 'Midia', 'Tamanho', 'Saude')
        Update-AuditArea 'Disco' 'Verificado' ''
    }

    # ---- volumes ----
    $v = Invoke-AuditCollect -Name 'VolumeInfo' -Requires 'Get-CompartDiskVolumeInfo' -Cache -Script { Get-CompartDiskVolumeInfo }
    if ($v.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $v -Title 'Volumes' -Area 'Volumes' -Impact 'ocupacao de disco nao verificada.'
        return
    }

    $niveis = @(); $semPct = 0; $criticos = 0; $atencao = 0
    foreach ($x in $v.Items) {
        $nome = Get-AuditText (Get-AuditValue $x @('Volume', 'Letra', 'DriveLetter', 'Unidade', 'Rotulo')) 'volume sem identificacao'
        $pct  = ConvertTo-AuditNumber (Get-AuditValue $x @('UsadoPct', 'Usado%', 'PercentUsado', 'UsedPct', 'Uso'))
        $tipo = Get-AuditVolumeKind $x

        if ($null -eq $pct) {
            # Fallback: deriva o percentual de tamanho/livre quando disponivel.
            $tam  = ConvertTo-AuditNumber (Get-AuditValue $x @('Tamanho', 'Size', 'TamanhoGB', 'Total'))
            $liv  = ConvertTo-AuditNumber (Get-AuditValue $x @('Livre', 'Free', 'LivreGB', 'EspacoLivre'))
            if ($null -ne $tam -and $tam -gt 0 -and $null -ne $liv) { $pct = [Math]::Round((($tam - $liv) / $tam) * 100, 1) }
        }
        if ($null -eq $pct) { $semPct++; $niveis += 'INFO'; continue }

        if ($tipo -eq 'Especial' -or $tipo -eq 'Removivel') {
            # Particao de recuperacao/EFI/OEM opera cheia por projeto: nunca CRIT.
            if ($pct -ge 95) {
                $niveis += 'INFO'
                Add-AuditFinding -Severity 'INFO' -Area 'Volumes' `
                    -Message ("Volume {0} ({1}) com {2}% de ocupacao." -f $nome, $tipo, $pct) `
                    -Recommendation 'Comportamento esperado em particoes de sistema/recuperacao/removiveis. Nao executar limpeza nessas particoes.'
            } else { $niveis += 'OK' }
            continue
        }

        if ($pct -ge 90) {
            $criticos++; $niveis += 'CRIT'
            $rec = if ($tipo -eq 'Sistema') {
                'Liberar espaco no volume de sistema (temporarios, caches, downloads, pontos de restauracao antigos). Nao remover particoes de recuperacao.'
            } else {
                'Avaliar arquivos de maior tamanho e politica de retencao antes de qualquer exclusao.'
            }
            Add-AuditFinding -Severity 'CRIT' -Area 'Volumes' -Message ("Volume {0} ({1}) com {2}% de ocupacao." -f $nome, $tipo, $pct) -Recommendation $rec
        } elseif ($pct -ge 80) {
            $atencao++; $niveis += 'WARN'
            Add-AuditFinding -Severity 'WARN' -Area 'Volumes' `
                -Message ("Volume {0} ({1}) com {2}% de ocupacao." -f $nome, $tipo, $pct) `
                -Recommendation 'Monitorar o crescimento; ainda sem impacto imediato.'
        } else { $niveis += 'OK' }
    }

    if ($semPct -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'Volumes' `
            -Message ("{0} volume(s) sem percentual de uso legivel." -f $semPct) `
            -Recommendation 'Ocupacao desses volumes nao foi avaliada.'
    }
    Add-AuditSection -Title 'Volumes' -Status (Resolve-AuditStatus $niveis) -Rows $v.Items `
        -Summary ("{0} volume(s) | >=90%: {1} | >=80%: {2} | sem leitura: {3}" -f $v.Count, $criticos, $atencao, $semPct)
    Write-AuditTable $v.Items
    if ($semPct -gt 0) { Update-AuditArea 'Volumes' 'Parcial' "$semPct volume(s) sem percentual." }
    else { Update-AuditArea 'Volumes' 'Verificado' '' }
}

# ------------------------------------------------------------------- rede ---
function Add-AuditNetwork {
    $ativas = 0
    $c = Invoke-AuditCollect -Name 'NetworkInfo' -Requires 'Get-CompartDiskNetworkInfo' -Cache -Script { Get-CompartDiskNetworkInfo }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Rede' -Area 'Rede' -Impact 'interfaces de rede nao enumeradas.'
    } else {
        foreach ($i in $c.Items) {
            $st = ConvertTo-AuditTriState (Get-AuditValue $i @('Status', 'Estado', 'Conectado', 'Up'))
            $ip = Get-AuditValue $i @('IP', 'IPv4', 'Endereco', 'IPAddress')
            if ($st -eq 'True' -or ($null -ne $ip -and "$ip" -notmatch '^(0\.0\.0\.0|169\.254\.)')) { $ativas++ }
        }
        Add-AuditSection -Title 'Rede' -Status $(if ($ativas -gt 0) { 'OK' } else { 'WARN' }) -Rows $c.Items `
            -Summary ("{0} interface(s) | com endereco/ativa(s): {1}" -f $c.Count, $ativas)
        Write-AuditTable $c.Items
        if ($ativas -eq 0) {
            Add-AuditFinding -Severity 'WARN' -Area 'Rede' `
                -Message 'Nenhuma interface com endereco valido identificada.' `
                -Recommendation 'Confirmar cabo/Wi-Fi e estado do adaptador. Evidencia local, ainda nao conclusiva sobre falha de hardware.'
        }
        Update-AuditArea 'Rede' 'Verificado' ''
    }

    # ---- conectividade ----
    $t = Invoke-AuditCollect -Name 'TestInternet' -Requires 'Test-Internet' -Cache -Script { Test-Internet }
    if ($t.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $t -Title 'Conectividade' -Area 'Conectividade' -Impact 'saida para a internet nao testada.' -Severity 'INFO'
        return
    }

    $online  = ConvertTo-AuditTriState (Get-AuditValue $t.Data @('Online', 'Conectado'))
    $dns     = ConvertTo-AuditTriState (Get-AuditValue $t.Data @('DnsOk', 'DNS', 'ResolucaoDNS'))
    $metodo  = Get-AuditText (Get-AuditValue $t.Data @('Method', 'Metodo')) 'metodo nao informado'
    $lat     = Get-AuditText (Get-AuditValue $t.Data @('Latency', 'Latencia')) 'nao medida'

    $pares = [ordered]@{
        'Online'             = $(switch ($online) { 'True' { 'Sim' } 'False' { 'Nao' } default { 'Nao determinado' } })
        'Metodo'             = $metodo
        'Latencia'           = $lat
        'Resolucao DNS'      = $(switch ($dns) { 'True' { 'Sim' } 'False' { 'Nao' } default { 'Nao determinado' } })
        'Interfaces ativas'  = $ativas
        'Observacao'         = 'Teste depende de saida direta para a internet; proxy, firewall corporativo ou rede isolada produzem resultado negativo sem que haja defeito local.'
    }

    if ($online -eq 'True') {
        Add-AuditSection -Title 'Conectividade' -Status 'OK' -Pairs $pares
        Add-AuditFinding -Severity 'OK' -Area 'Conectividade' -Message ("Conectividade externa confirmada via {0}." -f $metodo)
        Update-AuditArea 'Conectividade' 'Verificado' ''
    } elseif ($online -eq 'Unknown') {
        Add-AuditSection -Title 'Conectividade' -Status 'INFO' -Pairs $pares -Summary 'Resultado do teste nao interpretavel.'
        Add-AuditFinding -Severity 'INFO' -Area 'Conectividade' -Message 'Estado de conectividade nao determinado pelo teste.' `
            -Recommendation 'Validar manualmente antes de qualquer conclusao.'
        Update-AuditArea 'Conectividade' 'Nao verificado' 'Retorno nao interpretavel.'
    } else {
        # Sem internet nao e, isoladamente, defeito da maquina.
        if ($dns -eq 'True') {
            Add-AuditSection -Title 'Conectividade' -Status 'WARN' -Pairs $pares -Summary 'DNS respondeu, saida externa nao confirmada: padrao tipico de proxy/filtro.'
            Add-AuditFinding -Severity 'WARN' -Area 'Conectividade' `
                -Message ('Resolucao DNS funcional, porem o teste de saida ({0}) nao obteve resposta.' -f $metodo) `
                -Recommendation 'Verificar proxy, inspecao TLS ou bloqueio de ICMP/HTTP na borda antes de tratar como falha local.'
        } elseif ($ativas -eq 0) {
            Add-AuditSection -Title 'Conectividade' -Status 'CRIT' -Pairs $pares -Summary 'Sem interface ativa e sem saida externa.'
            Add-AuditFinding -Severity 'CRIT' -Area 'Conectividade' `
                -Message 'Nenhuma interface com endereco valido e teste de saida sem resposta: evidencia consistente de falha local de rede.' `
                -Recommendation 'Verificar adaptador, cabo/Wi-Fi e pilha TCP/IP. Nao aplicar reset de rede sem confirmar o diagnostico.'
        } else {
            Add-AuditSection -Title 'Conectividade' -Status 'WARN' -Pairs $pares -Summary 'Interface ativa, saida externa nao confirmada.'
            Add-AuditFinding -Severity 'WARN' -Area 'Conectividade' `
                -Message ('Interface ativa presente, mas o teste de saida ({0}) nao obteve resposta e o DNS nao foi confirmado.' -f $metodo) `
                -Recommendation 'Diferenciar ambiente isolado/proxy de falha real antes de qualquer intervencao.'
        }
        Update-AuditArea 'Conectividade' 'Verificado' 'Saida externa nao confirmada.'
    }
}

# -------------------------------------------------------------- seguranca ---
function Add-AuditSecurity {
    $c = Invoke-AuditCollect -Name 'SecurityPosture' -Requires 'Get-CompartDiskSecurityPosture' -Cache -Script { Get-CompartDiskSecurityPosture }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Postura de seguranca' -Area 'Seguranca' -Impact 'UAC e Secure Boot nao verificados.'
    } else {
        $niveis = @()
        $uac = ConvertTo-AuditTriState (Get-AuditValue $c.Data @('UAC', 'ControleDeContaDeUsuario'))
        switch ($uac) {
            'False' {
                $niveis += 'CRIT'
                Add-AuditFinding -Severity 'CRIT' -Area 'Seguranca' -Message 'UAC desabilitado (elevacao silenciosa possivel).' `
                    -Recommendation 'Reativar o Controle de Conta de Usuario apos validar dependencias de aplicacoes legadas.'
            }
            'True'  { $niveis += 'OK'; Add-AuditFinding -Severity 'OK' -Area 'Seguranca' -Message 'UAC habilitado.' }
            default {
                $niveis += 'INFO'
                Add-AuditFinding -Severity 'INFO' -Area 'Seguranca' -Message 'Estado do UAC nao determinado.' `
                    -Recommendation 'Verificar manualmente; ausencia de leitura nao indica desabilitado.'
            }
        }

        $sb = Get-AuditValue $c.Data @('SecureBoot', 'Secure Boot', 'InicializacaoSegura')
        $sbTri = ConvertTo-AuditTriState $sb
        $sbTexto = Get-AuditNormalKey "$sb"
        if ($sbTexto -match 'naosuportad|notsupported|indisponiv|legacy|bios') {
            $niveis += 'INFO'
            Add-AuditFinding -Severity 'INFO' -Area 'Seguranca' -Message 'Secure Boot nao suportado neste firmware (BIOS legado ou plataforma virtual).' `
                -Recommendation 'Condicao de plataforma, nao configuracao incorreta.'
        } else {
            switch ($sbTri) {
                'False' {
                    $niveis += 'WARN'
                    Add-AuditFinding -Severity 'WARN' -Area 'Seguranca' -Message 'Secure Boot desabilitado.' `
                        -Recommendation 'Avaliar reativacao no firmware; pode estar desabilitado por exigencia de dual boot ou driver nao assinado.'
                }
                'True'  { $niveis += 'OK'; Add-AuditFinding -Severity 'OK' -Area 'Seguranca' -Message 'Secure Boot habilitado.' }
                default { $niveis += 'INFO'; Add-AuditFinding -Severity 'INFO' -Area 'Seguranca' -Message 'Estado do Secure Boot nao determinado.' }
            }
        }

        Write-AuditPairs $c.Data 22
        Add-AuditSection -Title 'Postura de seguranca' -Status (Resolve-AuditStatus $niveis) -Pairs $c.Data
        Update-AuditArea 'Seguranca' 'Verificado' ''
    }

    # ---- firewall por perfil ----
    $f = Invoke-AuditCollect -Name 'Firewall' -Requires 'Get-CompartDiskFirewallInfo' -Cache -Script { Get-CompartDiskFirewallInfo }
    if ($f.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $f -Title 'Firewall' -Area 'Firewall' -Impact 'estado dos perfis de firewall nao verificado.'
        return
    }

    $niveis = @(); $desabilitados = @(); $habilitados = @(); $indefinidos = @(); $ativoDesabilitado = $false; $ativoConhecido = $false
    foreach ($p in $f.Items) {
        $perfil = Get-AuditText (Get-AuditValue $p @('Perfil', 'Profile', 'Nome', 'Name')) 'perfil sem nome'
        $hab    = ConvertTo-AuditTriState (Get-AuditValue $p @('Habilitado', 'Enabled', 'Ativo', 'Estado'))
        $atv    = ConvertTo-AuditTriState (Get-AuditValue $p @('PerfilAtivo', 'Ativo', 'Conectado', 'Active', 'EmUso'))
        if ($atv -eq 'True') { $ativoConhecido = $true }

        switch ($hab) {
            'True'  { $habilitados += $perfil }
            'False' {
                $desabilitados += $perfil
                if ($atv -eq 'True') { $ativoDesabilitado = $true }
            }
            default { $indefinidos += $perfil }
        }
    }

    if ($ativoDesabilitado) {
        $niveis += 'CRIT'
        Add-AuditFinding -Severity 'CRIT' -Area 'Firewall' `
            -Message ("Perfil de firewall em uso esta desabilitado ({0})." -f ($desabilitados -join ', ')) `
            -Recommendation 'Confirmar se a desativacao e imposta por politica corporativa antes de reativar.'
    } elseif ($desabilitados.Count -gt 0 -and $desabilitados.Count -eq $f.Count) {
        $niveis += 'CRIT'
        Add-AuditFinding -Severity 'CRIT' -Area 'Firewall' -Message 'Todos os perfis de firewall estao desabilitados.' `
            -Recommendation 'Verificar se ha solucao de firewall de terceiros gerenciando a protecao antes de concluir por exposicao.'
    } elseif ($desabilitados.Count -gt 0) {
        $niveis += 'WARN'
        $obs = if ($ativoConhecido) { 'O perfil atualmente em uso permanece habilitado.' } else { 'Nao foi possivel identificar qual perfil esta em uso.' }
        Add-AuditFinding -Severity 'WARN' -Area 'Firewall' `
            -Message ("Perfil(is) desabilitado(s): {0}. {1}" -f ($desabilitados -join ', '), $obs) `
            -Recommendation 'Avaliar necessidade por perfil; perfil inativo desabilitado tem impacto menor que perfil em uso.'
    }
    if ($indefinidos.Count -gt 0) {
        $niveis += 'INFO'
        Add-AuditFinding -Severity 'INFO' -Area 'Firewall' -Message ("Perfil(is) com estado nao legivel: {0}." -f ($indefinidos -join ', ')) `
            -Recommendation 'Consulta pode exigir elevacao ou estar restrita por politica.'
    }
    if ($desabilitados.Count -eq 0 -and $indefinidos.Count -eq 0 -and $f.Count -gt 0) {
        $niveis += 'OK'
        Add-AuditFinding -Severity 'OK' -Area 'Firewall' -Message ("Todos os {0} perfis de firewall estao habilitados." -f $f.Count)
    }

    Add-AuditSection -Title 'Firewall' -Status (Resolve-AuditStatus $niveis) -Rows $f.Items `
        -Summary ("Habilitados: {0} | desabilitados: {1} | nao legiveis: {2}" -f $habilitados.Count, $desabilitados.Count, $indefinidos.Count)
    Write-AuditTable $f.Items
    Update-AuditArea 'Firewall' $(if ($indefinidos.Count -gt 0) { 'Parcial' } else { 'Verificado' }) ''
}

# ---------------------------------------------------- antivirus e defender ---
function Add-AuditAntimalware {
    $terceiroAtivo = $false
    $terceiros = @()

    $av = Invoke-AuditCollect -Name 'AntivirusProducts' -Requires 'Get-CompartDiskAntivirusProducts' -Cache -Script { Get-CompartDiskAntivirusProducts }
    if ($av.State -eq 'Ok') {
        foreach ($p in $av.Items) {
            $nome = Get-AuditText (Get-AuditValue $p @('Produto', 'Nome', 'Name', 'DisplayName')) 'produto sem nome'
            $est  = Get-AuditValue $p @('Estado', 'Status', 'Ativo', 'State')
            $tri  = ConvertTo-AuditTriState $est
            if ($nome -notmatch '(?i)defender|windows security') {
                $terceiros += $nome
                if ($tri -ne 'False') { $terceiroAtivo = $true }   # ausencia de leitura nao prova inatividade
            }
        }
        Add-AuditSection -Title 'Produtos antivirus' -Status 'INFO' -Rows $av.Items `
            -Summary ("{0} produto(s) registrado(s) no Security Center | de terceiros: {1}" -f $av.Count, $terceiros.Count)
        Write-AuditTable $av.Items
        Update-AuditArea 'Antivirus' 'Verificado' ''
    } elseif ($av.State -eq 'Vazio') {
        Add-AuditSection -Title 'Produtos antivirus' -Status 'INFO' -Summary 'Security Center nao retornou produtos registrados (comum em Windows Server e em algumas politicas).'
        Update-AuditArea 'Antivirus' 'Parcial' 'Sem produtos retornados.'
    } else {
        Add-AuditNotCollected -Collect $av -Title 'Produtos antivirus' -Area 'Antivirus' -Impact 'presenca de antivirus de terceiros nao confirmada.' -Severity 'INFO'
    }

    $def = Invoke-AuditCollect -Name 'DefenderStatus' -Requires 'Get-CompartDiskDefenderStatus' -Cache -Script { Get-CompartDiskDefenderStatus }
    if ($def.State -ne 'Ok') {
        $extra = if ($terceiroAtivo) { (" Ha antivirus de terceiros registrado ({0}), o que explica a indisponibilidade do Defender." -f ($terceiros -join ', ')) } else { '' }
        Add-AuditSection -Title 'Microsoft Defender' -Status 'INFO' `
            -Summary ('Estado nao verificado: modulo Defender indisponivel, consulta recusada ou substituido por terceiros.' + $extra)
        Add-AuditFinding -Severity 'INFO' -Area 'Defender' -Message ('Estado do Microsoft Defender nao pode ser consultado.' + $extra) `
            -Recommendation 'Verificar em Seguranca do Windows. Consulta indisponivel nao equivale a protecao desativada.'
        Update-AuditArea 'Defender' 'Nao verificado' 'Consulta indisponivel.'
        if (-not $terceiroAtivo) { Update-AuditResult 'WARN' 'Estado do Defender nao verificado.' }
        return
    }

    $rtp  = ConvertTo-AuditTriState (Get-AuditValue $def.Data @('ProtecaoEmTempoReal', 'RealTimeProtection', 'TempoReal', 'RTP'))
    $svc  = ConvertTo-AuditTriState (Get-AuditValue $def.Data @('Servico', 'Service', 'AntimalwareService', 'ServicoAtivo'))
    $comp = ConvertTo-AuditTriState (Get-AuditValue $def.Data @('Comportamento', 'BehaviorMonitor', 'MonitoramentoDeComportamento'))
    $tamp = ConvertTo-AuditTriState (Get-AuditValue $def.Data @('TamperProtection', 'ProtecaoContraAdulteracao'))
    $assin = Get-AuditValue $def.Data @('Assinatura', 'Signature', 'VersaoAssinatura', 'AntivirusSignatureVersion')
    $idade = ConvertTo-AuditNumber (Get-AuditValue $def.Data @('IdadeAssinatura', 'SignatureAge', 'DiasAssinatura'))

    $niveis = @()
    switch ($rtp) {
        'True' {
            $niveis += 'OK'
            Add-AuditFinding -Severity 'OK' -Area 'Defender' -Message 'Protecao em tempo real do Microsoft Defender ativa.'
        }
        'False' {
            if ($terceiroAtivo) {
                # Modo passivo por antivirus de terceiros nao e vulnerabilidade.
                $niveis += 'INFO'
                Add-AuditFinding -Severity 'INFO' -Area 'Defender' `
                    -Message ("Defender com protecao em tempo real inativa; ha antivirus de terceiros registrado ({0}), configuracao esperada de modo passivo." -f ($terceiros -join ', ')) `
                    -Recommendation 'Confirmar que o produto de terceiros esta atualizado e com protecao ativa.'
            } else {
                $niveis += 'CRIT'
                Add-AuditFinding -Severity 'CRIT' -Area 'Defender' `
                    -Message 'Protecao em tempo real desabilitada e nenhum antivirus de terceiros ativo identificado.' `
                    -Recommendation 'Reativar em Seguranca do Windows; verificar se ha politica de grupo forcando a desativacao.'
            }
        }
        default {
            $niveis += 'INFO'
            Add-AuditFinding -Severity 'INFO' -Area 'Defender' -Message 'Protecao em tempo real com estado nao legivel.' `
                -Recommendation 'Verificar manualmente; leitura ausente nao indica desativacao.'
        }
    }
    if ($svc -eq 'False') {
        $niveis += 'WARN'
        Add-AuditFinding -Severity 'WARN' -Area 'Defender' -Message 'Servico de antimalware reportado como parado.' `
            -Recommendation 'Verificar se ha antivirus de terceiros gerenciando a protecao antes de qualquer acao.'
    }
    if ($comp -eq 'False') { $niveis += 'WARN'; Add-AuditFinding -Severity 'WARN' -Area 'Defender' -Message 'Monitoramento de comportamento desativado.' }
    if ($tamp -eq 'False') { $niveis += 'WARN'; Add-AuditFinding -Severity 'WARN' -Area 'Defender' -Message 'Protecao contra adulteracao (tamper protection) desativada.' }
    if ($null -ne $idade -and $idade -gt 7) {
        $niveis += 'WARN'
        Add-AuditFinding -Severity 'WARN' -Area 'Defender' -Message ("Assinaturas com {0} dia(s) de defasagem (versao {1})." -f $idade, (Get-AuditText $assin 'nao informada')) `
            -Recommendation 'Verificar conectividade com o servico de atualizacao de definicoes.'
    }

    Write-AuditPairs $def.Data 24
    Add-AuditSection -Title 'Microsoft Defender' -Status (Resolve-AuditStatus $niveis) -Pairs $def.Data
    Update-AuditArea 'Defender' 'Verificado' ''
}

# -------------------------------------------------------------- bitlocker ---
function Add-AuditBitLocker {
    $c = Invoke-AuditCollect -Name 'BitLocker' -Requires 'Test-BitLocker' -Cache -Script { Test-BitLocker }

    if ($c.State -eq 'Vazio') {
        # Secao sempre presente: antes ela sumia do relatorio e o leitor nao
        # conseguia distinguir "sem BitLocker" de "nao verificado".
        Add-AuditSection -Title 'BitLocker' -Status 'INFO' `
            -Summary 'Nenhum volume com informacao de BitLocker retornada (ausencia de TPM, edicao sem suporte ou consulta restrita sem elevacao).'
        Add-AuditFinding -Severity 'INFO' -Area 'BitLocker' -Message 'Nenhum volume com dados de BitLocker retornado.' `
            -Recommendation 'Confirmar edicao do Windows, presenca de TPM e elevacao antes de concluir que nao ha criptografia.'
        Update-AuditArea 'BitLocker' 'Nao verificado' 'Sem retorno.'
        return
    }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'BitLocker' -Area 'BitLocker' -Impact 'criptografia de disco nao verificada.'
        return
    }

    $niveis = @(); $protegidos = 0; $parciais = 0; $desprotegidos = 0; $indefinidos = 0
    foreach ($v in $c.Items) {
        $nome = Get-AuditText (Get-AuditValue $v @('Volume', 'Letra', 'DriveLetter', 'Unidade')) 'volume'
        $prot = ConvertTo-AuditTriState (Get-AuditValue $v @('Protecao', 'Protection', 'ProtectionStatus', 'Protegido', 'Status'))
        $pct  = ConvertTo-AuditNumber   (Get-AuditValue $v @('PercentualCriptografado', 'EncryptionPercentage', 'Percentual', 'Progresso'))
        $sysDrive = "$env:SystemDrive".TrimEnd('\')
        if (-not $sysDrive) { $sysDrive = 'C:' }
        $ehSistema = ($nome -and $nome.ToUpperInvariant().StartsWith($sysDrive.ToUpperInvariant()))

        if ($prot -eq 'True' -and ($null -eq $pct -or $pct -ge 100)) { $protegidos++; $niveis += 'OK'; continue }
        if ($null -ne $pct -and $pct -gt 0 -and $pct -lt 100) {
            $parciais++; $niveis += 'WARN'
            Add-AuditFinding -Severity 'WARN' -Area 'BitLocker' -Message ("Volume {0} parcialmente criptografado ({1}%)." -f $nome, $pct) `
                -Recommendation 'Aguardar a conclusao da criptografia; volume ainda nao esta plenamente protegido.'
            continue
        }
        if ($prot -eq 'False') {
            $desprotegidos++
            if ($ehSistema) {
                $niveis += 'WARN'
                Add-AuditFinding -Severity 'WARN' -Area 'BitLocker' -Message ("Volume de sistema {0} sem criptografia ativa." -f $nome) `
                    -Recommendation 'Avaliar conforme a politica da organizacao e o risco de furto/extravio. Ausencia de BitLocker nao e, por si so, falha critica.'
            } else {
                $niveis += 'INFO'
                Add-AuditFinding -Severity 'INFO' -Area 'BitLocker' -Message ("Volume {0} sem criptografia ativa." -f $nome)
            }
            continue
        }
        $indefinidos++; $niveis += 'INFO'
    }
    if ($indefinidos -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'BitLocker' -Message ("{0} volume(s) com estado de protecao nao legivel." -f $indefinidos) `
            -Recommendation 'Consulta pode exigir elevacao.'
    }
    if ($protegidos -gt 0 -and $parciais -eq 0 -and $desprotegidos -eq 0) {
        Add-AuditFinding -Severity 'OK' -Area 'BitLocker' -Message ("{0} volume(s) com BitLocker ativo." -f $protegidos)
    }

    Add-AuditSection -Title 'BitLocker' -Status (Resolve-AuditStatus $niveis) -Rows $c.Items `
        -Summary ("Protegidos: {0} | parciais: {1} | sem criptografia: {2} | nao legiveis: {3}" -f $protegidos, $parciais, $desprotegidos, $indefinidos)
    Write-AuditTable $c.Items
    Update-AuditArea 'BitLocker' $(if ($indefinidos -gt 0) { 'Parcial' } else { 'Verificado' }) ''
}

# --------------------------------------------------------- windows update ---
function Add-AuditWindowsUpdate {
    $c = Invoke-AuditCollect -Name 'WindowsUpdate' -Requires 'Get-CompartDiskWindowsUpdateInfo' -Cache -Script { Get-CompartDiskWindowsUpdateInfo }

    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Windows Update' -Area 'Windows Update' -Impact 'estado das atualizacoes nao verificado.'
    } else {
        $niveis = @()
        $reinicioWU = ConvertTo-AuditTriState (Get-AuditValue $c.Data @('ReinicioPendente', 'RebootPending', 'ReinicializacaoPendente'))
        $servico    = ConvertTo-AuditTriState (Get-AuditValue $c.Data @('Servico', 'Service', 'ServicoWU', 'wuauserv'))
        # (o veredito de reinicio e consolidado uma unica vez em Add-AuditIntegrity)
        $pendentes  = ConvertTo-AuditNumber   (Get-AuditValue $c.Data @('AtualizacoesPendentes', 'Pendentes', 'PendingUpdates'))

        if ($reinicioWU -eq 'True') {
            $niveis += 'WARN'
            Add-AuditFinding -Severity 'WARN' -Area 'Windows Update' -Message 'Reinicializacao pendente para concluir atualizacoes.' `
                -Recommendation 'Condicao operacional comum: agendar reinicio em janela adequada. Nao caracteriza falha do sistema.'
        }
        if ($servico -eq 'False') {
            $niveis += 'WARN'
            Add-AuditFinding -Severity 'WARN' -Area 'Windows Update' -Message 'Servico do Windows Update reportado como inativo.' `
                -Recommendation 'Servico pode estar em inicializacao manual/sob demanda por projeto ou controlado por WSUS/politica. Validar antes de alterar.'
        }
        if ($null -ne $pendentes -and $pendentes -gt 0) {
            $niveis += 'WARN'
            Add-AuditFinding -Severity 'WARN' -Area 'Windows Update' -Message ("{0} atualizacao(oes) pendente(s) de instalacao." -f $pendentes) `
                -Recommendation 'Avaliar a janela de manutencao aplicavel.'
        }

        Write-AuditPairs $c.Data 24
        Add-AuditSection -Title 'Windows Update' -Status (Resolve-AuditStatus $niveis) -Pairs $c.Data
        Update-AuditArea 'Windows Update' 'Verificado' ''
    }

}

function Add-AuditUpdateHistory {
    <# Separado da secao de Windows Update: consulta cara, exclusiva do modo Full. #>
    $h = Invoke-AuditCollect -Name 'UpdateHistory' -Requires 'Get-CompartDiskUpdateHistory' -Cache -Script { Get-CompartDiskUpdateHistory -Max 25 }
    if ($h.State -eq 'Vazio') {
        Add-AuditSection -Title 'Historico de atualizacoes' -Status 'INFO' -Summary 'Historico vazio: pode indicar instalacao recente, limpeza do datastore ou gerenciamento externo (WSUS/Intune).'
        Add-AuditFinding -Severity 'INFO' -Area 'Historico de atualizacoes' -Message 'Historico de atualizacoes vazio.' `
            -Recommendation 'Historico vazio nao comprova ausencia de atualizacoes instaladas.'
        Update-AuditArea 'Historico de atualizacoes' 'Parcial' 'Historico vazio.'
        return
    }
    if ($h.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $h -Title 'Historico de atualizacoes' -Area 'Historico de atualizacoes' -Impact 'falhas recentes de atualizacao nao avaliadas.' -Severity 'INFO'
        return
    }

    $falhas = @()
    foreach ($u in $h.Items) {
        $res = Get-AuditNormalKey "$(Get-AuditValue $u @('Resultado', 'Result', 'Status'))"
        if ($res -match 'falh|fail|erro|error|cancel') { $falhas += $u }
    }
    $status = 'INFO'
    if ($falhas.Count -gt 0) {
        $status = 'WARN'
        foreach ($u in ($falhas | Select-Object -First 5)) {
            $kb   = Get-AuditText (Get-AuditValue $u @('KB', 'Titulo', 'Title', 'Update')) 'atualizacao sem identificacao' 90
            $data = Get-AuditText (Get-AuditValue $u @('Data', 'Date', 'InstaladoEm')) 'data nao informada'
            $err  = Get-AuditText (Get-AuditValue $u @('Erro', 'Error', 'HResult', 'Codigo')) 'codigo nao informado'
            Add-AuditFinding -Severity 'WARN' -Area 'Historico de atualizacoes' `
                -Message ("Falha de instalacao: {0} | data: {1} | codigo: {2}." -f $kb, $data, $err) `
                -Recommendation 'Consultar o codigo de erro especifico antes de qualquer acao; falha isolada pode ter sido superada por instalacao posterior.'
        }
    } else {
        Add-AuditFinding -Severity 'OK' -Area 'Historico de atualizacoes' -Message ("Nenhuma falha nas ultimas {0} entradas do historico." -f $h.Count)
    }
    Add-AuditSection -Title 'Historico de atualizacoes' -Status $status -Rows $h.Items `
        -Summary ("{0} entrada(s) analisada(s) (limite 25) | falhas: {1}" -f $h.Count, $falhas.Count)
    Update-AuditArea 'Historico de atualizacoes' 'Verificado' ''
}

# -------------------------------------------------------------- drivers ----
$script:DriverErrorMap = @{
    '1'  = 'dispositivo nao configurado corretamente'
    '3'  = 'driver corrompido ou memoria insuficiente'
    '10' = 'dispositivo nao pode iniciar'
    '12' = 'recursos livres insuficientes'
    '14' = 'requer reinicializacao'
    '18' = 'reinstalacao de driver requerida'
    '19' = 'informacoes de configuracao incompletas no registro'
    '21' = 'remocao em andamento'
    '22' = 'dispositivo desabilitado'
    '24' = 'dispositivo ausente ou nao instalado completamente'
    '28' = 'drivers nao instalados'
    '31' = 'driver nao pode carregar os recursos necessarios'
    '32' = 'servico de inicializacao do driver desabilitado'
    '37' = 'falha na inicializacao do driver'
    '39' = 'driver corrompido ou ausente'
    '43' = 'dispositivo parado por reportar problema'
    '45' = 'dispositivo nao conectado no momento'
}

function Add-AuditDrivers {
    $c = Invoke-AuditCollect -Name 'Drivers' -Requires 'Get-CompartDiskDriverInfo' -Cache -Script { Get-CompartDiskDriverInfo }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Drivers' -Area 'Drivers' -Impact 'dispositivos com problema nao identificados.'
        return
    }

    # Reaproveita a coleta completa para derivar os problemas; so consulta de
    # novo se o objeto retornado nao expuser codigo/estado de erro.
    $temCodigo = $false
    foreach ($d in ($c.Items | Select-Object -First 5)) {
        if ($null -ne (Get-AuditValue $d @('ConfigManagerErrorCode', 'CodigoErro', 'ErrorCode', 'Codigo', 'Problema'))) { $temCodigo = $true; break }
    }

    $problemas = @()
    if ($temCodigo) {
        foreach ($d in $c.Items) {
            $cod = Get-AuditValue $d @('ConfigManagerErrorCode', 'CodigoErro', 'ErrorCode', 'Codigo', 'Problema')
            $n = ConvertTo-AuditNumber $cod
            if ($null -ne $n -and $n -ne 0) { $problemas += $d }
            elseif ($null -eq $n -and (Get-AuditNormalKey "$cod") -match 'erro|falha|problem') { $problemas += $d }
        }
    } else {
        $p = Invoke-AuditCollect -Name 'DriversProblemas' -Requires 'Get-CompartDiskDriverInfo' -Cache -Script { Get-CompartDiskDriverInfo -OnlyProblems }
        if ($p.State -eq 'Ok') { $problemas = $p.Items }
        elseif ($p.State -ne 'Vazio') {
            Add-AuditFinding -Severity 'INFO' -Area 'Drivers' -Message 'Consulta de dispositivos com problema indisponivel.' `
                -Recommendation 'Verificar o Gerenciador de Dispositivos manualmente.'
        }
    }

    $niveis = @(); $crit = 0; $warn = 0
    foreach ($x in ($problemas | Select-Object -First 15)) {
        $disp = Get-AuditText (Get-AuditValue $x @('Dispositivo', 'Device', 'Nome', 'Name')) 'dispositivo sem nome' 90
        $desc = Get-AuditText (Get-AuditValue $x @('Descricao', 'Description', 'Status')) '' 120
        $fab  = Get-AuditText (Get-AuditValue $x @('Fabricante', 'Manufacturer', 'Provedor')) 'fabricante nao informado' 60
        $cod  = ConvertTo-AuditNumber (Get-AuditValue $x @('ConfigManagerErrorCode', 'CodigoErro', 'ErrorCode', 'Codigo'))
        $chave = if ($null -ne $cod) { "$([int]$cod)" } else { '' }
        $signif = if ($chave -and $script:DriverErrorMap.ContainsKey($chave)) { $script:DriverErrorMap[$chave] } else { '' }

        # Codigos de dispositivo ausente/desconectado nao sao criticos.
        $severidade = 'CRIT'
        if ($chave -eq '' -or $chave -eq '22' -or $chave -eq '24' -or $chave -eq '28' -or $chave -eq '45') { $severidade = 'WARN' }

        $evid = "Dispositivo '$disp'"
        if ($chave)  { $evid += " | codigo $chave" }
        if ($signif) { $evid += " ($signif)" }
        if ($desc)   { $evid += " | $desc" }
        $evid += " | $fab"

        if ($severidade -eq 'CRIT') { $crit++; $niveis += 'CRIT' } else { $warn++; $niveis += 'WARN' }
        Add-AuditFinding -Severity $severidade -Area 'Drivers' -Message $evid `
            -Recommendation 'Confirmar o dispositivo no Gerenciador de Dispositivos e obter o driver correspondente junto ao fabricante. Nao reinstalar sem identificar o codigo e o hardware.'
    }
    $extras = (Get-AuditCount $problemas) - 15
    if ($extras -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'Drivers' -Message ("Mais {0} dispositivo(s) com problema nao detalhado(s) individualmente." -f $extras)
    }

    # Driver sem assinatura e indicio para investigacao, nunca prova de malware.
    $ns = @($c.Items | Where-Object { (ConvertTo-AuditTriState (Get-AuditValue $_ @('Assinado', 'Signed', 'IsSigned'))) -eq 'False' })
    if ($ns.Count -gt 0) {
        $niveis += 'WARN'
        Add-AuditFinding -Severity 'WARN' -Area 'Drivers' -Message ("{0} driver(s) sem assinatura digital." -f $ns.Count) `
            -Recommendation 'Indicio para investigacao de procedencia (comum em drivers OEM antigos e software de virtualizacao). Nao caracteriza malware por si so.'
    }
    if ((Get-AuditCount $problemas) -eq 0) {
        Add-AuditFinding -Severity 'OK' -Area 'Drivers' -Message 'Nenhum dispositivo com codigo de erro identificado.'
    }

    $mostrados = [Math]::Min(100, $c.Count)
    Add-AuditSection -Title 'Drivers' -Status (Resolve-AuditStatus $niveis) -Rows @($c.Items | Select-Object -First 100) `
        -Summary ("{0} driver(s) coletado(s); exibindo {1} | com problema: {2} | sem assinatura: {3}" -f $c.Count, $mostrados, (Get-AuditCount $problemas), $ns.Count)

    if ((Get-AuditCount $problemas) -gt 0) {
        Add-AuditSection -Title 'Dispositivos com problema' -Status (Resolve-AuditStatus @($niveis + 'WARN')) -Rows $problemas `
            -Summary ("{0} dispositivo(s) | criticos: {1} | avisos: {2}" -f (Get-AuditCount $problemas), $crit, $warn)
        Write-AuditTable $problemas @() 160 10
    }
    Update-AuditArea 'Drivers' 'Verificado' ''
}

# --------------------------------------------------------- contas locais ----
$script:ContasSistema = @('guest', 'convidado', 'defaultaccount', 'wdagutilityaccount', 'defaultuser0')

function Add-AuditLocalUsers {
    $c = Invoke-AuditCollect -Name 'LocalUsers' -Requires 'Get-CompartDiskLocalUsers' -Cache -Script { Get-CompartDiskLocalUsers }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Contas locais' -Area 'Contas' -Impact 'contas locais nao enumeradas.'
        return
    }

    $niveis = @(); $semSenha = 0; $convidado = 0
    foreach ($u in $c.Items) {
        $nome = Get-AuditText (Get-AuditValue $u @('Usuario', 'Nome', 'Name', 'User')) 'conta sem nome'
        $hab  = ConvertTo-AuditTriState (Get-AuditValue $u @('Habilitado', 'Enabled', 'Ativo'))
        $sen  = ConvertTo-AuditTriState (Get-AuditValue $u @('SenhaRequerida', 'PasswordRequired', 'RequerSenha'))
        $nk   = Get-AuditNormalKey $nome

        if ($hab -ne 'True') { $niveis += 'OK'; continue }

        if ($script:ContasSistema -contains $nk) {
            $convidado++
            $niveis += 'WARN'
            Add-AuditFinding -Severity 'WARN' -Area 'Contas' -Message ("Conta interna do Windows '{0}' esta habilitada." -f $nome) `
                -Recommendation 'Contas internas costumam permanecer desabilitadas. Confirmar se a habilitacao e intencional antes de qualquer alteracao.'
            continue
        }
        if ($sen -eq 'False') {
            $semSenha++
            $niveis += 'WARN'
            Add-AuditFinding -Severity 'WARN' -Area 'Contas' `
                -Message ("Conta local '{0}' habilitada sem exigencia de senha." -f $nome) `
                -Recommendation 'Validar se e conta de servico, conta gerenciada ou exigencia de aplicacao antes de alterar. Nao desabilitar contas necessarias ao sistema.'
            continue
        }
        $niveis += 'OK'
    }
    if ($semSenha -eq 0 -and $convidado -eq 0) {
        Add-AuditFinding -Severity 'OK' -Area 'Contas' -Message ("{0} conta(s) local(is) enumerada(s), sem condicao de risco evidente." -f $c.Count)
    }

    Add-AuditSection -Title 'Contas locais' -Status (Resolve-AuditStatus $niveis) -Rows $c.Items `
        -Summary ("{0} conta(s) | habilitadas sem senha obrigatoria: {1} | contas internas habilitadas: {2}" -f $c.Count, $semSenha, $convidado)
    Write-AuditTable $c.Items
    Update-AuditArea 'Contas' 'Verificado' ''
}

# ------------------------------------------ servicos, processos e startup ---
function Add-AuditServices {
    $c = Invoke-AuditCollect -Name 'Services' -Requires 'Get-CompartDiskServiceDiagnostics' -Cache -Script { Get-CompartDiskServiceDiagnostics }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Servicos essenciais' -Area 'Servicos' -Impact 'estado dos servicos nao verificado.'
    } else {
        $niveis = @(); $problemas = 0; $informativos = 0
        foreach ($s in $c.Items) {
            $nome  = Get-AuditText (Get-AuditValue $s @('Servico', 'Service', 'Nome', 'Name')) 'servico sem nome'
            $estado = Get-AuditText (Get-AuditValue $s @('Estado', 'Status', 'State')) 'estado nao informado'
            $inicio = Get-AuditText (Get-AuditValue $s @('Inicializacao', 'StartType', 'StartMode', 'Tipo')) ''
            $diag   = Get-AuditText (Get-AuditValue $s @('Diagnostico', 'Diagnosis', 'Resultado')) ''
            $nd = Get-AuditNormalKey $diag
            $ne = Get-AuditNormalKey $estado
            $ni = Get-AuditNormalKey $inicio

            if ($nd -eq '' -or $nd -eq 'ok') { $niveis += 'OK'; continue }

            # Servico manual/sob demanda parado e comportamento normal do Windows.
            if ($ni -match 'manual|demanda|demand|disabled|desabilit' -and $ne -match 'stopped|parad') {
                $informativos++
                $niveis += 'INFO'
                continue
            }
            if ($nd -match 'naoencontrad|notfound|ausente') {
                $informativos++
                $niveis += 'INFO'
                Add-AuditFinding -Severity 'INFO' -Area 'Servicos' -Message ("Servico '{0}' nao encontrado nesta instalacao." -f $nome) `
                    -Recommendation 'Pode nao existir nesta edicao/build do Windows.'
                continue
            }
            if ($ni -match 'automat' -and $ne -match 'stopped|parad') {
                $problemas++
                $niveis += 'WARN'
                Add-AuditFinding -Severity 'WARN' -Area 'Servicos' `
                    -Message ("Servico '{0}' configurado como automatico esta parado (diagnostico: {1})." -f $nome, (Get-AuditText $diag 'nao informado' 100)) `
                    -Recommendation 'Validar dependencias e necessidade real do servico antes de alterar o tipo de inicializacao.'
                continue
            }
            $informativos++
            $niveis += 'INFO'
        }
        if ($problemas -eq 0) {
            Add-AuditFinding -Severity 'OK' -Area 'Servicos' -Message ("Nenhum servico automatico essencial encontrado parado ({0} servico(s) avaliado(s))." -f $c.Count)
        }
        Add-AuditSection -Title 'Servicos essenciais' -Status (Resolve-AuditStatus $niveis) -Rows $c.Items `
            -Summary ("{0} servico(s) | automaticos parados: {1} | desvios sem impacto direto: {2}" -f $c.Count, $problemas, $informativos)
        Write-AuditTable $c.Items
        Update-AuditArea 'Servicos' 'Verificado' ''
    }

    # ---- processos (estritamente informativo, sem julgamento de consumo) ----
    $p = Invoke-AuditCollect -Name 'Processos' -Requires 'Get-CompartDiskProcessDiagnostics' -Script { Get-CompartDiskProcessDiagnostics -Top 15 }
    if ($p.State -eq 'Ok') {
        Add-AuditSection -Title 'Processos (top memoria)' -Status 'INFO' -Rows $p.Items `
            -Summary ("{0} processo(s) listado(s) por consumo de memoria. Consumo elevado nao caracteriza problema por si so." -f $p.Count)
        Write-AuditTable $p.Items @() 160 10
        Update-AuditArea 'Processos' 'Verificado' ''
    } else {
        Add-AuditNotCollected -Collect $p -Title 'Processos (top memoria)' -Area 'Processos' -Impact 'consumo de memoria nao inventariado.' -Severity 'INFO'
    }

    # ---- itens de inicializacao ----
    $s = Invoke-AuditCollect -Name 'Startup' -Requires 'Get-CompartDiskStartupItems' -Script { Get-CompartDiskStartupItems }
    if ($s.State -eq 'Ok') {
        Add-AuditSection -Title 'Itens de inicializacao' -Status 'INFO' -Rows $s.Items `
            -Summary ("{0} item(ns) de inicializacao. Presenca de software na inicializacao nao e, por si so, um problema." -f $s.Count)
        Update-AuditArea 'Inicializacao' 'Verificado' ''
    } elseif ($s.State -eq 'Vazio') {
        Add-AuditSection -Title 'Itens de inicializacao' -Status 'INFO' -Summary 'Nenhum item de inicializacao retornado.'
        Update-AuditArea 'Inicializacao' 'Verificado' 'Nenhum item.'
    } else {
        Add-AuditNotCollected -Collect $s -Title 'Itens de inicializacao' -Area 'Inicializacao' -Impact 'itens de inicializacao nao enumerados.' -Severity 'INFO'
    }
}

# ------------------------------------------------------------- energia -----
function Add-AuditPower {
    $c = Invoke-AuditCollect -Name 'Power' -Requires 'Get-CompartDiskPowerInfo' -Script { Get-CompartDiskPowerInfo }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Energia' -Area 'Energia' -Impact 'plano de energia nao verificado.' -Severity 'INFO'
        return
    }
    Add-AuditSection -Title 'Energia' -Status 'INFO' -Pairs $c.Data -Summary 'Levantamento consultivo; nenhuma configuracao de energia foi alterada.'
    Write-AuditPairs $c.Data 24
    Update-AuditArea 'Energia' 'Verificado' ''
}

# -------------------------------------------------------- licenciamento ----
function Add-AuditLicense {
    $c = Invoke-AuditCollect -Name 'License' -Requires 'Get-CompartDiskLicenseInfo' -Cache -Script { Get-CompartDiskLicenseInfo }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Licenciamento' -Area 'Licenciamento' -Impact 'estado de ativacao nao verificado.' -Severity 'INFO'
        return
    }

    $seguro = Protect-AuditPairs $c.Data      # chaves completas nunca saem daqui
    $estado = Get-AuditNormalKey "$(Get-AuditValue $c.Data @('Estado', 'Status', 'Ativacao', 'LicenseStatus'))"

    $status = 'INFO'
    if ($estado -match 'notificat|naolicenciad|unlicensed|expirad|graca|grace') {
        $status = 'WARN'
        Add-AuditFinding -Severity 'WARN' -Area 'Licenciamento' `
            -Message ("Estado de licenciamento reportado como '{0}'." -f (Get-AuditText (Get-AuditValue $c.Data @('Estado', 'Status')) 'nao informado' 60)) `
            -Recommendation 'Verificar a ativacao do Windows. Em ambiente corporativo com KMS, o estado pode variar conforme o ciclo de renovacao.'
    } elseif ($estado -match 'licenciad|licensed|ativad') {
        Add-AuditFinding -Severity 'OK' -Area 'Licenciamento' -Message 'Windows reportado como licenciado.'
    } else {
        Add-AuditFinding -Severity 'INFO' -Area 'Licenciamento' -Message 'Estado de licenciamento nao determinado a partir dos dados coletados.'
    }

    Add-AuditSection -Title 'Licenciamento' -Status $status -Pairs $seguro `
        -Summary 'Identificadores sensiveis mascarados: nenhuma chave completa e registrada nos relatorios.'
    Write-AuditPairs $seguro 22
    Update-AuditArea 'Licenciamento' 'Verificado' ''
}

# ------------------------------------------------------------- software ----
function Add-AuditSoftware {
    param([int]$MaxLinhas = 200, [switch]$Console)
    $c = Invoke-AuditCollect -Name 'Software' -Requires 'Get-CompartDiskInstalledSoftware' -Cache -Script { Get-CompartDiskInstalledSoftware }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Aplicativos instalados' -Area 'Software' -Impact 'inventario de software nao coletado.' -Severity 'INFO'
        return
    }

    $mostrar = $c.Count
    $resumo = "{0} aplicativo(s) inventariado(s)." -f $c.Count
    $linhas = $c.Items
    if ($MaxLinhas -gt 0 -and $c.Count -gt $MaxLinhas) {
        $linhas  = @($c.Items | Select-Object -First $MaxLinhas)
        $mostrar = $MaxLinhas
        $resumo  = "{0} aplicativo(s) inventariado(s); exibindo os {1} primeiros no relatorio." -f $c.Count, $MaxLinhas
    }
    Add-AuditSection -Title 'Aplicativos instalados' -Status 'INFO' -Rows $linhas -Summary $resumo
    if ($Console) { Write-AuditTable $c.Items @() 200 40 }
    Update-AuditArea 'Software' 'Verificado' $(if ($mostrar -lt $c.Count) { "Relatorio limitado a $MaxLinhas linhas." } else { '' })
}

# -------------------------------------------------------------- eventos ----
function Add-EventAudit {
    <# Mantida a assinatura original (-Dias) para compatibilidade de chamada. #>
    param([int]$Dias)

    $c = Invoke-AuditCollect -Name ("Eventos-$Dias") -Requires 'Get-CompartDiskEventSummary' -Cache -Script { Get-CompartDiskEventSummary -Days $Dias }
    $titulo = "Eventos ($Dias dias)"

    if ($c.State -eq 'Vazio') {
        Add-AuditSection -Title $titulo -Status 'OK' -Summary ("Consulta concluida: nenhum evento critico, erro ou aviso relevante em {0} dia(s)." -f $Dias)
        Add-AuditFinding -Severity 'OK' -Area 'Eventos' -Message ("Nenhum evento relevante nos ultimos {0} dias." -f $Dias)
        Update-AuditArea 'Eventos' 'Verificado' 'Sem ocorrencias.'
        return
    }
    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title $titulo -Area 'Eventos' -Impact 'ocorrencias do sistema nao avaliadas.'
        return
    }

    $criticos = @(); $erros = @(); $avisos = @()
    foreach ($e in $c.Items) {
        $n = Get-AuditNormalKey "$(Get-AuditValue $e @('Nivel', 'Level', 'Severidade'))"
        if     ($n -match 'critic') { $criticos += $e }
        elseif ($n -match 'erro|error') { $erros += $e }
        elseif ($n -match 'aviso|warn') { $avisos += $e }
    }

    $niveis = @('OK')
    foreach ($e in ($criticos | Select-Object -First 5)) {
        $niveis += 'CRIT'
        Add-AuditFinding -Severity 'CRIT' -Area 'Eventos' -Message (Format-AuditEvent $e $Dias) `
            -Recommendation 'Analisar o evento no Visualizador de Eventos com o ID e a origem indicados antes de concluir a causa.'
    }
    # Erro isolado costuma ser ruido; recorrencia e que caracteriza padrao.
    $errosRelevantes = @(); $errosPontuais = 0
    foreach ($e in $erros) {
        $oc = ConvertTo-AuditNumber (Get-AuditValue $e @('Ocorrencias', 'Count', 'Total'))
        if ($null -eq $oc -or $oc -ge 3) { $errosRelevantes += $e } else { $errosPontuais++ }
    }
    foreach ($e in ($errosRelevantes | Select-Object -First 5)) {
        $niveis += 'WARN'
        Add-AuditFinding -Severity 'WARN' -Area 'Eventos' -Message (Format-AuditEvent $e $Dias) `
            -Recommendation 'Ocorrencia recorrente: correlacionar com a origem antes de atribuir causa.'
    }
    if ($errosPontuais -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'Eventos' `
            -Message ("{0} tipo(s) de erro com ocorrencia pontual (menos de 3 registros no periodo)." -f $errosPontuais) `
            -Recommendation 'Sem recorrencia; monitorar.'
    }
    if ($criticos.Count -eq 0 -and $errosRelevantes.Count -eq 0) {
        Add-AuditFinding -Severity 'OK' -Area 'Eventos' -Message ("Nenhum evento critico ou erro recorrente em {0} dia(s)." -f $Dias)
    }
    if ($avisos.Count -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'Eventos' -Message ("{0} tipo(s) de aviso registrado(s) no periodo (nao classificados como problema)." -f $avisos.Count)
    }

    Add-AuditSection -Title $titulo -Status (Resolve-AuditStatus $niveis) -Rows $c.Items `
        -Summary ("Criticos: {0} | erros: {1} (recorrentes: {2}) | avisos: {3} | janela: {4} dia(s)" -f $criticos.Count, $erros.Count, $errosRelevantes.Count, $avisos.Count, $Dias)
    Write-AuditTable $c.Items @('Log', 'Nivel', 'EventoID', 'Origem', 'Ocorrencias') 200 15
    Write-AuditLog 'OK' ("Eventos analisados: {0} criticos, {1} erros, {2} avisos." -f $criticos.Count, $erros.Count, $avisos.Count)
    Update-AuditArea 'Eventos' 'Verificado' ''
}

function Format-AuditEvent {
    <# Evidencia no Message; a mensagem do evento nao e recomendacao. #>
    param($Evento, [int]$Dias)
    $log = Get-AuditText (Get-AuditValue $Evento @('Log', 'Canal', 'LogName')) 'log nao informado' 40
    $id  = Get-AuditText (Get-AuditValue $Evento @('EventoID', 'EventID', 'ID')) 'ID nao informado' 12
    $org = Get-AuditText (Get-AuditValue $Evento @('Origem', 'Source', 'Provider')) 'origem nao informada' 60
    $oc  = Get-AuditText (Get-AuditValue $Evento @('Ocorrencias', 'Count', 'Total')) '1' 8
    $msg = Get-AuditText (Get-AuditValue $Evento @('Mensagem', 'Message', 'Descricao')) '' 160
    $txt = "[{0}] ID {1} de {2}: {3} ocorrencia(s) em {4} dia(s)." -f $log, $id, $org, $oc, $Dias
    if ($msg) { $txt += " Evidencia: $msg" }
    return $txt
}

# ---------------------------------------------- integridade e pendencias ----
function Add-AuditIntegrity {
    param([string]$ReinicioWU = 'Unknown')

    $pares = [ordered]@{}
    $niveis = @()

    $r = Invoke-AuditCollect -Name 'PendingReboot' -Requires 'Test-CompartDiskPendingReboot' -Cache -Script { Test-CompartDiskPendingReboot }
    $tri = 'Unknown'
    if ($r.State -eq 'Ok' -or $r.State -eq 'Vazio') {
        # Retorno $false chega como 'Vazio': ambos sao consulta bem-sucedida.
        $tri = ConvertTo-AuditTriState $r.Data
        if ($r.State -eq 'Vazio' -and $null -ne $r.Data) { $tri = ConvertTo-AuditTriState $r.Data }
        elseif ($r.State -eq 'Vazio') { $tri = 'False' }
    }
    # Reconcilia com o que o Windows Update reportou, evitando relatorio contraditorio.
    $final = $tri
    if ($tri -eq 'Unknown' -and $ReinicioWU -ne 'Unknown') { $final = $ReinicioWU }
    if ($tri -eq 'False' -and $ReinicioWU -eq 'True') { $final = 'True' }

    $pares['Reinicio pendente'] = switch ($final) { 'True' { 'SIM' } 'False' { 'Nao' } default { 'Nao determinado' } }
    if ($tri -ne 'Unknown' -and $ReinicioWU -ne 'Unknown' -and $tri -ne $ReinicioWU) {
        $pares['Observacao reinicio'] = 'Fontes divergentes (verificacao de integridade x Windows Update); prevalece a indicacao de pendencia.'
    }
    if ($final -eq 'True') {
        $niveis += 'WARN'
        Add-AuditFinding -Severity 'WARN' -Area 'Integridade' -Message 'Reinicializacao pendente identificada.' `
            -Recommendation 'Agendar reinicio em janela adequada. Condicao operacional, nao falha do sistema.'
    } elseif ($final -eq 'Unknown') {
        $niveis += 'INFO'
    }

    $sc = Invoke-AuditCollect -Name 'ShadowCopies' -Requires 'Get-CompartDiskShadowCopies' -Script { Get-CompartDiskShadowCopies }
    if ($sc.State -eq 'Ok' -or $sc.State -eq 'Vazio') {
        $pares['Copias de sombra'] = $sc.Count
    } else {
        # 0 e "nao consultei" sao coisas diferentes: nunca exibir 0 por falha.
        $pares['Copias de sombra'] = 'Nao consultado'
        $niveis += 'INFO'
        Add-AuditFinding -Severity 'INFO' -Area 'Integridade' -Message 'Copias de sombra nao puderam ser consultadas (a consulta costuma exigir elevacao).' `
            -Recommendation 'Reexecutar elevado para confirmar a existencia de pontos de restauracao.'
    }

    $pr = Invoke-AuditCollect -Name 'Printers' -Requires 'Get-CompartDiskPrinters' -Script { Get-CompartDiskPrinters }
    if ($pr.State -eq 'Ok' -or $pr.State -eq 'Vazio') {
        $pares['Impressoras'] = $pr.Count
    } else {
        $pares['Impressoras'] = 'Nao consultado'
        $niveis += 'INFO'
    }

    Add-AuditSection -Title 'Integridade do sistema' -Status (Resolve-AuditStatus $niveis) -Pairs $pares
    Write-AuditPairs $pares 22
    Update-AuditArea 'Integridade' $(if ($niveis -contains 'INFO') { 'Parcial' } else { 'Verificado' }) ''
}

function Add-AuditProcessInventory {
    <#
      Inventario completo de processos com integridade do executavel.

      COMPLEMENTA, sem substituir, a secao 'Processos (top memoria)': aquela
      responde "quem esta consumindo memoria agora" e continua com CPU e
      responsividade; esta responde "o que esta em execucao, sob qual usuario, e
      o binario confere". Por isso as duas convivem sem repetir a pergunta.
    #>
    $c = Invoke-AuditCollect -Name 'ProcessInventory' -Requires 'Get-CompartDiskProcessInventory' -Cache `
         -Script { Get-CompartDiskProcessInventory }

    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Inventario de processos' -Area 'Processos' `
            -Impact 'processos nao inventariados com PPID, usuario e integridade do executavel.' -Severity 'INFO'
        Update-AuditArea 'Integridade de executaveis' 'Nao verificado' 'inventario de processos indisponivel'
        return
    }

    $itens = @($c.Items)
    Add-AuditSection -Title 'Processos' -Status 'INFO' -Rows $itens -Summary (
        "{0} processo(s) em execucao, com PPID, usuario, memoria, threads, handles, assinatura digital e SHA-256 do executavel." -f $itens.Count)
    Write-AuditTable $itens @('Processo', 'PID', 'PPID', 'Usuario', 'Memoria', 'Threads', 'Handles') 160 12
    Update-AuditArea 'Processos' 'Verificado' ''

    # ---- assinaturas digitais ---------------------------------------------
    # A tabela completa ja esta acima. Aqui entra so o que NAO esta validado:
    # repetir as centenas de linhas assinadas nao acrescenta diagnostico.
    $porEstado = @{}
    foreach ($p in $itens) {
        $e = Get-AuditText $p.Assinatura 'N/A'
        if (-not $porEstado.ContainsKey($e)) { $porEstado[$e] = 0 }
        $porEstado[$e]++
    }
    $pares = [ordered]@{}
    foreach ($k in @('Assinado e valido', 'Assinado, invalido', 'Nao assinado', 'Nao foi possivel verificar', 'Acesso negado', 'Nao verificado', 'N/A')) {
        if ($porEstado.ContainsKey($k)) { $pares[$k] = $porEstado[$k] }
    }
    foreach ($k in $porEstado.Keys) { if (-not $pares.Contains($k)) { $pares[$k] = $porEstado[$k] } }

    $invalidos   = @($itens | Where-Object { $_.Assinatura -eq 'Assinado, invalido' })
    $naoAssinados= @($itens | Where-Object { $_.Assinatura -eq 'Nao assinado' })
    $indefinidos = @($itens | Where-Object { $_.Assinatura -eq 'Nao foi possivel verificar' -or $_.Assinatura -eq 'Acesso negado' })

    # Uma linha por EXECUTAVEL, nao por processo: dez copias de um mesmo binario
    # sao o mesmo arquivo e a mesma conclusao.
    $atencao = @($invalidos + $naoAssinados + $indefinidos |
        Group-Object -Property Caminho |
        ForEach-Object {
            $r = $_.Group[0]
            [pscustomobject]@{
                Executavel = $r.Processo
                Assinatura = $r.Assinatura
                Editor     = $r.Editor
                Processos  = $_.Count
                SHA256     = $r.SHA256
                Caminho    = $r.Caminho
            }
        } | Sort-Object -Property Assinatura, Executavel)

    $statusSec = 'OK'
    if ($indefinidos.Count -gt 0) { $statusSec = 'INFO' }
    if ($invalidos.Count -gt 0)   { $statusSec = 'WARN' }

    Add-AuditSection -Title 'Assinaturas digitais' -Status $statusSec -Pairs $pares -Rows $atencao -Summary (
        "{0} executavel(is) distinto(s) sem assinatura valida. Executaveis com assinatura valida nao sao repetidos aqui." -f $atencao.Count)
    Write-AuditPairs $pares 30

    if ($invalidos.Count -gt 0) {
        $nomes = (@($invalidos | Select-Object -ExpandProperty Processo -Unique | Select-Object -First 6) -join ', ')
        Add-AuditFinding -Severity 'WARN' -Area 'Integridade de executaveis' `
            -Message ("{0} processo(s) com assinatura digital presente porem invalida: {1}." -f $invalidos.Count, $nomes) `
            -Recommendation 'Assinatura invalida indica binario alterado apos a assinatura, certificado nao confiavel ou cadeia incompleta. Conferir a origem do arquivo pelo SHA-256 antes de concluir.'
    }
    if ($naoAssinados.Count -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'Integridade de executaveis' `
            -Message ("{0} processo(s) com executavel sem assinatura digital." -f $naoAssinados.Count) `
            -Recommendation 'Ausencia de assinatura e comum em ferramentas legitimas e nao caracteriza problema por si so.'
    }
    if ($indefinidos.Count -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'Integridade de executaveis' `
            -Message ("{0} processo(s) cuja assinatura nao pode ser verificada (executavel protegido ou acesso negado)." -f $indefinidos.Count) `
            -Recommendation 'Processos protegidos do Windows nao expoem o binario nem para leitura administrativa.'
    }

    $estadoArea = 'Verificado'
    if ($indefinidos.Count -gt 0) { $estadoArea = 'Parcial' }
    Update-AuditArea 'Integridade de executaveis' $estadoArea $(
        if ($indefinidos.Count -gt 0) { "{0} executavel(is) sem verificacao possivel" -f $indefinidos.Count } else { '' })

    # ---- inventario de servicos com origem do binario ----------------------
    # Nao substitui 'Servicos essenciais', que segue com os 18 criticos e o mesmo
    # formato: aquela responde "os criticos estao saudaveis?", esta responde
    # "quais servicos existem e de quem e o binario de cada um".
    $sv = Invoke-AuditCollect -Name 'ServiceInventory' -Requires 'Get-CompartDiskServiceInventory' -Cache `
          -Script { Get-CompartDiskServiceInventory }
    if ($sv.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $sv -Title 'Servicos (inventario)' -Area 'Servicos' `
            -Impact 'servicos nao inventariados com origem do binario.' -Severity 'INFO'
        return
    }
    $servicos = @($sv.Items)
    $svAtencao = @($servicos | Where-Object { $_.Atencao -eq 'Sim' })
    $svTerceiro = @($servicos | Where-Object { $_.Origem -eq 'Terceiro' })
    Add-AuditSection -Title 'Servicos (inventario)' -Status $(if ($svAtencao.Count -gt 0) { 'WARN' } else { 'INFO' }) `
        -Rows $servicos -Summary (
        "{0} servico(s): {1} de terceiros, {2} com indicador que pede conferencia manual." -f `
        $servicos.Count, $svTerceiro.Count, $svAtencao.Count)
    Write-AuditTable $servicos @('Servico', 'Estado', 'Inicio', 'Origem', 'Editor') 160 12

    if ($svAtencao.Count -gt 0) {
        Add-AuditFinding -Severity 'WARN' -Area 'Integridade de executaveis' `
            -Message ("{0} servico(s) com indicador que pede conferencia manual." -f $svAtencao.Count) `
            -Recommendation 'Abrir a secao "Servicos (inventario)" e filtrar por "Pede conferencia" para ver o motivo de cada um.'
    }
}

function Add-AuditNetworkSurface {
    <#
      Superficie de rede: com quem a maquina fala, o que ela expoe e o que ela
      compartilha. As interfaces ja saem em 'Rede' (Add-AuditNetwork) e os
      perfis em 'Firewall' (Add-AuditSecurity) - nenhuma das duas e repetida.
    #>
    $c = Invoke-AuditCollect -Name 'NetConnections' -Requires 'Get-CompartDiskNetworkConnections' -Cache `
         -Script { Get-CompartDiskNetworkConnections }

    if ($c.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $c -Title 'Conexoes de rede' -Area 'Conexoes' `
            -Impact 'conexoes e portas em escuta nao inventariadas.' -Severity 'INFO'
        Update-AuditArea 'Portas em escuta' 'Nao verificado' 'coleta de conexoes indisponivel'
    } else {
        $conex = @($c.Items)
        $estab = @($conex | Where-Object { $_.Estado -eq 'ESTABLISHED' })
        $lista = @($conex | Where-Object { $_.Estado -eq 'LISTEN' })
        $semDono = @($conex | Where-Object { $_.Processo -eq 'N/A' })

        Add-AuditSection -Title 'Conexoes de rede' -Status 'INFO' -Rows $conex -Summary (
            "{0} conexao(oes): {1} estabelecida(s), {2} em escuta. Processo responsavel associado pelo PID dono do socket." -f `
            $conex.Count, $estab.Count, $lista.Count)
        Write-AuditTable $conex @('Protocolo', 'EnderecoLocal', 'PortaLocal', 'EnderecoRemoto', 'PortaRemota', 'Estado', 'Processo', 'PID') 170 12
        Update-AuditArea 'Conexoes' $(if ($semDono.Count -gt 0) { 'Parcial' } else { 'Verificado' }) $(
            if ($semDono.Count -gt 0) { "{0} socket(s) sem processo identificado" -f $semDono.Count } else { '' })

        # ---- portas em escuta, derivadas da mesma coleta -------------------
        $portas = @(Get-CompartDiskListeningPorts -Conexoes $conex)
        $externas = @($portas | Where-Object { $_.EnderecoDeEscuta -notmatch '^(127\.|::1$|N/A$)' })
        Add-AuditSection -Title 'Portas em escuta' -Status 'INFO' -Rows $portas -Summary (
            "{0} porta(s) em escuta; {1} aceitando conexao fora do proprio computador." -f $portas.Count, $externas.Count)
        Write-AuditTable $portas @('Porta', 'Protocolo', 'Processo', 'PID', 'Servico', 'EnderecoDeEscuta') 160 12
        Update-AuditArea 'Portas em escuta' 'Verificado' ''

        if ($externas.Count -gt 0) {
            Add-AuditFinding -Severity 'INFO' -Area 'Portas em escuta' `
                -Message ("{0} porta(s) em escuta alcancavel(is) pela rede." -f $externas.Count) `
                -Recommendation 'Conferir na tabela quais servicos expoem porta e se cada um e esperado nesta maquina.'
        }
    }

    # ---- compartilhamentos -------------------------------------------------
    $s = Invoke-AuditCollect -Name 'Shares' -Requires 'Get-CompartDiskShares' -Cache -Script { Get-CompartDiskShares }
    if ($s.State -ne 'Ok') {
        Add-AuditNotCollected -Collect $s -Title 'Compartilhamentos' -Area 'Compartilhamentos' `
            -Impact 'recursos compartilhados nao inventariados.' -Severity 'INFO'
        return
    }
    $shares = @($s.Items)
    $comuns = @($shares | Where-Object { $_.Administrativo -eq 'Nao' })
    Add-AuditSection -Title 'Compartilhamentos' -Status 'INFO' -Rows $shares -Summary (
        "{0} compartilhamento(s): {1} administrativo(s) do Windows e {2} criado(s) na maquina." -f `
        $shares.Count, ($shares.Count - $comuns.Count), $comuns.Count)
    Write-AuditTable $shares @('Nome', 'Caminho', 'Tipo', 'Administrativo') 150 12
    Update-AuditArea 'Compartilhamentos' 'Verificado' ''

    if ($comuns.Count -gt 0) {
        Add-AuditFinding -Severity 'INFO' -Area 'Compartilhamentos' `
            -Message ("{0} compartilhamento(s) nao administrativo(s) publicado(s): {1}." -f `
                $comuns.Count, ((@($comuns | Select-Object -ExpandProperty Nome -First 6)) -join ', ')) `
            -Recommendation 'Conferir se cada pasta compartilhada ainda precisa estar acessivel pela rede.'
    }
}

# ============================================================================
# 9. ORQUESTRACAO
# ============================================================================
function Invoke-QuickAudit {
    <# Diagnostico rapido: sem inventario de software, sem drivers, sem eventos. #>
    Invoke-Etapa 'Identificacao do sistema' { Add-AuditSystem }        -Areas @('Sistema')
    Invoke-Etapa 'Hardware'                 { Add-AuditHardware }      -Areas @('Hardware')
    Invoke-Etapa 'Discos e volumes'         { Add-AuditDisks }         -Areas @('Disco', 'Volumes')
    Invoke-Etapa 'Rede'                     { Add-AuditNetwork }       -Areas @('Rede', 'Conectividade')
    Invoke-Etapa 'Seguranca'                { Add-AuditSecurity }      -Areas @('Seguranca', 'Firewall')
    Invoke-Etapa 'Antivirus e Defender'     { Add-AuditAntimalware }   -Areas @('Antivirus', 'Defender')
    Invoke-Etapa 'BitLocker'                { Add-AuditBitLocker }     -Areas @('BitLocker')
    Invoke-Etapa 'Windows Update'           { Add-AuditWindowsUpdate } -Areas @('Windows Update')
    Update-AuditArea 'Historico de atualizacoes' 'Nao aplicavel' 'Consulta reservada ao modo Full (custo elevado).'
}

function Invoke-FullAudit {
    <#
      Full = Quick + cobertura estendida. As coletas comuns ficam em cache
      (Invoke-AuditCollect -Cache), portanto nao sao repetidas.
    #>
    Invoke-QuickAudit

    Invoke-Etapa 'Historico de atualizacoes' { Add-AuditUpdateHistory } -Areas @('Historico de atualizacoes')
    Invoke-Etapa 'Drivers'                   { Add-AuditDrivers }     -Areas @('Drivers')
    Invoke-Etapa 'Contas e grupos'           { Add-AuditLocalUsers }  -Areas @('Contas')
    Invoke-Etapa 'Servicos e processos'      { Add-AuditServices }    -Areas @('Servicos', 'Processos', 'Inicializacao')
    Invoke-Etapa 'Inventario de processos e integridade' { Add-AuditProcessInventory } -Areas @('Processos', 'Integridade de executaveis')
    Invoke-Etapa 'Superficie de rede'        { Add-AuditNetworkSurface } -Areas @('Conexoes', 'Portas em escuta', 'Compartilhamentos')
    Invoke-Etapa 'Energia e desempenho'      { Add-AuditPower }       -Areas @('Energia')
    Invoke-Etapa 'Licenciamento'             { Add-AuditLicense }     -Areas @('Licenciamento')
    Invoke-Etapa 'Aplicativos instalados'    { Add-AuditSoftware -MaxLinhas 200 } -Areas @('Software')
    Invoke-Etapa "Eventos dos ultimos $Days dias" { Add-EventAudit -Dias $Days } -Areas @('Eventos')

    $wu = 'Unknown'
    if ($script:Cache.ContainsKey('WindowsUpdate') -and $script:Cache['WindowsUpdate'].State -eq 'Ok') {
        $wu = ConvertTo-AuditTriState (Get-AuditValue $script:Cache['WindowsUpdate'].Data @('ReinicioPendente', 'RebootPending', 'ReinicializacaoPendente'))
    }
    Invoke-Etapa 'Integridade e pendencias' { Add-AuditIntegrity -ReinicioWU $wu } -Areas @('Integridade')
}

function Add-AuditClosingSections {
    # ---- cobertura: o que foi e o que nao foi verificado ----
    $cob = [ordered]@{}
    $naoVerificadas = @(); $parciais = @()
    foreach ($k in @($script:Areas.Keys)) {
        $a = $script:Areas[$k]
        $estado = $a.Estado
        if ($estado -eq 'Pendente') { $estado = 'Nao verificado' }
        $texto = $estado
        if ($a.Detalhe) { $texto += " - " + (Get-AuditText $a.Detalhe '' 140) }
        $cob["$k"] = $texto
        if ($estado -eq 'Nao verificado') { $naoVerificadas += $k }
        if ($estado -eq 'Parcial') { $parciais += $k }
    }
    $resumoCob = "Verificadas: {0} | parciais: {1} | nao verificadas: {2}" -f `
        (@($script:Areas.Keys | Where-Object { $script:Areas[$_].Estado -eq 'Verificado' }).Count), $parciais.Count, $naoVerificadas.Count
    $statusCob = 'OK'
    if ($naoVerificadas.Count -gt 0) { $statusCob = 'WARN' } elseif ($parciais.Count -gt 0) { $statusCob = 'INFO' }
    Add-AuditSection -Title 'Cobertura da auditoria' -Status $statusCob -Pairs $cob -Summary $resumoCob

    # ---- etapas executadas ----
    if ($script:Steps.Count -gt 0) {
        $incompletas = @($script:Steps | Where-Object { $_.Resultado -ne 'Concluida' })
        Add-AuditSection -Title 'Etapas executadas' -Status $(if ($incompletas.Count -gt 0) { 'WARN' } else { 'OK' }) `
            -Rows @($script:Steps) -Summary ("{0} etapa(s) | incompletas: {1}" -f $script:Steps.Count, $incompletas.Count)
    }

    # ---- resumo final ----
    $motivos = @($script:ResultReasons | Select-Object -First 8)

    # Os motivos so chegavam ao console e a secao do relatorio: o arquivo de log
    # registrava apenas "Resultado=WARN", sem nada que o justificasse. Write-AuditLog
    # e o unico emissor que alcanca o log e ignora -Quiet.
    if ($script:Result -ne 'OK') {
        $total = @($script:ResultReasons).Count
        Write-AuditLog 'WARN' ("Resultado {0} baseado em {1} ocorrencia(s) registrada(s) durante a auditoria:" -f $script:Result, $total)
        foreach ($m in $motivos) { Write-AuditLog 'WARN' ("  - {0}" -f $m) }
        if ($total -gt $motivos.Count) {
            Write-AuditLog 'INFO' ("  ... e mais {0} ocorrencia(s); a lista completa esta na secao 'Resumo da auditoria' do relatorio." -f ($total - $motivos.Count))
        }
    }
    $resumo = [ordered]@{
        'Resultado global'  = $script:Result
        'Achados criticos'  = $script:Findings['CRIT']
        'Achados de aviso'  = $script:Findings['WARN']
        'Informativos'      = $script:Findings['INFO']
        'Verificacoes OK'   = $script:Findings['OK']
        'Areas nao verificadas' = $(if ($naoVerificadas.Count -gt 0) { $naoVerificadas -join ', ' } else { 'nenhuma' })
        'Areas parciais'    = $(if ($parciais.Count -gt 0) { $parciais -join ', ' } else { 'nenhuma' })
        'Elevacao'          = $(if ($script:IsAdmin) { 'Administrador' } else { 'Usuario padrao' })
        'Duracao total'     = ("{0}s" -f [Math]::Round($script:Watch.Elapsed.TotalSeconds, 1))
        'Base do resultado' = $(if ($motivos.Count -gt 0) { $motivos -join ' ; ' } else { 'Todas as etapas solicitadas concluiram sem achado relevante.' })
        'Escopo'            = 'Somente leitura: nenhuma configuracao do Windows foi alterada por este modulo.'
    }
    $statusResumo = switch ($script:Result) { 'OK' { 'OK' } 'WARN' { 'WARN' } default { 'CRIT' } }
    Add-AuditSection -Title 'Resumo da auditoria' -Status $statusResumo -Pairs $resumo

    Write-AuditLine ''
    Write-AuditLine ("  Resultado global: {0}" -f $script:Result) $(switch ($script:Result) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } })
    Write-AuditPairs $resumo 22
}

# ============================================================================
# 10. FLUXO PRINCIPAL
# ============================================================================
$codigo = $null
try {
    # Validacao do parametro Days: limita sem abortar a auditoria.
    $diasSolicitados = $Days
    if ($Days -lt 1)  { $Days = 1 }
    if ($Days -gt 90) { $Days = 90 }

    if (-not (Start-CompartDiskModule -Name 'Audit' -Action $Action -Quiet:$Quiet)) {
        exit (Get-AuditExitCode 'ERROR')
    }
    $script:ModuleStarted = $true

    if ($diasSolicitados -ne $Days) {
        Write-AuditLog 'WARN' ("Parametro -Days ajustado de {0} para {1} (faixa suportada: 1 a 90)." -f $diasSolicitados, $Days)
        Add-AuditFinding -Severity 'INFO' -Area 'Execucao' `
            -Message ("Janela de eventos ajustada de {0} para {1} dia(s) (faixa suportada: 1 a 90)." -f $diasSolicitados, $Days) `
            -Recommendation 'Informar um valor entre 1 e 90 para evitar o ajuste automatico.'
    }

    Add-AuditContextSection -Modo $Action

    switch ($Action) {
        'Quick' { Invoke-QuickAudit }
        'Full'  { Invoke-FullAudit }
        'Events' {
            Invoke-Etapa "Eventos dos ultimos $Days dias" { Add-EventAudit -Dias $Days } -Areas @('Eventos')
        }
        'Software' {
            Invoke-Etapa 'Aplicativos instalados' { Add-AuditSoftware -MaxLinhas 0 -Console } -Areas @('Software')
        }
        'License' {
            Invoke-Etapa 'Licenciamento' { Add-AuditLicense } -Areas @('Licenciamento')
        }
    }

    Add-AuditClosingSections

    if (-not $NoReport) {
        Write-AuditLine ''
        Write-AuditLog 'INFO' 'Gerando relatorios (TXT, CSV, JSON, HTML)...'
        try {
            $arquivos = New-Report -Name "Auditoria_$Action" -Title 'Auditoria de manutencao do Windows' -Format TXT, CSV, JSON, HTML -Open:(-not $NoOpen)
            Write-AuditLine ''
            foreach ($a in @($arquivos)) { Write-AuditLine ("  $a") 'Green' }
        } catch {
            Write-AuditLog 'ERR' 'Falha ao gerar os relatorios.' $_
            Update-AuditResult 'WARN' 'Relatorios nao puderam ser gerados.'
            Write-AuditLine ('  Falha ao gerar relatorios: ' + $_.Exception.Message) 'Red'
        }
    }
} catch {
    # Falha estrutural: unica condicao que produz ERROR.
    Update-AuditResult 'ERROR' ("Excecao nao tratada: " + $_.Exception.Message)
    Write-AuditLog 'ERR' "Falha nao tratada no modulo Audit (Acao=$Action)." $_
    if ($script:ModuleStarted) {
        try {
            Add-AuditFinding -Severity 'CRIT' -Area 'Auditoria' `
                -Message ("Excecao no modulo: " + $_.Exception.Message) `
                -Recommendation 'Auditoria interrompida: os dados apresentados sao parciais.'
        } catch { }
    }
} finally {
    if ($script:ModuleStarted) {
        try {
            $codigo = Stop-CompartDiskModule -Result $script:Result -Quiet:$Quiet
        } catch {
            Write-AuditLog 'ERR' 'Falha ao encerrar o modulo.' $_
            $codigo = $null
        }
    }
    if ($null -eq $codigo -or -not ($codigo -is [int] -or $codigo -is [long] -or $codigo -is [double])) {
        $codigo = Get-AuditExitCode $script:Result
    }
}
exit ([int]$codigo)
