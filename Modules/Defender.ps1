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
        Add-CompartDiskFinding -Severity CRIT -Area 'Defender' -Message 'Protecao em tempo real desabilitada.' -Recommendation 'Reativar em Seguranca do Windows > Protecao contra virus e ameacas.'
        $script:result = 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Protecao em tempo real ativa.'
    }

    $idade = 0
    try { $idade = [int]$st['Assinaturas idade (d)'] } catch { }
    if ($idade -gt 7) {
        Add-CompartDiskFinding -Severity WARN -Area 'Defender' -Message "Assinaturas com $idade dias de idade." -Recommendation 'Executar a atualizacao de definicoes.'
        $script:result = 'WARN'
    } elseif ($idade -gt 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message "Assinaturas atualizadas ($idade dia(s))."
    }
    Write-Log OK 'Status do Defender coletado.'
}

function Update-DefenderSignatures {
    Write-Log INFO 'Atualizando definicoes do Microsoft Defender...'
    $r = Invoke-WithRetry -Activity 'Update-MpSignature' -Retries 3 -DelaySeconds 3 -Exponential -ScriptBlock {
        Update-MpSignature -ErrorAction Stop
        $true
    }
    if ($r) {
        $st = Get-MpComputerStatus
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
        Write-Log INFO "Iniciando varredura personalizada em '$Alvo'..."
        Start-MpScan -ScanType CustomScan -ScanPath $Alvo -ErrorAction Stop
    } else {
        $nome = if ($Tipo -eq 'QuickScan') { 'rapida' } else { 'completa (pode levar horas)' }
        Write-Log INFO "Iniciando varredura $nome..."
        Start-MpScan -ScanType $Tipo -ErrorAction Stop
    }

    $st = Get-MpComputerStatus
    $fim = if ($Tipo -eq 'FullScan') { $st.FullScanEndTime } else { $st.QuickScanEndTime }
    Write-Log OK "Varredura solicitada. Ultima conclusao registrada: $fim"
    Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message "Varredura $Tipo executada." -Recommendation 'Conferir ameacas detectadas na acao History.'
    Show-ThreatHistory
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
