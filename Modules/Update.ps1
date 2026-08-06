<#
 COMPARTDISK 1.3.1 - Update.ps1
 Desenvolvido por Edsilas
 Acoes: Status | History | Reset | Cache | Services | Search
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'History', 'Reset', 'Cache', 'Services', 'Search')]
    [string]$Action = 'Status',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'
$servicos = @('wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc', 'DoSvc')

function Show-UpdateStatus {
    $info = Get-CompartDiskWindowsUpdateInfo
    foreach ($k in $info.Keys) {
        $cor = 'Gray'
        if ("$($info[$k])" -match 'Stopped|ausente|SIM') { $cor = 'Yellow' }
        Write-CompartDiskKeyValue $k $info[$k] -Color $cor
    }
    Add-CompartDiskSection -Title 'Windows Update' -Status $(if ($info['Reinicio pendente'] -eq 'SIM') { 'WARN' } else { 'OK' }) -Pairs $info

    foreach ($s in $servicos) {
        $chave = 'Servico ' + $s
        $v = [string]$info[$chave]
        if ($v -match 'Disabled') {
            Add-CompartDiskFinding -Severity CRIT -Area 'Windows Update' -Message "Servico '$s' esta desabilitado." -Recommendation 'Reconfigurar para Manual/Automatico e reiniciar o servico.'
            $script:result = 'WARN'
        }
    }
    if ($info['Reinicio pendente'] -eq 'SIM') {
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message 'Reinicio pendente aguardando conclusao de atualizacoes.' -Recommendation 'Reiniciar o computador.'
    }
    Write-Log OK 'Status do Windows Update coletado.'
}

function Show-UpdateHistory {
    Write-Log INFO 'Consultando historico de atualizacoes (API COM nativa)...'
    $hist = Get-CompartDiskUpdateHistory -Max 60
    if ($hist.Count -eq 0) {
        Write-Log WARN 'Nenhum historico disponivel.'
        $script:result = 'WARN'
        return
    }
    $hist | Select-Object -First 25 | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Historico de atualizacoes' -Status INFO -Rows $hist -Summary "$($hist.Count) registro(s)"

    $falhas = @($hist | Where-Object { $_.Resultado -eq 'Falha' })
    if ($falhas.Count -gt 0) {
        $script:result = 'WARN'
        foreach ($f in ($falhas | Select-Object -First 5)) {
            Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message "Falha ao instalar: $($f.Titulo) ($($f.Codigo))" -Recommendation 'Executar o reset de componentes do Windows Update e tentar novamente.'
        }
        Write-Log WARN "$($falhas.Count) atualizacao(oes) com falha no historico."
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message 'Nenhuma falha recente no historico de atualizacoes.'
    }
}

function Search-PendingUpdates {
    Write-Log INFO 'Procurando atualizacoes pendentes (pode levar alguns minutos)...'
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res      = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        $rows = New-Object System.Collections.ArrayList
        foreach ($u in $res.Updates) {
            [void]$rows.Add([pscustomobject]@{
                Titulo     = $u.Title
                Severidade = $(if ($u.MsrcSeverity) { $u.MsrcSeverity } else { 'n/d' })
                Tamanho    = (ConvertTo-CompartDiskSize $u.MaxDownloadSize)
                Obrigatoria= $u.IsMandatory
                KB         = (($u.KBArticleIDs | ForEach-Object { "KB$_" }) -join ', ')
            })
        }
        if ($rows.Count -eq 0) {
            Write-Log OK 'Nenhuma atualizacao pendente.'
            Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message 'Sistema atualizado: nenhuma atualizacao pendente.'
        } else {
            $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
            Add-CompartDiskSection -Title 'Atualizacoes pendentes' -Status WARN -Rows @($rows) -Summary "$($rows.Count) pendente(s)"
            Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message "$($rows.Count) atualizacao(oes) pendente(s)." -Recommendation 'Instalar pelo Windows Update (Configuracoes > Windows Update).'
            $script:result = 'WARN'
            Write-Log WARN "$($rows.Count) atualizacao(oes) pendente(s)."
        }
    } catch {
        $script:result = 'WARN'
        Write-Log WARN 'Nao foi possivel consultar o servidor de atualizacoes.' -ErrorRecord $_
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message 'Busca por atualizacoes falhou.' -Recommendation 'Validar conectividade e o servico wuauserv; executar o reset de componentes.'
    }
}

