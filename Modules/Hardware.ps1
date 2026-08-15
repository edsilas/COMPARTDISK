<#
 COMPARTDISK 1.4.0 - Hardware.ps1
 Desenvolvido por Edsilas
 Acoes: Info | Full | Gpu | Memory | Devices | Temperature
#>
[CmdletBinding()]
param(
    [ValidateSet('Info', 'Full', 'Gpu', 'Memory', 'Devices', 'Temperature')]
    [string]$Action = 'Info',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

# Peso para consolidar severidades. O resultado do modulo escala, nunca regride:
# sem isso o estado global passa a ser o do ULTIMO item analisado, e um bloco
# saudavel executado depois apagaria o aviso de um bloco anterior.
$script:PesoSeveridade = @{ 'OK' = 0; 'INFO' = 0; 'WARN' = 1; 'CRIT' = 2 }

function Set-HwResultado {
    param([ValidateSet('OK', 'WARN', 'ERROR')][string]$Estado)
    $peso = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }
    if ($peso[$Estado] -gt $peso["$($script:result)"]) { $script:result = $Estado }
}

function Get-HwDado {
    <# Consulta cada coletor UMA vez por execucao e reutiliza o resultado.

       Antes, Info chamava Get-CompartDiskHardwareInfo duas vezes (Show-Basico e
       Show-Plataforma) e Full repetia o mesmo par, alem de reconsultar
       Win32_ComputerSystem que Get-CompartDiskSystemInfo ja havia lido.

       O envelope { Ok, Valor, Erro } tambem separa "consulta falhou" de "consulta
       nao devolveu nada" - a colecao vazia devolvida por Get-CompartDiskCim quando
       o WMI nao responde e indistinguivel, sozinha, de um inventario legitimamente
       vazio. #>
    param(
        [Parameter(Mandatory)][string]$Nome,
        [Parameter(Mandatory)][scriptblock]$Consulta
    )
    if (-not $script:Cache) { $script:Cache = @{} }
    if ($script:Cache.ContainsKey($Nome)) { return $script:Cache[$Nome] }
    $r = Invoke-SafeCommand $Consulta -Activity "Coleta: $Nome" -Silent
    $script:Cache[$Nome] = [pscustomobject]@{
        Ok    = $r.Success
        Valor = $r.Value
        Erro  = $(if ($r.Error) { "$($r.Error.Exception.Message)" } else { '' })
    }
    if (-not $r.Success) { Write-Log DEBUG ("Coleta '{0}' falhou: {1}" -f $Nome, $script:Cache[$Nome].Erro) -NoConsole }
    return $script:Cache[$Nome]
}

function ConvertTo-HwArray {
    <# Normaliza o retorno de um coletor numa colecao real.

       Invoke-SafeCommand guarda o resultado do bloco num CAMPO, e um array vazio
       devolvido pelo coletor chega ali como $null (o PowerShell desenrola a colecao
       vazia na atribuicao). Depois disso "@($valor)" nao produz colecao vazia:
       produz UM elemento nulo. Sem esta normalizacao, "nenhum item encontrado"
       virava uma linha fantasma - todos os campos vazios - publicada no relatorio
       como se fosse um dispositivo real. #>
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return @() }
    return @(@($Valor) | Where-Object { $null -ne $_ })
}

function Add-HwLimitacao {
    <# Registra uma limitacao de coleta como achado INFO e no log, sem transformar
       ausencia de dado em falha de hardware nem em atestado de saude. #>
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Mensagem,
        [string]$Recomendacao = ''
    )
    Write-Log WARN $Mensagem
    Add-CompartDiskFinding -Severity INFO -Area $Area -Message $Mensagem -Recommendation $Recomendacao
}

function Get-HwValorNumerico {
    <# Converte para numero apenas quando o texto E um numero. Devolve $null caso
       contrario, para que nenhum calculo prossiga sobre 'n/d', vazio ou texto. #>
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return $null }
    $t = "$Valor".Trim()
    if ($t -eq '' -or $t -eq 'n/d' -or $t -eq 'n/a') { return $null }
    $t = $t -replace ',', '.'
    $n = 0.0
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    return $null
}

