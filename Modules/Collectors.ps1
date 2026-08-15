<#
================================================================================
 COMPARTDISK 1.4.3 - Collectors.ps1
 Desenvolvido por Edsilas
 Coletores de dados reutilizaveis (somente leitura, nao alteram o sistema).
 Carregado automaticamente pelo Core.ps1.
================================================================================
#>

function Get-CompartDiskSystemInfo {
    [CmdletBinding()] param()
    $os = Get-CompartDiskCim -Class Win32_OperatingSystem
    $cs = Get-CompartDiskCim -Class Win32_ComputerSystem
    $bios = Get-CompartDiskCim -Class Win32_BIOS | Select-Object -First 1
    $w = Test-WindowsVersion

    $uptime = 'n/d'
    try {
        if ($os -and $os.LastBootUpTime) {
            $lb = if ($os.LastBootUpTime -is [datetime]) { $os.LastBootUpTime } else { [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime) }
            $u = (Get-Date) - $lb
            $uptime = ('{0}d {1}h {2}m' -f $u.Days, $u.Hours, $u.Minutes)
        }
    } catch { }

    return [ordered]@{
        'Sistema'          = $w.Caption
        'Familia'          = $w.Family
        'Versao'           = $w.DisplayVersion
        'Build'            = $w.FullBuild
        'Arquitetura'      = $w.Architecture
        'Instalado em'     = $(if ($os) { $os.InstallDate } else { 'n/d' })
        'Ultimo boot'      = $(if ($os) { $os.LastBootUpTime } else { 'n/d' })
        'Tempo ligado'     = $uptime
        'Fabricante'       = $(if ($cs) { $cs.Manufacturer } else { 'n/d' })
        'Modelo'           = $(if ($cs) { $cs.Model } else { 'n/d' })
        'Dominio/Grupo'    = $(if ($cs) { $cs.Domain } else { 'n/d' })
        'BIOS'             = $(if ($bios) { "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)" } else { 'n/d' })
        'BIOS data'        = $(if ($bios) { $bios.ReleaseDate } else { 'n/d' })
        'Numero de serie'  = $(if ($bios) { $bios.SerialNumber } else { 'n/d' })
        'Locale'           = (Get-Culture).Name
        'Fuso horario'     = (Get-TimeZone -ErrorAction SilentlyContinue).Id
    }
}

function Get-CompartDiskHardwareInfo {
    [CmdletBinding()] param()
    $cpu   = Get-CompartDiskCim -Class Win32_Processor | Select-Object -First 1
    $os    = Get-CompartDiskCim -Class Win32_OperatingSystem
    $board = Get-CompartDiskCim -Class Win32_BaseBoard | Select-Object -First 1

    $ramTotal = 0
    if ($os) { $ramTotal = [long]$os.TotalVisibleMemorySize * 1KB }
    $ramFree = 0
    if ($os) { $ramFree = [long]$os.FreePhysicalMemory * 1KB }

    $virt = 'n/d'
    try { if ($cpu) { $virt = if ($cpu.VirtualizationFirmwareEnabled) { 'Habilitada no firmware' } else { 'Desabilitada no firmware' } } } catch { }

    return [ordered]@{
        'CPU'                = $(if ($cpu) { $cpu.Name.Trim() } else { 'n/d' })
        'Nucleos fisicos'    = $(if ($cpu) { $cpu.NumberOfCores } else { 'n/d' })
        'Nucleos logicos'    = $(if ($cpu) { $cpu.NumberOfLogicalProcessors } else { 'n/d' })
        'Clock base'         = $(if ($cpu) { "$($cpu.MaxClockSpeed) MHz" } else { 'n/d' })
        'Socket'             = $(if ($cpu) { $cpu.SocketDesignation } else { 'n/d' })
        'Virtualizacao'      = $virt
        'Placa-mae'          = $(if ($board) { "$($board.Manufacturer) $($board.Product)" } else { 'n/d' })
        'Placa-mae serial'   = $(if ($board) { $board.SerialNumber } else { 'n/d' })
        'RAM total'          = (ConvertTo-CompartDiskSize $ramTotal)
        'RAM disponivel'     = (ConvertTo-CompartDiskSize $ramFree)
        'RAM em uso (%)'     = $(if ($ramTotal -gt 0) { [math]::Round((($ramTotal - $ramFree) / $ramTotal) * 100, 1) } else { 'n/d' })
    }
}

function Get-CompartDiskMemoryModules {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    $tipos = @{
        0 = 'Desconhecido'; 20 = 'DDR'; 21 = 'DDR2'; 22 = 'DDR2 FB-DIMM'; 24 = 'DDR3'; 26 = 'DDR4'
        27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5'
    }
    foreach ($m in (Get-CompartDiskCim -Class Win32_PhysicalMemory)) {
        # Speed e a velocidade NOMINAL do modulo; ConfiguredClockSpeed e a que ele
        # realmente opera. Publicar so uma das duas faz um modulo DDR4-3200 rodando
        # a 2133 parecer estar na velocidade de catalogo.
        [void]$rows.Add([pscustomobject]@{
            Slot        = $m.DeviceLocator
            Capacidade  = (ConvertTo-CompartDiskSize $m.Capacity)
            Velocidade  = $(if ($m.Speed) { "$($m.Speed) MHz" } else { 'n/d' })
            VelocidadeConfigurada = $(if ($m.ConfiguredClockSpeed) { "$($m.ConfiguredClockSpeed) MHz" } else { 'n/d' })
            Tipo        = $(if ($tipos.ContainsKey([int]$m.SMBIOSMemoryType)) { $tipos[[int]$m.SMBIOSMemoryType] } else { "Codigo $($m.SMBIOSMemoryType)" })
            Fabricante  = "$($m.Manufacturer)".Trim()
            PartNumber  = "$($m.PartNumber)".Trim()
            NumeroSerie = "$($m.SerialNumber)".Trim()
            # Valores crus para calculo e validacao, sem reparsing de texto.
            CapacidadeBytes      = $m.Capacity
            VelocidadeNominalMHz = $m.Speed
        })
    }
    return @($rows)
}

function Get-CompartDiskGpuInfo {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($g in (Get-CompartDiskCim -Class Win32_VideoController)) {
        [void]$rows.Add([pscustomobject]@{
            Adaptador    = $g.Name
            VRAM         = (ConvertTo-CompartDiskSize $g.AdapterRAM)
            Driver       = $g.DriverVersion
            DriverData   = $g.DriverDate
            Resolucao    = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"
            Atualizacao  = $(if ($g.CurrentRefreshRate) { "$($g.CurrentRefreshRate) Hz" } else { 'n/d' })
            Status       = $g.Status
            # PNPDeviceID distingue adaptador fisico (PCI\) de adaptador de software
            # (ROOT\, SW\) sem comparar nomes traduziveis. AdapterRAM cru permite ao
            # consumidor detectar a saturacao de 32 bits desta propriedade.
            PNPDeviceID    = "$($g.PNPDeviceID)"
            AdapterRAMBytes = $g.AdapterRAM
        })
    }
    return @($rows)
}

function Get-CompartDiskMonitors {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($m in (Get-CompartDiskCim -Class WmiMonitorID -Namespace 'root\wmi')) {
        $dec = {
            param($arr)
            if (-not $arr) { return 'n/d' }
            (($arr | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ }) -join '').Trim()
        }
        [void]$rows.Add([pscustomobject]@{
            Fabricante  = (& $dec $m.ManufacturerName)
            Modelo      = (& $dec $m.UserFriendlyName)
            NumeroSerie = (& $dec $m.SerialNumberID)
            AnoFabrico  = $m.YearOfManufacture
            Ativo       = $m.Active
        })
    }
    return @($rows)
}

