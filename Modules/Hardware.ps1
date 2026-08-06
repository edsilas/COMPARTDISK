<#
 COMPARTDISK 1.3.1 - Hardware.ps1
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

function Show-Basico {
    $sis = Get-CompartDiskSystemInfo
    $hw  = Get-CompartDiskHardwareInfo

    Write-Color ''
    Write-Color '  SISTEMA' -Color White
    foreach ($k in $sis.Keys) { Write-CompartDiskKeyValue $k $sis[$k] -Pad 20 }
    Write-Color ''
    Write-Color '  HARDWARE' -Color White
    foreach ($k in $hw.Keys) { Write-CompartDiskKeyValue $k $hw[$k] -Pad 20 }

    Add-CompartDiskSection -Title 'Sistema operacional' -Status OK -Pairs $sis
    Add-CompartDiskSection -Title 'Hardware principal' -Status OK -Pairs $hw

    # Get-CompartDiskHardwareInfo devolve a cadeia 'n/d' quando o WMI nao responde.
    # O "[double]'n/d'" lancava, o catch vazio engolia e $uso ficava em 0: o relatorio
    # afirmava "Uso de memoria em 0%" com severidade OK numa maquina em que a leitura
    # simplesmente nao aconteceu.
    $uso = $null
    if ("$($hw['RAM em uso (%)'])" -match '^\d+([.,]\d+)?$') {
        try { $uso = [double]("$($hw['RAM em uso (%)'])" -replace ',', '.') } catch { }
    }
    if ($null -eq $uso) {
        Add-CompartDiskFinding -Severity INFO -Area 'Memoria' -Message 'Uso de memoria nao verificado: leitura do WMI indisponivel.' -Recommendation 'Validar o repositorio WMI antes de interpretar este relatorio.'
    } elseif ($uso -ge 90) {
        Add-CompartDiskFinding -Severity CRIT -Area 'Memoria' -Message "Uso de memoria em $uso%." -Recommendation 'Fechar aplicativos ou avaliar expansao de RAM.'
        $script:result = 'WARN'
    } elseif ($uso -ge 80) {
        Add-CompartDiskFinding -Severity WARN -Area 'Memoria' -Message "Uso de memoria em $uso%." -Recommendation 'Monitorar consumo por processo.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Memoria' -Message "Uso de memoria em $uso%."
    }
    Write-Log OK 'Inventario basico coletado.'
}

function Show-Memoria {
    $mods = Get-CompartDiskMemoryModules
    if ($mods.Count -eq 0) {
        Write-Log WARN 'Nao foi possivel ler os modulos de memoria fisica.'
        return
    }
    Write-Color ''
    $mods | Format-Table -AutoSize | Out-String -Width 180 | Write-Output
    Add-CompartDiskSection -Title 'Modulos de memoria' -Status OK -Rows $mods -Summary "$($mods.Count) modulo(s) instalado(s)"
    Write-Log OK "$($mods.Count) modulo(s) de memoria identificado(s)."
}

function Show-Gpu {
    $g = Get-CompartDiskGpuInfo
    if ($g.Count -gt 0) {
        Write-Color ''
        $g | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Adaptadores graficos' -Status OK -Rows $g
        foreach ($a in $g) {
            if ("$($a.Status)" -ne 'OK' -and "$($a.Status)" -ne '') {
                Add-CompartDiskFinding -Severity WARN -Area 'GPU' -Message "Adaptador '$($a.Adaptador)' com status '$($a.Status)'." -Recommendation 'Reinstalar o driver de video.'
                $script:result = 'WARN'
            }
        }
    }
    $m = Get-CompartDiskMonitors
    if ($m.Count -gt 0) {
        Write-Color ''
        $m | Format-Table -AutoSize | Out-String -Width 180 | Write-Output
        Add-CompartDiskSection -Title 'Monitores' -Status INFO -Rows $m
    }
    Write-Log OK 'Subsistema grafico inventariado.'
}

function Show-Dispositivos {
    # USB
    $usb = New-Object System.Collections.ArrayList
    foreach ($d in (Get-CompartDiskCim -Class Win32_USBControllerDevice)) {
        try {
            $dep = [wmi]$d.Dependent
            [void]$usb.Add([pscustomobject]@{ Dispositivo = $dep.Name; Status = $dep.Status; DeviceID = $dep.DeviceID })
        } catch { }
    }
    if ($usb.Count -eq 0) {
        foreach ($d in (Get-CompartDiskCim -Class Win32_PnPEntity -Filter "PNPClass='USB'")) {
            [void]$usb.Add([pscustomobject]@{ Dispositivo = $d.Name; Status = $d.Status; DeviceID = $d.DeviceID })
        }
    }
    if ($usb.Count -gt 0) {
        Add-CompartDiskSection -Title 'Dispositivos USB' -Status INFO -Rows @($usb | Select-Object -First 40) -Summary "$($usb.Count) dispositivo(s)"
        Write-Color ("`n  Dispositivos USB: {0}" -f $usb.Count) -Color White
    }

    # PCI / barramento
    $pci = New-Object System.Collections.ArrayList
    foreach ($d in (Get-CompartDiskCim -Class Win32_PnPEntity -Filter "DeviceID LIKE 'PCI%'")) {
        [void]$pci.Add([pscustomobject]@{ Dispositivo = $d.Name; Classe = $d.PNPClass; Status = $d.Status; Fabricante = $d.Manufacturer })
    }
    if ($pci.Count -gt 0) {
        Add-CompartDiskSection -Title 'Dispositivos PCI' -Status INFO -Rows @($pci | Select-Object -First 40) -Summary "$($pci.Count) dispositivo(s)"
        Write-Color ("  Dispositivos PCI: {0}" -f $pci.Count) -Color White
    }

    # Problemas
    $prob = Get-CompartDiskDriverInfo -OnlyProblems
    if ($prob.Count -gt 0) {
        Write-Color ''
        $prob | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Dispositivos com problema' -Status CRIT -Rows $prob -Summary "$($prob.Count) dispositivo(s) com erro"
        foreach ($p in ($prob | Select-Object -First 10)) {
            Add-CompartDiskFinding -Severity CRIT -Area 'Dispositivos' -Message "$($p.Dispositivo): $($p.Descricao) (codigo $($p.CodigoErro))" -Recommendation 'Reinstalar ou atualizar o driver correspondente.'
        }
        $script:result = 'WARN'
    } else {
        Write-Log OK 'Nenhum dispositivo com erro no Gerenciador de Dispositivos.'
        Add-CompartDiskFinding -Severity OK -Area 'Dispositivos' -Message 'Nenhum dispositivo com codigo de erro.'
    }

    # Impressoras
    $imp = Get-CompartDiskPrinters
    if ($imp.Count -gt 0) {
        Add-CompartDiskSection -Title 'Impressoras' -Status INFO -Rows $imp
    }
}