function Show-Basico {
    $rSis = Get-HwDado 'SystemInfo'   { Get-CompartDiskSystemInfo }
    $rHw  = Get-HwDado 'HardwareInfo' { Get-CompartDiskHardwareInfo }

    if (-not $rSis.Ok -or -not $rHw.Ok) {
        Add-HwLimitacao -Area 'Hardware' -Mensagem 'Inventario basico incompleto: a consulta ao repositorio WMI falhou.' -Recomendacao 'Validar o repositorio WMI (winmgmt /verifyrepository) antes de interpretar este relatorio.'
        Set-HwResultado 'WARN'
    }

    $sis = $rSis.Valor
    $hw  = $rHw.Valor

    if ($sis) {
        Write-Color ''
        Write-Color '  SISTEMA' -Color White
        foreach ($k in $sis.Keys) { Write-CompartDiskKeyValue $k $sis[$k] -Pad 20 }
        Add-CompartDiskSection -Title 'Sistema operacional' -Status OK -Pairs $sis
    }
    if ($hw) {
        Write-Color ''
        Write-Color '  HARDWARE' -Color White
        foreach ($k in $hw.Keys) { Write-CompartDiskKeyValue $k $hw[$k] -Pad 20 }
        Add-CompartDiskSection -Title 'Hardware principal' -Status OK -Pairs $hw
    }
    if (-not $hw) { return }

    # Get-CompartDiskHardwareInfo devolve a cadeia 'n/d' quando o WMI nao responde.
    # O "[double]'n/d'" lancava, o catch vazio engolia e $uso ficava em 0: o relatorio
    # afirmava "Uso de memoria em 0%" com severidade OK numa maquina em que a leitura
    # simplesmente nao aconteceu.
    $uso = Get-HwValorNumerico $hw['RAM em uso (%)']
    if ($null -eq $uso -or $uso -lt 0 -or $uso -gt 100) {
        Add-CompartDiskFinding -Severity INFO -Area 'Memoria' -Message 'Uso de memoria nao verificado: leitura do WMI indisponivel.' -Recommendation 'Validar o repositorio WMI antes de interpretar este relatorio.'
    } elseif ($uso -ge 90) {
        Add-CompartDiskFinding -Severity CRIT -Area 'Memoria' -Message "Uso de memoria em $uso%." -Recommendation 'Fechar aplicativos ou avaliar expansao de RAM.'
        Set-HwResultado 'WARN'
    } elseif ($uso -ge 80) {
        Add-CompartDiskFinding -Severity WARN -Area 'Memoria' -Message "Uso de memoria em $uso%." -Recommendation 'Monitorar consumo por processo.'
        # Achado WARN sem resultado WARN e sinal mascarado: o ramo de 90% ja escalava
        # o resultado e este nao, entao o relatorio consolidado registrava OK.
        Set-HwResultado 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Memoria' -Message "Uso de memoria em $uso%."
    }
    Write-Log OK 'Inventario basico coletado.'
}

function Show-Memoria {
    $r = Get-HwDado 'MemoryModules' { Get-CompartDiskMemoryModules }
    $mods = (ConvertTo-HwArray $r.Valor)

    if (-not $r.Ok) {
        Add-HwLimitacao -Area 'Memoria' -Mensagem "Modulos de memoria nao enumerados: a consulta falhou ($($r.Erro))." -Recomendacao 'Validar o repositorio WMI; a capacidade total continua disponivel no inventario basico.'
        Add-CompartDiskSection -Title 'Modulos de memoria' -Status WARN -Summary 'Nao enumerados (falha na consulta)'
        Set-HwResultado 'WARN'
        return
    }
    if ($mods.Count -eq 0) {
        # Ausencia de Win32_PhysicalMemory e comum em maquina virtual e em firmware
        # que nao publica SMBIOS tipo 17. Nao e defeito de hardware nem falha total
        # do diagnostico: a capacidade total ja veio do inventario basico.
        Add-HwLimitacao -Area 'Memoria' -Mensagem 'Modulos de memoria nao publicados pelo firmware (SMBIOS tipo 17 ausente).' -Recomendacao 'Comum em maquina virtual. A capacidade total permanece valida no inventario basico.'
        Add-CompartDiskSection -Title 'Modulos de memoria' -Status INFO -Summary 'Nao publicados pelo firmware'
        return
    }

    # Capacidade total somada a partir dos MODULOS, distinta da capacidade total
    # visivel ao sistema operacional (que o inventario basico ja publica).
    $bytes = 0
    $semCapacidade = 0
    foreach ($m in $mods) {
        $b = Get-HwValorNumerico $m.CapacidadeBytes
        if ($null -eq $b -or $b -le 0) { $semCapacidade++ } else { $bytes += $b }
    }

    # Projecao para exibicao: as colunas numericas cruas existem para o calculo e
    # para a validacao, nao para poluir a tabela do relatorio.
    $vis = @($mods | Select-Object Slot, Capacidade, Velocidade, VelocidadeConfigurada, Tipo, Fabricante, PartNumber, NumeroSerie)
    Write-Color ''
    $vis | Format-Table -AutoSize | Out-String -Width 180 | Write-Output

    $resumo = "$($mods.Count) modulo(s) instalado(s)"
    if ($bytes -gt 0) { $resumo += " | $(ConvertTo-CompartDiskSize $bytes) somados nos modulos" }
    if ($semCapacidade -gt 0) { $resumo += " | $semCapacidade sem capacidade publicada" }
    Add-CompartDiskSection -Title 'Modulos de memoria' -Status OK -Rows $vis -Summary $resumo

    # Velocidades diferentes sao INFORMACAO de configuracao, nunca defeito: a placa
    # normalmente opera todos os modulos na menor frequencia comum, o que e um
    # impacto de desempenho previsto, e nao um modulo com falha.
    $vel = @($mods | ForEach-Object { Get-HwValorNumerico $_.VelocidadeNominalMHz } | Where-Object { $null -ne $_ -and $_ -gt 0 } | Sort-Object -Unique)
    if ($vel.Count -gt 1) {
        Add-CompartDiskFinding -Severity INFO -Area 'Memoria' `
            -Message ("Modulos com velocidades nominais diferentes: {0} MHz." -f ($vel -join ', ')) `
            -Recommendation 'Condicao de configuracao, nao defeito: o conjunto tende a operar na menor frequencia comum.'
    }
    Write-Log OK "$($mods.Count) modulo(s) de memoria identificado(s)."
}

