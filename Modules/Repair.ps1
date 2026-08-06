<#
 COMPARTDISK 1.3.1 - Repair.ps1
 Desenvolvido por Edsilas
 Acoes: Full | Sfc | Dism | Scan | Chkdsk | Component
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Sfc', 'Dism', 'Scan', 'Chkdsk', 'Component')]
    [string]$Action = 'Full',
    [string]$Drive = 'C:',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'
$sfcExe  = Join-Path $env:SystemRoot 'System32\sfc.exe'
$dismExe = Join-Path $env:SystemRoot 'System32\Dism.exe'

function Invoke-Sfc {
    Write-Log INFO 'Iniciando System File Checker (sfc /scannow). Pode levar varios minutos...'
    if (-not (Test-Path -LiteralPath $sfcExe)) {
        Write-Log ERR 'sfc.exe nao localizado no sistema.'
        $script:result = 'ERROR'
        return
    }
    # SFC precisa escrever no console: execucao direta preserva a barra de progresso
    & $sfcExe /scannow
    $rc = $LASTEXITCODE

    $log = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    $corrigidos = 0; $naoCorrigidos = 0
    if (Test-Path -LiteralPath $log) {
        try {
            $texto = Get-Content -LiteralPath $log -Tail 4000 -ErrorAction Stop
            $corrigidos    = @($texto | Select-String -Pattern 'Repairing corrupted file|Repaired file' -SimpleMatch:$false).Count
            $naoCorrigidos = @($texto | Select-String -Pattern 'cannot repair member file|Cannot repair').Count
        } catch { }
    }

    $pares = [ordered]@{
        'Codigo de retorno'      = $rc
        'Reparos detectados'     = $corrigidos
        'Falhas de reparo'       = $naoCorrigidos
        'Log de referencia'      = $log
    }
    Add-CompartDiskSection -Title 'System File Checker' -Status $(if ($naoCorrigidos -gt 0) { 'CRIT' } elseif ($corrigidos -gt 0) { 'WARN' } else { 'OK' }) `
        -Summary "Retorno $rc" -Pairs $pares

    if ($naoCorrigidos -gt 0) {
        $script:result = 'WARN'
        Add-CompartDiskFinding -Severity CRIT -Area 'Integridade' -Message 'SFC encontrou arquivos que nao pode reparar.' -Recommendation 'Executar DISM /RestoreHealth e repetir o SFC.'
    } elseif ($corrigidos -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Integridade' -Message 'SFC reparou arquivos de sistema corrompidos.' -Recommendation 'Reiniciar e executar novamente para confirmar.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Integridade' -Message 'SFC nao encontrou violacoes de integridade.'
    }
    Write-Log OK "SFC finalizado (codigo $rc)."
}

function Invoke-Dism {
    param([ValidateSet('ScanHealth', 'CheckHealth', 'RestoreHealth', 'AnalyzeComponentStore', 'StartComponentCleanup')][string]$Op = 'RestoreHealth')

    Write-Log INFO "Executando DISM /Online /Cleanup-Image /$Op ..."

    # Preferencia por cmdlet nativo quando disponivel (melhor tratamento de erro)
    if ($Op -in @('ScanHealth', 'CheckHealth', 'RestoreHealth') -and (Test-CompartDiskCommand 'Repair-WindowsImage')) {
        $r = Invoke-SafeCommand {
            switch ($Op) {
                'ScanHealth'    { Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop }
                'CheckHealth'   { Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop }
                'RestoreHealth' { Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop }
            }
        } -Activity "Repair-WindowsImage $Op"

        if ($r.Success -and $r.Value) {
            $saude = "$($r.Value.ImageHealthState)"
            Write-CompartDiskKeyValue 'Estado da imagem' $saude
            Add-CompartDiskSection -Title "DISM $Op" -Status $(if ($saude -eq 'Healthy') { 'OK' } else { 'WARN' }) `
                -Pairs ([ordered]@{ 'Estado da imagem' = $saude; 'Reinicio necessario' = $r.Value.RestartNeeded })
            if ($saude -eq 'Healthy') {
                Add-CompartDiskFinding -Severity OK -Area 'Imagem do Windows' -Message "DISM ${Op}: imagem integra."
            } else {
                $script:result = 'WARN'
                Add-CompartDiskFinding -Severity WARN -Area 'Imagem do Windows' -Message "DISM reportou estado '$saude'." -Recommendation 'Executar RestoreHealth e, em seguida, SFC.'
            }
            Write-Log OK "DISM $Op concluido via cmdlet nativo."
            return
        }
        Write-Log WARN 'Cmdlet Repair-WindowsImage indisponivel ou falhou. Usando Dism.exe.'
    }

    if (-not (Test-Path -LiteralPath $dismExe)) {
        Write-Log ERR 'Dism.exe nao localizado.'
        $script:result = 'ERROR'
        return
    }

    & $dismExe /Online /Cleanup-Image "/$Op"
    $rc = $LASTEXITCODE
    $ok = ($rc -eq 0 -or $rc -eq 3010)
    Add-CompartDiskSection -Title "DISM $Op" -Status $(if ($ok) { 'OK' } else { 'WARN' }) -Pairs ([ordered]@{
        'Codigo de retorno'   = $rc
        'Reinicio necessario' = $(if ($rc -eq 3010) { 'Sim' } else { 'Nao' })
        'Log'                 = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log')
    })
    if ($ok) {
        Write-Log OK "DISM $Op concluido (codigo $rc)."
        Add-CompartDiskFinding -Severity OK -Area 'Imagem do Windows' -Message "DISM $Op concluido com sucesso."
    } else {
        $script:result = 'WARN'
        Write-Log WARN "DISM $Op retornou codigo $rc."
        Add-CompartDiskFinding -Severity WARN -Area 'Imagem do Windows' -Message "DISM $Op retornou codigo $rc." -Recommendation 'Consultar %SystemRoot%\Logs\DISM\dism.log. Sem rede, usar fonte WIM/ESD local.'
    }
}

