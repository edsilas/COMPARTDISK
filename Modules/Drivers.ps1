<#
 COMPARTDISK 1.4.6 - Drivers.ps1
 Desenvolvido por Edsilas
 Acoes: List | Problems | Unsigned | Diagnose | Backup | Validate | Restore
        Package | Last | Export

 ESCOPO DESTE MODULO
 Inventario e diagnostico somente leitura, exportacao dos pacotes de driver,
 validacao do backup, empacotamento para transporte e restauracao dos pacotes
 previamente exportados pela propria ferramenta.

 O modulo NAO remove drivers, NAO desinstala dispositivos, NAO baixa pacotes da
 Internet, NAO executa arquivos encontrados no backup e NAO altera politica de
 assinatura. As unicas escritas permitidas sao:
   - Backup   : copia dos pacotes para o destino + manifesto;
   - Package  : copia/compactacao de um backup existente;
   - Restore  : adicao de pacotes ao repositorio de drivers do Windows, sempre
                por pnputil, apenas a partir de um backup validado, em simulacao
                por padrao e somente com -Force para aplicar de fato.

 NAO EXISTE UPLOAD. O COMPARTDISK nao possui backend de envio: remote.ps1
 apenas BAIXA o projeto do GitHub. A acao Package prepara o pacote e informa o
 caminho, o tamanho e o hash para transporte manual. Nenhum envio e simulado.

 Compativel com Windows 10 / Windows 11 (x64), Windows PowerShell 5.1 e
 PowerShell 7.x. Somente componentes nativos do Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('List', 'Problems', 'Backup', 'Unsigned', 'Export',
                 'Diagnose', 'Validate', 'Restore', 'Package', 'Last')]
    [string]$Action = 'List',
    # Destino do Backup/Package; origem do Validate/Restore/Package.
    [string]$Path = '',
    # Filtros de selecao (Restore e Package). Aceitam curinga (-like).
    [string]$InfName = '',
    [string]$Provider = '',
    [string]$DeviceClass = '',
    # Restore: restringe aos pacotes cujos IDs de hardware casam com dispositivos
    # que hoje reportam falta ou falha de driver.
    [switch]$OnlyMissing,
    # Package: gera .zip alem da pasta preparada.
    [switch]$Compress,
    # Restore: forca simulacao mesmo com -Force. DryRun sempre vence.
    [switch]$DryRun,
    # Backup : prossegue quando o espaco livre e menor que a estimativa (que e um
    #          limite superior deliberadamente pessimista).
    # Restore: aplica de fato, em vez de simular.
    [switch]$Force,
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

# ------------------------------------------------------------------------------
# Estado operacional da operacao corrente. Separado de $script:result: o result
# alimenta o codigo de saida, a fase descreve ate onde a operacao chegou e e o
# que vai para o manifesto e para o relatorio.
# ------------------------------------------------------------------------------
$script:FaseValidas = @('NaoIniciado', 'EmPreparacao', 'EmExecucao', 'Concluido',
                        'ConcluidoComAvisos', 'Falhou', 'Cancelado')
$script:Fase = 'NaoIniciado'

function Set-DriverFase {
    param([Parameter(Mandatory)][ValidateSet('NaoIniciado', 'EmPreparacao', 'EmExecucao',
                     'Concluido', 'ConcluidoComAvisos', 'Falhou', 'Cancelado')][string]$Fase)
    $script:Fase = $Fase
    Write-Log DEBUG ("Fase da operacao: {0}" -f $Fase) -NoConsole
}

function Get-DriverSectionStatus {
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

function Write-DriverInfo {
    <# Linha objetiva de informacao no padrao visual do Launcher. Nao substitui o
       log: o que precisa auditoria passa por Write-Log. #>
    param([Parameter(Mandatory)][string]$Chave, [AllowNull()][object]$Valor)
    if ($script:Quiet) { return }
    Write-CompartDiskKeyValue -Key $Chave -Value $Valor
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
    if ($Value -is [array]) {
        $itens = @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { "$_".Trim() })
        if ($itens.Count -eq 0) { return $Default }
        return ($itens -join '; ')
    }
    $t = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
    return $t
}

function ConvertTo-DriverArgumento {
    <# Argumento de linha de comando para Invoke-NativeCommand, que concatena os
       itens com espaco. Sem isto um destino com espaco vira dois argumentos.
       CommandLineToArgvW trata a sequencia de barras invertidas imediatamente
       antes da aspa de fechamento como escape: "D:\Dir\" chegaria ao pnputil como
       D:\Dir" e a exportacao gravaria no lugar errado. Duplicar preserva o valor. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Valor)
    $v = "$Valor"
    $m = [regex]::Match($v, '(\\+)$')
    if ($m.Success) {
        $barras = $m.Groups[1].Value
        $v = $v.Substring(0, $v.Length - $barras.Length) + $barras + $barras
    }
    return ('"{0}"' -f $v)
}

function Get-DriverNomeSeguro {
    <# Nome de arquivo/pasta derivado de dado do sistema (nome de INF, fabricante).
       Impede travessia de caminho e caracteres recusados pelo NTFS. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Nome, [string]$Padrao = 'pacote')
    $t = "$Nome".Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $Padrao }
    # Separadores e '..' sao neutralizados explicitamente, sem depender de
    # GetInvalidFileNameChars: a lista varia por plataforma, e este nome sempre
    # vem de dado do sistema, nunca de constante do proprio codigo.
    $t = $t.Replace('\', '_').Replace('/', '_')
    while ($t.Contains('..')) { $t = $t.Replace('..', '_') }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $t = $t.Replace($c, '_') }
    $t = $t.Trim('.', ' ')
    if ([string]::IsNullOrWhiteSpace($t)) { return $Padrao }
    if ($t.Length -gt 96) { $t = $t.Substring(0, 96) }
    return $t
}

function Get-DriverHashArquivo {
    <# SHA-256 de um arquivo. Usado nos artefatos que realmente sustentam a
       integridade do pacote (.inf e .cat) e no .zip final. Nao se calcula hash
       de gigabytes de binario de driver: custo alto e beneficio nulo diante da
       validacao por contagem, tamanho e leitura efetiva. #>
    param([Parameter(Mandatory)][string]$Caminho)
    $out = [pscustomobject]@{ Ok = $false; Sha256 = ''; Bytes = 0; Detalhe = '' }
    try {
        $fi = Get-Item -LiteralPath $Caminho -ErrorAction Stop
        $out.Bytes = [long]$fi.Length
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $fs = [System.IO.File]::OpenRead($fi.FullName)
            try { $out.Sha256 = ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '') }
            finally { $fs.Dispose() }
        } finally { $sha.Dispose() }
        $out.Ok = $true
    } catch {
        $out.Detalhe = $_.Exception.Message
        Write-Log DEBUG ("Hash indisponivel para {0}: {1}" -f $Caminho, $_.Exception.Message) -NoConsole
    }
    return $out
}

# ==============================================================================
# INVENTARIO
# Fonte canonica: Get-CompartDiskDriverInfo (Core). Consultado UMA vez por
# execucao e cacheado - List, Unsigned, Diagnose e Export compartilham o mesmo
# retrato.
#
# Enriquecimento: Get-CompartDiskDriverInfo colapsa IsSigned $null em 'NAO',
# o que transforma "assinatura desconhecida" em "sem assinatura". Uma consulta
# complementar com projecao de propriedades recupera IsSigned bruto, Signer,
# DeviceClass, Description, Status, Location, DeviceID e HardWareID. E uma
# consulta unica por execucao, cacheada, e nunca executada para Problems.
# ==============================================================================
$script:InventarioCache  = $null
$script:ProblemasCache   = $null
$script:EnriquecimentoOk = $null
$script:PresencaCache    = $null

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
    <# Mapa DeviceName|InfName|Versao -> dados brutos de assinatura/classe/ID. #>
    [CmdletBinding()] param()
    if ($null -ne $script:EnriquecimentoOk) { return $script:EnriquecimentoOk }

    $mapa = @{}
    $ok   = $false
    $consulta = 'SELECT DeviceName, InfName, DriverVersion, IsSigned, Signer, DeviceClass, ' +
                'Description, Status, Location, DeviceID, HardWareID FROM Win32_PnPSignedDriver'
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

function Get-DriverPresenca {
    <# Mapa DeviceID -> presenca/estado, a partir de Win32_PnPEntity. Consulta
       preguicosa: so Diagnose e Restore precisam saber se o dispositivo esta
       fisicamente presente, e enumerar Win32_PnPEntity inteiro nao se justifica
       nas acoes de leitura simples. #>
    [CmdletBinding()] param()
    if ($null -ne $script:PresencaCache) { return $script:PresencaCache }

    $mapa = @{}
    $ok   = $false
    $r = Invoke-SafeCommand {
        Get-CompartDiskCim -Query 'SELECT DeviceID, Name, Present, Status, ConfigManagerErrorCode, HardwareID FROM Win32_PnPEntity'
    } -Activity 'Presenca de dispositivos (Win32_PnPEntity)' -Silent

    if ($r.Success -and $null -ne $r.Value) {
        $ok = $true
        foreach ($e in (ConvertTo-DriverArray $r.Value)) {
            $id = "$($e.DeviceID)"
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $mapa[$id.ToLowerInvariant()] = $e
        }
    } else {
        Write-Log WARN 'Nao foi possivel determinar a presenca dos dispositivos.' -ErrorRecord $r.Error
    }

    $script:PresencaCache = [pscustomobject]@{ Ok = $ok; Mapa = $mapa; Total = $mapa.Count }
    return $script:PresencaCache
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

function Test-DriverTerceiro {
    <# Pacote publicado como oemNN.inf e um pacote de terceiro adicionado ao
       repositorio: e exatamente o conjunto que pnputil /export-driver exporta.
       Um INF com nome proprio veio na imagem do Windows. #>
    param([AllowNull()][object]$Inf)
    return ("$Inf".Trim() -match '(?i)^oem\d+\.inf$')
}

function Get-DriverInventory {
    <# Retorna { Ok, Status, Detalhe, Rows, Total, Enriquecido }.
       Status: 'Completo' | 'Parcial' | 'Vazio' | 'Falhou'. #>
    [CmdletBinding()] param()
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

    $enr = Get-DriverEnriquecimento
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
            Origem      = $(if (Test-DriverTerceiro $b.InfName) { 'Terceiro' } else { 'Windows' })
            Localizacao = (Get-DriverSafeText $(if ($bruto) { $bruto.Location } else { $null }))
            DeviceID    = (Get-DriverSafeText $(if ($bruto) { $bruto.DeviceID } else { $null }))
            HardwareID  = (Get-DriverSafeText $(if ($bruto) { $bruto.HardWareID } else { $null }))
        })
    }

    $inv.Rows  = @($rows)
    $inv.Total = $rows.Count
    $inv.Ok    = $true
    if ($inv.Enriquecido) {
        $inv.Status  = 'Completo'
        $inv.Detalhe = 'Inventario coletado com detalhamento de assinatura, classe, estado e identificacao.'
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
# Codigos que indicam driver ausente, nao carregado ou invalido. Sao os unicos
# em que restaurar um pacote do backup e uma resposta tecnicamente plausivel.
$script:CodigoDriverAusente = @(1, 3, 10, 18, 19, 28, 31, 37, 38, 39, 41, 52)

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
        $codigo = -1
        try { $codigo = [int]$p.CodigoErro } catch { $codigo = -1 }
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
            DriverAusente = ($script:CodigoDriverAusente -contains $codigo)
        })
    }
    $out.Rows = @($rows); $out.Total = $rows.Count; $out.Ok = $true; $out.Status = 'Completo'
    $out.Detalhe = ("{0} dispositivo(s) com codigo de erro." -f $rows.Count)
    $script:ProblemasCache = $out
    return $out
}

# ==============================================================================
# ANALISES COMPARTILHADAS (usadas por List, Unsigned, Diagnose e Export)
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

function Get-DriverDuplicados {
    <# Mesmo dispositivo atendido por mais de uma versao de driver enumerada.
       E INFORMATIVO: o repositorio de drivers do Windows retem versoes
       anteriores por projeto, e isso nao caracteriza defeito. Nada e removido
       por causa desta analise. #>
    param([object[]]$Rows)
    $grupos = @{}
    foreach ($r in (ConvertTo-DriverArray $Rows)) {
        $chave = ('{0}|{1}' -f "$($r.Dispositivo)", "$($r.Classe)").ToLowerInvariant()
        if (-not $grupos.ContainsKey($chave)) { $grupos[$chave] = New-Object System.Collections.ArrayList }
        [void]$grupos[$chave].Add($r)
    }
    $dup = New-Object System.Collections.ArrayList
    foreach ($k in $grupos.Keys) {
        $itens = @($grupos[$k])
        if ($itens.Count -lt 2) { continue }
        $versoes = @($itens | ForEach-Object { "$($_.Versao)" } | Sort-Object -Unique)
        if ($versoes.Count -lt 2) { continue }
        [void]$dup.Add([pscustomobject]@{
            Dispositivo = $itens[0].Dispositivo
            Classe      = $itens[0].Classe
            Ocorrencias = $itens.Count
            Versoes     = ($versoes -join ', ')
            Provedor    = $itens[0].Provedor
        })
    }
    return @($dup | Sort-Object -Property Dispositivo)
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

    $terceiros = @($Inventario.Rows | Where-Object { $_.Origem -eq 'Terceiro' }).Count
    $pares = [ordered]@{
        'Drivers enumerados'   = $Inventario.Total
        'De terceiros'         = $terceiros
        'Do Windows'           = ($Inventario.Total - $terceiros)
        'Estado da coleta'     = $Inventario.Status
        'Detalhamento'         = $(if ($Inventario.Enriquecido) { 'assinatura, classe, estado e identificacao disponiveis' } else { 'apenas dados basicos disponiveis' })
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
# SELECAO INTELIGENTE DE DESTINO
#
# A escolha manual do operador (-Path) SEMPRE vence. A selecao automatica existe
# apenas para quando nada foi informado, e percorre candidatos em ordem de
# plausibilidade, validando cada um antes de aceitar.
#
# Estado persistente: fica em LogDir, nao em OutDir. OutDir e recriado a cada
# sessao - um backup gravado la deixaria de ser localizavel na sessao seguinte,
# que e exatamente o momento em que o backup e necessario. Mesma decisao ja
# adotada por Debloat.ps1 para o manifesto de reversao.
# ==============================================================================
$script:EstadoSchema = 1
$script:EstadoCache  = $null

function Get-DriverPastaPersistente {
    <# Raiz persistente do modulo. Sem -Criar nada e criado: as acoes de leitura
       (Diagnose, Last, Validate) nao podem deixar diretorios pelo caminho so por
       terem consultado o estado. Devolve $null quando o caminho nao existe e nao
       pode ser criado - o chamador trata, em vez de receber um caminho invalido. #>
    [CmdletBinding()] param([switch]$Criar)
    $raiz = $Global:CompartDisk.LogDir
    if ([string]::IsNullOrWhiteSpace($raiz)) { return $null }
    $p = Join-Path $raiz 'COMPARTDISK_Drivers'
    try {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            if (-not $Criar) { return $null }
            New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null
        }
        return $p
    } catch {
        Write-Log DEBUG ("Pasta persistente indisponivel ({0}): {1}" -f $p, $_.Exception.Message) -NoConsole
        return $null
    }
}

function Get-DriverEstado {
    <# Estado do modulo entre sessoes: ultimo destino aceito e ultimo backup
       concluido. Um estado corrompido nunca derruba a operacao - vira estado
       vazio e a selecao cai para o proximo candidato. #>
    [CmdletBinding()] param()
    if ($null -ne $script:EstadoCache) { return $script:EstadoCache }

    $vazio = [pscustomobject]@{
        Schema = $script:EstadoSchema; UltimoDestino = ''; UltimoBackup = ''; Atualizado = ''
    }
    $pasta = Get-DriverPastaPersistente
    if (-not $pasta) { $script:EstadoCache = $vazio; return $vazio }

    $arq = Join-Path $pasta 'Drivers_Estado.json'
    if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) { $script:EstadoCache = $vazio; return $vazio }
    try {
        $obj = Get-Content -LiteralPath $arq -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $script:EstadoCache = [pscustomobject]@{
            Schema        = $(if ($obj.Schema) { $obj.Schema } else { 0 })
            UltimoDestino = (Get-DriverSafeText $obj.UltimoDestino '')
            UltimoBackup  = (Get-DriverSafeText $obj.UltimoBackup '')
            Atualizado    = (Get-DriverSafeText $obj.Atualizado '')
        }
    } catch {
        Write-Log DEBUG ("Estado do modulo ilegivel, ignorado: {0}" -f $_.Exception.Message) -NoConsole
        $script:EstadoCache = $vazio
    }
    return $script:EstadoCache
}

function Save-DriverEstado {
    <# Gravacao best-effort: nao poder registrar o ultimo destino nao invalida um
       backup que ja esta no disco. Falha vira DEBUG, nunca eleva o resultado. #>
    [CmdletBinding()] param([string]$UltimoDestino = '', [string]$UltimoBackup = '')
    $pasta = Get-DriverPastaPersistente -Criar
    if (-not $pasta) { return $false }

    $atual = Get-DriverEstado
    $novo = [pscustomobject]@{
        Schema        = $script:EstadoSchema
        UltimoDestino = $(if ($UltimoDestino) { $UltimoDestino } else { $atual.UltimoDestino })
        UltimoBackup  = $(if ($UltimoBackup)  { $UltimoBackup }  else { $atual.UltimoBackup })
        Atualizado    = (Get-Date -Format 's')
    }
    $arq = Join-Path $pasta 'Drivers_Estado.json'
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($arq, ($novo | ConvertTo-Json -Depth 4), $enc)
        $script:EstadoCache = $novo
        return $true
    } catch {
        Write-Log DEBUG ("Nao foi possivel gravar o estado do modulo: {0}" -f $_.Exception.Message) -NoConsole
        return $false
    }
}