function Get-HwVramPrecisa {
    <# AdapterRAM e UInt32: satura em 4 GB e publica ~4293918720 para qualquer placa
       com 4 GB ou mais. Publicar "4 GB" para uma placa de 12 GB e inventar um valor
       concreto errado. Quando a saturacao e detectada, tenta-se a chave que o proprio
       driver preenche (qwMemorySize, QWORD); se ela nao existir, declara-se o limite
       em vez de afirmar um numero. #>
    param([AllowNull()][object]$AdapterRAM, [string]$Nome)

    $b = Get-HwValorNumerico $AdapterRAM
    if ($null -eq $b -or $b -le 0) { return 'n/d' }
    if ($b -lt 4290000000) { return (ConvertTo-CompartDiskSize $b) }

    $classe = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    try {
        foreach ($sub in (Get-ChildItem -LiteralPath $classe -ErrorAction Stop)) {
            $desc = Get-CompartDiskRegistryValue -Path $sub.PSPath -Name 'DriverDesc'
            if ("$desc" -ne "$Nome") { continue }
            $qw = Get-CompartDiskRegistryValue -Path $sub.PSPath -Name 'HardwareInformation.qwMemorySize'
            $n = Get-HwValorNumerico $qw
            if ($null -ne $n -and $n -gt 0) { return (ConvertTo-CompartDiskSize $n) }
        }
    } catch { Write-Log DEBUG "qwMemorySize indisponivel para '$Nome': $($_.Exception.Message)" -NoConsole }
    return '>= 4 GB (AdapterRAM satura em 32 bits)'
}