function Get-CompartDiskDiskInfo {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList

    if (Test-CompartDiskCommand 'Get-PhysicalDisk') {
        try {
            foreach ($d in (Get-PhysicalDisk -ErrorAction Stop)) {
                $rel = $null
                try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
                [void]$rows.Add([pscustomobject]@{
                    Id           = $d.DeviceId
                    Modelo       = $d.FriendlyName
                    Midia        = "$($d.MediaType)"
                    Barramento   = "$($d.BusType)"
                    Tamanho      = (ConvertTo-CompartDiskSize $d.Size)
                    Saude        = "$($d.HealthStatus)"
                    Operacional  = ("$($d.OperationalStatus)")
                    Temperatura  = $(if ($rel -and $rel.Temperature) { "$($rel.Temperature) C" } else { 'n/d' })
                    HorasLigado  = $(if ($rel -and $rel.PowerOnHours) { $rel.PowerOnHours } else { 'n/d' })
                    Desgaste     = $(if ($rel -and $null -ne $rel.Wear) { "$($rel.Wear)%" } else { 'n/d' })
                    ErrosLeitura = $(if ($rel) { $rel.ReadErrorsTotal } else { 'n/d' })
                    ErrosEscrita = $(if ($rel) { $rel.WriteErrorsTotal } else { 'n/d' })
                    Fonte        = 'Storage'
                })
            }
        } catch { Write-Log DEBUG "Get-PhysicalDisk: $($_.Exception.Message)" -NoConsole }
    }

    if ($rows.Count -eq 0) {
        foreach ($d in (Get-CompartDiskCim -Class Win32_DiskDrive)) {
            [void]$rows.Add([pscustomobject]@{
                Id = $d.Index; Modelo = $d.Model; Midia = $d.MediaType; Barramento = $d.InterfaceType
                Tamanho = (ConvertTo-CompartDiskSize $d.Size); Saude = $d.Status; Operacional = $d.Status
                Temperatura = 'n/d'; HorasLigado = 'n/d'; Desgaste = 'n/d'
                ErrosLeitura = 'n/d'; ErrosEscrita = 'n/d'; Fonte = 'WMI'
            })
        }
    }

    # SMART bruto (preditivo de falha) - disponivel na maioria dos controladores
    try {
        foreach ($s in (Get-CompartDiskCim -Class MSStorageDriver_FailurePredictStatus -Namespace 'root\wmi')) {
            # O InstanceName termina em "_<indice do disco>". O casamento anterior era
            # -like "*<id>*", que procurava o digito em QUALQUER posicao: em
            # "...&1ec0a2c0&0&000000_0" o padrao "*1*" casa dentro do identificador
            # hexadecimal, e o prognostico de um disco era gravado em outro.
            # Com um unico disco o casamento frouxo e inofensivo e continua servindo
            # de rede de seguranca caso o formato do InstanceName seja outro.
            $m = [regex]::Match("$($s.InstanceName)", '_(\d+)$')
            $alvo = $null
            if ($m.Success) { $alvo = $rows | Where-Object { "$($_.Id)" -eq $m.Groups[1].Value } | Select-Object -First 1 }
            if (-not $alvo -and $rows.Count -eq 1) { $alvo = $rows[0] }
            if ($alvo) {
                $alvo | Add-Member -NotePropertyName 'SMART_Falha' -NotePropertyValue $(if ($s.PredictFailure) { 'SIM' } else { 'Nao' }) -Force
            }
        }
    } catch { Write-Log DEBUG "SMART FailurePredict indisponivel." -NoConsole }

    return @($rows)
}

function Get-CompartDiskVolumeInfo {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($v in (Get-CompartDiskCim -Class Win32_LogicalDisk -Filter 'DriveType=3')) {
        $pct = if ($v.Size -gt 0) { [math]::Round((($v.Size - $v.FreeSpace) / $v.Size) * 100, 1) } else { 0 }
        [void]$rows.Add([pscustomobject]@{
            Volume     = $v.DeviceID
            Rotulo     = $v.VolumeName
            Sistema    = $v.FileSystem
            Tamanho    = (ConvertTo-CompartDiskSize $v.Size)
            Livre      = (ConvertTo-CompartDiskSize $v.FreeSpace)
            UsadoPct   = "$pct%"
            Serial     = $v.VolumeSerialNumber
        })
    }
    return @($rows)
}

