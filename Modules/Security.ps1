<#
 COMPARTDISK 1.3.1 - Security.ps1
 Desenvolvido por Edsilas
 Acoes: Status | GpoReset | Takeown | Firewall | Uac
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'GpoReset', 'Takeown', 'Firewall', 'Uac')]
    [string]$Action = 'Status',
    [string]$Path = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Show-SecurityPosture {
    $p = Get-CompartDiskSecurityPosture
    Write-Color ''
    foreach ($k in $p.Keys) {
        $v = "$($p[$k])"
        $cor = 'Gray'
        if ($v -match 'Habilitado|Ativo|Sim|Pronto') { $cor = 'Green' }
        if ($v -match 'Desabilitado|Inativo|DESABILITADO|Nao suportado') { $cor = 'Yellow' }
        Write-CompartDiskKeyValue $k $p[$k] -Color $cor -Pad 24
    }

    $criticos = 0
    if ("$($p['UAC'])" -match 'DESABILITADO') {
        Add-CompartDiskFinding -Severity CRIT -Area 'Seguranca' -Message 'Controle de Conta de Usuario (UAC) esta desabilitado.' -Recommendation 'Reativar o UAC (EnableLUA=1) e reiniciar.'
        $criticos++
    }
    if ("$($p['Secure Boot'])" -match 'Desabilitado') {
        Add-CompartDiskFinding -Severity WARN -Area 'Seguranca' -Message 'Secure Boot desabilitado no firmware.' -Recommendation 'Habilitar Secure Boot na UEFI (requisito do Windows 11).'
    } elseif ("$($p['Secure Boot'])" -match 'Habilitado') {
        Add-CompartDiskFinding -Severity OK -Area 'Seguranca' -Message 'Secure Boot habilitado.'
    }
    if ("$($p['TPM presente'])" -eq 'Nao') {
        Add-CompartDiskFinding -Severity WARN -Area 'Seguranca' -Message 'TPM nao detectado.' -Recommendation 'Verificar se o TPM/fTPM esta habilitado na UEFI. Necessario para BitLocker e Windows 11.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Seguranca' -Message "TPM $($p['TPM versao']) presente e $($p['TPM estado'])."
    }
    if ("$($p['Memory Integrity'])" -match 'Desabilitado') {
        Add-CompartDiskFinding -Severity WARN -Area 'Seguranca' -Message 'Integridade de memoria (HVCI) desabilitada.' -Recommendation 'Habilitar em Seguranca do Windows > Seguranca do dispositivo > Isolamento do nucleo.'
    }
    if ("$($p['LSA Protection (PPL)'])" -match 'Desabilitado') {
        Add-CompartDiskFinding -Severity WARN -Area 'Seguranca' -Message 'Protecao do LSA (RunAsPPL) desabilitada.' -Recommendation 'Habilitar para mitigar roubo de credenciais.'
    }

    Add-CompartDiskSection -Title 'Postura de seguranca' -Status $(if ($criticos -gt 0) { 'CRIT' } else { 'OK' }) -Pairs $p

    # Firewall
    # Mesma causa comprovada em Bitlocker.ps1: os coletores devolvem @($rows) e o
    # PowerShell desembrulha a colecao de um unico elemento na atribuicao. Com
    # exatamente uma linha, ".Count" nao resolve no Windows PowerShell 5.1 e a
    # condicao ficava falsa - a secao inteira era pulada em silencio.
    $fw = @(Get-CompartDiskFirewallInfo)
    if ($fw.Count -gt 0) {
        Write-Color ''
        $fw | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
        Add-CompartDiskSection -Title 'Perfis de firewall' -Status OK -Rows $fw
    }

    # BitLocker resumido
    # No PC do log havia exatamente um volume BitLocker (C:, desprotegido): com
    # um unico elemento a condicao abaixo era falsa e o aviso de volume do
    # sistema sem protecao deixava de ser emitido por este modulo.
    $bl = @(Test-BitLocker)
    if ($bl.Count -gt 0) {
        $sistema = $bl | Where-Object { "$($_.MountPoint)" -like "$($env:SystemDrive)*" } | Select-Object -First 1
        if ($sistema -and "$($sistema.ProtectionStatus)" -notmatch 'On|1') {
            Add-CompartDiskFinding -Severity WARN -Area 'BitLocker' -Message "Volume do sistema ($($sistema.MountPoint)) sem protecao BitLocker ativa." -Recommendation 'Avaliar a ativacao da criptografia de disco conforme politica corporativa.'
        }
    }

    if ($criticos -gt 0) { $script:result = 'WARN' }
    Write-Log OK 'Postura de seguranca avaliada.'
}

