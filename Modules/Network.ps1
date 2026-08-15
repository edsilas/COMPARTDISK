<#
 COMPARTDISK 1.4.1 - Network.ps1
 Desenvolvido por Edsilas
 Acoes: Info | Reset | Hosts | Firewall | Test | Proxy | Wifi

 ESCOPO E SEGURANCA
 Info, Test, Proxy e Wifi sao ESTRITAMENTE somente leitura.
 Reset, Hosts e Firewall modificam o sistema e seguem sempre:
 pre-condicao -> backup validado (quando aplicavel) -> execucao -> releitura
 -> resultado real. "O comando terminou" nunca e tratado como "deu certo".

 O modulo NAO altera DNS, NAO altera MTU, NAO remove rotas, NAO desabilita
 nem reinicia adaptadores e NAO recupera credenciais de Wi-Fi ou de proxy.

 Compativel com Windows 10 / Windows 11, Windows PowerShell 5.1 e
 PowerShell 7.x. Somente componentes nativos do Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('Info', 'Reset', 'Hosts', 'Firewall', 'Test', 'Proxy', 'Wifi')]
    [string]$Action = 'Info',
    [switch]$Quiet,
    # O reset do proxy WinHTTP destroi configuracao corporativa valida e nao
    # pertence ao reset de pilha. Passou a ser decisao explicita do operador.
    [switch]$ResetProxy,
    # Permite as etapas que redefinem a configuracao IP mesmo quando ha
    # interface com endereco estatico (que seria perdido).
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
$ipcfg = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
$arp   = Join-Path $env:SystemRoot 'System32\arp.exe'

# ==============================================================================
# ESTADO GLOBAL
# Fonte unica e monotonica: OK -> WARN -> ERROR. Uma etapa WARN nunca
# desaparece no finally.
# ==============================================================================
$script:result     = 'OK'
$script:ResultRank = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-NetResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Position = 1)][string]$Reason = ''
    )
    if ($script:ResultRank[$Level] -gt $script:ResultRank[$script:result]) {
        $script:result = $Level
        Write-Log DEBUG ("Resultado do modulo elevado para {0}{1}" -f $Level, $(if ($Reason) { ": $Reason" } else { '' })) -NoConsole
    }
}

function Get-NetSectionStatus {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) { 'OK' { return 'OK' } 'WARN' { return 'WARN' } default { return 'CRIT' } }
}

function Get-NetFindingSeverity {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) { 'OK' { return 'OK' } 'WARN' { return 'WARN' } default { return 'CRIT' } }
}

function Get-NetWorstSeverity {
    param([string[]]$Severities)
    $rank = @{ 'OK' = 0; 'INFO' = 1; 'WARN' = 2; 'CRIT' = 3 }
    $pior = 'OK'
    foreach ($s in $Severities) {
        if (-not $rank.ContainsKey("$s")) { continue }
        if ($rank["$s"] -gt $rank[$pior]) { $pior = "$s" }
    }
    return $pior
}

function ConvertTo-NetArray {
    <# Funcao que devolve @() entrega $null ao chamador, e @($null) tem Count 1.
       Ponto unico de conversao de retorno para colecao. #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    return @(@($Value) | Where-Object { $null -ne $_ })
}

function Get-NetSafeText {
    param([AllowNull()][object]$Value, [string]$Default = 'n/d')
    if ($null -eq $Value) { return $Default }
    $t = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
    return $t
}

function Get-NetIPv4Class {
    <# Classifica um endereco IPv4, aceitando a forma "endereco/prefixo" que o
       coletor devolve. Devolve: Apipa | Loopback | Privado | CGNAT | Publico |
       Invalido.

       Existe para que a decisao "ha endereco utilizavel?" pare de ser feita por
       contagem. Ver Test-NetworkConnectivity: a regra anterior so reconhecia
       APIPA quando havia exatamente UM endereco no sistema. #>
    param([AllowNull()][object]$Endereco)
    $t = "$Endereco".Trim()
    if (-not $t) { return 'Invalido' }
    $t = ($t -split '/')[0].Trim()

    $ip = [System.Net.IPAddress]::Any
    if (-not [System.Net.IPAddress]::TryParse($t, [ref]$ip)) { return 'Invalido' }
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return 'Invalido' }

    $o = $ip.GetAddressBytes()
    if ($o[0] -eq 169 -and $o[1] -eq 254) { return 'Apipa' }
    if ($o[0] -eq 127)                    { return 'Loopback' }
    if ($o[0] -eq 10)                     { return 'Privado' }
    if ($o[0] -eq 192 -and $o[1] -eq 168) { return 'Privado' }
    if ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) { return 'Privado' }
    if ($o[0] -eq 100 -and $o[1] -ge 64 -and $o[1] -le 127) { return 'CGNAT' }
    return 'Publico'
}

function Test-NetIPv4Utilizavel {
    <# Endereco que permite roteamento: nem APIPA, nem loopback, nem invalido. #>
    param([AllowNull()][object]$Endereco)
    return ((Get-NetIPv4Class $Endereco) -in @('Privado', 'CGNAT', 'Publico'))
}

function Get-NetEstadoNormalizado {
    <# Traduz o Status bruto do adaptador para um vocabulario estavel.
       Get-NetAdapter e Win32_NetworkAdapter usam cadeias diferentes, e o
       relatorio nao deveria expor essa diferenca a quem le. #>
    param([AllowNull()][object]$Status)
    $s = "$Status".Trim()
    if (-not $s) { return 'Unknown' }
    switch -Regex ($s) {
        '(?i)^up$'                    { return 'Healthy' }
        '(?i)disabled'                { return 'Disabled' }
        '(?i)disconnected'            { return 'Disconnected' }
        '(?i)not\s*present'           { return 'NotPresent' }
        '(?i)faulty|failed|error'     { return 'Error' }
        '(?i)^down$'                  { return 'Disconnected' }
        default                       { return 'Unknown' }
    }
}

# ------------------------------------------------------------------------------
# Registro de etapas: cada operacao tem resultado proprio e verificavel.
# ------------------------------------------------------------------------------
$script:Steps = New-Object System.Collections.ArrayList

function Add-NetStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Etapa,
        [Parameter(Mandatory)][string]$Operacao,
        [string]$Alvo = '',
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR', 'SKIPPED', 'NOT_SUPPORTED', 'INFO')][string]$Resultado,
        [string]$Detalhe = ''
    )
    [void]$script:Steps.Add([pscustomobject]@{
        Etapa = $Etapa; Operacao = $Operacao; Alvo = $Alvo; Resultado = $Resultado; Detalhe = $Detalhe
    })
}

# ------------------------------------------------------------------------------
# -Quiet reduz SOMENTE a saida interativa. Logs, findings, sections, relatorio
# e resultado permanecem inalterados.
# ------------------------------------------------------------------------------
function Write-NetTable {
    [CmdletBinding()]
    param([object[]]$Rows, [string[]]$Property)
    if ($script:Quiet) { return }
    $dados = ConvertTo-NetArray $Rows
    if ($dados.Count -eq 0) { return }
    try {
        if ($Property) { $texto = $dados | Select-Object -Property $Property | Format-Table -AutoSize | Out-String -Width 200 }
        else           { $texto = $dados | Format-Table -AutoSize | Out-String -Width 200 }
        foreach ($linha in ($texto -split "`r?`n")) {
            if ($linha.Trim()) { Write-Color ("  " + $linha) }
        }
    } catch {
        Write-Log DEBUG "Falha ao formatar tabela: $($_.Exception.Message)" -NoConsole
    }
}

function Write-NetLine {
    param([string]$Text, $Color = 'Gray')
    if ($script:Quiet) { return }
    Write-Color $Text -Color $Color
}

function Write-NetPair {
    param([string]$Key, [AllowNull()][object]$Value, $Color = 'Gray')
    if ($script:Quiet) { return }
    Write-CompartDiskKeyValue $Key $Value -Color $Color
}

# ==============================================================================
# EXECUCAO DE COMANDOS EXTERNOS
# Cada comando declara os codigos de retorno aceitaveis: nao existe regra
# global "ExitCode != 0 = falha" nem "!= 0 = esperado".
# ==============================================================================
function Invoke-NetCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 120,
        [int[]]$AcceptableExitCodes = @(0),
        [Parameter(Mandatory)][string]$Activity
    )
    $out = [pscustomobject]@{
        Executado = $false; Ok = $false; ExitCode = $null
        StdOut = ''; StdErr = ''; Timeout = $false; Detalhe = ''
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        $out.Detalhe = ('Executavel ausente: {0}' -f $FilePath)
        return $out
    }
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    } -Activity $Activity -Silent

    if (-not $r.Success -or $null -eq $r.Value) {
        $msg = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        $out.Timeout = ($msg -match 'Tempo limite excedido')
        $out.Detalhe = $msg
        $out.Executado = $out.Timeout
        return $out
    }
    $out.Executado = $true
    $out.ExitCode  = [int]$r.Value.ExitCode
    $out.StdOut    = "$($r.Value.StdOut)"
    $out.StdErr    = "$($r.Value.StdErr)".Trim()
    $out.Ok        = (@($AcceptableExitCodes) -contains $out.ExitCode)
    if (-not $out.Ok) {
        $out.Detalhe = ('codigo {0} fora dos aceitaveis ({1})' -f $out.ExitCode, (@($AcceptableExitCodes) -join ', '))
        if ($out.StdErr) { $out.Detalhe += ('; stderr: {0}' -f (($out.StdErr -split "`r?`n" | Select-Object -First 1))) }
    }
    return $out
}

# ==============================================================================
# CONTEXTO DE EXECUCAO
# ==============================================================================
function Test-NetRemoteSession {
    <# Um reset de rede pode derrubar a propria sessao que executa o script. #>
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Remota = $false; Tipo = 'local' }
    try {
        if ("$env:SESSIONNAME" -match '^RDP-') { $out.Remota = $true; $out.Tipo = 'sessao RDP' ; return $out }
        if ($null -ne $PSSenderInfo)           { $out.Remota = $true; $out.Tipo = 'sessao WinRM'; return $out }
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('SSH_CLIENT'))) {
            $out.Remota = $true; $out.Tipo = 'sessao SSH'; return $out
        }
    } catch {
        Write-Log DEBUG "Deteccao de sessao remota indisponivel: $($_.Exception.Message)" -NoConsole
    }
    return $out
}

function Test-NetDomainJoined {
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Ok = $false; Dominio = $false; Nome = 'n/d' }
    try {
        $cs = Get-CompartDiskCim -Class Win32_ComputerSystem
        if ($null -ne $cs) {
            $c = @($cs) | Select-Object -First 1
            $out.Ok = $true
            $out.Dominio = [bool]$c.PartOfDomain
            $out.Nome = Get-NetSafeText $c.Domain
        }
    } catch {
        Write-Log DEBUG "Win32_ComputerSystem indisponivel: $($_.Exception.Message)" -NoConsole
    }
    return $out
}

function Test-NetRebootPending {
    [CmdletBinding()] param()
    try {
        if (Test-CompartDiskCommand 'Test-CompartDiskPendingReboot') { return [bool](Test-CompartDiskPendingReboot) }
    } catch {
        Write-Log DEBUG "Test-CompartDiskPendingReboot: $($_.Exception.Message)" -NoConsole
    }
    return $false
}

# ==============================================================================
# INVENTARIO DE REDE (cacheado por execucao; invalidado apos alteracao real)
# ==============================================================================
$script:AdapterCache  = $null
$script:NetInfoCache  = $null
$script:FirewallCache = $null

function Reset-NetCaches {
    <# Chamado apos operacoes que alteram o estado real da rede, para que a
       revalidacao nunca leia um retrato anterior a mudanca. #>
    $script:AdapterCache  = $null
    $script:NetInfoCache  = $null
    $script:FirewallCache = $null
}

function Get-NetworkInventory {
    <# Envolve Get-CompartDiskNetworkInfo (Core) distinguindo colecao vazia de
       falha de coleta. Retorna { Ok, Status, Detalhe, Rows, Total }. #>
    [CmdletBinding()] param()
    if ($script:NetInfoCache) { return $script:NetInfoCache }

    $out = [pscustomobject]@{ Ok = $false; Status = 'Falhou'; Detalhe = ''; Rows = @(); Total = 0 }
    $r = Invoke-SafeCommand { Get-CompartDiskNetworkInfo } -Activity 'Inventario de adaptadores' -Silent
    if (-not $r.Success) {
        $out.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
        $script:NetInfoCache = $out
        return $out
    }
    $rows = ConvertTo-NetArray $r.Value
    $out.Ok = $true
    $out.Rows = $rows
    $out.Total = $rows.Count
    $out.Status = $(if ($rows.Count -gt 0) { 'Completo' } else { 'Vazio' })
    if ($rows.Count -eq 0) { $out.Detalhe = 'A consulta concluiu sem devolver interfaces com configuracao IP.' }
    $script:NetInfoCache = $out
    return $out
}