function Get-CompartDiskNetworkInfo {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList

    # DHCP e MTU por indice de interface. Consulta ACRESCENTADA: os campos que ja
    # existiam continuam com o mesmo nome e o mesmo valor, e quem le apenas os
    # antigos nao percebe diferenca.
    $ipif = @{}
    if (Test-CompartDiskCommand 'Get-NetIPInterface') {
        try {
            foreach ($i in (Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {
                $ipif[[int]$i.InterfaceIndex] = $i
            }
        } catch { Write-Log DEBUG "Get-NetIPInterface: $($_.Exception.Message)" -NoConsole }
    }

    if (Test-CompartDiskCommand 'Get-NetIPConfiguration') {
        try {
            foreach ($c in (Get-NetIPConfiguration -Detailed -ErrorAction Stop)) {
                $idx = $(try { [int]$c.InterfaceIndex } catch { -1 })
                $i   = $(if ($ipif.ContainsKey($idx)) { $ipif[$idx] } else { $null })
                [void]$rows.Add([pscustomobject]@{
                    Interface = $c.InterfaceAlias
                    Descricao = $c.InterfaceDescription
                    Estado    = "$($c.NetAdapter.Status)"
                    MAC       = "$($c.NetAdapter.MacAddress)"
                    Velocidade= "$($c.NetAdapter.LinkSpeed)"
                    IPv4      = (($c.IPv4Address | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ')
                    IPv6      = (($c.IPv6Address | ForEach-Object { $_.IPAddress }) -join ', ')
                    Gateway   = (($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', ')
                    DNS       = (($c.DNSServer | ForEach-Object { $_.ServerAddresses }) -join ', ')
                    DHCP      = $(if ($i) { "$($i.Dhcp)" } else { 'N/A' })
                    MTU       = $(if ($i -and $i.NlMtu) { "$($i.NlMtu)" } else { 'N/A' })
                    Perfil    = "$($c.NetProfile.NetworkCategory)"
                })
            }
        } catch { Write-Log DEBUG "Get-NetIPConfiguration: $($_.Exception.Message)" -NoConsole }
    }

    if ($rows.Count -eq 0) {
        foreach ($n in (Get-CompartDiskCim -Class Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True')) {
            [void]$rows.Add([pscustomobject]@{
                Interface = $n.Description; Descricao = $n.Description; Estado = 'Ativo'
                MAC = $n.MACAddress; Velocidade = 'n/d'
                IPv4 = ($n.IPAddress -join ', '); IPv6 = ''
                Gateway = ($n.DefaultIPGateway -join ', '); DNS = ($n.DNSServerSearchOrder -join ', ')
                DHCP = $(if ($null -ne $n.DHCPEnabled) { $(if ([bool]$n.DHCPEnabled) { 'Enabled' } else { 'Disabled' }) } else { 'N/A' })
                MTU  = $(if ($n.MTU) { "$($n.MTU)" } else { 'N/A' })
                Perfil = 'n/d'
            })
        }
    }
    return @($rows)
}

function Get-CompartDiskFirewallInfo {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    if (Test-CompartDiskCommand 'Get-NetFirewallProfile') {
        # Qual perfil esta em uso agora. O Audit ja consultava 'PerfilAtivo' em
        # cada linha, mas nenhuma delas trazia o campo: sem ele, nao dava para
        # distinguir "perfil desligado" de "perfil desligado E em uso".
        $categoriasAtivas = @()
        if (Test-CompartDiskCommand 'Get-NetConnectionProfile') {
            try {
                $categoriasAtivas = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { "$($_.NetworkCategory)" })
            } catch { Write-Log DEBUG "Get-NetConnectionProfile: $($_.Exception.Message)" -NoConsole }
        }
        try {
            foreach ($p in (Get-NetFirewallProfile -ErrorAction Stop)) {
                $nome = "$($p.Name)"
                # NetworkCategory devolve Public/Private/DomainAuthenticated;
                # o perfil do firewall chama-se Public/Private/Domain.
                $ativo = $(if ($categoriasAtivas.Count -eq 0) { 'N/A' }
                           elseif ($categoriasAtivas -contains $nome -or ($nome -eq 'Domain' -and ($categoriasAtivas -match 'Domain'))) { 'Sim' }
                           else { 'Nao' })
                [void]$rows.Add([pscustomobject]@{
                    Perfil          = $nome
                    Habilitado      = $p.Enabled
                    PerfilAtivo     = $ativo
                    EntradaPadrao   = "$($p.DefaultInboundAction)"
                    SaidaPadrao     = "$($p.DefaultOutboundAction)"
                    NotificarBloqueio = $p.NotifyOnListen
                })
            }
        } catch { Write-Log DEBUG "Get-NetFirewallProfile: $($_.Exception.Message)" -NoConsole }
    }
    if ($rows.Count -eq 0) {
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\netsh.exe') -Arguments @('advfirewall', 'show', 'allprofiles', 'state') -TimeoutSeconds 30 } -Activity 'netsh firewall' -Silent
        if ($r.Success -and $r.Value.StdOut) {
            [void]$rows.Add([pscustomobject]@{ Perfil = 'netsh'; Habilitado = 'ver log'; EntradaPadrao = 'n/d'; SaidaPadrao = 'n/d'; NotificarBloqueio = 'n/d' })
            Write-Log INFO ("Firewall (netsh):`r`n" + $r.Value.StdOut) -NoConsole
        }
    }
    return @($rows)
}

function Get-CompartDiskSecurityPosture {
    [CmdletBinding()] param()
    $tpm = Test-TPM
    $sb  = Test-SecureBoot

    $dg = Get-CompartDiskCim -Class Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard'
    $vbs = 'n/d'; $cg = 'n/d'; $hvci = 'n/d'
    if ($dg) {
        $vbsMap = @{ 0 = 'Desabilitado'; 1 = 'Habilitado (nao em execucao)'; 2 = 'Em execucao' }
        $vbs = $(if ($vbsMap.ContainsKey([int]$dg.VirtualizationBasedSecurityStatus)) { $vbsMap[[int]$dg.VirtualizationBasedSecurityStatus] } else { 'n/d' })
        $running = @($dg.SecurityServicesRunning)
        $cg   = $(if ($running -contains 1) { 'Ativo' } else { 'Inativo' })
        $hvci = $(if ($running -contains 2) { 'Ativo' } else { 'Inativo' })
    }

    $uac = Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 0
    $lsa = Get-CompartDiskRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 0
    $smart = Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' $null
    if ($null -eq $smart) { $smart = Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'n/d' }
    $mi = Get-CompartDiskRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0

    $hello = 'n/d'
    try {
        $hello = $(if ((Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork' 'Enabled' $null) -eq 1) { 'Habilitado por politica' } else { 'Padrao do sistema' })
    } catch { }

    return [ordered]@{
        'Secure Boot'          = $sb.Status
        'Firmware'             = $sb.FirmwareType
        'TPM presente'         = $(if ($tpm.Present) { 'Sim' } else { 'Nao' })
        'TPM versao'           = $tpm.Version
        'TPM estado'           = $tpm.Status
        'TPM fabricante'       = $tpm.Manufacturer
        'VBS'                  = $vbs
        'Credential Guard'     = $cg
        'HVCI (Core Isolation)'= $hvci
        'Memory Integrity'     = $(if ($mi -eq 1) { 'Habilitado' } else { 'Desabilitado' })
        'LSA Protection (PPL)' = $(if ($lsa -eq 1) { 'Habilitado' } else { 'Desabilitado' })
        'UAC'                  = $(if ($uac -eq 1) { 'Habilitado' } else { 'DESABILITADO' })
        'SmartScreen'          = "$smart"
        'Windows Hello'        = $hello
    }
}

function Get-CompartDiskDefenderStatus {
    [CmdletBinding()] param()
    if (-not (Import-CompartDiskModule 'Defender')) { return $null }
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $p = $null
        try { $p = Get-MpPreference -ErrorAction Stop } catch { }
        return [ordered]@{
            'Servico ativo'         = $s.AMServiceEnabled
            'Protecao em tempo real'= $s.RealTimeProtectionEnabled
            'Protecao comportamental'= $s.BehaviorMonitorEnabled
            'Protecao na nuvem'     = $(if ($p) { $p.MAPSReporting } else { 'n/d' })
            'Modo passivo'          = $(if ($null -ne $s.AMRunningMode) { $s.AMRunningMode } else { 'n/d' })
            'Versao do motor'       = $s.AMEngineVersion
            'Versao da plataforma'  = $s.AMProductVersion
            'Assinaturas antivirus' = $s.AntivirusSignatureVersion
            'Assinaturas idade (d)' = $s.AntivirusSignatureAge
            'Assinaturas atualizadas em' = $s.AntivirusSignatureLastUpdated
            'Ultima varredura rapida'    = $s.QuickScanEndTime
            'Ultima varredura completa'  = $s.FullScanEndTime
            'Tamper Protection'     = $s.IsTamperProtected
            'Exclusoes (caminhos)'  = $(if ($p -and $p.ExclusionPath) { ($p.ExclusionPath -join '; ') } else { 'nenhuma' })
            'Exclusoes (processos)' = $(if ($p -and $p.ExclusionProcess) { ($p.ExclusionProcess -join '; ') } else { 'nenhuma' })
        }
    } catch {
        Write-Log DEBUG "Get-MpComputerStatus: $($_.Exception.Message)" -NoConsole
        return $null
    }
}

function Get-CompartDiskAntivirusProducts {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($av in (Get-CompartDiskCim -Class AntiVirusProduct -Namespace 'root\SecurityCenter2')) {
        $state = [int]$av.productState
        $ativo = (($state -band 0x1000) -ne 0)
        $atual = (($state -band 0x10) -eq 0)
        [void]$rows.Add([pscustomobject]@{
            Produto     = $av.displayName
            Ativo       = $(if ($ativo) { 'Sim' } else { 'Nao' })
            Atualizado  = $(if ($atual) { 'Sim' } else { 'Nao' })
            Executavel  = $av.pathToSignedProductExe
        })
    }
    return @($rows)
}

function Get-CompartDiskWindowsUpdateInfo {
    [CmdletBinding()] param()
    $info = [ordered]@{}
    $svcNames = 'wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc', 'DoSvc', 'TrustedInstaller'
    foreach ($n in $svcNames) {
        try {
            $s = Get-Service -Name $n -ErrorAction Stop
            $info["Servico $n"] = "$($s.Status) / $($s.StartType)"
        } catch { $info["Servico $n"] = 'ausente' }
    }

    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $info['Ultima busca']    = $au.Results.LastSearchSuccessDate
        $info['Ultima instalacao'] = $au.Results.LastInstallationSuccessDate
    } catch { $info['Agente Windows Update'] = 'COM indisponivel' }

    foreach ($p in @('SoftwareDistribution', 'SoftwareDistribution\Download', 'SoftwareDistribution\DataStore')) {
        $full = Join-Path $env:SystemRoot $p
        $sz = Get-CompartDiskFolderSize -Path $full
        $info["Cache $p"] = $(if ($sz.Exists) { "$(ConvertTo-CompartDiskSize $sz.Bytes) ($($sz.Files) arquivos)" } else { 'inexistente' })
    }

    $info['Reinicio pendente'] = $(if (Test-CompartDiskPendingReboot) { 'SIM' } else { 'Nao' })
    return $info
}

function Get-CompartDiskUpdateHistory {
    [CmdletBinding()] param([int]$Max = 40)
    $rows = New-Object System.Collections.ArrayList
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count    = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $take = [math]::Min($count, $Max)
            $mapa = @{ 0 = 'NaoIniciado'; 1 = 'EmProgresso'; 2 = 'Sucesso'; 3 = 'SucessoComErros'; 4 = 'Falha'; 5 = 'Cancelado' }
            foreach ($h in $searcher.QueryHistory(0, $take)) {
                [void]$rows.Add([pscustomobject]@{
                    Data      = $h.Date
                    Titulo    = $h.Title
                    Resultado = $(if ($mapa.ContainsKey([int]$h.ResultCode)) { $mapa[[int]$h.ResultCode] } else { $h.ResultCode })
                    Codigo    = ('0x{0:X8}' -f $h.HResult)
                    Operacao  = $(if ($h.Operation -eq 1) { 'Instalacao' } else { 'Desinstalacao' })
                })
            }
        }
    } catch {
        Write-Log DEBUG "Historico WU indisponivel: $($_.Exception.Message)" -NoConsole
    }

    if ($rows.Count -eq 0) {
        foreach ($q in (Get-CompartDiskCim -Class Win32_QuickFixEngineering)) {
            [void]$rows.Add([pscustomobject]@{
                Data = $q.InstalledOn; Titulo = $q.HotFixID; Resultado = 'Instalado'
                Codigo = 'n/d'; Operacao = $q.Description
            })
        }
    }
    return @($rows)
}

function Test-CompartDiskPendingReboot {
    [CmdletBinding()] param()
    $chaves = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    )
    foreach ($c in $chaves) { if (Test-Path -LiteralPath $c) { return $true } }
    try {
        $v = Get-CompartDiskRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations' $null
        if ($v) { return $true }
    } catch { }
    return $false
}

function Get-CompartDiskDriverInfo {
    [CmdletBinding()] param([switch]$OnlyProblems)

    # -OnlyProblems nao usa o inventario de drivers: o resultado do laco abaixo era
    # inteiramente descartado. Como Win32_PnPSignedDriver e uma das classes mais
    # lentas do repositorio (enumeracao completa de todos os drivers assinados),
    # cada consulta de "dispositivos com problema" pagava esse custo por nada -
    # em Hardware.ps1, em Drivers.ps1 e em Audit.ps1. A saida e identica.
    if ($OnlyProblems) {
        $problem = New-Object System.Collections.ArrayList
        foreach ($p in (Get-CompartDiskCim -Class Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0')) {
            [void]$problem.Add([pscustomobject]@{
                Dispositivo = $p.Name
                Fabricante  = $p.Manufacturer
                CodigoErro  = $p.ConfigManagerErrorCode
                Descricao   = (Get-CompartDiskDeviceErrorText $p.ConfigManagerErrorCode)
                Status      = $p.Status
                DeviceID    = $p.DeviceID
            })
        }
        return @($problem)
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($d in (Get-CompartDiskCim -Class Win32_PnPSignedDriver)) {
        if ([string]::IsNullOrWhiteSpace($d.DeviceName)) { continue }
        [void]$rows.Add([pscustomobject]@{
            Dispositivo = $d.DeviceName
            Fabricante  = $d.Manufacturer
            Versao      = $d.DriverVersion
            Data        = $(if ($d.DriverDate) { (Get-Date $d.DriverDate -Format 'yyyy-MM-dd') } else { 'n/d' })
            Assinado    = $(if ($d.IsSigned) { 'Sim' } else { 'NAO' })
            Provedor    = $d.DriverProviderName
            InfName     = $d.InfName
        })
    }
    return @($rows)
}

function Get-CompartDiskDeviceErrorSeverity {
    <# Severidade de um ConfigManagerErrorCode.

       Nem todo codigo diferente de zero e falha: 22 (desabilitado pelo operador) e
       45 (nao conectado) sao estados NORMAIS, e 21 (removendo) e transitorio.
       Trata-los como critico produz alarme falso em praticamente qualquer maquina
       que tenha um dispositivo desativado de proposito.

       A tabela espelha $script:CodigoSeveridade de Drivers.ps1, dono da auditoria de
       drivers, para que os dois modulos nao publiquem severidades diferentes para o
       mesmo dispositivo. Consolidar as duas numa unica fonte e trabalho para o
       proprio Drivers.ps1 e nao foi feito aqui. #>
    param([AllowNull()][object]$Code)
    $m = @{
        1  = 'CRIT'; 3  = 'CRIT'; 10 = 'CRIT'; 12 = 'CRIT'; 19 = 'CRIT'; 31 = 'CRIT'; 39 = 'CRIT'; 41 = 'CRIT'
        43 = 'CRIT'
        14 = 'WARN'; 18 = 'WARN'; 24 = 'WARN'; 28 = 'WARN'; 32 = 'WARN'; 35 = 'WARN'; 37 = 'WARN'; 38 = 'WARN'
        40 = 'WARN'; 42 = 'WARN'; 44 = 'WARN'; 47 = 'WARN'; 48 = 'WARN'; 49 = 'WARN'; 52 = 'WARN'
        21 = 'INFO'; 22 = 'INFO'; 45 = 'INFO'; 46 = 'INFO'
    }
    $n = -1
    try { $n = [int]$Code } catch { $n = -1 }
    if ($n -lt 0) { return 'WARN' }
    if ($m.ContainsKey($n)) { return $m[$n] }
    return 'WARN'
}

function Get-CompartDiskDeviceErrorText {
    param([int]$Code)
    $m = @{
        1 = 'Dispositivo nao configurado corretamente'
        3 = 'Driver corrompido ou memoria insuficiente'
        10 = 'Dispositivo nao pode iniciar'
        12 = 'Recursos livres insuficientes'
        14 = 'Requer reinicializacao'
        18 = 'Reinstalacao de driver necessaria'
        19 = 'Registro corrompido'
        21 = 'Removendo dispositivo'
        22 = 'Dispositivo desabilitado'
        24 = 'Dispositivo ausente ou com falha'
        28 = 'Drivers nao instalados'
        31 = 'Windows nao pode carregar os drivers'
        43 = 'Dispositivo interrompido por reportar problemas'
        45 = 'Dispositivo nao conectado'
    }
    if ($m.ContainsKey($Code)) { return $m[$Code] }
    return "Codigo $Code"
}

function Get-CompartDiskServiceDiagnostics {
    [CmdletBinding()] param()
    $essenciais = @(
        'wuauserv', 'BITS', 'CryptSvc', 'Winmgmt', 'EventLog', 'Dhcp', 'Dnscache',
        'LanmanWorkstation', 'RpcSs', 'Schedule', 'WinDefend', 'wscsvc', 'Spooler',
        'nsi', 'PlugPlay', 'Power', 'Themes', 'AudioSrv'
    )
    $rows = New-Object System.Collections.ArrayList
    foreach ($n in $essenciais) {
        try {
            $s = Get-Service -Name $n -ErrorAction Stop
            $wmi = Get-CompartDiskCim -Class Win32_Service -Filter "Name='$n'"
            $status = 'OK'
            if ($s.Status -ne 'Running' -and $wmi -and $wmi.StartMode -eq 'Auto') { $status = 'ATENCAO' }
            if ($wmi -and $wmi.StartMode -eq 'Disabled') { $status = 'DESABILITADO' }
            [void]$rows.Add([pscustomobject]@{
                Servico    = $n
                Nome       = $s.DisplayName
                Estado     = "$($s.Status)"
                Inicio     = $(if ($wmi) { $wmi.StartMode } else { 'n/d' })
                Conta      = $(if ($wmi) { $wmi.StartName } else { 'n/d' })
                Diagnostico= $status
            })
        } catch {
            [void]$rows.Add([pscustomobject]@{
                Servico = $n; Nome = 'n/d'; Estado = 'AUSENTE'; Inicio = 'n/d'; Conta = 'n/d'; Diagnostico = 'ATENCAO'
            })
        }
    }
    return @($rows)
}

function Get-CompartDiskProcessDiagnostics {
    [CmdletBinding()] param([int]$Top = 12)
    $rows = New-Object System.Collections.ArrayList
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -gt 4 }
        $porRam = $procs | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First $Top
        foreach ($p in $porRam) {
            $cpu = 'n/d'
            try { $cpu = [math]::Round($p.CPU, 1) } catch { }
            [void]$rows.Add([pscustomobject]@{
                PID        = $p.Id
                Processo   = $p.ProcessName
                Memoria    = (ConvertTo-CompartDiskSize $p.WorkingSet64)
                CPU_seg    = $cpu
                Threads    = $p.Threads.Count
                Handles    = $p.HandleCount
                Respondendo= $(if ($p.MainWindowHandle -ne 0) { $p.Responding } else { 'n/a' })
                Inicio     = $(try { $p.StartTime.ToString('HH:mm:ss') } catch { 'n/d' })
            })
        }
    } catch { Write-Log DEBUG "Get-Process: $($_.Exception.Message)" -NoConsole }
    return @($rows)
}

function Get-CompartDiskStartupItems {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in (Get-CompartDiskCim -Class Win32_StartupCommand)) {
        [void]$rows.Add([pscustomobject]@{
            Nome     = $s.Name
            Comando  = $s.Command
            Local    = $s.Location
            Usuario  = $s.User
        })
    }
    return @($rows)
}

function Get-CompartDiskEventSummary {
    [CmdletBinding()]
    param(
        [int]$Days = 7,
        [string[]]$LogName = @('System', 'Application'),
        [int]$MaxPerLog = 60
    )
    $rows = New-Object System.Collections.ArrayList
    $inicio = (Get-Date).AddDays(-$Days)
    foreach ($log in $LogName) {
        try {
            $filtro = @{ LogName = $log; StartTime = $inicio; Level = 1, 2, 3 }
            $ev = Get-WinEvent -FilterHashtable $filtro -MaxEvents $MaxPerLog -ErrorAction Stop
            # O corte de -MaxEvents e aplicado ANTES do agrupamento e devolve apenas os
            # mais RECENTES: ao ser atingido, as contagens viram um piso e eventos mais
            # antigos da janela nem aparecem. Isso precisa ficar dito.
            if (@($ev).Count -ge $MaxPerLog) {
                Write-Log WARN ("Log '{0}': limite de {1} eventos atingido. As contagens sao um piso e eventos mais antigos da janela de {2} dia(s) podem nao aparecer." -f $log, $MaxPerLog, $Days)
            }
            $grupos = $ev | Group-Object -Property Id, ProviderName | Sort-Object Count -Descending
            foreach ($g in $grupos) {
                $primeiro = $g.Group[0]
                $nivel = switch ([int]$primeiro.Level) { 1 { 'Critico' } 2 { 'Erro' } 3 { 'Aviso' } default { 'Info' } }
                $msg = "$($primeiro.Message)"
                if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
                [void]$rows.Add([pscustomobject]@{
                    Log        = $log
                    Nivel      = $nivel
                    EventoID   = $primeiro.Id
                    Origem     = $primeiro.ProviderName
                    Ocorrencias= $g.Count
                    UltimaVez  = $primeiro.TimeCreated
                    Mensagem   = ($msg -replace '\s+', ' ')
                })
            }
        } catch {
            Write-Log DEBUG "Eventos '$log' indisponiveis: $($_.Exception.Message)" -NoConsole
        }
    }
    # Ordenar por 'Nivel' como cadeia da a ordem alfabetica Aviso < Critico < Erro:
    # os avisos vinham primeiro e os criticos caiam abaixo do corte de 15 linhas que
    # Audit.ps1 exibe. O peso explicito ordena por gravidade real.
    $peso = @{ 'Critico' = 0; 'Erro' = 1; 'Aviso' = 2; 'Info' = 3 }
    return @($rows | Sort-Object `
        -Property @{ Expression = { if ($peso.ContainsKey("$($_.Nivel)")) { $peso["$($_.Nivel)"] } else { 9 } } }, `
                  @{ Expression = 'Ocorrencias'; Descending = $true })
}

function Get-CompartDiskLocalUsers {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    if (Test-CompartDiskCommand 'Get-LocalUser') {
        try {
            $admins = @()
            try { $admins = (Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { ($_.Name -split '\\')[-1] }) } catch { }
            foreach ($u in (Get-LocalUser -ErrorAction Stop)) {
                [void]$rows.Add([pscustomobject]@{
                    Usuario       = $u.Name
                    Habilitado    = $u.Enabled
                    Administrador = $(if ($admins -contains $u.Name) { 'Sim' } else { 'Nao' })
                    SenhaExpira   = $(if ($u.PasswordExpires) { $u.PasswordExpires } else { 'Nunca' })
                    UltimoLogon   = $(if ($u.LastLogon) { $u.LastLogon } else { 'nunca' })
                    SenhaRequerida= $u.PasswordRequired
                    Descricao     = $u.Description
                })
            }
            return @($rows)
        } catch { Write-Log DEBUG "Get-LocalUser: $($_.Exception.Message)" -NoConsole }
    }
    foreach ($u in (Get-CompartDiskCim -Class Win32_UserAccount -Filter 'LocalAccount=True')) {
        [void]$rows.Add([pscustomobject]@{
            Usuario = $u.Name; Habilitado = (-not $u.Disabled); Administrador = 'n/d'
            # Win32_UserAccount.PasswordExpires e Boolean ($true = a senha expira),
            # enquanto Get-LocalUser devolve a DATA de expiracao. O "-not" invertia o
            # sentido: a coluna dizia False justamente quando a senha expirava.
            SenhaExpira = $(if ($u.PasswordExpires) { 'Sim' } else { 'Nunca' })
            UltimoLogon = 'n/d'
            SenhaRequerida = $u.PasswordRequired; Descricao = $u.Description
        })
    }
    return @($rows)
}

function Get-CompartDiskLicenseInfo {
    [CmdletBinding()] param()
    $info = [ordered]@{}
    try {
        $sls = Get-CompartDiskCim -Query "SELECT * FROM SoftwareLicensingProduct WHERE PartialProductKey IS NOT NULL AND ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f'"
        $estados = @{ 0 = 'Nao licenciado'; 1 = 'Licenciado'; 2 = 'Periodo de tolerancia OOB'; 3 = 'Periodo de tolerancia OOT'; 4 = 'Tolerancia sem genuinidade'; 5 = 'Notificacao'; 6 = 'Tolerancia estendida' }
        foreach ($p in $sls) {
            $info['Produto']    = $p.Name
            $info['Descricao']  = $p.Description
            $info['Canal']      = $p.ProductKeyChannel
            $info['Chave (5)']  = $p.PartialProductKey
            $info['Estado']     = $(if ($estados.ContainsKey([int]$p.LicenseStatus)) { $estados[[int]$p.LicenseStatus] } else { $p.LicenseStatus })
            break
        }
    } catch { }
    try {
        $oa3 = (Get-CompartDiskCim -Query 'SELECT * FROM SoftwareLicensingService').OA3xOriginalProductKey
        if ($oa3) { $info['Chave OEM (firmware)'] = $oa3 }
    } catch { }
    if ($info.Count -eq 0) { $info['Licenciamento'] = 'Nao foi possivel consultar (SLS indisponivel)' }
    return $info
}

function Get-CompartDiskPowerInfo {
    [CmdletBinding()] param()
    $info = [ordered]@{}
    try {
        $plano = Get-CompartDiskCim -Class Win32_PowerPlan -Namespace 'root\cimv2\power' -Filter 'IsActive=True'
        if ($plano) { $info['Plano de energia ativo'] = $plano.ElementName }
    } catch { }
    if (-not $info['Plano de energia ativo']) {
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\powercfg.exe') -Arguments @('/getactivescheme') -TimeoutSeconds 20 } -Activity 'powercfg' -Silent
        if ($r.Success) { $info['Plano de energia ativo'] = ($r.Value.StdOut -replace '\r?\n', ' ').Trim() }
    }
    try {
        $b = Get-CompartDiskCim -Class Win32_Battery
        if ($b) {
            $info['Bateria']        = $b.Name
            $info['Carga atual']    = "$($b.EstimatedChargeRemaining)%"
            $info['Status bateria'] = $b.BatteryStatus
        } else { $info['Bateria'] = 'Nenhuma (desktop ou sem bateria)' }
    } catch { }
    try {
        $fast = Get-CompartDiskRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' $null
        if ($null -ne $fast) { $info['Inicializacao rapida'] = $(if ($fast -eq 1) { 'Habilitada' } else { 'Desabilitada' }) }
    } catch { }
    return $info
}

function Get-CompartDiskInstalledSoftware {
    [CmdletBinding()] param([int]$Max = 0)
    $rows = New-Object System.Collections.ArrayList
    $chaves = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $chaves) {
        try {
            foreach ($p in (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
                if ([string]::IsNullOrWhiteSpace($p.DisplayName)) { continue }
                if ($p.SystemComponent -eq 1) { continue }
                [void]$rows.Add([pscustomobject]@{
                    Aplicativo = $p.DisplayName
                    Versao     = $p.DisplayVersion
                    Fabricante = $p.Publisher
                    Instalado  = $p.InstallDate
                })
            }
        } catch { }
    }
    $out = $rows | Sort-Object Aplicativo -Unique
    if ($Max -gt 0) { $out = $out | Select-Object -First $Max }
    return @($out)
}

function Get-CompartDiskShadowCopies {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in (Get-CompartDiskCim -Class Win32_ShadowCopy)) {
        [void]$rows.Add([pscustomobject]@{
            Id       = $s.ID
            Volume   = $s.VolumeName
            Criado   = $s.InstallDate
            Origem   = $s.OriginatingMachine
        })
    }
    return @($rows)
}

function Get-CompartDiskPrinters {
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($p in (Get-CompartDiskCim -Class Win32_Printer)) {
        [void]$rows.Add([pscustomobject]@{
            Impressora = $p.Name
            Porta      = $p.PortName
            Driver     = $p.DriverName
            Padrao     = $p.Default
            Status     = $p.PrinterStatus
            Trabalhos  = $p.JobCountSinceLastReset
        })
    }
    return @($rows)
}

# ==============================================================================
# INTEGRIDADE DE EXECUTAVEL, PROCESSOS, REDE E COMPARTILHAMENTOS
#
# Tudo aqui e SOMENTE LEITURA, como o restante deste arquivo: nenhuma consulta
# altera estado, abre porta, muda regra de firewall ou encerra processo.
#
# Um dado que o Windows nao expoe - executavel protegido, arquivo removido,
# processo encerrado durante a coleta, cmdlet ausente na edicao - vira 'N/A',
# 'Acesso negado' ou 'Indisponivel'. Nunca um valor inventado, e nunca uma
# excecao que interrompa o restante do relatorio.
# ==============================================================================

function Get-CompartDiskFileTrust {
    <# SHA-256 real e estado da assinatura de UM arquivo.

       O resultado e cacheado por caminho durante a sessao: dezenas de processos
       compartilham o mesmo executavel (svchost.exe, conhost.exe), e sem cache o
       mesmo arquivo seria lido e o mesmo certificado validado dezenas de vezes.
       Como a chave e o caminho e o hash vem do arquivo real, o cache nao muda
       nenhum valor - so evita repetir o trabalho. #>
    [CmdletBinding()] param([AllowNull()][string]$Path, [switch]$SemHash)

    $vazio = [pscustomobject]@{
        SHA256 = 'N/A'; Assinatura = 'N/A'; Editor = 'N/A'; Detalhe = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $vazio }

    if (-not $Global:CompartDisk.ContainsKey('FileTrust') -or $null -eq $Global:CompartDisk.FileTrust) {
        $Global:CompartDisk.FileTrust = @{}
    }
    $chave = ('{0}|{1}' -f $Path.ToLowerInvariant(), [int][bool]$SemHash)
    if ($Global:CompartDisk.FileTrust.ContainsKey($chave)) { return $Global:CompartDisk.FileTrust[$chave] }

    $out = [pscustomobject]@{
        SHA256 = 'N/A'; Assinatura = 'Nao foi possivel verificar'; Editor = 'N/A'; Detalhe = ''
    }

    $existe = $false
    try { $existe = Test-Path -LiteralPath $Path -PathType Leaf } catch { }
    if (-not $existe) {
        $out.Assinatura = 'N/A'
        $out.Detalhe    = 'Arquivo nao encontrado'
        $Global:CompartDisk.FileTrust[$chave] = $out
        return $out
    }

    # --- SHA-256 do arquivo real -------------------------------------------
    if (-not $SemHash) {
        try {
            $out.SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        } catch {
            $msg = $_.Exception.Message
            $out.SHA256  = $(if ($msg -match 'denied|negad') { 'Acesso negado' } else { 'Indisponivel' })
            $out.Detalhe = (Get-CompartDiskTrechoErro $msg)
        }
    }

    # --- assinatura digital -------------------------------------------------
    if (-not (Test-CompartDiskCommand 'Get-AuthenticodeSignature')) {
        $out.Assinatura = 'Nao foi possivel verificar'
        $out.Detalhe    = 'Get-AuthenticodeSignature indisponivel neste motor'
        $Global:CompartDisk.FileTrust[$chave] = $out
        return $out
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $st  = "$($sig.Status)"
        $temCert = ($null -ne $sig.SignerCertificate)
        switch ($st) {
            'Valid'                  { $out.Assinatura = 'Assinado e valido' }
            'NotSigned'              { $out.Assinatura = 'Nao assinado' }
            'NotSupportedFileFormat' { $out.Assinatura = 'Nao assinado'; $out.Detalhe = 'Formato sem suporte a assinatura' }
            default {
                # HashMismatch, NotTrusted, UnknownError e afins: ha assinatura,
                # mas ela nao valida. Distinguir isto de "nao assinado" e o
                # ponto do requisito.
                if ($temCert) { $out.Assinatura = 'Assinado, invalido' }
                else          { $out.Assinatura = 'Nao foi possivel verificar' }
                if (-not $out.Detalhe) { $out.Detalhe = $st }
            }
        }
        if ($temCert) {
            $nome = ''
            try { $nome = "$($sig.SignerCertificate.Subject)" } catch { }
            # Do DN completo interessa so o CN: o resto alongaria a tabela sem
            # acrescentar nada ao diagnostico.
            $m = [regex]::Match($nome, 'CN=(?:")?([^",]+)')
            $out.Editor = $(if ($m.Success) { $m.Groups[1].Value.Trim() } elseif ($nome) { $nome } else { 'N/A' })
        } else {
            $out.Editor = 'N/A'
        }
    } catch {
        $msg = $_.Exception.Message
        $out.Assinatura = $(if ($msg -match 'denied|negad') { 'Acesso negado' } else { 'Nao foi possivel verificar' })
        if (-not $out.Detalhe) { $out.Detalhe = (Get-CompartDiskTrechoErro $msg) }
    }

    $Global:CompartDisk.FileTrust[$chave] = $out
    return $out
}

function Get-CompartDiskTrechoErro {
    <# Primeira linha da mensagem, curta: a tabela nao pode virar um log. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto, [int]$Max = 90)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }
    $t = ($Texto -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    $t = "$t".Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 1) + [char]0x2026 }
    return $t
}