# ------------------------------------------------------------------------------
# Destinos que nunca podem receber uma exportacao de drivers. Test-Compart-
# DiskProtectedPath cobre raiz, %SystemRoot% e Program Files; aqui entram os
# caminhos especificos do subsistema de drivers, onde despejar copias
# corromperia o proprio repositorio que se pretende salvar.
# ------------------------------------------------------------------------------
function Get-DriverDestinosProibidos {
    $lista = New-Object System.Collections.ArrayList
    foreach ($p in @(
        $env:SystemRoot
        (Join-Path $env:SystemRoot 'System32')
        (Join-Path $env:SystemRoot 'SysWOW64')
        (Join-Path $env:SystemRoot 'INF')
        (Join-Path $env:SystemRoot 'System32\DriverStore')
        (Join-Path $env:SystemRoot 'System32\config')
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        (Join-Path $env:SystemDrive '\')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$lista.Add("$p".TrimEnd('\')) }
    }
    return @($lista)
}

function Test-DriverDestinoSeguro {
    <# Recusa destinos que nao podem receber conteudo: caminhos protegidos do
       Windows e qualquer caminho DENTRO de %SystemRoot%. Um destino sob
       System32 faria o pnputil gravar centenas de pastas no diretorio de
       sistema, e a limpeza posterior seria manual e arriscada. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Caminho)
    $out = [pscustomobject]@{ Seguro = $false; Motivo = '' }

    $alvo = "$Caminho".TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($alvo)) { $out.Motivo = 'Caminho vazio.'; return $out }

    foreach ($p in (Get-DriverDestinosProibidos)) {
        if ($alvo -ieq $p) {
            $out.Motivo = ('Destino protegido do sistema: {0}' -f $p)
            return $out
        }
    }
    if (Test-CompartDiskProtectedPath -Path $alvo) {
        $out.Motivo = 'Caminho protegido pela politica de caminhos do COMPARTDISK.'
        return $out
    }
    $win = "$env:SystemRoot".TrimEnd('\')
    if (-not [string]::IsNullOrWhiteSpace($win) -and $alvo.StartsWith(($win + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        $out.Motivo = ('Destino dentro do diretorio do Windows ({0}): recusado.' -f $win)
        return $out
    }
    $out.Seguro = $true
    return $out
}

function Get-DriverVolumeInfo {
    <# Tipo e espaco livre do volume de destino. Nunca falha em silencio: quando
       nao for possivel determinar, devolve Ok=$false com o motivo. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$FullPath, [switch]$Unc)
    $out = [pscustomobject]@{
        Ok = $false; Bytes = 0; Total = 0; Tipo = 'Desconhecido'; Removivel = $false
        Rede = [bool]$Unc; Metodo = 'n/d'; Raiz = ''; Detalhe = ''
    }

    if ($Unc) {
        $out.Tipo    = 'Rede'
        $out.Detalhe = 'Caminho UNC: o espaco livre do compartilhamento remoto nao pode ser determinado localmente pelas APIs usadas por este modulo.'
        return $out
    }

    $raiz = ''
    try { $raiz = [System.IO.Path]::GetPathRoot($FullPath) } catch { $raiz = '' }
    if ([string]::IsNullOrWhiteSpace($raiz)) {
        $out.Detalhe = 'Nao foi possivel identificar o volume do destino.'
        return $out
    }
    $out.Raiz = $raiz
    $letra = $raiz.TrimEnd('\')

    # DriveType do Win32_LogicalDisk: 2 removivel, 3 fixo, 4 rede, 5 optico, 6 RAM.
    try {
        $disco = Get-CompartDiskCim -Class Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $letra)
        $d = @($disco) | Select-Object -First 1
        if ($d) {
            $tipo = 0
            try { $tipo = [int]$d.DriveType } catch { $tipo = 0 }
            $out.Tipo = switch ($tipo) {
                2 { 'Removivel' } 3 { 'Fixo' } 4 { 'Rede' } 5 { 'Optico' } 6 { 'RAM' } default { 'Desconhecido' }
            }
            $out.Removivel = ($tipo -eq 2)
            $out.Rede      = ($tipo -eq 4)
            try { $out.Total = [long]$d.Size } catch { $out.Total = 0 }
            if ($null -ne $d.FreeSpace) {
                $out.Ok = $true; $out.Bytes = [long]$d.FreeSpace; $out.Metodo = 'Win32_LogicalDisk'
                return $out
            }
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
            try { $out.Total = [long]$di.TotalSize } catch { $out.Total = 0 }
            if ($out.Tipo -eq 'Desconhecido') {
                $out.Tipo      = "$($di.DriveType)"
                $out.Removivel = ($di.DriveType -eq [System.IO.DriveType]::Removable)
                $out.Rede      = ($di.DriveType -eq [System.IO.DriveType]::Network)
            }
            $out.Detalhe = ''
            return $out
        }
        $out.Detalhe += ' O volume nao esta pronto.'
    } catch {
        $out.Detalhe += (' DriveInfo falhou: {0}' -f $_.Exception.Message)
    }
    return $out
}

# Compatibilidade: o restante do modulo continua pedindo apenas espaco livre.
function Get-DriverFreeSpace {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$FullPath, [switch]$Unc)
    return (Get-DriverVolumeInfo -FullPath $FullPath -Unc:$Unc)
}

function Test-DriverDestinoGravavel {
    <# Permissao de escrita comprovada por gravacao real, nao por leitura de ACL.
       Uma ACL permissiva convive com share somente-leitura, quota, disco cheio,
       midia protegida e filtro de antivirus - e todos falham na hora errada. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Diretorio, [switch]$Criar)
    $out = [pscustomobject]@{ Ok = $false; Criado = $false; Detalhe = '' }

    try {
        if (-not (Test-Path -LiteralPath $Diretorio -PathType Container)) {
            if (-not $Criar) { $out.Detalhe = 'O diretorio nao existe.'; return $out }
            New-Item -ItemType Directory -Path $Diretorio -Force -ErrorAction Stop | Out-Null
            if (-not (Test-Path -LiteralPath $Diretorio -PathType Container)) {
                $out.Detalhe = 'O diretorio nao existe apos a criacao.'
                return $out
            }
            $out.Criado = $true
        }
    } catch {
        $out.Detalhe = ('Nao foi possivel criar o diretorio: {0}' -f $_.Exception.Message)
        return $out
    }

    $probe = Join-Path $Diretorio ('.compartdisk_drv_{0}.tmp' -f $PID)
    try {
        [System.IO.File]::WriteAllText($probe, 'compartdisk')
        $lido = [System.IO.File]::ReadAllText($probe)
        if ($lido -ne 'compartdisk') { throw 'O conteudo relido nao confere.' }
        $out.Ok = $true
    } catch {
        $out.Detalhe = ('Sem permissao de escrita efetiva: {0}' -f $_.Exception.Message)
    } finally {
        try { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction Stop } }
        catch { Write-Log DEBUG "Sonda temporaria residual em $probe" -NoConsole }
    }
    return $out
}

function Resolve-DriverPath {
    <# Normalizacao unica de caminho: relativo, absoluto, UNC, caracteres
       invalidos e comprimento. Sem concatenacao fragil. #>
    [CmdletBinding()] param([Parameter(Mandatory)][AllowEmptyString()][string]$Caminho)
    $out = [pscustomobject]@{ Ok = $false; Completo = ''; Unc = $false; Detalhe = '' }

    $bruto = "$Caminho".Trim().Trim('"').Trim()
    if ([string]::IsNullOrWhiteSpace($bruto)) { $out.Detalhe = 'Caminho vazio.'; return $out }

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

    $out.Completo = $completo
    $out.Ok = $true
    return $out
}

function Test-DriverCandidatoDestino {
    <# Avalia um candidato a destino sem alterar nada alem de criar o proprio
       diretorio e a sonda de escrita. Devolve o veredito completo para que a
       selecao possa ser auditada no relatorio. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Caminho,
        [Parameter(Mandatory)][string]$Origem,
        [long]$MinimoBytes = 0,
        [switch]$Criar
    )
    $out = [pscustomobject]@{
        Ok = $false; Caminho = "$Caminho"; Origem = $Origem; Unc = $false
        Tipo = 'n/d'; EspacoLivre = 0; EspacoConhecido = $false; Motivo = ''
    }
    if ([string]::IsNullOrWhiteSpace($Caminho)) { $out.Motivo = 'nao definido'; return $out }

    $norm = Resolve-DriverPath -Caminho $Caminho
    if (-not $norm.Ok) { $out.Motivo = $norm.Detalhe; return $out }
    $out.Caminho = $norm.Completo
    $out.Unc     = $norm.Unc

    $seg = Test-DriverDestinoSeguro -Caminho $norm.Completo
    if (-not $seg.Seguro) { $out.Motivo = $seg.Motivo; return $out }

    $vol = Get-DriverVolumeInfo -FullPath $norm.Completo -Unc:$norm.Unc
    $out.Tipo            = $vol.Tipo
    $out.EspacoConhecido = $vol.Ok
    $out.EspacoLivre     = $vol.Bytes
    if ($vol.Ok -and $MinimoBytes -gt 0 -and $vol.Bytes -lt $MinimoBytes) {
        $out.Motivo = ('espaco livre insuficiente ({0} para um minimo de {1})' -f (ConvertTo-CompartDiskSize $vol.Bytes), (ConvertTo-CompartDiskSize $MinimoBytes))
        return $out
    }

    if ($Criar) {
        $grav = Test-DriverDestinoGravavel -Diretorio $norm.Completo -Criar
    } else {
        # Sem -Criar nada e criado: o diagnostico e somente leitura e nao pode
        # deixar diretorios pelo caminho so por ter avaliado candidatos. Sonda-se
        # o ancestral existente mais proximo, que e onde a criacao aconteceria.
        $alvo = $norm.Completo
        while (-not (Test-Path -LiteralPath $alvo -PathType Container)) {
            $pai = Split-Path -Parent $alvo
            if ([string]::IsNullOrWhiteSpace($pai) -or $pai -eq $alvo) { break }
            $alvo = $pai
        }
        if (-not (Test-Path -LiteralPath $alvo -PathType Container)) {
            $out.Motivo = 'nenhum diretorio ancestral existente para avaliar'
            return $out
        }
        $grav = Test-DriverDestinoGravavel -Diretorio $alvo
        if ($grav.Ok -and $alvo -ne $norm.Completo) {
            $out.Motivo = ('sera criado em {0} (nao criado agora: verificacao somente leitura)' -f $alvo)
        }
    }
    if (-not $grav.Ok) { $out.Motivo = $grav.Detalhe; return $out }

    $out.Ok = $true
    if ([string]::IsNullOrWhiteSpace($out.Motivo)) { $out.Motivo = 'aceito' }
    return $out
}

function Resolve-DriverBackupBase {
    <# Selecao de destino. -Path do operador vence sempre e nunca e substituido
       em silencio: quando o caminho informado e invalido a operacao para, em vez
       de gravar em outro lugar.

       Sem -Path, percorre nesta ordem:
         1. ultimo destino utilizado com sucesso (estado persistente)
         2. diretorio persistente do projeto (LogDir\COMPARTDISK_Drivers)
         3. area de documentos do usuario
         4. maior volume fixo local com espaco suficiente
         5. diretorio da sessao (comportamento historico, ultimo recurso)

       Temporarios do sistema NAO entram: um backup de drivers precisa sobreviver
       a limpeza de disco, e %TEMP% e alvo declarado do proprio Cleanup.ps1. #>
    [CmdletBinding()] param([string]$Path, [long]$MinimoBytes = 0, [switch]$SemCriar)
    $criar = -not $SemCriar
    $out = [pscustomobject]@{
        Ok = $false; Base = ''; Unc = $false; Tipo = 'n/d'; Origem = ''
        Detalhe = ''; Avaliados = @()
    }

    $bruto = "$Path".Trim().Trim('"').Trim()
    if (-not [string]::IsNullOrWhiteSpace($bruto)) {
        $c = Test-DriverCandidatoDestino -Caminho $bruto -Origem 'Parametro -Path (escolha do operador)' -Criar:$criar
        $out.Avaliados = @($c)
        if (-not $c.Ok) {
            $out.Detalhe = ('Destino informado recusado: {0}' -f $c.Motivo)
            return $out
        }
        $out.Ok = $true; $out.Base = $c.Caminho; $out.Unc = $c.Unc; $out.Tipo = $c.Tipo
        $out.Origem  = $c.Origem
        $out.Detalhe = 'Destino informado pelo operador.'
        return $out
    }

    $estado = Get-DriverEstado
    $docs = ''
    try { $docs = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments) } catch { $docs = '' }
    if ([string]::IsNullOrWhiteSpace($docs) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $docs = Join-Path $env:USERPROFILE 'Documents'
    }

    $candidatos = New-Object System.Collections.ArrayList
    if ($estado.UltimoDestino) {
        [void]$candidatos.Add(@{ P = $estado.UltimoDestino; O = 'Ultimo destino utilizado com sucesso' })
    }
    # Caminho calculado, nao criado: quem decide criar e Test-DriverCandidatoDestino,
    # conforme -Criar. Assim o Diagnose avalia o mesmo candidato sem escrever nada.
    if (-not [string]::IsNullOrWhiteSpace($Global:CompartDisk.LogDir)) {
        [void]$candidatos.Add(@{
            P = (Join-Path (Join-Path $Global:CompartDisk.LogDir 'COMPARTDISK_Drivers') 'Backup')
            O = 'Diretorio persistente do projeto'
        })
    }
    if ($docs) {
        [void]$candidatos.Add(@{ P = (Join-Path $docs 'COMPARTDISK_Drivers'); O = 'Area de documentos do usuario' })
    }
    foreach ($v in (Get-DriverVolumesCandidatos -MinimoBytes $MinimoBytes)) {
        [void]$candidatos.Add(@{ P = (Join-Path $v 'COMPARTDISK_Drivers'); O = ('Volume local com espaco suficiente ({0})' -f $v) })
    }
    if (-not [string]::IsNullOrWhiteSpace($Global:CompartDisk.OutDir)) {
        [void]$candidatos.Add(@{ P = (Join-Path $Global:CompartDisk.OutDir 'Backup_Drivers'); O = 'Diretorio da sessao (ultimo recurso)' })
    }

    $avaliados = New-Object System.Collections.ArrayList
    $vistos    = @{}
    foreach ($cand in $candidatos) {
        $chave = "$($cand.P)".TrimEnd('\').ToLowerInvariant()
        if ($vistos.ContainsKey($chave)) { continue }
        $vistos[$chave] = $true

        $c = Test-DriverCandidatoDestino -Caminho $cand.P -Origem $cand.O -MinimoBytes $MinimoBytes -Criar:$criar
        [void]$avaliados.Add($c)
        if ($c.Ok) {
            $out.Ok = $true; $out.Base = $c.Caminho; $out.Unc = $c.Unc; $out.Tipo = $c.Tipo
            $out.Origem  = $c.Origem
            $out.Detalhe = ('Destino escolhido automaticamente: {0}.' -f $c.Origem)
            $out.Avaliados = @($avaliados)
            return $out
        }
        Write-Log DEBUG ("Destino descartado ({0}): {1} - {2}" -f $cand.O, $c.Caminho, $c.Motivo) -NoConsole
    }

    $out.Avaliados = @($avaliados)
    $out.Detalhe = 'Nenhum destino atendeu aos criterios de seguranca, permissao de escrita e espaco livre.'
    return $out
}

