<#
 COMPARTDISK 1.5.1 - Winget.ps1
 Desenvolvido por Edsilas
 Diagnostico e preparacao do ambiente WinGet (App Installer).
 Acoes: Menu | Status | Prepare | Repair

 ESCOPO: deixar o WinGet disponivel usando SOMENTE mecanismos e fontes oficiais
 da Microsoft. O modulo nao aplica uma tentativa fixa: ele diagnostica, descobre
 QUAL cenario ocorreu e monta um plano de camadas condicionado a esse
 diagnostico. Cada camada tem proposito tecnico proprio; nenhuma repete a
 anterior.

 Camadas, na ordem em que fazem sentido (as inaplicaveis nem entram no plano):

   1. PATH / alias de execucao - o winget existe e nao e alcancavel pelo PATH.
      Corrige a variavel do processo e a do usuario. Sem download.
   2. Fontes - o winget executa, mas a fonte oficial nao responde:
      "winget source reset --force" e "winget source update".
   3. Dependencias - as bibliotecas de runtime do App Installer estao ausentes
      (causa dominante no Windows 10). Repostas pelo pacote oficial da Microsoft.
   4. Registro do pacote - o App Installer esta na maquina e perdeu o registro
      no perfil: Add-AppxPackage -Register, pelo manifesto local, pela imagem do
      Windows ou pela familia do pacote. Sem download.
   5. Microsoft.WinGet.Client - modulo OFICIAL da Microsoft, quando ja instalado
      nesta maquina: Repair-WinGetPackageManager.
   6. Pacote oficial - msixbundle publicado pela Microsoft em
      github.com/microsoft/winget-cli (ou aka.ms/getwinget), conferido por SHA256
      publicado e por assinatura digital antes de ser instalado. E a via que
      dispensa a Microsoft Store.
   7. Microsoft Store - pagina oficial do App Installer. Ultima camada: depende
      de um operador concluir na janela da Store.

 O QUE ESTE MODULO NAO FAZ, por decisao de projeto:
   - nao baixa nada fora dos dominios oficiais (aka.ms, microsoft.com,
     github.com/microsoft, githubusercontent.com), sempre por HTTPS;
   - nao instala pacote sem conferir SHA256 publicado e/ou assinatura da Microsoft;
   - nao usa Invoke-Expression nem executa conteudo remoto;
   - nao altera politica, Defender, SmartScreen, firewall, Store ou AppX;
   - nao contorna bloqueio corporativo - detecta, informa e para.

 MOTOR: nada aqui depende de PowerShell 7. As operacoes AppX rodam em processo
 no Windows PowerShell e, sob pwsh, sao reencaminhadas ao Windows PowerShell 5.1
 por Invoke-CompartDiskAppxScript (Core.ps1), onde esses cmdlets funcionam.

 O diagnostico e do Core (Test-WingetAvailability): um unico dono do estado.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Status', 'Prepare', 'Repair')]
    [string]$Action = 'Menu',
    [switch]$Quiet,
    # Ambiente em que baixar pacote nao e desejado (link tarifado, rede isolada,
    # politica interna). Sem ele o comportamento e o de sempre; com ele as
    # camadas locais continuam valendo e so as que dependem de download saem do
    # plano, com o motivo declarado.
    [switch]$SemDownload
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

$script:Trilha        = New-Object System.Collections.ArrayList
$script:RedeIniciada  = $false
$script:TempRaiz      = $null
$script:OrigemOficial = $null
$script:PathAjustado  = $false

# Fontes oficiais. Sao constantes do modulo: nenhum endereco vem de fora.
$script:WingetOficial = @{
    ApiRelease  = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
    Bundle      = 'https://aka.ms/getwinget'
    VCLibs      = 'https://aka.ms/Microsoft.VCLibs.{0}.14.00.Desktop.appx'
    StorePagina = 'ms-windows-store://pdp/?ProductId={0}'
    StoreUpdate = 'ms-windows-store://downloadsandupdates'
}
# Dominios aceitos para download. A verificacao e por sufixo de dominio e exige
# HTTPS: um endereco fora desta lista e recusado antes de qualquer requisicao.
$script:WingetHostsOficiais = @('aka.ms', 'microsoft.com', 'github.com', 'githubusercontent.com')

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

function Get-WingetMotorAppx {
    <# Onde as operacoes AppX vao rodar. Serve ao diagnostico: em maquina sem
       Windows PowerShell e sem cmdlets Appx, a camada de registro nao existe e
       isso precisa aparecer na ficha, nao virar uma falha inexplicada. #>
    [CmdletBinding()] param()
    if (-not (Test-CompartDiskCommand 'Get-AppxPackage')) { $null = Import-CompartDiskModule 'Appx' }
    $temAppx = Test-CompartDiskCommand 'Get-AppxPackage'
    $wps     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $temWps  = Test-Path -LiteralPath $wps

    if ($temAppx -and $PSVersionTable.PSVersion.Major -lt 6) { return 'Windows PowerShell (em processo)' }
    if ($temWps)  { return 'Windows PowerShell 5.1 (processo auxiliar)' }
    if ($temAppx) { return ('PowerShell {0} (em processo)' -f $PSVersionTable.PSVersion.Major) }
    return 'indisponivel'
}

function Get-WingetResumoDependencias {
    param([object]$Env)
    if (-not $Env.Dependencies -or @($Env.Dependencies).Count -eq 0) { return 'nao verificadas' }
    $faltando = @($Env.Dependencies | Where-Object { -not $_.Presente } | ForEach-Object { $_.Nome })
    if ($faltando.Count -eq 0) { return 'presentes' }
    return ('ausentes: {0}' -f ($faltando -join ', '))
}

function Get-WingetArquitetura {
    <# x64 | x86 | arm64. PROCESSOR_ARCHITECTURE diz "x86" quando o proprio
       processo e de 32 bits num Windows de 64 - PROCESSOR_ARCHITEW6432 e quem
       responde pelo sistema nesse caso. #>
    [CmdletBinding()] param()
    $a = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($a)) { $a = $env:PROCESSOR_ARCHITECTURE }
    switch ("$a".ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'X86'   { return 'x86' }
        default { if ([Environment]::Is64BitOperatingSystem) { return 'x64' } else { return 'x86' } }
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
    if ($Env.PackageScope -and $Env.PackageScope -ne 'nao encontrado') {
        Write-CompartDiskKeyValue 'Onde esta' $Env.PackageScope -Pad 16
    }
    Write-CompartDiskKeyValue 'winget.exe'    $(if ($Env.Executable) { $Env.Executable } else { 'nao encontrado' }) -Pad 16
    Write-CompartDiskKeyValue 'Encontrado por' $Env.ExecutableOrigin -Pad 16
    Write-CompartDiskKeyValue 'Alias exec.'   $Env.AliasState -Pad 16
    Write-CompartDiskKeyValue 'Versao'        $(if ($Env.VersionText) { $Env.VersionText } else { 'n/d' }) -Pad 16
    Write-CompartDiskKeyValue 'Dependencias'  (Get-WingetResumoDependencias -Env $Env) -Pad 16
    Write-CompartDiskKeyValue 'Fonte oficial' $(
        if ($null -eq $Env.SourcesOk) { 'nao verificada' } elseif ($Env.SourcesOk) { 'disponivel' } else { 'indisponivel' }) -Pad 16
    Write-CompartDiskKeyValue 'Microsoft Store' $(
        if ($null -eq $Env.StoreAvailable) { 'nao verificada' } elseif ($Env.StoreAvailable) { 'disponivel' } else { 'indisponivel' }) -Pad 16
    Write-CompartDiskKeyValue 'Politica'      $(if ($Env.PolicyBlocked) { $Env.PolicyDetail } else { 'sem bloqueio detectado' }) -Pad 16
    if ($Env.SideloadBlocked) { Write-CompartDiskKeyValue 'Sideload MSIX' 'bloqueado por politica' -Pad 16 }
    Write-CompartDiskKeyValue 'Motor AppX'    (Get-WingetMotorAppx) -Pad 16
    if ($null -ne $Env.Online) { Write-CompartDiskKeyValue 'Conectividade' $(if ($Env.Online) { 'disponivel' } else { 'indisponivel' }) -Pad 16 }
    if ($Env.LastError) { Write-CompartDiskKeyValue 'Ultimo erro' $Env.LastError -Pad 16 }

    Write-Color ''
    Write-Color ("  Resultado      : {0}" -f (Get-WingetRotuloEstado $Env.State)) -Color (Get-WingetCorEstado $Env.State)
    if ($Env.Reason) { Write-Color ("  {0}" -f $Env.Reason) -Color DarkGray }
    Write-Color ''

    Write-Log INFO ("Diagnostico WinGet | SO={0} | Build={1} | Arq={2} | AppInstaller={3} | Escopo={4} | Versao={5} | Origem={6} | Alias={7} | Deps={8} | Estado={9} | Motivo={10}" -f `
        $so, $build, $arq, $Env.AppInstaller, $Env.PackageScope, $(if ($Env.VersionText) { $Env.VersionText } else { 'n/d' }), `
        $Env.ExecutableOrigin, $Env.AliasState, (Get-WingetResumoDependencias -Env $Env), $Env.State, $Env.Reason) -NoConsole
    if ($Env.LastError) { Write-Log INFO ("Erro tecnico registrado no diagnostico: {0}" -f $Env.LastError) -NoConsole }
    foreach ($linha in $Env.Detail) { Write-Log DEBUG ("  {0}" -f $linha) -NoConsole }
}