function Get-CompartDiskProcessInventory {
    <# Inventario completo de processos com integridade do executavel.

       PPID, threads, handles e caminho vem de UMA consulta Win32_Process. O
       usuario vem de UMA chamada a Get-Process -IncludeUserName: consultar o
       dono processo a processo (GetOwner) custaria centenas de chamadas WMI.
       Sem privilegio administrativo esse cmdlet recusa, e o campo fica
       'Acesso negado' em vez de vazio. #>
    [CmdletBinding()] param([switch]$SemHash, [int]$MaxArquivos = 400)

    $rows = New-Object System.Collections.ArrayList
    $procs = @(Get-CompartDiskCim -Class Win32_Process)
    if ($procs.Count -eq 0) {
        Write-Log DEBUG 'Win32_Process nao retornou processos.' -NoConsole
        return @($rows)
    }

    # --- dono do processo, em uma unica passagem ----------------------------
    $donos = @{}
    $donoIndisponivel = 'N/A'
    try {
        foreach ($p in (Get-Process -IncludeUserName -ErrorAction Stop)) {
            if ($null -ne $p.UserName) { $donos[[int]$p.Id] = "$($p.UserName)" }
        }
    } catch {
        $donoIndisponivel = $(if (Test-Administrator) { 'Indisponivel' } else { 'Acesso negado' })
        Write-Log DEBUG ("Get-Process -IncludeUserName: {0}" -f $_.Exception.Message) -NoConsole
    }

    # --- servicos hospedados, por PID ---------------------------------------
    $servicosPorPid = @{}
    foreach ($s in (Get-CompartDiskCim -Class Win32_Service -Filter 'ProcessId > 0')) {
        $sp = [int]$s.ProcessId
        if (-not $servicosPorPid.ContainsKey($sp)) { $servicosPorPid[$sp] = New-Object System.Collections.ArrayList }
        [void]$servicosPorPid[$sp].Add("$($s.Name)")
    }

    # Limite de arquivos distintos analisados: protege contra uma maquina com
    # centenas de executaveis diferentes. O que passar do limite e declarado,
    # nao silenciado.
    $vistos = @{}
    $analisados = 0

    foreach ($p in $procs) {
        $caminho = "$($p.ExecutablePath)"
        $trust = $null

        if ([string]::IsNullOrWhiteSpace($caminho)) {
            # Idle (0), System (4) e processos protegidos nao expoem caminho.
            $trust = [pscustomobject]@{ SHA256 = 'N/A'; Assinatura = 'N/A'; Editor = 'N/A'; Detalhe = 'Executavel nao exposto pelo Windows' }
        } else {
            $chave = $caminho.ToLowerInvariant()
            if (-not $vistos.ContainsKey($chave)) {
                if ($analisados -ge $MaxArquivos) {
                    $vistos[$chave] = [pscustomobject]@{ SHA256 = 'Nao calculado'; Assinatura = 'Nao verificado'; Editor = 'N/A'; Detalhe = ("Limite de {0} arquivos distintos atingido" -f $MaxArquivos) }
                } else {
                    $vistos[$chave] = Get-CompartDiskFileTrust -Path $caminho -SemHash:$SemHash
                    $analisados++
                }
            }
            $trust = $vistos[$chave]
        }

        $mem = 'N/A'
        try { $mem = ConvertTo-CompartDiskSize ([int64]$p.WorkingSetSize) } catch { }

        $inicio = 'N/A'
        try { if ($p.CreationDate) { $inicio = ([datetime]$p.CreationDate).ToString('dd/MM HH:mm') } } catch { }

        $pid_ = [int]$p.ProcessId
        [void]$rows.Add([pscustomobject]@{
            Processo   = "$($p.Name)"
            PID        = $pid_
            PPID       = $(try { [int]$p.ParentProcessId } catch { 'N/A' })
            Usuario    = $(if ($donos.ContainsKey($pid_)) { $donos[$pid_] } else { $donoIndisponivel })
            Memoria    = $mem
            Threads    = $(try { [int]$p.ThreadCount } catch { 'N/A' })
            Handles    = $(try { [int]$p.HandleCount } catch { 'N/A' })
            Servicos   = $(if ($servicosPorPid.ContainsKey($pid_)) { ($servicosPorPid[$pid_] -join ', ') } else { '' })
            Assinatura = $trust.Assinatura
            Editor     = $trust.Editor
            SHA256     = $trust.SHA256
            Caminho    = $(if ($caminho) { $caminho } else { 'N/A' })
            Inicio     = $inicio
        })
    }

    return @($rows | Sort-Object -Property Processo, PID)
}

