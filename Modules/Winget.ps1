<#
 COMPARTDISK 1.4.1 - Winget.ps1
 Desenvolvido por Edsilas
 Diagnostico e preparacao do ambiente WinGet (App Installer).
 Acoes: Menu | Status | Prepare | Repair

 ESCOPO: deixar o WinGet disponivel usando SOMENTE mecanismos oficiais do
 Windows. Duas vias, nesta ordem:

   1. Reparo local, sem download: registrar de novo o pacote AppX do App
      Installer que ja existe na maquina (Add-AppxPackage -Register). E o caso
      tipico de "winget sumiu": o pacote continua instalado e o alias de
      execucao perdeu o registro no perfil.
   2. Microsoft Store: abrir a pagina oficial do App Installer
      (ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1) para o operador concluir.

 O QUE ESTE MODULO NAO FAZ, por decisao de projeto:
   - nao baixa instalador, pacote ou winget.exe de lugar nenhum;
   - nao usa Invoke-Expression nem executa conteudo remoto;
   - nao altera politica, Defender, SmartScreen, firewall, Store ou AppX;
   - nao contorna bloqueio corporativo - detecta, informa e para.

 O diagnostico e do Core (Test-WingetAvailability): um unico dono do estado.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Status', 'Prepare', 'Repair')]
    [string]$Action = 'Menu',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Test-ModoInterativo { return (Test-CompartDiskInterativo -Quiet:$Quiet) }

# ------------------------------------------------------------------------------
# DIAGNOSTICO
# ------------------------------------------------------------------------------
function Get-WingetEnvironment {
    <# Estado completo, sempre reconsultado: e usado antes e depois de agir. #>
    [CmdletBinding()] param([switch]$ComConectividade)
    return (Test-WingetAvailability -Refresh -Completo -TestarConectividade:$ComConectividade)
}

function Get-WingetRotuloEstado {
    param([string]$Estado)
    switch ($Estado) {
        'Available'   { return 'disponivel e funcional' }
        'Outdated'    { return 'instalado, porem desatualizado' }
        'Broken'      { return 'instalado, porem nao funcional' }
        'Missing'     { return 'ausente' }
        'Blocked'     { return 'bloqueado por politica' }
        'Unsupported' { return 'nao suportado por este Windows' }
        default       { return 'estado desconhecido' }
    }
}

function Get-WingetCorEstado {
    param([string]$Estado)
    switch ($Estado) {
        'Available'   { return [ConsoleColor]::Green }
        'Outdated'    { return [ConsoleColor]::Yellow }
        'Broken'      { return [ConsoleColor]::Yellow }
        'Missing'     { return [ConsoleColor]::Yellow }
        default       { return [ConsoleColor]::Red }
    }
}