function Invoke-ComponentStore {
    Write-Log INFO 'Analisando o armazenamento de componentes (WinSxS)...'
    & $dismExe /Online /Cleanup-Image /AnalyzeComponentStore
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { Write-Log WARN "AnalyzeComponentStore retornou $rc." }

    $tam = Get-CompartDiskFolderSize -Path (Join-Path $env:SystemRoot 'WinSxS')
    Add-CompartDiskSection -Title 'Armazenamento de componentes' -Status INFO -Pairs ([ordered]@{
        'WinSxS (tamanho aparente)' = (ConvertTo-CompartDiskSize $tam.Bytes)
        'Arquivos'                  = $tam.Files
        'Codigo de analise'         = $rc
    })
    Write-Log INFO 'Nota: o tamanho aparente do WinSxS inclui hardlinks e nao reflete o espaco real ocupado.'
    Write-Log OK 'Analise do armazenamento de componentes concluida.'
}

function Register-ChkdskScan {
    param([string]$Volume = 'C:')
    $letra = $Volume.TrimEnd('\').TrimEnd(':')
    Write-Log INFO "Agendando verificacao de disco para o volume $letra`: ..."

    # Metodo preferencial: marcar o volume como sujo (dirty bit) - nao interativo
    $agendado = $false
    if (Test-CompartDiskCommand 'Repair-Volume') {
        $r = Invoke-SafeCommand { Repair-Volume -DriveLetter $letra -Scan -ErrorAction Stop } -Activity "Repair-Volume -Scan $letra"
        if ($r.Success) {
            Write-Log OK "Varredura online concluida: $($r.Value)"
            if ("$($r.Value)" -ne 'NoErrorsFound') {
                Add-CompartDiskFinding -Severity WARN -Area 'Disco' -Message "Repair-Volume reportou '$($r.Value)' em $letra`:" -Recommendation 'Agendar reparo offline no proximo boot.'
                $script:result = 'WARN'
            } else {
                Add-CompartDiskFinding -Severity OK -Area 'Disco' -Message "Volume $letra`: sem erros de sistema de arquivos."
            }
        }
    }

    $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    $chkntfs = Join-Path $env:SystemRoot 'System32\chkntfs.exe'
    if (Test-Path -LiteralPath $fsutil) {
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $fsutil -Arguments @('dirty', 'set', "$letra`:") -TimeoutSeconds 30 } -Activity 'Marcar volume para verificacao'
        if ($r.Success -and $r.Value.ExitCode -eq 0) { $agendado = $true }
    }

    if ($agendado) {
        Write-Log OK "Verificacao completa agendada para $letra`: no proximo reinicio."
        Add-CompartDiskFinding -Severity INFO -Area 'Disco' -Message "CHKDSK agendado para $letra`: no proximo boot." -Recommendation 'Reiniciar o computador quando possivel; a verificacao pode demorar.'
    } else {
        $script:result = 'WARN'
        Write-Log WARN 'Nao foi possivel agendar a verificacao automaticamente.'
    }

    if (Test-Path -LiteralPath $chkntfs) {
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $chkntfs -Arguments @("$letra`:") -TimeoutSeconds 30 } -Activity 'Consultar agendamento'
        if ($r.Success) { Write-Output $r.Value.StdOut }
    }
}

# ------------------------------------------------------------------------------
try {
    if (-not (Start-CompartDiskModule -Name 'Repair' -Action $Action -RequireAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'Sfc'       { Invoke-Sfc }
        'Dism'      { Invoke-Dism -Op RestoreHealth }
        'Scan'      { Invoke-Dism -Op ScanHealth }
        'Component' { Invoke-ComponentStore }
        'Chkdsk'    { Register-ChkdskScan -Volume $Drive }
        'Full' {
            Write-Log INFO '=== REPARO PROFUNDO: DISM ScanHealth -> RestoreHealth -> SFC ==='
            Invoke-Dism -Op ScanHealth
            Invoke-Dism -Op RestoreHealth
            Invoke-Sfc
            if (Test-CompartDiskPendingReboot) {
                Add-CompartDiskFinding -Severity WARN -Area 'Sistema' -Message 'Ha um reinicio pendente.' -Recommendation 'Reiniciar antes de novas manutencoes.'
                Write-Log WARN 'Reinicio pendente detectado.'
            }
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Repair (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Reparo' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
