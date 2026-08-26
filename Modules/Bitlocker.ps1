<#
 COMPARTDISK 1.4.7 - Bitlocker.ps1
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
    # EVIDENCIA: no state_Bitlocker_Status.json de 13/08/2026 o resumo da secao
    # saiu como " volume(s)", sem numero. Test-BitLocker devolve @($result) e o
    # PowerShell desembrulha o array de um unico elemento na atribuicao: $vols
    # vira um PSCustomObject solto e ".Count" nao resolve. Com zero volumes o
    # retorno e $null e "$null.Count -eq 0" e falso no Windows PowerShell 5.1,
    # de modo que o ramo "nenhum volume" nunca era alcancado e o modulo terminava
    # OK sem dizer nada. @() garante colecao nos dois casos.
    $vols = @(Test-BitLocker)
    if ($vols.Count -eq 0) {
        Write-Log WARN 'Nenhum volume compativel com BitLocker foi retornado.'
        Add-CompartDiskFinding -Severity INFO -Area 'BitLocker' -Message 'BitLocker indisponivel nesta edicao do Windows ou sem volumes elegiveis.' -Recommendation 'Windows Home suporta apenas a Criptografia de Dispositivo, quando o hardware permite.'
        $script:result = 'UNSUPPORTED'
        return
    }

    # '| Write-Output' colocava a tabela no stream de sucesso do script, o que
    # ignora -Quiet e imprime sem a margem de 2 espacos do Launcher.
    Write-CompartDiskTitulo ('VOLUMES BITLOCKER ({0})' -f $vols.Count)
    Write-CompartDiskTable -Rows $vols
    Add-CompartDiskSection -Title 'Volumes BitLocker' -Status OK -Rows $vols -Summary "$($vols.Count) volume(s)"

    if ($Global:CompartDisk.BitLockerRaw) {
        # Saida bruta do manage-bde: e a unica evidencia quando o cmdlet e o WMI
        # nao respondem. Fica identificada, nunca solta no meio da tela.
        Write-CompartDiskTitulo 'SAIDA BRUTA DO MANAGE-BDE (evidencia da consulta)'
        Write-CompartDiskTexto $Global:CompartDisk.BitLockerRaw
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
    Write-CompartDiskTitulo ('PROTETORES DE CHAVE ({0})' -f $rows.Count)
    Write-CompartDiskTable -Rows @($rows)
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
    # Resumo antes do encerramento: publica em tela os achados e as secoes que
    # ate aqui so chegavam ao state_*.json e aos relatorios. Nao altera
    # resultado, codigo de saida nem o conteudo persistido.
    $oQue = switch ($Action) {
        'Status' { 'Estado da criptografia BitLocker dos volumes' }
        'Keys'   { 'Protetores de chave configurados por volume' }
        'Report' { 'Estado da criptografia BitLocker e geracao do relatorio' }
        default  { '' }
    }
    Write-CompartDiskSummary -Result $result -Verificacao $oQue
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