function Show-Gpu {
    $r = Get-HwDado 'GpuInfo' { Get-CompartDiskGpuInfo }
    $g = (ConvertTo-HwArray $r.Valor)

    if (-not $r.Ok) {
        Add-HwLimitacao -Area 'GPU' -Mensagem "Adaptadores graficos nao enumerados: a consulta falhou ($($r.Erro))." -Recomendacao 'Validar o repositorio WMI.'
        Add-CompartDiskSection -Title 'Adaptadores graficos' -Status WARN -Summary 'Nao enumerados (falha na consulta)'
        Set-HwResultado 'WARN'
    } elseif ($g.Count -eq 0) {
        # Silencio total era o comportamento anterior: sem secao, sem achado, sem log.
        Add-HwLimitacao -Area 'GPU' -Mensagem 'Nenhum adaptador grafico retornado por Win32_VideoController.' -Recomendacao 'Verificar o driver de video no Gerenciador de Dispositivos.'
        Add-CompartDiskSection -Title 'Adaptadores graficos' -Status INFO -Summary 'Nenhum adaptador retornado'
    } else {
        $rows = New-Object System.Collections.ArrayList
        foreach ($a in $g) {
            # PCI\ no PNPDeviceID identifica adaptador FISICO no barramento; ROOT\ e
            # SW\ identificam adaptadores de software (RDP, Hyper-V, VNC, basico da
            # Microsoft). Discriminador estrutural, nao comparacao de nome traduzido.
            $pnp = "$($a.PNPDeviceID)"
            $tipo = if ($pnp -like 'PCI\*') { 'Fisico (PCI)' }
                    elseif ($pnp) { 'Virtual/software' }
                    else { 'Desconhecido' }
            [void]$rows.Add([pscustomobject]@{
                Adaptador   = $a.Adaptador
                Tipo        = $tipo
                VRAM        = (Get-HwVramPrecisa -AdapterRAM $a.AdapterRAMBytes -Nome "$($a.Adaptador)")
                Driver      = $a.Driver
                DriverData  = $a.DriverData
                Resolucao   = $a.Resolucao
                Atualizacao = $a.Atualizacao
                Status      = $(if ("$($a.Status)" -ne '') { $a.Status } else { 'n/d' })
            })
        }
        Write-Color ''
        $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

        $fisicas = @($rows | Where-Object { $_.Tipo -eq 'Fisico (PCI)' }).Count
        Add-CompartDiskSection -Title 'Adaptadores graficos' -Status OK -Rows @($rows) `
            -Summary ("{0} adaptador(es) | {1} fisico(s)" -f $rows.Count, $fisicas)

        foreach ($a in $rows) {
            # Status ausente nao e status ruim: Win32_VideoController deixa a
            # propriedade nula em varios drivers. So um estado explicitamente
            # diferente de OK gera aviso. Multiplas GPUs, GPU inativa ou adaptador
            # virtual NAO geram achado por si so.
            if ("$($a.Status)" -notin @('OK', 'n/d')) {
                Add-CompartDiskFinding -Severity WARN -Area 'GPU' -Message "Adaptador '$($a.Adaptador)' com status '$($a.Status)'." -Recommendation 'Reinstalar o driver de video.'
                Set-HwResultado 'WARN'
            }
        }
    }

    $rm = Get-HwDado 'Monitors' { Get-CompartDiskMonitors }
    $m = (ConvertTo-HwArray $rm.Valor)
    if (-not $rm.Ok) {
        Add-HwLimitacao -Area 'GPU' -Mensagem 'Monitores nao enumerados: WmiMonitorID indisponivel.' -Recomendacao 'Classe exposta apenas por alguns drivers de video; ausencia nao indica defeito.'
    } elseif ($m.Count -gt 0) {
        Write-Color ''
        $m | Format-Table -AutoSize | Out-String -Width 180 | Write-Output
        Add-CompartDiskSection -Title 'Monitores' -Status INFO -Rows $m
    } else {
        Add-CompartDiskSection -Title 'Monitores' -Status INFO -Summary 'Nenhum monitor publicado por WmiMonitorID'
    }
    Write-Log OK 'Subsistema grafico inventariado.'
}

function Get-HwPnpDevices {
    <# Uma unica leitura de Win32_PnPEntity por execucao. USB, PCI, controladoras e
       dispositivos com erro derivam todos dela, em vez de tres consultas com
       filtros diferentes sobre a mesma classe. #>
    return (Get-HwDado 'PnPEntity' { Get-CompartDiskCim -Class Win32_PnPEntity })
}

function Show-Dispositivos {
    $rPnp = Get-HwPnpDevices
    if (-not $rPnp.Ok) {
        Add-HwLimitacao -Area 'Dispositivos' -Mensagem "Inventario de dispositivos nao realizado: Win32_PnPEntity indisponivel ($($rPnp.Erro))." -Recomendacao 'Validar o repositorio WMI (winmgmt /verifyrepository).'
        Add-CompartDiskSection -Title 'Dispositivos' -Status WARN -Summary 'Nao inventariados (falha na consulta)'
        Set-HwResultado 'WARN'
        return
    }
    $todos = (ConvertTo-HwArray $rPnp.Valor)
    if ($todos.Count -eq 0) {
        Add-HwLimitacao -Area 'Dispositivos' -Mensagem 'Win32_PnPEntity nao devolveu nenhum dispositivo.' -Recomendacao 'Resultado atipico: validar o repositorio WMI.'
        Set-HwResultado 'WARN'
        return
    }

    # ---------------------------------------------------------------- USB
    # O caminho anterior percorria Win32_USBControllerDevice e resolvia cada
    # referencia com [wmi]. Esse acelerador NAO EXISTE no PowerShell 7 - e o
    # Launcher procura o pwsh 7 antes do powershell.exe. Na engine preferida do
    # projeto a conversao lancava, o catch vazio silenciava, e o inventario caia
    # sem aviso para o filtro PNPClass='USB', que ve apenas hubs e controladores:
    # teclado, mouse, webcam e audio USB sumiam do relatorio.
    # DeviceID LIKE 'USB%' cobre todo dispositivo conectado por USB, e funciona
    # igual em 5.1 e 7.
    $usb = New-Object System.Collections.ArrayList
    foreach ($d in ($todos | Where-Object { "$($_.DeviceID)" -like 'USB\*' })) {
        $id = "$($d.DeviceID)"
        # Nao usar $pid: e variavel automatica somente-leitura do PowerShell (ID do
        # processo) e a atribuicao lanca, derrubando a acao inteira.
        $idVid = if ($id -match 'VID_([0-9A-Fa-f]{4})') { $matches[1].ToUpperInvariant() } else { 'n/d' }
        $idPid = if ($id -match 'PID_([0-9A-Fa-f]{4})') { $matches[1].ToUpperInvariant() } else { 'n/d' }
        [void]$usb.Add([pscustomobject]@{
            Dispositivo = $d.Name
            Fabricante  = $(if ("$($d.Manufacturer)" -ne '') { $d.Manufacturer } else { 'n/d' })
            Classe      = $(if ("$($d.PNPClass)" -ne '') { $d.PNPClass } else { 'n/d' })
            VID         = $idVid
            PID         = $idPid
            Status      = $(if ("$($d.Status)" -ne '') { $d.Status } else { 'n/d' })
            DeviceID    = $id
        })
    }
    if ($usb.Count -gt 0) {
        Add-CompartDiskSection -Title 'Dispositivos USB' -Status INFO -Rows @($usb | Select-Object -First 40) `
            -Summary ("{0} dispositivo(s) | metodo: Win32_PnPEntity (DeviceID USB)" -f $usb.Count)
        Write-Color ("`n  Dispositivos USB: {0}" -f $usb.Count) -Color White
    } else {
        Add-CompartDiskSection -Title 'Dispositivos USB' -Status INFO -Summary 'Nenhum dispositivo USB enumerado'
    }

    # ---------------------------------------------------------------- PCI
    $pci = New-Object System.Collections.ArrayList
    foreach ($d in ($todos | Where-Object { "$($_.DeviceID)" -like 'PCI\*' })) {
        [void]$pci.Add([pscustomobject]@{
            Dispositivo = $d.Name
            Classe      = $(if ("$($d.PNPClass)" -ne '') { $d.PNPClass } else { 'n/d' })
            Status      = $(if ("$($d.Status)" -ne '') { $d.Status } else { 'n/d' })
            Fabricante  = $(if ("$($d.Manufacturer)" -ne '') { $d.Manufacturer } else { 'n/d' })
        })
    }
    if ($pci.Count -gt 0) {
        Add-CompartDiskSection -Title 'Dispositivos PCI' -Status INFO -Rows @($pci | Select-Object -First 40) -Summary "$($pci.Count) dispositivo(s)"
        Write-Color ("  Dispositivos PCI: {0}" -f $pci.Count) -Color White
    }

    # -------------------------------------------------------- Controladoras
    # Derivadas da MESMA leitura: nenhuma consulta adicional. Identificacao
    # incompleta e registrada como informacao limitada, nunca como falha.
    $classesCtrl = @('SCSIAdapter', 'HDC', 'USB', 'Net', 'Display', 'SDHost', 'System')
    $ctrl = New-Object System.Collections.ArrayList
    foreach ($d in ($todos | Where-Object { $classesCtrl -contains "$($_.PNPClass)" -and "$($_.DeviceID)" -like 'PCI\*' })) {
        $tipo = switch ("$($d.PNPClass)") {
            'SCSIAdapter' { 'Armazenamento' }
            'HDC'         { 'Armazenamento (IDE/SATA)' }
            'USB'         { 'USB' }
            'Net'         { 'Rede' }
            'Display'     { 'Video' }
            'SDHost'      { 'Cartao SD' }
            default       { 'Sistema/barramento' }
        }
        [void]$ctrl.Add([pscustomobject]@{
            Controladora = $d.Name
            Tipo         = $tipo
            Fabricante   = $(if ("$($d.Manufacturer)" -ne '') { $d.Manufacturer } else { 'n/d' })
            Status       = $(if ("$($d.Status)" -ne '') { $d.Status } else { 'n/d' })
        })
    }
    if ($ctrl.Count -gt 0) {
        Add-CompartDiskSection -Title 'Controladoras e barramentos' -Status INFO -Rows @($ctrl | Select-Object -First 40) -Summary "$($ctrl.Count) controladora(s)"
    }

    # ------------------------------------------------- Dispositivos com erro
    # Derivado da mesma leitura: ConfigManagerErrorCode ja vem em Win32_PnPEntity.
    # Antes era uma segunda consulta (Get-CompartDiskDriverInfo -OnlyProblems), cuja
    # FALHA devolvia colecao vazia e o modulo publicava "Nenhum dispositivo com
    # codigo de erro" como achado OK - uma consulta que nao aconteceu virava
    # atestado de saude.
    $prob = New-Object System.Collections.ArrayList
    foreach ($d in $todos) {
        $cod = Get-HwValorNumerico $d.ConfigManagerErrorCode
        if ($null -eq $cod -or $cod -eq 0) { continue }
        $c = [int]$cod
        [void]$prob.Add([pscustomobject]@{
            Dispositivo = $d.Name
            Fabricante  = $(if ("$($d.Manufacturer)" -ne '') { $d.Manufacturer } else { 'n/d' })
            CodigoErro  = $c
            Problema    = (Get-CompartDiskDeviceErrorText $c)
            Severidade  = (Get-CompartDiskDeviceErrorSeverity $c)
            Estado      = $(if ("$($d.Status)" -ne '') { $d.Status } else { 'n/d' })
            DeviceID    = "$($d.DeviceID)"
        })
    }

    if ($prob.Count -eq 0) {
        Write-Log OK 'Nenhum dispositivo com erro no Gerenciador de Dispositivos.'
        Add-CompartDiskFinding -Severity OK -Area 'Dispositivos' -Message 'Nenhum dispositivo com codigo de erro.'
        return
    }

    # Severidade POR CODIGO, alinhada a classificacao canonica do Drivers.ps1.
    # Antes, todo codigo diferente de zero virava CRIT com a recomendacao
    # "reinstalar o driver": um dispositivo deliberadamente desabilitado (22) ou
    # simplesmente desconectado (45) - situacoes normais - eram publicados como
    # falha critica, e o mesmo equipamento recebia severidades contraditorias de
    # Hardware.ps1 e Drivers.ps1.
    $ordem = @($prob | Sort-Object -Property @{ Expression = { $script:PesoSeveridade["$($_.Severidade)"] }; Descending = $true }, Dispositivo)
    Write-Color ''
    $ordem | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

    $criticos = @($ordem | Where-Object { $_.Severidade -eq 'CRIT' })
    $avisos   = @($ordem | Where-Object { $_.Severidade -eq 'WARN' })
    $infos    = @($ordem | Where-Object { $_.Severidade -eq 'INFO' })

    $statusSecao = if ($criticos.Count -gt 0) { 'CRIT' } elseif ($avisos.Count -gt 0) { 'WARN' } else { 'INFO' }
    Add-CompartDiskSection -Title 'Dispositivos com problema' -Status $statusSecao -Rows @($ordem) `
        -Summary ("{0} com codigo de erro | {1} critico(s), {2} aviso(s), {3} informativo(s)" -f $prob.Count, $criticos.Count, $avisos.Count, $infos.Count)

    foreach ($p in (@($criticos) + @($avisos) | Select-Object -First 10)) {
        Add-CompartDiskFinding -Severity $p.Severidade -Area 'Dispositivos' `
            -Message ("{0}: {1} (codigo {2}) | ID: {3}" -f $p.Dispositivo, $p.Problema, $p.CodigoErro, $p.DeviceID) `
            -Recommendation 'Diagnostico detalhado e acao no modulo de drivers (Drivers.ps1 -Action Problems).'
    }
    if ($infos.Count -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Dispositivos' `
            -Message ("{0} dispositivo(s) desabilitado(s) ou nao conectado(s): {1}." -f $infos.Count, ((@($infos | Select-Object -First 5).Dispositivo) -join ', ')) `
            -Recommendation 'Condicao normal quando a desativacao ou a remocao foi intencional.'
    }
    if ($criticos.Count -gt 0 -or $avisos.Count -gt 0) { Set-HwResultado 'WARN' }

    # Impressoras
    $ri = Get-HwDado 'Printers' { Get-CompartDiskPrinters }
    if ($ri.Ok -and (ConvertTo-HwArray $ri.Valor).Count -gt 0) {
        Add-CompartDiskSection -Title 'Impressoras' -Status INFO -Rows (ConvertTo-HwArray $ri.Valor)
    }
}

function Show-Temperatura {
    Write-Log INFO 'Consultando sensores termicos expostos pelo firmware (ACPI)...'
    $rows = New-Object System.Collections.ArrayList

    $rz = Get-HwDado 'ThermalZone' { Get-CompartDiskCim -Class MSAcpi_ThermalZoneTemperature -Namespace 'root\wmi' }
    $descartadas = 0
    foreach ($z in (ConvertTo-HwArray $rz.Valor)) {
        # CurrentTemperature vem em DECIMOS DE KELVIN. Sem validacao, um firmware que
        # publica 0 produzia "-273.15 C" apresentado como leitura real, e 2732 (zero
        # absoluto convertido, o sentinela usual de "sem sensor") virava "0 C".
        $bruto = Get-HwValorNumerico $z.CurrentTemperature
        if ($null -eq $bruto -or $bruto -le 2732) { $descartadas++; continue }
        $c = [math]::Round(($bruto / 10) - 273.15, 1)
        if ($c -lt 5 -or $c -gt 125) { $descartadas++; continue }
        [void]$rows.Add([pscustomobject]@{
            Sensor      = "ACPI: $($z.InstanceName)"
            Origem      = 'Firmware (ACPI)'
            Temperatura = "$c C"
            Ativa       = $z.Active
        })
    }

    # Temperatura dos discos: reutiliza a coleta ja feita nesta execucao em vez de
    # reconsultar Get-PhysicalDisk e os contadores de confiabilidade disco a disco.
    $rd = Get-HwDado 'DiskInfo' { Get-CompartDiskDiskInfo }
    foreach ($d in (ConvertTo-HwArray $rd.Valor)) {
        $t = Get-HwValorNumerico ("$($d.Temperatura)" -replace '[^0-9,.\-]', '')
        if ($null -eq $t -or $t -le 0 -or $t -gt 125) { continue }
        [void]$rows.Add([pscustomobject]@{
            Sensor      = "Disco: $($d.Modelo)"
            Origem      = 'Contador de confiabilidade'
            Temperatura = "$t C"
            Ativa       = 'n/a'
        })
    }

    if ($rows.Count -eq 0) {
        # MSAcpi_ThermalZoneTemperature exige privilegio administrativo, e este modulo
        # nao o obriga (as outras cinco acoes sao leitura comum). Sem a distincao
        # abaixo, um Acesso Negado era reportado como ausencia de sensor no firmware,
        # mandando o usuario a UEFI atras de nada.
        if (-not (Test-Administrator)) {
            Write-Log WARN 'Leitura termica indisponivel: os sensores ACPI exigem privilegio administrativo.'
            Add-CompartDiskFinding -Severity INFO -Area 'Temperatura' -Message 'Sensores termicos nao consultados: execucao sem privilegio administrativo.' -Recommendation 'Reabrir o Launcher.bat como Administrador para ler os sensores ACPI.'
        } elseif (-not $rz.Ok) {
            Write-Log WARN "Leitura termica indisponivel: a consulta ACPI falhou ($($rz.Erro))."
            Add-CompartDiskFinding -Severity INFO -Area 'Temperatura' -Message "Sensores termicos nao consultados: a consulta ACPI falhou ($($rz.Erro))." -Recommendation 'Validar o repositorio WMI (namespace root\wmi).'
        } elseif ($descartadas -gt 0) {
            Write-Log WARN "Sensores termicos presentes, porem com $descartadas leitura(s) fora de faixa plausivel."
            Add-CompartDiskFinding -Severity INFO -Area 'Temperatura' -Message "Firmware publicou $descartadas leitura(s) termica(s) invalida(s) (fora da faixa de 5 C a 125 C)." -Recommendation 'Sensor nao confiavel neste firmware; consultar a UEFI/BIOS ou o utilitario do fabricante.'
        } else {
            Write-Log WARN 'Nenhum sensor termico exposto por este firmware.'
            Add-CompartDiskFinding -Severity INFO -Area 'Temperatura' -Message 'Firmware nao expoe sensores termicos via ACPI/WMI.' -Recommendation 'Consultar a UEFI/BIOS ou o utilitario do fabricante.'
        }
        $script:result = 'UNSUPPORTED'
        return
    }
    $rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
    Add-CompartDiskSection -Title 'Sensores termicos' -Status OK -Rows @($rows) `
        -Summary ("{0} leitura(s) valida(s){1}" -f $rows.Count, $(if ($descartadas -gt 0) { " | $descartadas descartada(s) fora de faixa" } else { '' }))
    Write-Log OK "$($rows.Count) leitura(s) termica(s) obtida(s)."
}