function Add-WingetSecao {
    <# Publica o diagnostico nas secoes que alimentam os relatorios. A trilha de
       tentativas vai junto: o relatorio precisa mostrar o que foi tentado, nao
       so onde a maquina parou. #>
    param([Parameter(Mandatory)][object]$Env, [string]$Titulo = 'Ambiente WinGet')
    $status = switch ($Env.State) { 'Available' { 'OK' } 'Outdated' { 'WARN' } 'Unknown' { 'WARN' } default { 'WARN' } }
    Add-CompartDiskSection -Title $Titulo -Status $status -Summary $Env.Reason -Rows @($script:Trilha) -Pairs ([ordered]@{
        'Estado'          = $Env.State
        'Windows'         = $(if ($Env.Windows) { $Env.Windows.Caption } else { 'n/d' })
        'Build'           = $(if ($Env.Windows) { $Env.Windows.FullBuild } else { 'n/d' })
        'Arquitetura'     = $(if ($Env.Windows) { $Env.Windows.Architecture } else { 'n/d' })
        'App Installer'   = $Env.AppInstaller
        'Onde esta'       = $Env.PackageScope
        'Versao do pacote'= $(if ($Env.AppInstallerVersion) { $Env.AppInstallerVersion } else { 'n/d' })
        'winget.exe'      = $(if ($Env.Executable) { 'encontrado' } else { 'nao encontrado' })
        'Encontrado por'  = $Env.ExecutableOrigin
        'Alias de execucao' = $Env.AliasState
        'Versao'          = $(if ($Env.VersionText) { $Env.VersionText } else { 'n/d' })
        'Dependencias'    = (Get-WingetResumoDependencias -Env $Env)
        'Fonte oficial'   = $(if ($null -eq $Env.SourcesOk) { 'nao verificada' } elseif ($Env.SourcesOk) { 'disponivel' } else { 'indisponivel' })
        'Microsoft Store' = $(if ($null -eq $Env.StoreAvailable) { 'nao verificada' } elseif ($Env.StoreAvailable) { 'disponivel' } else { 'indisponivel' })
        'Politica'        = $(if ($Env.PolicyBlocked) { $Env.PolicyDetail } else { 'sem bloqueio detectado' })
        'Sideload MSIX'   = $(if ($Env.SideloadBlocked) { 'bloqueado por politica' } else { 'permitido' })
        'Motor AppX'      = (Get-WingetMotorAppx)
        'Erro tecnico'    = $(if ($Env.LastError) { $Env.LastError } else { 'nenhum' })
        'Motivo'          = $Env.Reason
    })
}

# ------------------------------------------------------------------------------
# TRILHA DE EXECUCAO
#
# Cada etapa registra o que foi diagnosticado, o que foi feito, o que resultou e,
# quando falha, o motivo tecnico. E o que transforma "Falha ao instalar Winget"
# em um relato reconstituivel - na tela, no log e no relatorio da sessao.
# ------------------------------------------------------------------------------
function New-WingetAcao {
    param([string]$Nome = '')
    return [pscustomobject]@{
        Nome               = $Nome
        Executado          = $false
        Sucesso            = $false
        Metodo             = ''
        Mensagem           = ''
        Pendente           = $false
        DependenciaAusente = $false
    }
}

function Add-WingetTrilha {
    param(
        [Parameter(Mandatory)][string]$Etapa,
        [string]$Diagnostico = '',
        [string]$Acao        = '',
        [Parameter(Mandatory)][string]$Resultado,
        [string]$Motivo      = ''
    )
    [void]$script:Trilha.Add([pscustomobject]@{
        Etapa       = $Etapa
        Diagnostico = $Diagnostico
        Acao        = $(if ($Acao) { $Acao } else { 'nenhuma' })
        Resultado   = $Resultado
        Motivo      = $(if ($Motivo) { $Motivo } else { '-' })
    })
    Write-Log INFO ("Trilha | Etapa={0} | Diagnostico={1} | Acao={2} | Resultado={3} | Motivo={4}" -f `
        $Etapa, $Diagnostico, $(if ($Acao) { $Acao } else { 'nenhuma' }), $Resultado, $(if ($Motivo) { $Motivo } else { '-' })) -NoConsole
}

function Write-WingetTrilha {
    if (@($script:Trilha).Count -eq 0) { return }
    Write-CompartDiskTitulo 'ETAPAS EXECUTADAS'
    Write-CompartDiskTable -Rows @($script:Trilha) -Property @('Etapa', 'Resultado', 'Acao', 'Motivo')
}

# ------------------------------------------------------------------------------
# CODIGOS DE ERRO
# ------------------------------------------------------------------------------
function Get-WingetDescricaoCodigo {
    <# Traducao dos codigos que aparecem de verdade nesta operacao. O que nao
       estiver na tabela e devolvido em hexadecimal com a descricao do proprio
       Windows quando existir - nunca inventado. #>
    param($Codigo)
    if ($null -eq $Codigo) { return '' }
    $n = 0
    try { $n = [int]$Codigo } catch { return "$Codigo" }
    if ($n -eq 0) { return 'sucesso' }
    # Codigo de saida comum (winget e utilitarios nativos devolvem valores
    # pequenos e positivos): mostrar em hexadecimal so confundiria.
    if ($n -gt 0 -and $n -lt 65536) { return ('codigo {0}' -f $n) }

    # 0xFFFFFFFF SEM sufixo e lido como Int32 -1 pelo Windows PowerShell: a
    # mascara devolvia o proprio negativo, a conversao para UInt32 falhava e
    # derrubava a formatacao do erro justamente quando havia erro. L forca Int64.
    $hex = ('0x{0:X8}' -f ([uint32]([int64]$n -band 0xFFFFFFFFL)))
    $tabela = @{
        '0x80070002' = 'arquivo ou caminho nao encontrado'
        '0x80070005' = 'acesso negado: a operacao exige privilegio administrativo'
        '0x800B0109' = 'a cadeia do certificado termina em uma raiz nao confiavel'
        '0x80073CF0' = 'nao foi possivel abrir o pacote'
        '0x80073CF1' = 'pacote nao encontrado'
        '0x80073CF2' = 'pacote invalido ou corrompido'
        '0x80073CF3' = 'validacao do pacote falhou: dependencia ausente ou em conflito'
        '0x80073CF4' = 'espaco em disco insuficiente'
        '0x80073CF5' = 'falha de rede durante a instalacao do pacote'
        '0x80073CF6' = 'falha ao registrar o pacote'
        '0x80073CF9' = 'falha na instalacao do pacote'
        '0x80073D02' = 'o pacote esta em uso: feche o App Installer e o Terminal e repita'
        '0x8A150002' = 'o winget recusou a linha de comando informada'
    }
    if ($tabela.ContainsKey($hex)) { return ('{0} - {1}' -f $hex, $tabela[$hex]) }

    $desc = ''
    try { $desc = [System.Runtime.InteropServices.Marshal]::GetExceptionForHR($n).Message } catch { }
    if ($desc -and $desc -notmatch 'HRESULT') { return ('{0} - {1}' -f $hex, $desc) }
    return $hex
}

function Format-WingetFalha {
    <# Mensagem de falha util: codigo interpretado + texto real do comando. #>
    param($Codigo, [string]$Texto)
    $partes = New-Object System.Collections.ArrayList
    $c = Get-WingetDescricaoCodigo $Codigo
    if ($c -and $c -ne 'sucesso') { [void]$partes.Add($c) }
    $t = "$Texto".Trim()
    if ($t) { [void]$partes.Add(($t -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ') }
    if ($partes.Count -eq 0) { return 'falha sem detalhe informado pelo sistema' }
    return ($partes -join ' | ')
}

function Test-WingetFalhaDeDependencia {
    param([string]$Mensagem)
    if (-not $Mensagem) { return $false }
    return ($Mensagem -match '(?i)0x80073CF3' -or $Mensagem -match '(?i)depend')
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
# REDE E FONTES OFICIAIS
# ------------------------------------------------------------------------------
function Initialize-WingetRede {
    <# TLS moderno e proxy corporativo. Em Windows PowerShell 5.1 o padrao ainda
       pode ser TLS 1.0, o que faz qualquer endereco da Microsoft recusar a
       conexao; e em parque corporativo o proxy autenticado precisa das
       credenciais da sessao do Windows para deixar passar. #>
    if ($script:RedeIniciada) { return }
    $script:RedeIniciada = $true
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch { }
    try { if ([Net.WebRequest]::DefaultWebProxy) { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } } catch { }
    try { [System.Net.Http.HttpClient]::DefaultProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }
}

function Test-WingetEnderecoOficial {
    <# Somente HTTPS e somente dominios oficiais. Recusa antes de conectar. #>
    param([string]$Uri)
    try {
        $u = [uri]$Uri
        if ($u.Scheme -ne 'https') { return $false }
        $h = $u.Host.ToLowerInvariant()
        foreach ($d in $script:WingetHostsOficiais) {
            if ($h -eq $d -or $h.EndsWith('.' + $d)) { return $true }
        }
    } catch { }
    return $false
}

function Get-WingetCabecalhosHttp {
    return @{ 'User-Agent' = ('COMPARTDISK/{0}' -f $Global:CompartDisk.Version) }
}

function Invoke-WingetTextoHttp {
    <# GET de texto curto (metadados do release). Nunca lanca: devolve $null. #>
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSeconds = 45)
    if (-not (Test-WingetEnderecoOficial $Uri)) {
        Write-Log DEBUG ("Endereco recusado por nao ser oficial: {0}" -f $Uri) -NoConsole
        return $null
    }
    Initialize-WingetRede
    $anterior = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers (Get-WingetCabecalhosHttp) -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        $c = $r.Content
        if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
        return [string]$c
    } catch {
        Write-Log DEBUG ("Consulta HTTP falhou ({0}): {1}" -f $Uri, $_.Exception.Message) -NoConsole
        return $null
    } finally { $ProgressPreference = $anterior }
}

function Save-WingetArquivoOficial {
    <# Download para a pasta temporaria da sessao. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destino,
        [string]$Rotulo = 'arquivo',
        [int]$TimeoutSeconds = 1800
    )
    $out = [pscustomobject]@{ Sucesso = $false; Caminho = $null; Bytes = 0; Mensagem = '' }
    if (-not (Test-WingetEnderecoOficial $Uri)) {
        $out.Mensagem = ('endereco fora das fontes oficiais aceitas ({0})' -f $Uri)
        return $out
    }
    Initialize-WingetRede
    $anterior = $ProgressPreference
    $inicio   = Get-Date
    try {
        $ProgressPreference = 'SilentlyContinue'
        Write-Log INFO ('Baixando {0} de {1}...' -f $Rotulo, ([uri]$Uri).Host)
        Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers (Get-WingetCabecalhosHttp) `
            -OutFile $Destino -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $Destino)) {
            $out.Mensagem = 'o download terminou sem gerar arquivo'
            return $out
        }
        $out.Caminho = $Destino
        $out.Bytes   = (Get-Item -LiteralPath $Destino).Length
        if ($out.Bytes -le 0) {
            $out.Mensagem = 'arquivo baixado com 0 byte'
            return $out
        }
        $out.Sucesso = $true
        Write-Log OK ('{0} baixado ({1}) em {2:N0}s.' -f $Rotulo, (ConvertTo-CompartDiskSize $out.Bytes), ((Get-Date) - $inicio).TotalSeconds)
    } catch {
        $out.Mensagem = $_.Exception.Message
    } finally { $ProgressPreference = $anterior }
    return $out
}