function Get-DriverVolumesCandidatos {
    <# Volumes fixos locais, do maior espaco livre para o menor. Removiveis,
       opticos, RAM e rede ficam de fora da selecao AUTOMATICA: uma midia que
       pode ser desconectada nao e destino padrao para um backup do qual a
       reinstalacao vai depender. O operador ainda pode escolher qualquer um
       deles explicitamente por -Path. #>
    [CmdletBinding()] param([long]$MinimoBytes = 0)
    $saida = New-Object System.Collections.ArrayList
    try {
        $discos = Get-CompartDiskCim -Class Win32_LogicalDisk -Filter 'DriveType=3'
        $ordenados = @(ConvertTo-DriverArray $discos | Sort-Object -Property @{ Expression = { [long]$_.FreeSpace }; Descending = $true })
        foreach ($d in $ordenados) {
            $livre = 0
            try { $livre = [long]$d.FreeSpace } catch { $livre = 0 }
            if ($MinimoBytes -gt 0 -and $livre -lt $MinimoBytes) { continue }
            $raiz = "$($d.DeviceID)"
            if ([string]::IsNullOrWhiteSpace($raiz)) { continue }
            [void]$saida.Add(($raiz.TrimEnd('\') + '\'))
        }
    } catch {
        Write-Log DEBUG ("Enumeracao de volumes indisponivel: {0}" -f $_.Exception.Message) -NoConsole
    }
    return @($saida)
}

function Add-DriverDestinoSection {
    <# Torna a escolha auditavel: quais candidatos foram avaliados e por que cada
       um foi aceito ou descartado. #>
    param([Parameter(Mandatory)][object]$Base, [string]$Titulo = 'Selecao do destino')
    $linhas = @(ConvertTo-DriverArray $Base.Avaliados | ForEach-Object {
        [pscustomobject]@{
            Origem      = $_.Origem
            Caminho     = $_.Caminho
            Tipo        = $_.Tipo
            EspacoLivre = $(if ($_.EspacoConhecido) { (ConvertTo-CompartDiskSize $_.EspacoLivre) } else { 'nao determinado' })
            Resultado   = $(if ($_.Ok) { 'Aceito' } else { 'Descartado' })
            Motivo      = $_.Motivo
        }
    })
    Add-CompartDiskSection -Title $Titulo -Status $(if ($Base.Ok) { 'OK' } else { 'CRIT' }) -Rows $linhas `
        -Pairs ([ordered]@{
            'Destino'            = $(if ($Base.Ok) { $Base.Base } else { 'nenhum' })
            'Criterio'           = $(if ($Base.Origem) { $Base.Origem } else { 'n/d' })
            'Tipo de volume'     = $Base.Tipo
            'Candidatos avaliados' = @($Base.Avaliados).Count
        }) `
        -Summary $Base.Detalhe
}

# ==============================================================================
# REPOSITORIO DE DRIVERS: ENUMERACAO E ESTIMATIVA
# ==============================================================================
$script:PublicadosCache = $null
$script:EstimativaCache = $null

function Get-DriverPublicados {
    <# Pacotes publicados no repositorio, via 'pnputil /enum-drivers'.

       A saida do pnputil e localizada: os ROTULOS mudam com o idioma do Windows,
       mas os NOMES DE ARQUIVO nao. Extrair todos os tokens '*.inf' e separar
       'oemNN.inf' (nome publicado) dos demais (nome original) funciona em
       qualquer idioma, sem depender de traducao de rotulo.

       Devolve { Ok, Publicados, Originais, Total, Detalhe }. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$PnpUtil, [switch]$Refresh)
    if ($null -ne $script:PublicadosCache -and -not $Refresh) { return $script:PublicadosCache }

    $out = [pscustomobject]@{ Ok = $false; Publicados = @(); Originais = @(); Total = 0; Detalhe = '' }
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $PnpUtil -Arguments @('/enum-drivers') -TimeoutSeconds 300
    } -Activity 'pnputil /enum-drivers' -Silent

    if (-not $r.Success -or $null -eq $r.Value) {
        $out.Detalhe = ('Nao foi possivel enumerar os pacotes publicados: {0}' -f $(if ($r.Error) { $r.Error.Exception.Message } else { 'sem detalhe' }))
        if (-not $Refresh) { $script:PublicadosCache = $out }
        return $out
    }
    if ([int]$r.Value.ExitCode -ne 0) {
        $out.Detalhe = ('pnputil /enum-drivers retornou codigo {0}.' -f $r.Value.ExitCode)
        if (-not $Refresh) { $script:PublicadosCache = $out }
        return $out
    }

    try {
        $pub = @{}
        $ori = @{}
        foreach ($m in [regex]::Matches("$($r.Value.StdOut)", '(?i)\b[A-Za-z0-9_~\-\.]+\.inf\b')) {
            $nome = $m.Value.ToLowerInvariant()
            if ($nome -match '^oem\d+\.inf$') { $pub[$nome] = $true } else { $ori[$nome] = $true }
        }
        $out.Ok         = $true
        $out.Publicados = @($pub.Keys | Sort-Object)
        $out.Originais  = @($ori.Keys | Sort-Object)
        $out.Total      = $out.Publicados.Count
        $out.Detalhe    = ('{0} pacote(s) publicado(s) no repositorio de drivers.' -f $out.Total)
    } catch {
        $out.Detalhe = ('Falha ao interpretar a saida de /enum-drivers: {0}' -f $_.Exception.Message)
    }
    if (-not $Refresh) { $script:PublicadosCache = $out }
    return $out
}

function Get-DriverStoreEstimate {
    <# Limite SUPERIOR do volume a exportar: o FileRepository contem tambem os
       pacotes inbox, que o pnputil normalmente nao exporta. E estimativa
       declarada como tal, nunca apresentada como valor exato, e o resultado e
       cacheado - a varredura do repositorio e a operacao mais cara do modulo. #>
    [CmdletBinding()] param()
    if ($null -ne $script:EstimativaCache) { return $script:EstimativaCache }

    $out = [pscustomobject]@{ Ok = $false; Bytes = 0; Arquivos = 0; Pastas = 0; Segundos = 0; Detalhe = '' }
    $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    if (-not (Test-Path -LiteralPath $repo)) {
        $out.Detalhe = 'Repositorio de drivers nao localizado para estimativa.'
        $script:EstimativaCache = $out
        return $out
    }
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        try { $out.Pastas = @([System.IO.Directory]::EnumerateDirectories($repo)).Count } catch { $out.Pastas = 0 }
        $tam = Get-CompartDiskFolderSize -Path $repo
        $cron.Stop()
        $out.Segundos = [math]::Round($cron.Elapsed.TotalSeconds, 1)
        if ($null -eq $tam -or -not $tam.Exists) {
            $out.Detalhe = 'Nao foi possivel medir o repositorio de drivers.'
            $script:EstimativaCache = $out
            return $out
        }
        $bytes = 0; $arquivos = 0
        try { $bytes = [long]$tam.Bytes } catch { $bytes = 0 }
        try { $arquivos = [int]$tam.Files } catch { $arquivos = 0 }
        if ($bytes -le 0) {
            $out.Detalhe = 'A medicao do repositorio de drivers devolveu tamanho zero.'
            $script:EstimativaCache = $out
            return $out
        }
        $out.Ok = $true; $out.Bytes = $bytes; $out.Arquivos = $arquivos
        $out.Detalhe = 'Limite superior: inclui pacotes inbox que normalmente nao sao exportados.'
    } catch {
        $cron.Stop()
        $out.Detalhe = ('Estimativa indisponivel: {0}' -f $_.Exception.Message)
        Write-Log WARN 'Nao foi possivel estimar o tamanho do repositorio de drivers.' -ErrorRecord $_
    }
    $script:EstimativaCache = $out
    return $out
}

# ==============================================================================
# LEITURA DE INF
# O nome da pasta criada pelo pnputil nao e contrato publico. Ler o proprio INF
# e o unico jeito estavel de saber provedor, versao, data, classe e catalogo do
# pacote exportado - e funciona em qualquer idioma do Windows.
# ==============================================================================
function Read-DriverInf {
    <# Le a secao [Version] de um INF e resolve tokens %X% pela secao [Strings].
       Leitura limitada aos primeiros 64 KB: [Version] e [Strings] ficam no
       inicio e no fim de arquivos pequenos, e nenhum INF valido precisa de mais
       do que isso para declarar os campos usados aqui. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Caminho)
    $out = [pscustomobject]@{
        Ok = $false; Provedor = 'n/d'; Versao = 'n/d'; Data = 'n/d'; Classe = 'n/d'
        Catalogo = ''; Detalhe = ''
    }
    try {
        $texto = ''
        $fs = [System.IO.File]::OpenRead($Caminho)
        try {
            $lim = [math]::Min(65536, $fs.Length)
            $buf = New-Object byte[] $lim
            $lidos = $fs.Read($buf, 0, $lim)
            # INF pode vir em UTF-16 (com BOM) ou ANSI. StreamReader com deteccao
            # de BOM cobre o primeiro caso; o segundo degrada apenas os acentos,
            # e nenhum campo lido aqui depende deles.
            $ms = New-Object System.IO.MemoryStream($buf, 0, $lidos)
            try {
                $sr = New-Object System.IO.StreamReader($ms, [System.Text.Encoding]::Default, $true)
                try { $texto = $sr.ReadToEnd() } finally { $sr.Dispose() }
            } finally { $ms.Dispose() }
        } finally { $fs.Dispose() }

        if ([string]::IsNullOrWhiteSpace($texto)) { $out.Detalhe = 'INF vazio ou ilegivel.'; return $out }

        $strings = @{}
        $secao   = ''
        $version = @{}
        foreach ($linha in ($texto -split "`r?`n")) {
            $l = $linha.Trim()
            if ($l -match '^\[(.+)\]$') { $secao = $Matches[1].Trim().ToLowerInvariant(); continue }
            if ($l.StartsWith(';') -or [string]::IsNullOrWhiteSpace($l)) { continue }
            $i = $l.IndexOf('=')
            if ($i -lt 1) { continue }
            $chave = $l.Substring(0, $i).Trim()
            $valor = $l.Substring($i + 1).Trim().Trim('"')
            if ($secao -eq 'strings') { $strings[('%{0}%' -f $chave).ToLowerInvariant()] = $valor }
            elseif ($secao -eq 'version') { $version[$chave.ToLowerInvariant()] = $valor }
        }

        $resolver = {
            param($v)
            $t = "$v".Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { return 'n/d' }
            $k = $t.ToLowerInvariant()
            if ($strings.ContainsKey($k)) { return $strings[$k] }
            return $t
        }

        if ($version.ContainsKey('provider')) { $out.Provedor = (& $resolver $version['provider']) }
        if ($version.ContainsKey('class'))    { $out.Classe   = (& $resolver $version['class']) }
        if ($version.ContainsKey('catalogfile')) { $out.Catalogo = "$($version['catalogfile'])".Trim() }
        if ($version.ContainsKey('driverver')) {
            # DriverVer=MM/DD/YYYY,x.y.z.w
            # A data do INF e SEMPRE MM/DD/YYYY (especificacao do formato INF), e
            # por isso o parse exato vem primeiro. O parser generico interpretaria
            # 05/12/2023 como 5 de dezembro em qualquer dia menor ou igual a 12 -
            # um erro silencioso de mes/dia em quase metade dos pacotes.
            $dv = "$($version['driverver'])"
            $partes = $dv -split ','
            if ($partes.Count -ge 1) {
                $dt  = $null
                $tmp = [datetime]::MinValue
                if ([datetime]::TryParseExact($partes[0].Trim(), 'MM/dd/yyyy',
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$tmp)) { $dt = $tmp }
                else { $dt = ConvertTo-DriverDate ($partes[0].Trim()) }
                if ($null -ne $dt) { $out.Data = $dt.ToString('yyyy-MM-dd') }
            }
            if ($partes.Count -ge 2) { $out.Versao = $partes[1].Trim() }
        }
        $out.Ok = $true
    } catch {
        $out.Detalhe = $_.Exception.Message
        Write-Log DEBUG ("Leitura de INF falhou em {0}: {1}" -f $Caminho, $_.Exception.Message) -NoConsole
    }
    return $out
}

function Get-DriverInfHardwareIds {
    <# IDs de hardware declarados no INF, extraidos por padrao de token
       (BARRAMENTO\IDENTIFICADOR). E uma heuristica deliberadamente conservadora
       e usada em UM lugar so: o filtro -OnlyMissing do Restore. Quando nada e
       extraido, o pacote fica FORA do conjunto - nunca dentro por suposicao. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Caminho)
    $ids = @{}
    try {
        $texto = [System.IO.File]::ReadAllText($Caminho)
        foreach ($m in [regex]::Matches($texto, '(?im)\b(PCI|USB|HDAUDIO|ACPI|HID|SCSI|SD|ROOT|SWC|UMB|BTH|MMDEVAPI|DISPLAY|MONITOR|IDE)\\[A-Z0-9_&\-\.\+]{3,}')) {
            $ids[$m.Value.ToUpperInvariant()] = $true
        }
    } catch {
        Write-Log DEBUG ("IDs de hardware nao extraidos de {0}: {1}" -f $Caminho, $_.Exception.Message) -NoConsole
    }
    return @($ids.Keys)
}

# ==============================================================================
# ESTRUTURA DO BACKUP E MANIFESTO
#
# Backup_<carimbo>/
#   Drivers/     pacotes exportados pelo pnputil (alvo do /export-driver)
#   Manifest/    Drivers_Manifesto.json  (inventario auditavel do backup)
#   Metadata/    Inventario.json         (retrato dos drivers no momento)
#   Validation/  Drivers_Validacao.json  (resultado da ultima validacao)
#
# Nao existe subpasta Logs: o COMPARTDISK ja tem log central de sessao, e
# espalhar arquivos de log por backup contraria essa decisao de arquitetura.
#
# Backups da versao anterior gravavam os pacotes direto na pasta com carimbo.
# Esse formato continua sendo lido por Validate, Restore e Package.
# ==============================================================================
$script:ManifestoSchema = 1
$script:ManifestoNome   = 'Drivers_Manifesto.json'
$script:ValidacaoNome   = 'Drivers_Validacao.json'

function Get-DriverBackupLayout {
    <# Descobre onde estao os pacotes dentro de um diretorio de backup, aceitando
       o formato atual e o anterior. Devolve { Ok, Raiz, Drivers, Manifest,
       Metadata, Validation, Formato, Detalhe }. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Raiz)
    $out = [pscustomobject]@{
        Ok = $false; Raiz = $Raiz; Drivers = ''; Manifest = ''; Metadata = ''
        Validation = ''; Formato = 'desconhecido'; Detalhe = ''
    }
    if (-not (Test-Path -LiteralPath $Raiz -PathType Container)) {
        $out.Detalhe = 'O diretorio de backup nao existe.'
        return $out
    }
    $out.Manifest   = Join-Path $Raiz 'Manifest'
    $out.Metadata   = Join-Path $Raiz 'Metadata'
    $out.Validation = Join-Path $Raiz 'Validation'

    $sub = Join-Path $Raiz 'Drivers'
    if (Test-Path -LiteralPath $sub -PathType Container) {
        $out.Drivers = $sub
        $out.Formato = 'estruturado'
        $out.Ok = $true
        return $out
    }
    # Formato anterior: pacotes direto na raiz do carimbo.
    $out.Drivers = $Raiz
    $out.Formato = 'legado'
    $out.Ok = $true
    $out.Detalhe = 'Backup no formato anterior (pacotes na raiz, sem subpastas).'
    return $out
}

function Get-DriverPacotesDoDisco {
    <# Inventario real do que existe no disco: uma entrada por pasta de pacote,
       com o INF lido de verdade. Nao depende de manifesto nem do nome que o
       pnputil deu a pasta. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Diretorio, [switch]$ComHash)
    $saida = New-Object System.Collections.ArrayList
    $pastas = @()
    try { $pastas = @(Get-ChildItem -LiteralPath $Diretorio -Directory -ErrorAction Stop) }
    catch {
        Write-Log WARN ('Nao foi possivel listar os pacotes em {0}.' -f $Diretorio) -ErrorRecord $_
        return @($saida)
    }

    foreach ($p in $pastas) {
        $infs = @()
        try { $infs = @(Get-ChildItem -LiteralPath $p.FullName -Filter '*.inf' -File -Recurse -ErrorAction Stop) }
        catch { Write-Log DEBUG ("INF nao enumerado em {0}: {1}" -f $p.FullName, $_.Exception.Message) -NoConsole }

        $bytes = 0; $arquivos = 0; $vazios = 0
        try {
            $todos = @(Get-ChildItem -LiteralPath $p.FullName -File -Recurse -Force -ErrorAction Stop)
            $arquivos = $todos.Count
            foreach ($f in $todos) {
                $bytes += [long]$f.Length
                if ($f.Length -le 0) { $vazios++ }
            }
        } catch { Write-Log DEBUG ("Medicao do pacote {0} falhou: {1}" -f $p.Name, $_.Exception.Message) -NoConsole }

        $meta = $null
        $infPrincipal = @($infs) | Select-Object -First 1
        if ($infPrincipal) { $meta = Read-DriverInf -Caminho $infPrincipal.FullName }

        $hashInf = ''; $hashCat = ''
        if ($ComHash -and $infPrincipal) {
            $h = Get-DriverHashArquivo -Caminho $infPrincipal.FullName
            if ($h.Ok) { $hashInf = $h.Sha256 }
            if ($meta -and $meta.Catalogo) {
                $cat = Join-Path $infPrincipal.DirectoryName $meta.Catalogo
                if (Test-Path -LiteralPath $cat -PathType Leaf) {
                    $hc = Get-DriverHashArquivo -Caminho $cat
                    if ($hc.Ok) { $hashCat = $hc.Sha256 }
                }
            }
        }

        [void]$saida.Add([pscustomobject]@{
            Pasta         = $p.Name
            Caminho       = $p.FullName
            Inf           = $(if ($infPrincipal) { $infPrincipal.Name } else { 'n/d' })
            InfCaminho    = $(if ($infPrincipal) { $infPrincipal.FullName } else { '' })
            Infs          = @($infs).Count
            Provedor      = $(if ($meta) { $meta.Provedor } else { 'n/d' })
            Versao        = $(if ($meta) { $meta.Versao }   else { 'n/d' })
            Data          = $(if ($meta) { $meta.Data }     else { 'n/d' })
            Classe        = $(if ($meta) { $meta.Classe }   else { 'n/d' })
            Catalogo      = $(if ($meta) { $meta.Catalogo } else { '' })
            Arquivos      = $arquivos
            Bytes         = $bytes
            ArquivosVazios= $vazios
            HashInf       = $hashInf
            HashCatalogo  = $hashCat
        })
    }
    return @($saida)
}

function New-DriverManifesto {
    <# Manifesto = retrato auditavel do backup, nao log. Permite validar,
       restaurar e comparar sem depender do sistema que o gerou. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destino,
        [Parameter(Mandatory)][string]$Metodo,
        [object]$Inventario = $null
    )
    $win = $null
    try { $win = Test-WindowsVersion } catch { $win = $null }

    return [pscustomobject]@{
        Produto        = $Global:CompartDisk.Product
        VersaoProduto  = $Global:CompartDisk.Version
        Schema         = $script:ManifestoSchema
        Tipo           = 'DriversBackup'
        Criado         = (Get-Date -Format 's')
        Sessao         = $Global:CompartDisk.Session
        Computador     = $Global:CompartDisk.Computer
        Usuario        = $Global:CompartDisk.User
        Windows        = [pscustomobject]@{
            Nome        = (Get-CompartDiskOSName)
            Build       = (Get-CompartDiskBuild)
            Arquitetura = $(if ($win -and $win.Architecture) { "$($win.Architecture)" } else { "$env:PROCESSOR_ARCHITECTURE" })
        }
        PowerShell     = [pscustomobject]@{
            Motor  = $Global:CompartDisk.Engine
            Versao = $Global:CompartDisk.PSVersion
        }
        Metodo         = $Metodo
        Destino        = $Destino
        Estado         = 'EmExecucao'
        Totais         = [pscustomobject]@{
            DriversInventariados = $(if ($Inventario) { $Inventario.Total } else { 0 })
            PacotesPublicados    = 0
            PacotesExportados    = 0
            PacotesComProblema   = 0
            Arquivos             = 0
            Bytes                = 0
        }
        Pacotes        = (New-Object System.Collections.ArrayList)
        Observacoes    = (New-Object System.Collections.ArrayList)
    }
}

function Save-DriverManifesto {
    <# Gravacao atomica com validacao por releitura, no mesmo padrao ja adotado
       por Debloat.ps1: um manifesto truncado e pior que manifesto nenhum, porque
       cria a ilusao de que o backup pode ser auditado e restaurado. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifesto,
        [Parameter(Mandatory)][string]$Diretorio,
        [string]$Nome = ''
    )
    $out = [pscustomobject]@{ Ok = $false; Caminhos = @(); Erro = '' }
    if ([string]::IsNullOrWhiteSpace($Nome)) { $Nome = $script:ManifestoNome }

    $json = $null
    try {
        $copia = $Manifesto | Select-Object * -ExcludeProperty Pacotes, Observacoes
        $copia | Add-Member -NotePropertyName Pacotes     -NotePropertyValue @($Manifesto.Pacotes)     -Force
        $copia | Add-Member -NotePropertyName Observacoes -NotePropertyValue @($Manifesto.Observacoes) -Force
        $json = $copia | ConvertTo-Json -Depth 10
    } catch {
        $out.Erro = ('Serializacao do manifesto falhou: {0}' -f $_.Exception.Message)
        Write-Log ERR $out.Erro -ErrorRecord $_
        return $out
    }

    $esperados = @($Manifesto.Pacotes).Count
    $enc = New-Object System.Text.UTF8Encoding($false)
    $gravados = New-Object System.Collections.ArrayList

    foreach ($dir in @($Diretorio, $Global:CompartDisk.OutDir)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $destino = Join-Path $dir $Nome
        $tmp = "$destino.tmp"
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
            [System.IO.File]::WriteAllText($tmp, $json, $enc)
            $obj = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $obj) { throw 'A releitura devolveu conteudo vazio.' }
            if (@($obj.Pacotes).Count -ne $esperados) {
                throw ('Releitura nao conferiu: {0} de {1} pacote(s).' -f @($obj.Pacotes).Count, $esperados)
            }
            [System.IO.File]::Copy($tmp, $destino, $true)
            [System.IO.File]::Delete($tmp)
            [void]$gravados.Add($destino)
        } catch {
            Write-Log WARN ('Nao foi possivel gravar o manifesto em: {0}' -f $destino) -ErrorRecord $_
            try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } }
            catch { Write-Log DEBUG "Temporario residual em $tmp" -NoConsole }
        }
    }

    $out.Caminhos = @($gravados)
    $out.Ok = ($gravados.Count -gt 0)
    if (-not $out.Ok) { $out.Erro = 'Nenhuma copia do manifesto pode ser gravada.' }
    foreach ($g in $gravados) { Write-Log OK ('Manifesto do backup: {0}' -f $g) }
    return $out
}