function Get-NetAdapterFacts {
    <# Classifica adaptadores e determina DHCP x estatico por interface. E a base
       das pre-condicoes do Reset: sem isto, release/renew e reset de pilha
       seriam aplicados as cegas sobre configuracao estatica. #>
    [CmdletBinding()] param()
    if ($script:AdapterCache) { return $script:AdapterCache }

    $out = [pscustomobject]@{
        Ok = $false; Fonte = 'n/d'; Detalhe = ''; Rows = @()
        Instalados = 0; Conectados = 0; Desconectados = 0; Desabilitados = 0
        DhcpIPv4 = @(); EstaticoIPv4 = @(); Indeterminados = @()
    }
    $linhas = New-Object System.Collections.ArrayList
    # Consulta bem-sucedida com zero adaptadores NAO e o mesmo que consulta
    # falha: a primeira e uma maquina sem placa, a segunda e cegueira.
    $consultaOk = $false

    if (Test-CompartDiskCommand 'Get-NetAdapter') {
        $ad = Invoke-SafeCommand { Get-NetAdapter -ErrorAction Stop } -Activity 'Get-NetAdapter' -Silent
        if ($ad.Success) {
            $adapters = ConvertTo-NetArray $ad.Value
            $ipif = @()
            $q = Invoke-SafeCommand { Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop } -Activity 'Get-NetIPInterface' -Silent
            if ($q.Success) { $ipif = ConvertTo-NetArray $q.Value }

            foreach ($a in $adapters) {
                $alias = Get-NetSafeText $a.Name
                $idx   = $null
                try { if ($null -ne $a.InterfaceIndex) { $idx = [int]$a.InterfaceIndex } } catch { $idx = $null }

                # Correlacao por InterfaceIndex, com o alias apenas como recurso
                # secundario. O nome da interface e editavel pelo usuario, muda
                # entre versoes do Windows e pode repetir-se em ambiente com
                # muitos adaptadores virtuais: casar por nome associava MTU e
                # DHCP de uma interface a outra.
                $ifc = $null
                if ($null -ne $idx) {
                    $ifc = @($ipif | Where-Object { "$($_.InterfaceIndex)" -eq "$idx" }) | Select-Object -First 1
                }
                if (-not $ifc) {
                    $ifc = @($ipif | Where-Object { "$($_.InterfaceAlias)" -eq $alias }) | Select-Object -First 1
                }
                $dhcp = 'Indeterminado'
                if ($ifc) { $dhcp = $(if ("$($ifc.Dhcp)" -eq 'Enabled') { 'DHCP' } else { 'Estatico' }) }
                [void]$linhas.Add([pscustomobject]@{
                    Interface  = $alias
                    Indice     = $(if ($null -ne $idx) { $idx } else { 'n/d' })
                    Descricao  = (Get-NetSafeText $a.InterfaceDescription)
                    Estado     = (Get-NetSafeText $a.Status)
                    EstadoNorm = (Get-NetEstadoNormalizado $a.Status)
                    Virtual    = $(if ($a.Virtual) { 'Sim' } else { 'Nao' })
                    Velocidade = (Get-NetSafeText $a.LinkSpeed)
                    ConfigIPv4 = $dhcp
                    MTU        = $(if ($ifc) { Get-NetSafeText $ifc.NlMtu } else { 'n/d' })
                })
            }
            $consultaOk = $true
            $out.Fonte = 'Get-NetAdapter'
        } else {
            $out.Detalhe = $(if ($ad.Error) { $ad.Error.Exception.Message } else { 'Get-NetAdapter nao respondeu' })
        }
    }

    if ($linhas.Count -eq 0) {
        # Fallback CIM: Windows sem os cmdlets NetTCPIP disponiveis.
        #
        # O filtro anterior era 'PhysicalAdapter=True', que descarta TODA
        # interface virtual: VPN, Hyper-V, VMware, VirtualBox, WSL e Bluetooth
        # PAN sumiam do inventario justamente na maquina em que os cmdlets
        # modernos nao existem. O criterio passa a ser ter NetConnectionID, ou
        # seja, aparecer em Conexoes de Rede - isso inclui os virtuais reais e
        # continua excluindo miniportas WAN e adaptadores de tunel internos.
        $cim = Get-CompartDiskCim -Class Win32_NetworkAdapter -Filter 'NetConnectionID IS NOT NULL'
        if (@(ConvertTo-NetArray $cim).Count -eq 0) {
            $cim = Get-CompartDiskCim -Class Win32_NetworkAdapter -Filter 'PhysicalAdapter=True'
        }
        $cfg = Get-CompartDiskCim -Class Win32_NetworkAdapterConfiguration
        foreach ($a in (ConvertTo-NetArray $cim)) {
            $c = @((ConvertTo-NetArray $cfg) | Where-Object { $_.Index -eq $a.Index }) | Select-Object -First 1
            # Valores de NetConnectionStatus (Win32_NetworkAdapter):
            # 0 Desconectado, 1 Conectando, 2 Conectado, 3 Desconectando,
            # 4 Hardware ausente, 5 Hardware desabilitado, 6 Hardware com falha,
            # 7 Midia desconectada. O mapa anterior colapsava 5 e 6 em 'Down',
            # e um adaptador desabilitado era contado como desconectado.
            $estado = switch ([int]$a.NetConnectionStatus) {
                2 { 'Up' }
                0 { 'Disconnected' }
                7 { 'Disconnected' }
                4 { 'Not Present' }
                5 { 'Disabled' }
                6 { 'Hardware Faulty' }
                default { 'Down' }
            }
            $dhcp = 'Indeterminado'
            if ($c) { $dhcp = $(if ([bool]$c.DHCPEnabled) { 'DHCP' } else { 'Estatico' }) }
            [void]$linhas.Add([pscustomobject]@{
                Interface  = (Get-NetSafeText $a.NetConnectionID)
                Indice     = (Get-NetSafeText $a.InterfaceIndex)
                Descricao  = (Get-NetSafeText $a.Name)
                Estado     = $estado
                EstadoNorm = (Get-NetEstadoNormalizado $estado)
                Virtual    = $(if ($null -ne $a.PhysicalAdapter -and -not [bool]$a.PhysicalAdapter) { 'Sim' } else { 'Nao' })
                Velocidade = 'n/d'
                ConfigIPv4 = $dhcp
                MTU        = 'n/d'
            })
        }
        if ($linhas.Count -gt 0) { $consultaOk = $true; $out.Fonte = 'Win32_NetworkAdapter' }
    }
    $out.Ok = $consultaOk
    if (-not $consultaOk -and -not $out.Detalhe) { $out.Detalhe = 'Nenhuma fonte de inventario de adaptadores respondeu.' }

    # Contagem pelo estado normalizado. Antes, 'Not Present' (adaptador cujo
    # hardware nao esta no equipamento) era somado a Desconectados, e um
    # adaptador ausente aparecia no relatorio como cabo desconectado.
    $out.Rows = @($linhas)
    $out.Instalados    = @($linhas).Count
    $out.Conectados    = @($linhas | Where-Object { $_.EstadoNorm -eq 'Healthy' }).Count
    $out.Desabilitados = @($linhas | Where-Object { $_.EstadoNorm -eq 'Disabled' }).Count
    $out.Desconectados = @($linhas | Where-Object { $_.EstadoNorm -eq 'Disconnected' }).Count
    $out | Add-Member -NotePropertyName 'Ausentes' -NotePropertyValue @($linhas | Where-Object { $_.EstadoNorm -eq 'NotPresent' }).Count -Force
    $out | Add-Member -NotePropertyName 'ComFalha' -NotePropertyValue @($linhas | Where-Object { $_.EstadoNorm -eq 'Error' }).Count -Force
    $out | Add-Member -NotePropertyName 'Virtuais' -NotePropertyValue @($linhas | Where-Object { $_.Virtual -eq 'Sim' }).Count -Force
    $out.DhcpIPv4      = @($linhas | Where-Object { $_.ConfigIPv4 -eq 'DHCP' -and $_.EstadoNorm -eq 'Healthy' } | ForEach-Object { $_.Interface })
    $out.EstaticoIPv4  = @($linhas | Where-Object { $_.ConfigIPv4 -eq 'Estatico' -and $_.EstadoNorm -eq 'Healthy' } | ForEach-Object { $_.Interface })
    $out.Indeterminados= @($linhas | Where-Object { $_.ConfigIPv4 -eq 'Indeterminado' -and $_.EstadoNorm -eq 'Healthy' } | ForEach-Object { $_.Interface })

    $script:AdapterCache = $out
    return $out
}

function Get-NetFirewallState {
    <# Perfis + perfil ativo + gestao por GPO + produto de terceiros.
       Sem isso, um perfil desabilitado vira CRIT indiscriminadamente. #>
    [CmdletBinding()] param()
    if ($script:FirewallCache) { return $script:FirewallCache }

    $out = [pscustomobject]@{
        Ok = $false; Detalhe = ''; Perfis = @(); PerfilAtivo = 'n/d'
        GerenciadoPorGpo = $false; ProdutoTerceiro = ''; Desabilitados = @()
    }
    $r = Invoke-SafeCommand { Get-CompartDiskFirewallInfo } -Activity 'Perfis do firewall' -Silent
    if ($r.Success) {
        $perfis = ConvertTo-NetArray $r.Value
        # A linha sintetica 'netsh' do fallback do Core nao carrega estado real.
        $reais = @($perfis | Where-Object { "$($_.Perfil)" -ne 'netsh' })
        if ($reais.Count -gt 0) {
            $out.Ok = $true
            $out.Perfis = $reais
            $out.Desabilitados = @($reais | Where-Object { "$($_.Habilitado)" -match '^(False|0)$' } | ForEach-Object { "$($_.Perfil)" })
        } elseif ($perfis.Count -gt 0) {
            $out.Detalhe = 'Somente a saida textual do netsh esta disponivel: o estado por perfil nao pode ser confirmado.'
        } else {
            $out.Detalhe = 'Nenhum perfil de firewall foi devolvido pela consulta.'
        }
    } else {
        $out.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'consulta de perfis falhou' })
    }

    if (Test-CompartDiskCommand 'Get-NetConnectionProfile') {
        $p = Invoke-SafeCommand { Get-NetConnectionProfile -ErrorAction Stop } -Activity 'Get-NetConnectionProfile' -Silent
        if ($p.Success) {
            $cats = @((ConvertTo-NetArray $p.Value) | ForEach-Object { "$($_.NetworkCategory)" } | Sort-Object -Unique)
            if ($cats.Count -gt 0) { $out.PerfilAtivo = ($cats -join ', ') }
        }
    }

    try {
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall') { $out.GerenciadoPorGpo = $true }
    } catch {
        Write-Log DEBUG "Leitura de politica de firewall indisponivel: $($_.Exception.Message)" -NoConsole
    }

    try {
        $fp = Get-CompartDiskCim -Class FirewallProduct -Namespace 'root\SecurityCenter2'
        $nomes = @((ConvertTo-NetArray $fp) | ForEach-Object { Get-NetSafeText $_.displayName '' } | Where-Object { $_ })
        if ($nomes.Count -gt 0) { $out.ProdutoTerceiro = ($nomes -join ', ') }
    } catch {
        Write-Log DEBUG "SecurityCenter2 indisponivel: $($_.Exception.Message)" -NoConsole
    }

    $script:FirewallCache = $out
    return $out
}

function Test-NetProfileIsActive {
    param([string]$Perfil, [object]$Estado)
    $ativo = "$($Estado.PerfilAtivo)"
    $mapa  = @{ 'Domain' = 'DomainAuthenticated'; 'Private' = 'Private'; 'Public' = 'Public' }
    if (-not $mapa.ContainsKey($Perfil)) { return $false }
    return ($ativo -match [regex]::Escape($mapa[$Perfil]))
}

function Get-NetFirewallSeverity {
    <# Perfil desabilitado que NAO e o ativo nao equivale a maquina desprotegida.
       Com firewall de terceiros registrado, a protecao pode vir dele. #>
    param([string]$Perfil, [object]$Estado)
    if (Test-NetProfileIsActive -Perfil $Perfil -Estado $Estado) {
        if ($Estado.ProdutoTerceiro) { return 'WARN' }
        return 'CRIT'
    }
    return 'WARN'
}

