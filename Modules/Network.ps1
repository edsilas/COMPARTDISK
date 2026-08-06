<#
 COMPARTDISK 1.3.1 - Network.ps1
 Desenvolvido por Edsilas
 Acoes: Info | Reset | Hosts | Firewall | Test | Proxy | Wifi
#>
[CmdletBinding()]
param(
    [ValidateSet('Info', 'Reset', 'Hosts', 'Firewall', 'Test', 'Proxy', 'Wifi')]
    [string]$Action = 'Info',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'
$netsh  = Join-Path $env:SystemRoot 'System32\netsh.exe'
$ipcfg  = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
$arp    = Join-Path $env:SystemRoot 'System32\arp.exe'

function Show-NetworkInfo {
    $adapters = Get-CompartDiskNetworkInfo
    if ($adapters.Count -eq 0) {
        Write-Log WARN 'Nenhum adaptador de rede ativo localizado.'
        Add-CompartDiskFinding -Severity WARN -Area 'Rede' -Message 'Nenhum adaptador ativo.' -Recommendation 'Verificar drivers de rede e cabos.'
    } else {
        foreach ($a in $adapters) {
            Write-Color ''
            Write-Color ("  [{0}]  {1}" -f $a.Estado, $a.Interface) -Color White
            Write-CompartDiskKeyValue 'Descricao'  $a.Descricao
            Write-CompartDiskKeyValue 'MAC'        $a.MAC
            Write-CompartDiskKeyValue 'Velocidade' $a.Velocidade
            Write-CompartDiskKeyValue 'IPv4'       $a.IPv4
            Write-CompartDiskKeyValue 'IPv6'       $a.IPv6
            Write-CompartDiskKeyValue 'Gateway'    $a.Gateway
            Write-CompartDiskKeyValue 'DNS'        $a.DNS
            Write-CompartDiskKeyValue 'Perfil'     $a.Perfil
        }
        Add-CompartDiskSection -Title 'Adaptadores de rede' -Status OK -Rows $adapters -Summary "$($adapters.Count) interface(s)"
    }

    # DHCP / MTU / rotas
    if (Test-CompartDiskCommand 'Get-NetIPInterface') {
        $iface = Invoke-SafeCommand { Get-NetIPInterface -ErrorAction Stop |
            Where-Object { $_.ConnectionState -eq 'Connected' } |
            Select-Object InterfaceAlias, AddressFamily, NlMtu, Dhcp, ConnectionState } -Activity 'Get-NetIPInterface'
        if ($iface.Success -and $iface.Value) {
            $rows = @($iface.Value | ForEach-Object {
                [pscustomobject]@{ Interface = $_.InterfaceAlias; Familia = "$($_.AddressFamily)"; MTU = $_.NlMtu; DHCP = "$($_.Dhcp)" }
            })
            Add-CompartDiskSection -Title 'MTU e DHCP' -Status INFO -Rows $rows
            Write-Color ''
            $rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
        }
    }

    if (Test-CompartDiskCommand 'Get-NetRoute') {
        $rt = Invoke-SafeCommand { Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Select-Object InterfaceAlias, NextHop, RouteMetric } -Activity 'Get-NetRoute'
        if ($rt.Success -and $rt.Value) {
            Add-CompartDiskSection -Title 'Rotas padrao' -Status INFO -Rows @($rt.Value)
        }
    }

    # Compartilhamentos
    $shares = Get-CompartDiskCim -Class Win32_Share
    if ($shares) {
        $rows = @($shares | ForEach-Object { [pscustomobject]@{ Nome = $_.Name; Caminho = $_.Path; Descricao = $_.Description } })
        Add-CompartDiskSection -Title 'Compartilhamentos' -Status INFO -Rows $rows
    }

    # Firewall
    $fw = Get-CompartDiskFirewallInfo
    if ($fw.Count -gt 0) {
        Add-CompartDiskSection -Title 'Firewall do Windows' -Status OK -Rows $fw
        Write-Color ''
        $fw | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
        foreach ($p in $fw) {
            if ("$($p.Habilitado)" -eq 'False') {
                Add-CompartDiskFinding -Severity CRIT -Area 'Firewall' -Message "Perfil '$($p.Perfil)' esta desabilitado." -Recommendation 'Reativar o firewall no perfil correspondente.'
            }
        }
    }
    Write-Log OK 'Diagnostico de rede coletado.'
}

function Test-NetworkConnectivity {
    Write-Log INFO 'Testando conectividade (ICMP, DNS e HTTP)...'
    $net = Test-Internet
    Write-CompartDiskKeyValue 'Online'      $(if ($net.Online) { 'Sim' } else { 'NAO' }) -Color $(if ($net.Online) { 'Green' } else { 'Red' })
    Write-CompartDiskKeyValue 'Metodo'      $net.Method
    Write-CompartDiskKeyValue 'Alvo'        $net.Target
    Write-CompartDiskKeyValue 'Latencia'    $(if ($net.Latency) { "$($net.Latency) ms" } else { 'n/d' })
    Write-CompartDiskKeyValue 'Resolucao DNS' $(if ($net.DnsOk) { 'OK' } else { 'FALHA' })

    Add-CompartDiskSection -Title 'Conectividade' -Status $(if ($net.Online) { 'OK' } else { 'CRIT' }) -Pairs ([ordered]@{
        'Online'   = $net.Online; 'Metodo' = $net.Method; 'Alvo' = $net.Target
        'Latencia' = $net.Latency; 'DNS'   = $net.DnsOk
    })

    if (-not $net.Online) {
        Add-CompartDiskFinding -Severity CRIT -Area 'Rede' -Message 'Sem conectividade com a internet.' -Recommendation 'Executar o reset completo de rede e validar gateway/DNS.'
        $script:result = 'WARN'
    } elseif (-not $net.DnsOk) {
        Add-CompartDiskFinding -Severity WARN -Area 'DNS' -Message 'Resolucao de nomes falhou apesar da conectividade IP.' -Recommendation 'Limpar cache DNS e conferir servidores DNS configurados.'
        $script:result = 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Rede' -Message 'Conectividade e resolucao de nomes operacionais.'
    }

    # Teste de portas essenciais
    if (Test-CompartDiskCommand 'Test-NetConnection') {
        foreach ($alvo in @(@{H = 'windowsupdate.microsoft.com'; P = 443 }, @{H = 'login.live.com'; P = 443 })) {
            $r = Invoke-SafeCommand { Test-NetConnection -ComputerName $alvo.H -Port $alvo.P -WarningAction SilentlyContinue -ErrorAction Stop } -Activity "TCP $($alvo.H):$($alvo.P)" -Silent
            if ($r.Success) {
                $ok = $r.Value.TcpTestSucceeded
                Write-CompartDiskKeyValue "TCP $($alvo.H):$($alvo.P)" $(if ($ok) { 'Acessivel' } else { 'Bloqueado' }) -Color $(if ($ok) { 'Green' } else { 'Yellow' })
                if (-not $ok) {
                    Add-CompartDiskFinding -Severity WARN -Area 'Rede' -Message "Porta $($alvo.P) para $($alvo.H) inacessivel." -Recommendation 'Verificar proxy corporativo ou regras de firewall de saida.'
                }
            }
        }
    }
}

function Reset-NetworkStack {
    Write-Log INFO 'Resetando pilha TCP/IP, Winsock, DNS e ARP...'
    $passos = @(
        @{ N = 'Liberar concessao DHCP'; F = $ipcfg; A = @('/release') }
        @{ N = 'Limpar cache DNS';       F = $ipcfg; A = @('/flushdns') }
        @{ N = 'Renovar concessao DHCP'; F = $ipcfg; A = @('/renew') }
        @{ N = 'Reset Winsock';          F = $netsh; A = @('winsock', 'reset') }
        @{ N = 'Reset TCP/IP';           F = $netsh; A = @('int', 'ip', 'reset');   Nota = 'Codigo 1 e esperado: a pilha foi redefinida e o reinicio aplica a mudanca.' }
        @{ N = 'Reset IPv6';             F = $netsh; A = @('int', 'ipv6', 'reset'); Nota = 'Codigo 1 e esperado: a pilha foi redefinida e o reinicio aplica a mudanca.' }
        @{ N = 'Limpar tabela ARP';      F = $arp;   A = @('-d', '*') }
        @{ N = 'Reset Proxy WinHTTP';    F = $netsh; A = @('winhttp', 'reset', 'proxy') }
        @{ N = 'Registrar DNS';          F = $ipcfg; A = @('/registerdns') }
    )

    $falhas = 0
    foreach ($p in $passos) {
        if (-not (Test-Path -LiteralPath $p.F)) {
            Write-Log WARN "Executavel ausente para '$($p.N)'."
            $falhas++
            continue
        }
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $p.F -Arguments $p.A -TimeoutSeconds 120 } -Activity $p.N
        if ($r.Success -and $r.Value.ExitCode -eq 0) {
            Write-Log OK $p.N
        } else {
            # ipconfig /release retorna != 0 em maquinas com IP fixo: nao e falha real
            $codigo = if ($r.Value) { $r.Value.ExitCode } else { 'n/d' }
            $texto  = "{0} retornou codigo {1}." -f $p.N, $codigo
            if ($p.Nota) { $texto = "$texto $($p.Nota)" }
            Write-Log WARN $texto
            $falhas++
        }
    }

    if ($falhas -gt 0) {
        $script:result = 'WARN'
        Add-CompartDiskFinding -Severity WARN -Area 'Rede' -Message "$falhas etapa(s) do reset retornaram codigo diferente de zero." -Recommendation 'Normal em maquinas com IP fixo. Reiniciar e revalidar.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Rede' -Message 'Pilha de rede redefinida com sucesso.' -Recommendation 'Reiniciar o computador para aplicar integralmente.'
    }
    Write-Log OK 'Reset de rede concluido. Reinicio recomendado.'
}