function Test-WingetArquivoOficial {
    <# Duas conferencias independentes antes de instalar qualquer pacote:

       1. SHA256 publicado pela Microsoft junto do release. Quando existe, e a
          prova mais forte e o veredito e definitivo.
       2. Assinatura digital do pacote. Um MSIX da Microsoft e assinado; se a
          assinatura for invalida, adulterada ou de outro editor, o arquivo e
          recusado.

       Quando o Windows nao consegue AVALIAR a assinatura (SIP indisponivel), o
       resultado e registrado como aviso e o hash oficial decide. Sem hash e sem
       assinatura avaliavel, o arquivo e recusado. #>
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [string]$HashEsperado = ''
    )
    $out = [pscustomobject]@{ Confiavel = $false; Motivo = ''; Detalhe = '' }

    $hashOk = $null
    if ($HashEsperado) {
        try {
            $h = (Get-FileHash -LiteralPath $Caminho -Algorithm SHA256 -ErrorAction Stop).Hash
            $hashOk = ($h -ieq $HashEsperado.Trim())
            if (-not $hashOk) {
                $out.Motivo = 'o SHA256 do arquivo baixado nao confere com o publicado pela Microsoft'
                return $out
            }
            $out.Detalhe = 'SHA256 confere com o publicado no release oficial'
        } catch {
            $hashOk = $null
            Write-Log DEBUG ("Calculo de SHA256 falhou: {0}" -f $_.Exception.Message) -NoConsole
        }
    }

    $assinatura = 'nao avaliada'
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Caminho -ErrorAction Stop
        $assinatura = "$($sig.Status)"
        $assunto    = "$($sig.SignerCertificate.Subject)"
        if ($sig.Status -eq 'Valid' -and $assunto -match '(?i)O=Microsoft Corporation') {
            $out.Confiavel = $true
            $out.Detalhe   = (($out.Detalhe, 'assinado pela Microsoft Corporation') | Where-Object { $_ }) -join '; '
            return $out
        }
        if ($sig.Status -eq 'Valid') {
            $out.Motivo = ('o pacote esta assinado, mas nao pela Microsoft ({0})' -f $assunto)
            return $out
        }
        if ($assinatura -in @('NotSigned', 'HashMismatch', 'NotTrusted')) {
            $out.Motivo = ('assinatura digital recusada pelo Windows ({0})' -f $sig.Status)
            return $out
        }
    } catch {
        $assinatura = ('nao avaliada ({0})' -f $_.Exception.Message)
    }

    # Assinatura inconclusiva: o hash oficial decide.
    if ($hashOk) {
        $out.Confiavel = $true
        $out.Detalhe   = ('SHA256 oficial confere; assinatura {0}' -f $assinatura)
        Write-Log WARN ('Assinatura do pacote nao pode ser avaliada ({0}). O SHA256 publicado pela Microsoft confere e foi o criterio aplicado.' -f $assinatura)
        return $out
    }

    $out.Motivo = ('nao foi possivel comprovar a origem do arquivo (assinatura {0}, sem SHA256 publicado para conferir)' -f $assinatura)
    return $out
}

function Get-WingetOrigemOficial {
    <# Enderecos oficiais do pacote, na melhor fonte disponivel:

       1. release publicado em github.com/microsoft/winget-cli - traz versao,
          tamanho, SHA256 e o pacote de dependencias correspondente aquela versao;
       2. aka.ms/getwinget - atalho oficial da Microsoft, usado quando a consulta
          ao release nao responde (rede restrita, API indisponivel).

       Consultado uma vez por execucao: a mesma preparacao chega aqui pela
       camada de dependencias e pela do pacote, e repetir quatro requisicoes so
       para reler o mesmo release atrasaria o reparo.

       Nunca lanca. #>
    [CmdletBinding()] param()
    if ($script:OrigemOficial) { return $script:OrigemOficial }
    $o = [pscustomobject]@{
        Origem       = ''
        Versao       = ''
        Bundle       = $null
        BundleBytes  = 0
        BundleHash   = ''
        Deps         = $null
        DepsBytes    = 0
        DepsHash     = ''
        Licenca      = $null
        Requeridas   = @()
    }

    $json = Invoke-WingetTextoHttp -Uri $script:WingetOficial.ApiRelease
    if ($json) {
        try {
            $rel = $json | ConvertFrom-Json
            $o.Versao = "$($rel.tag_name)"
            $urlHashBundle = $null; $urlHashDeps = $null; $urlDepsJson = $null
            foreach ($a in @($rel.assets)) {
                $nome = "$($a.name)"
                $url  = "$($a.browser_download_url)"
                if (-not (Test-WingetEnderecoOficial $url)) { continue }
                if     ($nome -like '*.msixbundle')                       { $o.Bundle = $url;  $o.BundleBytes = [long]$a.size }
                elseif ($nome -eq 'DesktopAppInstaller_Dependencies.zip')  { $o.Deps   = $url;  $o.DepsBytes   = [long]$a.size }
                elseif ($nome -eq 'DesktopAppInstaller_Dependencies.txt')  { $urlHashDeps = $url }
                elseif ($nome -eq 'DesktopAppInstaller_Dependencies.json') { $urlDepsJson = $url }
                elseif ($nome -like '*_License1.xml')                      { $o.Licenca = $url }
                elseif ($nome -like 'Microsoft.DesktopAppInstaller_*.txt') { $urlHashBundle = $url }
            }
            if ($o.Bundle) {
                $o.Origem = ('release oficial microsoft/winget-cli {0}' -f $o.Versao)
                if ($urlHashBundle) { $o.BundleHash = "$(Invoke-WingetTextoHttp -Uri $urlHashBundle)".Trim() }
                if ($urlHashDeps)   { $o.DepsHash   = "$(Invoke-WingetTextoHttp -Uri $urlHashDeps)".Trim() }
                if ($urlDepsJson) {
                    $dj = Invoke-WingetTextoHttp -Uri $urlDepsJson
                    if ($dj) { try { $o.Requeridas = @(($dj | ConvertFrom-Json).Dependencies) } catch { } }
                }
            }
        } catch {
            Write-Log DEBUG ("Leitura do release oficial falhou: {0}" -f $_.Exception.Message) -NoConsole
        }
    }

    if (-not $o.Bundle) {
        $o.Bundle = $script:WingetOficial.Bundle
        $o.Origem = 'atalho oficial da Microsoft (aka.ms/getwinget)'
    }
    $script:OrigemOficial = $o
    return $o
}