function Write-WingetDiagnostico {
    <# Ficha de diagnostico. Sem dado sensivel: so versao, build e estado. #>
    param([Parameter(Mandatory)][object]$Env)

    Write-Color ''
    Write-Color '  DIAGNOSTICO DO AMBIENTE WINGET' -Color White
    Write-Color ("  " + ('-' * 74)) -Color DarkGray
    Write-Color ''

    $so = 'n/d'; $build = 'n/d'; $arq = 'n/d'
    if ($Env.Windows) {
        $so    = $Env.Windows.Caption
        $build = $Env.Windows.FullBuild
        $arq   = $Env.Windows.Architecture
    }
    Write-CompartDiskKeyValue 'Windows'       $so    -Pad 16
    Write-CompartDiskKeyValue 'Build'         $build -Pad 16
    Write-CompartDiskKeyValue 'Arquitetura'   $arq   -Pad 16
    Write-CompartDiskKeyValue 'Administrador' $(if ($Env.Admin) { 'sim' } else { 'nao' }) -Pad 16
    Write-CompartDiskKeyValue 'App Installer' $Env.AppInstaller -Pad 16
    if ($Env.AppInstallerVersion) { Write-CompartDiskKeyValue 'Versao do pacote' $Env.AppInstallerVersion -Pad 16 }
    if ($Env.PackageStatus)       { Write-CompartDiskKeyValue 'Estado do pacote' $Env.PackageStatus -Pad 16 }
    Write-CompartDiskKeyValue 'winget.exe'    $(if ($Env.Executable) { $Env.Executable } else { 'nao encontrado' }) -Pad 16
    Write-CompartDiskKeyValue 'Versao'        $(if ($Env.VersionText) { $Env.VersionText } else { 'n/d' }) -Pad 16
    Write-CompartDiskKeyValue 'Fonte oficial' $(
        if ($null -eq $Env.SourcesOk) { 'nao verificada' } elseif ($Env.SourcesOk) { 'disponivel' } else { 'indisponivel' }) -Pad 16
    Write-CompartDiskKeyValue 'Microsoft Store' $(
        if ($null -eq $Env.StoreAvailable) { 'nao verificada' } elseif ($Env.StoreAvailable) { 'disponivel' } else { 'indisponivel' }) -Pad 16
    Write-CompartDiskKeyValue 'Politica'      $(if ($Env.PolicyBlocked) { $Env.PolicyDetail } else { 'sem bloqueio detectado' }) -Pad 16
    if ($null -ne $Env.Online) { Write-CompartDiskKeyValue 'Conectividade' $(if ($Env.Online) { 'disponivel' } else { 'indisponivel' }) -Pad 16 }

    Write-Color ''
    Write-Color ("  Resultado      : {0}" -f (Get-WingetRotuloEstado $Env.State)) -Color (Get-WingetCorEstado $Env.State)
    if ($Env.Reason) { Write-Color ("  {0}" -f $Env.Reason) -Color DarkGray }
    Write-Color ''

    Write-Log INFO ("Diagnostico WinGet | SO={0} | Build={1} | Arq={2} | AppInstaller={3} | Versao={4} | Estado={5} | Motivo={6}" -f `
        $so, $build, $arq, $Env.AppInstaller, $(if ($Env.VersionText) { $Env.VersionText } else { 'n/d' }), $Env.State, $Env.Reason) -NoConsole
    foreach ($linha in $Env.Detail) { Write-Log DEBUG ("  {0}" -f $linha) -NoConsole }
}

function Add-WingetSecao {
    <# Publica o diagnostico nas secoes que alimentam os relatorios. #>
    param([Parameter(Mandatory)][object]$Env, [string]$Titulo = 'Ambiente WinGet')
    $status = switch ($Env.State) { 'Available' { 'OK' } 'Outdated' { 'WARN' } 'Unknown' { 'WARN' } default { 'WARN' } }
    Add-CompartDiskSection -Title $Titulo -Status $status -Summary $Env.Reason -Pairs ([ordered]@{
        'Estado'          = $Env.State
        'Windows'         = $(if ($Env.Windows) { $Env.Windows.Caption } else { 'n/d' })
        'Build'           = $(if ($Env.Windows) { $Env.Windows.FullBuild } else { 'n/d' })
        'Arquitetura'     = $(if ($Env.Windows) { $Env.Windows.Architecture } else { 'n/d' })
        'App Installer'   = $Env.AppInstaller
        'Versao do pacote'= $(if ($Env.AppInstallerVersion) { $Env.AppInstallerVersion } else { 'n/d' })
        'winget.exe'      = $(if ($Env.Executable) { 'encontrado' } else { 'nao encontrado' })
        'Versao'          = $(if ($Env.VersionText) { $Env.VersionText } else { 'n/d' })
        'Fonte oficial'   = $(if ($null -eq $Env.SourcesOk) { 'nao verificada' } elseif ($Env.SourcesOk) { 'disponivel' } else { 'indisponivel' })
        'Microsoft Store' = $(if ($null -eq $Env.StoreAvailable) { 'nao verificada' } elseif ($Env.StoreAvailable) { 'disponivel' } else { 'indisponivel' })
        'Politica'        = $(if ($Env.PolicyBlocked) { $Env.PolicyDetail } else { 'sem bloqueio detectado' })
        'Motivo'          = $Env.Reason
    })
}

# ------------------------------------------------------------------------------
# VALIDACAO POS-OPERACAO
# ------------------------------------------------------------------------------
function Test-WingetHealth {
    <# Bateria de validacao. Terminar sem erro NAO e prova de que o WinGet ficou
       utilizavel: cada etapa e exercitada de verdade e reportada. #>
    [CmdletBinding()] param([switch]$Silencioso)

    $env2 = Get-WingetEnvironment
    $etapas = New-Object System.Collections.ArrayList
    $ok = $true

    function Etapa { param([string]$Nome, [bool]$Passou, [string]$Detalhe = '')
        [void]$etapas.Add([pscustomobject]@{ Etapa = $Nome; Passou = $Passou; Detalhe = $Detalhe })
        if (-not $Silencioso) {
            if ($Passou) { Write-Log OK ("{0}{1}" -f $Nome, $(if ($Detalhe) { ": $Detalhe" } else { '' })) }
            else         { Write-Log WARN ("{0}{1}" -f $Nome, $(if ($Detalhe) { ": $Detalhe" } else { '' })) }
        }
    }

    # 1. pacote
    Etapa 'App Installer detectado' ($env2.AppInstaller -eq 'Presente') $env2.AppInstallerVersion
    if ($env2.AppInstaller -ne 'Presente') { $ok = $false }

    # 2. executavel
    $temExe = [bool]$env2.Executable
    Etapa 'WinGet encontrado' $temExe $env2.Executable
    if (-not $temExe) {
        $ok = $false
        return [pscustomobject]@{ Ok = $false; Etapas = $etapas; Env = $env2 }
    }

    # 3. versao
    $temVer = [bool]$env2.VersionText
    Etapa 'Versao' $temVer $env2.VersionText
    if (-not $temVer) { $ok = $false }

    # 4. inicializacao completa (--info)
    $infoOk = $false
    try { $infoOk = ((Invoke-NativeCommand -FilePath $env2.Executable -Arguments @('--info') -TimeoutSeconds 60).ExitCode -eq 0) } catch { }
    Etapa 'Inicializacao (--info)' $infoOk
    if (-not $infoOk) { $ok = $false }

    # 5. fontes
    $fontesOk = [bool]$env2.SourcesOk
    Etapa 'Fontes disponiveis' $fontesOk
    if (-not $fontesOk) { $ok = $false }

    # 6. consulta de teste - local, nao depende de internet
    $consultaOk = $false
    try {
        $c = Invoke-NativeCommand -FilePath $env2.Executable `
             -Arguments @('list', '--id', $env2.PackageName, '--exact', '--accept-source-agreements') -TimeoutSeconds 120
        # 0 = achou; codigo de "nada encontrado" tambem prova que o motor de
        # consulta respondeu. Falha de execucao e que reprova a etapa.
        $consultaOk = ($c.ExitCode -eq 0 -or ($c.StdOut -and $c.StdOut.Trim().Length -gt 0))
    } catch { }
    Etapa 'Consulta de teste concluida' $consultaOk
    if (-not $consultaOk) { $ok = $false }

    return [pscustomobject]@{ Ok = $ok; Etapas = $etapas; Env = $env2 }
}