# ==============================================================================
# ACAO: INFO  (estritamente somente leitura)
# ==============================================================================
function Show-NetworkInfo {
    Write-Log INFO 'Coletando diagnostico de rede (somente leitura)...'
    $inv    = Get-NetworkInventory
    $facts  = Get-NetAdapterFacts
    $niveis = New-Object System.Collections.ArrayList

    # ------------------------------------------------------------- adaptadores
    if (-not $facts.Ok -and -not $inv.Ok) {
        Write-Log ERR ('Inventario de adaptadores indisponivel: {0}' -f (Get-NetSafeText $facts.Detalhe $inv.Detalhe))
        Add-CompartDiskSection -Title 'Adaptadores de rede' -Status CRIT -Summary 'Consulta nao concluida'
        Add-CompartDiskFinding -Severity CRIT -Area 'Rede' `
            -Message ('Nao foi possivel enumerar os adaptadores de rede: {0}' -f (Get-NetSafeText $facts.Detalhe $inv.Detalhe)) `
            -Recommendation 'Validar o servico WMI (winmgmt) e os cmdlets NetTCPIP antes de qualquer intervencao.'
        Set-NetResult 'ERROR' 'inventario de adaptadores indisponivel'
        return
    }

    if ($facts.Ok) {
        Write-NetLine ''
        Write-NetTable -Rows $facts.Rows -Property @('Interface', 'Indice', 'EstadoNorm', 'ConfigIPv4', 'Velocidade', 'MTU', 'Virtual')
        $st = 'OK'
        $resumo = ("{0} instalado(s): {1} conectado(s), {2} desconectado(s), {3} desabilitado(s)" -f `
            $facts.Instalados, $facts.Conectados, $facts.Desconectados, $facts.Desabilitados)
        if ($facts.Instalados -eq 0) { $st = 'WARN' }
        elseif ($facts.Conectados -eq 0) { $st = 'WARN' }
        Add-CompartDiskSection -Title 'Adaptadores de rede' -Status $st -Rows $facts.Rows -Summary $resumo `
            -Pairs ([ordered]@{
                'Fonte'          = $facts.Fonte
                'Instalados'     = $facts.Instalados
                'Conectados'     = $facts.Conectados
                'Desconectados'  = $facts.Desconectados
                'Desabilitados'  = $facts.Desabilitados
                'Ausentes'       = $facts.Ausentes
                'Com falha'      = $facts.ComFalha
                'Virtuais'       = $facts.Virtuais
                'IPv4 por DHCP'  = $(if (@($facts.DhcpIPv4).Count -gt 0) { (@($facts.DhcpIPv4) -join ', ') } else { 'nenhum' })
                'IPv4 estatico'  = $(if (@($facts.EstaticoIPv4).Count -gt 0) { (@($facts.EstaticoIPv4) -join ', ') } else { 'nenhum' })
            })

        # Ausencia de adaptador conectado nao e, por si so, defeito: pode ser
        # servidor isolado, maquina desconectada ou interface desabilitada.
        if ($facts.Instalados -eq 0) {
            Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                -Message 'Nenhum adaptador de rede foi encontrado neste sistema.' `
                -Recommendation 'Verificar presenca fisica do adaptador e o driver correspondente no Gerenciador de Dispositivos.'
            [void]$niveis.Add('WARN')
        } elseif ($facts.Conectados -eq 0) {
            Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                -Message ("Nenhum adaptador conectado: {0} desconectado(s) e {1} desabilitado(s) de {2} instalado(s)." -f $facts.Desconectados, $facts.Desabilitados, $facts.Instalados) `
                -Recommendation 'Confirmar cabo, rede sem fio ou se a interface foi desabilitada administrativamente.'
            [void]$niveis.Add('WARN')
        }
    }

    # ------------------------------------------------- configuracao IP detalhada
    if ($inv.Ok -and $inv.Total -gt 0) {
        # Os dados eram apenas EXIBIDOS: a secao saia com Status OK fixo e
        # nenhuma condicao era avaliada. Uma interface conectada com endereco
        # APIPA, sem gateway e sem DNS aparecia no relatorio exatamente como uma
        # interface saudavel.
        $avaliacao = New-Object System.Collections.ArrayList
        $sevsIp = New-Object System.Collections.ArrayList

        foreach ($a in $inv.Rows) {
            Write-NetLine ''
            Write-NetLine ("  [{0}]  {1}" -f (Get-NetSafeText $a.Estado), (Get-NetSafeText $a.Interface)) 'White'
            Write-NetPair 'Descricao'  (Get-NetSafeText $a.Descricao)
            Write-NetPair 'MAC'        (Get-NetSafeText $a.MAC)
            Write-NetPair 'Velocidade' (Get-NetSafeText $a.Velocidade)
            Write-NetPair 'IPv4'       (Get-NetSafeText $a.IPv4)
            Write-NetPair 'IPv6'       (Get-NetSafeText $a.IPv6)
            Write-NetPair 'Gateway'    (Get-NetSafeText $a.Gateway)
            Write-NetPair 'DNS'        (Get-NetSafeText $a.DNS)
            Write-NetPair 'Perfil'     (Get-NetSafeText $a.Perfil)

            $iface   = Get-NetSafeText $a.Interface
            $estado  = Get-NetEstadoNormalizado $a.Estado
            $ipv4    = @(("$($a.IPv4)" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'n/d' })
            $ipv6    = @(("$($a.IPv6)" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'n/d' })
            $gw      = @(("$($a.Gateway)" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'n/d' })
            $dns     = @(("$($a.DNS)" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'n/d' })
            $rot     = @($ipv4 | Where-Object { Test-NetIPv4Utilizavel $_ })
            $apipaIf = @($ipv4 | Where-Object { (Get-NetIPv4Class $_) -eq 'Apipa' })
            # IPv6 link-local (fe80::) nao substitui endereco roteavel.
            $ipv6Rot = @($ipv6 | Where-Object { $_ -notmatch '(?i)^fe80:' })

            $sit = 'Healthy'
            $obs = ''
            # Interface parada nao e defeito: e estado legitimo e nao gera achado.
            if ($estado -ne 'Healthy') {
                $sit = $estado
                $obs = 'Interface nao conectada: a configuracao IP nao e avaliada.'
            }
            elseif ($apipaIf.Count -gt 0 -and $rot.Count -eq 0) {
                $sit = 'Warning'
                $obs = 'Endereco APIPA (169.254.x) e nenhum endereco roteavel: concessao DHCP nao obtida.'
                Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                    -Message ("Interface '{0}' conectada com endereco APIPA e sem endereco roteavel." -f $iface) `
                    -Recommendation 'Indica que o servidor DHCP nao respondeu. Conferir cabo, concessao DHCP e o proprio servidor antes de qualquer redefinicao.'
                [void]$sevsIp.Add('WARN')
            }
            elseif ($rot.Count -eq 0 -and $ipv6Rot.Count -eq 0) {
                $sit = 'Warning'
                $obs = 'Interface conectada sem endereco IPv4 roteavel nem IPv6 global.'
                Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                    -Message ("Interface '{0}' esta conectada, porem sem endereco IP utilizavel." -f $iface) `
                    -Recommendation 'Conferir a configuracao IP da interface e a disponibilidade do DHCP.'
                [void]$sevsIp.Add('WARN')
            }
            elseif ($rot.Count -eq 0 -and $ipv6Rot.Count -gt 0) {
                # Rede somente IPv6 e configuracao valida, nao defeito.
                $sit = 'Healthy'
                $obs = 'Sem IPv4 roteavel, com IPv6 global: rede somente IPv6.'
            }
            elseif ($gw.Count -eq 0) {
                # Sem gateway pode ser esperado em VPN e interface virtual, que
                # roteiam por rotas especificas em vez de rota padrao.
                $virtual = ("$($a.Descricao)" -match '(?i)virtual|hyper-v|vmware|virtualbox|vpn|tap|tun|wsl|loopback|bluetooth')
                if ($virtual) {
                    $sit = 'Healthy'
                    $obs = 'Sem gateway padrao: esperado em interface virtual ou de VPN.'
                } else {
                    $sit = 'Warning'
                    $obs = 'Interface com IP roteavel e sem gateway padrao.'
                    Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                        -Message ("Interface '{0}' possui endereco IP, porem nenhum gateway padrao." -f $iface) `
                        -Recommendation 'Sem gateway nao ha saida da rede local por esta interface. Conferir a configuracao IP e a concessao DHCP.'
                    [void]$sevsIp.Add('WARN')
                }
            }
            elseif ($dns.Count -eq 0) {
                $sit = 'Warning'
                $obs = 'Interface roteavel sem servidor DNS configurado.'
                Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                    -Message ("Interface '{0}' nao possui servidor DNS configurado." -f $iface) `
                    -Recommendation 'Sem DNS a navegacao por nome falha, ainda que o transporte IP funcione. Conferir a concessao DHCP ou a configuracao manual.'
                [void]$sevsIp.Add('WARN')
            }

            [void]$avaliacao.Add([pscustomobject]@{
                Interface = $iface
                Estado    = $estado
                IPv4      = $(if ($ipv4.Count -gt 0) { $ipv4 -join ', ' } else { 'nenhum' })
                Classe    = $(if ($ipv4.Count -gt 0) { (@($ipv4 | ForEach-Object { Get-NetIPv4Class $_ } | Sort-Object -Unique) -join ', ') } else { 'n/d' })
                IPv6Global= $(if ($ipv6Rot.Count -gt 0) { 'Sim' } else { 'Nao' })
                Gateway   = $(if ($gw.Count -gt 0) { $gw -join ', ' } else { 'nenhum' })
                DNS       = $(if ($dns.Count -gt 0) { $dns -join ', ' } else { 'nenhum' })
                Perfil    = (Get-NetSafeText $a.Perfil)
                Situacao  = $sit
                Observacao= $obs
            })
        }

        $statusIp = Get-NetWorstSeverity @($sevsIp)
        Write-NetLine ''
        Write-NetTable -Rows @($avaliacao) -Property @('Interface', 'Estado', 'IPv4', 'Classe', 'Gateway', 'DNS', 'Situacao')
        Add-CompartDiskSection -Title 'Configuracao IP por interface' -Status $statusIp -Rows @($avaliacao) `
            -Summary ("{0} interface(s) com configuracao IP" -f $inv.Total) `
            -Pairs ([ordered]@{
                'Interfaces avaliadas'    = $inv.Total
                'Com endereco roteavel'   = @($avaliacao | Where-Object { $_.Classe -match 'Privado|Publico|CGNAT' }).Count
                'Com APIPA'               = @($avaliacao | Where-Object { $_.Classe -match 'Apipa' }).Count
                'Sem gateway'             = @($avaliacao | Where-Object { $_.Gateway -eq 'nenhum' }).Count
                'Sem DNS'                 = @($avaliacao | Where-Object { $_.DNS -eq 'nenhum' }).Count
            })
        if (@($sevsIp).Count -gt 0) { [void]$niveis.Add('WARN') }
    } elseif ($inv.Ok) {
        Add-CompartDiskSection -Title 'Configuracao IP por interface' -Status WARN -Summary 'Nenhuma interface com configuracao IP'
    } else {
        Add-CompartDiskSection -Title 'Configuracao IP por interface' -Status WARN -Summary 'Consulta nao concluida'
        Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
            -Message ('A configuracao IP detalhada nao pode ser coletada: {0}' -f $inv.Detalhe) `
            -Recommendation 'O restante do diagnostico permanece valido; revalidar os cmdlets NetTCPIP.'
        [void]$niveis.Add('WARN')
    }

    # ------------------------------------------------------------- MTU por familia
    if (Test-CompartDiskCommand 'Get-NetIPInterface') {
        $iface = Invoke-SafeCommand { Get-NetIPInterface -ErrorAction Stop } -Activity 'Get-NetIPInterface (MTU)' -Silent
        if ($iface.Success) {
            $rows = @((ConvertTo-NetArray $iface.Value) |
                Where-Object { "$($_.ConnectionState)" -eq 'Connected' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Interface = (Get-NetSafeText $_.InterfaceAlias)
                        Familia   = (Get-NetSafeText $_.AddressFamily)
                        MTU       = (Get-NetSafeText $_.NlMtu)
                        DHCP      = (Get-NetSafeText $_.Dhcp)
                        Estado    = (Get-NetSafeText $_.ConnectionState)
                    }
                })
            if ($rows.Count -gt 0) {
                Add-CompartDiskSection -Title 'MTU e DHCP por familia' -Status INFO -Rows $rows `
                    -Summary ("{0} interface(s) conectada(s); MTU e apenas diagnostico e nao e alterada por este modulo" -f $rows.Count)
                Write-NetLine ''
                Write-NetTable -Rows $rows
            }
        } else {
            Add-CompartDiskSection -Title 'MTU e DHCP por familia' -Status WARN -Summary 'Consulta nao concluida'
            Write-Log WARN 'Nao foi possivel consultar MTU/DHCP por familia de endereco.'
            [void]$niveis.Add('WARN')
        }
    } else {
        Add-CompartDiskSection -Title 'MTU e DHCP por familia' -Status INFO -Summary 'Cmdlet Get-NetIPInterface indisponivel nesta instalacao'
    }

    # --------------------------------------------------------------------- rotas
    if (Test-CompartDiskCommand 'Get-NetRoute') {
        $rotas = New-Object System.Collections.ArrayList
        $familias = @(
            @{ Pref = '0.0.0.0/0'; Fam = 'IPv4' }
            @{ Pref = '::/0';      Fam = 'IPv6' }
        )
        $falhouRota = $false
        foreach ($f in $familias) {
            $rt = Invoke-SafeCommand { Get-NetRoute -DestinationPrefix $f.Pref -ErrorAction Stop } -Activity ("Get-NetRoute {0}" -f $f.Fam) -Silent
            if (-not $rt.Success) { $falhouRota = $true; continue }
            foreach ($x in (ConvertTo-NetArray $rt.Value)) {
                [void]$rotas.Add([pscustomobject]@{
                    Familia    = $f.Fam
                    Interface  = (Get-NetSafeText $x.InterfaceAlias)
                    ProximoSalto = (Get-NetSafeText $x.NextHop)
                    Metrica    = (Get-NetSafeText $x.RouteMetric)
                })
            }
        }
        $titulo = 'Rotas padrao (IPv4 e IPv6)'
        if (@($rotas).Count -gt 0) {
            # Multiplas rotas padrao sao normais com VPN ou interfaces virtuais.
            Add-CompartDiskSection -Title $titulo -Status INFO -Rows @($rotas) `
                -Summary ("{0} rota(s) padrao; multiplas rotas sao esperadas com VPN ou interfaces virtuais" -f @($rotas).Count)
        } elseif ($falhouRota) {
            Add-CompartDiskSection -Title $titulo -Status WARN -Summary 'Consulta de rotas nao concluida'
            [void]$niveis.Add('WARN')
        } else {
            Add-CompartDiskSection -Title $titulo -Status WARN -Summary 'Nenhuma rota padrao configurada'
            Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                -Message 'Nenhuma rota padrao (IPv4 ou IPv6) esta configurada.' `
                -Recommendation 'Sem rota padrao nao ha saida para fora da rede local: verificar gateway e concessao DHCP.'
            [void]$niveis.Add('WARN')
        }
    }

    # ----------------------------------------------------------- compartilhamentos
    $shares = Get-CompartDiskCim -Class Win32_Share
    $sh = ConvertTo-NetArray $shares
    if ($sh.Count -gt 0) {
        $rows = @($sh | ForEach-Object {
            $nome = Get-NetSafeText $_.Name
            $tipo = 'Usuario'
            if ($nome -eq 'IPC$')      { $tipo = 'IPC' }
            elseif ($nome -match '\$$'){ $tipo = 'Administrativo' }
            # Caminho local so e exposto para compartilhamentos de usuario: os
            # administrativos sao previsiveis e o caminho nao agrega diagnostico.
            [pscustomobject]@{
                Nome      = $nome
                Tipo      = $tipo
                Caminho   = $(if ($tipo -eq 'Usuario') { Get-NetSafeText $_.Path } else { '(padrao do sistema)' })
                Descricao = (Get-NetSafeText $_.Description '')
            }
        })
        $usuario = @($rows | Where-Object { $_.Tipo -eq 'Usuario' }).Count
        Add-CompartDiskSection -Title 'Compartilhamentos' -Status INFO -Rows $rows `
            -Summary ("{0} compartilhamento(s): {1} de usuario, {2} administrativo(s)/IPC" -f $rows.Count, $usuario, ($rows.Count - $usuario))
    }

    # ------------------------------------------------------------------ firewall
    $fw = Get-NetFirewallState
    if ($fw.Ok) {
        $pares = [ordered]@{
            'Perfil de rede ativo'  = $fw.PerfilAtivo
            'Gerenciado por GPO'    = $(if ($fw.GerenciadoPorGpo) { 'Sim' } else { 'Nao detectado' })
            'Firewall de terceiros' = $(if ($fw.ProdutoTerceiro) { $fw.ProdutoTerceiro } else { 'nenhum registrado' })
        }
        $sevs = New-Object System.Collections.ArrayList
        foreach ($p in $fw.Perfis) {
            if ("$($p.Habilitado)" -match '^(False|0)$') {
                $sev = Get-NetFirewallSeverity -Perfil "$($p.Perfil)" -Estado $fw
                [void]$sevs.Add($sev)
                $ehAtivo = Test-NetProfileIsActive -Perfil "$($p.Perfil)" -Estado $fw
                $ctx = $(if ($ehAtivo) { 'e o perfil da rede atualmente ativa' } else { 'nao e o perfil da rede atualmente ativa' })
                if ($ehAtivo -and $fw.ProdutoTerceiro) { $ctx += ('; protecao possivelmente provida por {0}' -f $fw.ProdutoTerceiro) }
                $rec = 'Reativar o firewall neste perfil, salvo se a protecao for provida por solucao de terceiros ou exigida de outra forma pela politica da organizacao.'
                if ($fw.GerenciadoPorGpo) { $rec = 'Perfil sob diretiva de grupo: tratar com a equipe responsavel, pois alteracoes locais podem ser revertidas.' }
                Add-CompartDiskFinding -Severity $sev -Area 'Firewall' `
                    -Message ("Perfil '{0}' do firewall esta desabilitado ({1})." -f (Get-NetSafeText $p.Perfil), $ctx) `
                    -Recommendation $rec
            }
        }
        $statusFw = Get-NetWorstSeverity @($sevs)
        Add-CompartDiskSection -Title 'Firewall do Windows' -Status $statusFw -Rows $fw.Perfis -Pairs $pares `
            -Summary ("{0} perfil(is); {1} desabilitado(s)" -f @($fw.Perfis).Count, @($fw.Desabilitados).Count)
        Write-NetLine ''
        Write-NetTable -Rows $fw.Perfis
        if (@($sevs).Count -gt 0) { [void]$niveis.Add('WARN') }
        if (@($fw.Desabilitados).Count -eq 0) {
            Add-CompartDiskFinding -Severity OK -Area 'Firewall' -Message 'Todos os perfis do firewall do Windows estao habilitados.'
        }
    } else {
        Add-CompartDiskSection -Title 'Firewall do Windows' -Status WARN -Summary 'Estado dos perfis nao pode ser confirmado'
        Add-CompartDiskFinding -Severity WARN -Area 'Firewall' `
            -Message ('O estado dos perfis do firewall nao pode ser confirmado: {0}' -f $fw.Detalhe) `
            -Recommendation 'Sem essa leitura nao e possivel afirmar que o firewall esta ativo nem que esta inativo.'
        [void]$niveis.Add('WARN')
    }

    if (@($niveis) -contains 'WARN') { Set-NetResult 'WARN' 'diagnostico de rede com pendencias' }
    Write-Log OK 'Diagnostico de rede coletado (nenhuma alteracao aplicada).'
}

