<#
 COMPARTDISK 1.3.1 - Bitlocker.ps1
 Desenvolvido por Edsilas
 Acoes: Status | Report | Keys
 Modulo somente leitura: nao altera o estado de criptografia dos volumes.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Report', 'Keys')]
    [string]$Action = 'Status',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Show-BitlockerStatus {
    $vols = Test-BitLocker
    if ($vols.Count -eq 0) {
        Write-Log WARN 'Nenhum volume compativel com BitLocker foi retornado.'
        Add-CompartDiskFinding -Severity INFO -Area 'BitLocker' -Message 'BitLocker indisponivel nesta edicao do Windows ou sem volumes elegiveis.' -Recommendation 'Windows Home suporta apenas a Criptografia de Dispositivo, quando o hardware permite.'
        $script:result = 'UNSUPPORTED'
        return
    }

    Write-Color ''
    $vols | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Volumes BitLocker' -Status OK -Rows $vols -Summary "$($vols.Count) volume(s)"

    if ($Global:CompartDisk.BitLockerRaw) {
        Write-Output $Global:CompartDisk.BitLockerRaw
    }

    $sistema = $vols | Where-Object { "$($_.MountPoint)" -like "$($env:SystemDrive)*" } | Select-Object -First 1
    if ($sistema) {
        $protegido = ("$($sistema.ProtectionStatus)" -match 'On|^1$')
        if ($protegido) {
            Add-CompartDiskFinding -Severity OK -Area 'BitLocker' -Message "Volume do sistema protegido ($($sistema.EncryptionMethod), $($sistema.Percentage)%)."
        } else {
            Add-CompartDiskFinding -Severity WARN -Area 'BitLocker' -Message 'Volume do sistema sem protecao BitLocker ativa.' -Recommendation 'Avaliar a ativacao conforme politica corporativa de protecao de dados.'
            $script:result = 'WARN'
        }
    }

    foreach ($v in $vols) {
        if ("$($v.VolumeStatus)" -match 'InProgress') {
            Add-CompartDiskFinding -Severity INFO -Area 'BitLocker' -Message "Volume $($v.MountPoint) em conversao ($($v.Percentage)%)." -Recommendation 'Aguardar a conclusao antes de desligar o computador.'
        }
    }
    Write-Log OK 'Status do BitLocker coletado.'
}

function Show-Protectors {
    if (-not (Import-CompartDiskModule 'BitLocker')) {
        Write-Log ERR 'Modulo BitLocker indisponivel nesta edicao.'
        $script:result = 'UNSUPPORTED'
        return
    }
    Write-Log WARN 'As chaves de recuperacao sao dados sensiveis. Nao serao gravadas em arquivo pela ferramenta.'
    $rows = New-Object System.Collections.ArrayList
    foreach ($v in (Get-BitLockerVolume -ErrorAction Stop)) {
        foreach ($p in $v.KeyProtector) {
            [void]$rows.Add([pscustomobject]@{
                Volume    = $v.MountPoint
                Tipo      = "$($p.KeyProtectorType)"
                Id        = $p.KeyProtectorId
                TemChave  = $(if ($p.RecoveryPassword) { 'Sim (exibida somente em tela)' } else { 'n/a' })
            })
        }
    }
    if ($rows.Count -eq 0) {
        Write-Log INFO 'Nenhum protetor de chave configurado.'
        return
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Protetores de chave' -Status INFO -Rows @($rows) -Summary 'Chaves de recuperacao omitidas do relatorio por seguranca'

    # A verificacao precisa ser por volume, e sobretudo no volume do sistema: uma
    # chave de recuperacao em D: nao ajuda quem perdeu o acesso a C:. A contagem
    # global deixava C: sem aviso sempre que qualquer outro volume tivesse chave.
    foreach ($g in ($rows | Group-Object Volume)) {
        if (@($g.Group | Where-Object { $_.Tipo -eq 'RecoveryPassword' }).Count -gt 0) { continue }
        $ehSistema = ("$($g.Name)" -like "$($env:SystemDrive)*")
        Add-CompartDiskFinding -Severity $(if ($ehSistema) { 'CRIT' } else { 'WARN' }) -Area 'BitLocker' -Message "Volume $($g.Name) sem protetor do tipo senha de recuperacao." -Recommendation 'Garantir o escrow da chave no AD/Entra ID ou na conta Microsoft antes de qualquer alteracao de firmware ou placa-mae.'
        if ($ehSistema) { $script:result = 'WARN' }
    }
    Write-Log OK 'Protetores de chave listados.'
}

try {
    if (-not (Start-CompartDiskModule -Name 'Bitlocker' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }
    switch ($Action) {
        'Status' { Show-BitlockerStatus }
        'Keys'   { Show-Protectors }
        'Report' {
            Show-BitlockerStatus
            New-Report -Name 'BitLocker' -Title 'Relatorio de criptografia de volumes' -Format TXT, CSV, JSON, HTML | Out-Null
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Bitlocker (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'BitLocker' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
