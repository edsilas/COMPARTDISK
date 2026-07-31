<#
 COMPARTDISK 1.2.0 - Performance.ps1
 Desenvolvido por Edsilas
 Acoes: Analyze | Ultimate | Balanced | Startup | Processes | Services
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Ultimate', 'Balanced', 'Startup', 'Processes', 'Services')]
    [string]$Action = 'Analyze',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'
$powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$GUID_ULTIMATE = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$GUID_BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'

function Show-Analysis {
    $energia = Get-CompartDiskPowerInfo
    Write-Color ''
    Write-Color '  ENERGIA' -Color White
    foreach ($k in $energia.Keys) { Write-CompartDiskKeyValue $k $energia[$k] -Pad 24 }
    Add-CompartDiskSection -Title 'Energia' -Status INFO -Pairs $energia

    # Processos
    $proc = Get-CompartDiskProcessDiagnostics -Top 12
    Write-Color ''
    Write-Color '  MAIORES CONSUMIDORES DE MEMORIA' -Color White
    $proc | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Processos (top memoria)' -Status INFO -Rows $proc

    # Contadores instantaneos
    $cpu = 'n/d'
    try {
        $c = Get-CompartDiskCim -Class Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        if ($c) { $cpu = "$($c.PercentProcessorTime)%" }
    } catch { }
    $hw = Get-CompartDiskHardwareInfo
    $pares = [ordered]@{
        'CPU (instantaneo)' = $cpu
        'RAM total'         = $hw['RAM total']
        'RAM disponivel'    = $hw['RAM disponivel']
        'RAM em uso (%)'    = $hw['RAM em uso (%)']
        'Processos ativos'  = (@(Get-Process -ErrorAction SilentlyContinue).Count)
    }
    try {
        $pf = Get-CompartDiskCim -Class Win32_PageFileUsage
        if ($pf) { $pares['Arquivo de paginacao'] = "$($pf.CurrentUsage) MB de $($pf.AllocatedBaseSize) MB" }
    } catch { }
    Write-Color ''
    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 24 }
    Add-CompartDiskSection -Title 'Carga do sistema' -Status OK -Pairs $pares

    # Inicializacao
    $startup = Get-CompartDiskStartupItems
    if ($startup.Count -gt 0) {
        Write-Color ''
        Write-Color ("  ITENS DE INICIALIZACAO: {0}" -f $startup.Count) -Color White
        $startup | Select-Object Nome, Local, Usuario | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Itens de inicializacao' -Status $(if ($startup.Count -gt 12) { 'WARN' } else { 'OK' }) -Rows $startup -Summary "$($startup.Count) item(ns)"
        if ($startup.Count -gt 12) {
            Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' -Message "$($startup.Count) programas configurados para iniciar com o Windows." -Recommendation 'Revisar em Gerenciador de Tarefas > Aplicativos de inicializacao.'
            $script:result = 'WARN'
        }
    }

    # Servicos
    $svc = Get-CompartDiskServiceDiagnostics
    $problemas = @($svc | Where-Object { $_.Diagnostico -ne 'OK' })
    if ($problemas.Count -gt 0) {
        Write-Color ''
        $problemas | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Servicos essenciais com desvio' -Status WARN -Rows $problemas
        foreach ($p in $problemas) {
            Add-CompartDiskFinding -Severity WARN -Area 'Servicos' -Message "Servico '$($p.Servico)' esta $($p.Estado) (inicio: $($p.Inicio))." -Recommendation 'Restaurar o tipo de inicializacao padrao e iniciar o servico.'
        }
        $script:result = 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Servicos' -Message 'Todos os servicos essenciais operando normalmente.'
    }
    Add-CompartDiskSection -Title 'Servicos essenciais' -Status OK -Rows $svc

    Write-Log OK 'Analise de desempenho concluida.'
}

function Set-PowerPlan {
    param([string]$Guid, [string]$Nome)

    if ($Guid -eq $GUID_ULTIMATE) {
        $lista = Invoke-NativeCommand -FilePath $powercfg -Arguments @('/list') -TimeoutSeconds 30
        if ($lista.StdOut -notmatch [regex]::Escape($Guid)) {
            Write-Log INFO 'Plano Desempenho Maximo ausente. Duplicando a partir do modelo do Windows...'
            $d = Invoke-NativeCommand -FilePath $powercfg -Arguments @('-duplicatescheme', $Guid) -TimeoutSeconds 60
            if ($d.ExitCode -ne 0) {
                Write-Log WARN 'Este dispositivo nao expoe o plano Desempenho Maximo (comum em notebooks com Modern Standby).'
                Write-Log INFO 'Aplicando o plano Alto Desempenho como alternativa nativa.'
                $Guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
                $Nome = 'Alto Desempenho'
            }
        }
    }

    $r = Invoke-NativeCommand -FilePath $powercfg -Arguments @('/setactive', $Guid) -TimeoutSeconds 30
    if ($r.ExitCode -eq 0) {
        Write-Log OK "Plano de energia ativo: $Nome"
        Add-CompartDiskFinding -Severity OK -Area 'Desempenho' -Message "Plano de energia definido como '$Nome'." -Recommendation 'Em notebooks, planos de alto desempenho reduzem a autonomia da bateria.'
    } else {
        $script:result = 'WARN'
        Write-Log WARN "Nao foi possivel ativar o plano '$Nome' (codigo $($r.ExitCode))."
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' -Message "Falha ao aplicar o plano de energia '$Nome'." -Recommendation 'Politicas de grupo corporativas podem bloquear a alteracao do plano.'
    }

    if ($Guid -ne $GUID_BALANCED) {
        Set-CompartDiskRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Type DWord | Out-Null
        Write-Log OK 'Efeitos visuais ajustados para melhor desempenho.'
    } else {
        Set-CompartDiskRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 0 -Type DWord | Out-Null
        Write-Log OK 'Efeitos visuais restaurados ao controle automatico do Windows.'
    }

    $atual = Invoke-NativeCommand -FilePath $powercfg -Arguments @('/getactivescheme') -TimeoutSeconds 20
    if ($atual.StdOut) { Write-Output $atual.StdOut.Trim() }
}

try {
    $precisaAdmin = @('Ultimate', 'Balanced') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Performance' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }
    switch ($Action) {
        'Analyze'   { Show-Analysis }
        'Ultimate'  { Set-PowerPlan -Guid $GUID_ULTIMATE -Nome 'Desempenho Maximo' }
        'Balanced'  { Set-PowerPlan -Guid $GUID_BALANCED -Nome 'Equilibrado (padrao)' }
        'Startup'   {
            $s = Get-CompartDiskStartupItems
            $s | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output
            Add-CompartDiskSection -Title 'Itens de inicializacao' -Status INFO -Rows $s
        }
        'Processes' {
            $p = Get-CompartDiskProcessDiagnostics -Top 25
            $p | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
            Add-CompartDiskSection -Title 'Processos' -Status INFO -Rows $p
        }
        'Services'  {
            $s = Get-CompartDiskServiceDiagnostics
            $s | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
            Add-CompartDiskSection -Title 'Servicos essenciais' -Status OK -Rows $s
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Performance (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Desempenho' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