function Import-DriverManifesto {
    <# Carrega o manifesto de um backup. Ausencia de manifesto NAO invalida o
       backup: os backups da versao anterior nao tinham um, e continuam
       validaveis e restauraveis pela leitura do disco. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Raiz)
    $out = [pscustomobject]@{ Ok = $false; Manifesto = $null; Caminho = ''; Detalhe = '' }

    $layout = Get-DriverBackupLayout -Raiz $Raiz
    $candidatos = @(
        (Join-Path $layout.Manifest $script:ManifestoNome)
        (Join-Path $Raiz $script:ManifestoNome)
    )
    foreach ($c in $candidatos) {
        if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        try {
            $obj = Get-Content -LiteralPath $c -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $obj) { throw 'Conteudo vazio.' }
            $out.Ok = $true; $out.Manifesto = $obj; $out.Caminho = $c
            $out.Detalhe = ('Manifesto schema {0}, gerado em {1}.' -f (Get-DriverSafeText $obj.Schema), (Get-DriverSafeText $obj.Criado))
            return $out
        } catch {
            $out.Detalhe = ('Manifesto encontrado, porem ilegivel: {0}' -f $_.Exception.Message)
            Write-Log WARN ('Manifesto ilegivel em {0}.' -f $c) -ErrorRecord $_
            return $out
        }
    }
    $out.Detalhe = 'Nenhum manifesto encontrado neste backup.'
    return $out
}

# ==============================================================================
# VALIDACAO DO BACKUP
# "pnputil terminou" nao e prova de backup. Aqui se confirma estrutura, contagem,
# tamanho, ausencia de arquivo vazio, legibilidade real e coerencia com o
# manifesto. Nada e declarado utilizavel sem passar por isto.
# ==============================================================================
function Test-DriverBackupIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destino,
        [int]$Amostra = 5,
        [switch]$ConferirHash
    )
    $out = [pscustomobject]@{
        Existe = $false; Formato = 'desconhecido'; Pacotes = 0; Infs = 0; Bytes = 0
        Arquivos = 0; ArquivosVazios = 0; PacotesSemInf = 0; Legivel = $false
        AmostrasLidas = 0; AmostrasFalhas = 0; ManifestoOk = $false
        ManifestoDetalhe = ''; ManifestoPacotes = 0; DivergenciaManifesto = 0
        HashConferidos = 0; HashDivergentes = 0; Utilizavel = $false; Detalhe = ''
    }
    if (-not (Test-Path -LiteralPath $Destino -PathType Container)) {
        $out.Detalhe = 'O diretorio de backup nao existe.'
        return $out
    }
    $out.Existe = $true

    $layout = Get-DriverBackupLayout -Raiz $Destino
    $out.Formato = $layout.Formato
    if (-not (Test-Path -LiteralPath $layout.Drivers -PathType Container)) {
        $out.Detalhe = 'A pasta de pacotes do backup nao existe.'
        return $out
    }

    $pacotes = Get-DriverPacotesDoDisco -Diretorio $layout.Drivers -ComHash:$ConferirHash
    $out.Pacotes = @($pacotes).Count
    foreach ($p in $pacotes) {
        $out.Infs           += $p.Infs
        $out.Bytes          += $p.Bytes
        $out.Arquivos       += $p.Arquivos
        $out.ArquivosVazios += $p.ArquivosVazios
        if ($p.Infs -eq 0) { $out.PacotesSemInf++ }
    }

    if ($out.Pacotes -eq 0) {
        $out.Detalhe = 'Nenhuma pasta de pacote encontrada no backup.'
        return $out
    }
    if ($out.Infs -eq 0) {
        $out.Detalhe = 'Nenhum arquivo .inf encontrado no backup: o conteudo nao e restauravel.'
        return $out
    }

    # Legibilidade real, em amostra distribuida - nao apenas o primeiro item.
    $comInf = @($pacotes | Where-Object { $_.InfCaminho })
    $total  = $comInf.Count
    $n      = [math]::Min([math]::Max(1, $Amostra), $total)
    $passo  = [math]::Max(1, [int][math]::Floor($total / $n))
    for ($i = 0; $i -lt $total -and $out.AmostrasLidas + $out.AmostrasFalhas -lt $n; $i += $passo) {
        $alvo = $comInf[$i]
        try {
            $fs = [System.IO.File]::OpenRead($alvo.InfCaminho)
            try {
                $buf = New-Object byte[] 64
                $lidos = $fs.Read($buf, 0, 64)
                if ($lidos -gt 0) { $out.AmostrasLidas++ } else { $out.AmostrasFalhas++ }
            } finally { $fs.Dispose() }
        } catch {
            $out.AmostrasFalhas++
            Write-Log WARN ('Nao foi possivel ler o pacote {0} do backup.' -f $alvo.Pasta) -ErrorRecord $_
        }
    }
    $out.Legivel = ($out.AmostrasLidas -gt 0 -and $out.AmostrasFalhas -eq 0)

    # Coerencia com o manifesto, quando existir.
    $man = Import-DriverManifesto -Raiz $Destino
    $out.ManifestoDetalhe = $man.Detalhe
    if ($man.Ok) {
        $out.ManifestoOk = $true
        $out.ManifestoPacotes = @($man.Manifesto.Pacotes).Count
        $out.DivergenciaManifesto = [math]::Abs($out.ManifestoPacotes - $out.Pacotes)

        if ($ConferirHash) {
            $mapa = @{}
            foreach ($mp in @($man.Manifesto.Pacotes)) {
                if ($mp.HashInf) { $mapa["$($mp.Pasta)".ToLowerInvariant()] = "$($mp.HashInf)" }
            }
            foreach ($p in $pacotes) {
                $k = "$($p.Pasta)".ToLowerInvariant()
                if (-not $mapa.ContainsKey($k) -or -not $p.HashInf) { continue }
                $out.HashConferidos++
                if ($mapa[$k] -ne $p.HashInf) {
                    $out.HashDivergentes++
                    Write-Log WARN ('Hash do INF divergente no pacote {0}: o conteudo mudou apos o backup.' -f $p.Pasta)
                }
            }
        }
    }

    $problemas = New-Object System.Collections.ArrayList
    if ($out.ArquivosVazios -gt 0) { [void]$problemas.Add(('{0} arquivo(s) com tamanho zero' -f $out.ArquivosVazios)) }
    if ($out.PacotesSemInf -gt 0)  { [void]$problemas.Add(('{0} pacote(s) sem .inf' -f $out.PacotesSemInf)) }
    if ($out.AmostrasFalhas -gt 0) { [void]$problemas.Add(('{0} amostra(s) ilegivel(is)' -f $out.AmostrasFalhas)) }
    if ($out.HashDivergentes -gt 0){ [void]$problemas.Add(('{0} hash(es) divergente(s) do manifesto' -f $out.HashDivergentes)) }
    if ($out.ManifestoOk -and $out.DivergenciaManifesto -gt 0) {
        [void]$problemas.Add(('manifesto declara {0} pacote(s) e o disco tem {1}' -f $out.ManifestoPacotes, $out.Pacotes))
    }

    # Utilizavel = da para restaurar a partir daqui. Divergencia de contagem e
    # arquivo vazio NAO invalidam tudo: invalidam a completude, e isso e dito.
    $out.Utilizavel = ($out.Pacotes -gt 0 -and $out.Infs -gt 0 -and $out.Bytes -gt 0 -and
                       $out.Legivel -and $out.HashDivergentes -eq 0)
    $out.Detalhe = $(if ($problemas.Count -gt 0) { ($problemas -join '; ') } else { 'Nenhuma inconsistencia detectada.' })
    return $out
}

function Save-DriverValidacao {
    <# Registra o resultado da validacao junto do proprio backup. Best-effort:
       nao poder gravar o registro nao altera o veredito ja apurado. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Raiz, [Parameter(Mandatory)][object]$Resultado)
    try {
        $layout = Get-DriverBackupLayout -Raiz $Raiz
        $dir = $layout.Validation
        if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $payload = $Resultado | Select-Object *
        $payload | Add-Member -NotePropertyName Verificado -NotePropertyValue (Get-Date -Format 's') -Force
        $payload | Add-Member -NotePropertyName Backup     -NotePropertyValue $Raiz -Force
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $dir $script:ValidacaoNome), ($payload | ConvertTo-Json -Depth 6), $enc)
        return $true
    } catch {
        Write-Log DEBUG ('Registro de validacao nao gravado: {0}' -f $_.Exception.Message) -NoConsole
        return $false
    }
}

function Get-DriverBackups {
    <# Backups conhecidos: os do diretorio informado/resolvido mais o ultimo
       registrado no estado persistente. Ordenados do mais recente para o mais
       antigo pela data de escrita real, nao pelo nome. #>
    [CmdletBinding()] param([string]$Base = '')
    $raizes = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($Base)) { [void]$raizes.Add($Base) }

    $estado = Get-DriverEstado
    if (-not [string]::IsNullOrWhiteSpace($estado.UltimoDestino)) { [void]$raizes.Add($estado.UltimoDestino) }
    # Split-Path lanca com cadeia vazia, e o estado vem vazio em toda maquina que
    # ainda nao concluiu um backup - ou seja, no caso mais comum.
    if (-not [string]::IsNullOrWhiteSpace($estado.UltimoBackup)) {
        try {
            $pai = Split-Path -Parent $estado.UltimoBackup
            if (-not [string]::IsNullOrWhiteSpace($pai)) { [void]$raizes.Add($pai) }
        } catch {
            Write-Log DEBUG ("Ultimo backup registrado com caminho invalido: {0}" -f $_.Exception.Message) -NoConsole
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Global:CompartDisk.LogDir)) {
        [void]$raizes.Add((Join-Path (Join-Path $Global:CompartDisk.LogDir 'COMPARTDISK_Drivers') 'Backup'))
    }
    if (-not [string]::IsNullOrWhiteSpace($Global:CompartDisk.OutDir)) {
        [void]$raizes.Add((Join-Path $Global:CompartDisk.OutDir 'Backup_Drivers'))
    }

    $achados = New-Object System.Collections.ArrayList
    $vistos  = @{}
    foreach ($raiz in $raizes) {
        if ([string]::IsNullOrWhiteSpace($raiz)) { continue }
        if (-not (Test-Path -LiteralPath $raiz -PathType Container)) { continue }
        $filhos = @()
        try { $filhos = @(Get-ChildItem -LiteralPath $raiz -Directory -ErrorAction Stop) }
        catch { Write-Log DEBUG ("Listagem de backups falhou em {0}: {1}" -f $raiz, $_.Exception.Message) -NoConsole; continue }

        foreach ($f in $filhos) {
            $chave = "$($f.FullName)".TrimEnd('\').ToLowerInvariant()
            if ($vistos.ContainsKey($chave)) { continue }
            $layout = Get-DriverBackupLayout -Raiz $f.FullName
            if (-not $layout.Ok) { continue }
            # So conta como backup o que tem ao menos uma pasta de pacote dentro.
            $temPacote = $false
            try { $temPacote = (@(Get-ChildItem -LiteralPath $layout.Drivers -Directory -ErrorAction Stop).Count -gt 0) }
            catch { $temPacote = $false }
            if (-not $temPacote) { continue }
            $vistos[$chave] = $true

            $man = Import-DriverManifesto -Raiz $f.FullName
            [void]$achados.Add([pscustomobject]@{
                Nome       = $f.Name
                Caminho    = $f.FullName
                Formato    = $layout.Formato
                Modificado = $f.LastWriteTime
                Manifesto  = $man.Ok
                Pacotes    = $(if ($man.Ok) { @($man.Manifesto.Pacotes).Count } else { 'n/d' })
                Estado     = $(if ($man.Ok) { (Get-DriverSafeText $man.Manifesto.Estado) } else { 'n/d' })
            })
        }
    }
    return @($achados | Sort-Object -Property Modificado -Descending)
}

