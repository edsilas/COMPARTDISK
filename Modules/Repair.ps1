<#
 COMPARTDISK 1.3.1 - Repair.ps1
 Desenvolvido por Edsilas
 Acoes: Full | Sfc | Dism | Scan | Chkdsk | Component
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Sfc', 'Dism', 'Scan', 'Chkdsk', 'Component')]
    [string]$Action = 'Full',
    [string]$Drive = 'C:',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

# ==============================================================================
# ESTADO GLOBAL
# Monotonico: OK -> WARN -> ERROR, e nunca regride.
#
# Antes, cada funcao atribuia $script:result diretamente. Numa acao Full a
# sequencia ScanHealth -> RestoreHealth -> SFC podia elevar o estado para ERROR
# na primeira etapa e rebaixa-lo para WARN na seguinte: o modulo devolvia
# "atencao" ao Launcher para uma execucao em que o DISM nao pode nem ser
# localizado. E o mesmo padrao ja adotado por Drivers.ps1 e Debloat.ps1.
# ==============================================================================
$script:result = 'OK'
$script:ResultRank = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-RepairResult {
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Position = 1)][string]$Reason = ''
    )
    if ($script:ResultRank[$Level] -gt $script:ResultRank[$script:result]) {
        $script:result = $Level
        Write-Log DEBUG ("Resultado do modulo elevado para {0}{1}" -f $Level, $(if ($Reason) { ": $Reason" } else { '' })) -NoConsole
    }
}

$sfcExe  = Join-Path $env:SystemRoot 'System32\sfc.exe'
$dismExe = Join-Path $env:SystemRoot 'System32\Dism.exe'

# Resultado da ultima etapa, consultado pela acao Full para decidir a proxima.
$script:UltimaEtapa = [pscustomobject]@{ Nome = ''; Ok = $false; Critico = $false; Detalhe = '' }

function Set-RepairEtapa {
    param([string]$Nome, [bool]$Ok, [bool]$Critico = $false, [string]$Detalhe = '')
    $script:UltimaEtapa = [pscustomobject]@{ Nome = $Nome; Ok = $Ok; Critico = $Critico; Detalhe = $Detalhe }
}

