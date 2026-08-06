<#
 COMPARTDISK 1.3.1 - Drivers.ps1
 Desenvolvido por Edsilas
 Acoes: List | Problems | Backup | Unsigned | Export
#>
[CmdletBinding()]
param(
    [ValidateSet('List', 'Problems', 'Backup', 'Unsigned', 'Export')]
    [string]$Action = 'List',
    [string]$Path = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'
$pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'

function Show-Drivers {
    $d = Get-CompartDiskDriverInfo
    if ($d.Count -eq 0) {
        Write-Log WARN 'Nao foi possivel enumerar os drivers.'
        $script:result = 'WARN'
        return
    }
    $ordenado = @($d | Sort-Object Data -Descending)
    $ordenado | Select-Object -First 40 | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
    Write-Color ("`n  Total de drivers assinados enumerados: {0}" -f $d.Count) -Color White

    Add-CompartDiskSection -Title 'Drivers instalados' -Status OK -Rows $ordenado -Summary "$($d.Count) driver(s)"

    # Drivers antigos (> 5 anos) que ainda estejam ativos
    $limite = (Get-Date).AddYears(-5)
    $antigos = @($d | Where-Object {
        $_.Data -ne 'n/d' -and (try { [datetime]::Parse($_.Data) -lt $limite } catch { $false })
    })
    if ($antigos.Count -gt 0) {
        Write-Log INFO "$($antigos.Count) driver(s) com mais de 5 anos."
        Add-CompartDiskFinding -Severity INFO -Area 'Drivers' -Message "$($antigos.Count) driver(s) com data anterior a $($limite.Year)." -Recommendation 'Normal para componentes inbox do Windows; avaliar apenas os de hardware dedicado.'
    }
    Write-Log OK "$($d.Count) driver(s) inventariado(s)."
}

function Show-Unsigned {
    $d = Get-CompartDiskDriverInfo
    $naoAssinados = @($d | Where-Object { $_.Assinado -eq 'NAO' })
    if ($naoAssinados.Count -eq 0) {
        Write-Log OK 'Todos os drivers enumerados possuem assinatura digital.'
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' -Message 'Nenhum driver sem assinatura digital.'
        return
    }
    $naoAssinados | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
    Add-CompartDiskSection -Title 'Drivers sem assinatura digital' -Status WARN -Rows $naoAssinados -Summary "$($naoAssinados.Count) driver(s)"
    Add-CompartDiskFinding -Severity WARN -Area 'Drivers' -Message "$($naoAssinados.Count) driver(s) sem assinatura digital." -Recommendation 'Validar a origem: drivers nao assinados sao vetor comum de instabilidade e comprometimento.'
    $script:result = 'WARN'
    Write-Log WARN "$($naoAssinados.Count) driver(s) sem assinatura."
}

function Show-Problems {
    $p = Get-CompartDiskDriverInfo -OnlyProblems
    if ($p.Count -eq 0) {
        Write-Log OK 'Nenhum dispositivo com codigo de erro.'
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' -Message 'Nenhum dispositivo com problema no Gerenciador de Dispositivos.'
        return
    }
    $p | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
    Add-CompartDiskSection -Title 'Dispositivos com problema' -Status CRIT -Rows $p -Summary "$($p.Count) dispositivo(s)"
    foreach ($d in ($p | Select-Object -First 15)) {
        Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' -Message "$($d.Dispositivo): $($d.Descricao)" -Recommendation 'Atualizar ou reinstalar o driver; verificar conexao fisica do dispositivo.'
    }
    $script:result = 'WARN'
    Write-Log WARN "$($p.Count) dispositivo(s) com problema."
}

function Backup-Drivers {
    param([string]$Destino)

    if ([string]::IsNullOrWhiteSpace($Destino)) {
        $Destino = Join-Path $Global:CompartDisk.OutDir 'Backup_Drivers'
    }
    if (-not (Test-Path -LiteralPath $pnputil)) {
        Write-Log ERR 'pnputil.exe nao localizado neste sistema.'
        $script:result = 'ERROR'
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Destino)) { New-Item -ItemType Directory -Path $Destino -Force | Out-Null }
    } catch {
        Write-Log ERR "Nao foi possivel criar o diretorio de destino: $Destino" -ErrorRecord $_
        $script:result = 'ERROR'
        return
    }

    # Verifica espaco livre antes de exportar
    try {
        $drive = (Get-Item -LiteralPath $Destino).PSDrive.Name
        $livre = (Get-CompartDiskCim -Class Win32_LogicalDisk -Filter "DeviceID='$drive`:'").FreeSpace
        if ($livre -lt 2GB) {
            Write-Log WARN "Espaco livre baixo em $drive`: ($(ConvertTo-CompartDiskSize $livre)). A exportacao pode falhar."
        }
    } catch { }

    Write-Log INFO "Exportando drivers de terceiros para: $Destino"
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $pnputil -Arguments @('/export-driver', '*', "`"$Destino`"") -TimeoutSeconds 1800
    } -Activity 'pnputil /export-driver' -Critical

    $pacotes = 0
    try { $pacotes = @(Get-ChildItem -LiteralPath $Destino -Directory -ErrorAction SilentlyContinue).Count } catch { }
    $tam = Get-CompartDiskFolderSize -Path $Destino

    if ($r.Success -and $r.Value.ExitCode -eq 0 -and $pacotes -gt 0) {
        Write-Log OK "$pacotes pacote(s) de driver exportado(s) ($(ConvertTo-CompartDiskSize $tam.Bytes))."
        Add-CompartDiskSection -Title 'Backup de drivers' -Status OK -Pairs ([ordered]@{
            'Destino' = $Destino; 'Pacotes' = $pacotes; 'Tamanho' = (ConvertTo-CompartDiskSize $tam.Bytes)
        })
        Add-CompartDiskFinding -Severity OK -Area 'Drivers' -Message "$pacotes pacote(s) de driver exportado(s)." -Recommendation "Copiar $Destino para midia externa antes de reinstalar o Windows."
    } else {
        $script:result = 'WARN'
        Write-Log WARN "Exportacao retornou codigo $(if ($r.Value) { $r.Value.ExitCode } else { 'n/d' }). Pacotes gerados: $pacotes."
        Add-CompartDiskFinding -Severity WARN -Area 'Drivers' -Message 'Exportacao de drivers concluida com ressalvas.' -Recommendation 'Verificar permissoes de escrita e espaco em disco no destino.'
    }
}

function Export-DriverInventory {
    $d = Get-CompartDiskDriverInfo
    $p = Get-CompartDiskDriverInfo -OnlyProblems
    Add-CompartDiskSection -Title 'Drivers instalados' -Status OK -Rows $d -Summary "$($d.Count) driver(s)"
    if ($p.Count -gt 0) { Add-CompartDiskSection -Title 'Dispositivos com problema' -Status CRIT -Rows $p }

    $arquivos = New-Report -Name 'Inventario_Drivers' -Title 'Inventario de drivers' -Format TXT, CSV, JSON, HTML -Data ([ordered]@{
        Meta     = New-CompartDiskReportMeta
        Sections = @($Global:CompartDisk.Sections)
        Findings = @($Global:CompartDisk.Findings)
    })
    Write-Log OK "$($arquivos.Count) arquivo(s) de inventario gerado(s)."
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('Backup') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Drivers' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }
    switch ($Action) {
        'List'     { Show-Drivers }
        'Problems' { Show-Problems }
        'Unsigned' { Show-Unsigned }
        'Backup'   { Backup-Drivers -Destino $Path }
        'Export'   { Export-DriverInventory }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Drivers (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Drivers' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