# ------------------------------------------------------------------------------
# ACOES OFICIAIS
# ------------------------------------------------------------------------------
function Repair-WingetSupport {
    <# Registra de novo o pacote AppX que ja esta na maquina. Sem download.
       Requer os cmdlets Appx (PowerShell); em Batch puro isto nao existe. #>
    [CmdletBinding()] param()

    $saida = [pscustomobject]@{ Executado = $false; Sucesso = $false; Metodo = ''; Mensagem = '' }

    if (-not (Test-CompartDiskCommand 'Add-AppxPackage')) { $null = Import-CompartDiskModule 'Appx' }
    if (-not (Test-CompartDiskCommand 'Add-AppxPackage')) {
        $saida.Mensagem = 'Cmdlets AppX indisponiveis neste motor: o reparo exige PowerShell com o modulo Appx.'
        Write-Log WARN $saida.Mensagem
        return $saida
    }

    # Caminho 1: registrar pelo manifesto do pacote instalado.
    $pacotes = @()
    try {
        $pacotes = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
        if (-not $pacotes -and (Test-Administrator)) {
            $pacotes = @(Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
        }
    } catch { Write-Log DEBUG ("Consulta de pacotes falhou: {0}" -f $_.Exception.Message) -NoConsole }

    foreach ($p in $pacotes) {
        $manifesto = $null
        try { if ($p.InstallLocation) { $manifesto = Join-Path $p.InstallLocation 'AppXManifest.xml' } } catch { }
        if (-not $manifesto -or -not (Test-Path -LiteralPath $manifesto)) { continue }
        $saida.Executado = $true
        $saida.Metodo    = 'Add-AppxPackage -Register (manifesto local)'
        Write-Log INFO ('Registrando novamente o App Installer a partir do manifesto local (versao {0})...' -f $p.Version)
        $r = Invoke-SafeCommand -Activity 'Registrar App Installer' -ScriptBlock {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifesto -ErrorAction Stop
        }
        if ($r.Success) { $saida.Sucesso = $true; return $saida }
        $saida.Mensagem = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha ao registrar' })
    }

    # Caminho 2: registrar pela familia do pacote (util quando o manifesto nao e
    # acessivel, mas o pacote esta provisionado na imagem).
    $saida.Executado = $true
    $saida.Metodo    = 'Add-AppxPackage -RegisterByFamilyName'
    Write-Log INFO 'Tentando registrar o App Installer pela familia do pacote...'
    $r2 = Invoke-SafeCommand -Activity 'Registrar App Installer pela familia' -ScriptBlock {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
    }
    if ($r2.Success) { $saida.Sucesso = $true; return $saida }
    if ($r2.Error) { $saida.Mensagem = $r2.Error.Exception.Message }
    return $saida
}

function Install-WingetSupport {
    <# Encaminha para a pagina oficial do App Installer na Microsoft Store.
       E o unico caminho oficial de INSTALACAO que nao envolve baixar pacote por
       fora do Windows - e ele exige a acao do operador na janela da Store. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env)

    $saida = [pscustomobject]@{ Executado = $false; Sucesso = $false; Metodo = ''; Mensagem = '' }

    if ($Env.StoreAvailable -eq $false) {
        $saida.Mensagem = 'Microsoft Store indisponivel ou removida por politica neste computador.'
        return $saida
    }

    $uri = 'ms-windows-store://pdp/?ProductId={0}' -f $Env.StoreProductId
    $saida.Metodo = 'Microsoft Store (App Installer, ProductId ' + $Env.StoreProductId + ')'
    $r = Invoke-SafeCommand -Activity 'Abrir a Microsoft Store no App Installer' -ScriptBlock {
        Start-Process $uri -ErrorAction Stop
    }
    $saida.Executado = $true
    $saida.Sucesso   = $r.Success
    if (-not $r.Success -and $r.Error) { $saida.Mensagem = $r.Error.Exception.Message }
    return $saida
}

