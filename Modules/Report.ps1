<#
 COMPARTDISK 1.3.1 - Report.ps1
 Desenvolvido por Edsilas
 Acoes: Build | Consolidate | Open
 Gera relatorios TXT/CSV/JSON/HTML a partir da sessao atual ou dos estados
 persistidos pelos modulos executados anteriormente.
#>
[CmdletBinding()]
param(
    [ValidateSet('Build', 'Consolidate', 'Open')]
    [string]$Action = 'Build',
    [string]$Title = 'Relatorio consolidado de manutencao',
    [switch]$NoOpen,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Import-SessionState {
    <# Reagrega os estados gravados por cada modulo desta sessao. #>
    $dir = $Global:CompartDisk.OutDir
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }

    # O proprio Report grava um state_Report_*.json contendo TUDO que acabou de
    # agregar. Reincluir esse arquivo em uma segunda consolidacao da mesma sessao
    # (cenario real: /autofix seguido do menu [8][3]) duplicaria cada achado e
    # dobraria os contadores do resumo executivo.
    $arquivos = @(Get-ChildItem -LiteralPath $dir -Filter 'state_*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'state_Report*' })
    if ($arquivos.Count -eq 0) { return 0 }

    $modulos = New-Object System.Collections.ArrayList
    foreach ($f in $arquivos) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            [void]$modulos.Add([pscustomobject]@{
                Modulo    = $j.Module
                Resultado = $j.Result
                Tempo     = "$($j.Elapsed)s"
                Executado = $j.Timestamp
                Mensagem  = $j.Message
            })
            foreach ($s in @($j.Sections)) {
                if (-not $s) { continue }
                $pares = $null
                if ($s.Pairs) {
                    $pares = [ordered]@{}
                    foreach ($p in $s.Pairs.PSObject.Properties) { $pares[$p.Name] = $p.Value }
                }
                Add-CompartDiskSection -Title $s.Title -Status $(if ($s.Status) { $s.Status } else { 'INFO' }) `
                    -Summary "$($s.Summary)" -Rows @($s.Rows) -Pairs $pares
            }
            foreach ($x in @($j.Findings)) {
                if (-not $x) { continue }
                Add-CompartDiskFinding -Severity $x.Severity -Area $x.Area -Message $x.Message -Recommendation "$($x.Recommendation)"
            }
        } catch {
            Write-Log WARN "Estado ilegivel ignorado: $($f.Name)" -NoConsole
        }
    }

    if ($modulos.Count -gt 0) {
        Add-CompartDiskSection -Title 'Modulos executados nesta sessao' -Status INFO -Rows @($modulos) -Summary "$($modulos.Count) modulo(s)"
    }
    return $arquivos.Count
}

function New-ConsolidatedReport {
    param([switch]$Consolidar)

    if ($Consolidar) {
        $n = Import-SessionState
        Write-Log INFO "$n estado(s) de modulo agregado(s) a partir da sessao atual."
    }

    # Se nao ha nada agregado, coleta um retrato minimo do sistema
    if ($Global:CompartDisk.Sections.Count -eq 0) {
        Write-Log INFO 'Nenhum estado previo encontrado. Coletando retrato do sistema...'
        Add-CompartDiskSection -Title 'Sistema operacional' -Status OK -Pairs (Get-CompartDiskSystemInfo)
        Add-CompartDiskSection -Title 'Hardware'            -Status OK -Pairs (Get-CompartDiskHardwareInfo)
        Add-CompartDiskSection -Title 'Postura de seguranca'-Status OK -Pairs (Get-CompartDiskSecurityPosture)
        Add-CompartDiskSection -Title 'Discos fisicos'      -Status OK -Rows  (Get-CompartDiskDiskInfo)
        Add-CompartDiskSection -Title 'Volumes'             -Status OK -Rows  (Get-CompartDiskVolumeInfo)
        Add-CompartDiskSection -Title 'Rede'                -Status OK -Rows  (Get-CompartDiskNetworkInfo)
        Add-CompartDiskSection -Title 'Firewall'            -Status OK -Rows  (Get-CompartDiskFirewallInfo)
        Add-CompartDiskSection -Title 'Windows Update'      -Status OK -Pairs (Get-CompartDiskWindowsUpdateInfo)
        Add-CompartDiskSection -Title 'Servicos essenciais' -Status OK -Rows  (Get-CompartDiskServiceDiagnostics)
        Add-CompartDiskSection -Title 'Licenciamento'       -Status INFO -Pairs (Get-CompartDiskLicenseInfo)
        Add-CompartDiskFinding -Severity INFO -Area 'Relatorio' -Message 'Retrato gerado sem execucao previa de modulos.' -Recommendation 'Executar a auditoria completa para um diagnostico aprofundado.'
    }

    $dados = [ordered]@{
        Meta     = New-CompartDiskReportMeta
        Sections = @($Global:CompartDisk.Sections)
        Findings = @($Global:CompartDisk.Findings)
    }

    $arquivos = New-Report -Name 'Relatorio_Consolidado' -Title $Title -Format TXT, CSV, JSON, HTML -Data $dados -Open:(-not $NoOpen)

    $crit = @($Global:CompartDisk.Findings | Where-Object { $_.Severity -eq 'CRIT' }).Count
    $warn = @($Global:CompartDisk.Findings | Where-Object { $_.Severity -eq 'WARN' }).Count
    $ok   = @($Global:CompartDisk.Findings | Where-Object { $_.Severity -eq 'OK' }).Count

    Write-Color ''
    Write-Color '  RESUMO EXECUTIVO' -Color White
    Write-Color ("    Itens criticos    : {0}" -f $crit) -Color $(if ($crit -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Color ("    Itens em atencao  : {0}" -f $warn) -Color $(if ($warn -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Color ("    Itens conformes   : {0}" -f $ok)   -Color Green
    Write-Color ''
    Write-Color '  ARQUIVOS GERADOS' -Color White
    foreach ($a in $arquivos) { Write-Color "    $a" -Color Cyan }

    if ($crit -gt 0) { $script:result = 'WARN' }
    Write-Log OK "Relatorio consolidado gerado ($($arquivos.Count) arquivos, $crit critico(s), $warn aviso(s))."
}

function Open-LastReport {
    $dir = $Global:CompartDisk.LogDir
    $raiz = Join-Path $dir 'COMPARTDISK_Relatorios'
    if (-not (Test-Path -LiteralPath $raiz)) {
        Write-Log WARN "Nenhum relatorio encontrado em: $raiz"
        $script:result = 'WARN'
        return
    }
    $ultimo = Get-ChildItem -LiteralPath $raiz -Recurse -Filter '*.html' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $ultimo) {
        Write-Log WARN 'Nenhum relatorio HTML localizado.'
        $script:result = 'WARN'
        return
    }
    Write-Log OK "Abrindo: $($ultimo.FullName)"
    try { Start-Process $ultimo.FullName } catch { Write-Log WARN 'Nao foi possivel abrir o arquivo.' }
}

try {
    if (-not (Start-CompartDiskModule -Name 'Report' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }
    switch ($Action) {
        'Build'       { New-ConsolidatedReport }
        'Consolidate' { New-ConsolidatedReport -Consolidar }
        'Open'        { Open-LastReport }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Report (Acao=$Action)." -ErrorRecord $_
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
