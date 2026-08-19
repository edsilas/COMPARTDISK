<#
 COMPARTDISK 1.4.4 - Defender.ps1
 Desenvolvido por Edsilas
 Acoes: Status | Update | QuickScan | FullScan | CustomScan | Exclusions | History
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Update', 'QuickScan', 'FullScan', 'CustomScan', 'Exclusions', 'History')]
    [string]$Action = 'Status',
    [string]$Path = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Set-DefenderResult {
    <# O resultado escala e nunca regride: sem isso o estado final seria o da ultima
       verificacao, e uma checagem saudavel no fim apagaria um problema anterior. #>
    param([ValidateSet('OK', 'WARN', 'ERROR')][string]$Estado)
    $peso = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }
    if ($peso[$Estado] -gt $peso["$($script:result)"]) { $script:result = $Estado }
}

function ConvertTo-DefenderTriState {
    <# Normaliza um valor booleano do Defender em tres estados EXPLICITOS.

       'Desconhecido' nao pode ser confundido com 'Nao': a leitura ausente de uma
       propriedade e a propriedade desligada exigem respostas diferentes. #>
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return 'Desconhecido' }
    $t = "$Valor".Trim()
    if ($t -eq '') { return 'Desconhecido' }
    if ($t -in @('True', 'Sim', '1'))  { return 'Sim' }
    if ($t -in @('False', 'Nao', '0')) { return 'Nao' }
    return 'Desconhecido'
}

function Get-DefenderContext {
    <# Contextualiza o estado do Defender a partir dos produtos registrados no
       Windows Security Center e do AMRunningMode.

       Sem isso, um computador com antivirus de terceiros ativo - configuracao
       legitima e comum - era reportado como 'Protecao em tempo real DESABILITADA'
       com severidade CRIT e a recomendacao de reativa-la: falso critico. #>
    param([AllowNull()][object]$Status, [object[]]$Produtos)

    $out = [pscustomobject]@{
        Modo = 'desconhecido'; Terceiros = @(); TerceirosTexto = ''; Passivo = $false
    }
    $terceiros = @()
    foreach ($p in (@($Produtos) | Where-Object { $null -ne $_ })) {
        if ("$($p.Ativo)" -eq 'Sim' -and "$($p.Produto)" -notmatch '(?i)defender') { $terceiros += "$($p.Produto)" }
    }
    $out.Terceiros = @($terceiros)
    $out.TerceirosTexto = (@($terceiros) -join ', ')

    $modoExec = ''
    if ($Status) { $modoExec = "$($Status['Modo passivo'])".Trim() }
    # AMRunningMode publica 'Passive Mode' / 'EDR Block Mode' quando outro produto
    # assume a protecao em tempo real. 'Normal' significa Defender no comando.
    if ($modoExec -match '(?i)passive|edr block') { $out.Passivo = $true }

    if ($out.Passivo) { $out.Modo = 'passivo' }
    elseif (@($terceiros).Count -gt 0) { $out.Modo = 'terceiros ativos' }
    elseif ($modoExec -match '(?i)normal') { $out.Modo = 'ativo' }
    return $out
}

function Assert-Defender {
    if (-not (Import-CompartDiskModule 'Defender')) {
        Write-Log ERR 'Modulo Defender indisponivel neste sistema.'
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message 'Modulo PowerShell do Defender indisponivel.' -Recommendation 'Verificar se ha antivirus de terceiros substituindo o Defender.'
        return $false
    }
    try {
        $null = Get-MpComputerStatus -ErrorAction Stop
        return $true
    } catch {
        Write-Log WARN 'Servico do Defender inativo ou substituido por outro antivirus.'
        return $false
    }
}