function Reset-LocalGpo {
    Write-Log INFO 'Redefinindo diretivas de grupo locais...'
    $pastas = @(
        (Join-Path $env:SystemRoot 'System32\GroupPolicy')
        (Join-Path $env:SystemRoot 'System32\GroupPolicyUsers')
    )
    $backup = Join-Path $Global:CompartDisk.OutDir 'GroupPolicy_Backup'
    if (-not (Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }

    foreach ($p in $pastas) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $dest = Join-Path $backup (Split-Path $p -Leaf)
        Invoke-SafeCommand { Copy-Item -LiteralPath $p -Destination $dest -Recurse -Force -ErrorAction Stop } -Activity "Backup de $(Split-Path $p -Leaf)" | Out-Null
        $r = Remove-CompartDiskPathSafely -Path $p
        Write-Log OK ("{0} removida ({1} itens)." -f (Split-Path $p -Leaf), $r.Removed)
    }
    Write-Log OK "Backup das diretivas anteriores em: $backup"

    $gpupdate = Join-Path $env:SystemRoot 'System32\gpupdate.exe'
    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $gpupdate -Arguments @('/force') -TimeoutSeconds 300 } -Activity 'gpupdate /force'
    if ($r.Success) { Write-Log OK 'Diretivas de grupo reaplicadas.' } else { $script:result = 'WARN' }

    Add-CompartDiskSection -Title 'Reset de GPO local' -Status OK -Pairs ([ordered]@{ 'Backup' = $backup; 'gpupdate' = 'executado' })
    Add-CompartDiskFinding -Severity OK -Area 'Politicas' -Message 'Diretivas de grupo locais redefinidas.' -Recommendation "Backup preservado em $backup. Reiniciar para aplicacao completa."
}

function Grant-AdminOwnership {
    param([string]$Alvo)
    if ([string]::IsNullOrWhiteSpace($Alvo)) {
        Write-Log ERR 'Nenhum caminho informado.'
        $script:result = 'ERROR'
        return
    }
    $Alvo = $Alvo.Trim('"')
    if (-not (Test-Path -LiteralPath $Alvo)) {
        Write-Log ERR "Caminho inexistente: $Alvo"
        $script:result = 'ERROR'
        return
    }

    # Protecao: recusa alvos criticos do sistema. A decisao mora no Core, em ponto
    # unico, porque esta lista e a do Remove-CompartDiskPathSafely divergiam - e a
    # comparacao nao normalizada deixava a raiz do disco passar em ambas.
    $norm = (Resolve-Path -LiteralPath $Alvo).Path.TrimEnd('\')
    if (Test-CompartDiskProtectedPath -Path $Alvo) {
        Write-Log ERR "Operacao recusada: '$norm' e um caminho critico do sistema."
        Add-CompartDiskFinding -Severity WARN -Area 'Permissoes' -Message "Takeown recusado em caminho critico: $norm"
        $script:result = 'WARN'
        return
    }

    $takeown = Join-Path $env:SystemRoot 'System32\takeown.exe'
    $icacls  = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $ehPasta = (Get-Item -LiteralPath $Alvo).PSIsContainer

    Write-Log INFO "Assumindo propriedade de: $Alvo"
    $argsTake = if ($ehPasta) { @('/f', "`"$Alvo`"", '/r', '/d', 'y') } else { @('/f', "`"$Alvo`"") }
    $r1 = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $takeown -Arguments $argsTake -TimeoutSeconds 600 } -Activity 'takeown'

    if (-not $r1.Success -or $r1.Value.ExitCode -ne 0) {
        Write-Log ERR 'Falha ao assumir a propriedade (takeown).'
        $script:result = 'ERROR'
        return
    }
    Write-Log OK 'Propriedade transferida para o grupo Administradores.'

    $argsIcacls = if ($ehPasta) { @("`"$Alvo`"", '/grant', '*S-1-5-32-544:F', '/t', '/c') } else { @("`"$Alvo`"", '/grant', '*S-1-5-32-544:F', '/c') }
    $r2 = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $icacls -Arguments $argsIcacls -TimeoutSeconds 600 } -Activity 'icacls'

    if ($r2.Success -and $r2.Value.ExitCode -eq 0) {
        Write-Log OK 'Controle total concedido ao grupo Administradores (SID S-1-5-32-544).'
        Add-CompartDiskFinding -Severity OK -Area 'Permissoes' -Message "Controle administrativo concedido em: $Alvo"
    } else {
        $script:result = 'WARN'
        Write-Log WARN 'Algumas ACLs nao puderam ser gravadas (arquivos em uso ou protegidos).'
    }
    Add-CompartDiskSection -Title 'Assumir controle' -Status OK -Pairs ([ordered]@{ 'Alvo' = $Alvo; 'Tipo' = $(if ($ehPasta) { 'Pasta' } else { 'Arquivo' }) })
}

function Enable-Uac {
    Write-Log INFO 'Restaurando as configuracoes padrao do Controle de Conta de Usuario...'
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $ok = $true
    $ok = (Set-CompartDiskRegistryValue -Path $k -Name 'EnableLUA' -Value 1 -Type DWord) -and $ok
    $ok = (Set-CompartDiskRegistryValue -Path $k -Name 'ConsentPromptBehaviorAdmin' -Value 5 -Type DWord) -and $ok
    $ok = (Set-CompartDiskRegistryValue -Path $k -Name 'PromptOnSecureDesktop' -Value 1 -Type DWord) -and $ok
    if ($ok) {
        Write-Log OK 'UAC restaurado ao padrao. Reinicio necessario.'
        Add-CompartDiskFinding -Severity OK -Area 'Seguranca' -Message 'UAC restaurado ao padrao do Windows.' -Recommendation 'Reiniciar para aplicar.'
    } else {
        $script:result = 'WARN'
    }
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('GpoReset', 'Takeown', 'Uac') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Security' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'Status'   { Show-SecurityPosture }
        'GpoReset' { Reset-LocalGpo }
        'Takeown'  { Grant-AdminOwnership -Alvo $Path }
        'Uac'      { Enable-Uac }
        'Firewall' {
            $fw = Get-CompartDiskFirewallInfo
            $fw | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
            Add-CompartDiskSection -Title 'Perfis de firewall' -Status OK -Rows $fw
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Security (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Seguranca' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
