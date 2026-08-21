<#
 COMPARTDISK 1.4.6 - Telemetry.ps1
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
    # EVIDENCIA: a versao anterior gravava "Servico 'X' parado e desabilitado"
    # logo apos as chamadas, sem reler nada, e o Stop-Service usava
    # -ErrorAction SilentlyContinue: uma parada recusada nao aparecia em lugar
    # nenhum e a linha de sucesso saia do mesmo jeito. Um unico catch generico
    # ainda classificava qualquer erro - inclusive acesso negado - como
    # "indisponivel neste build". Agora: executar, reler, e so entao registrar.
    $svcOk = 0; $svcFalha = 0; $svcAusente = 0
    foreach ($s in $servicos) {
        $svc = $null
        try { $svc = Get-Service -Name $s -ErrorAction Stop }
        catch {
            $svcAusente++
            Write-Log INFO "Servico '$s' inexistente neste build do Windows." -NoConsole
            continue
        }

        try {
            if ($Desabilitar) {
                if ($svc.Status -eq 'Running') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
                Set-Service -Name $s -StartupType Disabled -ErrorAction Stop
            } else {
                Set-Service -Name $s -StartupType Automatic -ErrorAction Stop
                Start-Service -Name $s -ErrorAction SilentlyContinue
            }
        } catch {
            $svcFalha++
            Write-Log WARN "Servico '$s': alteracao recusada - $($_.Exception.Message)"
            continue
        }

        $estado = 'n/d'; $modo = 'n/d'
        try {
            $estado = "$((Get-Service -Name $s -ErrorAction Stop).Status)"
            $wmi = Get-CompartDiskCim -Class Win32_Service -Filter "Name='$s'"
            if ($wmi) { $modo = "$($wmi.StartMode)" }
        } catch {
            Write-Log DEBUG "Releitura do servico '$s' falhou: $($_.Exception.Message)" -NoConsole
        }

        if ($Desabilitar) {
            $modoOk   = ("$modo"   -match '(?i)disabled|desabilitad|desativad')
            $estadoOk = ("$estado" -match '(?i)stopped|parado')
            if ($modoOk -and $estadoOk) {
                $svcOk++
                Write-Log OK "Servico '$s' parado e desabilitado (confirmado por releitura)."
            } elseif ($modoOk) {
                $svcFalha++
                Write-Log WARN "Servico '$s' desabilitado, mas ainda em execucao (estado=$estado): a parada so se consolida no proximo reinicio."
            } else {
                $svcFalha++
                Write-Log WARN "Servico '$s' nao ficou desabilitado: inicializacao=$modo, estado=$estado."
            }
        } else {
            $modoOk = ("$modo" -match '(?i)auto')
            if ($modoOk) {
                $svcOk++
                Write-Log OK "Servico '$s' restaurado para Automatico (confirmado por releitura; estado=$estado)."
            } else {
                $svcFalha++
                Write-Log WARN "Servico '$s' nao voltou para Automatico: inicializacao=$modo, estado=$estado."
            }
        }
    }
    Write-Log DEBUG ("Servicos de telemetria: {0} confirmado(s), {1} sem confirmacao, {2} inexistente(s) neste build." -f $svcOk, $svcFalha, $svcAusente) -NoConsole

    # 2) Politicas de registro
    $valor = if ($Desabilitar) { 0 } else { 1 }
    $chaves = @(
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = $valor }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; N = 'AllowTelemetry'; V = $valor }
        @{ P = 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows'; N = 'CEIPEnable'; V = $valor }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; V = $valor }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'; N = 'NumberOfSIUFInPeriod'; V = $(if ($Desabilitar) { 0 } else { 1 }) }
    )
    # Set-CompartDiskRegistryValue ja releia e devolve $false quando o valor nao
    # se confirma. O retorno era jogado fora com Out-Null: uma diretiva ou ACL
    # que recusasse a gravacao nao mudava em nada o desfecho do modulo.
    $regFalhas = New-Object System.Collections.ArrayList
    foreach ($c in $chaves) {
        if (-not (Set-CompartDiskRegistryValue -Path $c.P -Name $c.N -Value $c.V -Type DWord)) {
            [void]$regFalhas.Add("$($c.P)\$($c.N)")
        }
    }

    if ($Desabilitar) {
        $ed = (Test-WindowsVersion).Caption
        if ($ed -notmatch 'Enterprise|Education|Server') {
            Write-Log INFO 'Edicao Home/Pro: o nivel minimo efetivo de diagnostico e "Basico" (nivel 1) por design do Windows.'
        }
    }

    # 3) Tarefas agendadas
    # EVIDENCIA: a linha "Tarefas agendadas de telemetria ajustadas." era escrita
    # fora do laco e sem condicao alguma - saia identica com seis tarefas
    # ajustadas ou com seis falhas. Alem disso, o unico catch tratava acesso
    # negado (comum nestas tarefas, protegidas pelo TrustedInstaller) como
    # "inexistente neste build". A existencia passa a ser verificada antes, e o
    # resultado, depois.
    $tkOk = 0; $tkFalha = 0; $tkAusente = 0
    $tkProblema = New-Object System.Collections.ArrayList
    if (Test-CompartDiskCommand 'Get-ScheduledTask') {
        foreach ($t in $tarefas) {
            $nome = Split-Path $t -Leaf
            $caminho = (Split-Path $t -Parent) + '\'

            try { Get-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null }
            catch {
                $tkAusente++
                Write-Log DEBUG "Tarefa '$nome' inexistente neste build." -NoConsole
                continue
            }

            try {
                if ($Desabilitar) { Disable-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null }
                else              { Enable-ScheduledTask  -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null }
            } catch {
                $tkFalha++
                [void]$tkProblema.Add($nome)
                Write-Log WARN "Tarefa '$nome' nao pode ser ajustada: $($_.Exception.Message)"
                continue
            }

            $estadoTk = 'n/d'
            try { $estadoTk = "$((Get-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop).State)" }
            catch { Write-Log DEBUG "Releitura da tarefa '$nome' falhou: $($_.Exception.Message)" -NoConsole }

            $esperado = $(if ($Desabilitar) { '(?i)disabled|desabilitad' } else { '(?i)ready|running|pronto' })
            if ($estadoTk -match $esperado) {
                $tkOk++
                Write-Log DEBUG "Tarefa '$nome' ajustada (estado=$estadoTk)." -NoConsole
            } else {
                $tkFalha++
                [void]$tkProblema.Add($nome)
                Write-Log WARN "Tarefa '$nome': comando aceito, mas o estado relido e '$estadoTk'."
            }
        }

        if ($tkFalha -eq 0) {
            Write-Log OK ("Tarefas agendadas de telemetria ajustadas: {0} de {1} confirmada(s) por releitura; {2} inexistente(s) neste build." -f $tkOk, $tarefas.Count, $tkAusente)
        } else {
            Write-Log WARN ("Tarefas agendadas de telemetria: {0} confirmada(s), {1} nao ajustada(s) ({2}), {3} inexistente(s) neste build." -f `
                $tkOk, $tkFalha, ((@($tkProblema) | Select-Object -Unique) -join ', '), $tkAusente)
        }
    }

    # Desfecho construido sobre o que foi confirmado, e nao sobre o fato de o
    # modulo ter chegado ao fim sem excecao.
    $pendencias = New-Object System.Collections.ArrayList
    if ($svcFalha -gt 0)         { [void]$pendencias.Add("$svcFalha servico(s) nao confirmado(s)") }
    if ($regFalhas.Count -gt 0)  { [void]$pendencias.Add("$($regFalhas.Count) chave(s) de registro sem confirmacao: $((@($regFalhas)) -join ', ')") }
    if ($tkFalha -gt 0)          { [void]$pendencias.Add("$tkFalha tarefa(s) agendada(s) nao ajustada(s)") }

    if ($pendencias.Count -gt 0) {
        $script:result = 'WARN'
        $resumo = ($pendencias -join '; ')
        if ($Desabilitar) {
            Add-CompartDiskFinding -Severity WARN -Area 'Privacidade' -Message "Telemetria desativada parcialmente: $resumo." `
                -Recommendation 'Verificar diretivas de grupo/MDM e privilegios administrativos, e repetir apos reiniciar. Reversivel pela acao Enable deste modulo.'
            Write-Log WARN "Telemetria desativada parcialmente: $resumo."
        } else {
            Add-CompartDiskFinding -Severity WARN -Area 'Privacidade' -Message "Restauracao parcial das configuracoes de telemetria: $resumo." `
                -Recommendation 'Verificar diretivas de grupo/MDM e privilegios administrativos, e repetir apos reiniciar.'
            Write-Log WARN "Telemetria restaurada parcialmente: $resumo."
        }
    } elseif ($Desabilitar) {
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