function Show-DefenderStatus {
    $av = Get-CompartDiskAntivirusProducts
    if ($av.Count -gt 0) {
        Write-Color ''
        Write-Color '  Produtos de seguranca registrados no Windows:' -Color White
        $av | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
        Add-CompartDiskSection -Title 'Produtos antivirus' -Status INFO -Rows $av
        foreach ($p in $av) {
            if ($p.Ativo -eq 'Sim' -and $p.Atualizado -eq 'Nao') {
                Write-Log WARN "$($p.Produto) esta ativo mas com assinaturas desatualizadas."
                Add-CompartDiskFinding -Severity WARN -Area 'Antivirus' -Message "$($p.Produto) esta ativo mas com assinaturas desatualizadas." -Recommendation 'Atualizar as definicoes do produto.'
                Set-DefenderResult 'WARN'
            }
        }
    }

    $st = Get-CompartDiskDefenderStatus
    if (-not $st) {
        Write-Log WARN 'Nao foi possivel obter o status do Microsoft Defender.'
        Set-DefenderResult 'WARN'
        return
    }

    Write-Color ''
    foreach ($k in $st.Keys) {
        $v = "$($st[$k])"
        $cor = 'Gray'
        if ($v -eq 'False') { $cor = 'Yellow' }
        if ($v -eq 'True')  { $cor = 'Green' }
        Write-CompartDiskKeyValue $k $st[$k] -Color $cor -Pad 30
    }
    $ctx = Get-DefenderContext -Status $st -Produtos $av
    $rtp = ConvertTo-DefenderTriState $st['Protecao em tempo real']

    $status = switch ($rtp) { 'Sim' { 'OK' } 'Nao' { $(if ($ctx.Passivo -or $ctx.Terceiros.Count -gt 0) { 'INFO' } else { 'CRIT' }) } default { 'WARN' } }
    Add-CompartDiskSection -Title 'Microsoft Defender' -Status $status -Pairs $st `
        -Summary ("Modo: {0}{1}" -f $ctx.Modo, $(if ($ctx.TerceirosTexto) { " | terceiros: $($ctx.TerceirosTexto)" } else { '' }))

    if ($rtp -eq 'Sim') {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Protecao em tempo real ativa.'
    } elseif ($rtp -eq 'Nao') {
        if ($ctx.Passivo -or $ctx.Terceiros.Count -gt 0) {
            # Defender em modo passivo com outro antivirus ativo e configuracao
            # legitima do Windows, nao falha: quem protege em tempo real e o outro
            # produto. Antes, este caminho produzia CRIT e mandava reativar o
            # Defender, o que criaria dois antivirus disputando a mesma funcao.
            $quem = $(if ($ctx.TerceirosTexto) { $ctx.TerceirosTexto } else { 'outro produto de seguranca' })
            Write-Log INFO ("Defender em modo passivo: a protecao em tempo real esta a cargo de {0}." -f $quem)
            Add-CompartDiskFinding -Severity INFO -Area 'Defender' `
                -Message ("Microsoft Defender em modo passivo: a protecao em tempo real e exercida por {0}." -f $quem) `
                -Recommendation 'Condicao normal quando existe antivirus de terceiros ativo. Confirmar que o produto ativo esta atualizado e funcional.'
        } else {
            Write-Log WARN 'Protecao em tempo real do Defender DESABILITADA e nenhum outro antivirus ativo foi identificado.'
            Add-CompartDiskFinding -Severity CRIT -Area 'Defender' -Message 'Protecao em tempo real desabilitada e sem antivirus de terceiros ativo.' -Recommendation 'Reativar em Seguranca do Windows > Protecao contra virus e ameacas.'
            Set-DefenderResult 'WARN'
        }
    } else {
        # Ausencia de leitura NAO e protecao ativa. Antes, qualquer valor que nao
        # fosse exatamente 'False' - inclusive 'n/d', vazio ou chave ausente - caia
        # no ramo else e publicava "Protecao em tempo real ativa" como achado OK:
        # falso negativo no controle mais importante do modulo.
        Write-Log WARN 'Estado da protecao em tempo real nao pode ser determinado.'
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' `
            -Message 'Estado da protecao em tempo real nao verificado: a propriedade nao foi publicada pelo Defender.' `
            -Recommendation 'Conferir em Seguranca do Windows; validar o provedor WMI do Defender e o servico WinDefend.'
        Set-DefenderResult 'WARN'
    }

    # Tamper Protection e contexto, nao veredito: quando ativa, alteracoes de
    # configuracao do Defender podem ser recusadas pelo proprio Windows.
    $tp = ConvertTo-DefenderTriState $st['Tamper Protection']
    if ($tp -eq 'Nao') {
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' `
            -Message 'Tamper Protection desativada: as configuracoes do Defender podem ser alteradas por outros programas.' `
            -Recommendation 'Reativar em Seguranca do Windows > Protecao contra virus e ameacas > Gerenciar configuracoes.'
        Set-DefenderResult 'WARN'
    }

    # Idade das assinaturas em tres estados. Antes, "$idade = 0" era tanto o valor
    # inicial quanto o resultado de uma conversao que falhava no catch vazio, e o
    # ramo 'elseif ($idade -gt 0)' descartava justamente o melhor caso - assinatura
    # atualizada HOJE - sem gerar evidencia nenhuma.
    $idade = $null
    $bruto = "$($st['Assinaturas idade (d)'])".Trim()
    if ($bruto -match '^\d+$') { $idade = [int]$bruto }

    if ($null -eq $idade) {
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' `
            -Message ("Idade das assinaturas nao verificada (valor publicado: '{0}')." -f $(if ($bruto) { $bruto } else { 'ausente' })) `
            -Recommendation 'Conferir a data das definicoes em Seguranca do Windows.'
        Set-DefenderResult 'WARN'
    } elseif ($idade -gt 7) {
        Write-Log WARN "Assinaturas do Defender com $idade dias de idade."
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message "Assinaturas com $idade dias de idade." -Recommendation 'Executar a atualizacao de definicoes.'
        Set-DefenderResult 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message ("Assinaturas atualizadas ({0} dia(s))." -f $idade)
    }
    # EVIDENCIA: o log encerrava com "Status do Defender coletado." e
    # Resultado=WARN, sem nenhum motivo gravado no arquivo de log.
    if ($script:result -eq 'OK') {
        Write-Log OK 'Status do Defender coletado: nenhuma condicao de atencao encontrada.'
    } else {
        Write-Log WARN 'Status do Defender coletado com condicao(oes) de atencao registrada(s) acima.'
    }
}

function Update-DefenderSignatures {
    Write-Log INFO 'Atualizando definicoes do Microsoft Defender...'

    # Estado ANTES: sem ele nao ha como afirmar que a atualizacao mudou alguma coisa.
    $antesVersao = 'n/d'
    $antesData   = $null
    $ar = Invoke-SafeCommand { Get-MpComputerStatus -ErrorAction Stop } -Activity 'Get-MpComputerStatus (pre-atualizacao)' -Silent
    if ($ar.Success -and $null -ne $ar.Value) {
        $antesVersao = "$($ar.Value.AntivirusSignatureVersion)"
        try { $antesData = $ar.Value.AntivirusSignatureLastUpdated } catch { $antesData = $null }
    }

    # Invoke-WithRetry RELANCA na ultima tentativa: uma falha esperada (sem rede,
    # servico de atualizacao parado, bloqueio por diretiva) subia ao catch global e
    # virava "Falha nao tratada no modulo" com CRIT generico, sem diagnostico.
    $up = Invoke-SafeCommand {
        Invoke-WithRetry -Activity 'Update-MpSignature' -Retries 3 -DelaySeconds 3 -Exponential -ScriptBlock {
            Update-MpSignature -ErrorAction Stop
            $true
        }
    } -Activity 'Atualizacao de definicoes' -Silent

    if (-not $up.Success) {
        $diag = Get-DefenderScanFailureReason -ErrorRecord $up.Error
        Write-Log ERR ('A atualizacao de definicoes NAO foi concluida: {0}' -f $diag.Mensagem)
        Add-CompartDiskSection -Title 'Atualizacao de definicoes' -Status CRIT -Pairs ([ordered]@{
            'Situacao'        = 'nao concluida'
            'Causa'           = $diag.Causa
            'Detalhe'         = $diag.Mensagem
            'Versao anterior' = $antesVersao
        }) -Summary 'Atualizacao nao concluida'
        Add-CompartDiskFinding -Severity CRIT -Area 'Defender' `
            -Message ('A atualizacao de definicoes do Defender nao foi concluida: {0}' -f $diag.Mensagem) `
            -Recommendation $(if ($diag.Recomendacao) { $diag.Recomendacao } else { 'Verificar conectividade e o servico do Windows Update antes de repetir.' })
        Set-DefenderResult 'ERROR'
        return
    }

    # Mesma classe de defeito do FullScan: chamada nua a Get-MpComputerStatus
    # propaga CimException e derruba o modulo com "falha nao tratada".
    $sr = Invoke-SafeCommand { Get-MpComputerStatus -ErrorAction Stop } -Activity 'Get-MpComputerStatus (pos-atualizacao)' -Silent
    if (-not $sr.Success -or $null -eq $sr.Value) {
        Write-Log WARN 'Definicoes atualizadas, porem a versao resultante nao pode ser confirmada.'
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message 'A atualizacao de definicoes foi aceita, mas a versao resultante nao pode ser lida.' -Recommendation 'Confirmar o estado do provedor WMI do Defender antes de considerar as assinaturas atualizadas.'
        Set-DefenderResult 'WARN'
        return
    }
    $st = $sr.Value
    $depoisVersao = "$($st.AntivirusSignatureVersion)"
    $depoisData   = $null
    try { $depoisData = $st.AntivirusSignatureLastUpdated } catch { $depoisData = $null }

    # "Update-MpSignature nao lancou" nao prova que a assinatura mudou: quando ja
    # esta na versao mais recente, o comando devolve sucesso sem alterar nada.
    $mudou = ($depoisVersao -ne $antesVersao) -or ($null -ne $depoisData -and $null -ne $antesData -and $depoisData -ne $antesData)
    $idade = $null
    try { if ($null -ne $st.AntivirusSignatureAge) { $idade = [int]$st.AntivirusSignatureAge } } catch { $idade = $null }

    Add-CompartDiskSection -Title 'Atualizacao de definicoes' -Status OK -Pairs ([ordered]@{
        'Situacao'          = $(if ($mudou) { 'definicoes atualizadas' } else { 'ja estava na versao corrente' })
        'Versao anterior'   = $antesVersao
        'Versao atual'      = $depoisVersao
        'Atualizadas em'    = "$depoisData"
        'Idade (dias)'      = $(if ($null -ne $idade) { $idade } else { 'n/d' })
    }) -Summary $(if ($mudou) { "Atualizado para $depoisVersao" } else { "Mantido em $depoisVersao (ja corrente)" })

    if ($mudou) {
        Write-Log OK "Definicoes atualizadas: $antesVersao -> $depoisVersao ($depoisData)."
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message "Assinaturas atualizadas de $antesVersao para $depoisVersao."
    } else {
        Write-Log OK "Definicoes ja estavam na versao corrente ($depoisVersao)."
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message "Assinaturas ja estavam na versao corrente ($depoisVersao)."
    }
    # Comando aceito e versao inalterada com assinatura velha nao e sucesso pleno.
    if (-not $mudou -and $null -ne $idade -and $idade -gt 7) {
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' `
            -Message ("A atualizacao foi aceita, mas as definicoes continuam com {0} dias de idade." -f $idade) `
            -Recommendation 'Verificar conectividade com o servico de atualizacao do Defender e a diretiva de origem das definicoes.'
        Set-DefenderResult 'WARN'
    }
}

function Start-DefenderScan {
    param([ValidateSet('QuickScan', 'FullScan', 'CustomScan')][string]$Tipo, [string]$Alvo)

    if ($Tipo -eq 'CustomScan') {
        if ([string]::IsNullOrWhiteSpace($Alvo) -or -not (Test-Path -LiteralPath $Alvo)) {
            Write-Log ERR "Caminho invalido para varredura personalizada: '$Alvo'"
            Set-DefenderResult 'ERROR'
            return
        }
    }

    # EVIDENCIA: no log de 13/08/2026 a acao FullScan lancou CimException a
    # partir de Start-MpScan sem tratamento, produzindo 'Falha nao tratada no
    # modulo' e ERROR sem diagnostico. A chamada passa a ser envelopada e o
    # erro, classificado.
    if ($Tipo -eq 'CustomScan') {
        Write-Log INFO "Iniciando varredura personalizada em '$Alvo'..."
        $r = Invoke-SafeCommand { Start-MpScan -ScanType CustomScan -ScanPath $Alvo -ErrorAction Stop } -Activity 'Start-MpScan (CustomScan)' -Silent
    } else {
        $nome = if ($Tipo -eq 'QuickScan') { 'rapida' } else { 'completa (pode levar horas)' }
        Write-Log INFO "Iniciando varredura $nome..."
        $r = Invoke-SafeCommand { Start-MpScan -ScanType $Tipo -ErrorAction Stop } -Activity "Start-MpScan ($Tipo)" -Silent
    }

    if (-not $r.Success) {
        $diag = Get-DefenderScanFailureReason -ErrorRecord $r.Error
        Write-Log ERR ("A varredura {0} NAO pode ser iniciada: {1}" -f $Tipo, $diag.Mensagem)
        Add-CompartDiskFinding -Severity CRIT -Area 'Defender' `
            -Message ("A varredura {0} nao pode ser iniciada: {1}" -f $Tipo, $diag.Mensagem) `
            -Recommendation $diag.Recomendacao
        Add-CompartDiskSection -Title 'Varredura do Defender' -Status CRIT `
            -Pairs ([ordered]@{
                'Tipo'      = $Tipo
                'Situacao'  = 'nao iniciada'
                'Causa'     = $diag.Causa
                'Detalhe'   = $diag.Mensagem
            }) -Summary 'Varredura nao iniciada'
        Set-DefenderResult 'ERROR'
        return
    }

    # 'Start-MpScan' retorna assim que a varredura e ACEITA pelo servico. Isso
    # nao significa que ela terminou: a mensagem reflete apenas a solicitacao.
    $sr = Invoke-SafeCommand { Get-MpComputerStatus -ErrorAction Stop } -Activity 'Get-MpComputerStatus' -Silent
    $fim = 'nao disponivel'
    $emAndamento = 'n/d'
    if ($sr.Success -and $null -ne $sr.Value) {
        $st = $sr.Value
        try { $fim = "$(if ($Tipo -eq 'FullScan') { $st.FullScanEndTime } else { $st.QuickScanEndTime })" } catch { $fim = 'nao disponivel' }
        try { $emAndamento = "$($st.ScanInProgress)" } catch { $emAndamento = 'n/d' }
        if ([string]::IsNullOrWhiteSpace($fim)) { $fim = 'sem conclusao anterior registrada' }
    } else {
        Write-Log WARN 'A varredura foi solicitada, mas o status do Defender nao pode ser consultado em seguida.'
        Set-DefenderResult 'WARN'
    }

    Write-Log OK ("Varredura {0} SOLICITADA ao servico e aceita. Conclusao anterior registrada: {1}." -f $Tipo, $fim)
    Write-Log INFO 'A varredura roda em segundo plano: este modulo confirma o inicio, nao a conclusao.'
    Add-CompartDiskSection -Title 'Varredura do Defender' -Status OK `
        -Pairs ([ordered]@{
            'Tipo'                 = $Tipo
            'Situacao'             = 'solicitada e aceita pelo servico'
            'Varredura em curso'   = $emAndamento
            'Conclusao anterior'   = $fim
        }) -Summary 'Solicitacao aceita; conclusao nao verificada por este modulo'
    Add-CompartDiskFinding -Severity OK -Area 'Defender' `
        -Message ("Varredura {0} solicitada e aceita pelo servico do Defender." -f $Tipo) `
        -Recommendation 'A execucao ocorre em segundo plano. Conferir o resultado depois na acao History ou na Seguranca do Windows.'
    Show-ThreatHistory
}

function Get-DefenderScanFailureReason {
    <# Classifica a falha de inicio de varredura em vez de devolver a excecao
       crua. Cobre os casos observados em campo: CIM/WMI indisponivel, servico
       parado, Defender substituido por antivirus de terceiros e bloqueio por
       diretiva. #>
    param([AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $out = [pscustomobject]@{ Causa = 'indeterminada'; Mensagem = 'falha nao identificada'; Recomendacao = '' }
    if ($null -eq $ErrorRecord) { return $out }
    $msg = "$($ErrorRecord.Exception.Message)"
    $tipo = ''
    try { $tipo = $ErrorRecord.Exception.GetType().FullName } catch { $tipo = '' }
    $out.Mensagem = $msg

    $terceiro = ''
    try {
        $av = @(Get-CompartDiskAntivirusProducts) | Where-Object { $_.Ativo -eq 'Sim' -and "$($_.Produto)" -notmatch '(?i)defender' }
        if (@($av).Count -gt 0) { $terceiro = (@($av | ForEach-Object { $_.Produto }) -join ', ') }
    } catch {
        Write-Log DEBUG "Consulta de produtos antivirus indisponivel: $($_.Exception.Message)" -NoConsole
    }

    if ($terceiro) {
        $out.Causa = 'antivirus de terceiros ativo'
        $out.Recomendacao = ("O Microsoft Defender fica em modo passivo quando ha antivirus de terceiros ativo ({0}). Executar a varredura pelo proprio produto instalado." -f $terceiro)
        return $out
    }
    if ($tipo -like '*CimException*' -or $msg -match '(?i)WMI|CIM|provedor') {
        $out.Causa = 'provedor WMI/CIM do Defender indisponivel'
        $out.Recomendacao = 'Confirmar se o servico WinDefend esta em execucao e se o provedor WMI do Defender responde; reiniciar o computador e repetir.'
        return $out
    }
    if ($msg -match '(?i)acesso negado|denied|0x80070005') {
        $out.Causa = 'permissao insuficiente'
        $out.Recomendacao = 'Executar o Launcher como administrador e repetir a acao.'
        return $out
    }
    if ($msg -match '(?i)desabilitad|disabled|politica|policy') {
        $out.Causa = 'bloqueado por diretiva'
        $out.Recomendacao = 'A varredura foi recusada por configuracao administrativa: tratar com a equipe responsavel pela diretiva.'
        return $out
    }
    $out.Causa = 'erro do servico do Defender'
    $out.Recomendacao = 'Verificar o estado do servico WinDefend e a integridade do Microsoft Defender antes de repetir.'
    return $out
}

function Show-ThreatHistory {
    Write-Log INFO 'Consultando historico de ameacas...'
    # ThreatStatusID do Defender. Distinguir remediado de pendente e o que separa
    # "o antivirus fez o trabalho" de "ha algo a tratar agora".
    $mapaEstado = @{
        0 = 'Desconhecido'; 1 = 'Detectada (ativa)'; 2 = 'Limpa'; 3 = 'Em quarentena'
        4 = 'Removida'; 5 = 'Permitida pelo usuario'; 6 = 'Bloqueada'
        102 = 'FALHA ao colocar em quarentena'; 103 = 'FALHA ao remover'
        104 = 'FALHA ao permitir'; 105 = 'Abandonada'; 106 = 'FALHA ao bloquear'
    }
    # Estados que exigem acao agora: deteccao ainda ativa, remediacao que falhou,
    # abandono e ameaca explicitamente permitida pelo operador.
    $acionaveis = @(1, 5, 102, 103, 104, 105, 106)

    $rows = New-Object System.Collections.ArrayList
    $r = Invoke-SafeCommand { Get-MpThreatDetection -ErrorAction Stop } -Activity 'Get-MpThreatDetection'
    if ($r.Success -and $r.Value) {
        # Get-MpThreat consultado UMA vez e indexado por ThreatID. Antes era uma
        # chamada CIM por deteccao - ate 30 consultas para montar a mesma tabela.
        $catalogo = @{}
        $tr = Invoke-SafeCommand { Get-MpThreat -ErrorAction Stop } -Activity 'Get-MpThreat (catalogo)' -Silent
        if ($tr.Success -and $tr.Value) {
            foreach ($t in @($tr.Value)) {
                if ($null -eq $t) { continue }
                $catalogo["$($t.ThreatID)"] = $t
            }
        } else {
            Write-Log DEBUG 'Catalogo de ameacas indisponivel: os nomes ficarao como n/d.' -NoConsole
        }

        foreach ($d in (@($r.Value) | Sort-Object InitialDetectionTime -Descending | Select-Object -First 30)) {
            $nome = 'n/d'
            $sev  = 'n/d'
            $t = $catalogo["$($d.ThreatID)"]
            if ($t) { $nome = "$($t.ThreatName)"; $sev = "$($t.SeverityID)" }

            $cod = -1
            try { $cod = [int]$d.ThreatStatusID } catch { $cod = -1 }
            $estado = $(if ($mapaEstado.ContainsKey($cod)) { $mapaEstado[$cod] } else { "Codigo $cod" })

            [void]$rows.Add([pscustomobject]@{
                Detectado  = $d.InitialDetectionTime
                Ameaca     = $nome
                Severidade = $sev
                Estado     = $estado
                Pendente   = $(if ($acionaveis -contains $cod) { 'Sim' } else { 'Nao' })
                Recursos   = ((@($d.Resources) | Select-Object -First 2) -join '; ')
            })
        }
    }

    if (-not $r.Success) {
        # Consulta que falhou nao e historico limpo. Get-MpThreatDetection recusa em
        # modo passivo (antivirus de terceiros ativo) e com o WinDefend parado, e
        # afirmar "limpo" nesses casos e um atestado de seguranca sem base.
        Write-Log WARN 'O historico de ameacas nao pode ser consultado.'
        Add-CompartDiskFinding -Severity INFO -Area 'Defender' -Message 'Historico de ameacas nao verificado: a consulta ao Defender foi recusada.' -Recommendation 'Conferir em Seguranca do Windows > Protecao contra virus e ameacas > Historico de protecao. O Defender pode estar em modo passivo.'
        Set-DefenderResult 'WARN'
    } elseif ($rows.Count -eq 0) {
        Write-Log OK 'Nenhuma ameaca registrada no historico.'
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Historico de ameacas limpo.'
    } else {
        # Deteccao remediada e prova de que o antivirus funcionou, nao problema em
        # aberto. Antes, qualquer entrada historica gerava WARN: uma ameaca posta em
        # quarentena com sucesso meses atras mantinha a maquina em atencao para
        # sempre. O achado passa a refletir o estado ATUAL.
        $pendentes = @($rows | Where-Object { $_.Pendente -eq 'Sim' })
        $resolvidas = @($rows | Where-Object { $_.Pendente -ne 'Sim' })
        $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

        $sec = $(if (@($pendentes).Count -gt 0) { 'CRIT' } else { 'INFO' })
        Add-CompartDiskSection -Title 'Historico de ameacas' -Status $sec -Rows @($rows) `
            -Summary ("{0} deteccao(oes): {1} pendente(s), {2} ja remediada(s)" -f $rows.Count, @($pendentes).Count, @($resolvidas).Count)

        if (@($pendentes).Count -gt 0) {
            Write-Log WARN ("{0} deteccao(oes) com acao pendente no Defender." -f @($pendentes).Count)
            Add-CompartDiskFinding -Severity CRIT -Area 'Defender' `
                -Message ("{0} deteccao(oes) do Defender com acao pendente ou remediacao falha: {1}." -f @($pendentes).Count, ((@($pendentes | Select-Object -First 3).Ameaca) -join ', ')) `
                -Recommendation 'Tratar imediatamente em Seguranca do Windows > Protecao contra virus e ameacas > Historico de protecao.'
            Set-DefenderResult 'WARN'
        } else {
            Write-Log OK ("{0} deteccao(oes) no historico, todas ja remediadas pelo Defender." -f $rows.Count)
            Add-CompartDiskFinding -Severity INFO -Area 'Defender' `
                -Message ("{0} deteccao(oes) no historico do Defender, todas ja remediadas (limpa, quarentena, removida ou bloqueada)." -f $rows.Count) `
                -Recommendation 'Nenhuma acao pendente. O historico e mantido pelo Windows como registro.'
        }
    }
}