function Update-WingetSupport {
    <# Encaminha para a tela oficial de atualizacoes da Store. Nao force a
       atualizacao: quem decide o momento e o Windows, com as politicas em vigor. #>
    [CmdletBinding()] param()
    $saida = [pscustomobject]@{ Executado = $false; Sucesso = $false; Metodo = 'Microsoft Store (Downloads e atualizacoes)'; Mensagem = '' }
    $r = Invoke-SafeCommand -Activity 'Abrir atualizacoes da Microsoft Store' -ScriptBlock {
        Start-Process 'ms-windows-store://downloadsandupdates' -ErrorAction Stop
    }
    $saida.Executado = $true
    $saida.Sucesso   = $r.Success
    if (-not $r.Success -and $r.Error) { $saida.Mensagem = $r.Error.Exception.Message }
    return $saida
}

function Initialize-Winget {
    <# Orquestra: diagnostica, escolhe o metodo oficial adequado ao estado, age e
       valida. Nunca afirma sucesso sem a bateria de validacao passar. #>
    [CmdletBinding()] param([switch]$SomenteReparo)

    $env1 = Get-WingetEnvironment
    Write-WingetDiagnostico -Env $env1

    switch ($env1.State) {
        'Available' {
            Write-Log OK 'WinGet ja esta disponivel e funcional. Nada a fazer.'
            return [pscustomobject]@{ Estado = 'Available'; Alterou = $false; Ok = $true; Env = $env1 }
        }
        'Unsupported' {
            Write-Log WARN 'Este Windows nao atende aos requisitos necessarios para disponibilizar o WinGet.'
            Write-Color '  Nenhuma alteracao foi realizada.' -Color DarkGray
            return [pscustomobject]@{ Estado = 'Unsupported'; Alterou = $false; Ok = $false; Env = $env1 }
        }
        'Blocked' {
            Write-Log WARN 'A politica deste computador impede a instalacao ou o uso do App Installer.'
            Write-Color '  Contate o administrador responsavel. Nenhuma politica foi alterada.' -Color DarkGray
            return [pscustomobject]@{ Estado = 'Blocked'; Alterou = $false; Ok = $false; Env = $env1 }
        }
    }

    # A partir daqui: Broken, Missing, Outdated ou Unknown.
    #
    # O caminho da Microsoft Store abre uma janela e depende do operador concluir
    # a instalacao. Em execucao desassistida isso nao serve para nada e ainda
    # deixaria a maquina com uma janela aberta: nesse modo, so o reparo local
    # (silencioso e verificavel) e tentado, e a limitacao e declarada.
    $interativo  = Test-ModoInterativo
    $versaoAntes = $env1.AppInstallerVersion
    $acao = $null

    if ($env1.State -eq 'Outdated') {
        if (-not $interativo) {
            Write-Log WARN 'App Installer desatualizado. A atualizacao passa pela Microsoft Store e exige um operador; nada foi alterado.'
            return [pscustomobject]@{ Estado = $env1.State; Alterou = $false; Ok = $false; Env = $env1; Pendente = $true }
        }
        Write-Log INFO 'App Installer presente, porem desatualizado. Encaminhando para a atualizacao oficial da Store.'
        $acao = Update-WingetSupport
    }
    elseif ($env1.Registered -or $env1.Provisioned -or $env1.AppInstaller -eq 'Presente') {
        Write-Log INFO 'App Installer presente: reparando o registro do pacote, sem baixar nada.'
        $acao = Repair-WingetSupport
        if (-not $acao.Sucesso -and -not $SomenteReparo) {
            if ($interativo) {
                Write-Log WARN 'O reparo local nao resolveu. Encaminhando para a pagina oficial na Microsoft Store.'
                $acao = Install-WingetSupport -Env $env1
            } else {
                Write-Log WARN 'O reparo local nao resolveu. O proximo passo oficial e a Microsoft Store, que exige um operador.'
            }
        }
    }
    else {
        if ($SomenteReparo) {
            Write-Log WARN 'Nao ha pacote local para reparar. A instalacao depende da Microsoft Store.'
            return [pscustomobject]@{ Estado = $env1.State; Alterou = $false; Ok = $false; Env = $env1 }
        }
        # Antes da Store, uma ultima tentativa local: o pacote pode estar
        # provisionado na imagem e apenas nao registrado para este usuario.
        $acao = Repair-WingetSupport
        if (-not $acao.Sucesso) {
            if ($interativo) {
                Write-Log INFO 'Encaminhando para a pagina oficial do App Installer na Microsoft Store.'
                $acao = Install-WingetSupport -Env $env1
            } else {
                Write-Log WARN 'Sem pacote local para registrar. A instalacao pela Microsoft Store exige um operador; nada foi alterado.'
                return [pscustomobject]@{ Estado = $env1.State; Alterou = $false; Ok = $false; Env = $env1; Pendente = $true }
            }
        }
    }

    if ($acao -and $acao.Metodo) { Write-Log INFO ('Metodo utilizado: {0}' -f $acao.Metodo) }

    if ($acao -and -not $acao.Sucesso) {
        Write-Log ERR 'Nao foi possivel disponibilizar o WinGet por um metodo oficial neste ambiente.'
        if ($acao.Mensagem) { Write-Color ("  Motivo : {0}" -f $acao.Mensagem) -Color DarkGray }
        Write-Color '  Nenhuma alteracao insegura foi realizada.' -Color DarkGray
        $envF = Get-WingetEnvironment
        return [pscustomobject]@{ Estado = $envF.State; Alterou = $false; Ok = $false; Env = $envF; Metodo = $acao.Metodo }
    }

    # Encaminhamento para a Store nao conclui sozinho: depende do operador.
    if ($acao -and $acao.Metodo -like 'Microsoft Store*') {
        Write-Color ''
        Write-Log INFO 'A Microsoft Store foi aberta na pagina do App Installer.'
        Write-Color '  Conclua a instalacao na janela da Store e use "Verificar novamente".' -Color Gray
        $envF = Get-WingetEnvironment
        return [pscustomobject]@{ Estado = $envF.State; Alterou = $false; Ok = ($envF.State -eq 'Available'); Env = $envF; Metodo = $acao.Metodo; Pendente = $true }
    }

    # Reparo local executado: validar de verdade.
    Write-Color ''
    Write-Log INFO 'Validando o resultado...'
    $saude = Test-WingetHealth
    $envF  = $saude.Env
    if ($versaoAntes -or $envF.AppInstallerVersion) {
        Write-Log INFO ('Versao do App Installer antes: {0} | depois: {1}' -f `
            $(if ($versaoAntes) { $versaoAntes } else { 'n/d' }),
            $(if ($envF.AppInstallerVersion) { $envF.AppInstallerVersion } else { 'n/d' })) -NoConsole
    }

    if ($saude.Ok -and $envF.State -eq 'Available') {
        Write-Color ''
        Write-Log OK 'WinGet esta pronto para uso.'
        return [pscustomobject]@{ Estado = 'Available'; Alterou = $true; Ok = $true; Env = $envF; Metodo = $acao.Metodo }
    }

    Write-Color ''
    Write-Log WARN 'A operacao terminou, mas o WinGet ainda nao passou na validacao.'
    return [pscustomobject]@{ Estado = $envF.State; Alterou = $true; Ok = $false; Env = $envF; Metodo = $acao.Metodo }
}

# ------------------------------------------------------------------------------
# INTERFACE - somente numerica
# ------------------------------------------------------------------------------
function Write-WingetCabecalho {
    param([string]$Titulo)
    Write-Color ''
    Write-Color ("  {0}" -f $Titulo) -Color White
    Write-Color ("  " + ('-' * 74)) -Color DarkGray
    Write-Color ''
}

function Show-WingetPronto {
    <# Reintegracao: com o WinGet pronto, a saida natural e voltar aos aplicativos. #>
    param([object]$Env)
    Write-WingetCabecalho 'WINGET DISPONIVEL'
    Write-Log OK 'WinGet preparado e validado.'
    if ($Env -and $Env.VersionText) { Write-Color ("       Versao: {0}" -f $Env.VersionText) -Color DarkGray }
    Write-Color ''
    Write-Color '  [1] Continuar para aplicativos' -Color Cyan
    Write-Color '  [0] Voltar' -Color DarkGray
    Write-Color ''
    if (-not (Test-ModoInterativo)) { return 0 }
    return (Read-CompartDiskOpcao -Maximo 1)
}

function Show-WingetMenu {
    <# Tela principal do modulo. O texto e as opcoes mudam conforme o estado. #>
    while ($true) {
        $env1 = Get-WingetEnvironment
        Write-WingetDiagnostico -Env $env1

        if ($env1.State -eq 'Available') {
            Write-WingetCabecalho 'WINGET DISPONIVEL'
            Write-Log OK ('WinGet disponivel (versao {0}).' -f $(if ($env1.VersionText) { $env1.VersionText } else { 'n/d' }))
            Write-Color ''
            Write-Color '  [1] Verificar novamente' -Color Cyan
            Write-Color '  [0] Voltar' -Color DarkGray
            Write-Color ''
            if (-not (Test-ModoInterativo)) { return $env1 }
            $o = Read-CompartDiskOpcao -Maximo 1
            if ($o -eq 0) { return $env1 }
            continue
        }

        if ($env1.State -eq 'Unsupported' -or $env1.State -eq 'Blocked') {
            $titulo = $(if ($env1.State -eq 'Unsupported') { 'WINGET NAO SUPORTADO' } else { 'WINGET BLOQUEADO POR POLITICA' })
            Write-WingetCabecalho $titulo
            Write-Color ("  {0}" -f $env1.Reason) -Color Yellow
            Write-Color ''
            if ($env1.State -eq 'Blocked') {
                Write-Color '  Contate o administrador responsavel. O COMPARTDISK nao altera politica' -Color DarkGray
                Write-Color '  para contornar esse bloqueio.' -Color DarkGray
            } else {
                Write-Color '  Nenhuma alteracao foi realizada.' -Color DarkGray
            }
            Write-Color ''
            Write-Color '  [1] Verificar novamente' -Color Cyan
            Write-Color '  [0] Voltar' -Color DarkGray
            Write-Color ''
            if (-not (Test-ModoInterativo)) { return $env1 }
            $o = Read-CompartDiskOpcao -Maximo 1
            if ($o -eq 0) { return $env1 }
            continue
        }

        # Missing | Broken | Outdated | Unknown
        $ehReparo = ($env1.State -eq 'Broken' -or $env1.State -eq 'Outdated')
        Write-WingetCabecalho $(if ($ehReparo) { 'PROBLEMA NO WINGET' } else { 'WINGET NAO DISPONIVEL' })
        Write-Color ("  Estado detectado: {0}." -f (Get-WingetRotuloEstado $env1.State)) -Color Yellow
        Write-Color ''
        if ($ehReparo) {
            Write-Color '  [1] Reparar / atualizar WinGet' -Color Cyan
        } else {
            Write-Color '  [1] Instalar / preparar WinGet' -Color Cyan
        }
        Write-Color '  [2] Verificar novamente' -Color Cyan
        Write-Color '  [0] Voltar' -Color DarkGray
        Write-Color ''

        if (-not (Test-ModoInterativo)) { return $env1 }
        $opc = Read-CompartDiskOpcao -Maximo 2
        if ($opc -eq 0) { return $env1 }
        if ($opc -eq 2) { continue }

        $res = Initialize-Winget
        Add-WingetSecao -Env $res.Env -Titulo 'Preparacao do WinGet'
        if ($res.Ok) {
            $script:result = 'OK'
            $c = Show-WingetPronto -Env $res.Env
            if ($c -eq 1) { return $res.Env }
            return $res.Env
        }
        if ($script:result -eq 'OK') { $script:result = 'WARN' }
        Write-Color ''
        Write-Color '  [1] Verificar novamente' -Color Cyan
        Write-Color '  [0] Voltar' -Color DarkGray
        Write-Color ''
        $o2 = Read-CompartDiskOpcao -Maximo 1
        if ($o2 -eq 0) { return $res.Env }
    }
}

# ------------------------------------------------------------------------------
# EXECUCAO
# ------------------------------------------------------------------------------
try {
    if (-not (Start-CompartDiskModule -Name 'Winget' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }

    switch ($Action) {

        'Status' {
            $e = Get-WingetEnvironment -ComConectividade
            Write-WingetDiagnostico -Env $e
            Add-WingetSecao -Env $e
            switch ($e.State) {
                'Available' { $result = 'OK' }
                'Unsupported' { $result = 'UNSUPPORTED'
                    Add-CompartDiskFinding -Severity WARN -Area 'WinGet' -Message $e.Reason }
                'Blocked' { $result = 'UNSUPPORTED'
                    Add-CompartDiskFinding -Severity WARN -Area 'WinGet' -Message $e.Reason -Recommendation 'Politica corporativa: contatar o administrador.' }
                default   { $result = 'WARN'
                    Add-CompartDiskFinding -Severity WARN -Area 'WinGet' -Message $e.Reason -Recommendation 'Usar a opcao "Verificar / preparar WinGet" no menu de aplicativos.' }
            }
        }

        'Prepare' {
            $res = Initialize-Winget
            Add-WingetSecao -Env $res.Env -Titulo 'Preparacao do WinGet'
            if ($res.Ok) { $result = 'OK' }
            elseif ($res.Estado -eq 'Unsupported' -or $res.Estado -eq 'Blocked') { $result = 'UNSUPPORTED' }
            elseif ($res.Pendente) { $result = 'WARN' }
            else { $result = 'ERROR'
                Add-CompartDiskFinding -Severity WARN -Area 'WinGet' -Message ('Nao foi possivel disponibilizar o WinGet: {0}' -f $res.Env.Reason) }
        }

        'Repair' {
            $res = Initialize-Winget -SomenteReparo
            Add-WingetSecao -Env $res.Env -Titulo 'Reparo do WinGet'
            if ($res.Ok) { $result = 'OK' }
            elseif ($res.Estado -eq 'Unsupported' -or $res.Estado -eq 'Blocked') { $result = 'UNSUPPORTED' }
            else { $result = 'WARN' }
        }

        'Menu' {
            if (-not (Test-ModoInterativo)) {
                # Determinismo em execucao desassistida: nada de menu, nada de
                # acao implicita. As acoes automatizaveis sao Status/Prepare/Repair.
                $e = Get-WingetEnvironment
                Write-WingetDiagnostico -Env $e
                Add-WingetSecao -Env $e
                Write-Log WARN 'Acao Menu exige console interativo. Em automacao use -Action Status/-Prepare/-Repair.'
                $result = $(if ($e.State -eq 'Available') { 'OK' } else { 'UNSUPPORTED' })
                break
            }
            $e = Show-WingetMenu
            Add-WingetSecao -Env $e
            if ($result -eq 'OK' -and $e.State -ne 'Available') { $result = 'WARN' }
        }
    }

} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Winget (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'WinGet' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