# ==============================================================================
# ACAO: BACKUP
# Exporta copia dos pacotes do repositorio de drivers via pnputil. Nao instala,
# nao remove e nao altera nada no sistema. Backups anteriores nunca sao
# sobrescritos: cada execucao cria o proprio subdiretorio com carimbo.
# ==============================================================================
function Backup-Drivers {
    [CmdletBinding()] param([string]$Destino)
    Set-DriverFase 'EmPreparacao'

    # ---------------------------------------------------------- pre-condicoes
    if (-not (Test-Path -LiteralPath $pnputil)) {
        Write-Log ERR 'pnputil.exe nao localizado neste sistema: exportacao nao suportada.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message 'pnputil.exe nao localizado: o backup de drivers nao pode ser executado.' `
            -Recommendation 'Componente nativo ausente: avaliar integridade do Windows com DISM /RestoreHealth e SFC /scannow.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'pnputil.exe indisponivel'
        Set-DriverResult 'ERROR' 'pnputil ausente'
        Set-DriverFase 'Falhou'
        return $null
    }

    # ------------------------------------------------------------- capacidade
    # A estimativa e medida ANTES da escolha do destino: ela alimenta o criterio
    # de espaco minimo de cada candidato.
    Write-Log INFO 'Estimando o volume a exportar (leitura do repositorio de drivers)...'
    $estimativa = Get-DriverStoreEstimate
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

    $base = Resolve-DriverBackupBase -Path $Destino -MinimoBytes $necessario
    if (-not $base.Ok -and [string]::IsNullOrWhiteSpace("$Destino")) {
        # Nenhum candidato atendeu ao minimo estimado. A estimativa e um limite
        # superior deliberadamente pessimista: repete-se a selecao sem o filtro
        # de espaco para nao descartar um destino que na pratica caberia, e o
        # aviso de espaco fica a cargo da verificacao logo abaixo.
        Write-Log WARN 'Nenhum destino atende ao espaco estimado; reavaliando sem o filtro de espaco.'
        $base = Resolve-DriverBackupBase -Path $Destino
    }
    Add-DriverDestinoSection -Base $base
    if (-not $base.Ok) {
        Write-Log ERR ('Destino de backup invalido: {0}' -f $base.Detalhe)
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Destino de backup invalido: {0}' -f $base.Detalhe) `
            -Recommendation 'Informar um caminho valido em -Path ou liberar espaco e permissao de escrita em um dos destinos avaliados.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Destino invalido'
        Set-DriverResult 'ERROR' 'destino invalido'
        Set-DriverFase 'Falhou'
        return $null
    }
    Write-Log INFO ('Destino do backup: {0} ({1})' -f $base.Base, $base.Origem)
    Write-DriverInfo 'Destino'  $base.Base
    Write-DriverInfo 'Criterio' $base.Origem

    if ($base.Tipo -eq 'Removivel') {
        Write-Log WARN 'O destino esta em midia removivel: manter a unidade conectada ate o fim da exportacao.'
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('Destino em midia removivel: {0}' -f $base.Base) `
            -Recommendation 'Nao desconectar a unidade durante a exportacao; conferir o backup apos a conclusao.'
        Set-DriverResult 'WARN' 'destino em midia removivel'
    }

    # Backups anteriores sao preservados: nada e apagado nem sobrescrito.
    $anteriores = 0
    try { $anteriores = @(Get-ChildItem -LiteralPath $base.Base -Directory -ErrorAction Stop).Count }
    catch { Write-Log WARN ('Nao foi possivel contar os backups anteriores em {0}.' -f $base.Base) -ErrorRecord $_ }
    if ($anteriores -gt 0) {
        Write-Log INFO ("{0} backup(s) anterior(es) preservado(s) em {1}." -f $anteriores, $base.Base)
    }

    $espaco = Get-DriverVolumeInfo -FullPath $base.Base -Unc:$base.Unc
    if ($espaco.Ok) {
        Write-Log INFO ("Espaco livre no destino: {0} (necessario estimado: {1})." -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario))
        Write-DriverInfo 'Espaco livre' (ConvertTo-CompartDiskSize $espaco.Bytes)
        Write-DriverInfo 'Necessario (est.)' (ConvertTo-CompartDiskSize $necessario)
        if ($espaco.Bytes -lt $necessario -and -not $Force) {
            Write-Log ERR ("Espaco livre insuficiente no destino: {0} disponivel para {1} estimados." -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario))
            Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
                -Message ("Backup nao executado: espaco livre insuficiente ({0} disponivel, {1} estimados como necessarios)." -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario)) `
                -Recommendation 'A estimativa e um limite superior (inclui pacotes do proprio Windows, que nao sao exportados). Liberar espaco, informar outro destino em -Path, ou repetir com -Force para exportar assim mesmo assumindo o risco de exportacao parcial.'
            Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Pairs ([ordered]@{
                'Destino'          = $base.Base
                'Espaco livre'     = (ConvertTo-CompartDiskSize $espaco.Bytes)
                'Necessario (est.)'= (ConvertTo-CompartDiskSize $necessario)
                'Base do calculo'  = $baseCalculo
            }) -Summary 'Abortado antes da exportacao por falta de espaco'
            Set-DriverResult 'ERROR' 'espaco insuficiente'
            Set-DriverFase 'Falhou'
            return $null
        }
        if ($espaco.Bytes -lt $necessario) {
            Write-Log WARN 'Espaco abaixo da estimativa; prosseguindo por -Force. A exportacao pode ficar parcial.'
            Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
                -Message ('Exportacao iniciada com espaco abaixo da estimativa ({0} disponivel, {1} estimados), por decisao explicita (-Force).' -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario)) `
                -Recommendation 'Conferir o resultado da validacao antes de considerar o backup completo.'
            Set-DriverResult 'WARN' 'espaco abaixo da estimativa'
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
    $carimbo    = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $destinoRun = Join-Path $base.Base ('Drivers_{0}' -f $carimbo)
    $sufixo = 1
    while (Test-Path -LiteralPath $destinoRun) {
        $destinoRun = Join-Path $base.Base ('Drivers_{0}_{1}' -f $carimbo, $sufixo)
        $sufixo++
        if ($sufixo -gt 50) { break }
    }
    if (Test-Path -LiteralPath $destinoRun) {
        Write-Log ERR 'Nao foi possivel obter um nome de backup livre no destino.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message 'Nao foi possivel criar um diretorio de backup sem colidir com um existente.' `
            -Recommendation 'Informar outro destino em -Path ou remover manualmente os backups antigos apos conferi-los.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Colisao de nome no destino'
        Set-DriverResult 'ERROR' 'colisao de nome'
        Set-DriverFase 'Falhou'
        return $null
    }

    $pastaDrivers = Join-Path $destinoRun 'Drivers'
    try {
        foreach ($d in @($destinoRun, $pastaDrivers,
                         (Join-Path $destinoRun 'Manifest'),
                         (Join-Path $destinoRun 'Metadata'),
                         (Join-Path $destinoRun 'Validation'))) {
            New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Log ERR ('Nao foi possivel criar a estrutura da execucao: {0}' -f $destinoRun) -ErrorRecord $_
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel criar o diretorio de destino desta execucao: {0}' -f $destinoRun) `
            -Recommendation 'Verificar permissoes de escrita no volume de destino.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Destino inacessivel'
        Set-DriverResult 'ERROR' 'destino inacessivel'
        Set-DriverFase 'Falhou'
        return $null
    }
    # "New-Item executou" nao e prova: confirma-se por releitura.
    if (-not (Test-Path -LiteralPath $pastaDrivers -PathType Container)) {
        Write-Log ERR ('O diretorio de destino nao existe apos a criacao: {0}' -f $pastaDrivers)
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' -Message 'O diretorio de backup nao pode ser confirmado apos a criacao.'
        Add-CompartDiskSection -Title 'Backup de drivers' -Status CRIT -Summary 'Destino nao confirmado'
        Set-DriverResult 'ERROR' 'destino nao confirmado'
        Set-DriverFase 'Falhou'
        return $null
    }

    # ------------------------------------------------------- contagem esperada
    $esperado = Get-DriverPublicados -PnpUtil $pnputil
    if ($esperado.Ok) { Write-Log INFO $esperado.Detalhe }
    else { Write-Log WARN ('Contagem esperada indisponivel: {0}' -f $esperado.Detalhe) }

    # ------------------------------------------------------------- exportacao
    Set-DriverFase 'EmExecucao'
    Write-Log INFO ("Exportando os pacotes do repositorio de drivers para: {0}" -f $pastaDrivers)
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $pnputil `
            -Arguments @('/export-driver', '*', (ConvertTo-DriverArgumento $pastaDrivers)) -TimeoutSeconds 1800
    } -Activity 'pnputil /export-driver' -Silent
    $cron.Stop()
    $duracao = [math]::Round($cron.Elapsed.TotalSeconds, 1)

    $exitCode = $null
    $stdErr   = ''
    $timeout  = $false
    if ($r.Success -and $null -ne $r.Value) {
        $exitCode = [int]$r.Value.ExitCode
        $stdErr   = "$($r.Value.StdErr)".Trim()
    } else {
        $msg = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        $timeout = ($msg -match 'Tempo limite excedido')
        $stdErr = $msg
        if ($timeout) { Write-Log ERR ('A exportacao excedeu o tempo limite de 1800s e foi interrompida: {0}' -f $msg) }
        else          { Write-Log ERR ('A exportacao nao pode ser executada: {0}' -f $msg) }
    }
    if ($stdErr) { Write-Log WARN ('pnputil (stderr): {0}' -f ($stdErr -split "`r?`n" | Select-Object -First 3 | Out-String).Trim()) }

    # -------------------------------------------------------------- manifesto
    # Gerado a partir do que existe no disco, nao do que o comando prometeu.
    $inv = $null
    if ($script:InventarioCache) { $inv = $script:InventarioCache }
    $manifesto = New-DriverManifesto -Destino $destinoRun -Metodo 'pnputil /export-driver *' -Inventario $inv
    $manifesto.Totais.PacotesPublicados = $(if ($esperado.Ok) { $esperado.Total } else { 0 })

    $pacotes = Get-DriverPacotesDoDisco -Diretorio $pastaDrivers -ComHash
    foreach ($p in $pacotes) {
        if ($p.Infs -eq 0) { $manifesto.Totais.PacotesComProblema++ }
        $manifesto.Totais.Arquivos += $p.Arquivos
        $manifesto.Totais.Bytes    += $p.Bytes
        [void]$manifesto.Pacotes.Add([pscustomobject]@{
            Pasta        = $p.Pasta
            Inf          = $p.Inf
            Provedor     = $p.Provedor
            Versao       = $p.Versao
            Data         = $p.Data
            Classe       = $p.Classe
            Catalogo     = $p.Catalogo
            Arquivos     = $p.Arquivos
            Bytes        = $p.Bytes
            HashInf      = $p.HashInf
            HashCatalogo = $p.HashCatalogo
        })
    }
    $manifesto.Totais.PacotesExportados = @($pacotes).Count

    # Execucao que nao produziu nada nao deixa estrutura vazia acumulando no
    # destino. A remocao so acontece se NENHUM arquivo existir em qualquer nivel
    # abaixo do diretorio desta execucao, e o alvo e sempre o diretorio criado
    # agora - nunca a base, nunca um backup anterior. Na duvida, mantem-se.
    if (@($pacotes).Count -eq 0) {
        try {
            $arquivos = @(Get-ChildItem -LiteralPath $destinoRun -File -Recurse -Force -ErrorAction Stop)
            if ($arquivos.Count -eq 0 -and
                $destinoRun -ne $base.Base -and
                (Split-Path -Parent $destinoRun) -eq $base.Base) {
                Remove-Item -LiteralPath $destinoRun -Recurse -Force -ErrorAction Stop
                Write-Log INFO 'Estrutura desta execucao removida por nao conter nenhum arquivo; backups anteriores preservados.'
            } else {
                Write-Log INFO 'Estrutura desta execucao mantida para diagnostico.'
            }
        } catch {
            Write-Log WARN 'Estrutura vazia desta execucao mantida no destino.' -ErrorRecord $_
        }
    }

    # -------------------------------------------------------------- validacao
    $integridade = Test-DriverBackupIntegrity -Destino $destinoRun

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

    $exportouAlgo = $integridade.Utilizavel
    $codigoOk     = ($null -ne $exitCode -and $exitCode -eq 0)

    $nivel = 'ERROR'
    $situacao = 'falhou'
    if ($codigoOk -and $exportouAlgo -and -not $parcial) {
        $nivel = 'OK'
        $situacao = $(if ($esperado.Ok) { 'confirmado' } else { 'confirmado, completude nao comparavel' })
    }
    elseif ($exportouAlgo)                              { $nivel = 'WARN';  $situacao = 'parcial' }
    elseif ($codigoOk)                                  { $nivel = 'WARN';  $situacao = 'inconclusivo' }

    $manifesto.Estado = switch ($nivel) {
        'OK'   { 'Concluido' }
        'WARN' { 'ConcluidoComAvisos' }
        default { 'Falhou' }
    }
    if ($timeout) { [void]$manifesto.Observacoes.Add('Exportacao interrompida por tempo limite de 1800s.') }
    if ($stdErr)  { [void]$manifesto.Observacoes.Add(('pnputil (stderr): {0}' -f ($stdErr -split "`r?`n" | Select-Object -First 1))) }
    if ($integridade.Detalhe) { [void]$manifesto.Observacoes.Add($integridade.Detalhe) }

    $manifestoOk = $false
    if (@($pacotes).Count -gt 0) {
        $sm = Save-DriverManifesto -Manifesto $manifesto -Diretorio (Join-Path $destinoRun 'Manifest')
        $manifestoOk = $sm.Ok
        if (-not $manifestoOk) {
            Write-Log WARN 'Os pacotes foram exportados, porem o manifesto nao pode ser gravado: o backup fica sem trilha de auditoria.'
            Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
                -Message 'Backup gravado sem manifesto: a auditoria e a validacao por hash ficam indisponiveis para este backup.' `
                -Recommendation 'Conferir permissao de escrita no destino e repetir o backup para obter um manifesto integro.'
            Set-DriverResult 'WARN' 'manifesto nao gravado'
        }
        # Retrato do inventario junto do backup: o que o Restore precisa saber
        # sobre a maquina de origem sem depender do WMI de destino.
        if ($inv -and $inv.Ok) {
            try {
                $enc = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText(
                    (Join-Path (Join-Path $destinoRun 'Metadata') 'Inventario.json'),
                    (@($inv.Rows) | ConvertTo-Json -Depth 6), $enc)
            } catch { Write-Log DEBUG ("Retrato do inventario nao gravado: {0}" -f $_.Exception.Message) -NoConsole }
        }
        [void](Save-DriverValidacao -Raiz $destinoRun -Resultado $integridade)
        [void](Save-DriverEstado -UltimoDestino $base.Base -UltimoBackup $destinoRun)
    }

    $pares = [ordered]@{
        'Destino'                  = $destinoRun
        'Criterio do destino'      = $base.Origem
        'Backups anteriores'       = $anteriores
        'Codigo de retorno'        = $(if ($null -ne $exitCode) { $exitCode } else { 'n/d (processo nao concluiu)' })
        'Pacotes exportados'       = $integridade.Pacotes
        'Arquivos .inf'            = $integridade.Infs
        'Arquivos totais'          = $integridade.Arquivos
        'Arquivos vazios'          = $integridade.ArquivosVazios
        'Tamanho'                  = (ConvertTo-CompartDiskSize $integridade.Bytes)
        'Pacotes publicados (est.)'= $(if ($esperado.Ok) { $esperado.Total } else { 'n/d' })
        'Comparacao'               = $comparacao
        'Leitura verificada'       = $(if ($integridade.Legivel) { ('Sim ({0} amostra(s))' -f $integridade.AmostrasLidas) } else { 'Nao' })
        'Manifesto'                = $(if ($manifestoOk) { 'gravado e conferido' } else { 'nao gravado' })
        'Espaco livre'             = $(if ($espaco.Ok) { (ConvertTo-CompartDiskSize $espaco.Bytes) } else { 'nao determinado' })
        'Base do calculo'          = $baseCalculo
        'Duracao'                  = ('{0} s' -f $duracao)
        'Situacao'                 = $situacao
        'Estado da operacao'       = $manifesto.Estado
    }
    if ($integridade.Detalhe) { $pares['Observacao'] = $integridade.Detalhe }
    if ($timeout)             { $pares['Interrupcao'] = 'Tempo limite de 1800s excedido' }

    Add-CompartDiskSection -Title 'Backup de drivers' -Status (Get-DriverSectionStatus $nivel) -Pairs $pares `
        -Summary ("{0}: {1} pacote(s), {2}" -f $situacao, $integridade.Pacotes, (ConvertTo-CompartDiskSize $integridade.Bytes))

    switch ($nivel) {
        'OK' {
            Set-DriverFase 'Concluido'
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
            Set-DriverFase 'ConcluidoComAvisos'
            $motivo = $(if ($parcial) { ('exportacao parcial ({0})' -f $comparacao) } elseif (-not $exportouAlgo) { 'nenhum pacote pode ser confirmado no destino' } else { 'validacao incompleta' })
            Write-Log WARN ("Backup {0}: {1}. Pacotes confirmados: {2} ({3})." -f $situacao, $motivo, $integridade.Pacotes, (ConvertTo-CompartDiskSize $integridade.Bytes))
            Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
                -Message ("Backup {0}: {1}. {2} pacote(s) confirmado(s) em {3}." -f $situacao, $motivo, $integridade.Pacotes, $destinoRun) `
                -Recommendation 'O que ja foi exportado esta preservado e pode ser usado. Conferir o conteudo do destino, liberar espaco ou fechar processos que bloqueiem o repositorio e reexecutar apenas o backup.'
            Set-DriverResult 'WARN' 'backup parcial ou inconclusivo'
        }
        default {
            Set-DriverFase 'Falhou'
            Write-Log ERR ("Backup nao concluido. Codigo: {0}. Pacotes no destino: {1}." -f $(if ($null -ne $exitCode) { $exitCode } else { 'n/d' }), $integridade.Pacotes)
            Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
                -Message ("Backup de drivers nao concluido{0}. Nenhum pacote pode ser validado no destino." -f $(if ($timeout) { ' (tempo limite excedido)' } else { '' })) `
                -Recommendation 'Verificar privilegios administrativos, espaco em disco, antivirus e integridade do repositorio de drivers; reexecutar em seguida.'
            Set-DriverResult 'ERROR' 'backup nao concluido'
        }
    }

    return [pscustomobject]@{
        Ok = ($nivel -eq 'OK'); Nivel = $nivel; Destino = $destinoRun
        Integridade = $integridade; Manifesto = $manifesto
    }
}

# ==============================================================================
# SELECAO DA ORIGEM (Validate, Restore, Package)
# -Path pode apontar tanto para um backup especifico quanto para o diretorio que
# contem varios. Sem -Path, usa-se o mais recente conhecido.
# ==============================================================================
function Resolve-DriverBackupOrigem {
    [CmdletBinding()] param([string]$Path = '')
    $out = [pscustomobject]@{ Ok = $false; Raiz = ''; Origem = ''; Detalhe = ''; Candidatos = @() }

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $norm = Resolve-DriverPath -Caminho $Path
        if (-not $norm.Ok) { $out.Detalhe = $norm.Detalhe; return $out }
        if (-not (Test-Path -LiteralPath $norm.Completo -PathType Container)) {
            $out.Detalhe = ('O caminho informado nao existe ou nao e um diretorio: {0}' -f $norm.Completo)
            return $out
        }
        # Backup direto?
        $layout = Get-DriverBackupLayout -Raiz $norm.Completo
        $temPacote = $false
        try { $temPacote = (@(Get-ChildItem -LiteralPath $layout.Drivers -Directory -ErrorAction Stop | Where-Object { $_.Name -notin @('Manifest', 'Metadata', 'Validation') }).Count -gt 0) }
        catch { $temPacote = $false }
        if ($temPacote -and $layout.Formato -eq 'estruturado') {
            $out.Ok = $true; $out.Raiz = $norm.Completo; $out.Origem = 'Backup informado em -Path'
            $out.Detalhe = 'Backup no formato estruturado.'
            return $out
        }
        # Diretorio que contem backups?
        $lista = Get-DriverBackups -Base $norm.Completo
        if (@($lista).Count -gt 0) {
            $out.Ok = $true; $out.Raiz = $lista[0].Caminho; $out.Candidatos = @($lista)
            $out.Origem = 'Backup mais recente dentro do diretorio informado em -Path'
            $out.Detalhe = ('{0} backup(s) encontrado(s); selecionado o mais recente.' -f @($lista).Count)
            return $out
        }
        if ($temPacote) {
            $out.Ok = $true; $out.Raiz = $norm.Completo; $out.Origem = 'Backup informado em -Path'
            $out.Detalhe = 'Backup no formato anterior (pacotes na raiz).'
            return $out
        }
        $out.Detalhe = ('Nenhum backup de drivers encontrado em: {0}' -f $norm.Completo)
        return $out
    }

    $lista = Get-DriverBackups
    if (@($lista).Count -eq 0) {
        $out.Detalhe = 'Nenhum backup de drivers conhecido. Executar a acao Backup antes, ou informar o caminho em -Path.'
        return $out
    }
    $out.Ok = $true; $out.Raiz = $lista[0].Caminho; $out.Candidatos = @($lista)
    $out.Origem = 'Backup mais recente conhecido'
    $out.Detalhe = ('{0} backup(s) conhecido(s); selecionado o mais recente.' -f @($lista).Count)
    return $out
}

# ==============================================================================
# ACAO: VALIDATE  (somente leitura)
# ==============================================================================
function Invoke-DriverValidate {
    [CmdletBinding()] param([string]$Origem)
    Set-DriverFase 'EmExecucao'
    Write-Log INFO 'Validando backup de drivers...'

    $sel = Resolve-DriverBackupOrigem -Path $Origem
    if (-not $sel.Ok) {
        Write-Log ERR ('Validacao nao executada: {0}' -f $sel.Detalhe)
        Add-CompartDiskSection -Title 'Validacao do backup de drivers' -Status CRIT -Summary 'Backup nao localizado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel localizar um backup para validar: {0}' -f $sel.Detalhe) `
            -Recommendation 'Executar a acao Backup ou informar o diretorio do backup em -Path.'
        Set-DriverResult 'ERROR' 'backup nao localizado'
        Set-DriverFase 'Falhou'
        return $null
    }

    Write-Log INFO ('Backup selecionado: {0} ({1})' -f $sel.Raiz, $sel.Origem)
    Write-DriverInfo 'Backup' $sel.Raiz

    $v = Test-DriverBackupIntegrity -Destino $sel.Raiz -ConferirHash
    [void](Save-DriverValidacao -Raiz $sel.Raiz -Resultado $v)

    $pares = [ordered]@{
        'Backup'               = $sel.Raiz
        'Criterio de selecao'  = $sel.Origem
        'Formato'              = $v.Formato
        'Pacotes'              = $v.Pacotes
        'Arquivos .inf'        = $v.Infs
        'Arquivos totais'      = $v.Arquivos
        'Arquivos vazios'      = $v.ArquivosVazios
        'Pacotes sem .inf'     = $v.PacotesSemInf
        'Tamanho'              = (ConvertTo-CompartDiskSize $v.Bytes)
        'Amostras lidas'       = ('{0} ok / {1} falha(s)' -f $v.AmostrasLidas, $v.AmostrasFalhas)
        'Manifesto'            = $(if ($v.ManifestoOk) { ('presente ({0} pacote(s) declarado(s))' -f $v.ManifestoPacotes) } else { 'ausente' })
        'Hashes conferidos'    = ('{0} conferido(s), {1} divergente(s)' -f $v.HashConferidos, $v.HashDivergentes)
        'Utilizavel para restaurar' = $(if ($v.Utilizavel) { 'Sim' } else { 'Nao' })
        'Observacao'           = $v.Detalhe
    }

    $status = 'OK'
    if (-not $v.Utilizavel) { $status = 'CRIT' }
    elseif ($v.ArquivosVazios -gt 0 -or $v.PacotesSemInf -gt 0 -or -not $v.ManifestoOk -or $v.DivergenciaManifesto -gt 0) { $status = 'WARN' }

    Add-CompartDiskSection -Title 'Validacao do backup de drivers' -Status $status -Pairs $pares `
        -Summary ("{0} pacote(s), {1}; {2}" -f $v.Pacotes, (ConvertTo-CompartDiskSize $v.Bytes), $(if ($v.Utilizavel) { 'utilizavel' } else { 'NAO utilizavel' }))

    if (-not $v.Utilizavel) {
        Set-DriverFase 'Falhou'
        Write-Log ERR ('Backup NAO utilizavel para restauracao: {0}' -f $v.Detalhe)
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('O backup em {0} nao passou na validacao e nao deve ser considerado utilizavel: {1}' -f $sel.Raiz, $v.Detalhe) `
            -Recommendation 'Refazer o backup a partir da maquina de origem. Nao apagar este diretorio antes de confirmar que existe outra copia integra.'
        Set-DriverResult 'ERROR' 'backup nao utilizavel'
        return $v
    }

    if ($status -eq 'WARN') {
        Set-DriverFase 'ConcluidoComAvisos'
        Write-Log WARN ('Backup utilizavel com ressalvas: {0}' -f $v.Detalhe)
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('Backup utilizavel, porem com ressalvas: {0}' -f $v.Detalhe) `
            -Recommendation 'A restauracao e possivel, mas a completude nao esta comprovada. Refazer o backup quando a maquina de origem ainda estiver disponivel.'
        Set-DriverResult 'WARN' 'backup validado com ressalvas'
        return $v
    }

    Set-DriverFase 'Concluido'
    Write-Log OK ('Backup validado: {0} pacote(s), {1}, leitura e hashes conferidos.' -f $v.Pacotes, (ConvertTo-CompartDiskSize $v.Bytes))
    Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
        -Message ('Backup validado e utilizavel: {0} pacote(s) em {1}.' -f $v.Pacotes, $sel.Raiz)
    return $v
}

# ==============================================================================
# ACAO: LAST  (somente leitura)
# Responde a pergunta operacional "onde esta o meu backup e ele presta?".
# ==============================================================================
function Show-DriverUltimoBackup {
    [CmdletBinding()] param([string]$Origem)
    Write-Log INFO 'Consultando backups de drivers conhecidos...'

    $base = ''
    if (-not [string]::IsNullOrWhiteSpace($Origem)) {
        $norm = Resolve-DriverPath -Caminho $Origem
        if ($norm.Ok) { $base = $norm.Completo }
    }
    $lista = Get-DriverBackups -Base $base
    $estado = Get-DriverEstado

    if (@($lista).Count -eq 0) {
        Write-Log WARN 'Nenhum backup de drivers localizado.'
        Add-CompartDiskSection -Title 'Backups de drivers' -Status WARN `
            -Pairs ([ordered]@{
                'Backups localizados' = 0
                'Ultimo destino registrado' = $(if ($estado.UltimoDestino) { $estado.UltimoDestino } else { 'nenhum' })
            }) -Summary 'Nenhum backup localizado'
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message 'Nenhum backup de drivers foi localizado nos diretorios conhecidos.' `
            -Recommendation 'Executar a acao Backup antes de reinstalar o Windows, ou informar em -Path o diretorio onde os backups foram gravados.'
        Set-DriverResult 'WARN' 'nenhum backup localizado'
        return
    }

    Write-DriverTable -Rows $lista -Property @('Nome', 'Modificado', 'Pacotes', 'Estado', 'Formato', 'Caminho')

    $mais = $lista[0]
    $v = Test-DriverBackupIntegrity -Destino $mais.Caminho
    $pares = [ordered]@{
        'Backups localizados'   = @($lista).Count
        'Mais recente'          = $mais.Caminho
        'Data'                  = $mais.Modificado
        'Formato'               = $mais.Formato
        'Manifesto'             = $(if ($mais.Manifesto) { 'presente' } else { 'ausente' })
        'Pacotes no disco'      = $v.Pacotes
        'Tamanho'               = (ConvertTo-CompartDiskSize $v.Bytes)
        'Utilizavel'            = $(if ($v.Utilizavel) { 'Sim' } else { 'Nao' })
        'Ultimo destino usado'  = $(if ($estado.UltimoDestino) { $estado.UltimoDestino } else { 'nao registrado' })
    }
    $status = $(if ($v.Utilizavel) { 'OK' } else { 'WARN' })
    Add-CompartDiskSection -Title 'Backups de drivers' -Status $status -Rows $lista -Pairs $pares `
        -Summary ("{0} backup(s); mais recente com {1} pacote(s)" -f @($lista).Count, $v.Pacotes)

    if ($v.Utilizavel) {
        Write-Log OK ('Backup mais recente: {0} ({1} pacote(s), {2}).' -f $mais.Caminho, $v.Pacotes, (ConvertTo-CompartDiskSize $v.Bytes))
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
            -Message ('Backup mais recente localizado e utilizavel: {0}' -f $mais.Caminho)
    } else {
        Write-Log WARN ('O backup mais recente nao passou na validacao rapida: {0}' -f $v.Detalhe)
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('O backup mais recente ({0}) nao passou na validacao rapida: {1}' -f $mais.Caminho, $v.Detalhe) `
            -Recommendation 'Executar a acao Validate para o diagnostico completo antes de depender deste backup.'
        Set-DriverResult 'WARN' 'backup mais recente com ressalvas'
    }
}

# ==============================================================================
# ACAO: RESTORE
#
# Adiciona ao repositorio de drivers do Windows pacotes previamente exportados
# pela propria ferramenta. Regras que nao se negociam:
#
#  - SIMULACAO E O PADRAO. Sem -Force nada e instalado; a acao lista exatamente
#    o que faria. -DryRun forca simulacao mesmo com -Force.
#  - Nunca remove, desinstala ou substitui um driver funcional. Nao existe
#    /delete-driver neste modulo.
#  - Nunca usa /force nem desabilita verificacao de assinatura.
#  - Nunca executa .exe, .msi ou qualquer outro arquivo encontrado no backup:
#    apenas .inf, e apenas por pnputil.
#  - So opera sobre backup que passou na validacao.
#  - Pacote ja publicado e ignorado (idempotencia): reexecutar a restauracao
#    nao duplica pacotes no repositorio.
#
# Vocabulario de resultado por pacote (sem sobreposicao):
#   Simulado | Restaurado | RestauradoPendenteReinicio | JaPresente
#   SemDispositivoCorrespondente | NaoAplicavel | Falhou
# ==============================================================================
function Select-DriverRestoreCandidatos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Pacotes,
        [string]$FiltroInf = '',
        [string]$FiltroProvedor = '',
        [string]$FiltroClasse = '',
        [switch]$SomenteAusentes
    )
    $saida = New-Object System.Collections.ArrayList
    $descartados = New-Object System.Collections.ArrayList

    # IDs de hardware dos dispositivos que hoje reportam driver ausente/invalido.
    $idsProblema = @()
    if ($SomenteAusentes) {
        $pres = Get-DriverPresenca
        if (-not $pres.Ok) {
            Write-Log WARN 'Nao foi possivel enumerar os dispositivos: o filtro -OnlyMissing nao pode ser aplicado com seguranca.'
            return [pscustomobject]@{ Ok = $false; Selecionados = @(); Descartados = @(); Detalhe = 'presenca de dispositivos indisponivel' }
        }
        $tmp = New-Object System.Collections.ArrayList
        foreach ($e in $pres.Mapa.Values) {
            $codigo = -1
            try { $codigo = [int]$e.ConfigManagerErrorCode } catch { $codigo = -1 }
            if ($script:CodigoDriverAusente -notcontains $codigo) { continue }
            foreach ($h in @($e.HardwareID)) {
                if (-not [string]::IsNullOrWhiteSpace("$h")) { [void]$tmp.Add("$h".ToUpperInvariant()) }
            }
        }
        $idsProblema = @($tmp | Sort-Object -Unique)
        Write-Log INFO ('{0} identificador(es) de hardware em dispositivos com driver ausente ou invalido.' -f $idsProblema.Count)
    }

    foreach ($p in $Pacotes) {
        $motivo = ''
        if ($p.Infs -eq 0 -or [string]::IsNullOrWhiteSpace($p.InfCaminho)) {
            $motivo = 'pacote sem .inf'
        }
        elseif ($FiltroInf -and -not (("$($p.Inf)" -like $FiltroInf) -or ("$($p.Pasta)" -like $FiltroInf))) {
            $motivo = 'nao casa com -InfName'
        }
        elseif ($FiltroProvedor -and -not ("$($p.Provedor)" -like $FiltroProvedor)) {
            $motivo = 'nao casa com -Provider'
        }
        elseif ($FiltroClasse -and -not ("$($p.Classe)" -like $FiltroClasse)) {
            $motivo = 'nao casa com -DeviceClass'
        }
        elseif ($SomenteAusentes) {
            $idsInf = Get-DriverInfHardwareIds -Caminho $p.InfCaminho
            if (@($idsInf).Count -eq 0) {
                # Falha fechada: sem IDs extraidos nao se supoe compatibilidade.
                $motivo = 'IDs de hardware nao extraiveis do INF (nao avaliado por -OnlyMissing)'
            } else {
                $casou = $false
                foreach ($idInf in $idsInf) {
                    foreach ($idDisp in $idsProblema) {
                        if ($idDisp.StartsWith($idInf, [System.StringComparison]::OrdinalIgnoreCase)) { $casou = $true; break }
                    }
                    if ($casou) { break }
                }
                if (-not $casou) { $motivo = 'nenhum dispositivo com driver ausente corresponde a este pacote' }
            }
        }

        if ($motivo) {
            [void]$descartados.Add([pscustomobject]@{ Pasta = $p.Pasta; Inf = $p.Inf; Provedor = $p.Provedor; Motivo = $motivo })
        } else {
            [void]$saida.Add($p)
        }
    }
    return [pscustomobject]@{
        Ok = $true; Selecionados = @($saida); Descartados = @($descartados); Detalhe = ''
    }
}

function Restore-Drivers {
    [CmdletBinding()]
    param(
        [string]$Origem,
        [string]$FiltroInf = '',
        [string]$FiltroProvedor = '',
        [string]$FiltroClasse = '',
        [switch]$SomenteAusentes,
        [switch]$Aplicar
    )
    Set-DriverFase 'EmPreparacao'
    $simular = -not $Aplicar

    if (-not (Test-Path -LiteralPath $pnputil)) {
        Write-Log ERR 'pnputil.exe nao localizado: restauracao nao suportada neste sistema.'
        Add-CompartDiskSection -Title 'Restauracao de drivers' -Status CRIT -Summary 'pnputil.exe indisponivel'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message 'pnputil.exe nao localizado: a restauracao de drivers nao pode ser executada.' `
            -Recommendation 'Componente nativo ausente: avaliar integridade do Windows com DISM /RestoreHealth e SFC /scannow.'
        Set-DriverResult 'ERROR' 'pnputil ausente'
        Set-DriverFase 'Falhou'
        return
    }

    # ------------------------------------------------------- origem e validacao
    $sel = Resolve-DriverBackupOrigem -Path $Origem
    if (-not $sel.Ok) {
        Write-Log ERR ('Restauracao nao executada: {0}' -f $sel.Detalhe)
        Add-CompartDiskSection -Title 'Restauracao de drivers' -Status CRIT -Summary 'Backup nao localizado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel localizar um backup para restaurar: {0}' -f $sel.Detalhe) `
            -Recommendation 'Informar o diretorio do backup em -Path.'
        Set-DriverResult 'ERROR' 'backup nao localizado'
        Set-DriverFase 'Falhou'
        return
    }
    Write-Log INFO ('Backup selecionado: {0} ({1})' -f $sel.Raiz, $sel.Origem)

    $v = Test-DriverBackupIntegrity -Destino $sel.Raiz -ConferirHash
    if (-not $v.Utilizavel) {
        Write-Log ERR ('Backup reprovado na validacao: {0}' -f $v.Detalhe)
        Add-CompartDiskSection -Title 'Restauracao de drivers' -Status CRIT `
            -Pairs ([ordered]@{ 'Backup' = $sel.Raiz; 'Motivo' = $v.Detalhe }) `
            -Summary 'Backup reprovado na validacao; nada foi alterado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Restauracao recusada: o backup em {0} nao passou na validacao ({1}).' -f $sel.Raiz, $v.Detalhe) `
            -Recommendation 'Nenhuma alteracao foi feita no sistema. Validar ou refazer o backup antes de tentar restaurar.'
        Set-DriverResult 'ERROR' 'backup reprovado na validacao'
        Set-DriverFase 'Falhou'
        return
    }
    if ($v.HashDivergentes -gt 0) {
        Write-Log ERR 'Hashes divergentes do manifesto: o conteudo do backup mudou apos a criacao.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Restauracao recusada: {0} pacote(s) com hash divergente do manifesto em {1}.' -f $v.HashDivergentes, $sel.Raiz) `
            -Recommendation 'O conteudo foi alterado apos o backup. Nenhuma alteracao foi feita. Usar outra copia integra.'
        Add-CompartDiskSection -Title 'Restauracao de drivers' -Status CRIT -Summary 'Integridade do backup comprometida'
        Set-DriverResult 'ERROR' 'integridade do backup comprometida'
        Set-DriverFase 'Falhou'
        return
    }

    # ---------------------------------------------------------------- selecao
    $layout  = Get-DriverBackupLayout -Raiz $sel.Raiz
    $pacotes = Get-DriverPacotesDoDisco -Diretorio $layout.Drivers
    $filtro  = Select-DriverRestoreCandidatos -Pacotes $pacotes -FiltroInf $FiltroInf `
                   -FiltroProvedor $FiltroProvedor -FiltroClasse $FiltroClasse -SomenteAusentes:$SomenteAusentes
    if (-not $filtro.Ok) {
        Add-CompartDiskSection -Title 'Restauracao de drivers' -Status CRIT -Summary 'Selecao nao pode ser calculada'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('A selecao de pacotes nao pode ser calculada: {0}. Nada foi alterado.' -f $filtro.Detalhe) `
            -Recommendation 'Validar o repositorio WMI e repetir; ou restaurar sem -OnlyMissing e escolher os pacotes por -InfName.'
        Set-DriverResult 'ERROR' 'selecao nao calculavel'
        Set-DriverFase 'Falhou'
        return
    }
    $alvos = @($filtro.Selecionados)

    if ($alvos.Count -eq 0) {
        Write-Log WARN 'Nenhum pacote do backup atende aos criterios informados.'
        Add-CompartDiskSection -Title 'Restauracao de drivers' -Status WARN -Rows @($filtro.Descartados) `
            -Pairs ([ordered]@{
                'Backup'            = $sel.Raiz
                'Pacotes no backup' = @($pacotes).Count
                'Selecionados'      = 0
                'Modo'              = $(if ($simular) { 'Simulacao' } else { 'Aplicacao' })
            }) -Summary 'Nenhum pacote selecionado; nada foi alterado'
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message 'Nenhum pacote do backup atende aos filtros informados: nada foi alterado no sistema.' `
            -Recommendation 'Rever os filtros -InfName, -Provider, -DeviceClass e -OnlyMissing, ou restaurar sem filtros.'
        Set-DriverResult 'WARN' 'nenhum pacote selecionado'
        Set-DriverFase 'Concluido'
        return
    }

    # Estado ANTES: base de comparacao para a verificacao pos-restauracao.
    $antes = Get-DriverPublicados -PnpUtil $pnputil
    $publicadosAntes = @{}
    if ($antes.Ok) { foreach ($o in $antes.Originais) { $publicadosAntes[$o] = $true } }
    $problemasAntes = Get-DriverProblems

    Write-Log INFO ('{0} pacote(s) selecionado(s) de {1} no backup. Modo: {2}.' -f `
        $alvos.Count, @($pacotes).Count, $(if ($simular) { 'SIMULACAO (nada sera alterado)' } else { 'APLICACAO' }))
    if ($simular) {
        Write-Log WARN 'Modo simulacao: nenhum driver sera instalado. Repetir com -Force para aplicar.'
    } else {
        Write-Log WARN ('Os {0} pacote(s) abaixo serao ADICIONADOS ao repositorio de drivers do Windows. Nenhum driver existente sera removido.' -f $alvos.Count)
    }
    Write-DriverTable -Rows $alvos -First 40 -Property @('Pasta', 'Inf', 'Provedor', 'Versao', 'Data', 'Classe')

    # ------------------------------------------------------------- execucao
    Set-DriverFase 'EmExecucao'
    $resultados = New-Object System.Collections.ArrayList
    $reinicio   = $false
    $cron = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($p in $alvos) {
        $nomeOriginal = "$($p.Inf)".ToLowerInvariant()
        if (-not $simular -and $antes.Ok -and $publicadosAntes.ContainsKey($nomeOriginal)) {
            [void]$resultados.Add([pscustomobject]@{
                Pasta = $p.Pasta; Inf = $p.Inf; Provedor = $p.Provedor; Versao = $p.Versao
                Resultado = 'JaPresente'; Codigo = 'n/d'
                Detalhe = 'Pacote com este nome de INF ja consta no repositorio de drivers; nao reinstalado.'
            })
            continue
        }
        if ($simular) {
            [void]$resultados.Add([pscustomobject]@{
                Pasta = $p.Pasta; Inf = $p.Inf; Provedor = $p.Provedor; Versao = $p.Versao
                Resultado = 'Simulado'; Codigo = 'n/d'
                Detalhe = 'Seria adicionado ao repositorio por pnputil /add-driver /install.'
            })
            continue
        }

        $r = Invoke-SafeCommand {
            Invoke-NativeCommand -FilePath $pnputil `
                -Arguments @('/add-driver', (ConvertTo-DriverArgumento $p.InfCaminho), '/install') -TimeoutSeconds 600
        } -Activity ('pnputil /add-driver {0}' -f $p.Inf) -Silent

        $codigo = $null
        $detalhe = ''
        if ($r.Success -and $null -ne $r.Value) {
            $codigo = [int]$r.Value.ExitCode
            $detalhe = "$($r.Value.StdErr)".Trim()
        } else {
            $detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        }

        # 0 sucesso; 3010 sucesso pendente de reinicio; 259 nenhum dispositivo
        # correspondente (o pacote entra no repositorio, mas nada foi instalado).
        $estadoItem = 'Falhou'
        switch ($codigo) {
            0    { $estadoItem = 'Restaurado' }
            3010 { $estadoItem = 'RestauradoPendenteReinicio'; $reinicio = $true }
            259  { $estadoItem = 'SemDispositivoCorrespondente' }
            default { $estadoItem = 'Falhou' }
        }
        if ($estadoItem -eq 'Falhou') {
            Write-Log WARN ('Pacote {0} ({1}) nao pode ser adicionado. Codigo: {2}. {3}' -f `
                $p.Pasta, $p.Inf, $(if ($null -ne $codigo) { $codigo } else { 'n/d' }), $detalhe)
        }
        [void]$resultados.Add([pscustomobject]@{
            Pasta = $p.Pasta; Inf = $p.Inf; Provedor = $p.Provedor; Versao = $p.Versao
            Resultado = $estadoItem
            Codigo = $(if ($null -ne $codigo) { $codigo } else { 'n/d' })
            Detalhe = $detalhe
        })
    }
    $cron.Stop()
    $duracao = [math]::Round($cron.Elapsed.TotalSeconds, 1)

    # ------------------------------------------------------------ verificacao
    # Codigo de retorno nao e prova: o repositorio e reconsultado e comparado.
    $verificacao = 'nao aplicavel (simulacao)'
    $depois = $null
    if (-not $simular) {
        $depois = Get-DriverPublicados -PnpUtil $pnputil -Refresh
        if ($depois.Ok -and $antes.Ok) {
            $confirmados = 0
            foreach ($res in $resultados) {
                if ($res.Resultado -notin @('Restaurado', 'RestauradoPendenteReinicio', 'SemDispositivoCorrespondente')) { continue }
                if ($depois.Originais -contains "$($res.Inf)".ToLowerInvariant()) { $confirmados++ }
                else {
                    $res.Resultado = 'Falhou'
                    $res.Detalhe = 'O comando retornou sucesso, porem o pacote nao aparece no repositorio apos a reconsulta.'
                    Write-Log WARN ('Pacote {0} nao confirmado no repositorio apos a instalacao.' -f $res.Inf)
                }
            }
            $verificacao = ('{0} pacote(s) confirmado(s) por reconsulta ao repositorio (publicados: {1} antes, {2} depois)' -f `
                $confirmados, $antes.Total, $depois.Total)
        } else {
            $verificacao = 'nao foi possivel reconsultar o repositorio apos a operacao'
            Write-Log WARN 'Nao foi possivel reconsultar o repositorio de drivers apos a restauracao.'
        }
    }

    # Estado dos dispositivos apos a restauracao (retrato novo, sem cache).
    $problemasDepois = $null
    if (-not $simular) {
        $script:ProblemasCache = $null
        $problemasDepois = Get-DriverProblems
    }

    $cont = @{}
    foreach ($e in @('Simulado', 'Restaurado', 'RestauradoPendenteReinicio', 'JaPresente',
                     'SemDispositivoCorrespondente', 'NaoAplicavel', 'Falhou')) {
        $cont[$e] = @($resultados | Where-Object { $_.Resultado -eq $e }).Count
    }
    $falhas = $cont['Falhou']
    $ok     = $cont['Restaurado'] + $cont['RestauradoPendenteReinicio']

    Write-DriverTable -Rows $resultados -First 40 -Property @('Resultado', 'Pasta', 'Inf', 'Provedor', 'Versao', 'Codigo')

    $pares = [ordered]@{
        'Backup de origem'      = $sel.Raiz
        'Modo'                  = $(if ($simular) { 'Simulacao (nada foi alterado)' } else { 'Aplicacao' })
        'Pacotes no backup'     = @($pacotes).Count
        'Selecionados'          = $alvos.Count
        'Descartados por filtro'= @($filtro.Descartados).Count
        'Simulado'              = $cont['Simulado']
        'Restaurado'            = $cont['Restaurado']
        'Pendente de reinicio'  = $cont['RestauradoPendenteReinicio']
        'Ja presente'           = $cont['JaPresente']
        'Sem dispositivo correspondente' = $cont['SemDispositivoCorrespondente']
        'Falhou'                = $falhas
        'Verificacao'           = $verificacao
        'Duracao'               = ('{0} s' -f $duracao)
    }
    if ($problemasDepois) {
        $pares['Dispositivos com erro (antes)']  = $(if ($problemasAntes.Ok) { $problemasAntes.Total } else { 'n/d' })
        $pares['Dispositivos com erro (depois)'] = $(if ($problemasDepois.Ok) { $problemasDepois.Total } else { 'n/d' })
    }

    $status = 'OK'
    if ($falhas -gt 0) { $status = 'WARN' }
    if (-not $simular -and $ok -eq 0 -and $cont['JaPresente'] -eq 0 -and $cont['SemDispositivoCorrespondente'] -eq 0) { $status = 'CRIT' }

    Add-CompartDiskSection -Title 'Restauracao de drivers' -Status $status -Rows @($resultados) -Pairs $pares `
        -Summary ("{0}: {1} de {2} pacote(s)" -f $(if ($simular) { 'simulacao' } else { 'aplicacao' }), $(if ($simular) { $cont['Simulado'] } else { $ok }), $alvos.Count)

    if ($simular) {
        Set-DriverFase 'Concluido'
        Write-Log OK ('Simulacao concluida: {0} pacote(s) seriam adicionados. Nada foi alterado.' -f $cont['Simulado'])
        Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
            -Message ('Simulacao de restauracao: {0} pacote(s) do backup {1} seriam adicionados ao repositorio de drivers. Nenhuma alteracao foi feita.' -f $cont['Simulado'], $sel.Raiz) `
            -Recommendation 'Repetir a mesma acao com -Force para aplicar. Nenhum driver existente e removido pela restauracao.'
        return
    }

    if ($reinicio) {
        Write-Log WARN 'Um ou mais pacotes exigem reinicializacao para concluir a instalacao.'
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('{0} pacote(s) instalado(s) com pendencia de reinicializacao.' -f $cont['RestauradoPendenteReinicio']) `
            -Recommendation 'Reiniciar o computador e reavaliar o estado dos dispositivos. O COMPARTDISK nao reinicia a maquina.'
        Set-DriverResult 'WARN' 'reinicio pendente'
    }

    if ($status -eq 'CRIT') {
        Set-DriverFase 'Falhou'
        Write-Log ERR ('Nenhum pacote pode ser restaurado. {0} falha(s).' -f $falhas)
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Restauracao nao concluida: nenhum dos {0} pacote(s) selecionados pode ser adicionado ao repositorio.' -f $alvos.Count) `
            -Recommendation 'Verificar privilegios administrativos, politica de instalacao de dispositivos e assinatura dos pacotes. Nenhum driver existente foi removido.'
        Set-DriverResult 'ERROR' 'restauracao nao concluida'
        return
    }
    if ($falhas -gt 0) {
        Set-DriverFase 'ConcluidoComAvisos'
        Write-Log WARN ('Restauracao parcial: {0} pacote(s) adicionados, {1} falha(s).' -f $ok, $falhas)
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('Restauracao parcial: {0} de {1} pacote(s) adicionados ao repositorio; {2} falharam.' -f $ok, $alvos.Count, $falhas) `
            -Recommendation 'Os pacotes bem-sucedidos permanecem instalados. Repetir a acao restaurando apenas os que falharam com -InfName, apos verificar assinatura e compatibilidade.'
        Set-DriverResult 'WARN' 'restauracao parcial'
        return
    }

    Set-DriverFase 'Concluido'
    Write-Log OK ('Restauracao concluida e verificada: {0} pacote(s) adicionados, {1} ja presente(s).' -f $ok, $cont['JaPresente'])
    Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
        -Message ('Restauracao concluida: {0} pacote(s) adicionados e confirmados por reconsulta ao repositorio.' -f $ok) `
        -Recommendation 'Conferir o Gerenciador de Dispositivos; reiniciar caso algum pacote tenha indicado pendencia.'
}

# ==============================================================================
# ACAO: PACKAGE
#
# Etapa SEPARADA do backup: prepara um conjunto selecionado para transporte,
# com manifesto proprio e hash. Nao envia nada.
#
# NAO EXISTE UPLOAD NO COMPARTDISK. Nenhum modulo do projeto possui destino de
# envio: remote.ps1 apenas baixa o projeto do GitHub. Este modulo entrega o
# pacote pronto e informa caminho, tamanho e SHA-256 para transporte manual, e
# nao simula envio nem inventa integracao com servico externo.
# ==============================================================================
function Get-DriverZipCompressor {
    <# System.IO.Compression.ZipFile e nativo do .NET e lida melhor com volume
       grande que Compress-Archive, que so entra como alternativa. #>
    [CmdletBinding()] param()
    try {
        if (-not ('System.IO.Compression.ZipFile' -as [type])) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        }
        if ('System.IO.Compression.ZipFile' -as [type]) { return 'ZipFile' }
    } catch {
        Write-Log DEBUG ("System.IO.Compression.FileSystem indisponivel: {0}" -f $_.Exception.Message) -NoConsole
    }
    if (Test-CompartDiskCommand 'Compress-Archive') { return 'Compress-Archive' }
    return ''
}

function New-DriverPacote {
    [CmdletBinding()]
    param(
        [string]$Origem,
        [string]$FiltroInf = '',
        [string]$FiltroProvedor = '',
        [string]$FiltroClasse = '',
        [switch]$Compactar
    )
    Set-DriverFase 'EmPreparacao'

    $sel = Resolve-DriverBackupOrigem -Path $Origem
    if (-not $sel.Ok) {
        Write-Log ERR ('Preparacao nao executada: {0}' -f $sel.Detalhe)
        Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status CRIT -Summary 'Backup nao localizado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel localizar um backup para empacotar: {0}' -f $sel.Detalhe) `
            -Recommendation 'Executar a acao Backup ou informar o diretorio do backup em -Path.'
        Set-DriverResult 'ERROR' 'backup nao localizado'
        Set-DriverFase 'Falhou'
        return
    }

    $v = Test-DriverBackupIntegrity -Destino $sel.Raiz
    if (-not $v.Utilizavel) {
        Write-Log ERR ('Backup reprovado na validacao: {0}' -f $v.Detalhe)
        Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status CRIT `
            -Pairs ([ordered]@{ 'Backup' = $sel.Raiz; 'Motivo' = $v.Detalhe }) `
            -Summary 'Backup reprovado; nenhum pacote foi gerado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Empacotamento recusado: o backup em {0} nao passou na validacao ({1}).' -f $sel.Raiz, $v.Detalhe) `
            -Recommendation 'Nao transportar um backup que nao pode ser validado. Refazer o backup na maquina de origem.'
        Set-DriverResult 'ERROR' 'backup reprovado na validacao'
        Set-DriverFase 'Falhou'
        return
    }

    $layout  = Get-DriverBackupLayout -Raiz $sel.Raiz
    $pacotes = Get-DriverPacotesDoDisco -Diretorio $layout.Drivers -ComHash
    $filtro  = Select-DriverRestoreCandidatos -Pacotes $pacotes -FiltroInf $FiltroInf `
                   -FiltroProvedor $FiltroProvedor -FiltroClasse $FiltroClasse
    $alvos = @($filtro.Selecionados)
    $temFiltro = -not ([string]::IsNullOrWhiteSpace($FiltroInf) -and
                       [string]::IsNullOrWhiteSpace($FiltroProvedor) -and
                       [string]::IsNullOrWhiteSpace($FiltroClasse))

    if ($alvos.Count -eq 0) {
        Write-Log WARN 'Nenhum pacote atende aos filtros informados.'
        Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status WARN -Rows @($filtro.Descartados) `
            -Pairs ([ordered]@{ 'Backup' = $sel.Raiz; 'Pacotes no backup' = @($pacotes).Count; 'Selecionados' = 0 }) `
            -Summary 'Nenhum pacote selecionado'
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message 'Nenhum pacote atende aos filtros informados: nenhum pacote de transporte foi gerado.' `
            -Recommendation 'Rever -InfName, -Provider e -DeviceClass, ou empacotar o backup completo sem filtros.'
        Set-DriverResult 'WARN' 'nenhum pacote selecionado'
        Set-DriverFase 'Concluido'
        return
    }

    $bytesSel = 0
    foreach ($a in $alvos) { $bytesSel += [long]$a.Bytes }
    Write-Log INFO ('{0} de {1} pacote(s) selecionado(s), {2}.' -f $alvos.Count, @($pacotes).Count, (ConvertTo-CompartDiskSize $bytesSel))

    # Backup completo, sem compactar: o proprio backup ja e o pacote. Copiar
    # gigabytes para produzir um clone identico nao agrega nada.
    if (-not $temFiltro -and -not $Compactar) {
        $man = Import-DriverManifesto -Raiz $sel.Raiz
        Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status OK `
            -Pairs ([ordered]@{
                'Pacote (pasta)'   = $sel.Raiz
                'Pacotes'          = $alvos.Count
                'Tamanho'          = (ConvertTo-CompartDiskSize $bytesSel)
                'Manifesto'        = $(if ($man.Ok) { $man.Caminho } else { 'ausente' })
                'Compactado'       = 'Nao (usar -Compress para gerar .zip)'
                'Envio automatico' = 'Nao disponivel: o COMPARTDISK nao possui integracao de upload'
            }) -Summary ('Backup completo pronto para transporte: {0} pacote(s), {1}' -f $alvos.Count, (ConvertTo-CompartDiskSize $bytesSel))
        Write-Log OK ('Backup pronto para transporte: {0} ({1}).' -f $sel.Raiz, (ConvertTo-CompartDiskSize $bytesSel))
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
            -Message ('Backup validado e pronto para transporte manual: {0} ({1} pacote(s), {2}).' -f $sel.Raiz, $alvos.Count, (ConvertTo-CompartDiskSize $bytesSel)) `
            -Recommendation 'Copiar a pasta para a midia de destino. O COMPARTDISK nao possui envio automatico: nenhum arquivo sai desta maquina por conta da ferramenta.'
        Set-DriverFase 'Concluido'
        return
    }

    # ------------------------------------------------------- destino do pacote
    $paiBackup = Split-Path -Parent $sel.Raiz
    if ([string]::IsNullOrWhiteSpace($paiBackup)) { $paiBackup = $sel.Raiz }
    $dirPacotes = Join-Path $paiBackup 'Pacotes'
    # Compactar exige espaco para a copia preparada E para o .zip.
    $necessario = [long]($bytesSel * 2 + 128MB)
    $cand = Test-DriverCandidatoDestino -Caminho $dirPacotes -Origem 'Pasta Pacotes ao lado do backup' -MinimoBytes $necessario -Criar
    if (-not $cand.Ok) {
        Write-Log ERR ('Destino do pacote recusado: {0}' -f $cand.Motivo)
        Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status CRIT `
            -Pairs ([ordered]@{
                'Destino pretendido' = $dirPacotes
                'Necessario (est.)'  = (ConvertTo-CompartDiskSize $necessario)
                'Motivo'             = $cand.Motivo
            }) -Summary 'Destino do pacote indisponivel'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel preparar o pacote: {0}' -f $cand.Motivo) `
            -Recommendation 'Liberar espaco no volume do backup ou copiar o backup para outro volume antes de empacotar.'
        Set-DriverResult 'ERROR' 'destino do pacote indisponivel'
        Set-DriverFase 'Falhou'
        return
    }

    Set-DriverFase 'EmExecucao'
    $carimbo = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $nomePac = 'Drivers_Backup_{0}' -f $carimbo
    $stage   = Join-Path $cand.Caminho $nomePac
    $stageDrv= Join-Path $stage 'Drivers'
    try {
        foreach ($d in @($stage, $stageDrv, (Join-Path $stage 'Manifest'))) {
            New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Log ERR ('Nao foi possivel criar a area de preparacao: {0}' -f $stage) -ErrorRecord $_
        Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status CRIT -Summary 'Area de preparacao inacessivel'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message ('Nao foi possivel criar a area de preparacao do pacote em {0}.' -f $stage) `
            -Recommendation 'Verificar permissao de escrita no volume do backup.'
        Set-DriverResult 'ERROR' 'area de preparacao inacessivel'
        Set-DriverFase 'Falhou'
        return
    }

    $copiados = 0
    $falhasCopia = 0
    $manifesto = New-DriverManifesto -Destino $stage -Metodo 'Copia seletiva de backup validado'
    foreach ($a in $alvos) {
        $alvoPasta = Join-Path $stageDrv (Get-DriverNomeSeguro $a.Pasta)
        try {
            Copy-Item -LiteralPath $a.Caminho -Destination $alvoPasta -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $alvoPasta -PathType Container)) { throw 'O destino nao existe apos a copia.' }
            $copiados++
            [void]$manifesto.Pacotes.Add([pscustomobject]@{
                Pasta = $a.Pasta; Inf = $a.Inf; Provedor = $a.Provedor; Versao = $a.Versao
                Data = $a.Data; Classe = $a.Classe; Catalogo = $a.Catalogo
                Arquivos = $a.Arquivos; Bytes = $a.Bytes
                HashInf = $a.HashInf; HashCatalogo = $a.HashCatalogo
            })
            $manifesto.Totais.Arquivos += $a.Arquivos
            $manifesto.Totais.Bytes    += $a.Bytes
        } catch {
            $falhasCopia++
            Write-Log WARN ('Falha ao copiar o pacote {0} para a area de preparacao.' -f $a.Pasta) -ErrorRecord $_
        }
    }
    $manifesto.Totais.PacotesExportados = $copiados
    $manifesto.Estado = $(if ($falhasCopia -eq 0 -and $copiados -gt 0) { 'Concluido' } elseif ($copiados -gt 0) { 'ConcluidoComAvisos' } else { 'Falhou' })
    [void]$manifesto.Observacoes.Add(('Origem: {0}' -f $sel.Raiz))
    if ($temFiltro) {
        [void]$manifesto.Observacoes.Add(('Filtros aplicados: Inf="{0}" Provider="{1}" Class="{2}"' -f $FiltroInf, $FiltroProvedor, $FiltroClasse))
    }
    $sm = Save-DriverManifesto -Manifesto $manifesto -Diretorio (Join-Path $stage 'Manifest')

    if ($copiados -eq 0) {
        Write-Log ERR 'Nenhum pacote pode ser copiado para a area de preparacao.'
        Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status CRIT `
            -Pairs ([ordered]@{ 'Area de preparacao' = $stage; 'Falhas de copia' = $falhasCopia }) `
            -Summary 'Nenhum pacote copiado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
            -Message 'Nenhum pacote pode ser copiado para o pacote de transporte.' `
            -Recommendation 'Verificar espaco, permissao e se algum arquivo esta bloqueado por outro processo. O backup de origem nao foi alterado.'
        Set-DriverResult 'ERROR' 'nenhum pacote copiado'
        Set-DriverFase 'Falhou'
        return
    }

    # ------------------------------------------------------------ compactacao
    $zip = ''
    $zipBytes = 0
    $zipHash = ''
    $zipEntradas = 0
    $zipOk = $false
    $zipDetalhe = 'nao solicitada'
    if ($Compactar) {
        $motor = Get-DriverZipCompressor
        if (-not $motor) {
            $zipDetalhe = 'nenhum mecanismo de compactacao nativo disponivel neste PowerShell'
            Write-Log WARN 'Compactacao indisponivel: a pasta preparada permanece utilizavel.'
            Set-DriverResult 'WARN' 'compactacao indisponivel'
        } else {
            $zip = Join-Path $cand.Caminho ('{0}.zip' -f $nomePac)
            $r = Invoke-SafeCommand {
                if ($motor -eq 'ZipFile') {
                    [System.IO.Compression.ZipFile]::CreateFromDirectory(
                        $stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
                } else {
                    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force -ErrorAction Stop
                }
                return $true
            } -Activity ('Compactacao ({0})' -f $motor) -Silent

            if (-not $r.Success) {
                $zipDetalhe = ('falhou: {0}' -f $(if ($r.Error) { $r.Error.Exception.Message } else { 'motivo nao identificado' }))
                Write-Log WARN ('Compactacao falhou: {0}' -f $zipDetalhe)
                Set-DriverResult 'WARN' 'compactacao falhou'
            } else {
                # "Compactou" nao e prova: o arquivo e reaberto e as entradas contadas.
                try {
                    $fi = Get-Item -LiteralPath $zip -ErrorAction Stop
                    $zipBytes = [long]$fi.Length
                    if ($zipBytes -le 0) { throw 'O arquivo compactado esta vazio.' }
                    if ('System.IO.Compression.ZipFile' -as [type]) {
                        $arc = [System.IO.Compression.ZipFile]::OpenRead($zip)
                        try { $zipEntradas = @($arc.Entries).Count } finally { $arc.Dispose() }
                        if ($zipEntradas -le 0) { throw 'O arquivo compactado nao contem entradas.' }
                    }
                    $h = Get-DriverHashArquivo -Caminho $zip
                    if ($h.Ok) { $zipHash = $h.Sha256 }
                    $zipOk = $true
                    $zipDetalhe = ('verificado: {0} entrada(s)' -f $zipEntradas)
                } catch {
                    $zipDetalhe = ('gerado, porem nao verificavel: {0}' -f $_.Exception.Message)
                    Write-Log WARN ('Arquivo compactado nao pode ser verificado: {0}' -f $zip) -ErrorRecord $_
                    Set-DriverResult 'WARN' 'pacote compactado nao verificado'
                }
            }
        }
    }

    $pares = [ordered]@{
        'Backup de origem'   = $sel.Raiz
        'Pasta preparada'    = $stage
        'Pacotes copiados'   = ('{0} de {1}' -f $copiados, $alvos.Count)
        'Falhas de copia'    = $falhasCopia
        'Tamanho preparado'  = (ConvertTo-CompartDiskSize $manifesto.Totais.Bytes)
        'Manifesto'          = $(if ($sm.Ok) { 'gravado e conferido' } else { 'nao gravado' })
        'Arquivo compactado' = $(if ($zipOk) { $zip } else { 'nenhum' })
        'Tamanho do .zip'    = $(if ($zipOk) { (ConvertTo-CompartDiskSize $zipBytes) } else { 'n/d' })
        'SHA-256 do .zip'    = $(if ($zipHash) { $zipHash } else { 'n/d' })
        'Compactacao'        = $zipDetalhe
        'Envio automatico'   = 'Nao disponivel: o COMPARTDISK nao possui integracao de upload'
        'Estado da operacao' = $manifesto.Estado
    }
    $status = 'OK'
    if ($falhasCopia -gt 0 -or -not $sm.Ok) { $status = 'WARN' }
    if ($Compactar -and -not $zipOk) { $status = 'WARN' }

    Add-CompartDiskSection -Title 'Pacote de drivers para transporte' -Status $status -Pairs $pares `
        -Summary ('{0} pacote(s) preparado(s), {1}' -f $copiados, $(if ($zipOk) { (ConvertTo-CompartDiskSize $zipBytes) + ' compactado' } else { (ConvertTo-CompartDiskSize $manifesto.Totais.Bytes) }))

    if ($status -eq 'WARN') {
        Set-DriverFase 'ConcluidoComAvisos'
        Write-Log WARN ('Pacote preparado com ressalvas: {0} pacote(s) copiado(s), {1} falha(s).' -f $copiados, $falhasCopia)
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('Pacote de transporte preparado com ressalvas em {0}: {1} de {2} pacote(s) copiado(s); compactacao {3}.' -f $stage, $copiados, $alvos.Count, $zipDetalhe) `
            -Recommendation 'Conferir o conteudo antes de transportar. O backup de origem permanece intacto.'
        Set-DriverResult 'WARN' 'pacote preparado com ressalvas'
    } else {
        Set-DriverFase 'Concluido'
        Write-Log OK ('Pacote pronto: {0}' -f $(if ($zipOk) { $zip } else { $stage }))
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
            -Message ('Pacote de transporte pronto e verificado: {0} ({1} pacote(s)).' -f $(if ($zipOk) { $zip } else { $stage }), $copiados) `
            -Recommendation 'Copiar manualmente para a midia ou compartilhamento de destino. O COMPARTDISK nao envia arquivos: nenhum dado sai desta maquina por conta da ferramenta.'
    }

    Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
        -Message 'O COMPARTDISK nao possui integracao de upload: nao existe destino remoto configurado no projeto.' `
        -Recommendation 'O transporte do pacote e manual e permanece sob controle do operador. Nenhum envio foi tentado nem simulado.'
}

# ==============================================================================
# ACAO: DIAGNOSE  (somente leitura)
# Verificacao previa: responde "da para fazer backup aqui e agora?" ANTES de
# iniciar uma operacao longa, e nao altera absolutamente nada.
# ==============================================================================
function Invoke-DriverDiagnose {
    [CmdletBinding()] param([string]$Destino)
    Set-DriverFase 'EmExecucao'
    Write-Log INFO 'Diagnostico previo do subsistema de drivers...'

    $admin   = Test-Administrator
    $temPnp  = Test-Path -LiteralPath $pnputil
    $inv     = Get-DriverInventory
    $prob    = Get-DriverProblems

    $checks = New-Object System.Collections.ArrayList
    $addCheck = {
        param($Item, $Estado, $Detalhe)
        [void]$checks.Add([pscustomobject]@{ Verificacao = $Item; Estado = $Estado; Detalhe = $Detalhe })
    }

    & $addCheck 'Privilegio administrativo' $(if ($admin) { 'OK' } else { 'WARN' }) `
        $(if ($admin) { 'Presente: backup e restauracao disponiveis.' } else { 'Ausente: Backup e Restore serao recusados. Diagnostico e inventario continuam disponiveis.' })
    & $addCheck 'pnputil.exe' $(if ($temPnp) { 'OK' } else { 'CRIT' }) `
        $(if ($temPnp) { $pnputil } else { 'Nao localizado: backup e restauracao indisponiveis.' })
    & $addCheck 'Repositorio WMI' $(if ($inv.Ok) { 'OK' } else { 'CRIT' }) $inv.Detalhe
    & $addCheck 'Inventario de drivers' $(if ($inv.Status -eq 'Completo') { 'OK' } elseif ($inv.Ok) { 'WARN' } else { 'CRIT' }) `
        ('{0} driver(s); coleta {1}.' -f $inv.Total, $inv.Status)

    # Repositorio de drivers acessivel?
    $repo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    $repoOk = Test-Path -LiteralPath $repo
    & $addCheck 'Repositorio de drivers' $(if ($repoOk) { 'OK' } else { 'CRIT' }) `
        $(if ($repoOk) { $repo } else { 'FileRepository nao localizado: a exportacao nao tem origem.' })

    # Pacotes publicados (exige privilegio; sem ele o resultado e informativo).
    $pub = $null
    if ($temPnp -and $admin) {
        $pub = Get-DriverPublicados -PnpUtil $pnputil
        & $addCheck 'Pacotes de terceiros publicados' $(if ($pub.Ok) { 'OK' } else { 'WARN' }) $pub.Detalhe
    } else {
        & $addCheck 'Pacotes de terceiros publicados' 'INFO' 'Nao consultado: exige pnputil e privilegio administrativo.'
    }

    # Estimativa e destino.
    $est = Get-DriverStoreEstimate
    & $addCheck 'Estimativa de tamanho' $(if ($est.Ok) { 'OK' } else { 'WARN' }) `
        $(if ($est.Ok) { ('Limite superior {0} em {1} arquivo(s), medido em {2}s.' -f (ConvertTo-CompartDiskSize $est.Bytes), $est.Arquivos, $est.Segundos) } else { $est.Detalhe })

    $necessario = $(if ($est.Ok) { [long]($est.Bytes + 512MB) } else { [long]4GB })
    # -SemCriar: o diagnostico avalia os candidatos sem criar nenhum diretorio.
    $base = Resolve-DriverBackupBase -Path $Destino -MinimoBytes $necessario -SemCriar
    if (-not $base.Ok -and [string]::IsNullOrWhiteSpace("$Destino")) { $base = Resolve-DriverBackupBase -Path $Destino -SemCriar }
    Add-DriverDestinoSection -Base $base -Titulo 'Selecao do destino (diagnostico)'
    & $addCheck 'Destino de backup' $(if ($base.Ok) { 'OK' } else { 'CRIT' }) `
        $(if ($base.Ok) { ('{0} ({1}, volume {2})' -f $base.Base, $base.Origem, $base.Tipo) } else { $base.Detalhe })

    $espaco = $null
    if ($base.Ok) {
        $espaco = Get-DriverVolumeInfo -FullPath $base.Base -Unc:$base.Unc
        if ($espaco.Ok) {
            $suficiente = ($espaco.Bytes -ge $necessario)
            & $addCheck 'Espaco livre no destino' $(if ($suficiente) { 'OK' } else { 'WARN' }) `
                ('{0} livre para {1} estimados ({2}).' -f (ConvertTo-CompartDiskSize $espaco.Bytes), (ConvertTo-CompartDiskSize $necessario), $(if ($suficiente) { 'suficiente' } else { 'abaixo da estimativa, que e um limite superior' }))
        } else {
            & $addCheck 'Espaco livre no destino' 'WARN' $espaco.Detalhe
        }
    }

    # Sinais de saude do proprio parque de drivers.
    $ass = $null
    if ($inv.Ok -and $inv.Total -gt 0) {
        $ass = Get-DriverSignatureAnalysis $inv.Rows
        & $addCheck 'Assinatura digital' $(if ($ass.TotalNaoAssinados -gt 0) { 'WARN' } elseif ($ass.TotalDesconhecidos -gt 0) { 'INFO' } else { 'OK' }) `
            ('{0} assinado(s), {1} sem assinatura, {2} inconclusivo(s).' -f $ass.TotalAssinados, $ass.TotalNaoAssinados, $ass.TotalDesconhecidos)

        $dup = Get-DriverDuplicados $inv.Rows
        & $addCheck 'Versoes duplicadas' $(if (@($dup).Count -gt 0) { 'INFO' } else { 'OK' }) `
            $(if (@($dup).Count -gt 0) { ('{0} dispositivo(s) com mais de uma versao de driver enumerada. O repositorio retem versoes anteriores por projeto; nada e removido por isso.' -f @($dup).Count) } else { 'Nenhuma duplicidade de versao enumerada.' })
    }

    if ($prob.Ok) {
        $crit = @($prob.Rows | Where-Object { $_.Severidade -eq 'CRIT' }).Count
        $ausentes = @($prob.Rows | Where-Object { $_.DriverAusente }).Count
        & $addCheck 'Dispositivos com codigo de erro' $(if ($crit -gt 0) { 'WARN' } elseif ($prob.Total -gt 0) { 'INFO' } else { 'OK' }) `
            ('{0} dispositivo(s) com codigo de erro; {1} critico(s); {2} com driver ausente ou invalido.' -f $prob.Total, $crit, $ausentes)
    } else {
        & $addCheck 'Dispositivos com codigo de erro' 'CRIT' $prob.Detalhe
    }

    Write-DriverTable -Rows $checks -Property @('Verificacao', 'Estado', 'Detalhe')

    $status = Get-DriverWorstSeverity @($checks | ForEach-Object { $_.Estado })
    $prontoBackup = ($admin -and $temPnp -and $repoOk -and $base.Ok)
    Add-CompartDiskSection -Title 'Diagnostico previo de drivers' -Status $status -Rows @($checks) `
        -Pairs ([ordered]@{
            'Pronto para backup'  = $(if ($prontoBackup) { 'Sim' } else { 'Nao' })
            'Destino previsto'    = $(if ($base.Ok) { $base.Base } else { 'nenhum' })
            'Necessario (est.)'   = (ConvertTo-CompartDiskSize $necessario)
            'Espaco livre'        = $(if ($espaco -and $espaco.Ok) { (ConvertTo-CompartDiskSize $espaco.Bytes) } else { 'nao determinado' })
            'Drivers enumerados'  = $inv.Total
            'Verificacoes'        = @($checks).Count
        }) -Summary ("{0} verificacao(oes); pronto para backup: {1}" -f @($checks).Count, $(if ($prontoBackup) { 'sim' } else { 'nao' }))

    if (-not $prontoBackup) {
        Set-DriverFase 'ConcluidoComAvisos'
        $faltando = @()
        if (-not $admin)   { $faltando += 'privilegio administrativo' }
        if (-not $temPnp)  { $faltando += 'pnputil.exe' }
        if (-not $repoOk)  { $faltando += 'repositorio de drivers' }
        if (-not $base.Ok) { $faltando += 'destino valido' }
        Write-Log WARN ('Pre-condicoes de backup nao atendidas: {0}.' -f ($faltando -join ', '))
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' `
            -Message ('O backup de drivers nao pode ser executado agora: falta {0}.' -f ($faltando -join ', ')) `
            -Recommendation 'Reabrir o Launcher.bat como Administrador e/ou informar um destino valido em -Path antes de executar o backup.'
        Set-DriverResult 'WARN' 'pre-condicoes de backup nao atendidas'
    } else {
        Set-DriverFase 'Concluido'
        Write-Log OK ('Pre-condicoes atendidas: backup pode ser executado para {0}.' -f $base.Base)
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' `
            -Message ('Diagnostico concluido: o backup de drivers pode ser executado para {0}.' -f $base.Base) `
            -Recommendation 'Nada foi alterado por esta verificacao.'
    }
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
        -Property @('Dispositivo', 'Fabricante', 'Versao', 'Data', 'Assinatura', 'Classe', 'Origem', 'Estado')
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
            'Com driver ausente ou invalido'  = @($prob.Rows | Where-Object { $_.DriverAusente }).Count
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

    $inv  = Get-DriverInventory
    $prob = Get-DriverProblems

    # Versoes duplicadas: informativo, nunca acionavel por si so.
    if ($inv.Ok -and $inv.Total -gt 0) {
        $dup = Get-DriverDuplicados $inv.Rows
        if (@($dup).Count -gt 0) {
            Add-CompartDiskSection -Title 'Dispositivos com mais de uma versao de driver' -Status INFO -Rows @($dup) `
                -Pairs ([ordered]@{ 'Dispositivos' = @($dup).Count }) `
                -Summary ("{0} dispositivo(s) com versoes multiplas enumeradas" -f @($dup).Count)
            Add-CompartDiskFinding -Severity INFO -Area 'Drivers' `
                -Message ("{0} dispositivo(s) apresentam mais de uma versao de driver enumerada." -f @($dup).Count) `
                -Recommendation 'O repositorio de drivers do Windows retem versoes anteriores por projeto, o que permite reverter uma atualizacao problematica. Nenhuma remocao e recomendada com base apenas nesta contagem.'
        }
    }

    # Correlacao de sinais: dispositivo com codigo de erro cujo driver tambem
    # nao esta assinado tem prioridade sobre um driver antigo saudavel.
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
#
# Somente leitura (sem elevacao): List, Problems, Unsigned, Export, Diagnose,
#   Validate, Last, Package.
# Exigem administrador: Backup (pnputil /export-driver e /enum-drivers dependem
#   de privilegio elevado) e Restore (adiciona pacotes ao repositorio).
#
# Nenhuma acao faz pergunta interativa: o modulo e invocado pelo Launcher com
# argumentos fixos e precisa continuar utilizavel em RMM, GPO e tarefa agendada.
# A escolha do operador entra por -Path e pelos filtros, nunca por prompt.
# ==============================================================================
$codigo = $Global:CompartDisk.Exit.ERROR
try {
    $precisaAdmin = @('Backup', 'Restore') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Drivers' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # Sem isto o estado persistido para o Report.ps1 sairia como OK enquanto
        # o modulo devolvia codigo de erro.
        Set-DriverFase 'Falhou'
        Set-DriverResult 'ERROR' 'privilegios administrativos ausentes'
    } else {
        switch ($Action) {
            'List'     { Show-Drivers }
            'Problems' { Show-Problems }
            'Unsigned' { Show-Unsigned }
            'Export'   { Export-DriverInventory }
            'Diagnose' { Invoke-DriverDiagnose -Destino $Path }
            'Backup'   { [void](Backup-Drivers -Destino $Path) }
            'Validate' { [void](Invoke-DriverValidate -Origem $Path) }
            'Last'     { Show-DriverUltimoBackup -Origem $Path }
            'Package'  {
                New-DriverPacote -Origem $Path -FiltroInf $InfName -FiltroProvedor $Provider `
                    -FiltroClasse $DeviceClass -Compactar:$Compress
            }
            'Restore'  {
                # Simulacao e o padrao. -DryRun vence -Force: pedir simulacao
                # explicita nunca pode acabar em instalacao.
                $aplicar = ($Force -and -not $DryRun)
                Restore-Drivers -Origem $Path -FiltroInf $InfName -FiltroProvedor $Provider `
                    -FiltroClasse $DeviceClass -SomenteAusentes:$OnlyMissing -Aplicar:$aplicar
            }
        }
    }
} catch {
    Set-DriverFase 'Falhou'
    Set-DriverResult 'ERROR' 'excecao nao tratada'
    Write-Log ERR "Falha nao tratada no modulo Drivers (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' `
        -Message ("Excecao no modulo durante a acao '{0}': {1}" -f $Action, $_.Exception.Message) `
        -Recommendation 'Consultar o log detalhado da sessao para a etapa exata e o codigo do erro. Operacoes ja concluidas antes da falha permanecem no destino.'
} finally {
    Write-Log DEBUG ("Estado operacional final: {0} | Resultado: {1}" -f $script:Fase, $script:result) -NoConsole
    $codigo = Stop-CompartDiskModule -Result $script:result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$script:result] }
}
exit ([int]$codigo)