function Repair-UpdateServices {
    Write-Log INFO 'Reconfigurando servicos do Windows Update...'
    $config = @{
        'wuauserv'  = 'Manual'
        'bits'      = 'Manual'
        'cryptsvc'  = 'Automatic'
        'msiserver' = 'Manual'
        'usosvc'    = 'Manual'
        'DoSvc'     = 'Manual'
    }
    foreach ($n in $config.Keys) {
        Invoke-SafeCommand {
            $svc = Get-Service -Name $n -ErrorAction Stop
            if ($svc.StartType -eq 'Disabled') {
                Set-Service -Name $n -StartupType $config[$n] -ErrorAction Stop
                Write-Log OK "Servico '$n' reabilitado como $($config[$n])."
            } else {
                Write-Log DEBUG "Servico '$n' ja em $($svc.StartType)." -NoConsole
            }
        } -Activity "Configurar servico $n" | Out-Null
    }
    $iniciados = @(Set-CompartDiskServiceState -Name @('cryptsvc', 'bits', 'wuauserv') -Action Start)
    $naoIniciados = @($iniciados | Where-Object { -not $_.Success })
    # A afirmacao acompanha o resultado: em parque gerenciado, uma diretiva de grupo
    # pode forcar wuauserv como Disabled e a reconfiguracao nao pega. O relatorio
    # trazia lado a lado o CRIT do diagnostico e um OK dizendo que fora resolvido.
    if ($naoIniciados.Count -eq 0) {
        Write-Log OK 'Servicos do Windows Update reconfigurados.'
        Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message 'Servicos do Windows Update verificados e habilitados.'
    } else {
        $script:result = 'WARN'
        $nomes = ($naoIniciados | ForEach-Object { $_.Service }) -join ', '
        Write-Log WARN "Servicos do Windows Update nao iniciados: $nomes"
        Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message "Nem todos os servicos do Windows Update puderam ser habilitados: $nomes." -Recommendation 'Verificar diretiva de grupo que force o tipo de inicializacao, ou politica corporativa de atualizacao.'
    }
}