function Show-Plataforma {
    $tpm = Test-TPM
    $sb  = Test-SecureBoot
    $rHw = Get-HwDado 'HardwareInfo' { Get-CompartDiskHardwareInfo }
    $rCs = Get-HwDado 'ComputerSystem' { Get-CompartDiskCim -Class Win32_ComputerSystem }

    # TPM: estados distintos, sem colapsar ausencia em falha. Um equipamento que
    # simplesmente nao possui TPM nao tem defeito de hardware.
    $tpmTexto =
        if (-not $tpm.Present) { 'Ausente (equipamento nao expoe TPM)' }
        elseif ($tpm.Ready)    { "Presente, habilitado e pronto (versao $($tpm.Version))" }
        elseif ($tpm.Enabled)  { "Presente e habilitado, nao pronto (versao $($tpm.Version))" }
        else                   { "Presente, nao habilitado (versao $($tpm.Version))" }

    $cs = $rCs.Valor
    $hyperv = if (-not $rCs.Ok -or -not $cs) { 'n/d' }
              elseif ($cs.HypervisorPresent) { 'Sim' } else { 'Nao' }

    # Bateria: apenas PRESENCA, como inventario. A saude, o desgaste e o relatorio
    # detalhado pertencem ao Battery.ps1 e nao sao duplicados aqui. Desktop sem
    # bateria e condicao normal e nunca gera achado.
    $rBat = Get-HwDado 'Battery' { Get-CompartDiskCim -Class Win32_Battery }
    $bateria = if (-not $rBat.Ok) { 'n/d (consulta indisponivel)' }
               elseif ((ConvertTo-HwArray $rBat.Valor).Count -gt 0) { "Presente ($((ConvertTo-HwArray $rBat.Valor).Count)) - detalhe no modulo de bateria" }
               else { 'Ausente (desktop ou equipamento sem bateria)' }

    $hw = $rHw.Valor
    $pares = [ordered]@{
        'Firmware'          = $sb.FirmwareType
        'Secure Boot'       = $sb.Status
        'TPM'               = $tpmTexto
        'TPM fabricante'    = $tpm.Manufacturer
        'Virtualizacao CPU' = $(if ($hw) { $hw['Virtualizacao'] } else { 'n/d' })
        'Hyper-V presente'  = $hyperv
        'Bateria'           = $bateria
    }
    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 20 }
    Add-CompartDiskSection -Title 'Plataforma e virtualizacao' -Status OK -Pairs $pares
}