# ==============================================================================
# ACAO: TEST  (estritamente somente leitura)
# Diagnostico em camadas. Um booleano "online" nao diz onde a cadeia quebrou,
# e ICMP bloqueado nao prova ausencia de internet.
#
# Test-Internet do Core nao e usado aqui: ele colapsa o resultado em um unico
# booleano e sua resolucao de nomes ([Net.Dns]::GetHostEntry) e sincrona e sem
# tempo limite, o que pode bloquear o modulo. As sondas abaixo tem limite real.
# ==============================================================================
function Test-NetTcpPortQuick {
    <# Conexao TCP com tempo limite efetivo. Test-NetConnection nao aceita
       timeout e pode levar dezenas de segundos por alvo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 4000)
    $out = [pscustomobject]@{ Alvo = ('{0}:{1}' -f $Target, $Port); Ok = $false; Ms = 0; Detalhe = '' }
    $cli = $null
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $cli = New-Object System.Net.Sockets.TcpClient
        $iar = $cli.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $out.Detalhe = ('sem resposta em {0} ms' -f $TimeoutMs)
        } else {
            $cli.EndConnect($iar)
            $out.Ok = $true
        }
    } catch {
        $out.Detalhe = $_.Exception.Message
        if ($_.Exception.InnerException) { $out.Detalhe = $_.Exception.InnerException.Message }
    } finally {
        $cron.Stop()
        $out.Ms = [int]$cron.Elapsed.TotalMilliseconds
        if ($cli) { try { $cli.Close() } catch { Write-Log DEBUG "Fechamento de socket: $($_.Exception.Message)" -NoConsole } }
    }
    return $out
}

function Test-NetDnsName {
    <# Resolucao com tempo limite real, distinguindo timeout de falha de consulta. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutMs = 4000)
    $out = [pscustomobject]@{ Nome = $Name; Ok = $false; Enderecos = ''; Ms = 0; Detalhe = '' }
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $task = [System.Net.Dns]::GetHostAddressesAsync($Name)
        $concluiu = $true
        try { $concluiu = $task.Wait($TimeoutMs) } catch { $concluiu = $true }
        if (-not $concluiu) {
            $out.Detalhe = ('sem resposta em {0} ms' -f $TimeoutMs)
        } elseif ($task.IsFaulted) {
            $ex = $task.Exception
            $msg = 'consulta recusada ou nome inexistente'
            try { if ($ex -and $ex.InnerException) { $msg = $ex.InnerException.Message } }
            catch { $msg = 'consulta recusada ou nome inexistente' }
            $out.Detalhe = $msg
        } else {
            $addrs = @($task.Result | ForEach-Object { $_.IPAddressToString })
            if ($addrs.Count -gt 0) { $out.Ok = $true; $out.Enderecos = ($addrs -join ', ') }
            else { $out.Detalhe = 'resposta sem enderecos' }
        }
    } catch {
        $out.Detalhe = $_.Exception.Message
    } finally {
        $cron.Stop()
        $out.Ms = [int]$cron.Elapsed.TotalMilliseconds
    }
    return $out
}

function Test-NetPingHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target, [int]$TimeoutMs = 2000)
    $out = [pscustomobject]@{ Alvo = $Target; Ok = $false; Ms = 0; Detalhe = '' }
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $rep = $ping.Send($Target, $TimeoutMs)
            if ("$($rep.Status)" -eq 'Success') { $out.Ok = $true; $out.Ms = [int]$rep.RoundtripTime }
            else { $out.Detalhe = "$($rep.Status)" }
        } finally {
            try { $ping.Dispose() } catch { Write-Log DEBUG "Dispose do ping: $($_.Exception.Message)" -NoConsole }
        }
    } catch {
        $out.Detalhe = $_.Exception.Message
    }
    return $out
}

function Test-NetHttpProbe {
    <# Sonda HTTP equivalente a usada pelo proprio Windows (NCSI). #>
    [CmdletBinding()]
    param([string]$Url = 'http://www.msftconnecttest.com/connecttest.txt', [int]$TimeoutMs = 6000)
    $out = [pscustomobject]@{ Alvo = $Url; Ok = $false; Ms = 0; Detalhe = '' }
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    try {
        $req = [System.Net.WebRequest]::Create($Url)
        $req.Timeout = $TimeoutMs
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        $out.Ok = $true
    } catch {
        $out.Detalhe = $_.Exception.Message
    } finally {
        $cron.Stop()
        $out.Ms = [int]$cron.Elapsed.TotalMilliseconds
        if ($resp) { try { $resp.Close() } catch { Write-Log DEBUG "Fechamento de resposta HTTP: $($_.Exception.Message)" -NoConsole } }
    }
    return $out
}