function Show-Temperatura {
    Write-Log INFO 'Consultando sensores termicos expostos pelo firmware (ACPI)...'
    $rows = New-Object System.Collections.ArrayList

    foreach ($z in (Get-CompartDiskCim -Class MSAcpi_ThermalZoneTemperature -Namespace 'root\wmi')) {
        $c = [math]::Round(($z.CurrentTemperature / 10) - 273.15, 1)
        [void]$rows.Add([pscustomobject]@{
            Zona = $z.InstanceName; Temperatura = "$c C"; Ativa = $z.Active
        })
    }

    # Temperatura dos discos (via contadores de confiabilidade)
    foreach ($d in (Get-CompartDiskDiskInfo)) {
        if ($d.Temperatura -and "$($d.Temperatura)" -ne 'n/d') {
            [void]$rows.Add([pscustomobject]@{ Zona = "Disco: $($d.Modelo)"; Temperatura = $d.Temperatura; Ativa = 'n/a' })
        }
    }

    if ($rows.Count -eq 0) {
        # MSAcpi_ThermalZoneTemperature exige privilegio administrativo, e este modulo
        # nao o obriga (as outras cinco acoes sao leitura comum). Sem a distincao
        # abaixo, um Acesso Negado era reportado como ausencia de sensor no firmware,
        # mandando o usuario a UEFI atras de nada.
        if (-not (Test-Administrator)) {
            Write-Log WARN 'Leitura termica indisponivel: os sensores ACPI exigem privilegio administrativo.'
            Add-CompartDiskFinding -Severity INFO -Area 'Temperatura' -Message 'Sensores termicos nao consultados: execucao sem privilegio administrativo.' -Recommendation 'Reabrir o Launcher.bat como Administrador para ler os sensores ACPI.'
        } else {
            Write-Log WARN 'Nenhum sensor termico exposto por este firmware.'
            Add-CompartDiskFinding -Severity INFO -Area 'Temperatura' -Message 'Firmware nao expoe sensores termicos via ACPI/WMI.' -Recommendation 'Consultar a UEFI/BIOS ou o utilitario do fabricante.'
        }
        $script:result = 'UNSUPPORTED'
        return
    }
    $rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
    Add-CompartDiskSection -Title 'Sensores termicos' -Status OK -Rows @($rows)
    Write-Log OK "$($rows.Count) leitura(s) termica(s) obtida(s)."
}

function Show-Plataforma {
    $tpm = Test-TPM
    $sb  = Test-SecureBoot
    $hw  = Get-CompartDiskHardwareInfo
    $pares = [ordered]@{
        'Firmware'          = $sb.FirmwareType
        'Secure Boot'       = $sb.Status
        'TPM'               = "$($tpm.Version) - $($tpm.Status)"
        'TPM fabricante'    = $tpm.Manufacturer
        'Virtualizacao CPU' = $hw['Virtualizacao']
        'Hyper-V presente'  = $(try { if ((Get-CompartDiskCim -Class Win32_ComputerSystem).HypervisorPresent) { 'Sim' } else { 'Nao' } } catch { 'n/d' })
    }
    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 20 }
    Add-CompartDiskSection -Title 'Plataforma e virtualizacao' -Status OK -Pairs $pares
}

# ------------------------------------------------------------------------------
try {
    if (-not (Start-CompartDiskModule -Name 'Hardware' -Action $Action -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'Info'        { Show-Basico; Show-Plataforma }
        'Memory'      { Show-Memoria }
        'Gpu'         { Show-Gpu }
        'Devices'     { Show-Dispositivos }
        'Temperature' { Show-Temperatura }
        'Full' {
            Show-Basico
            Show-Plataforma
            Show-Memoria
            Show-Gpu
            Show-Dispositivos
            $discos = Get-CompartDiskDiskInfo
            if ($discos.Count -gt 0) {
                Write-Color ''
                $discos | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
                Add-CompartDiskSection -Title 'Discos fisicos' -Status OK -Rows $discos
            }
            $vols = Get-CompartDiskVolumeInfo
            if ($vols.Count -gt 0) { Add-CompartDiskSection -Title 'Volumes' -Status OK -Rows $vols }
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