function Invoke-HwEtapa {
    <# Cada bloco do inventario e independente: a falha de um componente nao pode
       cancelar os demais. Sem isso, uma consulta de GPU que lance impede a
       enumeracao da placa-mae, dos discos e de todo o restante do relatorio. #>
    param([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][scriptblock]$Bloco)
    try {
        & $Bloco
    } catch {
        Write-Log WARN "Etapa '$Nome' do inventario falhou; as demais continuam." -ErrorRecord $_
        Add-CompartDiskFinding -Severity WARN -Area 'Hardware' `
            -Message ("Etapa '{0}' do inventario de hardware falhou: {1}" -f $Nome, $_.Exception.Message) `
            -Recommendation 'Reexecutar; validar o repositorio WMI e os privilegios.'
        Set-HwResultado 'WARN'
    }
}

function Show-Armazenamento {
    $rd = Get-HwDado 'DiskInfo' { Get-CompartDiskDiskInfo }
    if (-not $rd.Ok) {
        Add-HwLimitacao -Area 'Armazenamento' -Mensagem "Discos fisicos nao enumerados: a consulta falhou ($($rd.Erro))." -Recomendacao 'Diagnostico de saude do armazenamento no modulo S.M.A.R.T. (Smart.ps1).'
        Set-HwResultado 'WARN'
    } else {
        $discos = (ConvertTo-HwArray $rd.Valor)
        if ($discos.Count -gt 0) {
            Write-Color ''
            $discos | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
            Add-CompartDiskSection -Title 'Discos fisicos' -Status OK -Rows $discos -Summary "$($discos.Count) disco(s) fisico(s)"
        } else {
            Add-HwLimitacao -Area 'Armazenamento' -Mensagem 'Nenhum disco fisico enumerado.' -Recomendacao 'Resultado atipico: validar o subsistema de armazenamento.'
            Set-HwResultado 'WARN'
        }
    }

    $rv = Get-HwDado 'VolumeInfo' { Get-CompartDiskVolumeInfo }
    if ($rv.Ok -and (ConvertTo-HwArray $rv.Valor).Count -gt 0) {
        Add-CompartDiskSection -Title 'Volumes' -Status OK -Rows (ConvertTo-HwArray $rv.Valor) -Summary "$((ConvertTo-HwArray $rv.Valor).Count) volume(s) fixo(s)"
    } elseif (-not $rv.Ok) {
        Add-HwLimitacao -Area 'Armazenamento' -Mensagem 'Volumes nao enumerados: a consulta falhou.'
    }
}

