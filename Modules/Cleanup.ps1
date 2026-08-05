<#
 COMPARTDISK 1.2.0 - Cleanup.ps1
 Desenvolvido por Edsilas
 Acoes: Analyze | Standard | Deep | Browsers | Logs
 Nenhum alvo remove arquivos necessarios ao funcionamento do Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Standard', 'Deep', 'Browsers', 'Logs')]
    [string]$Action = 'Analyze',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Get-CleanupTargets {
    param([switch]$IncludeDeep, [switch]$IncludeBrowsers, [switch]$IncludeLogs)

    $t = New-Object System.Collections.ArrayList

    $add = {
        param($nome, $caminho, $grupo, $manterRaiz = $true, $excluir = @(), $excluirPadrao = @())
        [void]$t.Add([pscustomobject]@{
            Nome = $nome; Caminho = $caminho; Grupo = $grupo; ManterRaiz = $manterRaiz
            Excluir = $excluir; ExcluirPadrao = $excluirPadrao
        })
    }

    # --- Padrao: sempre seguro
    # Na execucao remota o proprio pacote e extraido em %TEMP%\COMPARTDISK_<id>,
    # e o trace de inicializacao vive em %TEMP%\COMPARTDISK_Bootstrap.log. Limpar
    # o TEMP sem essa excecao apagaria os modulos da instancia em execucao.
    & $add 'Temp do usuario'          $env:TEMP 'Padrao' $true @() @('COMPARTDISK_*')
    & $add 'Temp do Windows'          (Join-Path $env:SystemRoot 'Temp') 'Padrao'
    & $add 'Cache do Windows Update'  (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') 'Padrao'
    & $add 'Delivery Optimization'    (Join-Path $env:SystemRoot 'SoftwareDistribution\DeliveryOptimization') 'Padrao'
    & $add 'Cache de miniaturas'      (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') 'Padrao' $true @()
    & $add 'INetCache'                (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache') 'Padrao'
    & $add 'Relatorios de erro (WER)' (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue') 'Padrao'
    & $add 'WER arquivados'           (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive') 'Padrao'
    & $add 'CrashDumps do usuario'    (Join-Path $env:LOCALAPPDATA 'CrashDumps') 'Padrao'

    if ($IncludeDeep) {
        & $add 'Prefetch'             (Join-Path $env:SystemRoot 'Prefetch') 'Profundo'
        & $add 'Minidumps'            (Join-Path $env:SystemRoot 'Minidump') 'Profundo'
        & $add 'Logs do CBS'          (Join-Path $env:SystemRoot 'Logs\CBS') 'Profundo'
        & $add 'Logs do DISM'         (Join-Path $env:SystemRoot 'Logs\DISM') 'Profundo'
        & $add 'Logs do WindowsUpdate' (Join-Path $env:SystemRoot 'Logs\WindowsUpdate') 'Profundo'
        & $add 'Cache de fontes'      (Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache') 'Profundo'
        & $add 'Downloaded Program Files' (Join-Path $env:SystemRoot 'Downloaded Program Files') 'Profundo'
    }

    if ($IncludeBrowsers) {
        $navegadores = @(
            @{ N = 'Microsoft Edge'; P = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') }
            @{ N = 'Google Chrome';  P = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') }
            @{ N = 'Brave';          P = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') }
        )
        $subcaches = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache')
        foreach ($nav in $navegadores) {
            if (-not (Test-Path -LiteralPath $nav.P)) { continue }
            foreach ($perfil in (Get-ChildItem -LiteralPath $nav.P -Directory -ErrorAction SilentlyContinue)) {
                if ($perfil.Name -notmatch '^(Default|Profile \d+|Guest Profile)$') { continue }
                foreach ($sc in $subcaches) {
                    $full = Join-Path $perfil.FullName $sc
                    if (Test-Path -LiteralPath $full) {
                        & $add "$($nav.N) / $($perfil.Name) / $sc" $full 'Navegadores'
                    }
                }
            }
        }
        # Firefox (cache2)
        $ff = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $ff) {
            foreach ($p in (Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) {
                $c = Join-Path $p.FullName 'cache2'
                if (Test-Path -LiteralPath $c) { & $add "Firefox / $($p.Name) / cache2" $c 'Navegadores' }
            }
        }
    }

    return @($t)
}

function Invoke-CleanupAnalysis {
    param([object[]]$Targets)
    Write-Log INFO "Analisando $($Targets.Count) alvo(s) sem remover nada..."
    $rows = New-Object System.Collections.ArrayList
    $total = 0
    foreach ($t in $Targets) {
        $s = Get-CompartDiskFolderSize -Path $t.Caminho
        if (-not $s.Exists) { continue }
        $total += $s.Bytes
        [void]$rows.Add([pscustomobject]@{
            Grupo    = $t.Grupo
            Alvo     = $t.Nome
            Arquivos = $s.Files
            Tamanho  = (ConvertTo-CompartDiskSize $s.Bytes)
            Bytes    = $s.Bytes
            Caminho  = $t.Caminho
        })
    }
    $ordenado = @($rows | Sort-Object Bytes -Descending)
    $ordenado | Select-Object Grupo, Alvo, Arquivos, Tamanho | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

    Write-Color ''
    Write-Color ("  Potencial de liberacao: {0}" -f (ConvertTo-CompartDiskSize $total)) -Color Green

    Add-CompartDiskSection -Title 'Analise de limpeza (simulacao)' -Status INFO -Rows $ordenado `
        -Summary ("Potencial de liberacao: {0}" -f (ConvertTo-CompartDiskSize $total))
    Add-CompartDiskFinding -Severity INFO -Area 'Limpeza' -Message "Analise concluida: $(ConvertTo-CompartDiskSize $total) recuperaveis." -Recommendation 'Executar a limpeza padrao ou profunda para liberar o espaco.'
    Write-Log OK "Analise concluida. Potencial: $(ConvertTo-CompartDiskSize $total)."
}

function Invoke-Cleanup {
    param([object[]]$Targets)

    $antesLivre = 0
    try { $antesLivre = (Get-CompartDiskCim -Class Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'").FreeSpace } catch { }

    $rows = New-Object System.Collections.ArrayList
    $totalLiberado = 0
    $bloqueadosTotal = 0

    foreach ($t in $Targets) {
        if (-not (Test-Path -LiteralPath $t.Caminho)) { continue }
        $antes = Get-CompartDiskFolderSize -Path $t.Caminho
        $r = Remove-CompartDiskPathSafely -Path $t.Caminho -KeepRoot:$t.ManterRaiz -ExcludeNames $t.Excluir -ExcludePatterns $t.ExcluirPadrao

        $totalLiberado   += $r.BytesFreed
        $bloqueadosTotal += $r.Failed

        [void]$rows.Add([pscustomobject]@{
            Grupo     = $t.Grupo
            Alvo      = $t.Nome
            Antes     = (ConvertTo-CompartDiskSize $antes.Bytes)
            Liberado  = (ConvertTo-CompartDiskSize $r.BytesFreed)
            Removidos = $r.Removed
            EmUso     = $r.Failed
        })
        Write-Log OK ("{0}: {1} liberados ({2} itens removidos, {3} em uso)" -f $t.Nome, (ConvertTo-CompartDiskSize $r.BytesFreed), $r.Removed, $r.Failed)
    }

    # Lixeira: usa a API nativa do Shell (nao remove pastas de sistema)
    if (Test-CompartDiskCommand 'Clear-RecycleBin') {
        $r = Invoke-SafeCommand { Clear-RecycleBin -Force -ErrorAction Stop } -Activity 'Esvaziar lixeira'
        if ($r.Success) { Write-Log OK 'Lixeira esvaziada.' }
    }

    # Cache DNS
    Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\ipconfig.exe') -Arguments @('/flushdns') -TimeoutSeconds 30
    } -Activity 'Limpar cache DNS' | Out-Null
    Write-Log OK 'Cache DNS limpo.'

    $depoisLivre = 0
    try { $depoisLivre = (Get-CompartDiskCim -Class Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'").FreeSpace } catch { }
    $delta = $depoisLivre - $antesLivre

    Write-Color ''
    Write-Color ("  {0} : {1}" -f "Total liberado (soma dos alvos)".PadRight(30), (ConvertTo-CompartDiskSize $totalLiberado)) -Color Green
    if ($delta -gt 0) {
        Write-Color ("  {0} : {1}" -f ("Ganho real em $env:SystemDrive").PadRight(30), (ConvertTo-CompartDiskSize $delta)) -Color Green
    }
    if ($bloqueadosTotal -gt 0) {
        Write-Color ("  {0} : {1}" -f "Itens em uso (ignorados)".PadRight(30), $bloqueadosTotal) -Color Yellow
    }

    Add-CompartDiskSection -Title 'Limpeza executada' -Status OK -Rows @($rows) -Summary ("Liberado: {0}" -f (ConvertTo-CompartDiskSize $totalLiberado))
    Add-CompartDiskFinding -Severity OK -Area 'Limpeza' -Message "Limpeza concluida: $(ConvertTo-CompartDiskSize $totalLiberado) liberados." `
        -Recommendation $(if ($bloqueadosTotal -gt 0) { "$bloqueadosTotal item(ns) estavam em uso; repetir apos reiniciar." } else { '' })

    Write-Log OK "Limpeza finalizada. Total: $(ConvertTo-CompartDiskSize $totalLiberado)."
}

function Clear-EventLogs {
    Write-Log WARN 'Os logs de eventos serao apagados. Isso afeta a capacidade de auditoria futura.'
    $exportar = Join-Path $Global:CompartDisk.OutDir 'EventLogs_Backup'
    if (-not (Test-Path -LiteralPath $exportar)) { New-Item -ItemType Directory -Path $exportar -Force | Out-Null }

    $wevtutil = Join-Path $env:SystemRoot 'System32\wevtutil.exe'
    if (-not (Test-Path -LiteralPath $wevtutil)) {
        Write-Log ERR 'wevtutil.exe nao localizado.'
        $script:result = 'ERROR'
        return
    }

    # Exporta os principais antes de limpar (reversibilidade).
    # O exito e medido pelo arquivo efetivamente produzido, e nao pela ausencia de
    # excecao: a limpeza abaixo e irreversivel e nao pode ser precedida por um
    # "backup concluido" que nunca existiu.
    $exportados = 0
    foreach ($log in @('System', 'Application', 'Security')) {
        $dest = Join-Path $exportar "$log.evtx"
        $e = Invoke-SafeCommand {
            Invoke-NativeCommand -FilePath $wevtutil -Arguments @('epl', "`"$log`"", "`"$dest`"") -TimeoutSeconds 120
        } -Activity "Exportar log $log"
        if ($e.Success -and $e.Value -and $e.Value.ExitCode -eq 0 -and (Test-Path -LiteralPath $dest)) {
            $exportados++
        } else {
            Write-Log WARN "Log '$log' nao pode ser exportado. Ele sera limpo SEM copia de seguranca."
        }
    }
    if ($exportados -gt 0) {
        Write-Log OK "Backup de $exportados de 3 log(s) principal(is) em: $exportar"
    } else {
        Write-Log ERR 'Nenhum log pode ser exportado. A limpeza prosseguira SEM copia de seguranca.'
        $script:result = 'WARN'
    }

    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $wevtutil -Arguments @('el') -TimeoutSeconds 60 } -Activity 'Listar logs'
    $limpos = 0; $falhas = 0
    if ($r.Success -and $r.Value.StdOut) {
        foreach ($log in ($r.Value.StdOut -split '\r?\n')) {
            $nome = $log.Trim()
            if (-not $nome) { continue }
            $c = Invoke-NativeCommand -FilePath $wevtutil -Arguments @('cl', "`"$nome`"") -TimeoutSeconds 30
            if ($c.ExitCode -eq 0) { $limpos++ } else { $falhas++ }
        }
    }
    Write-Log OK "$limpos log(s) limpos, $falhas nao puderam ser limpos (protegidos pelo sistema)."

    $dumps = @(
        (Join-Path $env:SystemRoot 'Minidump')
        (Join-Path $env:SystemRoot 'MEMORY.DMP')
    )
    $lib = 0
    foreach ($d in $dumps) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        if (Test-Path -LiteralPath $d -PathType Leaf) {
            $sz = (Get-Item -LiteralPath $d).Length
            Invoke-SafeCommand { Remove-Item -LiteralPath $d -Force -ErrorAction Stop } -Activity "Remover $d" | Out-Null
            $lib += $sz
        } else {
            $r2 = Remove-CompartDiskPathSafely -Path $d -KeepRoot
            $lib += $r2.BytesFreed
        }
    }

    Add-CompartDiskSection -Title 'Limpeza de logs e dumps' -Status OK -Pairs ([ordered]@{
        'Logs limpos'      = $limpos
        'Logs protegidos'  = $falhas
        'Dumps liberados'  = (ConvertTo-CompartDiskSize $lib)
        'Backup dos logs'  = $(if ($exportados -gt 0) { "$exportar ($exportados de 3)" } else { 'NENHUM - exportacao falhou' })
    })
    Add-CompartDiskFinding -Severity $(if ($exportados -gt 0) { 'INFO' } else { 'WARN' }) -Area 'Limpeza' `
        -Message "$limpos log(s) de eventos limpos." `
        -Recommendation $(if ($exportados -gt 0) { "Backup preservado em $exportar" } else { 'Nenhum log pode ser exportado antes da limpeza.' })
}

# ------------------------------------------------------------------------------
try {
    if (-not (Start-CompartDiskModule -Name 'Cleanup' -Action $Action -RequireAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'Analyze' {
            Invoke-CleanupAnalysis -Targets (Get-CleanupTargets -IncludeDeep -IncludeBrowsers)
        }
        'Standard' {
            Invoke-Cleanup -Targets (Get-CleanupTargets)
        }
        'Deep' {
            Invoke-Cleanup -Targets (Get-CleanupTargets -IncludeDeep -IncludeBrowsers)
        }
        'Browsers' {
            Invoke-Cleanup -Targets (Get-CleanupTargets -IncludeBrowsers | Where-Object { $_.Grupo -eq 'Navegadores' })
        }
        'Logs' {
            Clear-EventLogs
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Cleanup (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Limpeza' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