function Get-DefenderExclusionRisk {
    <# Classifica a ABRANGENCIA de uma exclusao. Uma exclusao estreita e legitima e
       comum; o que merece revisao e a que cobre area ampla ou interpretador de uso
       geral - vetores conhecidos de evasao. Classificar tudo como risco produz
       ruido e faz o operador ignorar o achado. #>
    param([Parameter(Mandatory)][ValidateSet('Caminho', 'Processo', 'Extensao', 'IP')][string]$Tipo,
          [Parameter(Mandatory)][AllowEmptyString()][string]$Valor)

    $v = "$Valor".Trim()
    if (-not $v) { return [pscustomobject]@{ Risco = 'Indeterminado'; Motivo = 'valor vazio' } }

    switch ($Tipo) {
        'Caminho' {
            $n = $v.TrimEnd('\')
            if ($n -match '^[A-Za-z]:$' -or $n -match '^[A-Za-z]:\\?\*?$') { return [pscustomobject]@{ Risco = 'Amplo'; Motivo = 'raiz de unidade inteira' } }
            # A lista e montada com guarda: Join-Path lanca quando a variavel de
            # ambiente nao existe, e o array e avaliado ANTES do teste de nulo
            # dentro do laco - um ambiente sem %SystemDrive% derrubaria a auditoria
            # inteira de exclusoes.
            $amplos = New-Object System.Collections.ArrayList
            foreach ($e in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:TEMP)) {
                if (-not [string]::IsNullOrWhiteSpace($e)) { [void]$amplos.Add("$e") }
            }
            if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) { [void]$amplos.Add(("$env:SystemDrive".TrimEnd('\') + '\Users')) }
            foreach ($amplo in $amplos) {
                if ($n -eq "$amplo".TrimEnd('\')) { return [pscustomobject]@{ Risco = 'Amplo'; Motivo = ('diretorio de sistema: {0}' -f $amplo) } }
            }
            if ($n -match '^\*' -or $n -eq '*') { return [pscustomobject]@{ Risco = 'Amplo'; Motivo = 'curinga sem raiz definida' } }
            return [pscustomobject]@{ Risco = 'Normal'; Motivo = 'caminho especifico' }
        }
        'Extensao' {
            $e = $v.TrimStart('.').ToLowerInvariant()
            if ($e -in @('exe', 'dll', 'sys', 'ps1', 'bat', 'cmd', 'vbs', 'js', 'scr', 'com', 'msi', '*')) {
                return [pscustomobject]@{ Risco = 'Amplo'; Motivo = 'extensao executavel de uso geral' }
            }
            return [pscustomobject]@{ Risco = 'Normal'; Motivo = 'extensao especifica' }
        }
        'Processo' {
            # Split explicito nos dois separadores em vez de [IO.Path]::GetFileName,
            # que depende do separador da plataforma corrente. Cobre tanto o caminho
            # completo quanto a exclusao declarada apenas pelo nome do executavel.
            $nome = (("$v" -split '[\\/]')[-1]).Trim().ToLowerInvariant()
            if ($nome -in @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe',
                            'mshta.exe', 'rundll32.exe', 'regsvr32.exe', 'msbuild.exe', 'explorer.exe')) {
                return [pscustomobject]@{ Risco = 'Amplo'; Motivo = 'interpretador ou utilitario de uso geral' }
            }
            return [pscustomobject]@{ Risco = 'Normal'; Motivo = 'processo especifico' }
        }
        default { return [pscustomobject]@{ Risco = 'Normal'; Motivo = 'endereco especifico' } }
    }
}

function Show-Exclusions {
    # Chamada nua propaga a excecao ate o catch global e vira "Excecao no modulo"
    # com CRIT generico - mesma classe de defeito ja corrigida neste arquivo para
    # Get-MpComputerStatus e Start-MpScan. Get-MpPreference recusa em modo passivo
    # e sem privilegio suficiente.
    $pr = Invoke-SafeCommand { Get-MpPreference -ErrorAction Stop } -Activity 'Get-MpPreference' -Silent
    if (-not $pr.Success -or $null -eq $pr.Value) {
        $motivo = $(if ($pr.Error) { $pr.Error.Exception.Message } else { 'a consulta nao devolveu resultado' })
        Write-Log WARN ('As exclusoes do Defender nao puderam ser consultadas: {0}' -f $motivo)
        Add-CompartDiskSection -Title 'Exclusoes do Defender' -Status WARN -Summary 'Nao verificadas (consulta recusada)'
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' `
            -Message ('Exclusoes do Defender nao verificadas: {0}' -f $motivo) `
            -Recommendation 'Reexecutar como administrador. O Defender recusa a consulta em modo passivo.'
        Set-DefenderResult 'WARN'
        return
    }
    $p = $pr.Value

    $pares = [ordered]@{
        'Caminhos excluidos'   = $(if ($p.ExclusionPath) { ($p.ExclusionPath -join "`n") } else { 'nenhum' })
        'Extensoes excluidas'  = $(if ($p.ExclusionExtension) { ($p.ExclusionExtension -join ', ') } else { 'nenhuma' })
        'Processos excluidos'  = $(if ($p.ExclusionProcess) { ($p.ExclusionProcess -join "`n") } else { 'nenhum' })
        'IPs excluidos'        = $(if ($p.ExclusionIpAddress) { ($p.ExclusionIpAddress -join ', ') } else { 'nenhum' })
    }
    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 22 }

    # Uma linha por exclusao: tipo -> valor -> abrangencia -> motivo.
    $linhas = New-Object System.Collections.ArrayList
    foreach ($par in @(@{ T = 'Caminho'; L = $p.ExclusionPath }, @{ T = 'Processo'; L = $p.ExclusionProcess },
                       @{ T = 'Extensao'; L = $p.ExclusionExtension }, @{ T = 'IP'; L = $p.ExclusionIpAddress })) {
        foreach ($v in @($par.L)) {
            if ($null -eq $v -or "$v".Trim() -eq '') { continue }
            $risco = Get-DefenderExclusionRisk -Tipo $par.T -Valor "$v"
            [void]$linhas.Add([pscustomobject]@{ Tipo = $par.T; Valor = "$v"; Abrangencia = $risco.Risco; Motivo = $risco.Motivo })
        }
    }

    $amplas = @($linhas | Where-Object { $_.Abrangencia -eq 'Amplo' })
    $total  = @($linhas).Count
    $status = $(if (@($amplas).Count -gt 0) { 'WARN' } elseif ($total -gt 0) { 'INFO' } else { 'OK' })
    Add-CompartDiskSection -Title 'Exclusoes do Defender' -Status $status -Rows @($linhas) -Pairs $pares `
        -Summary ("{0} exclusao(oes); {1} de abrangencia ampla" -f $total, @($amplas).Count)

    if ($total -eq 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Nenhuma exclusao configurada no Defender.'
    } elseif (@($amplas).Count -gt 0) {
        # Exclusao ampla pode ser legitima em ambiente corporativo: o achado pede
        # revisao, nao afirma comprometimento.
        Write-Log WARN ("{0} de {1} exclusao(oes) do Defender cobrem area ampla." -f @($amplas).Count, $total)
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' `
            -Message ("{0} de {1} exclusao(oes) do Defender cobrem area ampla: {2}." -f @($amplas).Count, $total, ((@($amplas | Select-Object -First 3).Valor) -join ', ')) `
            -Recommendation 'Revisar com o responsavel: exclusoes amplas podem ser legitimas em ambiente corporativo, mas sao vetor conhecido de evasao. Este modulo nao remove exclusoes.'
        Set-DefenderResult 'WARN'
    } else {
        Add-CompartDiskFinding -Severity INFO -Area 'Defender' `
            -Message ("{0} exclusao(oes) configurada(s) no Defender, todas de escopo especifico." -f $total) `
            -Recommendation 'Nenhuma exclusao ampla identificada. Revisar periodicamente a lista.'
    }
    Write-Log OK ("Exclusoes listadas: {0} no total, {1} ampla(s)." -f $total, @($amplas).Count)
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('Update', 'QuickScan', 'FullScan', 'CustomScan') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Defender' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # O estado persistido para o Report.ps1 vem de $result e o finally roda mesmo
        # com este exit: sair sem marcar gravava "Resultado=OK" para uma execucao
        # recusada, enquanto o processo devolvia 2.
        $result = 'ERROR'
        exit $Global:CompartDisk.Exit.ERROR
    }

    if ($Action -eq 'Status') {
        Show-DefenderStatus
    } else {
        if (-not (Assert-Defender)) {
            $result = 'UNSUPPORTED'
        } else {
            switch ($Action) {
                'Update'     { Update-DefenderSignatures }
                'QuickScan'  { Start-DefenderScan -Tipo QuickScan }
                'FullScan'   { Start-DefenderScan -Tipo FullScan }
                'CustomScan' { Start-DefenderScan -Tipo CustomScan -Alvo $Path }
                'Exclusions' { Show-Exclusions }
                'History'    { Show-ThreatHistory }
            }
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Defender (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Defender' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
