<#
 COMPARTDISK 1.3.0 - Telemetry.ps1
 Desenvolvido por Edsilas
 Acoes: Status | Disable | Enable
 Alteracoes reversiveis: a acao Enable restaura o comportamento padrao do Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Disable', 'Enable')]
    [string]$Action = 'Status',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

$servicos = @('DiagTrack', 'dmwappushservice')
$tarefas  = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\Autochk\Proxy',
    '\Microsoft\Windows\Feedback\Siuf\DmClient'
)

function Show-TelemetryStatus {
    $pares = [ordered]@{}
    foreach ($s in $servicos) {
        try {
            $svc = Get-Service -Name $s -ErrorAction Stop
            $wmi = Get-CompartDiskCim -Class Win32_Service -Filter "Name='$s'"
            $pares["Servico $s"] = "$($svc.Status) / $(if ($wmi) { $wmi.StartMode } else { 'n/d' })"
        } catch { $pares["Servico $s"] = 'ausente neste build' }
    }

    $nivel = Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' $null
    $mapa = @{ 0 = '0 - Seguranca (somente Enterprise/Edu)'; 1 = '1 - Basico'; 2 = '2 - Avancado'; 3 = '3 - Completo' }
    $pares['Politica AllowTelemetry'] = $(if ($null -ne $nivel -and $mapa.ContainsKey([int]$nivel)) { $mapa[[int]$nivel] } else { 'nao definida (padrao do Windows)' })
    $pares['Feedback (Siuf)']         = $(if ((Get-CompartDiskRegistryValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' $null) -eq 0) { 'Desabilitado' } else { 'Padrao' })
    $pares['CEIP']                    = $(if ((Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows' 'CEIPEnable' $null) -eq 0) { 'Desabilitado' } else { 'Padrao' })
    $pares['Publicidade (Advertising ID)'] = $(if ((Get-CompartDiskRegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' $null) -eq 0) { 'Desabilitado' } else { 'Padrao' })

    $desativadas = 0
    foreach ($t in $tarefas) {
        try {
            $nome = Split-Path $t -Leaf
            $caminho = Split-Path $t -Parent
            $tk = Get-ScheduledTask -TaskName $nome -TaskPath "$caminho\" -ErrorAction Stop
            if ($tk.State -eq 'Disabled') { $desativadas++ }
        } catch { }
    }
    $pares['Tarefas de telemetria desativadas'] = "$desativadas de $($tarefas.Count)"

    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 34 }
    Add-CompartDiskSection -Title 'Telemetria e privacidade' -Status INFO -Pairs $pares
    Write-Log OK 'Status de telemetria coletado.'
}

function Set-Telemetry {
    param([bool]$Desabilitar)

    $alvo = if ($Desabilitar) { 'desativacao' } else { 'restauracao' }
    Write-Log INFO "Iniciando $alvo da telemetria da Microsoft..."

    # 1) Servicos
    foreach ($s in $servicos) {
        try {
            $svc = Get-Service -Name $s -ErrorAction Stop
            if ($Desabilitar) {
                if ($svc.Status -eq 'Running') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
                Set-Service -Name $s -StartupType Disabled -ErrorAction Stop
                Write-Log OK "Servico '$s' parado e desabilitado."
            } else {
                Set-Service -Name $s -StartupType Automatic -ErrorAction Stop
                Start-Service -Name $s -ErrorAction SilentlyContinue
                Write-Log OK "Servico '$s' restaurado para Automatico."
            }
        } catch {
            Write-Log WARN "Servico '$s' indisponivel neste build do Windows." -NoConsole
        }
    }

    # 2) Politicas de registro
    $valor = if ($Desabilitar) { 0 } else { 1 }
    $chaves = @(
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = $valor }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; N = 'AllowTelemetry'; V = $valor }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows'; N = 'CEIPEnable'; V = $valor }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; V = $valor }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'; N = 'NumberOfSIUFInPeriod'; V = $(if ($Desabilitar) { 0 } else { 1 }) }
    )
    foreach ($c in $chaves) { Set-CompartDiskRegistryValue -Path $c.P -Name $c.N -Value $c.V -Type DWord | Out-Null }

    if ($Desabilitar) {
        $ed = (Test-WindowsVersion).Caption
        if ($ed -notmatch 'Enterprise|Education|Server') {
            Write-Log INFO 'Edicao Home/Pro: o nivel minimo efetivo de diagnostico e "Basico" (nivel 1) por design do Windows.'
        }
    }

    # 3) Tarefas agendadas
    if (Test-CompartDiskCommand 'Get-ScheduledTask') {
        foreach ($t in $tarefas) {
            $nome = Split-Path $t -Leaf
            $caminho = (Split-Path $t -Parent) + '\'
            try {
                if ($Desabilitar) { Disable-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null }
                else              { Enable-ScheduledTask  -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null }
                Write-Log DEBUG "Tarefa '$nome' ajustada." -NoConsole
            } catch {
                Write-Log DEBUG "Tarefa '$nome' inexistente neste build." -NoConsole
            }
        }
        Write-Log OK 'Tarefas agendadas de telemetria ajustadas.'
    }

    if ($Desabilitar) {
        Add-CompartDiskFinding -Severity OK -Area 'Privacidade' -Message 'Telemetria da Microsoft desativada no nivel maximo permitido pela edicao.' -Recommendation 'Reversivel pela acao Enable deste modulo.'
        Write-Log OK 'Telemetria desativada.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Privacidade' -Message 'Configuracoes de telemetria restauradas ao padrao do Windows.'
        Write-Log OK 'Telemetria restaurada ao padrao.'
    }
    Show-TelemetryStatus
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('Disable', 'Enable') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Telemetry' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }
    switch ($Action) {
        'Status'  { Show-TelemetryStatus }
        'Disable' { Set-Telemetry -Desabilitar $true }
        'Enable'  { Set-Telemetry -Desabilitar $false }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Telemetry (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Privacidade' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
