<#
 COMPARTDISK 1.2.0 - Audit.ps1
 Desenvolvido por Edsilas
 Acoes: Full | Quick | Events | Software | License
 Somente leitura: nenhuma alteracao e feita no sistema.
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Quick', 'Events', 'Software', 'License')]
    [string]$Action = 'Full',
    [int]$Days = 7,
    [switch]$NoReport,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Invoke-Etapa {
    param([string]$Nome, [scriptblock]$Bloco)
    Write-Color ''
    Write-Color ("  >> {0}" -f $Nome) -Color DarkCyan
    $r = Invoke-SafeCommand -ScriptBlock $Bloco -Activity $Nome
    if (-not $r.Success) {
        Write-Log WARN "Etapa '$Nome' incompleta: $($r.Error.Exception.Message)"
        $script:result = 'WARN'
    }
}

function Add-EventAudit {
    param([int]$Dias)
    $ev = Get-CompartDiskEventSummary -Days $Dias
    if ($ev.Count -eq 0) {
        Add-CompartDiskSection -Title "Eventos ($Dias dias)" -Status OK -Summary 'Nenhum evento critico, erro ou aviso relevante.'
        Add-CompartDiskFinding -Severity OK -Area 'Eventos' -Message "Nenhum evento critico nos ultimos $Dias dias."
        return
    }

    $criticos = @($ev | Where-Object { $_.Nivel -eq 'Critico' })
    $erros    = @($ev | Where-Object { $_.Nivel -eq 'Erro' })
    $avisos   = @($ev | Where-Object { $_.Nivel -eq 'Aviso' })

    $status = 'OK'
    if ($criticos.Count -gt 0) { $status = 'CRIT' } elseif ($erros.Count -gt 0) { $status = 'WARN' }

    Add-CompartDiskSection -Title "Eventos ($Dias dias)" -Status $status -Rows $ev `
        -Summary ("Criticos: {0} | Erros: {1} | Avisos: {2}" -f $criticos.Count, $erros.Count, $avisos.Count)

    foreach ($e in ($criticos | Select-Object -First 5)) {
        Add-CompartDiskFinding -Severity CRIT -Area 'Eventos' -Message "[$($e.Log)] ID $($e.EventoID) de $($e.Origem): $($e.Ocorrencias) ocorrencia(s)." -Recommendation $e.Mensagem
    }
    foreach ($e in ($erros | Select-Object -First 5)) {
        Add-CompartDiskFinding -Severity WARN -Area 'Eventos' -Message "[$($e.Log)] ID $($e.EventoID) de $($e.Origem): $($e.Ocorrencias) ocorrencia(s)." -Recommendation $e.Mensagem
    }
    if ($criticos.Count -gt 0 -or $erros.Count -gt 0) { $script:result = 'WARN' }

    $ev | Select-Object -First 15 | Format-Table Log, Nivel, EventoID, Origem, Ocorrencias -AutoSize | Out-String -Width 200 | Write-Output
    Write-Log OK "Eventos analisados: $($criticos.Count) criticos, $($erros.Count) erros, $($avisos.Count) avisos."
}

function Invoke-QuickAudit {
    Invoke-Etapa 'Identificacao do sistema' {
        $s = Get-CompartDiskSystemInfo
        foreach ($k in $s.Keys) { Write-CompartDiskKeyValue $k $s[$k] -Pad 18 }
        Add-CompartDiskSection -Title 'Sistema operacional' -Status OK -Pairs $s
        $w = Test-WindowsVersion
        if (-not $w.Supported) {
            Add-CompartDiskFinding -Severity CRIT -Area 'Sistema' -Message "Build $($w.Build) fora do escopo suportado (Windows 10/11)." -Recommendation 'Atualizar o sistema operacional.'
        } else {
            Add-CompartDiskFinding -Severity OK -Area 'Sistema' -Message "$($w.Family) $($w.DisplayVersion) build $($w.FullBuild)."
        }
    }

    Invoke-Etapa 'Hardware' {
        $h = Get-CompartDiskHardwareInfo
        foreach ($k in $h.Keys) { Write-CompartDiskKeyValue $k $h[$k] -Pad 18 }
        Add-CompartDiskSection -Title 'Hardware' -Status OK -Pairs $h
    }

    Invoke-Etapa 'Discos e volumes' {
        $d = Get-CompartDiskDiskInfo
        Add-CompartDiskSection -Title 'Discos fisicos' -Status OK -Rows $d
        foreach ($x in $d) {
            if ("$($x.Saude)" -match 'Unhealthy|Warning') {
                Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Disco '$($x.Modelo)' com saude '$($x.Saude)'." -Recommendation 'Backup imediato e substituicao.'
            }
        }
        $v = Get-CompartDiskVolumeInfo
        Add-CompartDiskSection -Title 'Volumes' -Status OK -Rows $v
        foreach ($x in $v) {
            $pct = [double](("$($x.UsadoPct)" -replace '%', ''))
            if ($pct -ge 90) {
                Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Volume $($x.Volume) com $pct% ocupado." -Recommendation 'Executar limpeza profunda.'
            } elseif ($pct -ge 80) {
                Add-CompartDiskFinding -Severity WARN -Area 'Disco' -Message "Volume $($x.Volume) com $pct% ocupado."
            }
        }
        $d | Format-Table Modelo, Midia, Tamanho, Saude -AutoSize | Out-String -Width 160 | Write-Output
        $v | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
    }

    Invoke-Etapa 'Rede' {
        $n = Get-CompartDiskNetworkInfo
        Add-CompartDiskSection -Title 'Rede' -Status OK -Rows $n -Summary "$($n.Count) interface(s)"
        $net = Test-Internet
        Add-CompartDiskSection -Title 'Conectividade' -Status $(if ($net.Online) { 'OK' } else { 'CRIT' }) -Pairs ([ordered]@{
            'Online' = $net.Online; 'Metodo' = $net.Method; 'Latencia' = $net.Latency; 'DNS' = $net.DnsOk
        })
        if (-not $net.Online) {
            Add-CompartDiskFinding -Severity CRIT -Area 'Rede' -Message 'Sem conectividade com a internet.' -Recommendation 'Executar o reset de rede.'
        } else {
            Add-CompartDiskFinding -Severity OK -Area 'Rede' -Message "Conectividade confirmada via $($net.Method)."
        }
    }

    Invoke-Etapa 'Seguranca' {
        $s = Get-CompartDiskSecurityPosture
        Add-CompartDiskSection -Title 'Postura de seguranca' -Status OK -Pairs $s
        if ("$($s['UAC'])" -match 'DESABILITADO') {
            Add-CompartDiskFinding -Severity CRIT -Area 'Seguranca' -Message 'UAC desabilitado.' -Recommendation 'Reativar imediatamente.'
        }
        if ("$($s['Secure Boot'])" -match 'Desabilitado') {
            Add-CompartDiskFinding -Severity WARN -Area 'Seguranca' -Message 'Secure Boot desabilitado.'
        }
        $fw = Get-CompartDiskFirewallInfo
        Add-CompartDiskSection -Title 'Firewall' -Status OK -Rows $fw
        foreach ($p in $fw) {
            if ("$($p.Habilitado)" -eq 'False') {
                Add-CompartDiskFinding -Severity CRIT -Area 'Firewall' -Message "Perfil '$($p.Perfil)' desabilitado." -Recommendation 'Reativar o firewall.'
            }
        }
    }

    Invoke-Etapa 'Antivirus e Defender' {
        $av = Get-CompartDiskAntivirusProducts
        if ($av.Count -gt 0) { Add-CompartDiskSection -Title 'Produtos antivirus' -Status OK -Rows $av }
        $def = Get-CompartDiskDefenderStatus
        if ($def) {
            Add-CompartDiskSection -Title 'Microsoft Defender' -Status $(if ("$($def['Protecao em tempo real'])" -eq 'True') { 'OK' } else { 'CRIT' }) -Pairs $def
            if ("$($def['Protecao em tempo real'])" -ne 'True') {
                Add-CompartDiskFinding -Severity CRIT -Area 'Defender' -Message 'Protecao em tempo real desabilitada.' -Recommendation 'Reativar em Seguranca do Windows.'
            } else {
                Add-CompartDiskFinding -Severity OK -Area 'Defender' -Message 'Protecao em tempo real ativa.'
            }
        }
    }

    Invoke-Etapa 'BitLocker' {
        $b = Test-BitLocker
        if ($b.Count -gt 0) { Add-CompartDiskSection -Title 'BitLocker' -Status OK -Rows $b }
    }

    Invoke-Etapa 'Windows Update' {
        $u = Get-CompartDiskWindowsUpdateInfo
        Add-CompartDiskSection -Title 'Windows Update' -Status OK -Pairs $u
        if ($u['Reinicio pendente'] -eq 'SIM') {
            Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message 'Reinicio pendente.' -Recommendation 'Reiniciar o computador.'
        }
        $h = Get-CompartDiskUpdateHistory -Max 25
        if ($h.Count -gt 0) { Add-CompartDiskSection -Title 'Historico de atualizacoes' -Status INFO -Rows $h }
    }
}

function Invoke-FullAudit {
    Invoke-QuickAudit

    Invoke-Etapa 'Drivers' {
        $d = Get-CompartDiskDriverInfo
        Add-CompartDiskSection -Title 'Drivers' -Status OK -Rows @($d | Select-Object -First 100) -Summary "$($d.Count) driver(s)"
        $p = Get-CompartDiskDriverInfo -OnlyProblems
        if ($p.Count -gt 0) {
            Add-CompartDiskSection -Title 'Dispositivos com problema' -Status CRIT -Rows $p
            foreach ($x in ($p | Select-Object -First 10)) {
                Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' -Message "$($x.Dispositivo): $($x.Descricao)" -Recommendation 'Reinstalar o driver.'
            }
        } else {
            Add-CompartDiskFinding -Severity OK -Area 'Drivers' -Message 'Nenhum dispositivo com codigo de erro.'
        }
        $ns = @($d | Where-Object { $_.Assinado -eq 'NAO' })
        if ($ns.Count -gt 0) {
            Add-CompartDiskFinding -Severity WARN -Area 'Drivers' -Message "$($ns.Count) driver(s) sem assinatura digital." -Recommendation 'Validar a procedencia.'
        }
    }

    Invoke-Etapa 'Contas e grupos' {
        $u = Get-CompartDiskLocalUsers
        Add-CompartDiskSection -Title 'Contas locais' -Status OK -Rows $u
        foreach ($c in $u) {
            if ($c.Habilitado -eq $true -and $c.SenhaRequerida -eq $false) {
                Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Conta '$($c.Usuario)' habilitada sem senha obrigatoria." -Recommendation 'Definir senha ou desabilitar.'
            }
        }
    }

    Invoke-Etapa 'Servicos e processos' {
        $s = Get-CompartDiskServiceDiagnostics
        Add-CompartDiskSection -Title 'Servicos essenciais' -Status OK -Rows $s
        foreach ($x in ($s | Where-Object { $_.Diagnostico -ne 'OK' })) {
            Add-CompartDiskFinding -Severity WARN -Area 'Servicos' -Message "Servico '$($x.Servico)' esta $($x.Estado)." -Recommendation 'Restaurar o tipo de inicializacao padrao.'
        }
        Add-CompartDiskSection -Title 'Processos (top memoria)' -Status INFO -Rows (Get-CompartDiskProcessDiagnostics -Top 15)
        Add-CompartDiskSection -Title 'Itens de inicializacao' -Status INFO -Rows (Get-CompartDiskStartupItems)
    }

    Invoke-Etapa 'Energia e desempenho' {
        Add-CompartDiskSection -Title 'Energia' -Status INFO -Pairs (Get-CompartDiskPowerInfo)
    }

    Invoke-Etapa 'Licenciamento' {
        Add-CompartDiskSection -Title 'Licenciamento' -Status INFO -Pairs (Get-CompartDiskLicenseInfo)
    }

    Invoke-Etapa 'Aplicativos instalados' {
        $sw = Get-CompartDiskInstalledSoftware
        Add-CompartDiskSection -Title 'Aplicativos instalados' -Status INFO -Rows @($sw | Select-Object -First 200) -Summary "$($sw.Count) aplicativo(s)"
    }

    Invoke-Etapa "Eventos dos ultimos $Days dias" {
        Add-EventAudit -Dias $Days
    }

    Invoke-Etapa 'Integridade e pendencias' {
        $pares = [ordered]@{
            'Reinicio pendente'   = $(if (Test-CompartDiskPendingReboot) { 'SIM' } else { 'Nao' })
            'Copias de sombra'    = (Get-CompartDiskShadowCopies).Count
            'Impressoras'         = (Get-CompartDiskPrinters).Count
        }
        Add-CompartDiskSection -Title 'Integridade do sistema' -Status OK -Pairs $pares
    }
}

# ------------------------------------------------------------------------------
try {
    if (-not (Start-CompartDiskModule -Name 'Audit' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }

    if (-not (Test-Administrator)) {
        Write-Log WARN 'Executando sem privilegios administrativos: parte da auditoria ficara incompleta.'
    }

    switch ($Action) {
        'Quick'    { Invoke-QuickAudit }
        'Full'     { Invoke-FullAudit }
        'Events'   { Add-EventAudit -Dias $Days }
        'Software' {
            $sw = Get-CompartDiskInstalledSoftware
            $sw | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
            Add-CompartDiskSection -Title 'Aplicativos instalados' -Status INFO -Rows $sw -Summary "$($sw.Count) aplicativo(s)"
        }
        'License'  {
            $l = Get-CompartDiskLicenseInfo
            foreach ($k in $l.Keys) { Write-CompartDiskKeyValue $k $l[$k] -Pad 22 }
            Add-CompartDiskSection -Title 'Licenciamento' -Status INFO -Pairs $l
        }
    }

    if (-not $NoReport) {
        Write-Color ''
        Write-Log INFO 'Gerando relatorios (TXT, CSV, JSON, HTML)...'
        $arquivos = New-Report -Name "Auditoria_$Action" -Title 'Auditoria de manutencao do Windows' -Format TXT, CSV, JSON, HTML -Open
        Write-Color ''
        foreach ($a in $arquivos) { Write-Color "  $a" -Color Green }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Audit (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Auditoria' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