function Get-CompartDiskNetworkConnections {
    <# Conexoes TCP e escutas UDP, associadas ao processo dono.

       Prefere Get-NetTCPConnection/Get-NetUDPEndpoint. Onde os cmdlets nao
       existem, cai para 'netstat -ano', que devolve o mesmo conjunto essencial
       (protocolo, enderecos, estado e PID) em qualquer Windows suportado. #>
    [CmdletBinding()] param([hashtable]$NomePorPid)

    $rows = New-Object System.Collections.ArrayList
    if (-not $NomePorPid) {
        $NomePorPid = @{}
        foreach ($p in (Get-CompartDiskCim -Class Win32_Process)) {
            $NomePorPid[[int]$p.ProcessId] = "$($p.Name)"
        }
    }

    # Servicos por PID, para nomear quem escuta dentro de um svchost.
    $servicosPorPid = @{}
    foreach ($s in (Get-CompartDiskCim -Class Win32_Service -Filter 'ProcessId > 0')) {
        $sp = [int]$s.ProcessId
        if (-not $servicosPorPid.ContainsKey($sp)) { $servicosPorPid[$sp] = New-Object System.Collections.ArrayList }
        [void]$servicosPorPid[$sp].Add("$($s.Name)")
    }

    # IP local -> interface, para o campo 'Interface quando disponivel'.
    $ifPorIp = @{}
    if (Test-CompartDiskCommand 'Get-NetIPAddress') {
        try {
            foreach ($a in (Get-NetIPAddress -ErrorAction Stop)) {
                $ifPorIp["$($a.IPAddress)"] = "$($a.InterfaceAlias)"
            }
        } catch { Write-Log DEBUG "Get-NetIPAddress: $($_.Exception.Message)" -NoConsole }
    }

    function Add-Conexao {
        param([string]$Proto, [string]$LocalIp, $LocalPorta, [string]$RemotoIp, $RemotoPorta, [string]$Estado, $ProcId)
        $pidNum = -1
        try { $pidNum = [int]$ProcId } catch { }
        $nome = $(if ($pidNum -ge 0 -and $NomePorPid.ContainsKey($pidNum)) { $NomePorPid[$pidNum] } else { 'N/A' })
        $svc  = $(if ($pidNum -ge 0 -and $servicosPorPid.ContainsKey($pidNum)) { ($servicosPorPid[$pidNum] -join ', ') } else { '' })
        $iface = $(if ($ifPorIp.ContainsKey($LocalIp)) { $ifPorIp[$LocalIp] } else { 'N/A' })
        [void]$rows.Add([pscustomobject]@{
            Protocolo     = $Proto
            EnderecoLocal = $(if ($LocalIp) { $LocalIp } else { 'N/A' })
            PortaLocal    = $LocalPorta
            EnderecoRemoto= $(if ($RemotoIp) { $RemotoIp } else { 'N/A' })
            PortaRemota   = $RemotoPorta
            Estado        = $Estado
            Processo      = $nome
            PID           = $(if ($pidNum -ge 0) { $pidNum } else { 'N/A' })
            Servico       = $svc
            Interface     = $iface
        })
    }

    $viaCmdlet = $false
    if (Test-CompartDiskCommand 'Get-NetTCPConnection') {
        try {
            foreach ($c in (Get-NetTCPConnection -ErrorAction Stop)) {
                $est = "$($c.State)"
                if ($est -eq 'Listen') { $est = 'LISTEN' } elseif ($est -eq 'Established') { $est = 'ESTABLISHED' } else { $est = $est.ToUpperInvariant() }
                Add-Conexao -Proto 'TCP' -LocalIp "$($c.LocalAddress)" -LocalPorta $c.LocalPort `
                            -RemotoIp "$($c.RemoteAddress)" -RemotoPorta $c.RemotePort -Estado $est -ProcId $c.OwningProcess
            }
            $viaCmdlet = $true
        } catch { Write-Log DEBUG "Get-NetTCPConnection: $($_.Exception.Message)" -NoConsole }
    }
    if ($viaCmdlet -and (Test-CompartDiskCommand 'Get-NetUDPEndpoint')) {
        try {
            foreach ($u in (Get-NetUDPEndpoint -ErrorAction Stop)) {
                # UDP nao tem conexao nem estado: e sempre um ponto de escuta.
                Add-Conexao -Proto 'UDP' -LocalIp "$($u.LocalAddress)" -LocalPorta $u.LocalPort `
                            -RemotoIp '' -RemotoPorta 'N/A' -Estado 'LISTEN' -ProcId $u.OwningProcess
            }
        } catch { Write-Log DEBUG "Get-NetUDPEndpoint: $($_.Exception.Message)" -NoConsole }
    }

    if (-not $viaCmdlet) {
        $netstat = Join-Path $env:SystemRoot 'System32\netstat.exe'
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netstat -Arguments @('-ano') -TimeoutSeconds 60 } -Activity 'netstat -ano' -Silent
        if ($r.Success -and $r.Value -and $r.Value.StdOut) {
            foreach ($linha in ($r.Value.StdOut -split "`r?`n")) {
                $t = $linha.Trim()
                if ($t -notmatch '^(TCP|UDP)\s') { continue }
                $c = @($t -split '\s+')
                if ($c.Count -lt 4) { continue }
                $proto = $c[0]
                $lp = Split-CompartDiskEndereco $c[1]
                $rp = Split-CompartDiskEndereco $c[2]
                if ($proto -eq 'TCP' -and $c.Count -ge 5) {
                    Add-Conexao -Proto 'TCP' -LocalIp $lp.Ip -LocalPorta $lp.Porta -RemotoIp $rp.Ip -RemotoPorta $rp.Porta `
                                -Estado ($c[3].ToUpperInvariant()) -ProcId $c[4]
                } elseif ($proto -eq 'UDP') {
                    Add-Conexao -Proto 'UDP' -LocalIp $lp.Ip -LocalPorta $lp.Porta -RemotoIp '' -RemotoPorta 'N/A' `
                                -Estado 'LISTEN' -ProcId $c[3]
                }
            }
        } else {
            Write-Log DEBUG 'netstat indisponivel: conexoes de rede nao coletadas.' -NoConsole
        }
    }

    return @($rows | Sort-Object -Property Protocolo, @{ Expression = { [int]('0' + "$($_.PortaLocal)") } })
}