function Restore-HostsFile {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path -LiteralPath $hosts) {
        # Backup em OutDir, como todos os demais do projeto, e nao dentro de System32 -
        # onde acumulava um arquivo por sessao sem limpeza. E o exito e medido pelo
        # arquivo produzido: a sobrescrita seguinte e irreversivel e nao pode ser
        # precedida por um "backup criado" que nunca existiu.
        $bkp = Join-Path $Global:CompartDisk.OutDir "hosts_anterior_$($Global:CompartDisk.Session).txt"
        $b = Invoke-SafeCommand { Copy-Item -LiteralPath $hosts -Destination $bkp -Force -ErrorAction Stop } -Activity 'Backup do arquivo hosts'
        if ($b.Success -and (Test-Path -LiteralPath $bkp)) {
            Write-Log OK "Backup criado: $bkp"
        } else {
            Write-Log WARN 'O backup do arquivo hosts falhou; o conteudo anterior nao ficara preservado.'
            Add-CompartDiskFinding -Severity WARN -Area 'Rede' -Message 'Backup do arquivo hosts nao pode ser gravado.' -Recommendation 'Definir COMPARTDISK_LOGDIR para um diretorio gravavel antes de repetir.'
            $script:result = 'WARN'
        }
    }

    $conteudo = @(
        '# Copyright (c) 1993-2009 Microsoft Corp.'
        '#'
        '# Arquivo HOSTS padrao restaurado pela ferramenta COMPARTDISK.'
        '# Cada entrada deve permanecer em uma linha individual.'
        '#'
        '#	127.0.0.1       localhost'
        '#	::1             localhost'
    )
    Invoke-SafeCommand {
        [System.IO.File]::WriteAllLines($hosts, $conteudo, (New-Object System.Text.UTF8Encoding($false)))
    } -Activity 'Gravar hosts padrao' -Critical | Out-Null

    Invoke-SafeCommand { Invoke-NativeCommand -FilePath $ipcfg -Arguments @('/flushdns') -TimeoutSeconds 30 } -Activity 'Flush DNS' | Out-Null
    Write-Log OK 'Arquivo hosts restaurado ao padrao Microsoft e cache DNS limpo.'
    Add-CompartDiskFinding -Severity OK -Area 'Rede' -Message 'Arquivo hosts restaurado ao padrao.'
}

