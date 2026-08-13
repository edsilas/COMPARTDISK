<#
 COMPARTDISK 1.3.1 - Defender.ps1
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
                $script:result = 'WARN'
            }
        }
    }

    $st = Get-CompartDiskDefenderStatus
    if (-not $st) {
        Write-Log WARN 'Nao foi possivel obter o status do Microsoft Defender.'
        $script:result = 'WARN'
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
    $status = 'OK'
    if ("$($st['Protecao em tempo real'])" -eq 'False') { $status = 'CRIT' }
    Add-CompartDiskSection -Title 'Microsoft Defender' -Status $status -Pairs $st

    if ("$($st['Protecao em tempo real'])" -eq 'False') {
        Write-Log WARN 'Protecao em tempo real do Defender DESABILITADA.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Defender' -Message 'Protecao em tempo real desabilitada.' -Recommendation 'Reativar em Seguranca do Windows > Protecao contra virus e ameacas.'
        $script:result = 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Protecao em tempo real ativa.'
    }

    $idade = 0
    try { $idade = [int]$st['Assinaturas idade (d)'] } catch { }
    if ($idade -gt 7) {
        Write-Log WARN "Assinaturas do Defender com $idade dias de idade."
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message "Assinaturas com $idade dias de idade." -Recommendation 'Executar a atualizacao de definicoes.'
        $script:result = 'WARN'
    } elseif ($idade -gt 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message "Assinaturas atualizadas ($idade dia(s))."
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
    $r = Invoke-WithRetry -Activity 'Update-MpSignature' -Retries 3 -DelaySeconds 3 -Exponential -ScriptBlock {
        Update-MpSignature -ErrorAction Stop
        $true
    }
    if ($r) {
        # Mesma classe de defeito do FullScan: chamada nua a Get-MpComputerStatus
        # propaga CimException e derruba o modulo com "falha nao tratada".
        $sr = Invoke-SafeCommand { Get-MpComputerStatus -ErrorAction Stop } -Activity 'Get-MpComputerStatus (pos-atualizacao)' -Silent
        if (-not $sr.Success -or $null -eq $sr.Value) {
            Write-Log WARN 'Definicoes atualizadas, porem a versao resultante nao pode ser confirmada.'
            Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message 'A atualizacao de definicoes foi aceita, mas a versao resultante nao pode ser lida.' -Recommendation 'Confirmar o estado do provedor WMI do Defender antes de considerar as assinaturas atualizadas.'
            $script:result = 'WARN'
            return
        }
        $st = $sr.Value
        Write-Log OK "Definicoes atualizadas: versao $($st.AntivirusSignatureVersion) ($($st.AntivirusSignatureLastUpdated))."
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message "Assinaturas atualizadas para $($st.AntivirusSignatureVersion)."
    }
}

function Start-DefenderScan {
    param([ValidateSet('QuickScan', 'FullScan', 'CustomScan')][string]$Tipo, [string]$Alvo)

    if ($Tipo -eq 'CustomScan') {
        if ([string]::IsNullOrWhiteSpace($Alvo) -or -not (Test-Path -LiteralPath $Alvo)) {
            Write-Log ERR "Caminho invalido para varredura personalizada: '$Alvo'"
            $script:result = 'ERROR'
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
        $script:result = 'ERROR'
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
        $script:result = 'WARN'
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
    $rows = New-Object System.Collections.ArrayList
    $r = Invoke-SafeCommand { Get-MpThreatDetection -ErrorAction Stop } -Activity 'Get-MpThreatDetection'
    if ($r.Success -and $r.Value) {
        foreach ($d in ($r.Value | Sort-Object InitialDetectionTime -Descending | Select-Object -First 30)) {
            $nome = 'n/d'
            $sev  = 'n/d'
            try {
                $t = Get-MpThreat -ThreatID $d.ThreatID -ErrorAction Stop | Select-Object -First 1
                if ($t) { $nome = $t.ThreatName; $sev = "$($t.SeverityID)" }
            } catch { }
            [void]$rows.Add([pscustomobject]@{
                Detectado = $d.InitialDetectionTime
                Ameaca    = $nome
                Severidade= $sev
                Acao      = "$($d.ThreatStatusID)"
                Recursos  = (($d.Resources | Select-Object -First 2) -join '; ')
            })
        }
    }

    if (-not $r.Success) {
        # Consulta que falhou nao e historico limpo. Get-MpThreatDetection recusa em
        # modo passivo (antivirus de terceiros ativo) e com o WinDefend parado, e
        # afirmar "limpo" nesses casos e um atestado de seguranca sem base.
        Write-Log WARN 'O historico de ameacas nao pode ser consultado.'
        Add-CompartDiskFinding -Severity INFO -Area 'Defender' -Message 'Historico de ameacas nao verificado: a consulta ao Defender foi recusada.' -Recommendation 'Conferir em Seguranca do Windows > Protecao contra virus e ameacas > Historico de protecao. O Defender pode estar em modo passivo.'
        $script:result = 'WARN'
    } elseif ($rows.Count -eq 0) {
        Write-Log OK 'Nenhuma ameaca registrada no historico.'
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Historico de ameacas limpo.'
    } else {
        $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Historico de ameacas' -Status WARN -Rows @($rows) -Summary "$($rows.Count) deteccao(oes)"
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message "$($rows.Count) deteccao(oes) no historico do Defender." -Recommendation 'Revisar as acoes tomadas em Seguranca do Windows > Historico de protecao.'
        $script:result = 'WARN'
    }
}

function Show-Exclusions {
    $p = Get-MpPreference -ErrorAction Stop
    $pares = [ordered]@{
        'Caminhos excluidos'   = $(if ($p.ExclusionPath) { ($p.ExclusionPath -join "`n") } else { 'nenhum' })
        'Extensoes excluidas'  = $(if ($p.ExclusionExtension) { ($p.ExclusionExtension -join ', ') } else { 'nenhuma' })
        'Processos excluidos'  = $(if ($p.ExclusionProcess) { ($p.ExclusionProcess -join "`n") } else { 'nenhum' })
        'IPs excluidos'        = $(if ($p.ExclusionIpAddress) { ($p.ExclusionIpAddress -join ', ') } else { 'nenhum' })
    }
    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 22 }
    Add-CompartDiskSection -Title 'Exclusoes do Defender' -Status INFO -Pairs $pares

    $total = @($p.ExclusionPath).Count + @($p.ExclusionProcess).Count
    if ($total -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message "$total exclusao(oes) configurada(s) no Defender." -Recommendation 'Auditar exclusoes: sao um vetor comum de evasao de antivirus.'
        $script:result = 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Nenhuma exclusao configurada no Defender.'
    }
    Write-Log OK 'Exclusoes listadas.'
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('Update', 'QuickScan', 'FullScan', 'CustomScan') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Defender' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
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
