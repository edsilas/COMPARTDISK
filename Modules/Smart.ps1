<#
 COMPARTDISK 1.3.1 - Smart.ps1
 Desenvolvido por Edsilas
 Acoes: Status | Detail | Volumes | Shadow | Spaces
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Detail', 'Volumes', 'Shadow', 'Spaces')]
    [string]$Action = 'Status',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Show-DiskHealth {
    $discos = Get-CompartDiskDiskInfo
    if ($discos.Count -eq 0) {
        Write-Log ERR 'Nao foi possivel enumerar discos fisicos (WMI/Storage inoperantes).'
        $script:result = 'ERROR'
        return
    }

    Write-Color ''
    $discos | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
    Add-CompartDiskSection -Title 'Discos fisicos' -Status OK -Rows $discos -Summary "$($discos.Count) disco(s)"

    foreach ($d in $discos) {
        $saude = "$($d.Saude)"
        # O ramo de queda de Get-CompartDiskDiskInfo traz Win32_DiskDrive.Status, cujo
        # vocabulario e outro: 'Pred Fail', 'Degraded', 'Error', 'NonRecover'. Nenhum
        # casava os padroes originais, e um disco prestes a falhar ficava sem achado.
        if ($saude -match 'Unhealthy|Warning|Pred Fail|Degraded|Error|NonRecover|Lost Comm|No Contact') {
            Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Disco '$($d.Modelo)' com saude '$saude'." -Recommendation 'Fazer backup imediato e planejar substituicao.'
            $script:result = 'WARN'
        } elseif ($saude -match 'Healthy|^OK$') {
            Add-CompartDiskFinding -Severity OK -Area 'Disco' -Message "Disco '$($d.Modelo)': saude $saude."
        } else {
            Add-CompartDiskFinding -Severity INFO -Area 'Disco' -Message "Disco '$($d.Modelo)' com saude nao classificada: '$saude'." -Recommendation 'Conferir o estado do disco no utilitario do fabricante.'
        }
        if ($d.PSObject.Properties['SMART_Falha'] -and $d.SMART_Falha -eq 'SIM') {
            Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "SMART preve falha iminente em '$($d.Modelo)'." -Recommendation 'Substituir o disco com urgencia apos backup completo.'
            $script:result = 'WARN'
        }
        # Desgaste de SSD
        if ("$($d.Desgaste)" -match '^(\d+)%$') {
            $w = [int]$matches[1]
            if ($w -ge 80) {
                Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "SSD '$($d.Modelo)' com $w% de desgaste." -Recommendation 'Planejar substituicao.'
            } elseif ($w -ge 50) {
                Add-CompartDiskFinding -Severity WARN -Area 'Disco' -Message "SSD '$($d.Modelo)' com $w% de desgaste."
            }
        }
    }

    Write-Log INFO 'Nota: HealthStatus reflete o agregado reportado pelo controlador; nao substitui a leitura completa de atributos SMART do fabricante.'
    Write-Log OK 'Saude dos discos avaliada.'
}

function Show-Detail {
    Show-DiskHealth

    if (-not (Test-CompartDiskCommand 'Get-StorageReliabilityCounter')) {
        Write-Log WARN 'Contadores de confiabilidade indisponiveis nesta plataforma.'
        return
    }
    $rows = New-Object System.Collections.ArrayList
    foreach ($d in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $r = $null
        try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { continue }
        if (-not $r) { continue }
        [void]$rows.Add([pscustomobject]@{
            Disco            = $d.FriendlyName
            Temperatura      = $(if ($r.Temperature) { "$($r.Temperature) C" } else { 'n/d' })
            TempMaxima       = $(if ($r.TemperatureMax) { "$($r.TemperatureMax) C" } else { 'n/d' })
            HorasLigado      = $r.PowerOnHours
            CiclosStartStop  = $r.StartStopCycleCount
            ErrosLeitura     = $r.ReadErrorsTotal
            ErrosLeituraCorr = $r.ReadErrorsCorrected
            ErrosEscrita     = $r.WriteErrorsTotal
            ErrosNaoCorrig   = $r.ReadErrorsUncorrected
            Desgaste         = $(if ($null -ne $r.Wear) { "$($r.Wear)%" } else { 'n/d' })
        })
    }
    if ($rows.Count -gt 0) {
        Write-Color ''
        $rows | Format-List | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Contadores de confiabilidade' -Status OK -Rows @($rows)

        foreach ($r in $rows) {
            # O '\D' -> '0' original trocava cada nao-digito por zero em vez de
            # remove-lo: 'n/d' virava '000' por sorte, e '2 erros' viraria 2000000.
            $naoCorrig = 0
            if ("$($r.ErrosNaoCorrig)" -match '^\d+$') { $naoCorrig = [int]"$($r.ErrosNaoCorrig)" }
            if ($naoCorrig -gt 0) {
                Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Disco '$($r.Disco)' com erros de leitura nao corrigidos." -Recommendation 'Backup imediato e substituicao.'
                $script:result = 'WARN'
            }
        }
    }
}

