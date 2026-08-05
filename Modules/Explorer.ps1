<#
 COMPARTDISK 1.3.0 - Explorer.ps1
 Desenvolvido por Edsilas
 Acoes: Restart | ClearCache | Spooler | ResetView
#>
[CmdletBinding()]
param(
    [ValidateSet('Restart', 'ClearCache', 'Spooler', 'ResetView')]
    [string]$Action = 'Restart',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Restart-ShellExplorer {
    Write-Log INFO 'Reiniciando o shell do Windows...'
    $antes = @(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count

    Invoke-SafeCommand {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
    } -Activity 'Encerrar explorer.exe' | Out-Null

    Start-Sleep -Seconds 2

    # O Windows reinicia o shell automaticamente quando ele e a shell padrao.
    $depois = @(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count
    if ($depois -eq 0) {
        Invoke-WithRetry -Activity 'Iniciar explorer.exe' -Retries 3 -DelaySeconds 2 -ScriptBlock {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction Stop
            Start-Sleep -Seconds 2
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { throw 'Explorer nao iniciou.' }
            $true
        } | Out-Null
    }

    $final = @(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count
    if ($final -gt 0) {
        Write-Log OK "Interface do Windows reiniciada ($antes -> $final processo(s))."
        Add-CompartDiskFinding -Severity OK -Area 'Explorer' -Message 'Shell do Windows reiniciado com sucesso.'
    } else {
        $script:result = 'ERROR'
        Write-Log ERR 'O Explorer nao voltou a executar. Use Ctrl+Shift+Esc > Arquivo > Executar nova tarefa > explorer.exe'
        Add-CompartDiskFinding -Severity CRIT -Area 'Explorer' -Message 'Shell do Windows nao reiniciou automaticamente.' -Recommendation 'Iniciar explorer.exe manualmente pelo Gerenciador de Tarefas.'
    }
}

function Clear-ShellCache {
    Write-Log INFO 'Limpando caches de icones e miniaturas...'
    $base = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    if (-not (Test-Path -LiteralPath $base)) {
        Write-Log WARN 'Diretorio de cache do Explorer nao encontrado.'
        return
    }

    # O Explorer mantem os arquivos abertos: encerrar primeiro
    Invoke-SafeCommand { Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force } -Activity 'Encerrar explorer' | Out-Null
    Start-Sleep -Seconds 2

    $liberado = 0
    $removidos = 0
    foreach ($padrao in @('thumbcache_*.db', 'iconcache_*.db')) {
        foreach ($f in (Get-ChildItem -LiteralPath $base -Filter $padrao -Force -ErrorAction SilentlyContinue)) {
            try {
                $sz = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $liberado += $sz
                $removidos++
            } catch { Write-Log DEBUG "Bloqueado: $($f.Name)" -NoConsole }
        }
    }

    $legado = Join-Path $env:LOCALAPPDATA 'IconCache.db'
    if (Test-Path -LiteralPath $legado) {
        try {
            $liberado += (Get-Item -LiteralPath $legado).Length
            Remove-Item -LiteralPath $legado -Force -ErrorAction Stop
            $removidos++
        } catch { }
    }

    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction SilentlyContinue

    Write-Log OK "$removidos arquivo(s) de cache removido(s), $(ConvertTo-CompartDiskSize $liberado) liberados."
    Add-CompartDiskSection -Title 'Cache do Explorer' -Status OK -Pairs ([ordered]@{
        'Arquivos removidos' = $removidos; 'Espaco liberado' = (ConvertTo-CompartDiskSize $liberado)
    })
    Add-CompartDiskFinding -Severity OK -Area 'Explorer' -Message "Cache de icones e miniaturas reconstruido ($removidos arquivos)."
}

function Reset-PrintSpooler {
    Write-Log INFO 'Limpando a fila de impressao...'
    $spool = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'

    $p = Set-CompartDiskServiceState -Name @('Spooler') -Action Stop
    if (-not $p[0].Success) {
        Write-Log WARN "Spooler nao parou: $($p[0].Detail)"
    }

    $r = Remove-CompartDiskPathSafely -Path $spool -KeepRoot
    Write-Log OK "$($r.Removed) trabalho(s) de impressao removido(s) ($(ConvertTo-CompartDiskSize $r.BytesFreed))."

    Set-CompartDiskServiceState -Name @('Spooler') -Action Start | Out-Null

    $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Log OK 'Servico de spooler reiniciado com sucesso.'
        Add-CompartDiskFinding -Severity OK -Area 'Impressao' -Message "Fila de impressao limpa ($($r.Removed) trabalhos)."
    } else {
        $script:result = 'WARN'
        Write-Log WARN 'O servico de spooler nao voltou ao estado Em execucao.'
        Add-CompartDiskFinding -Severity WARN -Area 'Impressao' -Message 'Servico Spooler nao esta em execucao apos o reset.' -Recommendation 'Verificar dependencias do servico e drivers de impressora corrompidos.'
    }

    $imp = Get-CompartDiskPrinters
    if ($imp.Count -gt 0) { Add-CompartDiskSection -Title 'Impressoras' -Status INFO -Rows $imp }
}

function Reset-FolderViews {
    Write-Log INFO 'Redefinindo as preferencias de exibicao de pastas...'
    $chaves = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\Shell\BagMRU',
        'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Bags',
        'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU',
        'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
    )
    $n = 0
    foreach ($k in $chaves) {
        if (Test-Path -LiteralPath $k) {
            $r = Invoke-SafeCommand { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop } -Activity "Remover $k"
            if ($r.Success) { $n++ }
        }
    }
    Write-Log OK "$n chave(s) de exibicao removida(s). Reiniciando o shell..."
    Restart-ShellExplorer
    Add-CompartDiskFinding -Severity OK -Area 'Explorer' -Message 'Preferencias de exibicao de pastas redefinidas ao padrao.'
}

try {
    $precisaAdmin = @('Spooler') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Explorer' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }
    switch ($Action) {
        'Restart'    { Restart-ShellExplorer }
        'ClearCache' { Clear-ShellCache }
        'Spooler'    { Reset-PrintSpooler }
        'ResetView'  { Reset-FolderViews }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Explorer (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Explorer' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