function Test-NetworkConnectivity {
    Write-Log INFO 'Testando conectividade em camadas (interface, IP, gateway, DNS, TCP e HTTP)...'

    $facts = Get-NetAdapterFacts
    $inv   = Get-NetworkInventory
    $camadas = New-Object System.Collections.ArrayList
    $detalhes = New-Object System.Collections.ArrayList

    function Add-Camada {
        param([string]$Camada, [string]$Estado, [string]$Evidencia)
        [void]$camadas.Add([pscustomobject]@{ Camada = $Camada; Estado = $Estado; Evidencia = $Evidencia })
    }

    # ------------------------------------------------------ 1. interface fisica
    $temInterface = ($facts.Ok -and $facts.Conectados -gt 0)
    Add-Camada '1. Interface' $(if ($temInterface) { 'OK' } else { 'FALHA' }) `
        $(if ($facts.Ok) { ("{0} conectado(s) de {1} instalado(s)" -f $facts.Conectados, $facts.Instalados) } else { 'inventario indisponivel' })

    # -------------------------------------------------------- 2. endereco IPv4
    # A regra anterior era:
    #   $temIp = ($ips.Count -gt 0 -and -not ($ips.Count -eq 1 -and $apipa))
    # que so reconhecia APIPA quando havia EXATAMENTE UM endereco no sistema.
    # Num notebook com Ethernet e Wi-Fi, ambos sem concessao DHCP, havia dois
    # enderecos 169.254.x, a condicao ficava falsa e a camada era dada como OK -
    # exatamente o cenario que ela existe para detectar.
    # Agora a decisao e por classe do endereco, nao por contagem.
    $ips = @()
    $utilizaveis = @()
    $apipaList = @()
    foreach ($a in $inv.Rows) {
        foreach ($ip in ("$($a.IPv4)" -split ',')) {
            $t = $ip.Trim()
            if (-not $t -or $t -eq 'n/d') { continue }
            $ips += $t
            switch (Get-NetIPv4Class $t) {
                'Apipa'    { $apipaList += $t }
                'Loopback' { }
                'Invalido' { }
                default    { $utilizaveis += $t }
            }
        }
    }
    $apipa = ($apipaList.Count -gt 0)
    $temIp = ($utilizaveis.Count -gt 0)
    $evidIp = $(if ($ips.Count -gt 0) { ($ips -join ', ') } else { 'nenhum endereco IPv4' })
    if ($apipa) {
        $evidIp += (' ({0} endereco(s) 169.254.x: concessao DHCP nao obtida)' -f $apipaList.Count)
    }
    if ($ips.Count -gt 0 -and -not $temIp) {
        $evidIp += ' - nenhum endereco roteavel'
    }
    Add-Camada '2. Endereco IPv4' $(if ($temIp) { 'OK' } else { 'FALHA' }) $evidIp

    # -------------------------------------------------------------- 3. gateway
    $gateways = @()
    foreach ($a in $inv.Rows) {
        foreach ($g in ("$($a.Gateway)" -split ',')) {
            $t = $g.Trim()
            if ($t -and $t -ne 'n/d' -and (@($gateways) -notcontains $t)) { $gateways += $t }
        }
    }
    $gwOk = $false
    $gwEvid = 'nenhum gateway configurado'
    if ($gateways.Count -gt 0) {
        $gwEvid = ''
        foreach ($g in $gateways) {
            $p = Test-NetPingHost -Target $g -TimeoutMs 2000
            [void]$detalhes.Add([pscustomobject]@{ Teste = 'Gateway (ICMP)'; Alvo = $g; Resultado = $(if ($p.Ok) { 'Responde' } else { 'Sem resposta' }); Tempo = ('{0} ms' -f $p.Ms); Observacao = (Get-NetSafeText $p.Detalhe '') })
            if ($p.Ok) { $gwOk = $true }
            $gwEvid += ('{0}={1}; ' -f $g, $(if ($p.Ok) { 'responde' } else { 'sem resposta ICMP' }))
        }
        $gwEvid = $gwEvid.TrimEnd('; ')
    }
    # Gateway sem resposta ICMP nao prova roteamento quebrado: muitos bloqueiam ICMP.
    Add-Camada '3. Gateway' $(if ($gateways.Count -eq 0) { 'FALHA' } elseif ($gwOk) { 'OK' } else { 'INCONCLUSIVO' }) $gwEvid

    # ------------------------------------------- 4. transporte TCP sem depender de DNS
    $tcpIp = Test-NetTcpPortQuick -Target '1.1.1.1' -Port 443 -TimeoutMs 4000
    [void]$detalhes.Add([pscustomobject]@{ Teste = 'TCP para IP literal'; Alvo = $tcpIp.Alvo; Resultado = $(if ($tcpIp.Ok) { 'Acessivel' } else { 'Bloqueado' }); Tempo = ('{0} ms' -f $tcpIp.Ms); Observacao = (Get-NetSafeText $tcpIp.Detalhe '') })
    Add-Camada '4. Transporte TCP' $(if ($tcpIp.Ok) { 'OK' } else { 'FALHA' }) `
        ("{0} ({1})" -f $tcpIp.Alvo, $(if ($tcpIp.Ok) { 'conexao estabelecida sem usar DNS' } else { $tcpIp.Detalhe }))

    # ------------------------------------------------------------------ 5. DNS
    $nomes = @('www.microsoft.com', 'www.msftconnecttest.com')
    $dnsOk = 0
    foreach ($n in $nomes) {
        $d = Test-NetDnsName -Name $n -TimeoutMs 4000
        [void]$detalhes.Add([pscustomobject]@{ Teste = 'Resolucao DNS'; Alvo = $n; Resultado = $(if ($d.Ok) { 'Resolvido' } else { 'Nao resolvido' }); Tempo = ('{0} ms' -f $d.Ms); Observacao = $(if ($d.Ok) { $d.Enderecos } else { $d.Detalhe }) })
        if ($d.Ok) { $dnsOk++ }
    }
    $dnsEstado = $(if ($dnsOk -eq $nomes.Count) { 'OK' } elseif ($dnsOk -gt 0) { 'PARCIAL' } else { 'FALHA' })
    Add-Camada '5. Resolucao DNS' $dnsEstado ("{0} de {1} nome(s) resolvido(s)" -f $dnsOk, $nomes.Count)

    # -------------------------------------------------- 6. TCP com nome + 7. HTTP
    $tcpNome = Test-NetTcpPortQuick -Target 'www.microsoft.com' -Port 443 -TimeoutMs 5000
    [void]$detalhes.Add([pscustomobject]@{ Teste = 'TCP com nome'; Alvo = $tcpNome.Alvo; Resultado = $(if ($tcpNome.Ok) { 'Acessivel' } else { 'Bloqueado' }); Tempo = ('{0} ms' -f $tcpNome.Ms); Observacao = (Get-NetSafeText $tcpNome.Detalhe '') })
    Add-Camada '6. TCP 443 por nome' $(if ($tcpNome.Ok) { 'OK' } else { 'FALHA' }) ("{0} ({1})" -f $tcpNome.Alvo, $(if ($tcpNome.Ok) { 'handshake TCP concluido' } else { $tcpNome.Detalhe }))

    $http = Test-NetHttpProbe
    [void]$detalhes.Add([pscustomobject]@{ Teste = 'HTTP (NCSI)'; Alvo = $http.Alvo; Resultado = $(if ($http.Ok) { 'Respondeu' } else { 'Sem resposta' }); Tempo = ('{0} ms' -f $http.Ms); Observacao = (Get-NetSafeText $http.Detalhe '') })
    Add-Camada '7. HTTP externo' $(if ($http.Ok) { 'OK' } else { 'FALHA' }) ("{0} ({1})" -f $http.Alvo, $(if ($http.Ok) { 'resposta recebida' } else { $http.Detalhe }))

    # --------------------------------------------------------------- conclusao
    $nivel = 'OK'
    $diagnostico = 'Conectividade externa operacional nas camadas testadas.'
    $recomendacao = ''
    if (-not $temInterface) {
        $nivel = 'ERROR'
        $diagnostico = 'Nenhum adaptador de rede conectado: a cadeia falha na camada de interface.'
        $recomendacao = 'Verificar cabo, rede sem fio, driver do adaptador e se a interface esta desabilitada administrativamente.'
    } elseif (-not $temIp) {
        $nivel = 'ERROR'
        $diagnostico = $(if ($apipa) { 'Interface conectada com endereco APIPA (169.254.x): a concessao DHCP nao foi obtida.' } else { 'Interface conectada sem endereco IPv4 valido.' })
        $recomendacao = 'Validar o servidor DHCP e a concessao da interface. Em rede com endereco fixo, conferir a configuracao manual.'
    } elseif ($gateways.Count -eq 0) {
        $nivel = 'ERROR'
        $diagnostico = 'Endereco IPv4 presente, porem sem gateway padrao configurado.'
        $recomendacao = 'Sem gateway nao ha roteamento para fora da rede local: conferir a configuracao IP e a concessao DHCP.'
    } elseif (-not $tcpIp.Ok -and -not $http.Ok) {
        $nivel = 'WARN'
        $diagnostico = 'Configuracao IP presente, mas nenhuma conexao externa (TCP ou HTTP) pode ser estabelecida.'
        $recomendacao = 'Validar gateway, regras de saida do firewall, proxy corporativo e disponibilidade do enlace.'
    } elseif ($dnsEstado -eq 'FALHA' -and $tcpIp.Ok) {
        $nivel = 'WARN'
        $diagnostico = 'Transporte TCP externo funciona, porem nenhum nome de teste foi resolvido: a falha esta na resolucao DNS.'
        $recomendacao = 'Conferir os servidores DNS configurados na interface e limpar o cache DNS local. Nao alterar o DNS em rede corporativa sem validar com a equipe responsavel.'
    } elseif ($dnsEstado -eq 'PARCIAL') {
        $nivel = 'WARN'
        $diagnostico = 'Resolucao DNS parcial: parte dos nomes de teste nao foi resolvida.'
        $recomendacao = 'Pode indicar filtro de nomes, DNS corporativo com escopo restrito ou indisponibilidade pontual do dominio consultado.'
    } elseif (-not $tcpNome.Ok -or -not $http.Ok) {
        $nivel = 'WARN'
        $diagnostico = 'DNS resolve e o transporte responde, mas o destino de teste externo nao pode ser alcancado por completo.'
        $recomendacao = 'Verificar proxy corporativo, inspecao TLS e regras de saida do firewall. A indisponibilidade de um endpoint especifico nao caracteriza, por si so, ausencia de internet.'
    } elseif (-not $gwOk) {
        $diagnostico = 'Conectividade externa operacional. O gateway nao respondeu a ICMP, o que e comum quando o equipamento bloqueia ping.'
    }

    Write-NetLine ''
    Write-NetTable -Rows @($camadas)
    Write-NetLine ''
    Write-NetTable -Rows @($detalhes)

    Add-CompartDiskSection -Title 'Conectividade por camada' -Status (Get-NetSectionStatus $nivel) -Rows @($camadas) `
        -Summary $diagnostico
    Add-CompartDiskSection -Title 'Conectividade - evidencias' -Status INFO -Rows @($detalhes) `
        -Summary ("{0} sonda(s) executada(s); todas somente leitura" -f @($detalhes).Count)

    if ($nivel -eq 'OK') {
        Add-CompartDiskFinding -Severity OK -Area 'Rede' -Message $diagnostico
        Write-Log OK $diagnostico
    } else {
        Add-CompartDiskFinding -Severity (Get-NetFindingSeverity $nivel) -Area 'Rede' `
            -Message $diagnostico -Recommendation $recomendacao
        Set-NetResult $nivel 'falha identificada no teste de conectividade'
        if ($nivel -eq 'ERROR') { Write-Log ERR $diagnostico } else { Write-Log WARN $diagnostico }
    }
    # Este modulo diagnostica: nenhuma correcao e aplicada a partir do Test.
    Write-Log INFO 'Teste concluido sem aplicar alteracoes. Correcoes exigem a acao Reset, executada de forma explicita.'
}

# ==============================================================================
# ACAO: RESET  (modificadora)
# Etapas independentes, cada uma com pre-condicao, codigos aceitaveis proprios
# e resultado individual. Nao existe "reset unico e homogeneo".
#
# Fora do fluxo padrao, por decisao deliberada:
#  - netsh winhttp reset proxy : destroi configuracao de proxy corporativo e nao
#    pertence a pilha TCP/IP. Disponivel em -ResetProxy, com a configuracao
#    anterior registrada antes da alteracao.
#  - release/renew e reset de pilha sobre interface com endereco ESTATICO:
#    'netsh int ip reset' devolve a configuracao IP ao padrao e removeria o
#    endereco fixo. Exige -Force.
# ==============================================================================
function Get-NetWinHttpProxy {
    <# Leitura da configuracao WinHTTP atual (somente leitura). #>
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Ok = $false; Texto = ''; Detalhe = '' }
    $r = Invoke-NetCommand -FilePath $netsh -Arguments @('winhttp', 'show', 'proxy') `
            -TimeoutSeconds 30 -AcceptableExitCodes @(0) -Activity 'netsh winhttp show proxy'
    if ($r.Ok) {
        $out.Ok = $true
        $linhas = @(($r.StdOut -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $out.Texto = ($linhas -join ' | ')
    } else {
        $out.Detalhe = (Get-NetSafeText $r.Detalhe 'consulta nao concluida')
    }
    return $out
}

function Reset-NetworkStack {
    Write-Log INFO '=== RESET CONTROLADO DA PILHA DE REDE ==='

    # ------------------------------------------------------------ Etapa A: pre-check
    $facts   = Get-NetAdapterFacts
    $sessao  = Test-NetRemoteSession
    $reboot  = Test-NetRebootPending
    $dominio = Test-NetDomainJoined
    $proxyAntes = Get-NetWinHttpProxy

    $temEstatico = (@($facts.EstaticoIPv4).Count -gt 0)
    $temDhcp     = (@($facts.DhcpIPv4).Count -gt 0)
    $indefinido  = (@($facts.Indeterminados).Count -gt 0)

    Write-Log INFO ("Etapa A - Pre-check: {0} interface(s) conectada(s) | DHCP: {1} | estatico: {2} | sessao: {3} | reinicio pendente: {4}" -f `
        $facts.Conectados,
        $(if ($temDhcp) { (@($facts.DhcpIPv4) -join ', ') } else { 'nenhuma' }),
        $(if ($temEstatico) { (@($facts.EstaticoIPv4) -join ', ') } else { 'nenhuma' }),
        $sessao.Tipo,
        $(if ($reboot) { 'SIM' } else { 'Nao' }))
    Add-NetStep -Etapa 'A' -Operacao 'Pre-check' -Alvo 'configuracao de rede' -Resultado 'INFO' `
        -Detalhe ("conectadas={0}; DHCP={1}; estatico={2}; sessao={3}; reinicio pendente={4}; dominio={5}" -f `
            $facts.Conectados, @($facts.DhcpIPv4).Count, @($facts.EstaticoIPv4).Count, $sessao.Tipo, `
            $(if ($reboot) { 'sim' } else { 'nao' }), $(if ($dominio.Dominio) { $dominio.Nome } else { 'nao' }))

    if (-not $facts.Ok) {
        Write-Log ERR 'Nao foi possivel inventariar os adaptadores: o reset foi abortado antes de qualquer alteracao.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Rede' `
            -Message ('Reset abortado no pre-check: {0}' -f (Get-NetSafeText $facts.Detalhe 'inventario indisponivel')) `
            -Recommendation 'Sem inventario nao e possivel distinguir interface DHCP de estatica, e um reset as cegas removeria configuracao fixa.'
        Add-CompartDiskSection -Title 'Reset de rede' -Status CRIT -Summary 'Abortado no pre-check' -Rows @($script:Steps)
        Set-NetResult 'ERROR' 'pre-check do reset falhou'
        return
    }
    if ($sessao.Remota) {
        Write-Log WARN ("Execucao a partir de {0}: um reset de rede pode interromper esta propria sessao." -f $sessao.Tipo)
    }
    if ($reboot) {
        Write-Log WARN 'Ja existe reinicio pendente: parte das validacoes so sera conclusiva apos reiniciar.'
    }
    if ($dominio.Dominio) {
        Write-Log INFO ("Maquina ingressada no dominio '{0}': diretivas podem reaplicar configuracoes apos o reset." -f $dominio.Nome)
    }

    $exigeReboot = $false

    # -------------------------------------------------------------- Etapa B: DNS
    $b = Invoke-NetCommand -FilePath $ipcfg -Arguments @('/flushdns') -TimeoutSeconds 60 -AcceptableExitCodes @(0) -Activity 'ipconfig /flushdns'
    if ($b.Ok) {
        Write-Log OK 'Cache DNS local limpo.'
        Add-NetStep -Etapa 'B' -Operacao 'Limpar cache DNS' -Alvo 'resolvedor local' -Resultado 'OK' -Detalhe 'cache local esvaziado; nao altera os servidores DNS configurados'
    } else {
        Write-Log WARN ('Limpeza do cache DNS nao confirmada: {0}' -f $b.Detalhe)
        Add-NetStep -Etapa 'B' -Operacao 'Limpar cache DNS' -Alvo 'resolvedor local' -Resultado 'ERROR' -Detalhe $b.Detalhe
    }

    # ------------------------------------------------------------- Etapa C: DHCP
    # Release/renew so faz sentido onde existe concessao DHCP. Em interface
    # estatica o resultado correto e SKIPPED, nunca WARN.
    $dhcpPodeRodar = $temDhcp
    $motivoDhcp = ''
    if (-not $temDhcp) {
        $motivoDhcp = $(if ($temEstatico) { 'todas as interfaces conectadas usam endereco estatico' } elseif ($indefinido) { 'nao foi possivel determinar o modo de enderecamento' } else { 'nenhuma interface conectada com DHCP' })
    } elseif ($sessao.Remota -and -not $script:Force) {
        $dhcpPodeRodar = $false
        $motivoDhcp = ("execucao a partir de {0}: /release derrubaria esta sessao (use -Force para executar mesmo assim)" -f $sessao.Tipo)
    }

    if (-not $dhcpPodeRodar) {
        Write-Log INFO ('Etapa C ignorada - {0}.' -f $motivoDhcp)
        Add-NetStep -Etapa 'C' -Operacao 'Liberar e renovar concessao DHCP' -Alvo 'interfaces DHCP' -Resultado 'SKIPPED' -Detalhe $motivoDhcp
    } else {
        $rel = Invoke-NetCommand -FilePath $ipcfg -Arguments @('/release') -TimeoutSeconds 120 -AcceptableExitCodes @(0) -Activity 'ipconfig /release'
        if ($rel.Ok) { Add-NetStep -Etapa 'C' -Operacao 'Liberar concessao DHCP' -Alvo (@($facts.DhcpIPv4) -join ', ') -Resultado 'OK' -Detalhe 'concessao liberada' }
        else {
            Write-Log WARN ('Liberacao de concessao DHCP nao confirmada: {0}' -f $rel.Detalhe)
            Add-NetStep -Etapa 'C' -Operacao 'Liberar concessao DHCP' -Alvo (@($facts.DhcpIPv4) -join ', ') -Resultado 'WARN' -Detalhe $rel.Detalhe
        }
        $ren = Invoke-NetCommand -FilePath $ipcfg -Arguments @('/renew') -TimeoutSeconds 180 -AcceptableExitCodes @(0) -Activity 'ipconfig /renew'
        if ($ren.Ok) {
            Write-Log OK 'Concessao DHCP renovada.'
            Add-NetStep -Etapa 'C' -Operacao 'Renovar concessao DHCP' -Alvo (@($facts.DhcpIPv4) -join ', ') -Resultado 'OK' -Detalhe 'nova concessao obtida'
        } else {
            Write-Log WARN ('Renovacao de concessao DHCP nao confirmada: {0}' -f $ren.Detalhe)
            Add-NetStep -Etapa 'C' -Operacao 'Renovar concessao DHCP' -Alvo (@($facts.DhcpIPv4) -join ', ') -Resultado 'ERROR' -Detalhe $ren.Detalhe
        }
    }

    # ---------------------------------------------------------- Etapa D: Winsock
    # Alteracao sistemica: redefine o catalogo de provedores de sockets.
    # Nao toca na configuracao IP, entao nao depende do modo de enderecamento.
    $d = Invoke-NetCommand -FilePath $netsh -Arguments @('winsock', 'reset') -TimeoutSeconds 120 -AcceptableExitCodes @(0) -Activity 'netsh winsock reset'
    if ($d.Ok) {
        $exigeReboot = $true
        Write-Log OK 'Catalogo Winsock redefinido. A alteracao so se aplica integralmente apos reiniciar.'
        Add-NetStep -Etapa 'D' -Operacao 'Reset do Winsock' -Alvo 'catalogo de sockets' -Resultado 'OK' -Detalhe 'catalogo redefinido; exige reinicio para aplicar'
    } else {
        Write-Log WARN ('Reset do Winsock nao confirmado: {0}' -f $d.Detalhe)
        Add-NetStep -Etapa 'D' -Operacao 'Reset do Winsock' -Alvo 'catalogo de sockets' -Resultado 'ERROR' -Detalhe $d.Detalhe
    }

    # ------------------------------------------------- Etapas E e F: pilha IP
    # 'netsh int ip reset' devolve a configuracao IP ao padrao (DHCP). Em
    # interface com endereco fixo isso REMOVE a configuracao manual.
    $podePilha = $true
    $motivoPilha = ''
    if ($temEstatico -and -not $script:Force) {
        $podePilha = $false
        $motivoPilha = ("interface(s) com endereco estatico detectada(s) ({0}): o reset da pilha removeria a configuracao manual. Use -Force para executar mesmo assim" -f (@($facts.EstaticoIPv4) -join ', '))
    } elseif ($indefinido -and -not $script:Force) {
        $podePilha = $false
        $motivoPilha = ("nao foi possivel determinar o modo de enderecamento de {0}: o reset nao e aplicado as cegas. Use -Force para executar mesmo assim" -f (@($facts.Indeterminados) -join ', '))
    }

    foreach ($fam in @(@{ E = 'E'; A = @('int', 'ip', 'reset');   N = 'Reset da pilha IPv4' }, @{ E = 'F'; A = @('int', 'ipv6', 'reset'); N = 'Reset da pilha IPv6' })) {
        if (-not $podePilha) {
            Write-Log INFO ('Etapa {0} ignorada - {1}.' -f $fam.E, $motivoPilha)
            Add-NetStep -Etapa $fam.E -Operacao $fam.N -Alvo 'configuracao IP' -Resultado 'SKIPPED' -Detalhe $motivoPilha
            continue
        }
        # Codigo 1 e retorno documentado de sucesso que exige reinicio.
        $r = Invoke-NetCommand -FilePath $netsh -Arguments $fam.A -TimeoutSeconds 120 -AcceptableExitCodes @(0, 1) -Activity $fam.N
        if ($r.Ok) {
            $exigeReboot = $true
            Write-Log OK ('{0} concluido (codigo {1}); exige reinicio para aplicar.' -f $fam.N, $r.ExitCode)
            Add-NetStep -Etapa $fam.E -Operacao $fam.N -Alvo 'configuracao IP' -Resultado 'OK' -Detalhe ('codigo {0}: pilha redefinida, reinicio necessario' -f $r.ExitCode)
        } else {
            Write-Log WARN ('{0} nao confirmado: {1}' -f $fam.N, $r.Detalhe)
            Add-NetStep -Etapa $fam.E -Operacao $fam.N -Alvo 'configuracao IP' -Resultado 'ERROR' -Detalhe $r.Detalhe
        }
    }

    # --------------------------------------------------------------- Etapa G: ARP
    # Codigo 1 ocorre quando nao ha entradas a remover: nao e falha.
    $g = Invoke-NetCommand -FilePath $arp -Arguments @('-d', '*') -TimeoutSeconds 60 -AcceptableExitCodes @(0, 1) -Activity 'arp -d *'
    if ($g.Ok) {
        Write-Log OK 'Cache ARP limpo; as entradas serao recriadas conforme necessario.'
        Add-NetStep -Etapa 'G' -Operacao 'Limpar cache ARP' -Alvo 'tabela ARP' -Resultado 'OK' -Detalhe ('codigo {0}: entradas removidas ou tabela ja vazia' -f $g.ExitCode)
    } else {
        Write-Log WARN ('Limpeza do cache ARP nao confirmada: {0}' -f $g.Detalhe)
        Add-NetStep -Etapa 'G' -Operacao 'Limpar cache ARP' -Alvo 'tabela ARP' -Resultado 'WARN' -Detalhe $g.Detalhe
    }

    # ------------------------------------------------------- Etapa H: registro DNS
    $h = Invoke-NetCommand -FilePath $ipcfg -Arguments @('/registerdns') -TimeoutSeconds 120 -AcceptableExitCodes @(0) -Activity 'ipconfig /registerdns'
    if ($h.Ok) {
        # O comando solicita o registro; a conclusao depende do servidor DNS.
        Write-Log OK 'Solicitacao de registro DNS enviada. A conclusao depende do servidor DNS e nao e confirmada aqui.'
        Add-NetStep -Etapa 'H' -Operacao 'Solicitar registro DNS' -Alvo 'servidor DNS' -Resultado 'OK' -Detalhe 'solicitacao enviada; conclusao nao verificavel localmente'
    } else {
        Write-Log WARN ('Solicitacao de registro DNS nao confirmada: {0}' -f $h.Detalhe)
        Add-NetStep -Etapa 'H' -Operacao 'Solicitar registro DNS' -Alvo 'servidor DNS' -Resultado 'WARN' -Detalhe $h.Detalhe
    }

    # ------------------------------------------------------------ Etapa I: proxy
    if (-not $script:ResetProxy) {
        Add-NetStep -Etapa 'I' -Operacao 'Reset do proxy WinHTTP' -Alvo 'WinHTTP' -Resultado 'SKIPPED' `
            -Detalhe 'fora do fluxo padrao: destruiria configuracao de proxy corporativo. Usar -ResetProxy quando houver evidencia de proxy invalido'
        Write-Log INFO 'Etapa I ignorada - reset do proxy WinHTTP nao faz parte do reset padrao (use -ResetProxy).'
    } else {
        Write-Log WARN ('Reset do proxy WinHTTP solicitado. Configuracao anterior: {0}' -f (Get-NetSafeText $proxyAntes.Texto 'nao pode ser lida'))
        $i = Invoke-NetCommand -FilePath $netsh -Arguments @('winhttp', 'reset', 'proxy') -TimeoutSeconds 60 -AcceptableExitCodes @(0) -Activity 'netsh winhttp reset proxy'
        if ($i.Ok) {
            $proxyDepois = Get-NetWinHttpProxy
            Write-Log OK 'Proxy WinHTTP redefinido para acesso direto.'
            Add-NetStep -Etapa 'I' -Operacao 'Reset do proxy WinHTTP' -Alvo 'WinHTTP' -Resultado 'OK' `
                -Detalhe ("antes: {0} | depois: {1}" -f (Get-NetSafeText $proxyAntes.Texto 'nao lido'), (Get-NetSafeText $proxyDepois.Texto 'nao lido'))
            Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
                -Message ('Proxy WinHTTP redefinido para acesso direto. Configuracao anterior: {0}' -f (Get-NetSafeText $proxyAntes.Texto 'nao pode ser lida')) `
                -Recommendation 'Em ambiente corporativo, reaplicar a configuracao de proxy exigida pela organizacao (netsh winhttp set proxy ou importacao das definicoes do navegador).'
            Set-NetResult 'WARN' 'proxy WinHTTP redefinido'
        } else {
            Write-Log WARN ('Reset do proxy WinHTTP nao confirmado: {0}' -f $i.Detalhe)
            Add-NetStep -Etapa 'I' -Operacao 'Reset do proxy WinHTTP' -Alvo 'WinHTTP' -Resultado 'ERROR' -Detalhe $i.Detalhe
        }
    }

    # ---------------------------------------------------------- Revalidacao final
    Reset-NetCaches
    $factsDepois = Get-NetAdapterFacts
    $invDepois   = Get-NetworkInventory
    $ipsDepois = 0
    foreach ($a in $invDepois.Rows) {
        foreach ($ip in ("$($a.IPv4)" -split ',')) { if ($ip.Trim()) { $ipsDepois++ } }
    }
    Add-NetStep -Etapa 'Final' -Operacao 'Revalidacao' -Alvo 'estado da rede' -Resultado 'INFO' `
        -Detalhe ("conectadas={0}; enderecos IPv4 presentes={1}" -f $factsDepois.Conectados, $ipsDepois)

    $erros    = @($script:Steps | Where-Object { $_.Resultado -eq 'ERROR' })
    $alertas  = @($script:Steps | Where-Object { $_.Resultado -eq 'WARN' })
    $ignorados= @($script:Steps | Where-Object { $_.Resultado -eq 'SKIPPED' })
    $ok       = @($script:Steps | Where-Object { $_.Resultado -eq 'OK' })

    $nivel = 'OK'
    if ($erros.Count -gt 0) { $nivel = 'WARN' }
    if ($ok.Count -eq 0)    { $nivel = 'ERROR' }
    if ($factsDepois.Conectados -gt 0 -and $ipsDepois -eq 0 -and -not $exigeReboot) { $nivel = 'ERROR' }
    Set-NetResult $nivel 'resultado consolidado do reset de rede'

    $pares = [ordered]@{
        'Etapas concluidas'      = $ok.Count
        'Etapas com falha'       = $erros.Count
        'Etapas com ressalva'    = $alertas.Count
        'Etapas ignoradas'       = $ignorados.Count
        'Interfaces conectadas'  = ("antes {0} / depois {1}" -f $facts.Conectados, $factsDepois.Conectados)
        'Enderecos IPv4 apos'    = $ipsDepois
        'Proxy WinHTTP'          = $(if ($script:ResetProxy) { 'redefinido a pedido' } else { 'preservado' })
        'Reinicio pendente antes'= $(if ($reboot) { 'SIM' } else { 'Nao' })
        'Reinicio necessario'    = $(if ($exigeReboot) { 'SIM - Winsock e/ou pilha IP redefinidos' } else { 'Nao identificado' })
        'Sessao de execucao'     = $sessao.Tipo
        'Status final'           = $nivel
    }

    Write-NetLine ''
    Write-NetTable -Rows @($script:Steps)
    Add-CompartDiskSection -Title 'Reset de rede' -Status (Get-NetSectionStatus $nivel) -Pairs $pares `
        -Summary ("{0} etapa(s) concluida(s), {1} com falha, {2} ignorada(s)" -f $ok.Count, $erros.Count, $ignorados.Count)
    Add-CompartDiskSection -Title 'Reset de rede - etapas' -Status (Get-NetSectionStatus $nivel) -Rows @($script:Steps) `
        -Summary ("{0} etapa(s) registrada(s)" -f @($script:Steps).Count)

    $msg = ("Reset executado: {0} etapa(s) concluida(s), {1} com falha, {2} ignorada(s) por pre-condicao. " -f $ok.Count, $erros.Count, $ignorados.Count) +
           'A restauracao da conectividade nao esta comprovada por esta execucao.'
    $rec = 'Executar -Action Test para verificar em qual camada a rede responde apos a alteracao.'
    if ($exigeReboot) { $rec = 'Reiniciar o computador para aplicar o Winsock e a pilha IP, e em seguida executar -Action Test para verificar a conectividade.' }

    Add-CompartDiskFinding -Severity (Get-NetFindingSeverity $nivel) -Area 'Rede' -Message $msg -Recommendation $rec
    if ($nivel -eq 'OK') { Write-Log OK $msg } elseif ($nivel -eq 'WARN') { Write-Log WARN $msg } else { Write-Log ERR $msg }
    if ($exigeReboot) { Write-Log WARN 'Reinicio recomendado: Winsock e/ou pilha IP so se aplicam integralmente apos reiniciar.' }
}

# ==============================================================================
# BACKUP: nome exclusivo e validacao objetiva
# Test-Path sozinho nao prova backup: um arquivo antigo com o mesmo nome faria
# uma exportacao falha parecer bem-sucedida.
# ==============================================================================
function ConvertTo-NetNormalizedText {
    <# WriteAllLines usa o separador da plataforma; comparar texto sem
       normalizar CRLF/LF faria a confirmacao de conteudo falhar sempre e
       destruiria a idempotencia da acao. #>
    param([AllowNull()][object]$Value)
    return ((("$Value") -replace "`r`n", "`n").Trim())
}

function Get-NetBackupPath {
    param([Parameter(Mandatory)][string]$Prefixo, [Parameter(Mandatory)][string]$Extensao)
    $dir = $Global:CompartDisk.OutDir
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $env:TEMP }
    $sessao = Get-NetSafeText $Global:CompartDisk.Session (Get-Date -Format 'yyyyMMdd_HHmmss')
    $base = ('{0}_{1}_{2}' -f $Prefixo, $sessao, (Get-Date -Format 'HHmmss'))
    $alvo = Join-Path $dir ('{0}.{1}' -f $base, $Extensao)
    $i = 1
    while (Test-Path -LiteralPath $alvo) {
        $alvo = Join-Path $dir ('{0}_{1}.{2}' -f $base, $i, $Extensao)
        $i++
        if ($i -gt 50) { break }
    }
    return $alvo
}

function Test-NetBackupFile {
    <# Backup so e valido se o arquivo existe, foi criado NESTA execucao,
       tem conteudo e pode ser lido. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][datetime]$Desde, [long]$TamanhoMinimo = 1)
    $out = [pscustomobject]@{ Ok = $false; Bytes = 0; Detalhe = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $out.Detalhe = 'arquivo de backup nao foi criado'; return $out }
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $out.Bytes = [long]$fi.Length
        if ($fi.LastWriteTime -lt $Desde.AddSeconds(-5)) { $out.Detalhe = 'arquivo preexistente: nao foi gravado por esta execucao'; return $out }
        if ($fi.Length -lt $TamanhoMinimo) { $out.Detalhe = ('arquivo com {0} byte(s), abaixo do minimo esperado' -f $fi.Length); return $out }
        $fs = [System.IO.File]::OpenRead($fi.FullName)
        try {
            $buf = New-Object byte[] 16
            if ($fs.Read($buf, 0, 16) -le 0) { $out.Detalhe = 'arquivo de backup nao pode ser lido'; return $out }
        } finally { $fs.Dispose() }
        $out.Ok = $true
    } catch {
        $out.Detalhe = $_.Exception.Message
    }
    return $out
}

# ==============================================================================
# ACAO: HOSTS  (modificadora)
# Regra absoluta: sem backup validado, o arquivo hosts NAO e sobrescrito.
# ==============================================================================
function Restore-HostsFile {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

    # Conteudo minimo e valido: as entradas de localhost permanecem comentadas,
    # como no padrao da Microsoft, porque o Windows as resolve internamente.
    $conteudo = @(
        '# Copyright (c) 1993-2009 Microsoft Corp.'
        '#'
        '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.'
        '#'
        '# Cada entrada deve permanecer em uma linha individual.'
        '# O endereco IP deve vir na primeira coluna, seguido do nome correspondente.'
        '# O endereco e o nome devem ser separados por ao menos um espaco.'
        '#'
        '# Linhas iniciadas por "#" sao comentarios.'
        '#'
        '# Exemplos:'
        '#'
        '#      102.54.94.97     rhino.acme.com          # servidor de origem'
        '#       38.25.63.10     x.acme.com              # cliente x'
        '#'
        '# A resolucao de localhost e tratada pelo proprio DNS do Windows.'
        '#	127.0.0.1       localhost'
        '#	::1             localhost'
    )

    $existe = Test-Path -LiteralPath $hosts
    $atual = $null
    if ($existe) {
        $lr = Invoke-SafeCommand { [System.IO.File]::ReadAllText($hosts) } -Activity 'Leitura do arquivo hosts' -Silent
        if (-not $lr.Success) {
            Write-Log ERR 'O arquivo hosts existe mas nao pode ser lido: nenhuma alteracao foi aplicada.'
            Add-CompartDiskFinding -Severity CRIT -Area 'Rede' `
                -Message ('O arquivo hosts nao pode ser lido: {0}' -f $(if ($lr.Error) { $lr.Error.Exception.Message } else { 'motivo desconhecido' })) `
                -Recommendation 'Executar como administrador e verificar permissoes e bloqueio por antivirus antes de repetir.'
            Add-CompartDiskSection -Title 'Arquivo hosts' -Status CRIT -Summary 'Leitura nao concluida; arquivo preservado'
            Set-NetResult 'ERROR' 'arquivo hosts ilegivel'
            return
        }
        $atual = "$($lr.Value)"
    }

    # Idempotencia: se ja esta no conteudo padrao, nao ha o que substituir.
    $alvoTexto = ($conteudo -join "`r`n")
    $alvoNorm  = ConvertTo-NetNormalizedText $alvoTexto
    if ($existe -and ((ConvertTo-NetNormalizedText $atual) -eq $alvoNorm)) {
        Write-Log OK 'O arquivo hosts ja esta no conteudo padrao: nenhuma alteracao aplicada.'
        Add-CompartDiskSection -Title 'Arquivo hosts' -Status OK -Summary 'Ja no padrao; nenhuma alteracao necessaria' `
            -Pairs ([ordered]@{ 'Caminho' = $hosts; 'Acao' = 'nenhuma (idempotente)' })
        Add-CompartDiskFinding -Severity OK -Area 'Rede' -Message 'O arquivo hosts ja se encontra no conteudo padrao.'
        return
    }

    # ------------------------------------------------------------------ backup
    $bkpPath = ''
    $bkpBytes = 0
    if ($existe) {
        $inicio = Get-Date
        $bkpPath = Get-NetBackupPath -Prefixo 'hosts_anterior' -Extensao 'txt'
        $dirBkp = Split-Path -Parent $bkpPath
        $prep = Invoke-SafeCommand {
            if (-not (Test-Path -LiteralPath $dirBkp)) { New-Item -ItemType Directory -Path $dirBkp -Force -ErrorAction Stop | Out-Null }
            Copy-Item -LiteralPath $hosts -Destination $bkpPath -Force -ErrorAction Stop
        } -Activity 'Backup do arquivo hosts' -Silent

        $origemBytes = 0
        try { $origemBytes = [long](Get-Item -LiteralPath $hosts -ErrorAction Stop).Length } catch { $origemBytes = 0 }
        $val = Test-NetBackupFile -Path $bkpPath -Desde $inicio -TamanhoMinimo ([math]::Max(1, $origemBytes))

        if (-not $prep.Success -or -not $val.Ok) {
            $motivo = $(if (-not $prep.Success -and $prep.Error) { $prep.Error.Exception.Message } else { $val.Detalhe })
            Write-Log ERR ('Backup do arquivo hosts nao pode ser validado: {0}. O arquivo NAO foi alterado.' -f $motivo)
            Add-CompartDiskFinding -Severity CRIT -Area 'Rede' `
                -Message ('Restauracao do hosts abortada: o backup nao pode ser validado ({0}).' -f $motivo) `
                -Recommendation 'A sobrescrita e irreversivel sem backup. Definir COMPARTDISK_LOGDIR para um diretorio gravavel e repetir.'
            Add-CompartDiskSection -Title 'Arquivo hosts' -Status CRIT `
                -Pairs ([ordered]@{ 'Caminho' = $hosts; 'Backup' = $bkpPath; 'Situacao' = 'abortado: backup invalido'; 'Detalhe' = $motivo }) `
                -Summary 'Abortado antes de qualquer escrita; arquivo original preservado'
            Set-NetResult 'ERROR' 'backup do hosts invalido'
            return
        }
        $bkpBytes = $val.Bytes
        Write-Log OK ("Backup validado: {0} ({1} bytes)." -f $bkpPath, $bkpBytes)
    } else {
        Write-Log WARN 'O arquivo hosts nao existe: sera criado com o conteudo padrao (nao ha conteudo anterior para preservar).'
    }

    # ------------------------------------------------------------------ escrita
    # UTF-8 sem BOM: o conteudo padrao e ASCII puro, portanto os bytes gravados
    # sao identicos aos de ANSI e o parser do Windows os interpreta sem BOM.
    $w = Invoke-SafeCommand {
        [System.IO.File]::WriteAllLines($hosts, $conteudo, (New-Object System.Text.UTF8Encoding($false)))
    } -Activity 'Gravar hosts padrao' -Silent
    if (-not $w.Success) {
        $motivo = $(if ($w.Error) { $w.Error.Exception.Message } else { 'motivo desconhecido' })
        Write-Log ERR ('A gravacao do arquivo hosts falhou: {0}' -f $motivo)
        Add-CompartDiskFinding -Severity CRIT -Area 'Rede' `
            -Message ('Nao foi possivel gravar o arquivo hosts: {0}' -f $motivo) `
            -Recommendation $(if ($bkpPath) { ('O conteudo anterior esta preservado em {0}.' -f $bkpPath) } else { 'Executar como administrador e verificar bloqueio por antivirus.' })
        Add-CompartDiskSection -Title 'Arquivo hosts' -Status CRIT `
            -Pairs ([ordered]@{ 'Caminho' = $hosts; 'Backup' = (Get-NetSafeText $bkpPath 'nao aplicavel'); 'Situacao' = 'falha na gravacao' }) `
            -Summary 'Gravacao nao concluida'
        Set-NetResult 'ERROR' 'gravacao do hosts falhou'
        return
    }

    # --------------------------------------------------------------- validacao
    $rv = Invoke-SafeCommand { [System.IO.File]::ReadAllText($hosts) } -Activity 'Releitura do arquivo hosts' -Silent
    $confirmado = ($rv.Success -and (ConvertTo-NetNormalizedText $rv.Value) -eq $alvoNorm)
    if (-not $confirmado) {
        Write-Log WARN 'O arquivo hosts foi gravado, mas a releitura nao confirmou o conteudo esperado.'
        Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
            -Message 'O arquivo hosts foi gravado, porem a releitura nao confirmou o conteudo esperado.' `
            -Recommendation $(if ($bkpPath) { ('Conferir o arquivo manualmente; o conteudo anterior esta em {0}.' -f $bkpPath) } else { 'Conferir o arquivo manualmente.' })
        Set-NetResult 'WARN' 'conteudo do hosts nao confirmado'
    }

    # Flush do cache e etapa SEPARADA: limpar cache nao prova resolucao correta.
    $f = Invoke-NetCommand -FilePath $ipcfg -Arguments @('/flushdns') -TimeoutSeconds 60 -AcceptableExitCodes @(0) -Activity 'ipconfig /flushdns'
    if ($f.Ok) { Write-Log OK 'Cache DNS local limpo.' }
    else {
        Write-Log WARN ('Limpeza do cache DNS nao confirmada: {0}' -f $f.Detalhe)
        Set-NetResult 'WARN' 'flush de DNS nao confirmado'
    }

    $nivel = $(if ($confirmado -and $f.Ok) { 'OK' } else { 'WARN' })
    Add-CompartDiskSection -Title 'Arquivo hosts' -Status (Get-NetSectionStatus $nivel) `
        -Pairs ([ordered]@{
            'Caminho'          = $hosts
            'Existia antes'    = $(if ($existe) { 'Sim' } else { 'Nao' })
            'Backup'           = (Get-NetSafeText $bkpPath 'nao aplicavel (arquivo inexistente)')
            'Backup (bytes)'   = $bkpBytes
            'Conteudo confirmado' = $(if ($confirmado) { 'Sim (releitura)' } else { 'Nao' })
            'Cache DNS'        = $(if ($f.Ok) { 'limpo' } else { 'nao confirmado' })
        }) -Summary $(if ($nivel -eq 'OK') { 'Restaurado e confirmado por releitura' } else { 'Concluido com ressalvas' })

    if ($nivel -eq 'OK') {
        Write-Log OK 'Arquivo hosts restaurado ao conteudo padrao e confirmado por releitura.'
        Add-CompartDiskFinding -Severity OK -Area 'Rede' `
            -Message 'Arquivo hosts restaurado ao conteudo padrao e confirmado por releitura.' `
            -Recommendation $(if ($bkpPath) { ('Conteudo anterior preservado em {0}.' -f $bkpPath) } else { '' })
    }
}

# ==============================================================================
# ACAO: FIREWALL  (modificadora)
# Regra absoluta: sem backup validado, a politica NAO e redefinida.
# Perfis nao sao habilitados em bloco: apenas os que estavam habilitados antes
# e ficaram desabilitados pelo reset sao restaurados ao estado anterior.
# ==============================================================================
function Reset-FirewallPolicy {
    Write-Log INFO 'Preparando reset da politica de firewall...'

    $dominio = Test-NetDomainJoined
    $antes   = Get-NetFirewallState
    if (-not $antes.Ok) {
        Write-Log ERR 'O estado atual dos perfis do firewall nao pode ser lido: o reset foi abortado.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Firewall' `
            -Message ('Reset do firewall abortado: o estado atual nao pode ser lido ({0}).' -f (Get-NetSafeText $antes.Detalhe 'consulta indisponivel')) `
            -Recommendation 'Sem o estado anterior nao e possivel restaurar os perfis corretamente apos o reset.'
        Add-CompartDiskSection -Title 'Firewall - reset' -Status CRIT -Summary 'Abortado no pre-check'
        Set-NetResult 'ERROR' 'estado do firewall ilegivel'
        return
    }

    $estadoAnterior = @{}
    foreach ($p in $antes.Perfis) { $estadoAnterior["$($p.Perfil)"] = ("$($p.Habilitado)" -notmatch '^(False|0)$') }

    if ($dominio.Dominio) {
        Write-Log WARN ("Maquina no dominio '{0}': o reset afeta a politica LOCAL. Regras distribuidas por diretiva permanecem e podem ser reaplicadas." -f $dominio.Nome)
    }
    if ($antes.GerenciadoPorGpo) {
        Write-Log WARN 'Firewall sob diretiva de grupo: parte da configuracao sera reaplicada pela GPO apos o reset.'
    }
    if ($antes.ProdutoTerceiro) {
        Write-Log INFO ('Firewall de terceiros registrado: {0}' -f $antes.ProdutoTerceiro)
    }

    # ------------------------------------------------------------------ backup
    $inicio = Get-Date
    $bkp = Get-NetBackupPath -Prefixo 'Firewall_Backup' -Extensao 'wfw'
    $dirBkp = Split-Path -Parent $bkp
    try {
        if (-not (Test-Path -LiteralPath $dirBkp)) { New-Item -ItemType Directory -Path $dirBkp -Force -ErrorAction Stop | Out-Null }
    } catch {
        Write-Log ERR ('Diretorio de backup indisponivel: {0}' -f $dirBkp)
        Add-CompartDiskFinding -Severity CRIT -Area 'Firewall' `
            -Message ('Reset do firewall abortado: o diretorio de backup nao pode ser preparado ({0}).' -f $_.Exception.Message) `
            -Recommendation 'Definir COMPARTDISK_LOGDIR para um diretorio gravavel e repetir.'
        Add-CompartDiskSection -Title 'Firewall - reset' -Status CRIT -Summary 'Abortado: destino de backup indisponivel'
        Set-NetResult 'ERROR' 'destino de backup indisponivel'
        return
    }

    $exp = Invoke-NetCommand -FilePath $netsh -Arguments @('advfirewall', 'export', "`"$bkp`"") `
            -TimeoutSeconds 120 -AcceptableExitCodes @(0) -Activity 'netsh advfirewall export'
    $val = Test-NetBackupFile -Path $bkp -Desde $inicio -TamanhoMinimo 1024

    if (-not $exp.Ok -or -not $val.Ok) {
        $motivo = $(if (-not $exp.Ok) { (Get-NetSafeText $exp.Detalhe 'exportacao nao concluida') } else { $val.Detalhe })
        Write-Log ERR ('Backup da politica de firewall nao pode ser validado: {0}. O reset NAO foi executado.' -f $motivo)
        Add-CompartDiskFinding -Severity CRIT -Area 'Firewall' `
            -Message ('Reset do firewall abortado: o backup da politica nao pode ser validado ({0}).' -f $motivo) `
            -Recommendation 'O reset e irreversivel sem a politica exportada. Verificar privilegios administrativos e o diretorio de saida antes de repetir.'
        Add-CompartDiskSection -Title 'Firewall - reset' -Status CRIT `
            -Pairs ([ordered]@{ 'Backup' = $bkp; 'Situacao' = 'abortado: backup invalido'; 'Detalhe' = $motivo }) `
            -Summary 'Abortado antes de qualquer alteracao; politica atual preservada'
        Set-NetResult 'ERROR' 'backup do firewall invalido'
        return
    }
    Write-Log OK ("Backup da politica validado: {0} ({1} bytes)." -f $bkp, $val.Bytes)

    # ------------------------------------------------------------------- reset
    $r = Invoke-NetCommand -FilePath $netsh -Arguments @('advfirewall', 'reset') `
            -TimeoutSeconds 120 -AcceptableExitCodes @(0) -Activity 'netsh advfirewall reset'
    if (-not $r.Ok) {
        Write-Log ERR ('O reset da politica de firewall nao foi concluido: {0}' -f $r.Detalhe)
        Add-CompartDiskFinding -Severity CRIT -Area 'Firewall' `
            -Message ('O reset da politica de firewall nao foi concluido: {0}' -f $r.Detalhe) `
            -Recommendation ('A politica anterior permanece exportada em {0}.' -f $bkp)
        Add-CompartDiskSection -Title 'Firewall - reset' -Status CRIT `
            -Pairs ([ordered]@{ 'Backup' = $bkp; 'Codigo de retorno' = (Get-NetSafeText $r.ExitCode 'n/d'); 'Situacao' = 'reset nao concluido' }) `
            -Summary 'Reset nao concluido'
        Set-NetResult 'ERROR' 'reset do firewall nao concluido'
        return
    }

    # ------------------------------------------------- restauracao dos perfis
    Reset-NetCaches
    $depois = Get-NetFirewallState
    $restaurados = New-Object System.Collections.ArrayList
    $naoRestaurados = New-Object System.Collections.ArrayList

    if ($depois.Ok -and (Test-CompartDiskCommand 'Set-NetFirewallProfile')) {
        foreach ($p in $depois.Perfis) {
            $nome = "$($p.Perfil)"
            $agoraHabilitado = ("$($p.Habilitado)" -notmatch '^(False|0)$')
            $antesHabilitado = $false
            if ($estadoAnterior.ContainsKey($nome)) { $antesHabilitado = [bool]$estadoAnterior[$nome] }
            # Somente o que estava habilitado e o reset desligou. Um perfil
            # desativado de proposito continua desativado.
            if ($antesHabilitado -and -not $agoraHabilitado) {
                $s = Invoke-SafeCommand { Set-NetFirewallProfile -Profile $nome -Enabled True -ErrorAction Stop } -Activity ("Restaurar perfil {0}" -f $nome) -Silent
                if ($s.Success) { [void]$restaurados.Add($nome) }
                else { [void]$naoRestaurados.Add(('{0} ({1})' -f $nome, $(if ($s.Error) { $s.Error.Exception.Message } else { 'falha' }))) }
            }
        }
        if (@($restaurados).Count -gt 0) { Reset-NetCaches; $depois = Get-NetFirewallState }
    }

    # ---------------------------------------------------------- validacao final
    $desligadosDepois = @()
    if ($depois.Ok) { $desligadosDepois = @($depois.Desabilitados) }

    $nivel = 'OK'
    if (-not $depois.Ok) { $nivel = 'WARN' }
    elseif (@($naoRestaurados).Count -gt 0) { $nivel = 'WARN' }
    else {
        foreach ($nome in $estadoAnterior.Keys) {
            if ([bool]$estadoAnterior[$nome] -and (@($desligadosDepois) -contains $nome)) { $nivel = 'WARN'; break }
        }
    }
    Set-NetResult $nivel 'resultado do reset da politica de firewall'

    $pares = [ordered]@{
        'Backup da politica'      = $bkp
        'Backup (bytes)'          = $val.Bytes
        'Codigo do reset'         = (Get-NetSafeText $r.ExitCode 'n/d')
        'Perfis antes'            = (($antes.Perfis | ForEach-Object { '{0}={1}' -f $_.Perfil, $(if ("$($_.Habilitado)" -notmatch '^(False|0)$') { 'on' } else { 'off' }) }) -join ', ')
        'Perfis depois'           = $(if ($depois.Ok) { (($depois.Perfis | ForEach-Object { '{0}={1}' -f $_.Perfil, $(if ("$($_.Habilitado)" -notmatch '^(False|0)$') { 'on' } else { 'off' }) }) -join ', ') } else { 'nao verificado' })
        'Perfis restaurados'      = $(if (@($restaurados).Count -gt 0) { (@($restaurados) -join ', ') } else { 'nenhum necessario' })
        'Perfis nao restaurados'  = $(if (@($naoRestaurados).Count -gt 0) { (@($naoRestaurados) -join ', ') } else { 'nenhum' })
        'Perfil de rede ativo'    = $(if ($depois.Ok) { $depois.PerfilAtivo } else { $antes.PerfilAtivo })
        'Gerenciado por GPO'      = $(if ($antes.GerenciadoPorGpo) { 'Sim' } else { 'Nao detectado' })
        'Dominio'                 = $(if ($dominio.Dominio) { $dominio.Nome } else { 'nao ingressada' })
        'Firewall de terceiros'   = $(if ($antes.ProdutoTerceiro) { $antes.ProdutoTerceiro } else { 'nenhum registrado' })
        'Status final'            = $nivel
    }
    Add-CompartDiskSection -Title 'Firewall - reset' -Status (Get-NetSectionStatus $nivel) -Pairs $pares `
        -Rows $(if ($depois.Ok) { $depois.Perfis } else { @() }) `
        -Summary ("Politica local redefinida; {0} perfil(is) restaurado(s) ao estado anterior" -f @($restaurados).Count)

    if ($nivel -eq 'OK') {
        $msg = 'Politica local de firewall redefinida ao padrao e estado dos perfis confirmado por releitura.'
        Write-Log OK $msg
        Add-CompartDiskFinding -Severity OK -Area 'Firewall' -Message $msg `
            -Recommendation ("Regras personalizadas anteriores estao no backup {0} e podem ser reimportadas com 'netsh advfirewall import'." -f $bkp)
    } else {
        $msg = ('Reset da politica executado, porem o estado final dos perfis nao pode ser plenamente confirmado{0}.' -f $(if (@($naoRestaurados).Count -gt 0) { (': ' + (@($naoRestaurados) -join ', ')) } else { '' }))
        Write-Log WARN $msg
        Add-CompartDiskFinding -Severity WARN -Area 'Firewall' -Message $msg `
            -Recommendation ("Conferir os perfis manualmente. O backup {0} permite reimportar a politica anterior." -f $bkp)
    }
    if ($antes.GerenciadoPorGpo -or $dominio.Dominio) {
        Add-CompartDiskFinding -Severity INFO -Area 'Firewall' `
            -Message 'O reset afeta apenas a politica local; regras distribuidas por diretiva de grupo permanecem e podem ser reaplicadas.' `
            -Recommendation 'Em parque gerenciado, validar com a equipe responsavel antes de considerar a configuracao final.'
    }
}

# ==============================================================================
# ACAO: PROXY  (estritamente somente leitura)
# WinINet (por usuario) e WinHTTP (do sistema) sao configuracoes DISTINTAS e
# podem divergir legitimamente. Proxy configurado NAO e anomalia.
# ==============================================================================
function Protect-NetProxyString {
    <# Mascara credenciais embutidas (usuario:senha@host) antes de exibir. #>
    param([AllowNull()][object]$Value)
    $t = "$Value"
    if ([string]::IsNullOrWhiteSpace($t)) { return $t }
    return ($t -replace '([A-Za-z0-9._%+\-]+):([^@\s/]+)@', '***:***@')
}

function Show-ProxyConfig {
    Write-Log INFO 'Coletando configuracao de proxy (somente leitura)...'
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

    $habilitado = Get-CompartDiskRegistryValue $reg 'ProxyEnable' 0
    $servidor   = Get-CompartDiskRegistryValue $reg 'ProxyServer' ''
    $excecoes   = Get-CompartDiskRegistryValue $reg 'ProxyOverride' ''
    $pac        = Get-CompartDiskRegistryValue $reg 'AutoConfigURL' ''
    $autoDetect = Get-CompartDiskRegistryValue $reg 'AutoDetect' $null

    $wininet = [ordered]@{
        'Proxy manual habilitado'      = $(if ("$habilitado" -eq '1') { 'Sim' } else { 'Nao' })
        'Servidor proxy'               = $(if ($servidor) { (Protect-NetProxyString $servidor) } else { 'nenhum' })
        'Excecoes'                     = $(if ($excecoes) { "$excecoes" } else { 'nenhuma' })
        'Script de configuracao automatica' = $(if ($pac) { (Protect-NetProxyString $pac) } else { 'nenhum' })
        'Deteccao automatica (WPAD)'   = $(if ($null -eq $autoDetect) { 'nao definido' } elseif ("$autoDetect" -eq '1') { 'Sim' } else { 'Nao' })
        'Escopo'                       = 'usuario atual do processo (HKCU)'
    }

    # WinHTTP: usado por Windows Update, BITS e servicos. Falha de consulta NAO
    # pode ser reportada como "sem proxy".
    $wh = Get-NetWinHttpProxy
    $winhttp = [ordered]@{}
    if ($wh.Ok) {
        $winhttp['Configuracao'] = (Protect-NetProxyString $wh.Texto)
        $winhttp['Consulta']     = 'concluida'
    } else {
        $winhttp['Configuracao'] = 'nao foi possivel consultar o WinHTTP'
        $winhttp['Consulta']     = (Get-NetSafeText $wh.Detalhe 'falha na consulta')
    }

    foreach ($k in $wininet.Keys) { Write-NetPair $k $wininet[$k] }
    Write-NetLine ''
    foreach ($k in $winhttp.Keys) { Write-NetPair ("WinHTTP - $k") $winhttp[$k] }

    Add-CompartDiskSection -Title 'Proxy - WinINet (usuario)' -Status INFO -Pairs $wininet `
        -Summary 'Configuracao usada por navegadores e aplicacoes do usuario'
    Add-CompartDiskSection -Title 'Proxy - WinHTTP (sistema)' -Status $(if ($wh.Ok) { 'INFO' } else { 'WARN' }) -Pairs $winhttp `
        -Summary 'Configuracao usada por Windows Update, BITS e servicos do sistema'

    if (-not $wh.Ok) {
        Add-CompartDiskFinding -Severity WARN -Area 'Rede' `
            -Message ('A configuracao de proxy WinHTTP nao pode ser consultada: {0}' -f (Get-NetSafeText $wh.Detalhe 'falha na consulta')) `
            -Recommendation 'A ausencia de leitura nao significa ausencia de proxy: repetir a consulta antes de concluir.'
        Set-NetResult 'WARN' 'consulta WinHTTP indisponivel'
    } else {
        $temProxy = (("$habilitado" -eq '1') -or $pac -or ($wh.Texto -notmatch '(?i)direct|direto'))
        $msg = $(if ($temProxy) { 'Configuracao de proxy presente e coletada. Proxy configurado e condicao normal em ambiente corporativo.' } else { 'Nenhum proxy configurado para o usuario atual nem para o WinHTTP.' })
        Add-CompartDiskFinding -Severity INFO -Area 'Rede' -Message $msg
    }
    Write-Log OK 'Configuracao de proxy coletada (nenhuma alteracao aplicada).'
}

# ==============================================================================
# ACAO: WIFI  (estritamente somente leitura)
# O modulo NAO recupera, NAO exibe e NAO exporta chaves de seguranca: o verbo
# 'key=clear' do netsh nunca e utilizado.
# ==============================================================================
function ConvertFrom-NetshWlanBlock {
    <# Parsing resiliente a idioma: as chaves sao reconhecidas pelo prefixo
       ASCII, o que funciona em portugues e ingles e sobrevive a diferencas de
       codificacao na saida do netsh. #>
    param([string]$Texto)

    $mapa = @(
        @{ Campo = 'Interface';    Padrao = '^(Name|Nome)$' }
        @{ Campo = 'Descricao';    Padrao = '^Descri' }
        @{ Campo = 'Estado';       Padrao = '^(State|Estado)$' }
        @{ Campo = 'SSID';         Padrao = '^SSID$' }
        @{ Campo = 'BSSID';        Padrao = '^BSSID$' }
        @{ Campo = 'Radio';        Padrao = '^(Radio type|Tipo de r)' }
        @{ Campo = 'Autenticacao'; Padrao = '^(Authentication|Autentica)' }
        @{ Campo = 'Criptografia'; Padrao = '^(Cipher|Codifica|Cifra)' }
        @{ Campo = 'Canal';        Padrao = '^(Channel|Canal)$' }
        @{ Campo = 'Sinal';        Padrao = '^(Signal|Sinal)$' }
        @{ Campo = 'Banda';        Padrao = '^(Band|Banda)$' }
        @{ Campo = 'RecepcaoMbps'; Padrao = '^(Receive rate|Taxa de rec)' }
        @{ Campo = 'EnvioMbps';    Padrao = '^(Transmit rate|Taxa de trans)' }
    )

    $blocos = New-Object System.Collections.ArrayList
    $atual = $null
    foreach ($linha in ($Texto -split "`r?`n")) {
        if ($linha -notmatch '^\s*(.+?)\s*:\s*(.*)$') { continue }
        $chave = $Matches[1].Trim()
        $valor = $Matches[2].Trim()
        if ($chave -match '^(Name|Nome)$') {
            if ($null -ne $atual) { [void]$blocos.Add($atual) }
            $atual = [ordered]@{}
            foreach ($m in $mapa) { $atual[$m.Campo] = 'n/d' }
        }
        if ($null -eq $atual) { continue }
        foreach ($m in $mapa) {
            if ($chave -match $m.Padrao) {
                # Primeira ocorrencia vence: evita que chaves semelhantes mais
                # abaixo no bloco sobrescrevam o valor correto.
                if ($atual[$m.Campo] -eq 'n/d' -and $valor) { $atual[$m.Campo] = $valor }
                break
            }
        }
    }
    if ($null -ne $atual) { [void]$blocos.Add($atual) }

    return @(@($blocos) | ForEach-Object {
        $h = $_
        $o = [pscustomobject]@{}
        foreach ($m in $mapa) { Add-Member -InputObject $o -MemberType NoteProperty -Name $m.Campo -Value $h[$m.Campo] }
        $o
    })
}

function Get-NetWifiAdapterPresence {
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Ok = $false; Presente = $false; Total = 0; Detalhe = '' }
    if (-not (Test-CompartDiskCommand 'Get-NetAdapter')) {
        $out.Detalhe = 'Get-NetAdapter indisponivel nesta instalacao'
        return $out
    }
    $r = Invoke-SafeCommand { Get-NetAdapter -ErrorAction Stop } -Activity 'Get-NetAdapter (Wi-Fi)' -Silent
    if (-not $r.Success) {
        $out.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'consulta nao concluida' })
        return $out
    }
    $wifi = @((ConvertTo-NetArray $r.Value) | Where-Object {
        "$($_.PhysicalMediaType)" -match '802\.11|Wireless' -or "$($_.InterfaceDescription)" -match '(?i)wi-?fi|wireless|802\.11'
    })
    $out.Ok = $true
    $out.Total = $wifi.Count
    $out.Presente = ($wifi.Count -gt 0)
    return $out
}

function Show-WifiInfo {
    Write-Log INFO 'Coletando diagnostico Wi-Fi (somente leitura)...'
    $presenca = Get-NetWifiAdapterPresence

    $r = Invoke-NetCommand -FilePath $netsh -Arguments @('wlan', 'show', 'interfaces') `
            -TimeoutSeconds 45 -AcceptableExitCodes @(0) -Activity 'netsh wlan show interfaces'

    if (-not $r.Ok) {
        # Ausencia de Wi-Fi e condicao normal em desktop, servidor ou maquina
        # cabeada: nao e defeito e nao gera CRIT.
        $semAdaptador = ($presenca.Ok -and -not $presenca.Presente)
        $sev = $(if ($semAdaptador) { 'INFO' } else { 'WARN' })
        $msg = $(if ($semAdaptador) {
            'Nenhum adaptador Wi-Fi presente neste sistema (condicao normal em equipamento cabeado, servidor ou maquina virtual).'
        } else {
            ('Nao foi possivel consultar as interfaces Wi-Fi: {0}' -f (Get-NetSafeText $r.Detalhe 'servico WLAN pode estar inativo'))
        })
        $rec = $(if ($semAdaptador) { '' } else { 'Verificar se o servico WLAN AutoConfig (WlanSvc) esta em execucao e se o adaptador esta habilitado.' })

        Write-Log $(if ($semAdaptador) { 'INFO' } else { 'WARN' }) $msg
        Add-CompartDiskSection -Title 'Wi-Fi' -Status $sev `
            -Pairs ([ordered]@{
                'Adaptador Wi-Fi'  = $(if ($presenca.Ok) { $(if ($presenca.Presente) { ("{0} presente(s)" -f $presenca.Total) } else { 'nenhum' }) } else { 'nao determinado' })
                'Consulta netsh'   = (Get-NetSafeText $r.Detalhe 'nao concluida')
            }) -Summary $msg
        Add-CompartDiskFinding -Severity $sev -Area 'Rede' -Message $msg -Recommendation $rec
        if ($sev -eq 'WARN') { Set-NetResult 'WARN' 'consulta Wi-Fi indisponivel' }
        return
    }

    $interfaces = ConvertFrom-NetshWlanBlock -Texto $r.StdOut
    if (@($interfaces).Count -eq 0) {
        Write-Log INFO 'O servico WLAN respondeu, porem nenhuma interface Wi-Fi foi listada.'
        Add-CompartDiskSection -Title 'Wi-Fi' -Status INFO -Summary 'Servico WLAN ativo sem interfaces listadas'
        Add-CompartDiskFinding -Severity INFO -Area 'Rede' `
            -Message 'O servico WLAN respondeu, porem nenhuma interface Wi-Fi foi listada.' `
            -Recommendation 'Verificar se o adaptador esta desabilitado ou se o modo aviao esta ativo.'
        return
    }

    Write-NetLine ''
    Write-NetTable -Rows $interfaces -Property @('Interface', 'Estado', 'SSID', 'Sinal', 'Canal', 'Radio', 'Autenticacao', 'Criptografia')

    $conectadas = @($interfaces | Where-Object { "$($_.SSID)" -ne 'n/d' -and "$($_.SSID)" })
    Add-CompartDiskSection -Title 'Wi-Fi - interfaces' -Status INFO -Rows $interfaces `
        -Summary ("{0} interface(s) Wi-Fi; {1} associada(s) a uma rede" -f @($interfaces).Count, @($conectadas).Count)

    # Perfis: somente a quantidade e os nomes. Nenhuma chave de seguranca e
    # consultada, exibida ou exportada por este modulo.
    $p = Invoke-NetCommand -FilePath $netsh -Arguments @('wlan', 'show', 'profiles') `
            -TimeoutSeconds 45 -AcceptableExitCodes @(0) -Activity 'netsh wlan show profiles'
    if ($p.Ok) {
        $nomes = New-Object System.Collections.ArrayList
        foreach ($linha in ($p.StdOut -split "`r?`n")) {
            if ($linha -match '^\s*(All User Profile|Perfil de Todos os Usu|Perfil de todos os usu)[^:]*:\s*(.+?)\s*$') {
                [void]$nomes.Add($Matches[2].Trim())
            }
        }
        $rows = @(@($nomes) | ForEach-Object { [pscustomobject]@{ Perfil = $_ } })
        Add-CompartDiskSection -Title 'Wi-Fi - perfis salvos' -Status INFO -Rows $rows `
            -Pairs ([ordered]@{ 'Perfis salvos' = @($nomes).Count; 'Chaves de seguranca' = 'nao consultadas por decisao de projeto' }) `
            -Summary ("{0} perfil(is) salvo(s); nenhuma credencial e lida ou exibida" -f @($nomes).Count)
        Write-NetLine ("`n  Perfis Wi-Fi salvos: {0}" -f @($nomes).Count) 'White'
    } else {
        Add-CompartDiskSection -Title 'Wi-Fi - perfis salvos' -Status WARN -Summary 'Consulta de perfis nao concluida'
        Write-Log WARN ('Nao foi possivel listar os perfis Wi-Fi: {0}' -f (Get-NetSafeText $p.Detalhe 'consulta nao concluida'))
        Set-NetResult 'WARN' 'consulta de perfis Wi-Fi indisponivel'
    }

    if (@($conectadas).Count -eq 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Rede' `
            -Message ("{0} interface(s) Wi-Fi presente(s), nenhuma associada a uma rede no momento." -f @($interfaces).Count) `
            -Recommendation 'Condicao normal quando o equipamento usa cabo ou esta fora do alcance da rede sem fio.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Rede' `
            -Message ("{0} interface(s) Wi-Fi associada(s) a uma rede." -f @($conectadas).Count)
    }
    Write-Log OK 'Diagnostico Wi-Fi coletado (nenhuma alteracao aplicada).'
}

# ==============================================================================
# DESPACHO
# Info, Test, Proxy e Wifi sao somente leitura e nao exigem elevacao.
# Reset, Hosts e Firewall modificam o sistema e exigem administrador.
# ==============================================================================
$codigo = $Global:CompartDisk.Exit.ERROR
try {
    $precisaAdmin = @('Reset', 'Hosts', 'Firewall') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Network' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # Sem isto o estado persistido para o Report.ps1 sairia como OK enquanto
        # o modulo devolvia codigo de erro.
        Set-NetResult 'ERROR' 'privilegios administrativos ausentes'
    } else {
        if ($precisaAdmin) {
            $s = Test-NetRemoteSession
            Write-Log INFO ("Acao modificadora '{0}' iniciada a partir de {1}. Alteracoes de rede podem interromper sessoes remotas." -f $Action, $s.Tipo)
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
    }
} catch {
    Set-NetResult 'ERROR' 'excecao nao tratada'
    Write-Log ERR "Falha nao tratada no modulo Network (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Rede' `
        -Message ("Excecao no modulo durante a acao '{0}': {1}" -f $Action, $_.Exception.Message) `
        -Recommendation 'Consultar o log detalhado da sessao para a etapa exata e o codigo do erro.'
} finally {
    $codigo = Stop-CompartDiskModule -Result $script:result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$script:result] }
}
exit ([int]$codigo)