function New-WingetPastaTemporaria {
    if ($script:TempRaiz -and (Test-Path -LiteralPath $script:TempRaiz)) { return $script:TempRaiz }
    $base = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $Global:CompartDisk.LogDir }
    $p = Join-Path $base ('COMPARTDISK_WinGet_{0}' -f $Global:CompartDisk.Session)
    try {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        $script:TempRaiz = $p
        return $p
    } catch {
        Write-Log WARN ('Nao foi possivel criar a pasta temporaria de trabalho: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Remove-WingetPastaTemporaria {
    <# Remove SOMENTE a pasta criada por este modulo, conferida pelo nome. #>
    if (-not $script:TempRaiz) { return }
    try {
        $nome = Split-Path -Leaf $script:TempRaiz
        if ($nome -like 'COMPARTDISK_WinGet_*' -and (Test-Path -LiteralPath $script:TempRaiz)) {
            Remove-Item -LiteralPath $script:TempRaiz -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Write-Log DEBUG ('Limpeza da pasta temporaria adiada: {0}' -f $_.Exception.Message) -NoConsole
    }
    $script:TempRaiz = $null
}

function Test-WingetEspacoLivre {
    param([long]$BytesNecessarios)
    try {
        $raiz = New-WingetPastaTemporaria
        if (-not $raiz) { return $true }
        $unidade = (Split-Path -Qualifier $raiz)
        $d = Get-CompartDiskCim -Class Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $unidade)
        if (-not $d) { return $true }
        $livre = [long]$d.FreeSpace
        if ($livre -le 0) { return $true }
        return ($livre -gt ($BytesNecessarios * 2))
    } catch { return $true }
}

function Confirm-WingetDownload {
    <# Em execucao com operador, baixar centenas de megabytes e uma decisao dele.
       Em automacao a acao ja foi pedida por -Action Prepare e segue direto. #>
    param([string]$Descricao, [long]$Bytes, [string]$Origem)
    if (-not (Test-ModoInterativo)) { return $true }
    Write-Color ''
    Write-Color ('  Origem oficial : {0}' -f $Origem) -Color Gray
    Write-Color ('  Pacote         : {0}' -f $Descricao) -Color Gray
    if ($Bytes -gt 0) { Write-Color ('  Tamanho        : {0}' -f (ConvertTo-CompartDiskSize $Bytes)) -Color Gray }
    Write-Color '  O arquivo e conferido por SHA256 e assinatura da Microsoft antes de instalar.' -Color DarkGray
    Write-Color ''
    Write-Color '  [1] Baixar e instalar' -Color Cyan
    Write-Color '  [0] Nao baixar' -Color DarkGray
    Write-Color ''
    return ((Read-CompartDiskOpcao -Maximo 1) -eq 1)
}

function Update-WingetPathProcesso {
    <# Depois de registrar ou instalar o pacote, o alias de execucao passa a
       existir - mas o PATH DESTE processo continua o de antes. A atualizacao e
       aditiva: nada que ja estava na variavel e removido. #>
    try {
        $atual = New-Object System.Collections.ArrayList
        foreach ($p in ("$env:PATH" -split ';')) { if ($p) { [void]$atual.Add($p) } }
        foreach ($escopo in @('Machine', 'User')) {
            $v = [Environment]::GetEnvironmentVariable('Path', $escopo)
            foreach ($p in ("$v" -split ';')) {
                if (-not $p) { continue }
                if (-not ($atual | Where-Object { $_.TrimEnd('\') -ieq $p.TrimEnd('\') })) { [void]$atual.Add($p) }
            }
        }
        $env:PATH = ($atual -join ';')
    } catch { Write-Log DEBUG ('Atualizacao do PATH do processo falhou: {0}' -f $_.Exception.Message) -NoConsole }
}

# ------------------------------------------------------------------------------
# CAMADA 1 - PATH E ALIAS DE EXECUCAO
# ------------------------------------------------------------------------------
function Repair-WingetPath {
    <# O winget existe e nao e alcancavel por "winget" na linha de comando: a
       pasta WindowsApps saiu do PATH do usuario. E o cenario em que instalar ou
       reinstalar nada resolve, porque nao falta pacote - falta caminho.

       Escopo do usuario apenas. O PATH da maquina nao e tocado. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env)

    $saida = New-WingetAcao 'PATH'
    $alias = $Env.AliasPath
    if ((-not $alias) -or (-not (Test-Path -LiteralPath $alias)) -or $Env.AliasState -ne 'ok') {
        $saida.Mensagem = 'nao ha alias de execucao valido para expor no PATH'
        return $saida
    }

    $pasta = Split-Path -Parent $alias
    $saida.Executado = $true
    $saida.Metodo    = ('PATH do usuario + PATH do processo ({0})' -f $pasta)

    # 1. processo - efeito imediato nesta sessao
    Update-WingetPathProcesso
    $noProcesso = @("$env:PATH" -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $pasta.TrimEnd('\') })
    if ($noProcesso.Count -eq 0) { $env:PATH = ("$env:PATH".TrimEnd(';') + ';' + $pasta) }

    # 2. usuario - efeito nas proximas sessoes. O tipo do valor e preservado:
    #    gravar um REG_EXPAND_SZ como REG_SZ congela entradas com %VARIAVEL%.
    $gravou = $false
    try {
        $chave = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if ($chave) {
            try {
                $bruto = [string]$chave.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $tipo  = [Microsoft.Win32.RegistryValueKind]::ExpandString
                try { if ($chave.GetValueKind('Path') -eq [Microsoft.Win32.RegistryValueKind]::String) { $tipo = [Microsoft.Win32.RegistryValueKind]::String } } catch { }

                # A comparacao tem de ser entre caminhos EXPANDIDOS. A entrada
                # do WindowsApps costuma estar gravada como
                # "%USERPROFILE%\AppData\Local\Microsoft\WindowsApps"; conferir
                # o texto bruto contra o caminho ja expandido nunca casa, e o
                # reparo acrescentaria uma copia da mesma pasta a cada execucao.
                $existente = @($bruto -split ';' | Where-Object {
                    $_ -and ([Environment]::ExpandEnvironmentVariables($_)).TrimEnd('\') -ieq $pasta.TrimEnd('\')
                })
                if ($existente.Count -gt 0) {
                    Write-Log INFO 'A pasta WindowsApps ja constava do PATH do usuario: nada foi alterado no registro.'
                    $gravou = $true
                } else {
                    $novo = $(if ($bruto.Trim()) { $bruto.TrimEnd(';') + ';' + $pasta } else { $pasta })
                    $chave.SetValue('Path', $novo, $tipo)
                    $gravou = $true
                    Write-Log OK 'Pasta WindowsApps devolvida ao PATH do usuario.'
                }
            } finally { $chave.Close() }
        }
    } catch {
        $saida.Mensagem = ('PATH do usuario nao pode ser gravado: {0}' -f $_.Exception.Message)
        Write-Log WARN $saida.Mensagem
    }

    # 3. validacao real: o executavel tem de responder pelo caminho exposto
    $responde = $false
    try { $responde = ((Invoke-NativeCommand -FilePath $alias -Arguments @('--version') -TimeoutSeconds 30).ExitCode -eq 0) } catch { }
    $saida.Sucesso = $responde
    if (-not $responde) {
        if (-not $saida.Mensagem) { $saida.Mensagem = 'o alias voltou ao PATH, mas o winget continua sem responder a --version' }
    } elseif (-not $gravou) {
        $saida.Mensagem = 'corrigido apenas nesta sessao: o PATH do usuario nao pode ser gravado'
    }
    return $saida
}

function Invoke-WingetAjustePath {
    <# O winget funciona, mas so e alcancavel FORA do PATH.

       Para a Central de Aplicativos isso nao e problema - ela usa o caminho
       resolvido. Para o operador que digita "winget", para qualquer script e
       para as rotinas Batch do proprio Launcher, o comando simplesmente nao
       existe. E um defeito real do ambiente que NAO e defeito do pacote: trata-lo
       como estado de falha faria a Central recusar uma maquina em que o winget
       funciona. Por isso ele e corrigido aqui, sem mudar o estado diagnosticado.

       Idempotente por construcao: depois do ajuste a origem passa a ser o PATH e
       a condicao deixa de valer. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env)

    if (-not $Env.Executable)              { return $false }
    if ($Env.ExecutableOrigin -eq 'PATH')  { return $false }
    if ($Env.AliasState -ne 'ok')          { return $false }
    # Uma vez por execucao. Quando o ajuste funciona, a origem passa a ser o PATH
    # e a condicao acima ja barra a repeticao; quando NAO funciona (registro do
    # usuario sem permissao de escrita, por exemplo), a condicao continua valendo
    # e o menu tentaria de novo a cada "Verificar novamente" - insistir na mesma
    # operacao que acabou de falhar nao muda o resultado.
    if ($script:PathAjustado) { return $false }
    $script:PathAjustado = $true

    Write-Log WARN ('O winget responde, mas so e alcancavel por {0}: o comando "winget" nao resolve neste ambiente.' -f $Env.ExecutableOrigin)
    $acao = Repair-WingetPath -Env $Env
    Add-WingetTrilha -Etapa 'PATH' -Diagnostico ('winget alcancado por {0}, fora do PATH.' -f $Env.ExecutableOrigin) `
        -Acao $acao.Metodo -Resultado $(if ($acao.Sucesso) { 'sucesso' } elseif ($acao.Executado) { 'falhou' } else { 'nao aplicavel' }) `
        -Motivo $acao.Mensagem
    return [bool]$acao.Executado
}

# ------------------------------------------------------------------------------
# CAMADA 2 - FONTES DO WINGET
# ------------------------------------------------------------------------------
function Repair-WingetSources {
    <# O winget executa e a fonte oficial nao responde. Isso nao e problema de
       pacote: e configuracao de fonte corrompida, e o proprio winget tem o
       comando oficial para recompor as fontes padrao. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env)

    $saida = New-WingetAcao 'Fontes'
    if (-not $Env.Executable) {
        $saida.Mensagem = 'sem winget.exe para executar o reparo de fontes'
        return $saida
    }

    $saida.Executado = $true
    $saida.Metodo    = 'winget source reset --force + winget source update'

    try {
        $r = Invoke-NativeCommand -FilePath $Env.Executable -Arguments @('source', 'reset', '--force') -TimeoutSeconds 180
        if ($r.ExitCode -ne 0) {
            $saida.Mensagem = Format-WingetFalha $r.ExitCode ("$($r.StdErr)`n$($r.StdOut)")
            return $saida
        }
        # Atualizar o indice depende de rede; falhar aqui nao invalida o reset.
        try { $null = Invoke-NativeCommand -FilePath $Env.Executable -Arguments @('source', 'update') -TimeoutSeconds 300 } catch { }

        $l = Invoke-NativeCommand -FilePath $Env.Executable -Arguments @('source', 'list') -TimeoutSeconds 60
        $saida.Sucesso = ($l.ExitCode -eq 0 -and $l.StdOut -match '(?im)^\s*winget\s')
        if (-not $saida.Sucesso) {
            $saida.Mensagem = Format-WingetFalha $l.ExitCode 'a fonte oficial "winget" continua ausente da lista de fontes'
        }
    } catch {
        $saida.Mensagem = $_.Exception.Message
    }
    return $saida
}

# ------------------------------------------------------------------------------
# CAMADA 3 - DEPENDENCIAS DE RUNTIME
# ------------------------------------------------------------------------------
function Get-WingetDependenciasAusentes {
    <# Confronta o que a maquina tem com o que a versao publicada do App
       Installer exige. Sem a lista oficial (sem rede), aplica o conjunto minimo
       conhecido: a biblioteca C++ de desktop e um runtime de interface. #>
    param([object[]]$Requeridas = @())

    $faltando = New-Object System.Collections.ArrayList

    if (@($Requeridas).Count -gt 0) {
        foreach ($d in $Requeridas) {
            $nome = "$($d.Name)"
            if (-not $nome) { continue }
            $q = Get-CompartDiskAppxPacote -Name $nome
            if (-not $q.Consultado) { continue }
            $ok = $false
            foreach ($p in @($q.Pacotes)) {
                if (-not $d.Version) { $ok = $true; break }
                try { if ([version]$p.Version -ge [version]"$($d.Version)") { $ok = $true; break } } catch { $ok = $true; break }
            }
            if (-not $ok) { [void]$faltando.Add($nome) }
        }
        return @($faltando)
    }

    $q1 = Get-CompartDiskAppxPacote -Name 'Microsoft.VCLibs.140.00.UWPDesktop'
    if ($q1.Consultado -and @($q1.Pacotes).Count -eq 0) { [void]$faltando.Add('Microsoft.VCLibs.140.00.UWPDesktop') }
    $q2 = Get-CompartDiskAppxPacote -Name 'Microsoft.UI.Xaml.*'
    $q3 = Get-CompartDiskAppxPacote -Name 'Microsoft.WindowsAppRuntime.*'
    if ($q2.Consultado -and $q3.Consultado -and @($q2.Pacotes).Count -eq 0 -and @($q3.Pacotes).Count -eq 0) {
        [void]$faltando.Add('Microsoft.UI.Xaml / Microsoft.WindowsAppRuntime')
    }
    return @($faltando)
}

function Install-WingetPacoteAppx {
    <# Instalacao de um pacote AppX/MSIX pelo motor correto, com o erro real
       preservado. Nao decide nada: quem decide e a camada que chamou. #>
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [string[]]$Dependencias = @(),
        [switch]$ForcarQualquerVersao,
        [string]$Atividade = 'Instalar pacote'
    )
    $cmd = "Add-AppxPackage -Path '" + $Caminho + "'"
    if (@($Dependencias).Count -gt 0) {
        $lista = (@($Dependencias) | ForEach-Object { "'" + $_ + "'" }) -join ','
        $cmd += ' -DependencyPath @(' + $lista + ')'
    }
    # -ForceUpdateFromAnyVersion existe desde o Windows 10 1809, que e a build
    # minima exigida por este modulo. Sem ele, reinstalar a MESMA versao sobre
    # uma instalacao corrompida e recusado - e e exatamente esse o reparo.
    if ($ForcarQualquerVersao) { $cmd += ' -ForceUpdateFromAnyVersion' }
    $cmd += ' -ErrorAction Stop'
    return (Invoke-CompartDiskAppxScript -Comando $cmd -Activity $Atividade -TimeoutSeconds 900)
}

function Repair-WingetDependencias {
    <# Repoe as bibliotecas de runtime exigidas pelo App Installer, a partir do
       pacote de dependencias publicado pela Microsoft junto do release (ou, para
       a biblioteca C++ isolada, do atalho oficial aka.ms). #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env)

    $saida = New-WingetAcao 'Dependencias'

    $origem    = $null
    $requeridas = @()
    if (-not $SemDownload -and $Env.Online -ne $false) {
        $origem = Get-WingetOrigemOficial
        if ($origem) { $requeridas = @($origem.Requeridas) }
    }

    $faltando = Get-WingetDependenciasAusentes -Requeridas $requeridas
    if (@($faltando).Count -eq 0) {
        $saida.Mensagem = 'as dependencias exigidas ja estao presentes: nada a instalar'
        return $saida
    }
    Write-Log INFO ('Dependencias ausentes: {0}.' -f (@($faltando) -join ', '))

    if ($SemDownload) {
        $saida.Mensagem = 'reposicao de dependencia exige download e a execucao pediu -SemDownload'
        return $saida
    }
    if ($Env.Online -eq $false) {
        $saida.Mensagem = 'sem conectividade para obter as dependencias oficiais'
        return $saida
    }
    if ($Env.SideloadBlocked) {
        $saida.Mensagem = 'politica de sideload impede instalar pacote assinado nesta maquina'
        return $saida
    }

    $arq  = Get-WingetArquitetura
    $raiz = New-WingetPastaTemporaria
    if (-not $raiz) {
        $saida.Mensagem = 'sem pasta temporaria gravavel para o download'
        return $saida
    }

    # So a biblioteca C++ falta: o atalho oficial dela e muito menor que o
    # pacote completo de dependencias. Qualquer outro caso usa o pacote do release.
    $somenteVCLibs = (@($faltando).Count -eq 1 -and "$($faltando[0])" -like 'Microsoft.VCLibs*')
    $instalar = New-Object System.Collections.ArrayList

    if ($somenteVCLibs) {
        $uri     = ($script:WingetOficial.VCLibs -f $arq)
        $destino = Join-Path $raiz ('Microsoft.VCLibs.{0}.14.00.Desktop.appx' -f $arq)
        if (-not (Confirm-WingetDownload -Descricao ('Microsoft VCLibs Desktop ({0})' -f $arq) -Bytes 0 -Origem 'aka.ms (Microsoft)')) {
            $saida.Mensagem = 'download recusado pelo operador'
            return $saida
        }
        $saida.Executado = $true
        $saida.Metodo    = ('VCLibs Desktop {0} (atalho oficial aka.ms)' -f $arq)
        $d = Save-WingetArquivoOficial -Uri $uri -Destino $destino -Rotulo 'Microsoft VCLibs Desktop'
        if (-not $d.Sucesso) { $saida.Mensagem = $d.Mensagem; return $saida }
        $conf = Test-WingetArquivoOficial -Caminho $destino
        if (-not $conf.Confiavel) { $saida.Mensagem = $conf.Motivo; return $saida }
        [void]$instalar.Add($destino)
    }
    else {
        if (-not $origem -or -not $origem.Deps) {
            $saida.Mensagem = 'o pacote oficial de dependencias nao esta disponivel para esta versao'
            return $saida
        }
        if (-not (Test-WingetEspacoLivre -BytesNecessarios $origem.DepsBytes)) {
            $saida.Mensagem = 'espaco em disco insuficiente na pasta temporaria para o pacote de dependencias'
            return $saida
        }
        if (-not (Confirm-WingetDownload -Descricao 'Dependencias do App Installer' -Bytes $origem.DepsBytes -Origem $origem.Origem)) {
            $saida.Mensagem = 'download recusado pelo operador'
            return $saida
        }
        $saida.Executado = $true
        $saida.Metodo    = ('Dependencias do App Installer ({0})' -f $origem.Origem)

        $zip = Join-Path $raiz 'DesktopAppInstaller_Dependencies.zip'
        $d = Save-WingetArquivoOficial -Uri $origem.Deps -Destino $zip -Rotulo 'dependencias do App Installer'
        if (-not $d.Sucesso) { $saida.Mensagem = $d.Mensagem; return $saida }
        if ($origem.DepsHash) {
            try {
                $h = (Get-FileHash -LiteralPath $zip -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($h -ine $origem.DepsHash) {
                    $saida.Mensagem = 'o SHA256 do pacote de dependencias nao confere com o publicado pela Microsoft'
                    return $saida
                }
                Write-Log OK 'SHA256 do pacote de dependencias confere com o publicado no release oficial.'
            } catch {
                $saida.Mensagem = ('nao foi possivel conferir o SHA256 do pacote de dependencias: {0}' -f $_.Exception.Message)
                return $saida
            }
        }

        $extraido = Join-Path $raiz 'deps'
        try {
            if (Test-Path -LiteralPath $extraido) { Remove-Item -LiteralPath $extraido -Recurse -Force -ErrorAction SilentlyContinue }
            Expand-Archive -LiteralPath $zip -DestinationPath $extraido -Force -ErrorAction Stop
        } catch {
            $saida.Mensagem = ('falha ao extrair o pacote de dependencias: {0}' -f $_.Exception.Message)
            return $saida
        }

        $achados = @()
        try {
            $achados = @(Get-ChildItem -LiteralPath $extraido -Recurse -File -ErrorAction Stop |
                         Where-Object { $_.Extension -in @('.appx', '.msix') })
        } catch { }
        # Arquivos da arquitetura desta maquina: o pacote traz todas.
        $daArq = @($achados | Where-Object { $_.FullName -match ('(?i)[\\/]{0}[\\/]' -f [regex]::Escape($arq)) -or $_.Name -match ('(?i)[._-]{0}[._-]' -f [regex]::Escape($arq)) })
        if ($daArq.Count -eq 0) { $daArq = $achados }
        if ($daArq.Count -eq 0) {
            $saida.Mensagem = 'o pacote de dependencias nao trouxe nenhum arquivo instalavel para esta arquitetura'
            return $saida
        }
        foreach ($f in $daArq) {
            $conf = Test-WingetArquivoOficial -Caminho $f.FullName
            if (-not $conf.Confiavel) {
                Write-Log WARN ('Dependencia ignorada ({0}): {1}' -f $f.Name, $conf.Motivo)
                continue
            }
            [void]$instalar.Add($f.FullName)
        }
        if ($instalar.Count -eq 0) {
            $saida.Mensagem = 'nenhuma dependencia do pacote passou na conferencia de origem'
            return $saida
        }
    }

    $instaladas = 0
    foreach ($f in $instalar) {
        $nome = Split-Path -Leaf $f
        Write-Log INFO ('Instalando dependencia {0}...' -f $nome)
        $r = Install-WingetPacoteAppx -Caminho $f -Atividade ('Instalar dependencia ' + $nome)
        if ($r.Success) { $instaladas++; Write-Log OK ('Dependencia instalada: {0}' -f $nome) }
        else            { Write-Log WARN ('Dependencia {0} nao instalou: {1}' -f $nome, $r.Error) }
    }

    $restantes = Get-WingetDependenciasAusentes -Requeridas $requeridas
    $saida.Sucesso = (@($restantes).Count -eq 0)
    if (-not $saida.Sucesso) {
        $saida.Mensagem = ('ainda ausentes apos a instalacao: {0}' -f (@($restantes) -join ', '))
    } elseif ($instaladas -eq 0) {
        $saida.Mensagem = 'nenhuma dependencia precisou ser instalada'
    }
    return $saida
}

# ------------------------------------------------------------------------------
# CAMADA 4 - REGISTRO DO PACOTE LOCAL (sem download)
# ------------------------------------------------------------------------------
function Get-WingetManifestosLocais {
    <# Manifestos do App Installer que existem NESTA maquina, em ordem de
       preferencia: o do pacote do perfil, o de outro perfil (com privilegio) e o
       da imagem do Windows. Um manifesto e o que permite registrar de novo sem
       baixar nada. #>
    [CmdletBinding()] param([object]$Env)

    $lista = New-Object System.Collections.ArrayList
    $adicionar = {
        param($caminho, $origem)
        if (-not $caminho) { return }
        $m = Join-Path $caminho 'AppXManifest.xml'
        if (-not (Test-Path -LiteralPath $m)) { return }
        if ($lista | Where-Object { $_.Manifesto -ieq $m }) { return }
        [void]$lista.Add([pscustomobject]@{ Manifesto = $m; Origem = $origem })
    }

    if ($Env -and $Env.InstallLocation) { & $adicionar $Env.InstallLocation 'pacote registrado' }

    $q = Get-CompartDiskAppxPacote -Name 'Microsoft.DesktopAppInstaller'
    if ($q.Consultado) { foreach ($p in @($q.Pacotes)) { & $adicionar $p.InstallLocation 'pacote do perfil' } }

    if ($Env -and $Env.Admin) {
        $qa = Get-CompartDiskAppxPacote -Name 'Microsoft.DesktopAppInstaller' -TodosUsuarios
        if ($qa.Consultado) { foreach ($p in @($qa.Pacotes)) { & $adicionar $p.InstallLocation 'pacote de outro perfil' } }
    }

    foreach ($raiz in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($raiz)) { continue }
        try {
            $pastas = Get-ChildItem -LiteralPath (Join-Path $raiz 'WindowsApps') -Directory `
                      -Filter 'Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe' -ErrorAction Stop
            foreach ($d in (@($pastas) | Sort-Object Name -Descending)) { & $adicionar $d.FullName 'imagem do Windows' }
        } catch { }
    }

    return @($lista)
}

function Repair-WingetSupport {
    <# Registra de novo o pacote AppX que ja esta na maquina. Sem download.

       Tres caminhos, do mais especifico ao mais generico - cada um resolve um
       estado diferente, e por isso nenhum repete o anterior:
         a. manifesto do pacote no perfil    - registro perdido no proprio perfil;
         b. manifesto na imagem/outro perfil - pacote em disco, perfil sem registro;
         c. familia do pacote                - provisionado, sem manifesto legivel.

       Requer os cmdlets Appx; sob PowerShell 7 a operacao e reencaminhada ao
       Windows PowerShell 5.1 pelo Core. #>
    [CmdletBinding()] param([object]$Env)

    $saida = New-WingetAcao 'Registro'

    if ((Get-WingetMotorAppx) -eq 'indisponivel') {
        $saida.Mensagem = 'nenhum motor com cmdlets Appx neste sistema: o registro do pacote nao pode ser executado'
        Write-Log WARN $saida.Mensagem
        return $saida
    }

    $manifestos = Get-WingetManifestosLocais -Env $Env
    foreach ($m in $manifestos) {
        $saida.Executado = $true
        $saida.Metodo    = ('Add-AppxPackage -Register ({0})' -f $m.Origem)
        Write-Log INFO ('Registrando novamente o App Installer pelo manifesto local ({0})...' -f $m.Origem)
        $r = Invoke-CompartDiskAppxScript -Activity 'Registrar App Installer' -TimeoutSeconds 600 `
             -Comando ("Add-AppxPackage -DisableDevelopmentMode -Register '" + $m.Manifesto + "' -ErrorAction Stop")
        if ($r.Success) { $saida.Sucesso = $true; return $saida }
        $saida.Mensagem = $r.Error
        $saida.DependenciaAusente = (Test-WingetFalhaDeDependencia $r.Error)
        Write-Log WARN ('Registro pelo manifesto ({0}) nao concluiu: {1}' -f $m.Origem, $r.Error)
        if ($saida.DependenciaAusente) { return $saida }
    }

    # Caminho c: sem manifesto acessivel, resta a familia do pacote - util
    # quando o pacote esta provisionado na imagem e a pasta nao pode ser lida.
    $saida.Executado = $true
    $saida.Metodo    = 'Add-AppxPackage -RegisterByFamilyName'
    Write-Log INFO 'Tentando registrar o App Installer pela familia do pacote...'
    $r2 = Invoke-CompartDiskAppxScript -Activity 'Registrar App Installer pela familia' -TimeoutSeconds 600 `
          -Comando ("Add-AppxPackage -RegisterByFamilyName -MainPackage '" + $Env.PackageFamily + "' -ErrorAction Stop")
    if ($r2.Success) { $saida.Sucesso = $true; return $saida }
    $saida.Mensagem = $r2.Error
    if (-not $saida.DependenciaAusente) { $saida.DependenciaAusente = (Test-WingetFalhaDeDependencia $r2.Error) }
    return $saida
}

# ------------------------------------------------------------------------------
# CAMADA 5 - MODULO OFICIAL Microsoft.WinGet.Client
# ------------------------------------------------------------------------------
function Repair-WingetModuloOficial {
    <# Reparo pela implementacao da propria Microsoft, quando o modulo oficial ja
       esta instalado nesta maquina. O COMPARTDISK NAO instala modulo do
       PowerShell Gallery para isso: instalar um modulo seria um efeito colateral
       maior que o problema, e a camada seguinte cobre o mesmo caso. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env)

    $saida = New-WingetAcao 'ModuloOficial'

    $disponivel = $false
    try { $disponivel = [bool](Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' -ErrorAction SilentlyContinue) } catch { }
    if (-not $disponivel) {
        $saida.Mensagem = 'o modulo oficial Microsoft.WinGet.Client nao esta instalado nesta maquina'
        return $saida
    }

    try { Import-Module Microsoft.WinGet.Client -ErrorAction Stop -WarningAction SilentlyContinue }
    catch {
        $saida.Mensagem = ('o modulo oficial existe mas nao pode ser carregado: {0}' -f $_.Exception.Message)
        return $saida
    }

    $cmd = $null
    try { $cmd = Get-Command Repair-WinGetPackageManager -ErrorAction Stop } catch { }
    if (-not $cmd) {
        $saida.Mensagem = 'a versao instalada do modulo oficial nao oferece Repair-WinGetPackageManager'
        return $saida
    }

    # Parametros conferidos no proprio cmdlet: versoes diferentes do modulo
    # expoem conjuntos diferentes, e passar um inexistente derrubaria a chamada.
    $p = @{ ErrorAction = 'Stop' }
    if ($cmd.Parameters.ContainsKey('Force'))    { $p['Force']    = $true }
    if ($cmd.Parameters.ContainsKey('Latest'))   { $p['Latest']   = $true }
    if ($Env.Admin -and $cmd.Parameters.ContainsKey('AllUsers')) { $p['AllUsers'] = $true }

    $saida.Executado = $true
    $saida.Metodo    = 'Microsoft.WinGet.Client :: Repair-WinGetPackageManager'
    Write-Log INFO 'Executando o reparo oficial do Windows Package Manager (Microsoft.WinGet.Client)...'
    $r = Invoke-SafeCommand -Activity 'Repair-WinGetPackageManager' -Silent -ScriptBlock { Repair-WinGetPackageManager @p }
    if ($r.Success) { $saida.Sucesso = $true; return $saida }
    if ($r.Error) { $saida.Mensagem = $r.Error.Exception.Message }
    return $saida
}

# ------------------------------------------------------------------------------
# CAMADA 6 - PACOTE OFICIAL DA MICROSOFT (independe da Microsoft Store)
# ------------------------------------------------------------------------------
function Test-WingetVersaoJaAtual {
    <# Compara a versao instalada com a publicada no release. Evita baixar
       centenas de megabytes para reinstalar o que ja esta na maquina. #>
    param([object]$Env, [object]$Origem)
    if (-not $Env.AppInstallerVersion -or -not $Origem.Versao) { return $false }
    try {
        $m = [regex]::Match("$($Origem.Versao)", '(\d+)\.(\d+)\.(\d+)')
        if (-not $m.Success) { return $false }
        $publicada = [version]$m.Value
        $mi = [regex]::Match("$($Env.AppInstallerVersion)", '(\d+)\.(\d+)\.(\d+)')
        if (-not $mi.Success) { return $false }
        $instalada = [version]$mi.Value
        return ($instalada -ge $publicada)
    } catch { return $false }
}

function Install-WingetPacoteOficial {
    <# Instala/atualiza o App Installer pelo pacote MSIX publicado pela Microsoft.
       E a camada que torna a preparacao independente da Microsoft Store: o
       pacote vem do repositorio oficial do Windows Package Manager, e conferido
       por SHA256 publicado e por assinatura da Microsoft, e so entao instalado. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env, [switch]$Interativo)

    $saida = New-WingetAcao 'PacoteOficial'

    if ($SemDownload) {
        $saida.Mensagem = 'a execucao pediu -SemDownload: o pacote oficial nao foi baixado'
        return $saida
    }
    if ($Env.Online -eq $false) {
        $saida.Mensagem = 'sem conectividade para obter o pacote oficial'
        return $saida
    }
    if ($Env.SideloadBlocked) {
        $saida.Mensagem = 'politica de sideload (AllowAllTrustedApps=0) impede instalar pacote MSIX assinado'
        return $saida
    }
    if ((Get-WingetMotorAppx) -eq 'indisponivel') {
        $saida.Mensagem = 'nenhum motor com cmdlets Appx neste sistema: o pacote nao pode ser instalado'
        return $saida
    }

    $origem = Get-WingetOrigemOficial
    if (-not $origem.Bundle) {
        $saida.Mensagem = 'nao foi possivel resolver o endereco oficial do pacote'
        return $saida
    }

    # Idempotencia: nada de reinstalar o que ja esta na versao publicada quando o
    # problema era so a versao. Estado quebrado continua reinstalando, porque ai
    # a reinstalacao E o reparo.
    if ($Env.State -eq 'Outdated' -and (Test-WingetVersaoJaAtual -Env $Env -Origem $origem)) {
        $saida.Mensagem = ('a versao instalada ({0}) ja e a publicada pela Microsoft ({1}): nada a baixar' -f $Env.AppInstallerVersion, $origem.Versao)
        return $saida
    }

    if ($origem.BundleBytes -gt 0 -and -not (Test-WingetEspacoLivre -BytesNecessarios $origem.BundleBytes)) {
        $saida.Mensagem = 'espaco em disco insuficiente na pasta temporaria para o pacote oficial'
        return $saida
    }
    if (-not (Confirm-WingetDownload -Descricao 'App Installer (Windows Package Manager)' -Bytes $origem.BundleBytes -Origem $origem.Origem)) {
        $saida.Mensagem = 'download recusado pelo operador'
        return $saida
    }

    $raiz = New-WingetPastaTemporaria
    if (-not $raiz) {
        $saida.Mensagem = 'sem pasta temporaria gravavel para o download'
        return $saida
    }

    $saida.Executado = $true
    $saida.Metodo    = ('Pacote oficial App Installer ({0})' -f $origem.Origem)

    $bundle = Join-Path $raiz 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $d = Save-WingetArquivoOficial -Uri $origem.Bundle -Destino $bundle -Rotulo 'App Installer (pacote oficial)'
    if (-not $d.Sucesso) { $saida.Mensagem = $d.Mensagem; return $saida }

    $conf = Test-WingetArquivoOficial -Caminho $bundle -HashEsperado $origem.BundleHash
    if (-not $conf.Confiavel) {
        $saida.Mensagem = ('pacote recusado: {0}' -f $conf.Motivo)
        Write-Log ERR ('O pacote baixado foi recusado e nao sera instalado. Motivo: {0}' -f $conf.Motivo)
        return $saida
    }
    Write-Log OK ('Pacote conferido ({0}).' -f $conf.Detalhe)

    # Reinstalar sobre uma instalacao existente exige aceitar qualquer versao:
    # sem isso, repor a MESMA versao sobre um pacote corrompido e recusado.
    $forcar = ($Env.AppInstaller -eq 'Presente' -or $Env.Provisioned)
    Write-Log INFO 'Instalando o App Installer a partir do pacote oficial...'
    $r = Install-WingetPacoteAppx -Caminho $bundle -ForcarQualquerVersao:$forcar -Atividade 'Instalar App Installer'

    if (-not $r.Success -and (Test-WingetFalhaDeDependencia $r.Error)) {
        # Falhou por dependencia: repor as dependencias e repetir - condicionado
        # ao erro real, nao uma segunda tentativa as cegas.
        Write-Log WARN ('A instalacao falhou por dependencia: {0}' -f $r.Error)
        $dep = Repair-WingetDependencias -Env $Env
        Add-WingetTrilha -Etapa 'Dependencias' -Diagnostico 'A instalacao do pacote oficial falhou por dependencia ausente.' `
            -Acao $dep.Metodo -Resultado $(if ($dep.Sucesso) { 'sucesso' } elseif ($dep.Executado) { 'falhou' } else { 'nao aplicavel' }) -Motivo $dep.Mensagem
        if ($dep.Sucesso) {
            Write-Log INFO 'Dependencias repostas. Repetindo a instalacao do pacote oficial...'
            $r = Install-WingetPacoteAppx -Caminho $bundle -ForcarQualquerVersao:$forcar -Atividade 'Instalar App Installer (apos dependencias)'
        } else {
            $saida.Mensagem = ('dependencia ausente e nao reposta: {0}' -f $dep.Mensagem)
            $saida.DependenciaAusente = $true
            return $saida
        }
    }

    if (-not $r.Success) {
        $saida.Mensagem = $r.Error
        $saida.DependenciaAusente = (Test-WingetFalhaDeDependencia $r.Error)
        return $saida
    }

    Update-WingetPathProcesso
    $saida.Sucesso = $true

    # Com privilegio e com a licenca publicada, provisionar deixa o pacote
    # disponivel para os demais perfis da maquina. E complemento: falhar aqui nao
    # invalida a instalacao que ja funcionou para este usuario.
    if ($Env.Admin -and $origem.Licenca) {
        $lic = Join-Path $raiz 'AppInstaller_License.xml'
        $dl  = Save-WingetArquivoOficial -Uri $origem.Licenca -Destino $lic -Rotulo 'licenca do pacote' -TimeoutSeconds 120
        if ($dl.Sucesso) {
            $cmd = "Import-Module Dism -ErrorAction SilentlyContinue; Add-AppxProvisionedPackage -Online -PackagePath '" + $bundle + "' -LicensePath '" + $lic + "' -ErrorAction Stop | Out-Null"
            $rp = Invoke-CompartDiskAppxScript -Comando $cmd -Activity 'Provisionar App Installer' -TimeoutSeconds 900
            if ($rp.Success) { Write-Log OK 'Pacote provisionado na imagem: os demais perfis desta maquina passam a receber o App Installer.' }
            else             { Write-Log WARN ('Provisionamento para todos os perfis nao concluiu: {0}' -f $rp.Error) }
        }
    }

    return $saida
}

# ------------------------------------------------------------------------------
# CAMADA 7 - MICROSOFT STORE (ultima, depende de operador)
# ------------------------------------------------------------------------------
function Install-WingetSupport {
    <# Encaminha para a pagina oficial do App Installer na Microsoft Store. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Env)

    $saida = New-WingetAcao 'StorePagina'

    if ($Env.StoreAvailable -eq $false) {
        $saida.Mensagem = 'Microsoft Store indisponivel ou removida por politica neste computador'
        return $saida
    }

    $uri = $script:WingetOficial.StorePagina -f $Env.StoreProductId
    $saida.Metodo = 'Microsoft Store (App Installer, ProductId ' + $Env.StoreProductId + ')'
    $r = Invoke-SafeCommand -Activity 'Abrir a Microsoft Store no App Installer' -ScriptBlock {
        Start-Process $uri -ErrorAction Stop
    }
    $saida.Executado = $true
    $saida.Sucesso   = $r.Success
    $saida.Pendente  = $r.Success
    if (-not $r.Success -and $r.Error) { $saida.Mensagem = $r.Error.Exception.Message }
    return $saida
}

function Update-WingetSupport {
    <# Encaminha para a tela oficial de atualizacoes da Store. Nao force a
       atualizacao: quem decide o momento e o Windows, com as politicas em vigor. #>
    [CmdletBinding()] param()
    $saida = New-WingetAcao 'StoreAtualizacao'
    $saida.Metodo = 'Microsoft Store (Downloads e atualizacoes)'
    $r = Invoke-SafeCommand -Activity 'Abrir atualizacoes da Microsoft Store' -ScriptBlock {
        Start-Process 'ms-windows-store://downloadsandupdates' -ErrorAction Stop
    }
    $saida.Executado = $true
    $saida.Sucesso   = $r.Success
    $saida.Pendente  = $r.Success
    if (-not $r.Success -and $r.Error) { $saida.Mensagem = $r.Error.Exception.Message }
    return $saida
}

# ------------------------------------------------------------------------------
# ORQUESTRACAO
# ------------------------------------------------------------------------------
function Get-WingetPlano {
    <# Monta a sequencia de camadas A PARTIR DO DIAGNOSTICO. Camada que nao tem
       o que fazer neste ambiente nao entra no plano - assim a execucao nunca
       gasta tempo repetindo algo que ja se sabe inaplicavel, e o operador ve
       exatamente o que sera tentado e por que. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Env, [switch]$SomenteReparo, [switch]$Interativo)

    $plano = New-Object System.Collections.ArrayList
    $incluir = {
        param($nome, $motivo)
        [void]$plano.Add([pscustomobject]@{ Nome = $nome; Motivo = $motivo })
    }

    $temPacote   = ($Env.AppInstaller -eq 'Presente' -or $Env.Provisioned)
    $exeExiste   = [bool]$Env.Executable
    $exeResponde = [bool]$Env.VersionText
    $servidor    = [bool]($Env.Windows -and ("$($Env.Windows.Caption)" -match '(?i)server'))
    $lojaUtil    = (($Env.StoreAvailable -ne $false) -and (-not $servidor))
    $semRede     = ($Env.Online -eq $false)

    # 1. PATH - o executavel existe e nao e alcancavel por "winget".
    if ($exeExiste -and $Env.ExecutableOrigin -ne 'PATH' -and $Env.AliasState -eq 'ok') {
        & $incluir 'PATH' ('winget.exe alcancado por {0}, fora do PATH.' -f $Env.ExecutableOrigin)
    }

    # 2. Fontes - o winget executa e a fonte oficial nao responde.
    if ($exeResponde -and $Env.SourcesOk -eq $false) {
        & $incluir 'Fontes' 'O winget executa, mas a fonte oficial nao respondeu.'
    }

    # 3. Dependencias - diagnosticadas como ausentes. Registrar sem elas falha
    #    com 0x80073CF3, entao vem antes do registro. No Windows 10 e a causa
    #    dominante; no Windows 11 as bibliotecas costumam vir na imagem.
    if ($Env.DependenciesOk -eq $false -and $Env.State -ne 'Outdated') {
        & $incluir 'Dependencias' 'Dependencias de runtime do App Installer ausentes.'
    }

    # 4. Registro - pacote na maquina e winget que nao executa. O estado
    #    'Nao verificavel' tambem entra: nao poder consultar o pacote nao e
    #    prova de que ele nao esta em disco, e a propria camada procura o
    #    manifesto antes de desistir.
    if ((-not $exeResponde) -and ($temPacote -or $Env.AliasState -eq 'quebrado' -or $Env.AppInstaller -eq 'Nao verificavel')) {
        $motivo = switch ($Env.PackageScope) {
            'outro perfil de usuario' { 'Pacote na maquina, sem registro neste perfil de usuario.' }
            'imagem do Windows'       { 'Pacote provisionado na imagem, sem registro para este usuario.' }
            default                   {
                if ($Env.AppInstaller -eq 'Nao verificavel') { 'Estado do pacote nao verificavel: procurar o manifesto local e registrar.' }
                else { 'Pacote presente e winget que nao executa: registro do perfil perdido.' }
            }
        }
        & $incluir 'Registro' $motivo
    }

    # -Action Repair para aqui: so o que e local e verificavel, sem rede.
    if ($SomenteReparo) { return ,$plano }

    # 5. Modulo oficial da Microsoft, quando ja instalado nesta maquina.
    if (-not $semRede) {
        & $incluir 'ModuloOficial' 'Reparo pela implementacao oficial da Microsoft, se o modulo estiver presente.'
    }

    # 6. Pacote oficial - a via que dispensa a Microsoft Store.
    if ((-not $semRede) -and (-not $SemDownload) -and (-not $Env.SideloadBlocked)) {
        $motivo = 'Pacote oficial da Microsoft, sem depender da Microsoft Store.'
        if ($Env.State -eq 'Outdated') { $motivo = 'Atualizacao pelo pacote oficial da Microsoft, sem depender da Store.' }
        & $incluir 'PacoteOficial' $motivo
    }

    # 7. Microsoft Store - por ultimo, e so onde ha operador e loja utilizavel.
    if ($Interativo -and $lojaUtil) {
        if ($Env.State -eq 'Outdated') { & $incluir 'StoreAtualizacao' 'Atualizacao pela tela oficial da Microsoft Store.' }
        else                           { & $incluir 'StorePagina'      'Pagina oficial do App Installer na Microsoft Store.' }
    }

    return ,$plano
}

function Invoke-WingetCamada {
    param([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][object]$Env, [switch]$Interativo)
    switch ($Nome) {
        'PATH'             { return (Repair-WingetPath          -Env $Env) }
        'Fontes'           { return (Repair-WingetSources       -Env $Env) }
        'Dependencias'     { return (Repair-WingetDependencias  -Env $Env) }
        'Registro'         { return (Repair-WingetSupport       -Env $Env) }
        'ModuloOficial'    { return (Repair-WingetModuloOficial -Env $Env) }
        'PacoteOficial'    { return (Install-WingetPacoteOficial -Env $Env -Interativo:$Interativo) }
        'StorePagina'      { return (Install-WingetSupport      -Env $Env) }
        'StoreAtualizacao' { return (Update-WingetSupport) }
    }
    $a = New-WingetAcao $Nome
    $a.Mensagem = ('camada nao reconhecida: {0}' -f $Nome)
    return $a
}

function Initialize-Winget {
    <# Orquestra: diagnostica, monta o plano de camadas, executa uma a uma,
       revalida depois de cada sucesso e so declara resultado com a bateria de
       validacao. Nunca afirma sucesso sem Test-WingetHealth passar. #>
    [CmdletBinding()] param([switch]$SomenteReparo)

    $script:Trilha.Clear()

    # A conectividade entra no diagnostico porque e ela que decide se as camadas
    # de rede sao aplicaveis - sem isso o plano ofereceria download em maquina
    # offline e a falha viria depois, sem explicacao.
    $env1 = Get-WingetEnvironment -ComConectividade
    Write-WingetDiagnostico -Env $env1

    switch ($env1.State) {
        'Available' {
            # Funcional nao quer dizer alcancavel: se o winget so responde fora
            # do PATH, o acesso pelo nome do comando e restabelecido aqui.
            $ajustou = Invoke-WingetAjustePath -Env $env1
            if ($ajustou) {
                $env1 = Get-WingetEnvironment
                Write-Log OK 'WinGet disponivel e funcional; o acesso pelo comando "winget" foi restabelecido.'
            } else {
                Write-Log OK 'WinGet ja esta disponivel e funcional. Nada a fazer.'
                Add-WingetTrilha -Etapa 'Diagnostico' -Diagnostico 'WinGet disponivel e funcional.' -Resultado 'nada a fazer'
            }
            return [pscustomobject]@{ Estado = 'Available'; Alterou = $ajustou; Ok = $true; Env = $env1 }
        }
        'Unsupported' {
            Write-Log WARN 'Este Windows nao atende aos requisitos necessarios para disponibilizar o WinGet.'
            Write-Color '  Nenhuma alteracao foi realizada.' -Color DarkGray
            Add-WingetTrilha -Etapa 'Diagnostico' -Diagnostico $env1.Reason -Resultado 'nao suportado'
            return [pscustomobject]@{ Estado = 'Unsupported'; Alterou = $false; Ok = $false; Env = $env1 }
        }
        'Blocked' {
            Write-Log WARN 'A politica deste computador impede a instalacao ou o uso do App Installer.'
            Write-Color '  Contate o administrador responsavel. Nenhuma politica foi alterada.' -Color DarkGray
            Add-WingetTrilha -Etapa 'Diagnostico' -Diagnostico $env1.PolicyDetail -Resultado 'bloqueado por politica'
            return [pscustomobject]@{ Estado = 'Blocked'; Alterou = $false; Ok = $false; Env = $env1 }
        }
    }

    # A partir daqui: Broken, Missing, Outdated ou Unknown.
    $interativo  = Test-ModoInterativo
    $versaoAntes = $env1.AppInstallerVersion
    $plano = Get-WingetPlano -Env $env1 -SomenteReparo:$SomenteReparo -Interativo:$interativo

    if (@($plano).Count -eq 0) {
        # Sem camada aplicavel: dizer POR QUE, e nao "falha ao instalar".
        $motivo = 'nenhuma estrategia e aplicavel a este ambiente'
        if ($SomenteReparo)              { $motivo = 'nao ha pacote local para reparar; a instalacao depende das camadas de rede ou da Microsoft Store' }
        elseif ($env1.Online -eq $false) { $motivo = 'sem conectividade e sem pacote local para reparar' }
        elseif ($SemDownload)            { $motivo = '-SemDownload em vigor e nao ha pacote local para reparar' }
        elseif (-not $interativo)        { $motivo = 'as estrategias restantes dependem da Microsoft Store, que exige um operador' }
        Write-Log WARN ('Nenhuma acao aplicada: {0}.' -f $motivo)
        Add-WingetTrilha -Etapa 'Plano' -Diagnostico (Get-WingetRotuloEstado $env1.State) -Resultado 'sem camada aplicavel' -Motivo $motivo
        Write-WingetTrilha
        return [pscustomobject]@{ Estado = $env1.State; Alterou = $false; Ok = $false; Env = $env1; Pendente = $true }
    }

    Write-Color ''
    Write-Log INFO ('Plano definido pelo diagnostico ({0} etapa(s)): {1}' -f `
        @($plano).Count, ((@($plano) | ForEach-Object { $_.Nome }) -join ' > '))

    $envAtual      = $env1
    $ultimoMetodo  = ''
    $alterou       = $false
    $pendente      = $false
    $repetirApos   = $null
    $depsInseridas = $false
    $i             = 0

    while ($i -lt $plano.Count) {
        $camada = $plano[$i]
        $i++
        Write-Color ''
        Write-Log INFO ('Etapa {0}/{1} - {2}: {3}' -f $i, $plano.Count, $camada.Nome, $camada.Motivo)

        $acao = Invoke-WingetCamada -Nome $camada.Nome -Env $envAtual -Interativo:$interativo
        if ($acao.Metodo) { $ultimoMetodo = $acao.Metodo }
        if ($acao.Executado -and $camada.Nome -notlike 'Store*') { $alterou = $true }

        $resultado = $(if ($acao.Sucesso) { 'sucesso' } elseif ($acao.Executado) { 'falhou' } else { 'nao aplicavel' })
        Add-WingetTrilha -Etapa $camada.Nome -Diagnostico $camada.Motivo -Acao $acao.Metodo -Resultado $resultado -Motivo $acao.Mensagem

        if ($acao.Sucesso) {
            Write-Log OK ('Etapa {0} concluida: {1}' -f $camada.Nome, $(if ($acao.Metodo) { $acao.Metodo } else { 'sem metodo declarado' }))
            if ($acao.Pendente) { $pendente = $true; break }

            Update-WingetPathProcesso
            $envAtual = Get-WingetEnvironment
            if ($envAtual.State -eq 'Available') { break }

            # Sucesso da camada nao e sucesso do objetivo: seguir para a proxima.
            Write-Log WARN ('O WinGet continua {0} apos a etapa {1}. Avaliando a proxima estrategia.' -f `
                (Get-WingetRotuloEstado $envAtual.State), $camada.Nome)

            if ($camada.Nome -eq 'Dependencias' -and $repetirApos) {
                [void]$plano.Insert($i, [pscustomobject]@{
                    Nome   = $repetirApos
                    Motivo = 'Repetida agora que as dependencias foram repostas.'
                })
                $repetirApos = $null
            }
        }
        elseif ($acao.Executado) {
            Write-Log WARN ('Etapa {0} nao resolveu: {1}' -f $camada.Nome, `
                $(if ($acao.Mensagem) { $acao.Mensagem } else { 'sem detalhe informado pelo sistema' }))

            # Encadeamento condicionado ao erro real: falha por dependencia
            # habilita a camada de dependencias e so entao repete a etapa. Uma
            # unica vez - repetir sem mudar nada seria falhar duas vezes igual.
            if ($acao.DependenciaAusente -and -not $depsInseridas) {
                $depsInseridas = $true
                $repetirApos   = $camada.Nome
                [void]$plano.Insert($i, [pscustomobject]@{
                    Nome   = 'Dependencias'
                    Motivo = ('A etapa {0} falhou por dependencia ausente.' -f $camada.Nome)
                })
            }
        }
        else {
            Write-Log INFO ('Etapa {0} nao se aplica: {1}' -f $camada.Nome, `
                $(if ($acao.Mensagem) { $acao.Mensagem } else { 'sem condicao para executar' }))
        }
    }

    Write-WingetTrilha

    if ($versaoAntes -or $envAtual.AppInstallerVersion) {
        Write-Log INFO ('Versao do App Installer antes: {0} | depois: {1}' -f `
            $(if ($versaoAntes) { $versaoAntes } else { 'n/d' }),
            $(if ($envAtual.AppInstallerVersion) { $envAtual.AppInstallerVersion } else { 'n/d' })) -NoConsole
    }

    # Encaminhamento para a Store nao conclui sozinho: depende do operador.
    if ($pendente) {
        Write-Color ''
        Write-Log INFO 'A Microsoft Store foi aberta na pagina oficial do App Installer.'
        Write-Color '  Conclua a instalacao na janela da Store e use "Verificar novamente".' -Color Gray
        $envF = Get-WingetEnvironment
        return [pscustomobject]@{ Estado = $envF.State; Alterou = $alterou; Ok = ($envF.State -eq 'Available'); Env = $envF; Metodo = $ultimoMetodo; Pendente = $true }
    }

    # Validacao de verdade antes de qualquer afirmacao de sucesso.
    Write-Color ''
    Write-Log INFO 'Validando o resultado...'
    $saude = Test-WingetHealth
    $envF  = $saude.Env

    if ($saude.Ok -and $envF.State -eq 'Available') {
        Write-Color ''
        Write-Log OK 'WinGet esta pronto para uso.'
        return [pscustomobject]@{ Estado = 'Available'; Alterou = $alterou; Ok = $true; Env = $envF; Metodo = $ultimoMetodo }
    }

    Write-Color ''
    if ($alterou) {
        Write-Log WARN 'As estrategias aplicaveis foram executadas, e o WinGet ainda nao passou na validacao.'
    } else {
        Write-Log ERR 'Nao foi possivel disponibilizar o WinGet por nenhum metodo oficial aplicavel a este ambiente.'
    }
    Write-Color ("  Estado final : {0}" -f (Get-WingetRotuloEstado $envF.State)) -Color DarkGray
    Write-Color ("  Motivo       : {0}" -f $envF.Reason) -Color DarkGray
    if ($envF.LastError) { Write-Color ("  Erro tecnico : {0}" -f $envF.LastError) -Color DarkGray }
    Write-Color '  Nenhuma alteracao insegura foi realizada.' -Color DarkGray

    return [pscustomobject]@{ Estado = $envF.State; Alterou = $alterou; Ok = $false; Env = $envF; Metodo = $ultimoMetodo }
}

# ------------------------------------------------------------------------------
# INTERFACE - somente numerica
# ------------------------------------------------------------------------------
function Write-WingetCabecalho {
    <# Delega ao ponto unico do Core: limpa a tela e desenha titulo e regua.
       Mantido como nome local para nao mexer nos pontos de chamada. #>
    param([string]$Titulo)
    Write-CompartDiskMenuCabecalho -Titulo $Titulo -Quiet:$Quiet
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
        # Preparar o WinGet inclui deixa-lo alcancavel pelo nome do comando: com
        # o executavel resolvido fora do PATH, a correcao acontece antes da ficha
        # ser desenhada, para que a tela mostre o estado ja corrigido.
        if (Invoke-WingetAjustePath -Env $env1) { $env1 = Get-WingetEnvironment }

        # O cabecalho abre a tela (e a limpa). Por isso ele vem ANTES do
        # diagnostico: desenhado depois, apagaria a ficha recem-impressa.
        $tituloTela = switch ("$($env1.State)") {
            'Available'   { 'WINGET DISPONIVEL' }
            'Unsupported' { 'WINGET NAO SUPORTADO' }
            'Blocked'     { 'WINGET BLOQUEADO POR POLITICA' }
            'Broken'      { 'PROBLEMA NO WINGET' }
            'Outdated'    { 'PROBLEMA NO WINGET' }
            default       { 'WINGET NAO DISPONIVEL' }
        }
        Write-WingetCabecalho $tituloTela
        Write-WingetDiagnostico -Env $env1

        if ($env1.State -eq 'Available') {
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
    Remove-WingetPastaTemporaria
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