function Clear-UpdateCache {
    Write-Log INFO 'Limpando cache de downloads do Windows Update...'
    $parados = Set-CompartDiskServiceState -Name @('wuauserv', 'bits', 'usosvc', 'DoSvc') -Action Stop
    foreach ($p in $parados) { if (-not $p.Success) { Write-Log WARN "Servico $($p.Service): $($p.Detail)" } }

    $alvos = @(
        (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
        (Join-Path $env:SystemRoot 'SoftwareDistribution\DeliveryOptimization')
        (Join-Path $env:SystemDrive 'Windows\SoftwareDistribution\PostRebootEventCache.V2')
    )
    $total = 0
    foreach ($a in $alvos) {
        $antes = Get-CompartDiskFolderSize -Path $a
        if (-not $antes.Exists) { continue }
        $r = Remove-CompartDiskPathSafely -Path $a -KeepRoot
        $total += $r.BytesFreed
        Write-Log OK ("{0}: {1} liberados ({2} itens, {3} bloqueados)" -f (Split-Path $a -Leaf), (ConvertTo-CompartDiskSize $r.BytesFreed), $r.Removed, $r.Failed)
    }

    Set-CompartDiskServiceState -Name @('wuauserv', 'bits', 'usosvc', 'DoSvc') -Action Start | Out-Null
    Add-CompartDiskSection -Title 'Cache do Windows Update' -Status OK -Pairs ([ordered]@{ 'Espaco liberado' = (ConvertTo-CompartDiskSize $total) })
    Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message "Cache de downloads limpo: $(ConvertTo-CompartDiskSize $total) liberados."
    Write-Log OK "Cache limpo. Total liberado: $(ConvertTo-CompartDiskSize $total)."
}

function Reset-UpdateComponents {
    Write-Log INFO '=== RESET COMPLETO DOS COMPONENTES DO WINDOWS UPDATE ==='

    Repair-UpdateServices
    $parados = Set-CompartDiskServiceState -Name @('wuauserv', 'bits', 'cryptsvc', 'usosvc', 'DoSvc', 'msiserver') -Action Stop
    $bloqueados = @($parados | Where-Object { -not $_.Success })
    if ($bloqueados.Count -gt 0) {
        Write-Log WARN ("Servicos que nao pararam: {0}" -f (($bloqueados | ForEach-Object { $_.Service }) -join ', '))
    }

    # Renomeia (nao apaga) as pastas criticas -> reversivel
    $renomear = @(
        @{ P = (Join-Path $env:SystemRoot 'SoftwareDistribution'); N = 'SoftwareDistribution' }
        @{ P = (Join-Path $env:SystemRoot 'System32\catroot2');    N = 'catroot2' }
    )
    foreach ($item in $renomear) {
        $old = "$($item.P).old"
        try {
            $destino = "$($item.N).old"
            if (Test-Path -LiteralPath $old) {
                # O .old de uma execucao anterior guarda o estado REAL anterior a
                # ferramenta. Apaga-lo destruia justamente o que a renomeacao existe
                # para preservar - e a recomendacao emitida quando uma pasta fica
                # bloqueada e "executar o reset novamente", tornando esse o caminho
                # mais provavel em vez do mais raro.
                $destino = "$($item.N).old_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
                Write-Log INFO "Backup anterior de '$($item.N)' preservado. Novo backup: $destino"
            }
            if (Test-Path -LiteralPath $item.P) {
                Rename-Item -LiteralPath $item.P -NewName $destino -Force -ErrorAction Stop
                Write-Log OK "Pasta '$($item.N)' redefinida (backup em $destino)."
            }
        } catch {
            $script:result = 'WARN'
            Write-Log WARN "'$($item.N)' esta bloqueada por processo ativo e nao foi redefinida." -ErrorRecord $_
            Add-CompartDiskFinding -Severity WARN -Area 'Windows Update' -Message "Pasta $($item.N) bloqueada durante o reset." -Recommendation 'Reiniciar o computador e executar o reset novamente.'
        }
    }

    # Reregistra as DLLs do agente de atualizacao
    $regsvr = Join-Path $env:SystemRoot 'System32\regsvr32.exe'
    $dlls = @('atl.dll', 'urlmon.dll', 'mshtml.dll', 'jscript.dll', 'vbscript.dll', 'msxml3.dll', 'msxml6.dll',
        'actxprxy.dll', 'softpub.dll', 'wintrust.dll', 'dssenh.dll', 'rsaenh.dll', 'cryptdlg.dll',
        'oleaut32.dll', 'ole32.dll', 'shell32.dll', 'wuapi.dll', 'wuaueng.dll', 'wups.dll', 'wups2.dll', 'wuwebv.dll')
    $ok = 0
    foreach ($d in $dlls) {
        $caminho = Join-Path $env:SystemRoot "System32\$d"
        if (-not (Test-Path -LiteralPath $caminho)) { continue }
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $regsvr -Arguments @('/s', "`"$caminho`"") -TimeoutSeconds 20 } -Activity "regsvr32 $d" -Silent
        if ($r.Success -and $r.Value.ExitCode -eq 0) { $ok++ }
    }
    Write-Log OK "$ok biblioteca(s) do agente reregistradas."

    # Reset das politicas de proxy WinHTTP usadas pelo agente
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netsh -Arguments @('winsock', 'reset') -TimeoutSeconds 60 } -Activity 'Winsock reset' | Out-Null

    Set-CompartDiskServiceState -Name @('cryptsvc', 'bits', 'wuauserv', 'usosvc', 'DoSvc') -Action Start | Out-Null

    # Forca nova deteccao
    $usoclient = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
    if (Test-Path -LiteralPath $usoclient) {
        Invoke-SafeCommand { Invoke-NativeCommand -FilePath $usoclient -Arguments @('StartScan') -TimeoutSeconds 30 } -Activity 'UsoClient StartScan' -Silent | Out-Null
    } else {
        $wuauclt = Join-Path $env:SystemRoot 'System32\wuauclt.exe'
        if (Test-Path -LiteralPath $wuauclt) {
            Invoke-SafeCommand { Invoke-NativeCommand -FilePath $wuauclt -Arguments @('/resetauthorization', '/detectnow') -TimeoutSeconds 30 } -Activity 'wuauclt detectnow' -Silent | Out-Null
        }
    }

    Add-CompartDiskSection -Title 'Reset do Windows Update' -Status $(if ($result -eq 'OK') { 'OK' } else { 'WARN' }) -Pairs ([ordered]@{
        'Servicos reconfigurados' = ($servicos -join ', ')
        'DLLs reregistradas'      = $ok
        'Backups'                 = 'SoftwareDistribution.old / catroot2.old'
    })
    Add-CompartDiskFinding -Severity OK -Area 'Windows Update' -Message 'Componentes do Windows Update redefinidos.' -Recommendation 'Reiniciar o computador e buscar atualizacoes novamente.'
    Write-Log OK 'Reset dos componentes concluido. Reinicio recomendado.'
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('Reset', 'Cache', 'Services') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Update' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'Status'   { Show-UpdateStatus }
        'History'  { Show-UpdateHistory }
        'Search'   { Search-PendingUpdates }
        'Services' { Repair-UpdateServices }
        'Cache'    { Clear-UpdateCache }
        'Reset'    { Reset-UpdateComponents }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Update (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Windows Update' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