function Reset-FirewallPolicy {
    Write-Log INFO 'Exportando politica atual antes do reset...'
    $bkp = Join-Path $Global:CompartDisk.OutDir "Firewall_Backup_$($Global:CompartDisk.Session).wfw"
    Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netsh -Arguments @('advfirewall', 'export', "`"$bkp`"") -TimeoutSeconds 60 } -Activity 'Exportar firewall' | Out-Null
    if (Test-Path -LiteralPath $bkp) { Write-Log OK "Backup da politica: $bkp" }

    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netsh -Arguments @('advfirewall', 'reset') -TimeoutSeconds 60 } -Activity 'Reset firewall' -Critical
    if ($r.Success -and $r.Value.ExitCode -eq 0) {
        Write-Log OK 'Regras do firewall restauradas ao padrao.'
        Add-CompartDiskFinding -Severity OK -Area 'Firewall' -Message 'Politica de firewall restaurada ao padrao.' -Recommendation "Backup disponivel em $bkp"
    } else {
        $script:result = 'WARN'
        Write-Log WARN 'O reset do firewall retornou codigo diferente de zero.'
    }

    if (Test-CompartDiskCommand 'Set-NetFirewallProfile') {
        Invoke-SafeCommand { Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True -ErrorAction Stop } -Activity 'Reativar perfis do firewall' | Out-Null
        Write-Log OK 'Perfis Domain/Public/Private habilitados.'
    }
}

function Show-ProxyConfig {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pairs = [ordered]@{
        'Proxy habilitado' = $(if ((Get-CompartDiskRegistryValue $reg 'ProxyEnable' 0) -eq 1) { 'Sim' } else { 'Nao' })
        'Servidor proxy'   = (Get-CompartDiskRegistryValue $reg 'ProxyServer' 'nenhum')
        'Excecoes'         = (Get-CompartDiskRegistryValue $reg 'ProxyOverride' 'nenhuma')
        'Script automatico'= (Get-CompartDiskRegistryValue $reg 'AutoConfigURL' 'nenhum')
    }
    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netsh -Arguments @('winhttp', 'show', 'proxy') -TimeoutSeconds 20 } -Activity 'WinHTTP proxy'
    if ($r.Success) { $pairs['WinHTTP'] = ($r.Value.StdOut -replace '\s+', ' ').Trim() }

    foreach ($k in $pairs.Keys) { Write-CompartDiskKeyValue $k $pairs[$k] }
    Add-CompartDiskSection -Title 'Configuracao de proxy' -Status INFO -Pairs $pairs
    Write-Log OK 'Configuracao de proxy coletada.'
}

function Show-WifiInfo {
    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netsh -Arguments @('wlan', 'show', 'interfaces') -TimeoutSeconds 30 } -Activity 'netsh wlan'
    if (-not $r.Success -or -not $r.Value.StdOut -or $r.Value.ExitCode -ne 0) {
        Write-Log WARN 'Nenhuma interface Wi-Fi disponivel ou servico WLAN inativo.'
        return
    }
    Write-Output $r.Value.StdOut
    Add-CompartDiskSection -Title 'Wi-Fi' -Status INFO -Summary 'Saida de netsh wlan show interfaces' `
        -Pairs ([ordered]@{ 'Detalhes' = (($r.Value.StdOut -split '\r?\n' | Where-Object { $_ -match ':' } | Select-Object -First 20) -join ' | ') })

    $p = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netsh -Arguments @('wlan', 'show', 'profiles') -TimeoutSeconds 30 } -Activity 'Perfis Wi-Fi'
    if ($p.Success) { Write-Output $p.Value.StdOut }
    Write-Log OK 'Diagnostico Wi-Fi coletado.'
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('Reset', 'Hosts', 'Firewall') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Network' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'Info'     { Show-NetworkInfo }
        'Reset'    { Reset-NetworkStack }
        'Hosts'    { Restore-HostsFile }
        'Firewall' { Reset-FirewallPolicy }
        'Test'     { Test-NetworkConnectivity }
        'Proxy'    { Show-ProxyConfig }
        'Wifi'     { Show-WifiInfo }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Network (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Rede' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