function Get-SfcCbsEvidencia {
    <# Le o CBS.log considerando SOMENTE as entradas gravadas a partir do inicio
       desta execucao.

       Antes, a funcao contava padroes nas ultimas 4000 linhas do arquivo. O
       CBS.log e cumulativo e sobrevive a reinicios: um reparo ocorrido semanas
       atras continuava sendo contado, e o modulo reportava "SFC reparou
       arquivos" numa execucao que nao reparou nada. O inverso tambem acontecia
       - num log com muita atividade recente, as linhas da execucao atual saiam
       da janela de 4000 e um reparo real era reportado como "nenhuma violacao".

       As linhas do CBS comecam com "AAAA-MM-DD HH:MM:SS". O corte e feito por
       esse carimbo. Quando ele nao puder ser interpretado, devolve
       Confiavel=$false e o chamador decide pelo codigo de retorno em vez de
       inventar uma contagem. #>
    param([Parameter(Mandatory)][datetime]$Desde)

    $out = [pscustomobject]@{
        Confiavel = $false; Corrigidos = 0; NaoCorrigidos = 0
        Linhas = 0; Caminho = (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'); Detalhe = ''
    }
    if (-not (Test-Path -LiteralPath $out.Caminho)) {
        $out.Detalhe = 'CBS.log nao localizado.'
        return $out
    }
    try {
        # Janela generosa: o SFC grava muitas linhas por execucao. O filtro real
        # e o carimbo de data/hora, nao a quantidade.
        $bruto = Get-Content -LiteralPath $out.Caminho -Tail 60000 -ErrorAction Stop
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $recentes = New-Object System.Collections.ArrayList
        $viuCarimbo = $false
        foreach ($linha in $bruto) {
            $m = [regex]::Match("$linha", '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
            if ($m.Success) {
                $viuCarimbo = $true
                $dt = [datetime]::MinValue
                if ([datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $inv,
                        [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
                    if ($dt -lt $Desde) { continue }
                }
            }
            [void]$recentes.Add($linha)
        }
        if (-not $viuCarimbo) {
            $out.Detalhe = 'Formato de carimbo do CBS.log nao reconhecido: contagem descartada.'
            return $out
        }
        $out.Linhas        = $recentes.Count
        $out.Corrigidos    = @($recentes | Select-String -Pattern 'Repairing corrupted file|Repaired file').Count
        $out.NaoCorrigidos = @($recentes | Select-String -Pattern 'cannot repair member file|Cannot repair').Count
        $out.Confiavel     = $true
        $out.Detalhe       = ('{0} linha(s) gravada(s) durante esta execucao.' -f $recentes.Count)
    } catch {
        $out.Detalhe = ('Nao foi possivel ler o CBS.log: {0}' -f $_.Exception.Message)
        Write-Log WARN 'CBS.log ilegivel: a conclusao do SFC usara apenas o codigo de retorno.' -ErrorRecord $_
    }
    return $out
}

function Invoke-Sfc {
    Write-Log INFO 'Iniciando System File Checker (sfc /scannow). Pode levar varios minutos...'
    if (-not (Test-Path -LiteralPath $sfcExe)) {
        Write-Log ERR 'sfc.exe nao localizado no sistema.'
        Add-CompartDiskSection -Title 'System File Checker' -Status CRIT -Summary 'sfc.exe indisponivel'
        Add-CompartDiskFinding -Severity CRIT -Area 'Integridade' `
            -Message 'sfc.exe nao localizado: a verificacao de arquivos de sistema nao pode ser executada.' `
            -Recommendation 'Componente nativo ausente: avaliar a integridade do Windows com DISM /RestoreHealth.'
        Set-RepairResult 'ERROR' 'sfc.exe ausente'
        Set-RepairEtapa -Nome 'SFC' -Ok $false -Critico $true -Detalhe 'sfc.exe ausente'
        return
    }

    # Marca temporal ANTES da execucao: e o que separa as linhas desta execucao
    # das que ja estavam no CBS.log. Um segundo de folga cobre a diferenca de
    # arredondamento entre o relogio do processo e o carimbo do log.
    $inicio = (Get-Date).AddSeconds(-1)

    # SFC precisa escrever no console: execucao direta preserva a barra de progresso
    & $sfcExe /scannow
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = -1 }

    $ev = Get-SfcCbsEvidencia -Desde $inicio

    # Interpretacao: o codigo de retorno decide primeiro; a evidencia do CBS
    # apenas detalha O QUE aconteceu quando a execucao foi valida.
    #
    # Antes, o codigo era ignorado por completo: a funcao classificava apenas
    # pela contagem no log e encerrava com Write-Log OK inclusive quando o SFC
    # nao pode sequer iniciar - "SFC finalizado (codigo 1)" era gravado como
    # sucesso, e o finding dizia "nao encontrou violacoes".
    $estado = 'Desconhecido'
    $status = 'OK'
    $sev    = 'OK'
    $msg    = ''
    $rec    = ''
    $critico = $false

    if ($rc -ne 0) {
        $estado  = 'Nao concluido'
        $status  = 'CRIT'
        $sev     = 'CRIT'
        $critico = $true
        $msg = "O System File Checker nao concluiu a verificacao (codigo $rc)."
        $rec = 'Causas usuais: outro reparo em andamento, reinicio pendente, servico TrustedInstaller parado ou privilegio insuficiente. Resolver a pendencia e repetir.'
        Set-RepairResult 'ERROR' "sfc retornou $rc"
    }
    elseif (-not $ev.Confiavel) {
        $estado = 'Concluido, detalhamento indisponivel'
        $status = 'WARN'
        $sev    = 'WARN'
        $msg = 'O SFC concluiu, porem o CBS.log nao pode ser interpretado para confirmar se houve reparo.'
        $rec = "Conferir manualmente $($ev.Caminho). O codigo de retorno indica execucao bem-sucedida."
        Set-RepairResult 'WARN' 'evidencia do CBS indisponivel'
    }
    elseif ($ev.NaoCorrigidos -gt 0) {
        $estado  = 'Corrupcao nao reparada'
        $status  = 'CRIT'
        $sev     = 'CRIT'
        $critico = $true
        $msg = 'SFC encontrou arquivos que nao pode reparar.'
        $rec = 'Executar DISM /RestoreHealth e repetir o SFC.'
        Set-RepairResult 'WARN' 'arquivos nao reparados pelo SFC'
    }
    elseif ($ev.Corrigidos -gt 0) {
        $estado = 'Reparos aplicados'
        $status = 'WARN'
        $sev    = 'WARN'
        $msg = 'SFC reparou arquivos de sistema corrompidos.'
        $rec = 'Reiniciar e executar novamente para confirmar que nao restou corrupcao.'
        Set-RepairResult 'WARN' 'SFC aplicou reparos'
    }
    else {
        $estado = 'Integro'
        $msg = 'SFC nao encontrou violacoes de integridade.'
    }

    $pares = [ordered]@{
        'Codigo de retorno'      = $rc
        'Estado'                 = $estado
        'Reparos detectados'     = $(if ($ev.Confiavel) { $ev.Corrigidos } else { 'nao determinado' })
        'Falhas de reparo'       = $(if ($ev.Confiavel) { $ev.NaoCorrigidos } else { 'nao determinado' })
        'Evidencia do CBS'       = $(if ($ev.Confiavel) { $ev.Detalhe } else { "nao utilizada: $($ev.Detalhe)" })
        'Log de referencia'      = $ev.Caminho
    }
    Add-CompartDiskSection -Title 'System File Checker' -Status $status -Summary "Retorno $rc - $estado" -Pairs $pares
    if ($rec) { Add-CompartDiskFinding -Severity $sev -Area 'Integridade' -Message $msg -Recommendation $rec }
    else      { Add-CompartDiskFinding -Severity $sev -Area 'Integridade' -Message $msg }

    if ($rc -eq 0) { Write-Log OK "SFC finalizado (codigo $rc) - $estado." }
    else           { Write-Log ERR "SFC nao concluiu (codigo $rc)." }

    Set-RepairEtapa -Nome 'SFC' -Ok ($rc -eq 0) -Critico $critico -Detalhe $estado
}

function Get-DismCodigoTexto {
    <# Traducao dos codigos de retorno que o DISM realmente devolve neste fluxo.
       Sem isto o relatorio exibia apenas o numero, e "codigo 50" nao diz a
       ninguem que a operacao nao e suportada naquela edicao. #>
    param([int]$Codigo)
    switch ($Codigo) {
        0     { return 'Concluido com sucesso.' }
        3010  { return 'Concluido; reinicio necessario para finalizar.' }
        2     { return 'Arquivo ou recurso nao encontrado.' }
        5     { return 'Acesso negado.' }
        11    { return 'Formato invalido.' }
        50    { return 'Operacao nao suportada nesta edicao ou imagem.' }
        87    { return 'Parametro invalido.' }
        1726  { return 'Falha na chamada de procedimento remoto (RPC): o servico de manutencao pode estar parado.' }
        1393  { return 'Estrutura de disco corrompida.' }
        -2146498555 { return 'Arquivos de origem nao encontrados: e preciso uma fonte WIM/ESD local ou acesso ao Windows Update.' }
        default { return "Codigo $Codigo. Consultar o log do DISM para o detalhe." }
    }
}

function Invoke-Dism {
    param([ValidateSet('ScanHealth', 'CheckHealth', 'RestoreHealth', 'AnalyzeComponentStore', 'StartComponentCleanup')][string]$Op = 'RestoreHealth')

    Write-Log INFO "Executando DISM /Online /Cleanup-Image /$Op ..."
    $dismLog = Join-Path $env:SystemRoot 'Logs\DISM\dism.log'

    # Uma falha de RestoreHealth significa que o reparo NAO aconteceu, e isso e
    # erro - nao aviso. ScanHealth e CheckHealth apenas diagnosticam: falhar
    # neles degrada a informacao, nao o sistema.
    $opDeReparo = ($Op -eq 'RestoreHealth')

    # Preferencia por cmdlet nativo quando disponivel (melhor tratamento de erro)
    $motivoFallback = ''
    if ($Op -in @('ScanHealth', 'CheckHealth', 'RestoreHealth') -and (Test-CompartDiskCommand 'Repair-WindowsImage')) {
        $r = Invoke-SafeCommand {
            switch ($Op) {
                'ScanHealth'    { Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop }
                'CheckHealth'   { Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop }
                'RestoreHealth' { Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop }
            }
        } -Activity "Repair-WindowsImage $Op"

        if ($r.Success -and $r.Value) {
            $saude    = "$($r.Value.ImageHealthState)"
            $reinicio = [bool]$r.Value.RestartNeeded
            Write-CompartDiskKeyValue 'Estado da imagem' $saude
            $integra = ($saude -eq 'Healthy')
            Add-CompartDiskSection -Title "DISM $Op" -Status $(if ($integra) { 'OK' } else { 'WARN' }) `
                -Summary ("Estado da imagem: {0}" -f $saude) `
                -Pairs ([ordered]@{
                    'Mecanismo'           = 'Repair-WindowsImage (cmdlet nativo)'
                    'Estado da imagem'    = $saude
                    'Reinicio necessario' = $(if ($reinicio) { 'Sim' } else { 'Nao' })
                })
            if ($integra) {
                Add-CompartDiskFinding -Severity OK -Area 'Imagem do Windows' -Message "DISM ${Op}: imagem integra."
            } else {
                Set-RepairResult 'WARN' "imagem em estado '$saude'"
                Add-CompartDiskFinding -Severity WARN -Area 'Imagem do Windows' -Message "DISM reportou estado '$saude'." -Recommendation 'Executar RestoreHealth e, em seguida, SFC.'
            }
            if ($reinicio) {
                Set-RepairResult 'WARN' 'reinicio necessario apos DISM'
                Add-CompartDiskFinding -Severity WARN -Area 'Imagem do Windows' `
                    -Message "DISM $Op exige reinicio para finalizar a operacao." `
                    -Recommendation 'Reiniciar antes de executar o SFC ou novas manutencoes.'
            }
            Write-Log OK "DISM $Op concluido via cmdlet nativo (estado: $saude)."
            Set-RepairEtapa -Nome "DISM $Op" -Ok $true -Critico $false -Detalhe $saude
            return
        }

        # O fallback so acontece quando o cmdlet realmente nao entregou resultado,
        # e o motivo e registrado. Antes, a mensagem dizia "indisponivel ou
        # falhou" sem distinguir os dois casos nem preservar o erro original.
        $motivoFallback = $(if ($r.Error) { $r.Error.Exception.Message } else { 'o cmdlet nao devolveu estado da imagem' })
        Write-Log WARN "Repair-WindowsImage nao concluiu ($motivoFallback). Repetindo com Dism.exe."
    }

    if (-not (Test-Path -LiteralPath $dismExe)) {
        Write-Log ERR 'Dism.exe nao localizado.'
        Add-CompartDiskSection -Title "DISM $Op" -Status CRIT -Summary 'Dism.exe indisponivel' `
            -Pairs ([ordered]@{ 'Mecanismo' = 'nenhum disponivel'; 'Motivo' = 'Dism.exe nao localizado' })
        Add-CompartDiskFinding -Severity CRIT -Area 'Imagem do Windows' `
            -Message "DISM $Op nao pode ser executado: Dism.exe nao localizado." `
            -Recommendation 'Componente nativo ausente: avaliar a integridade da instalacao do Windows.'
        Set-RepairResult 'ERROR' 'Dism.exe ausente'
        Set-RepairEtapa -Nome "DISM $Op" -Ok $false -Critico $true -Detalhe 'Dism.exe ausente'
        return
    }

    & $dismExe /Online /Cleanup-Image "/$Op"
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = -1 }
    $ok        = ($rc -eq 0 -or $rc -eq 3010)
    $reinicio  = ($rc -eq 3010)
    $descricao = Get-DismCodigoTexto -Codigo $rc

    $pares = [ordered]@{
        'Mecanismo'           = 'Dism.exe'
        'Codigo de retorno'   = $rc
        'Interpretacao'       = $descricao
        'Reinicio necessario' = $(if ($reinicio) { 'Sim' } else { 'Nao' })
        'Log'                 = $dismLog
    }
    if ($motivoFallback) { $pares['Motivo do fallback'] = $motivoFallback }

    Add-CompartDiskSection -Title "DISM $Op" -Status $(if ($ok) { 'OK' } else { 'CRIT' }) `
        -Summary ("Retorno {0} - {1}" -f $rc, $descricao) -Pairs $pares

    if ($ok) {
        Write-Log OK "DISM $Op concluido (codigo $rc)."
        Add-CompartDiskFinding -Severity OK -Area 'Imagem do Windows' -Message "DISM $Op concluido com sucesso."
        if ($reinicio) {
            Set-RepairResult 'WARN' 'reinicio necessario apos DISM'
            Add-CompartDiskFinding -Severity WARN -Area 'Imagem do Windows' `
                -Message "DISM $Op exige reinicio para finalizar a operacao." `
                -Recommendation 'Reiniciar antes de executar o SFC ou novas manutencoes.'
        }
        Set-RepairEtapa -Nome "DISM $Op" -Ok $true -Critico $false -Detalhe $descricao
        return
    }

    # Falha: o reparo nao aconteceu. Antes isto era sempre WARN, e o modulo
    # devolvia "atencao" ao Launcher para uma imagem que continua corrompida.
    if ($opDeReparo) {
        Set-RepairResult 'ERROR' "DISM RestoreHealth falhou com codigo $rc"
        Write-Log ERR "DISM $Op falhou (codigo $rc): $descricao"
        Add-CompartDiskFinding -Severity CRIT -Area 'Imagem do Windows' `
            -Message "DISM $Op nao concluiu o reparo (codigo $rc): $descricao" `
            -Recommendation "Consultar $dismLog. Sem acesso ao Windows Update, informar uma fonte WIM/ESD local com /Source. A imagem permanece no estado anterior."
    } else {
        Set-RepairResult 'WARN' "DISM $Op retornou codigo $rc"
        Write-Log WARN "DISM $Op retornou codigo ${rc}: $descricao"
        Add-CompartDiskFinding -Severity WARN -Area 'Imagem do Windows' `
            -Message "DISM $Op nao concluiu o diagnostico (codigo $rc): $descricao" `
            -Recommendation "Consultar $dismLog. O estado da imagem permanece desconhecido nesta execucao."
    }
    Set-RepairEtapa -Nome "DISM $Op" -Ok $false -Critico $opDeReparo -Detalhe $descricao
}

function Invoke-ComponentStore {
    Write-Log INFO 'Analisando o armazenamento de componentes (WinSxS)...'

    # Dism.exe era invocado sem verificacao: numa maquina sem ele, o operador de
    # chamada lancava excecao e a acao caia no catch global como falha nao
    # tratada, em vez de ser reportada como capacidade ausente.
    if (-not (Test-Path -LiteralPath $dismExe)) {
        Write-Log ERR 'Dism.exe nao localizado: a analise do armazenamento de componentes nao pode ser executada.'
        Add-CompartDiskSection -Title 'Armazenamento de componentes' -Status CRIT -Summary 'Dism.exe indisponivel'
        Add-CompartDiskFinding -Severity CRIT -Area 'Imagem do Windows' `
            -Message 'Dism.exe nao localizado: a analise do WinSxS nao pode ser executada.' `
            -Recommendation 'Componente nativo ausente: avaliar a integridade da instalacao do Windows.'
        Set-RepairResult 'ERROR' 'Dism.exe ausente'
        Set-RepairEtapa -Nome 'AnalyzeComponentStore' -Ok $false -Critico $true -Detalhe 'Dism.exe ausente'
        return
    }

    & $dismExe /Online /Cleanup-Image /AnalyzeComponentStore
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = -1 }
    $ok = ($rc -eq 0 -or $rc -eq 3010)
    $descricao = Get-DismCodigoTexto -Codigo $rc

    # A medicao do WinSxS e deliberadamente informativa: o diretorio e formado
    # majoritariamente por hardlinks, e a soma dos tamanhos NAO corresponde ao
    # espaco fisico ocupado. Ela nunca decide o status da secao.
    $tam = Get-CompartDiskFolderSize -Path (Join-Path $env:SystemRoot 'WinSxS')
    $bytes = 0; $arquivos = 0
    if ($null -ne $tam) {
        try { $bytes = [long]$tam.Bytes } catch { $bytes = 0 }
        try { $arquivos = [int]$tam.Files } catch { $arquivos = 0 }
    }

    Add-CompartDiskSection -Title 'Armazenamento de componentes' -Status $(if ($ok) { 'INFO' } else { 'WARN' }) `
        -Summary ("Analise retornou {0}" -f $rc) -Pairs ([ordered]@{
            'Codigo de analise'         = $rc
            'Interpretacao'             = $descricao
            'WinSxS (tamanho aparente)' = (ConvertTo-CompartDiskSize $bytes)
            'Arquivos'                  = $arquivos
            'Observacao'                = 'O tamanho aparente inclui hardlinks e NAO reflete o espaco fisico ocupado. Use o relatorio do proprio DISM para o tamanho real.'
        })
    Write-Log INFO 'Nota: o tamanho aparente do WinSxS inclui hardlinks e nao reflete o espaco real ocupado.'

    # Antes, esta funcao encerrava sempre com Write-Log OK e status INFO, mesmo
    # quando o DISM falhava: o modulo devolvia OK ao Launcher para uma analise
    # que nao aconteceu.
    if ($ok) {
        Write-Log OK 'Analise do armazenamento de componentes concluida.'
        Add-CompartDiskFinding -Severity INFO -Area 'Imagem do Windows' `
            -Message 'Analise do armazenamento de componentes concluida.' `
            -Recommendation 'A limpeza do WinSxS pertence ao modulo Debloat (acao Components).'
        Set-RepairEtapa -Nome 'AnalyzeComponentStore' -Ok $true -Critico $false -Detalhe $descricao
    } else {
        Write-Log WARN "AnalyzeComponentStore retornou ${rc}: $descricao"
        Add-CompartDiskFinding -Severity WARN -Area 'Imagem do Windows' `
            -Message "A analise do armazenamento de componentes nao concluiu (codigo $rc): $descricao" `
            -Recommendation 'Consultar o log do DISM. A medicao do WinSxS exibida e apenas do sistema de arquivos e nao substitui a analise.'
        Set-RepairResult 'WARN' "AnalyzeComponentStore retornou $rc"
        Set-RepairEtapa -Nome 'AnalyzeComponentStore' -Ok $false -Critico $false -Detalhe $descricao
    }
}

function Resolve-RepairVolume {
    <# Normaliza e VALIDA a unidade antes de qualquer operacao de disco.

       Antes, a normalizacao era 'C:'.TrimEnd('\').TrimEnd(':') e nada mais:
       -Drive '' produzia cadeia vazia, -Drive 'CC' passava adiante, e o valor
       seguia direto para Repair-Volume e para 'fsutil dirty set'. Marcar o
       volume errado como sujo forca um CHKDSK completo no proximo boot. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Valor)
    $out = [pscustomobject]@{ Ok = $false; Letra = ''; Raiz = ''; Sistema = ''; Detalhe = '' }

    $t = "$Valor".Trim().Trim('"').Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { $out.Detalhe = 'Nenhuma unidade informada.'; return $out }
    $t = $t.TrimEnd('\').TrimEnd(':')
    if ($t -notmatch '^[A-Za-z]$') {
        $out.Detalhe = ("Unidade invalida: '{0}'. Informe uma unica letra de unidade, por exemplo C ou C:." -f $Valor)
        return $out
    }
    $letra = $t.ToUpperInvariant()
    $raiz  = "${letra}:\"

    if (-not (Test-Path -LiteralPath $raiz)) {
        $out.Detalhe = ("A unidade {0}: nao existe ou nao esta acessivel." -f $letra)
        return $out
    }

    # Tipo de volume: dirty bit e CHKDSK sao conceitos de NTFS/ReFS. Marcar um
    # volume FAT ou de rede nao produz o efeito pretendido.
    $sistema = ''
    try {
        $vol = Get-CompartDiskCim -Class Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $letra)
        $v = @($vol) | Select-Object -First 1
        if ($v) {
            $sistema = "$($v.FileSystem)"
            $tipo = 0
            try { $tipo = [int]$v.DriveType } catch { $tipo = 0 }
            if ($tipo -eq 4) { $out.Detalhe = ("A unidade {0}: e um recurso de rede: CHKDSK nao se aplica." -f $letra); return $out }
            if ($tipo -eq 5) { $out.Detalhe = ("A unidade {0}: e uma midia optica: CHKDSK nao se aplica." -f $letra); return $out }
        }
    } catch {
        Write-Log DEBUG "Tipo do volume ${letra}: indeterminado: $($_.Exception.Message)" -NoConsole
    }

    $out.Ok = $true; $out.Letra = $letra; $out.Raiz = $raiz; $out.Sistema = $sistema
    $out.Detalhe = 'Unidade validada.'
    return $out
}

function Get-VolumeSujo {
    <# Le o dirty bit atual. E a confirmacao real do agendamento: 'fsutil dirty
       set' retornar 0 nao prova que o volume ficou marcado. Devolve $true,
       $false ou $null (indeterminado). #>
    param([Parameter(Mandatory)][string]$Letra)
    $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    if (-not (Test-Path -LiteralPath $fsutil)) { return $null }
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $fsutil -Arguments @('dirty', 'query', "${Letra}:") -TimeoutSeconds 30
    } -Activity "fsutil dirty query ${Letra}:" -Silent
    if (-not $r.Success -or $null -eq $r.Value) { return $null }

    # A saida e localizada, mas o par "is/nao ... Dirty" mantem a palavra Dirty
    # em qualquer idioma do Windows. O criterio negativo vem primeiro porque
    # "is NOT Dirty" tambem contem "Dirty".
    $txt = "$($r.Value.StdOut)"
    if ($txt -match '(?i)\bnot\s+dirty\b|\bnao\s+esta\s+suja|\bnao\s+esta\s+sujo') { return $false }
    if ($txt -match '(?i)\bdirty\b|\bsuj[ao]\b') { return $true }
    return $null
}

function Register-ChkdskScan {
    param([string]$Volume = 'C:', [switch]$Forcar)

    $alvo = Resolve-RepairVolume -Valor $Volume
    if (-not $alvo.Ok) {
        Write-Log ERR ("Verificacao de disco nao executada: {0}" -f $alvo.Detalhe)
        Add-CompartDiskSection -Title 'Verificacao de disco' -Status CRIT -Summary 'Unidade invalida' `
            -Pairs ([ordered]@{ 'Valor informado' = $Volume; 'Motivo' = $alvo.Detalhe })
        Add-CompartDiskFinding -Severity CRIT -Area 'Disco' `
            -Message ("Verificacao de disco nao executada: {0}" -f $alvo.Detalhe) `
            -Recommendation 'Informar uma unidade local valida em -Drive, por exemplo C:. Nenhuma alteracao foi feita.'
        Set-RepairResult 'ERROR' 'unidade invalida'
        Set-RepairEtapa -Nome 'CHKDSK' -Ok $false -Critico $true -Detalhe $alvo.Detalhe
        return
    }
    $letra = $alvo.Letra
    Write-Log INFO "Verificando o volume ${letra}: (sistema de arquivos: $(if ($alvo.Sistema) { $alvo.Sistema } else { 'n/d' }))..."

    # ------------------------------------------------- 1. verificacao ONLINE
    # Nao altera nada. E o que decide se o reparo offline e mesmo necessario.
    $scanEstado = 'nao executado'
    $scanOk     = $false
    $precisaReparo = $null   # $true, $false ou $null (inconclusivo)

    if (Test-CompartDiskCommand 'Repair-Volume') {
        $r = Invoke-SafeCommand { Repair-Volume -DriveLetter $letra -Scan -ErrorAction Stop } -Activity "Repair-Volume -Scan $letra"
        if ($r.Success) {
            $scanOk = $true
            $scanEstado = "$($r.Value)"
            Write-Log OK "Varredura online concluida: $scanEstado"
            if ($scanEstado -eq 'NoErrorsFound') {
                $precisaReparo = $false
                Add-CompartDiskFinding -Severity OK -Area 'Disco' -Message "Volume ${letra}: sem erros de sistema de arquivos."
            } else {
                $precisaReparo = $true
                Add-CompartDiskFinding -Severity WARN -Area 'Disco' -Message "Repair-Volume reportou '$scanEstado' em ${letra}:" -Recommendation 'Agendar reparo offline no proximo boot.'
                Set-RepairResult 'WARN' "volume ${letra}: com erros"
            }
        } else {
            # Antes, a falha do Repair-Volume era ignorada por completo: nenhum
            # log, nenhum finding, nenhum efeito no resultado do modulo.
            $scanEstado = 'falhou'
            Write-Log WARN "A varredura online do volume ${letra}: nao pode ser concluida." -ErrorRecord $r.Error
            Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
                -Message ("A varredura online do volume {0}: nao pode ser concluida: {1}" -f $letra, $(if ($r.Error) { $r.Error.Exception.Message } else { 'motivo nao identificado' })) `
                -Recommendation 'O estado do sistema de arquivos permanece desconhecido nesta execucao.'
            Set-RepairResult 'WARN' 'varredura online falhou'
        }
    } else {
        $scanEstado = 'cmdlet indisponivel'
        Write-Log WARN 'Repair-Volume indisponivel nesta sessao: a verificacao online foi pulada.'
        Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
            -Message 'O cmdlet Repair-Volume nao esta disponivel: a verificacao online nao pode ser executada.' `
            -Recommendation 'O agendamento offline continua disponivel, porem sem diagnostico previo.'
        Set-RepairResult 'WARN' 'Repair-Volume indisponivel'
    }

    # ------------------------------------------- 2. estado atual do dirty bit
    $sujoAntes = Get-VolumeSujo -Letra $letra
    if ($sujoAntes -eq $true) {
        # Idempotencia: o volume ja esta marcado, reexecutar nao acrescenta nada.
        Write-Log INFO "O volume ${letra}: ja esta marcado para verificacao no proximo reinicio."
    }

    # ------------------------------------------------- 3. decisao do reparo
    # Marcar o dirty bit forca um CHKDSK completo no proximo boot, que pode
    # levar horas em disco grande. So se faz isso quando ha motivo: erro
    # confirmado, diagnostico inconclusivo ou pedido explicito por -Forcar.
    # Antes, o volume era marcado incondicionalmente, mesmo quando a varredura
    # acabara de confirmar que nao havia erro algum.
    $deveAgendar = $Forcar -or ($precisaReparo -ne $false)
    $agendado = ($sujoAntes -eq $true)
    $motivoDecisao = ''

    if (-not $deveAgendar) {
        $motivoDecisao = 'Varredura online nao encontrou erros: reparo offline desnecessario.'
        Write-Log OK "Volume ${letra}: integro. Nenhum reparo offline foi agendado."
    }
    elseif ($agendado) {
        $motivoDecisao = 'O volume ja estava marcado para verificacao.'
    }
    else {
        $motivoDecisao = $(if ($Forcar) { 'Agendamento solicitado explicitamente (-Forcar).' }
                           elseif ($precisaReparo -eq $true) { 'A varredura online encontrou erros.' }
                           else { 'A varredura online foi inconclusiva: agendado por precaucao.' })
        $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
        if (-not (Test-Path -LiteralPath $fsutil)) {
            Write-Log ERR 'fsutil.exe nao localizado: nao ha como agendar a verificacao.'
            Set-RepairResult 'ERROR' 'fsutil ausente'
        } else {
            $r = Invoke-SafeCommand {
                Invoke-NativeCommand -FilePath $fsutil -Arguments @('dirty', 'set', "${letra}:") -TimeoutSeconds 30
            } -Activity "Marcar volume ${letra}: para verificacao"
            $rcSet = $(if ($r.Success -and $null -ne $r.Value) { [int]$r.Value.ExitCode } else { -1 })
            # "o comando retornou 0" nao e prova de agendamento: o estado e
            # reconsultado. Este era exatamente o ponto em que o modulo
            # declarava "CHKDSK agendado" sem ter confirmado nada.
            $sujoDepois = Get-VolumeSujo -Letra $letra
            if ($sujoDepois -eq $true) {
                $agendado = $true
            } elseif ($rcSet -eq 0 -and $null -eq $sujoDepois) {
                $motivoDecisao += ' O comando retornou sucesso, porem o estado nao pode ser reconsultado.'
                Set-RepairResult 'WARN' 'agendamento nao confirmado'
            } else {
                Set-RepairResult 'ERROR' 'agendamento nao efetivado'
            }
        }
    }

    # ------------------------------------------------------ 4. relatorio
    $agendamentoTexto = $(if ($agendado) { 'Sim' }
                          elseif (-not $deveAgendar) { 'Nao necessario' }
                          else { 'NAO confirmado' })
    $status = 'OK'
    if ($precisaReparo -eq $true) { $status = 'WARN' }
    if ($deveAgendar -and -not $agendado) { $status = 'CRIT' }

    Add-CompartDiskSection -Title 'Verificacao de disco' -Status $status `
        -Summary ("Volume {0}: {1}" -f $letra, $scanEstado) -Pairs ([ordered]@{
            'Volume'                   = "${letra}:"
            'Sistema de arquivos'      = $(if ($alvo.Sistema) { $alvo.Sistema } else { 'n/d' })
            'Verificacao online'       = $scanEstado
            'Marcado antes'            = $(if ($null -eq $sujoAntes) { 'nao determinado' } elseif ($sujoAntes) { 'Sim' } else { 'Nao' })
            'Reparo offline agendado'  = $agendamentoTexto
            'Criterio'                 = $motivoDecisao
        })

    if ($agendado) {
        Write-Log OK "Verificacao completa agendada para ${letra}: no proximo reinicio."
        Add-CompartDiskFinding -Severity INFO -Area 'Disco' `
            -Message "CHKDSK agendado e confirmado para ${letra}: no proximo boot." `
            -Recommendation 'Reiniciar o computador quando possivel; a verificacao pode demorar.'
    } elseif ($deveAgendar) {
        Write-Log ERR "Nao foi possivel confirmar o agendamento da verificacao para ${letra}:."
        Add-CompartDiskFinding -Severity CRIT -Area 'Disco' `
            -Message "O reparo offline do volume ${letra}: era necessario e nao pode ser agendado." `
            -Recommendation 'Executar, em prompt administrativo: chkdsk C: /F. O volume permanece no estado anterior.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Disco' `
            -Message "Volume ${letra}: verificado online, sem necessidade de reparo offline." `
            -Recommendation 'Nenhuma alteracao foi feita no volume.'
    }
    Set-RepairEtapa -Nome 'CHKDSK' -Ok ($status -ne 'CRIT') -Critico ($status -eq 'CRIT') -Detalhe $scanEstado

    # Agendamento vigente, interpretado em vez de despejado no console. O
    # Write-Output anterior emitia texto no stream de sucesso do script, o que
    # contraria o padrao do projeto (Core.ps1 documenta esse cuidado).
    $chkntfs = Join-Path $env:SystemRoot 'System32\chkntfs.exe'
    if (Test-Path -LiteralPath $chkntfs) {
        $r = Invoke-SafeCommand {
            Invoke-NativeCommand -FilePath $chkntfs -Arguments @("${letra}:") -TimeoutSeconds 30
        } -Activity "chkntfs ${letra}:" -Silent
        if ($r.Success -and $null -ne $r.Value) {
            foreach ($linha in ("$($r.Value.StdOut)" -split "`r?`n")) {
                if ($linha.Trim()) { Write-Log INFO ("chkntfs: {0}" -f $linha.Trim()) }
            }
        }
    }
}

function Invoke-RepairFull {
    <# Sequencia: DISM ScanHealth -> DISM RestoreHealth -> SFC.

       Cada etapa consulta o resultado REAL da anterior. Antes, as tres eram
       chamadas em linha reta: com o Dism.exe ausente, o ScanHealth marcava
       ERROR, o RestoreHealth rebaixava para WARN e o SFC seguia como se a
       imagem tivesse sido reparada - o relatorio final descrevia um reparo
       profundo bem-sucedido sobre uma imagem que ninguem conseguiu tocar. #>
    Write-Log INFO '=== REPARO PROFUNDO: DISM ScanHealth -> RestoreHealth -> SFC ==='

    $reiniciopendenteAntes = $false
    try { $reiniciopendenteAntes = [bool](Test-CompartDiskPendingReboot) } catch { $reiniciopendenteAntes = $false }
    if ($reiniciopendenteAntes) {
        # Com reinicio pendente o DISM costuma recusar-se a operar e o SFC pode
        # abortar. Vale avisar ANTES de consumir dezenas de minutos.
        Write-Log WARN 'Ha um reinicio pendente: as etapas podem ser recusadas pelo Windows.'
        Add-CompartDiskFinding -Severity WARN -Area 'Sistema' `
            -Message 'Reparo profundo iniciado com reinicio pendente: as etapas podem ser recusadas pelo servico de manutencao.' `
            -Recommendation 'Reiniciar e repetir o reparo caso alguma etapa nao conclua.'
        Set-RepairResult 'WARN' 'reinicio pendente antes do reparo'
    }

    # ---------------------------------------------------------- 1. ScanHealth
    Invoke-Dism -Op ScanHealth
    $scan = $script:UltimaEtapa

    # ------------------------------------------------------- 2. RestoreHealth
    # Executado quando o scan apontou problema OU quando o scan nao conseguiu
    # concluir (nao saber e motivo suficiente para tentar reparar). Quando o
    # scan confirma imagem integra, o RestoreHealth e pulado: repeti-lo custa
    # dezenas de minutos e nao tem o que reparar.
    $imagemIntegra = ($scan.Ok -and $scan.Detalhe -eq 'Healthy')
    if ($imagemIntegra) {
        Write-Log INFO 'ScanHealth confirmou imagem integra: RestoreHealth dispensado nesta execucao.'
        Add-CompartDiskSection -Title 'DISM RestoreHealth' -Status OK -Summary 'Dispensado: imagem integra' `
            -Pairs ([ordered]@{
                'Executado' = 'Nao'
                'Motivo'    = 'ScanHealth confirmou que a imagem esta integra; o reparo seria redundante.'
            })
        Add-CompartDiskFinding -Severity OK -Area 'Imagem do Windows' `
            -Message 'RestoreHealth dispensado: a verificacao anterior confirmou imagem integra.'
        Set-RepairEtapa -Nome 'DISM RestoreHealth' -Ok $true -Critico $false -Detalhe 'dispensado'
    } else {
        Invoke-Dism -Op RestoreHealth
    }
    $restore = $script:UltimaEtapa

    # ------------------------------------------------------------------ 3. SFC
    # O SFC roda mesmo apos falha do RestoreHealth: ele repara a partir do
    # armazenamento local e ainda pode resolver parte do problema. O que NAO
    # pode acontecer e a sequencia ser apresentada como integralmente bem
    # sucedida quando a etapa da qual o SFC depende falhou.
    $restoreFalhouCritico = ($restore.Critico -and -not $restore.Ok)
    if ($restoreFalhouCritico) {
        Write-Log WARN 'RestoreHealth nao concluiu: o SFC sera executado, porem sem a imagem de origem reparada.'
    }
    Invoke-Sfc
    $sfc = $script:UltimaEtapa

    # ----------------------------------------------------- 4. consolidacao
    $etapas = @(
        [pscustomobject]@{ Etapa = 'DISM ScanHealth';    Concluida = $(if ($scan.Ok) { 'Sim' } else { 'Nao' }); Detalhe = $scan.Detalhe }
        [pscustomobject]@{ Etapa = 'DISM RestoreHealth'; Concluida = $(if ($restore.Ok) { 'Sim' } else { 'Nao' }); Detalhe = $restore.Detalhe }
        [pscustomobject]@{ Etapa = 'System File Checker';Concluida = $(if ($sfc.Ok) { 'Sim' } else { 'Nao' }); Detalhe = $sfc.Detalhe }
    )
    $falhas = @($etapas | Where-Object { $_.Concluida -eq 'Nao' }).Count
    $statusSeq = 'OK'
    if ($falhas -gt 0) { $statusSeq = $(if ($restoreFalhouCritico -or -not $sfc.Ok) { 'CRIT' } else { 'WARN' }) }

    Add-CompartDiskSection -Title 'Reparo profundo: sequencia' -Status $statusSeq -Rows $etapas `
        -Summary ("{0} de 3 etapa(s) concluida(s)" -f (3 - $falhas)) -Pairs ([ordered]@{
            'Etapas concluidas'   = (3 - $falhas)
            'Etapas nao concluidas' = $falhas
            'Reinicio pendente no inicio' = $(if ($reiniciopendenteAntes) { 'Sim' } else { 'Nao' })
        })

    if ($falhas -gt 0) {
        Add-CompartDiskFinding -Severity $(if ($statusSeq -eq 'CRIT') { 'CRIT' } else { 'WARN' }) -Area 'Reparo' `
            -Message ("O reparo profundo nao concluiu todas as etapas: {0} de 3 falharam." -f $falhas) `
            -Recommendation 'As etapas concluidas permanecem aplicadas. Consultar as secoes individuais para a etapa exata e repetir apos resolver a causa.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Reparo' `
            -Message 'Reparo profundo concluido: as tres etapas foram executadas e validadas.'
    }

    # Reinicio pendente APOS as operacoes: o proprio reparo pode te-lo criado.
    $reinicioDepois = $false
    try { $reinicioDepois = [bool](Test-CompartDiskPendingReboot) } catch { $reinicioDepois = $false }
    if ($reinicioDepois) {
        Add-CompartDiskFinding -Severity WARN -Area 'Sistema' -Message 'Ha um reinicio pendente.' -Recommendation 'Reiniciar antes de novas manutencoes.'
        Write-Log WARN 'Reinicio pendente detectado.'
        Set-RepairResult 'WARN' 'reinicio pendente'
    }
}

# ------------------------------------------------------------------------------
$codigo = $Global:CompartDisk.Exit.ERROR
try {
    if (-not (Start-CompartDiskModule -Name 'Repair' -Action $Action -RequireAdmin -Quiet:$Quiet)) {
        # Antes havia um 'exit' direto aqui. Em PowerShell o exit dispara o
        # finally, e o finally persistia $result ainda em 'OK': o modulo saia
        # com codigo de erro enquanto gravava estado OK no state_Repair_*.json,
        # e o relatorio consolidado do Report.ps1 nao via a falha.
        Set-RepairResult 'ERROR' 'privilegios administrativos ausentes'
    } else {
        switch ($Action) {
            'Sfc'       { Invoke-Sfc }
            'Dism'      { Invoke-Dism -Op RestoreHealth }
            'Scan'      { Invoke-Dism -Op ScanHealth }
            'Component' { Invoke-ComponentStore }
            'Chkdsk'    { Register-ChkdskScan -Volume $Drive }
            'Full'      { Invoke-RepairFull }
        }
    }
} catch {
    Set-RepairResult 'ERROR' 'excecao nao tratada'
    Write-Log ERR "Falha nao tratada no modulo Repair (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Reparo' -Message "Excecao no modulo: $($_.Exception.Message)" `
        -Recommendation 'Consultar o log detalhado da sessao. Operacoes ja concluidas antes da falha permanecem aplicadas.'
} finally {
    $codigo = Stop-CompartDiskModule -Result $script:result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$script:result] }
}
exit ([int]$codigo)