function Split-CompartDiskEndereco {
    <# Separa "1.2.3.4:445" e "[::1]:445" em IP e porta. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return [pscustomobject]@{ Ip = 'N/A'; Porta = 'N/A' } }
    $t = $Texto.Trim()
    $i = $t.LastIndexOf(':')
    if ($i -lt 0) { return [pscustomobject]@{ Ip = $t; Porta = 'N/A' } }
    $ip = $t.Substring(0, $i).Trim('[', ']')
    $po = $t.Substring($i + 1)
    return [pscustomobject]@{ Ip = $(if ($ip) { $ip } else { 'N/A' }); Porta = $(if ($po) { $po } else { 'N/A' }) }
}

function Get-CompartDiskListeningPorts {
    <# Portas em escuta, derivadas das conexoes ja coletadas: uma unica origem
       de verdade, sem repetir a consulta ao sistema. #>
    [CmdletBinding()] param([object[]]$Conexoes)
    if (-not $Conexoes) { $Conexoes = Get-CompartDiskNetworkConnections }
    $rows = New-Object System.Collections.ArrayList
    foreach ($c in @($Conexoes | Where-Object { $_.Estado -eq 'LISTEN' })) {
        [void]$rows.Add([pscustomobject]@{
            Porta            = $c.PortaLocal
            Protocolo        = $c.Protocolo
            Processo         = $c.Processo
            PID              = $c.PID
            Servico          = $(if ($c.Servico) { $c.Servico } else { 'N/A' })
            EnderecoDeEscuta = $c.EnderecoLocal
            Interface        = $c.Interface
        })
    }
    return @($rows | Sort-Object -Property @{ Expression = { [int]('0' + "$($_.Porta)") } }, Protocolo)
}

function Get-CompartDiskShares {
    <# Compartilhamentos publicados pela maquina. Somente leitura: nenhum
       compartilhamento e criado, alterado ou removido. #>
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in (Get-CompartDiskCim -Class Win32_Share)) {
        $tipo = switch ([int64]$s.Type) {
            0          { 'Disco' }
            1          { 'Impressora' }
            2          { 'Dispositivo' }
            3          { 'IPC' }
            2147483648 { 'Disco administrativo' }
            2147483649 { 'Impressora administrativa' }
            2147483650 { 'Dispositivo administrativo' }
            2147483651 { 'IPC administrativo' }
            default    { "Tipo $($s.Type)" }
        }
        [void]$rows.Add([pscustomobject]@{
            Nome        = "$($s.Name)"
            Caminho     = $(if ($s.Path) { "$($s.Path)" } else { 'N/A' })
            Tipo        = $tipo
            Descricao   = $(if ($s.Description) { "$($s.Description)" } else { '' })
            Administrativo = $(if ([int64]$s.Type -ge 2147483648 -or "$($s.Name)" -match '\$$') { 'Sim' } else { 'Nao' })
        })
    }
    return @($rows | Sort-Object -Property Nome)
}