# ------------------------------------------------------------------------------
try {
    if (-not (Start-CompartDiskModule -Name 'Hardware' -Action $Action -Quiet:$Quiet)) {
        # O estado persistido em state_Hardware_<Acao>.json vem de $result, e o
        # finally roda mesmo com este exit: sair sem marcar gravava "Resultado=OK"
        # para uma execucao recusada, enquanto o processo devolvia 2.
        $result = 'ERROR'
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'Info' {
            Invoke-HwEtapa 'inventario basico' { Show-Basico }
            Invoke-HwEtapa 'plataforma'        { Show-Plataforma }
        }
        'Memory'      { Invoke-HwEtapa 'memoria'      { Show-Memoria } }
        'Gpu'         { Invoke-HwEtapa 'video'        { Show-Gpu } }
        'Devices'     { Invoke-HwEtapa 'dispositivos' { Show-Dispositivos } }
        'Temperature' { Invoke-HwEtapa 'temperatura'  { Show-Temperatura } }
        'Full' {
            Invoke-HwEtapa 'inventario basico' { Show-Basico }
            Invoke-HwEtapa 'plataforma'        { Show-Plataforma }
            Invoke-HwEtapa 'memoria'           { Show-Memoria }
            Invoke-HwEtapa 'video'             { Show-Gpu }
            Invoke-HwEtapa 'dispositivos'      { Show-Dispositivos }
            Invoke-HwEtapa 'armazenamento'     { Show-Armazenamento }
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Hardware (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Hardware' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