function Show-Volumes {
    $vols = Get-CompartDiskVolumeInfo
    Write-Color ''
    $vols | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Volumes logicos' -Status OK -Rows $vols

    foreach ($v in $vols) {
        $pct = [double](("$($v.UsadoPct)" -replace '%', ''))
        if ($pct -ge 95) {
            Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Volume $($v.Volume) com $pct% de uso." -Recommendation 'Liberar espaco imediatamente: risco de instabilidade do Windows.'
            $script:result = 'WARN'
        } elseif ($pct -ge 85) {
            Add-CompartDiskFinding -Severity WARN -Area 'Disco' -Message "Volume $($v.Volume) com $pct% de uso." -Recommendation 'Executar a limpeza profunda.'
        } else {
            Add-CompartDiskFinding -Severity OK -Area 'Disco' -Message "Volume $($v.Volume): $($v.Livre) livres."
        }
    }

    if (Test-CompartDiskCommand 'Get-Volume') {
        $rows = New-Object System.Collections.ArrayList
        foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
            [void]$rows.Add([pscustomobject]@{
                Letra = $v.DriveLetter; Rotulo = $v.FileSystemLabel; Sistema = $v.FileSystem
                Saude = "$($v.HealthStatus)"; Operacional = "$($v.OperationalStatus)"
                # Get-Partition nao expoe tamanho de cluster; .Size e o tamanho da
                # particao - a coluna publicava um numero que nao era o que o rotulo
                # dizia, e duplicava a tabela de volumes logicos.
                TamanhoCluster = $(if ($v.PSObject.Properties['AllocationUnitSize'] -and $v.AllocationUnitSize) { "$($v.AllocationUnitSize) bytes" } else { 'n/d' })
            })
        }
        if ($rows.Count -gt 0) { Add-CompartDiskSection -Title 'Estado dos volumes (Storage)' -Status OK -Rows @($rows) }
    }
    Write-Log OK 'Volumes analisados.'
}

function Show-Shadow {
    $s = Get-CompartDiskShadowCopies
    if ($s.Count -eq 0) {
        Write-Log INFO 'Nenhuma copia de sombra (Shadow Copy) presente.'
        Add-CompartDiskFinding -Severity INFO -Area 'Disco' -Message 'Nenhum ponto de restauracao/shadow copy encontrado.' -Recommendation 'Considerar habilitar a Protecao do Sistema para recuperacao rapida.'
        return
    }
    $s | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Copias de sombra' -Status INFO -Rows $s -Summary "$($s.Count) copia(s)"
    Write-Log OK "$($s.Count) copia(s) de sombra listada(s)."
}

function Show-Spaces {
    if (-not (Test-CompartDiskCommand 'Get-StoragePool')) {
        Write-Log WARN 'Storage Spaces indisponivel nesta plataforma.'
        $script:result = 'UNSUPPORTED'
        return
    }
    $pools = Get-StoragePool -ErrorAction SilentlyContinue | Where-Object { -not $_.IsPrimordial }
    if (-not $pools) {
        Write-Log INFO 'Nenhum pool de armazenamento configurado.'
        return
    }
    $rows = @($pools | ForEach-Object {
        [pscustomobject]@{
            Pool = $_.FriendlyName; Saude = "$($_.HealthStatus)"; Operacional = "$($_.OperationalStatus)"
            Tamanho = (ConvertTo-CompartDiskSize $_.Size); Alocado = (ConvertTo-CompartDiskSize $_.AllocatedSize)
        }
    })
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Storage Spaces' -Status OK -Rows $rows
}

try {
    if (-not (Start-CompartDiskModule -Name 'Smart' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }
    switch ($Action) {
        'Status'  { Show-DiskHealth }
        'Detail'  { Show-Detail }
        'Volumes' { Show-Volumes }
        'Shadow'  { Show-Shadow }
        'Spaces'  { Show-Spaces }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Smart (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
