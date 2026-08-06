<#
 COMPARTDISK 1.3.1 - Battery.ps1
 Desenvolvido por Edsilas
 Acoes: Info | Report | Sleep
#>
[CmdletBinding()]
param(
    [ValidateSet('Info', 'Report', 'Sleep')]
    [string]$Action = 'Info',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'
$powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'

function Test-Bateria {
    $b = Get-CompartDiskCim -Class Win32_Battery
    if (-not $b) {
        Write-Log WARN 'Nenhuma bateria detectada (desktop ou bateria ausente).'
        Add-CompartDiskFinding -Severity INFO -Area 'Bateria' -Message 'Nenhuma bateria presente no sistema.'
        return $null
    }
    return $b
}

function Show-BatteryInfo {
    $b = Test-Bateria
    if (-not $b) { $script:result = 'UNSUPPORTED'; return }

    $status = @{
        1 = 'Descarregando'; 2 = 'Conectada a energia'; 3 = 'Totalmente carregada'; 4 = 'Baixa'
        5 = 'Critica'; 6 = 'Carregando'; 7 = 'Carregando (alta)'; 8 = 'Carregando (baixa)'
        9 = 'Carregando (critica)'; 10 = 'Indefinido'; 11 = 'Carga parcial'
    }

    foreach ($bat in @($b)) {
        $pares = [ordered]@{
            'Bateria'            = $bat.Name
            # Win32_Battery nao expoe fabricante: DeviceID e um identificador, nao um
            # nome. E Chemistry e um codigo numerico, como BatteryStatus logo abaixo.
            'Identificador'      = $bat.DeviceID
            'Quimica'            = $(
                $q = @{ 1 = 'Outra'; 2 = 'Desconhecida'; 3 = 'Chumbo-acido'; 4 = 'Niquel-cadmio'
                        5 = 'Niquel-hidreto metalico'; 6 = 'Ions de litio'; 7 = 'Zinco-ar'; 8 = 'Litio-polimero' }
                if ($q.ContainsKey([int]$bat.Chemistry)) { $q[[int]$bat.Chemistry] } else { "Codigo $($bat.Chemistry)" }
            )
            'Carga estimada'     = "$($bat.EstimatedChargeRemaining)%"
            'Status'             = $(if ($status.ContainsKey([int]$bat.BatteryStatus)) { $status[[int]$bat.BatteryStatus] } else { $bat.BatteryStatus })
            'Autonomia estimada' = $(if ($bat.EstimatedRunTime -and $bat.EstimatedRunTime -lt 71582788) { "$($bat.EstimatedRunTime) min" } else { 'conectada a energia' })
            'Voltagem'           = $(if ($bat.DesignVoltage) { "$($bat.DesignVoltage) mV" } else { 'n/d' })
        }

        # Capacidade projetada vs total (saude real)
        try {
            $st = Get-CompartDiskCim -Class BatteryStaticData -Namespace 'root\wmi'
            $fc = Get-CompartDiskCim -Class BatteryFullChargedCapacity -Namespace 'root\wmi'
            if ($st -and $fc) {
                $projetada = [double]($st | Select-Object -First 1).DesignedCapacity
                $atual     = [double]($fc | Select-Object -First 1).FullChargedCapacity
                if ($projetada -gt 0) {
                    $saude = [math]::Round(($atual / $projetada) * 100, 1)
                    $pares['Capacidade projetada'] = "$projetada mWh"
                    $pares['Capacidade atual']     = "$atual mWh"
                    $pares['Saude da bateria']     = "$saude%"

                    if ($saude -lt 60) {
                        Add-CompartDiskFinding -Severity CRIT -Area 'Bateria' -Message "Saude da bateria em $saude% da capacidade original." -Recommendation 'Substituicao recomendada.'
                        $script:result = 'WARN'
                    } elseif ($saude -lt 80) {
                        Add-CompartDiskFinding -Severity WARN -Area 'Bateria' -Message "Saude da bateria em $saude% da capacidade original." -Recommendation 'Desgaste perceptivel; monitorar autonomia.'
                    } else {
                        Add-CompartDiskFinding -Severity OK -Area 'Bateria' -Message "Saude da bateria em $saude% da capacidade original."
                    }
                }
            }
        } catch { Write-Log DEBUG "Capacidade detalhada indisponivel: $($_.Exception.Message)" -NoConsole }

        foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 22 }
        Add-CompartDiskSection -Title 'Bateria' -Status OK -Pairs $pares
    }
    Write-Log OK 'Informacoes de bateria coletadas.'
}

function New-BatteryReport {
    if (-not (Test-Bateria)) { $script:result = 'UNSUPPORTED'; return }
    $destino = Join-Path $Global:CompartDisk.OutDir "Relatorio_Bateria_$($Global:CompartDisk.Session).html"
    Write-Log INFO 'Gerando relatorio nativo de bateria (powercfg /batteryreport)...'

    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $powercfg -Arguments @('/batteryreport', '/output', "`"$destino`"") -TimeoutSeconds 180
    } -Activity 'powercfg /batteryreport' -Critical

    if ((Test-Path -LiteralPath $destino)) {
        Write-Log OK "Relatorio gerado: $destino"
        Add-CompartDiskFinding -Severity OK -Area 'Bateria' -Message 'Relatorio detalhado de bateria gerado.' -Recommendation "Arquivo: $destino"
        try { Start-Process $destino } catch { Write-Log WARN 'Nao foi possivel abrir o relatorio automaticamente.' }
    } else {
        $script:result = 'ERROR'
        Write-Log ERR "Falha ao gravar o relatorio (codigo $(if ($r.Value) { $r.Value.ExitCode } else { 'n/d' }))."
    }
}

function New-SleepReport {
    $destino = Join-Path $Global:CompartDisk.OutDir "Diagnostico_Energia_$($Global:CompartDisk.Session).html"
    Write-Log INFO 'Executando diagnostico de energia (powercfg /energy, 60 segundos)...'
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $powercfg -Arguments @('/energy', '/output', "`"$destino`"", '/duration', '60') -TimeoutSeconds 300
    } -Activity 'powercfg /energy'

    if (Test-Path -LiteralPath $destino) {
        Write-Log OK "Diagnostico de energia gerado: $destino"
        Add-CompartDiskFinding -Severity INFO -Area 'Energia' -Message 'Diagnostico de eficiencia energetica gerado.' -Recommendation "Arquivo: $destino"
        try { Start-Process $destino } catch { }
    } else {
        $script:result = 'WARN'
        Write-Log WARN 'O diagnostico de energia nao produziu arquivo de saida.'
    }

    $s = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $powercfg -Arguments @('/a') -TimeoutSeconds 60 } -Activity 'powercfg /a'
    if ($s.Success -and $s.Value.StdOut) {
        Write-Output $s.Value.StdOut
        Add-CompartDiskSection -Title 'Estados de suspensao disponiveis' -Status INFO -Pairs ([ordered]@{
            'powercfg /a' = ($s.Value.StdOut -replace '\s+', ' ').Trim()
        })
    }
}

try {
    if (-not (Start-CompartDiskModule -Name 'Battery' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }
    switch ($Action) {
        'Info'   { Show-BatteryInfo }
        'Report' { New-BatteryReport }
        'Sleep'  { New-SleepReport }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Battery (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Bateria' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
