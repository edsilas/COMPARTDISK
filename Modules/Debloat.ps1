<#
 COMPARTDISK 1.3.1 - Debloat.ps1
 Desenvolvido por Edsilas
 Acoes: Analyze | Apps | Services | Tasks | Privacy | Tweaks | Components | Full
        Backup | Restore | RestorePoint

 PRINCIPIOS DESTE MODULO
 1. Simulacao e o padrao. A acao 'Analyze' nunca altera nada, e -DryRun aplica a
    mesma protecao a qualquer outra acao, inclusive a RestorePoint.
 2. Nada e removido por opiniao. Cada item do catalogo declara nivel de risco,
    motivo e reversibilidade, e so entra no nivel escolhido pelo operador.
 3. Listas de protecao vencem o catalogo. Um item protegido nunca e tocado, mesmo
    que seja pedido explicitamente por -Include, e aparece no relatorio como
    'Protegido' em vez de sumir em silencio.
 4. Toda alteracao e registrada em manifesto com o estado ANTERIOR, o que permite
    a acao 'Restore' devolver o sistema ao ponto de partida quando isso for
    tecnicamente possivel. Quando nao for, o manifesto diz exatamente por que.
 5. Nada e dado como aplicado sem reconsulta. Ausencia de excecao nao e prova de
    sucesso: o estado final e lido de volta do sistema antes de virar 'Aplicado'.
 6. Nao duplica outros modulos. Limpeza de temporarios pertence a Cleanup.ps1,
    telemetria a Telemetry.ps1 e plano de energia a Performance.ps1. Este modulo
    cobre apenas o que aqueles nao cobrem, e delega o resto.

 PRECEDENCIA DE SELECAO (deterministica, nesta ordem)
    PROTECAO  >  -Exclude  >  -Include  >  -Level
    Protecao e absoluta. -Exclude veta o que -Include pediu. -Include promove um
    item acima do nivel corrente (e isso e registrado no log). O nivel so decide
    o que entra quando nao ha -Include.

 VOCABULARIO DE RESULTADO (por item, sem sobreposicao semantica)
    Simulado      alteracao identificada, nada tocado
    Aplicado      alteracao executada E confirmada por reconsulta
    Parcial       parte das instancias mudou, parte falhou
    JaAplicado    sistema ja estava no estado desejado
    NaoInstalado  alvo ausente; para Debloat isso e objetivo ja atingido
    NaoSuportado  recurso, cmdlet ou build nao permite a operacao
    Protegido     bloqueado por lista de protecao, mesmo sob -Include
    Falhou        tentativa executada e nao confirmada
    Ignorado      nao avaliado (nao deve aparecer em operacao normal)
 E na acao Restore: Restaurado | JaRestaurado | NaoRestauravel | Falhou | Simulado

 CLASSIFICACAO DE RISCO (eixo distinto do resultado)
    O RESULTADO diz o que aconteceu; a CLASSE diz o que o alvo e. Sao eixos
    independentes e ambos aparecem no relatorio.

    Classes de preservacao - nunca vem do catalogo, sempre das listas de
    protecao, e nenhum item assim e tocado em qualquer nivel:
       ESSENCIAL     remocao quebra loja, logon, shell, rede ou atualizacao
       SISTEMA       componente de sistema, pacote nao removivel, tarefa de SO
       SEGURANCA     valor ou ramo que sustenta defesa, UAC ou criptografia
       DEPENDENCIA   framework ou pacote de recurso do qual outros dependem

    Classes de alteracao - atribuidas no catalogo, derivadas do nivel quando
    nao declaradas:
       DEBLOAT_SEGURO         elegivel a partir do nivel Safe
       DEBLOAT_MODERADO       elegivel a partir do nivel Moderate
       OPCIONAL               elegivel apenas em Aggressive
       RECOMENDADO_PRESERVAR  alto impacto; so entra com -Include explicito

    Classes de situacao - apuradas em tempo de execucao:
       INEXISTENTE   alvo ausente do sistema (resultado NaoInstalado)
       INCOMPATIVEL  nao existe nesta build/edicao (resultado NaoSuportado)
       ERRO          tentativa executada e nao confirmada (resultado Falhou)

 COMPATIBILIDADE DE PLATAFORMA
    Cada item pode declarar MinBuild, MaxBuild e Familia. Um ajuste aplicado na
    plataforma errada nao falha: fica inerte. Reportar isso como 'Aplicado'
    seria sucesso falso, entao o item e barrado antes da execucao e reportado
    como NaoSuportado com o motivo.
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Apps', 'Services', 'Tasks', 'Privacy', 'Tweaks', 'Components', 'Full', 'Backup', 'Restore', 'RestorePoint')]
    [string]$Action = 'Analyze',
    [ValidateSet('Safe', 'Moderate', 'Aggressive')]
    [string]$Level = 'Safe',
    [string[]]$Include = @(),
    [string[]]$Exclude = @(),
    [string]$ManifestPath = '',
    [switch]$DryRun,
    [switch]$SkipRestorePoint,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

# ==============================================================================
# 0. ESTADO GLOBAL DO MODULO
#    Um unico ponto de escrita. O estado so sobe (OK -> WARN -> ERROR) para que
#    um WARN tardio nunca apague um ERROR anterior, nem o contrario.
# ==============================================================================

$result = 'OK'
$script:DebloatRank = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-DebloatResultado {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Estado)
    $atual = "$script:result"
    if (-not $script:DebloatRank.ContainsKey($atual)) { $atual = 'OK' }
    if ($script:DebloatRank[$Estado] -gt $script:DebloatRank[$atual]) { $script:result = $Estado }
    return $script:result
}

# Caches de inventario. Preenchidos sob demanda e invalidados quando o modulo
# altera o proprio objeto consultado.
$script:CacheCatalogo   = $null
$script:CacheAppx       = $null
$script:CacheProv       = $null
$script:CacheProvSujo   = $true
$script:CacheServicos   = $null
$script:CacheTarefas    = $null
$script:CacheSsd        = 'nao-avaliado'
$script:RebootPendente  = $null
$script:CacheWindows    = $null

function Get-DebloatWindows {
    <# Retrato unico da plataforma, consultado uma vez por execucao. Alimenta o
       gate de compatibilidade do catalogo: escrever um valor que so existe no
       Windows 11 numa maquina Windows 10 nao falha - fica inerte, e um ajuste
       inerte reportado como 'Aplicado' e sucesso falso.

       Quando a consulta falha, devolve Conhecido=$false. Nesse caso o gate deixa
       o item passar em vez de barrar tudo: perder a deteccao de plataforma nao
       pode transformar o modulo inteiro em 'NaoSuportado'. #>
    if ($null -ne $script:CacheWindows) { return $script:CacheWindows }
    $out = [pscustomobject]@{
        Conhecido = $false; Build = 0; Familia = 'Desconhecida'
        IsWindows11 = $false; IsWindows10 = $false; Edicao = 'n/d'
    }
    try {
        $w = Test-WindowsVersion
        $out.Conhecido   = $true
        $out.Build       = [int]$w.Build
        $out.Familia     = "$($w.Family)"
        $out.IsWindows11 = [bool]$w.IsWindows11
        $out.IsWindows10 = [bool]$w.IsWindows10
        $out.Edicao      = "$($w.Caption)"
    } catch {
        Write-Log DEBUG "Plataforma nao identificada para o gate de compatibilidade: $($_.Exception.Message)" -NoConsole
    }
    $script:CacheWindows = $out
    return $out
}

# ==============================================================================
# 1. LISTAS DE PROTECAO
#    Avaliadas ANTES do catalogo e antes de -Include. Um item aqui nunca e
#    tocado. A regra e conservadora por desenho: na duvida, protege.
# ==============================================================================

# Familias Appx cuja remocao quebra a experiencia do Windows, a loja, a
# autenticacao, o menu Iniciar, a seguranca ou os codecs de midia.
$AppxProtegidos = @(
    'Microsoft.WindowsStore'
    'Microsoft.StorePurchaseApp'
    'Microsoft.DesktopAppInstaller'
    'Microsoft.WindowsTerminal'
    'Microsoft.SecHealthUI'
    'Microsoft.Windows.SecHealthUI'
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
    'Microsoft.Windows.Search'
    'Microsoft.Windows.CloudExperienceHost'
    'Microsoft.Windows.ContentDeliveryManager'
    'Microsoft.Windows.PeopleExperienceHost'
    'Microsoft.Windows.OOBENetworkConnectionFlow'
    'Microsoft.Windows.OOBENetworkCaptivePortal'
    'Microsoft.Windows.Apprep.ChxApp'
    'Microsoft.Windows.AssignedAccessLockApp'
    'Microsoft.Windows.CallingShellApp'
    'Microsoft.Windows.NarratorQuickStart'
    'Microsoft.Windows.ParentalControls'
    'Microsoft.Windows.PinningConfirmationDialog'
    'Microsoft.Windows.SecureAssessmentBrowser'
    'Microsoft.Windows.XGpuEjectDialog'
    'Microsoft.Windows.PrintQueueActionCenter'
    'Microsoft.AAD.BrokerPlugin'
    'Microsoft.AccountsControl'
    'Microsoft.AsyncTextService'
    'Microsoft.BioEnrollment'
    'Microsoft.CredDialogHost'
    'Microsoft.ECApp'
    'Microsoft.LockApp'
    'Microsoft.Win32WebViewHost'
    'Microsoft.XboxGameCallableUI'
    'Microsoft.MicrosoftEdge'
    'Microsoft.MicrosoftEdge.Stable'
    'Microsoft.MicrosoftEdgeDevToolsClient'
    'Microsoft.WebpImageExtension'
    'Microsoft.HEIFImageExtension'
    'Microsoft.HEVCVideoExtension'
    'Microsoft.VP9VideoExtensions'
    'Microsoft.RawImageExtension'
    'Microsoft.AV1VideoExtension'
    'Microsoft.WebMediaExtensions'
    'Microsoft.Services.Store.Engagement'
    'Microsoft.Advertising.Xaml'
    'Microsoft.WindowsStore.Engagement'
    'Microsoft.Windows.NarratorQuickStartApp'
    'Microsoft.Windows.CapturePicker'
    'Microsoft.Windows.PrintQueueActionCenterApp'
    'Microsoft.Windows.Cortana'
    'Microsoft.CredentialManagerUX'
    'Microsoft.WindowsSecurityCenter'
    'Microsoft.SecureAssessmentBrowser'
    'NcsiUwpApp'
    'Windows.CBSPreview'
    'Windows.PrintDialog'
    'Windows.immersivecontrolpanel'
)

# Prefixos de familia sempre protegidos (bibliotecas de runtime, o novo shell do
# Windows 11 e o proprio gerenciador de pacotes). Remover qualquer um deles
# derruba dezenas de aplicativos de uma vez.
$AppxPrefixosProtegidos = @(
    'Microsoft.VCLibs.'
    'Microsoft.NET.Native.'
    'Microsoft.NET.'
    'Microsoft.UI.Xaml.'
    'Microsoft.WindowsAppRuntime.'
    'MicrosoftWindows.Client.'
    'MicrosoftWindows.UndockedDevKit'
    'MicrosoftWindows.LKG.'
    'Microsoft.WindowsPackageManager'
    'Microsoft.Windows.Photos.MediaEngine'
    'Microsoft.MicrosoftEdgeWebView'
    'Microsoft.WinAppRuntime.'
)

# Servicos que sustentam atualizacao, seguranca, rede, audio, impressao, sessao,
# identidade e instalacao de software. Fora do alcance deste modulo em qualquer
# nivel, inclusive Aggressive.
$ServicosProtegidos = @(
    'wuauserv', 'BITS', 'CryptSvc', 'msiserver', 'TrustedInstaller', 'sppsvc'
    'UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'DeliveryOptimization'
    'WinDefend', 'SecurityHealthService', 'wscsvc', 'mpssvc', 'SgrmBroker'
    'Sense', 'WdNisSvc', 'webthreatdefsvc', 'wlidsvc'
    'EventLog', 'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'PlugPlay', 'Power'
    'Schedule', 'Winmgmt', 'ProfSvc', 'UserManager', 'SamSs', 'LSM'
    'Dhcp', 'Dnscache', 'nsi', 'NlaSvc', 'netprofm', 'LanmanWorkstation'
    'LanmanServer', 'WlanSvc', 'NetSetupSvc', 'WinHttpAutoProxySvc', 'NcbService'
    'AudioSrv', 'Audiosrv', 'AudioEndpointBuilder', 'Themes', 'ShellHWDetection'
    'CoreMessagingRegistrar', 'SystemEventsBroker', 'StateRepository'
    'TokenBroker', 'AppXSvc', 'ClipSVC', 'InstallService', 'EntAppSvc'
    'BFE', 'DPS', 'gpsvc', 'KeyIso', 'Netlogon', 'SENS', 'BrokerInfrastructure'
    'DispBrokerDesktopSvc', 'UdkUserSvc', 'CDPUserSvc', 'CDPSvc', 'WpnService'
    'Spooler', 'DeviceInstall', 'DevQueryBroker', 'VSS', 'swprv', 'srservice'
    'EFS', 'vaultsvc', 'SessionEnv', 'seclogon', 'Wcmsvc', 'WdiServiceHost'
)

# Prefixos de servico por sessao de usuario. O Windows sufixa a instancia com o
# LUID da sessao (CDPUserSvc_4a1b2), portanto comparacao exata nao basta.
$ServicosPrefixosProtegidos = @(
    'CDPUserSvc_', 'OneSyncSvc_', 'WpnUserService_', 'UdkUserSvc_', 'cbdhsvc_'
    'PimIndexMaintenanceSvc_', 'UnistoreSvc_', 'UserDataSvc_', 'MessagingService_'
    'DevicePickerUserSvc_', 'DevicesFlowUserSvc_', 'PrintWorkflowUserSvc_'
    'BluetoothUserService_', 'CaptureService_', 'ConsentUxUserSvc_'
    'CredentialEnrollmentManagerUserSvc_', 'DeviceAssociationBrokerSvc_'
    'NPSMSvc_', 'WpnUserService', 'AarSvc_', 'BcastDVRUserService_'
)

# Caminhos de tarefa agendada fora de alcance: atualizacao, defesa, recuperacao,
# manutencao do disco, servicing, criptografia de volume e diagnostico critico.
$TarefasProtegidas = @(
    '\Microsoft\Windows\WindowsUpdate\'
    '\Microsoft\Windows\UpdateOrchestrator\'
    '\Microsoft\Windows\WaaSMedic\'
    '\Microsoft\Windows\InstallService\'
    '\Microsoft\Windows\Servicing\'
    '\Microsoft\Windows\Setup\'
    '\Microsoft\Windows\Windows Defender\'
    '\Microsoft\Windows\ExploitGuard\'
    '\Microsoft\Windows\SystemRestore\'
    '\Microsoft\Windows\Recovery\'
    '\Microsoft\Windows\Chkdsk\'
    '\Microsoft\Windows\Data Integrity Scan\'
    '\Microsoft\Windows\Defrag\'
    '\Microsoft\Windows\DiskDiagnostic\'
    '\Microsoft\Windows\Maintenance\'
    '\Microsoft\Windows\MemoryDiagnostic\'
    '\Microsoft\Windows\BitLocker\'
    '\Microsoft\Windows\TPM\'
    '\Microsoft\Windows\CertificateServicesClient\'
    '\Microsoft\Windows\Time Synchronization\'
    '\Microsoft\Windows\Registry\'
    '\Microsoft\Windows\WOF\'
    '\Microsoft\Windows\StateRepository\'
    '\Microsoft\Windows\Task Manager\'
    '\Microsoft\Windows\Plug and Play\'
    '\Microsoft\Windows\RemoteAssistance\'
    '\Microsoft\Windows\User Profile Service\'
    '\Microsoft\Windows\Sysmain\'
    '\Microsoft\Windows\Storage Tiers Management\'
    '\Microsoft\Windows\Flighting\OneSettings\'
)

# Ramos de registro fora de alcance. Cobre o hive SYSTEM inteiro (boot, servicos,
# controle), a base de seguranca, e as chaves que sustentam logon, UAC, Defender,
# Windows Update e criptografia.
$RegistroProtegido = @(
    'HKLM:\SYSTEM'
    'HKLM:\SECURITY'
    'HKLM:\SAM'
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Winlogon'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    'HKLM:\SOFTWARE\Microsoft\Windows Defender'
    'HKLM:\SOFTWARE\Microsoft\Windows Security Health'
    'HKLM:\SOFTWARE\Microsoft\Cryptography'
    'HKLM:\SOFTWARE\Microsoft\SystemCertificates'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
    'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography'
    'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'
)

# Nomes de valor que desabilitam defesa, autenticacao ou atualizacao. Barrados em
# qualquer caminho, inclusive fora dos ramos protegidos acima. Nenhum item do
# catalogo atual usa estes nomes; a guarda existe para o catalogo futuro.
$RegistroValoresProibidos = @(
    'DisableAntiSpyware', 'DisableAntiVirus', 'DisableRealtimeMonitoring'
    'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableScriptScanning'
    'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable', 'ServiceKeepAlive'
    'EnableLUA', 'ConsentPromptBehaviorAdmin', 'ConsentPromptBehaviorUser'
    'PromptOnSecureDesktop', 'FilterAdministratorToken'
    'EnableSmartScreen', 'SmartScreenEnabled', 'ShellSmartScreenLevel'
    'EnableFirewall', 'DoNotAllowExceptions', 'DisableNotifications'
    'NoAutoUpdate', 'AUOptions', 'DisableWindowsUpdateAccess', 'WUServer'
    'DisableSR', 'DisableConfig', 'DisableTaskMgr', 'DisableRegistryTools'
    'DisableCMD', 'LocalAccountTokenFilterPolicy', 'LimitBlankPasswordUse'
)

# ==============================================================================
# 2. CATALOGO DECLARATIVO
#    Fonte unica de verdade. Cada entrada carrega o nivel minimo em que passa a
#    ser elegivel, o motivo tecnico, se a alteracao pode ser desfeita pela acao
#    Restore e se exige pedido explicito por -Include.
# ==============================================================================

function New-CatalogoItem {
    <# Classe e classificacao de RISCO; Nivel e escopo de execucao. Sao eixos
       diferentes e nao se substituem: o Nivel decide se o item entra na rodada,
       a Classe explica o que ele e. As classes de preservacao (ESSENCIAL,
       SISTEMA, SEGURANCA, DEPENDENCIA) nunca aparecem aqui - o catalogo so
       contem o que pode ser alterado. Elas sao atribuidas pelas listas de
       protecao, em Get-DebloatClasseProtecao.

       Compat declara em que plataforma o item faz efeito:
         MinBuild / MaxBuild - faixa de build (0 = sem limite)
         Familia             - 'Windows 11', 'Windows 10' ou vazio para ambas #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Appx', 'Service', 'Task', 'Registry')][string]$Tipo,
        [Parameter(Mandatory)][string]$Alvo,
        [Parameter(Mandatory)][string]$Categoria,
        [Parameter(Mandatory)][ValidateSet('Safe', 'Moderate', 'Aggressive')][string]$Nivel,
        [Parameter(Mandatory)][string]$Motivo,
        [bool]$Reversivel = $true,
        [bool]$RequerInclude = $false,
        [ValidateSet('DEBLOAT_SEGURO', 'DEBLOAT_MODERADO', 'OPCIONAL', 'RECOMENDADO_PRESERVAR')]
        [string]$Classe = '',
        [hashtable]$Compat = @{},
        [hashtable]$Dados = @{}
    )
    # Sem classe declarada, deriva-se do nivel: e o mesmo criterio que o operador
    # ja usa hoje, apenas explicitado.
    if ([string]::IsNullOrWhiteSpace($Classe)) {
        $Classe = switch ($Nivel) {
            'Safe'     { 'DEBLOAT_SEGURO' }
            'Moderate' { 'DEBLOAT_MODERADO' }
            default    { 'OPCIONAL' }
        }
    }
    if ($RequerInclude) { $Classe = 'RECOMENDADO_PRESERVAR' }

    return [pscustomobject]@{
        Id            = $Id
        Tipo          = $Tipo
        Alvo          = $Alvo
        Categoria     = $Categoria
        Nivel         = $Nivel
        Motivo        = $Motivo
        Reversivel    = $Reversivel
        RequerInclude = $RequerInclude
        Classe        = $Classe
        Compat        = $Compat
        Dados         = $Dados
    }
}

function Test-DebloatCompatibilidade {
    <# Decide se o item faz efeito NESTA plataforma. Devolve { Compativel,
       Motivo }. Um item declarado para outra familia ou fora da faixa de build
       nao e "falha": e INCOMPATIVEL, e o vocabulario do modulo ja tem o valor
       certo para isso - NaoSuportado.

       Plataforma desconhecida libera o item: perder a deteccao nao pode zerar o
       modulo. O executor ainda validara o resultado por reconsulta. #>
    param([Parameter(Mandatory)][object]$Item)
    $out = [pscustomobject]@{ Compativel = $true; Motivo = '' }

    $compat = $Item.Compat
    if ($null -eq $compat -or $compat.Count -eq 0) { return $out }

    $w = Get-DebloatWindows
    if (-not $w.Conhecido) { return $out }

    if ($compat.ContainsKey('Familia')) {
        $fam = "$($compat.Familia)"
        if ($fam -and $fam -ne $w.Familia) {
            $out.Compativel = $false
            $out.Motivo = ('destinado a {0}; esta maquina e {1}' -f $fam, $w.Familia)
            return $out
        }
    }
    if ($compat.ContainsKey('MinBuild')) {
        $min = [int]$compat.MinBuild
        if ($min -gt 0 -and $w.Build -lt $min) {
            $out.Compativel = $false
            $out.Motivo = ('exige build {0} ou superior; esta maquina tem {1}' -f $min, $w.Build)
            return $out
        }
    }
    if ($compat.ContainsKey('MaxBuild')) {
        $max = [int]$compat.MaxBuild
        if ($max -gt 0 -and $w.Build -gt $max) {
            $out.Compativel = $false
            $out.Motivo = ('valido ate a build {0}; esta maquina tem {1}' -f $max, $w.Build)
            return $out
        }
    }
    return $out
}

function Get-DebloatCatalogo {
    <# Construido uma unica vez por execucao e reaproveitado: Analyze, Backup,
       Full e Restore precisam enxergar exatamente a mesma lista. #>
    if ($null -ne $script:CacheCatalogo) { return $script:CacheCatalogo }

    $c = New-Object System.Collections.ArrayList
    $add = { param($i) [void]$c.Add($i) }

    # ---------- APLICATIVOS: nivel Safe ----------
    $appsSafe = @(
        @{ N = 'Microsoft.3DBuilder'; M = 'Modelagem 3D descontinuada pela Microsoft.' }
        @{ N = 'Microsoft.Microsoft3DViewer'; M = 'Visualizador 3D descontinuado.' }
        @{ N = 'Microsoft.Print3D'; M = 'Impressao 3D descontinuada.' }
        @{ N = 'Microsoft.MixedReality.Portal'; M = 'Portal de realidade mista descontinuado.' }
        @{ N = 'Microsoft.BingFinance'; M = 'Aplicativo de noticias financeiras com anuncios.' }
        @{ N = 'Microsoft.BingNews'; M = 'Aplicativo de noticias com anuncios.' }
        @{ N = 'Microsoft.BingSports'; M = 'Aplicativo de esportes com anuncios.' }
        @{ N = 'Microsoft.BingWeather'; M = 'Aplicativo de clima com anuncios.' }
        @{ N = 'Microsoft.BingTranslator'; M = 'Tradutor substituido por servico web.' }
        @{ N = 'Microsoft.BingFoodAndDrink'; M = 'Conteudo promocional pre-instalado.' }
        @{ N = 'Microsoft.BingHealthAndFitness'; M = 'Conteudo promocional pre-instalado.' }
        @{ N = 'Microsoft.BingTravel'; M = 'Conteudo promocional pre-instalado.' }
        @{ N = 'Microsoft.GetHelp'; M = 'Assistente de suporte redundante com a web.' }
        @{ N = 'Microsoft.Getstarted'; M = 'Aplicativo de dicas exibido apos a instalacao.' }
        @{ N = 'Microsoft.Messaging'; M = 'Mensagens SMS descontinuado no desktop.' }
        @{ N = 'Microsoft.MicrosoftOfficeHub'; M = 'Atalho promocional para o Microsoft 365.' }
        @{ N = 'Microsoft.MicrosoftSolitaireCollection'; M = 'Jogo com anuncios e assinatura.' }
        @{ N = 'Microsoft.NetworkSpeedTest'; M = 'Teste de velocidade redundante.' }
        @{ N = 'Microsoft.OneConnect'; M = 'Wi-Fi pago, descontinuado.' }
        @{ N = 'Microsoft.People'; M = 'Agenda de contatos legada.' }
        @{ N = 'Microsoft.SkypeApp'; M = 'Versao pre-instalada do Skype, descontinuada.' }
        @{ N = 'Microsoft.Todos'; M = 'Gerenciador de tarefas opcional.' }
        @{ N = 'Microsoft.Wallet'; M = 'Carteira digital descontinuada.' }
        @{ N = 'Microsoft.WindowsFeedbackHub'; M = 'Envio de feedback a Microsoft.' }
        @{ N = 'Microsoft.WindowsMaps'; M = 'Mapas offline raramente usados no desktop.' }
        @{ N = 'Microsoft.YourPhone'; M = 'Vinculo com celular, opcional.' }
        @{ N = 'Microsoft.PowerAutomateDesktop'; M = 'Automacao pre-instalada, opcional.' }
        @{ N = 'Microsoft.549981C3F5F10'; M = 'Aplicativo da Cortana.' }
        @{ N = 'Microsoft.Office.OneNote'; M = 'Versao da loja, substituida pela do Office.' }
        @{ N = 'MicrosoftTeams'; M = 'Teams pessoal pre-instalado.' }
        @{ N = 'MSTeams'; M = 'Teams pessoal pre-instalado.' }
        @{ N = 'Clipchamp.Clipchamp'; M = 'Editor de video pre-instalado.' }
        @{ N = 'Microsoft.Copilot'; M = 'Assistente pre-instalado, reinstalavel pela loja.' }
        @{ N = 'Microsoft.OutlookForWindows'; M = 'Novo Outlook pre-instalado, opcional.' }
        @{ N = 'Microsoft.Whiteboard'; M = 'Quadro branco colaborativo, opcional.' }
        @{ N = 'Microsoft.MicrosoftJournal'; M = 'Aplicativo de anotacoes a caneta, opcional.' }
        @{ N = 'Microsoft.MicrosoftPowerBIForWindows'; M = 'Cliente do Power BI pre-instalado.' }
        @{ N = 'Microsoft.RemoteDesktop'; M = 'Cliente de area de trabalho remota, opcional.' }
        @{ N = 'Microsoft.MinecraftUWP'; M = 'Jogo pre-instalado em alguns OEM.' }
        @{ N = 'Microsoft.MicrosoftStickyNotes'; M = 'Notas adesivas, sincronizadas na nuvem.' }
    )
    foreach ($a in $appsSafe) {
        & $add (New-CatalogoItem -Id "app:$($a.N)" -Tipo Appx -Alvo $a.N -Categoria 'Aplicativos' `
            -Nivel Safe -Motivo $a.M -Reversivel $false)
    }

    # Pre-instalados de terceiros. Casados por curinga porque o nome da familia
    # muda conforme o fabricante e a regiao do equipamento. A protecao e
    # reconfirmada no executor contra o nome REAL de cada pacote encontrado.
    $terceiros = @(
        '*CandyCrush*', '*BubbleWitch*', 'king.com.*', '*Spotify*', '*Disney*'
        '*Netflix*', '*Facebook*', '*Twitter*', '*TikTok*', '*Instagram*'
        '*LinkedIn*', '*Duolingo*', '*EclipseManager*', '*ActiproSoftware*'
        '*AdobeSystemsIncorporated.AdobePhotoshopExpress*', '*Dolby*'
        '*PrimeVideo*', '*Amazon.com.Amazon*', '*Hulu*', '*Booking.com*'
        '*iHeartRadio*', '*Plex*', '*Sidia.LiveWallpaper*', '*RoyalRevolt*'
        '*Wunderlist*', '*Flipboard*', '*Asphalt*', '*MarchofEmpires*'
        # Mensageria e redes sociais pre-instaladas pelo fabricante ou entregues
        # pelo ContentDeliveryManager. O nome da familia varia por publicador
        # (5319275A.WhatsAppDesktop e o mais comum), dai o curinga.
        '*WhatsApp*', '*Messenger*', '*Telegram*', '*Viber*', '*Line.Line*'
        # Antivirus e VPN de avaliacao. Nao substituem o Defender, que permanece
        # protegido: o que sai aqui e a versao de teste pre-instalada.
        '*McAfee*', '*Norton*', '*ExpressVPN*', '*Avast*', '*AVGTechnologies*'
        # Utilitarios e conteudo promocional de OEM.
        '*Keeper*', '*Dropbox*', '*Evernote*', '*Fitbit*', '*Prime*'
        '*SlingTV*', '*Spotify.AB*', '*PicsArt*', '*WinZip*', '*PowerDirector*'
        '*Sway*', '*Bing.Suggested*', '*Simple.Solitaire*', '*GAMELOFT*'
        '*Playtika*', '*Rovio*', '*ZeptoLab*', '*TheNewYorkTimes*'
    )
    foreach ($t in $terceiros) {
        & $add (New-CatalogoItem -Id "app:$t" -Tipo Appx -Alvo $t -Categoria 'Aplicativos' `
            -Nivel Safe -Motivo 'Aplicativo comercial pre-instalado pelo fabricante.' -Reversivel $false)
    }

    # Jogos casuais da propria Microsoft, entregues por provisionamento. Nenhum e
    # dependencia de nada: sao titulos avulsos com anuncio e assinatura. Ficam em
    # Safe pelo mesmo criterio ja aplicado ao Solitaire, que era o unico coberto.
    $jogos = @(
        @{ N = 'Microsoft.MicrosoftMahjong'; M = 'Jogo casual pre-instalado, com anuncios.' }
        @{ N = 'Microsoft.MicrosoftSudoku'; M = 'Jogo casual pre-instalado, com anuncios.' }
        @{ N = 'Microsoft.MicrosoftJigsaw'; M = 'Jogo casual pre-instalado, com anuncios.' }
        @{ N = 'Microsoft.MicrosoftTreasureHunt'; M = 'Jogo casual pre-instalado, com anuncios.' }
        @{ N = 'Microsoft.MicrosoftUltimateWordGames'; M = 'Jogo casual pre-instalado, com anuncios.' }
        @{ N = 'Microsoft.MicrosoftMinesweeper'; M = 'Jogo casual pre-instalado, com anuncios.' }
        @{ N = 'Microsoft.MicrosoftBingJigsaw'; M = 'Jogo casual pre-instalado, com anuncios.' }
        @{ N = 'Microsoft.CasualGames'; M = 'Pacote de jogos casuais pre-instalado.' }
        @{ N = 'Microsoft.MinecraftEducationEdition'; M = 'Edicao educacional do Minecraft, pre-instalada.' }
    )
    foreach ($j in $jogos) {
        & $add (New-CatalogoItem -Id "app:$($j.N)" -Tipo Appx -Alvo $j.N -Categoria 'Aplicativos' `
            -Nivel Safe -Motivo $j.M -Reversivel $false)
    }

    # Componentes de IA entregues como Appx. O aplicativo Copilot ja constava em
    # $appsSafe; aqui entram os pacotes irmaos que o acompanham a partir do
    # Windows 11 23H2. Nao sao o shell: MicrosoftWindows.Client.* continua
    # integralmente protegido e nada nesta lista casa com aquele prefixo.
    $iaApps = @(
        @{ N = 'Microsoft.Windows.Ai.Copilot.Provider'; M = 'Provedor do Copilot no shell; reinstalavel pela loja.'; B = 22000 }
        @{ N = 'Microsoft.Copilot.Native'; M = 'Componente nativo do Copilot.'; B = 22000 }
        @{ N = 'MicrosoftCorporationII.MicrosoftFamily'; M = 'Aplicativo Familia Microsoft, pre-instalado.'; B = 0 }
        @{ N = 'MicrosoftCorporationII.QuickAssist'; M = 'Assistencia rapida, reinstalavel pela loja.'; B = 0 }
    )
    foreach ($a in $iaApps) {
        $compat = @{}
        if ($a.B -gt 0) { $compat = @{ MinBuild = $a.B } }
        & $add (New-CatalogoItem -Id "app:$($a.N)" -Tipo Appx -Alvo $a.N -Categoria 'Aplicativos' `
            -Nivel Safe -Motivo $a.M -Reversivel $false -Compat $compat)
    }

    # ---------- APLICATIVOS: nivel Moderate ----------
    $appsModerate = @(
        @{ N = 'Microsoft.XboxApp'; M = 'Cliente Xbox legado.' }
        @{ N = 'Microsoft.Xbox.TCUI'; M = 'Interface de sobreposicao do Xbox.' }
        @{ N = 'Microsoft.XboxGameOverlay'; M = 'Sobreposicao de jogo do Xbox.' }
        @{ N = 'Microsoft.XboxGamingOverlay'; M = 'Barra de jogos (Win+G).' }
        @{ N = 'Microsoft.XboxSpeechToTextOverlay'; M = 'Legendas do Xbox.' }
        @{ N = 'Microsoft.GamingApp'; M = 'Aplicativo Xbox atual.' }
        @{ N = 'Microsoft.ZuneMusic'; M = 'Media Player padrao para audio.' }
        @{ N = 'Microsoft.ZuneVideo'; M = 'Filmes e TV, player padrao de video.' }
        @{ N = 'Microsoft.Windows.Photos'; M = 'Visualizador de imagens padrao.' }
        @{ N = 'Microsoft.WindowsCamera'; M = 'Aplicativo de camera padrao.' }
        @{ N = 'Microsoft.WindowsAlarms'; M = 'Alarmes e relogio.' }
        @{ N = 'Microsoft.WindowsSoundRecorder'; M = 'Gravador de voz.' }
        @{ N = 'microsoft.windowscommunicationsapps'; M = 'Email e Calendario do Windows.' }
        @{ N = 'Microsoft.Paint'; M = 'Paint da loja (Windows 11).' }
        @{ N = 'Microsoft.WindowsNotepad'; M = 'Bloco de Notas da loja (Windows 11).' }
        @{ N = 'Microsoft.QuickAssist'; M = 'Assistencia remota da Microsoft.' }
    )
    foreach ($a in $appsModerate) {
        & $add (New-CatalogoItem -Id "app:$($a.N)" -Tipo Appx -Alvo $a.N -Categoria 'Aplicativos' `
            -Nivel Moderate -Motivo $a.M -Reversivel $false)
    }

    # ---------- APLICATIVOS: nivel Aggressive ----------
    # RequerInclude marca o que nao entra so por escolher Aggressive: sao itens
    # cuja remocao muda comportamento visivel do sistema, entao exigem que o
    # operador cite o alvo em -Include.
    $appsAggressive = @(
        @{ N = 'Microsoft.WindowsCalculator'; M = 'Calculadora do Windows.'; X = $false }
        @{ N = 'Microsoft.WindowsFeedback'; M = 'Componente legado de feedback.'; X = $false }
        @{ N = 'Microsoft.ScreenSketch'; M = 'Ferramenta de Captura; assume a tecla Print Screen no Windows 11. Exige -Include.'; X = $true }
        @{ N = 'Microsoft.XboxIdentityProvider'; M = 'Autenticacao Xbox; jogos que usam login Xbox param de autenticar. Exige -Include.'; X = $true }
    )
    foreach ($a in $appsAggressive) {
        & $add (New-CatalogoItem -Id "app:$($a.N)" -Tipo Appx -Alvo $a.N -Categoria 'Aplicativos' `
            -Nivel Aggressive -Motivo $a.M -Reversivel $false -RequerInclude $a.X)
    }

    # ---------- SERVICOS ----------
    # DiagTrack e dmwappushservice ficam de fora de proposito: pertencem ao
    # modulo Telemetry.ps1. Duplicar aqui criaria duas fontes de verdade.
    $servicos = @(
        @{ N = 'MapsBroker'; Startup = 'Disabled'; L = 'Safe'; X = $false; M = 'Gerenciador de mapas baixados; sem uso se o app Mapas foi removido.' }
        @{ N = 'RetailDemo'; Startup = 'Disabled'; L = 'Safe'; X = $false; M = 'Modo de demonstracao de loja; irrelevante fora do varejo.' }
        @{ N = 'WMPNetworkSvc'; Startup = 'Disabled'; L = 'Safe'; X = $false; M = 'Compartilhamento de midia do Windows Media Player.' }
        @{ N = 'Fax'; Startup = 'Disabled'; L = 'Safe'; X = $false; M = 'Servico de fax analogico.' }
        @{ N = 'RemoteRegistry'; Startup = 'Disabled'; L = 'Safe'; X = $false; M = 'Acesso remoto ao registro; superficie de ataque sem uso domestico.' }
        @{ N = 'PrintNotify'; Startup = 'Manual'; L = 'Safe'; X = $false; M = 'Notificacoes de impressora; a fila de impressao continua funcionando.' }
        @{ N = 'WerSvc'; Startup = 'Manual'; L = 'Moderate'; X = $false; M = 'Relatorio de erros do Windows.' }
        @{ N = 'lfsvc'; Startup = 'Manual'; L = 'Moderate'; X = $false; M = 'Geolocalizacao; alguns aplicativos de clima e mapas dependem dela.' }
        @{ N = 'XblAuthManager'; Startup = 'Manual'; L = 'Moderate'; X = $false; M = 'Autenticacao Xbox Live.' }
        @{ N = 'XblGameSave'; Startup = 'Manual'; L = 'Moderate'; X = $false; M = 'Salvamento na nuvem do Xbox.' }
        @{ N = 'XboxNetApiSvc'; Startup = 'Manual'; L = 'Moderate'; X = $false; M = 'Rede do Xbox Live.' }
        @{ N = 'XboxGipSvc'; Startup = 'Manual'; L = 'Moderate'; X = $false; M = 'Acessorios Xbox conectados por USB.' }
        @{ N = 'SysMain'; Startup = 'Disabled'; L = 'Moderate'; X = $false; M = 'Superfetch; ganho nulo em SSD e custo de I/O em segundo plano. Preservado se o disco do sistema nao for confirmado como SSD.' }
        @{ N = 'TabletInputService'; Startup = 'Manual'; L = 'Aggressive'; X = $false; M = 'Teclado virtual e escrita a caneta; Manual mantem o acionamento sob demanda.' }
        @{ N = 'WSearch'; Startup = 'Disabled'; L = 'Aggressive'; X = $true; M = 'Indexacao do Windows Search; desativa a busca por arquivos no menu Iniciar e no Explorer. Exige -Include.' }
    )
    foreach ($s in $servicos) {
        & $add (New-CatalogoItem -Id "svc:$($s.N)" -Tipo Service -Alvo $s.N -Categoria 'Servicos' `
            -Nivel $s.L -Motivo $s.M -Reversivel $true -RequerInclude $s.X -Dados @{ Startup = $s.Startup })
    }

    # ---------- TAREFAS AGENDADAS ----------
    # As seis tarefas de telemetria classica pertencem ao Telemetry.ps1.
    $tarefas = @(
        @{ N = '\Microsoft\Windows\Application Experience\StartupAppTask'; L = 'Safe'; X = $false; M = 'Coleta de dados de aplicativos de inicializacao.' }
        @{ N = '\Microsoft\Windows\Application Experience\PcaPatchDbTask'; L = 'Safe'; X = $false; M = 'Banco de compatibilidade de aplicativos.' }
        @{ N = '\Microsoft\Windows\Windows Error Reporting\QueueReporting'; L = 'Safe'; X = $false; M = 'Envio de relatorios de erro a Microsoft.' }
        @{ N = '\Microsoft\Windows\CloudExperienceHost\CreateObjectTask'; L = 'Safe'; X = $false; M = 'Experiencia de nuvem na primeira execucao.' }
        @{ N = '\Microsoft\Windows\Maps\MapsToastTask'; L = 'Safe'; X = $false; M = 'Notificacoes do aplicativo Mapas.' }
        @{ N = '\Microsoft\Windows\Maps\MapsUpdateTask'; L = 'Safe'; X = $false; M = 'Atualizacao de mapas offline.' }
        @{ N = '\Microsoft\Windows\Retail Demo\CleanupOfflineContent'; L = 'Safe'; X = $false; M = 'Limpeza do modo demonstracao de loja.' }
        @{ N = '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'; L = 'Safe'; X = $false; M = 'Coleta de feedback por cenario.' }
        @{ N = '\Microsoft\Windows\DiskFootprint\Diagnostics'; L = 'Moderate'; X = $false; M = 'Diagnostico de uso de disco.' }
        @{ N = '\Microsoft\Office\OfficeTelemetryAgentLogOn'; L = 'Moderate'; X = $false; M = 'Telemetria do Microsoft Office.' }
        @{ N = '\Microsoft\Office\OfficeTelemetryAgentFallBack'; L = 'Moderate'; X = $false; M = 'Telemetria do Microsoft Office.' }
        @{ N = '\Microsoft\Windows\Windows Media Sharing\UpdateLibrary'; L = 'Moderate'; X = $false; M = 'Biblioteca compartilhada do Media Player.' }
        @{ N = '\Microsoft\Windows\Shell\FamilySafetyMonitor'; L = 'Moderate'; X = $true; M = 'Monitoramento de controle dos pais; desabilitar quebra limites de tempo e filtros de conta infantil. Exige -Include.' }
        @{ N = '\Microsoft\Windows\Shell\FamilySafetyRefreshTask'; L = 'Moderate'; X = $true; M = 'Atualizacao do controle dos pais; ver observacao acima. Exige -Include.' }
    )
    foreach ($t in $tarefas) {
        $pos = $t.N.LastIndexOf('\')
        & $add (New-CatalogoItem -Id "task:$($t.N)" -Tipo Task -Alvo $t.N -Categoria 'Tarefas' `
            -Nivel $t.L -Motivo $t.M -Reversivel $true -RequerInclude $t.X `
            -Dados @{ Caminho = $t.N.Substring(0, $pos + 1); Nome = $t.N.Substring($pos + 1) })
    }

    # ---------- PRIVACIDADE ----------
    # Complementa Telemetry.ps1 sem repetir nenhuma das cinco chaves que ele ja
    # controla (AllowTelemetry x2, CEIPEnable, AdvertisingInfo, Siuf).
    $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $privacidade = @(
        @{ P = $cdm; N = 'SilentInstalledAppsEnabled'; V = 0; L = 'Safe'; M = 'Instalacao silenciosa de aplicativos promovidos.' }
        @{ P = $cdm; N = 'PreInstalledAppsEnabled'; V = 0; L = 'Safe'; M = 'Reinstalacao automatica de aplicativos pre-instalados.' }
        @{ P = $cdm; N = 'OemPreInstalledAppsEnabled'; V = 0; L = 'Safe'; M = 'Reinstalacao de aplicativos do fabricante.' }
        @{ P = $cdm; N = 'SystemPaneSuggestionsEnabled'; V = 0; L = 'Safe'; M = 'Sugestoes de aplicativos no menu Iniciar.' }
        @{ P = $cdm; N = 'SoftLandingEnabled'; V = 0; L = 'Safe'; M = 'Dicas promocionais do Windows.' }
        @{ P = $cdm; N = 'SubscribedContent-338388Enabled'; V = 0; L = 'Safe'; M = 'Conteudo sugerido no menu Iniciar.' }
        @{ P = $cdm; N = 'SubscribedContent-338389Enabled'; V = 0; L = 'Safe'; M = 'Dicas e sugestoes na tela de bloqueio.' }
        @{ P = $cdm; N = 'SubscribedContent-353694Enabled'; V = 0; L = 'Safe'; M = 'Sugestoes na linha do tempo.' }
        @{ P = $cdm; N = 'SubscribedContent-353696Enabled'; V = 0; L = 'Safe'; M = 'Sugestoes em Configuracoes.' }
        @{ P = $cdm; N = 'RotatingLockScreenOverlayEnabled'; V = 0; L = 'Moderate'; M = 'Sobreposicao promocional do Windows Spotlight.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'; N = 'TailoredExperiencesWithDiagnosticDataEnabled'; V = 0; L = 'Safe'; M = 'Experiencias personalizadas por dados de diagnostico.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; N = 'ScoobeSystemSettingEnabled'; V = 0; L = 'Safe'; M = 'Tela de sugestoes apos atualizacoes.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\InputPersonalization'; N = 'RestrictImplicitTextCollection'; V = 1; L = 'Safe'; M = 'Coleta implicita de texto digitado.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\InputPersonalization'; N = 'RestrictImplicitInkCollection'; V = 1; L = 'Safe'; M = 'Coleta implicita de escrita a caneta.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Personalization\Settings'; N = 'AcceptedPrivacyPolicy'; V = 0; L = 'Safe'; M = 'Consentimento de personalizacao de entrada.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; N = 'BingSearchEnabled'; V = 0; L = 'Safe'; M = 'Busca da web dentro do menu Iniciar (efetivo no Windows 10; no Windows 11 22H2+ o efeito depende da politica DisableSearchBoxSuggestions).' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; N = 'CortanaConsent'; V = 0; L = 'Safe'; M = 'Consentimento da Cortana.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'DisableWebSearch'; V = 1; L = 'Moderate'; M = 'Politica de bloqueio da busca web.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'ConnectedSearchUseWeb'; V = 0; L = 'Moderate'; M = 'Consulta web na busca do sistema.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; N = 'AllowCortana'; V = 0; L = 'Moderate'; M = 'Politica de disponibilidade da Cortana.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; N = 'DisableWindowsConsumerFeatures'; V = 1; L = 'Moderate'; M = 'Recursos de consumo que reinstalam aplicativos.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; N = 'DisableCloudOptimizedContent'; V = 1; L = 'Moderate'; M = 'Conteudo otimizado por nuvem na interface.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_TrackProgs'; V = 0; L = 'Moderate'; M = 'Rastreamento de programas mais usados.' }
    )
    foreach ($p in $privacidade) {
        & $add (New-CatalogoItem -Id "reg:$($p.P)\$($p.N)" -Tipo Registry -Alvo "$($p.P)\$($p.N)" `
            -Categoria 'Privacidade' -Nivel $p.L -Motivo $p.M -Reversivel $true `
            -Dados @{ Caminho = $p.P; Nome = $p.N; Valor = $p.V; Tipo = 'DWord' })
    }

    # ---------- IA E EXPERIENCIAS DO CONSUMIDOR ----------
    # Copilot, Recall e Widgets nao sao um unico interruptor: existem como
    # aplicativo, como politica de maquina, como botao de shell e como recurso.
    # Remover so o Appx deixa o botao na barra e a politica ausente, e a
    # experiencia volta na atualizacao seguinte. Cada camada e um item proprio,
    # com o build minimo em que ela existe - abaixo dele o valor e inerte, e
    # aplicar valor inerte seria declarar sucesso sem efeito.
    #
    # Todos sao gravacao de valor, portanto reversiveis pela acao Restore, que
    # guarda o estado anterior no manifesto.
    $ia = @(
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; V = 1
           L = 'Moderate'; B = 22621; F = 'Windows 11'
           M = 'Politica de maquina que desliga o Copilot para todos os usuarios.' }
        @{ P = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; V = 1
           L = 'Moderate'; B = 22621; F = 'Windows 11'
           M = 'Mesma politica no perfil do usuario atual.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'ShowCopilotButton'; V = 0
           L = 'Moderate'; B = 22621; F = 'Windows 11'
           M = 'Oculta o botao do Copilot na barra de tarefas.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1
           L = 'Moderate'; B = 26100; F = 'Windows 11'
           M = 'Desliga o Recall, que captura e indexa imagens da tela. Aumenta a privacidade; nao desativa nenhum controle de seguranca.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'AllowRecallEnablement'; V = 0
           L = 'Moderate'; B = 26100; F = 'Windows 11'
           M = 'Impede que o Recall seja reativado por atualizacao ou por configuracao do usuario.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; V = 1
           L = 'Moderate'; B = 22621; F = 'Windows 11'
           M = 'Remove as sugestoes web da caixa de busca. E a chave que efetiva o bloqueio no Windows 11 22H2+, onde BingSearchEnabled sozinho nao basta.' }
        # Widgets: desativado por configuracao e politica, sem remover pacote. O
        # pacote MicrosoftWindows.Client.WebExperience permanece protegido pelo
        # prefixo do shell, e esta e a via reversivel de desligar a experiencia.
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; N = 'AllowNewsAndInterests'; V = 0
           L = 'Moderate'; B = 22000; F = 'Windows 11'
           M = 'Politica que desliga Widgets no Windows 11 sem remover o pacote do shell.' }
    )
    foreach ($k in $ia) {
        $compat = @{}
        if ($k.B -gt 0) { $compat['MinBuild'] = $k.B }
        if ($k.F)       { $compat['Familia']  = $k.F }
        & $add (New-CatalogoItem -Id "reg:$($k.P)\$($k.N)" -Tipo Registry -Alvo "$($k.P)\$($k.N)" `
            -Categoria 'Privacidade' -Nivel $k.L -Motivo $k.M -Reversivel $true -Compat $compat `
            -Dados @{ Caminho = $k.P; Nome = $k.N; Valor = $k.V; Tipo = 'DWord' })
    }

    # ---------- AJUSTES OPCIONAIS ----------
    # NtfsDisableLastAccessUpdate foi retirado: o valor so tem efeito em
    # HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem (ramo protegido) e o
    # mecanismo nativo e 'fsutil behavior set disablelastaccess'. Escrito no
    # caminho antigo (\Policies) era inerte.
    # O campo C declara a plataforma em que o ajuste tem efeito. TaskbarDa e
    # TaskbarMn so existem no shell do Windows 11, e EnableFeeds so no do
    # Windows 10: aplicados na plataforma errada nao falham, ficam inertes - e
    # eram reportados como 'Aplicado', que e sucesso sem efeito.
    $adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $tweaks = @(
        @{ P = $adv; N = 'HideFileExt'; V = 0; L = 'Safe'; C = @{}; M = 'Exibe a extensao dos arquivos; reduz risco de arquivo disfarcado.' }
        @{ P = $adv; N = 'LaunchTo'; V = 1; L = 'Safe'; C = @{}; M = 'Explorer abre em Este Computador em vez de Acesso Rapido.' }
        @{ P = $adv; N = 'ShowTaskViewButton'; V = 0; L = 'Safe'; C = @{}; M = 'Oculta o botao de Visao de Tarefas na barra.' }
        @{ P = $adv; N = 'TaskbarDa'; V = 0; L = 'Safe'; C = @{ Familia = 'Windows 11' }; M = 'Oculta Widgets na barra de tarefas do Windows 11.' }
        @{ P = $adv; N = 'TaskbarMn'; V = 0; L = 'Safe'; C = @{ Familia = 'Windows 11' }; M = 'Oculta o Chat na barra de tarefas do Windows 11.' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; N = 'EnableFeeds'; V = 0; L = 'Safe'; C = @{ Familia = 'Windows 10' }; M = 'Desativa Noticias e Interesses no Windows 10.' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard'; N = 'Disabled'; V = 1; L = 'Moderate'; C = @{}; M = 'Acoes sugeridas ao copiar texto.' }
        @{ P = $adv; N = 'ShowSyncProviderNotifications'; V = 0; L = 'Moderate'; C = @{}; M = 'Anuncios do OneDrive dentro do Explorer.' }
        @{ P = 'HKCU:\Control Panel\Desktop'; N = 'MenuShowDelay'; V = 200; L = 'Aggressive'; C = @{}; M = 'Reduz o atraso de abertura de menus de 400 ms para 200 ms.' }
    )
    foreach ($t in $tweaks) {
        $tipoReg = if ($t.P -eq 'HKCU:\Control Panel\Desktop') { 'String' } else { 'DWord' }
        $valor   = if ($tipoReg -eq 'String') { "$($t.V)" } else { $t.V }
        & $add (New-CatalogoItem -Id "reg:$($t.P)\$($t.N)" -Tipo Registry -Alvo "$($t.P)\$($t.N)" `
            -Categoria 'Ajustes' -Nivel $t.L -Motivo $t.M -Reversivel $true -Compat $t.C `
            -Dados @{ Caminho = $t.P; Nome = $t.N; Valor = $valor; Tipo = $tipoReg })
    }

    $script:CacheCatalogo = @($c)
    return $script:CacheCatalogo
}

# ==============================================================================
# 3. PROTECAO, SELECAO E VALIDACAO PREVIA
# ==============================================================================

$NiveisOrdem = @{ Safe = 1; Moderate = 2; Aggressive = 3 }

function Test-AppxProtegido {
    <# Protecao por nome exato ou por prefixo de familia. Aplicada antes de
       qualquer outra regra, inclusive antes de -Include. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return $true }
    if ($AppxProtegidos -contains $Nome) { return $true }
    foreach ($p in $AppxPrefixosProtegidos) {
        if ($Nome.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-DebloatAppxBloqueado {
    <# Segunda camada, estrutural: decide pelo que o pacote E, nao pelo nome que
       ele tem. Framework, recurso de idioma, pacote nao removivel e pacote
       assinado como componente de sistema ficam fora de alcance. #>
    param([Parameter(Mandatory)][object]$Pacote)
    $nome = "$($Pacote.Name)"
    if (Test-AppxProtegido -Nome $nome) { return 'lista de protecao' }
    if ($Pacote.PSObject.Properties.Name -contains 'IsFramework' -and $Pacote.IsFramework) { return 'framework' }
    if ($Pacote.PSObject.Properties.Name -contains 'IsResourcePackage' -and $Pacote.IsResourcePackage) { return 'pacote de recurso' }
    if ($Pacote.PSObject.Properties.Name -contains 'NonRemovable' -and $Pacote.NonRemovable) { return 'marcado como nao removivel' }
    if ($Pacote.PSObject.Properties.Name -contains 'SignatureKind' -and "$($Pacote.SignatureKind)" -eq 'System') { return 'componente de sistema' }
    return ''
}

function Test-ServicoProtegido {
    <# Nome exato mais prefixo de instancia por sessao (CDPUserSvc_4a1b2). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return $true }
    if ($ServicosProtegidos -contains $Nome) { return $true }
    foreach ($p in $ServicosPrefixosProtegidos) {
        if ($Nome.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    # Instancia por sessao: remove o sufixo _<luid> e reavalia a familia base.
    if ($Nome -match '^(?<base>.+?)_[0-9a-fA-F]{3,}$') {
        $base = $Matches['base']
        if ($ServicosProtegidos -contains $base) { return $true }
        foreach ($p in $ServicosPrefixosProtegidos) {
            if (("$base" + '_').StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    if ($Nome -like '*ServiceHost*' -or $Nome -like 'Wpn*' -or $Nome -like '*Defender*') { return $true }
    return $false
}

function Test-TarefaProtegida {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CaminhoCompleto)
    if ([string]::IsNullOrWhiteSpace($CaminhoCompleto)) { return $true }
    foreach ($p in $TarefasProtegidas) {
        if ($CaminhoCompleto.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-RegistroProtegido {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Caminho,
        [AllowEmptyString()][string]$Nome = ''
    )
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return $true }
    foreach ($r in $RegistroProtegido) {
        if ($Caminho.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    if ($Nome -and ($RegistroValoresProibidos -contains $Nome)) { return $true }
    return $false
}

function Get-DebloatMotivoProtecao {
    <# Devolve o motivo textual da protecao, ou string vazia quando o item esta
       liberado. Como string vazia e falsa em PowerShell, serve tanto para
       decidir quanto para explicar. #>
    param([Parameter(Mandatory)][object]$Item)
    switch ($Item.Tipo) {
        'Appx'     { if (Test-AppxProtegido    -Nome $Item.Alvo)                     { return 'familia Appx protegida' } }
        'Service'  { if (Test-ServicoProtegido -Nome $Item.Alvo)                     { return 'servico protegido' } }
        'Task'     { if (Test-TarefaProtegida  -CaminhoCompleto $Item.Alvo)          { return 'tarefa de sistema protegida' } }
        'Registry' {
            $cam = "$($Item.Dados.Caminho)"
            $nom = "$($Item.Dados.Nome)"
            # Os dois bloqueios sao reportados separadamente: um ramo protegido e
            # estrutura do sistema, um valor barrado e controle de seguranca. O
            # texto unico anterior impedia classificar corretamente qual dos dois
            # impediu a alteracao.
            if ($nom -and ($RegistroValoresProibidos -contains $nom)) {
                return 'valor de registro barrado por seguranca'
            }
            if (Test-RegistroProtegido -Caminho $cam -Nome $nom) { return 'ramo de registro protegido' }
        }
        default    { return 'tipo desconhecido' }
    }
    return ''
}

function Test-ItemProtegido {
    param([Parameter(Mandatory)][object]$Item)
    return [bool](Get-DebloatMotivoProtecao -Item $Item)
}

function Get-DebloatClasseProtecao {
    <# Traduz o motivo tecnico da protecao para a classe de risco correspondente.
       E o que responde "por que este item nao foi tocado" numa palavra, sem
       obrigar quem le o relatorio a interpretar o texto do motivo.

       Nao substitui o vocabulario de RESULTADO: um item barrado continua saindo
       como 'Protegido'. A classe acompanha, explicando a natureza do bloqueio. #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Motivo
    )
    if ([string]::IsNullOrWhiteSpace($Motivo)) { return $Item.Classe }

    # A ordem importa: o primeiro padrao que casar devolve. Os motivos mais
    # especificos vem antes dos mais genericos.
    switch -Wildcard ($Motivo) {
        '*barrado por seguranca*'     { return 'SEGURANCA' }
        '*framework*'                 { return 'DEPENDENCIA' }
        '*pacote de recurso*'         { return 'DEPENDENCIA' }
        '*componente de sistema*'     { return 'SISTEMA' }
        '*nao removivel*'             { return 'SISTEMA' }
        '*tarefa de sistema*'         { return 'SISTEMA' }
        '*ramo de registro*'          { return 'SISTEMA' }
        '*servico protegido*'         { return 'ESSENCIAL' }
        '*familia Appx protegida*'    { return 'ESSENCIAL' }
        '*lista de protecao*'         { return 'ESSENCIAL' }
        '*provisionamento protegido*' { return 'ESSENCIAL' }
        default                       { return 'SISTEMA' }
    }
}

function Test-DebloatPadrao {
    <# Casamento de um padrao de -Include/-Exclude contra um item. Compara Id,
       Alvo e Categoria; curinga e comparacao sem diferenciar maiusculas ficam a
       cargo do operador -like. #>
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][AllowEmptyString()][string]$Padrao)
    if ([string]::IsNullOrWhiteSpace($Padrao)) { return $false }
    return ($Item.Id -like $Padrao -or $Item.Alvo -like $Padrao -or $Item.Categoria -like $Padrao)
}

function Select-DebloatItens {
    <# Precedencia deterministica: PROTECAO > -Exclude > -Include > -Level.
       Devolve tambem o que foi barrado, para o relatorio poder mostrar em vez
       de esconder. #>
    param(
        [Parameter(Mandatory)][object[]]$Catalogo,
        [string]$NivelMaximo = 'Safe',
        [string[]]$Incluir = @(),
        [string[]]$Excluir = @()
    )
    $teto          = $NiveisOrdem[$NivelMaximo]
    $sel           = New-Object System.Collections.ArrayList
    $protegidos    = New-Object System.Collections.ArrayList
    $promovidos    = New-Object System.Collections.ArrayList
    $pendentes     = New-Object System.Collections.ArrayList
    $incompativeis = New-Object System.Collections.ArrayList

    foreach ($i in @($Catalogo)) {
        $pedidoExplicito = $false
        foreach ($p in @($Incluir)) {
            if (Test-DebloatPadrao -Item $i -Padrao $p) { $pedidoExplicito = $true; break }
        }

        # 1. Nivel (so decide quando nao ha -Include casando o item)
        $elegivel = ($NiveisOrdem[$i.Nivel] -le $teto)
        if (@($Incluir).Count -gt 0) { $elegivel = $pedidoExplicito }

        # 2. Itens de alto impacto exigem citacao explicita, mesmo em Aggressive
        if ($elegivel -and $i.RequerInclude -and -not $pedidoExplicito) {
            [void]$pendentes.Add($i)
            $elegivel = $false
        }
        if (-not $elegivel) { continue }

        # 3. -Exclude veta o que -Include pediu
        $vetado = $false
        foreach ($p in @($Excluir)) {
            if (Test-DebloatPadrao -Item $i -Padrao $p) { $vetado = $true; break }
        }
        if ($vetado) { continue }

        # 4. Protecao vence tudo, inclusive -Include "*"
        $motivo = Get-DebloatMotivoProtecao -Item $i
        if ($motivo) {
            Write-Log DEBUG "Item protegido ignorado: $($i.Id) ($motivo)" -NoConsole
            [void]$protegidos.Add([pscustomobject]@{
                Item = $i; Motivo = $motivo
                Classe = (Get-DebloatClasseProtecao -Item $i -Motivo $motivo)
            })
            continue
        }

        # 5. Compatibilidade de plataforma. Avaliada DEPOIS da protecao: um item
        #    protegido continua sendo reportado como protegido, nao como
        #    incompativel. Aplicar um ajuste inerte e sucesso falso, entao ele
        #    sai da selecao e e reportado - nunca silenciado.
        $compat = Test-DebloatCompatibilidade -Item $i
        if (-not $compat.Compativel) {
            Write-Log DEBUG "Item incompativel com esta plataforma: $($i.Id) ($($compat.Motivo))" -NoConsole
            [void]$incompativeis.Add([pscustomobject]@{ Item = $i; Motivo = $compat.Motivo })
            continue
        }

        if ($pedidoExplicito -and $NiveisOrdem[$i.Nivel] -gt $teto) { [void]$promovidos.Add($i) }
        [void]$sel.Add($i)
    }

    return [pscustomobject]@{
        Itens         = @($sel)
        Protegidos    = @($protegidos)
        Promovidos    = @($promovidos)
        Pendentes     = @($pendentes)
        Incompativeis = @($incompativeis)
    }
}

function Test-DebloatRebootPendente {
    if ($null -eq $script:RebootPendente) {
        try { $script:RebootPendente = [bool](Test-CompartDiskPendingReboot) }
        catch {
            Write-Log DEBUG "Nao foi possivel avaliar reinicio pendente: $($_.Exception.Message)" -NoConsole
            $script:RebootPendente = $false
        }
    }
    return $script:RebootPendente
}

function Get-DebloatEspacoLivre {
    $livre = 0
    try {
        $d = Get-CompartDiskCim -Class Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
        if ($d) { $livre = [double]$d.FreeSpace }
    } catch {
        Write-Log DEBUG "Espaco livre indisponivel: $($_.Exception.Message)" -NoConsole
    }
    return $livre
}

function Test-DebloatPreconditions {
    <# Separa impeditivo de aviso. Impeditivo aborta; aviso apenas informa e o
       fluxo segue, porque um reinicio pendente nao invalida, por exemplo,
       ajustes de registro no perfil do usuario. #>
    [CmdletBinding()] param()
    $avisos      = New-Object System.Collections.ArrayList
    $impeditivos = New-Object System.Collections.ArrayList

    try {
        $w = Test-WindowsVersion
        if (-not $w.Supported) {
            [void]$impeditivos.Add("Build $($w.Build) fora do escopo suportado (Windows 10/11).")
        }
    } catch {
        [void]$impeditivos.Add("Nao foi possivel identificar a versao do Windows: $($_.Exception.Message)")
    }

    if (-not (Test-Administrator)) {
        [void]$impeditivos.Add('Privilegios administrativos ausentes.')
    }

    if (Test-DebloatRebootPendente) {
        [void]$avisos.Add('Ha reinicio pendente. Alteracoes de servico e componente podem nao se consolidar ate reiniciar, e a limpeza de componentes sera pulada.')
    }

    if (-not (Test-CompartDiskCommand 'Get-AppxPackage')) {
        if (-not (Import-CompartDiskModule 'Appx')) {
            [void]$avisos.Add('Modulo Appx indisponivel: a remocao de aplicativos sera reportada como NaoSuportado.')
        }
    }

    if (-not (Test-CompartDiskCommand 'Get-ScheduledTask')) {
        [void]$avisos.Add('Modulo ScheduledTasks indisponivel: as tarefas agendadas serao reportadas como NaoSuportado.')
    }

    $livre = Get-DebloatEspacoLivre
    if ($livre -gt 0 -and $livre -lt 2GB) {
        [void]$avisos.Add("Espaco livre em $env:SystemDrive abaixo de 2 GB ($(ConvertTo-CompartDiskSize $livre)). A limpeza de componentes precisa de folga para trabalhar.")
    }

    return [pscustomobject]@{
        Ok          = ($impeditivos.Count -eq 0)
        Impeditivos = @($impeditivos)
        Avisos      = @($avisos)
        EspacoLivre = $livre
    }
}

function Test-SistemaEmSsd {
    <# Usado apenas para decidir sobre o SysMain: o Superfetch traz ganho real em
       disco mecanico e custo de I/O em estado solido. Devolve $true, $false ou
       $null (indeterminado). Discos externos sao descartados da amostra. #>
    if ($script:CacheSsd -ne 'nao-avaliado') { return $script:CacheSsd }
    $script:CacheSsd = $null
    try {
        if (-not (Test-CompartDiskCommand 'Get-PhysicalDisk')) { return $script:CacheSsd }
        $discos = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object {
            "$($_.BusType)" -notin @('USB', '1394', 'Fibre Channel', 'iSCSI', 'File Backed Virtual')
        })
        $tipos = @($discos | ForEach-Object { "$($_.MediaType)" } | Where-Object { $_ })
        if ($tipos.Count -eq 0) { return $script:CacheSsd }
        if ($tipos -contains 'HDD') { $script:CacheSsd = $false; return $script:CacheSsd }
        if ($tipos -contains 'SSD') { $script:CacheSsd = $true }
    } catch {
        Write-Log DEBUG "Tipo de midia indeterminado: $($_.Exception.Message)" -NoConsole
    }
    return $script:CacheSsd
}

# ==============================================================================
# 4. INVENTARIOS EM CACHE
#    Uma consulta por tipo de objeto por execucao, em vez de uma por item do
#    catalogo. A validacao pos-alteracao reconsulta apenas o alvo tocado.
# ==============================================================================

function Get-DebloatAppxInventario {
    param([switch]$Atualizar)
    if ($null -ne $script:CacheAppx -and -not $Atualizar) { return $script:CacheAppx }

    $inv = [pscustomobject]@{ Disponivel = $false; TodosUsuarios = $false; Pacotes = @() }
    if (-not (Test-CompartDiskCommand 'Get-AppxPackage')) {
        $script:CacheAppx = $inv
        return $inv
    }
    try {
        $inv.Pacotes       = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        $inv.TodosUsuarios = $true
        $inv.Disponivel    = $true
    } catch {
        Write-Log DEBUG "Inventario Appx para todos os usuarios indisponivel: $($_.Exception.Message)" -NoConsole
        try {
            $inv.Pacotes    = @(Get-AppxPackage -ErrorAction Stop)
            $inv.Disponivel = $true
            Write-Log WARN 'Inventario Appx limitado ao usuario atual (sem elevacao ou sem permissao). Pacotes de outros perfis nao serao vistos.'
        } catch {
            Write-Log WARN "Inventario Appx indisponivel: $($_.Exception.Message)"
        }
    }
    Write-Log DEBUG "Inventario Appx: $($inv.Pacotes.Count) pacote(s), todos os usuarios = $($inv.TodosUsuarios)" -NoConsole
    $script:CacheAppx = $inv
    return $inv
}

function Get-DebloatProvInventario {
    <# Reconstruido apenas quando alguma remocao de provisionamento marcou o
       cache como sujo, e nunca uma vez por item. #>
    param([switch]$Atualizar)
    if ($null -ne $script:CacheProv -and -not $script:CacheProvSujo -and -not $Atualizar) { return $script:CacheProv }

    $inv = [pscustomobject]@{ Disponivel = $false; Lista = @() }
    if (-not (Test-CompartDiskCommand 'Get-AppxProvisionedPackage')) {
        $script:CacheProv = $inv; $script:CacheProvSujo = $false
        return $inv
    }
    try {
        $inv.Lista      = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
        $inv.Disponivel = $true
    } catch {
        Write-Log WARN "Inventario de pacotes provisionados indisponivel: $($_.Exception.Message)"
    }
    $script:CacheProv     = $inv
    $script:CacheProvSujo = $false
    return $inv
}

function Get-DebloatServicosInventario {
    if ($null -ne $script:CacheServicos) { return $script:CacheServicos }
    $tab = @{}
    try {
        foreach ($s in @(Get-CompartDiskCim -Class Win32_Service)) {
            if (-not $s.Name) { continue }
            $tab["$($s.Name)".ToLowerInvariant()] = [pscustomobject]@{
                Nome        = "$($s.Name)"
                StartMode   = "$($s.StartMode)"
                State       = "$($s.State)"
                Delayed     = [bool]$s.DelayedAutoStart
                DisplayName = "$($s.DisplayName)"
            }
        }
    } catch {
        Write-Log WARN "Inventario de servicos via CIM indisponivel, caindo para consulta individual: $($_.Exception.Message)"
    }
    $script:CacheServicos = $tab
    return $tab
}

function Get-DebloatServicoEstado {
    <# Estado corrente de um servico. Com -Atualizar, reconsulta o sistema e
       atualiza o cache: e o que sustenta a validacao pos-alteracao. #>
    param([Parameter(Mandatory)][string]$Nome, [switch]$Atualizar)
    $inv   = Get-DebloatServicosInventario
    $chave = $Nome.ToLowerInvariant()

    if ($Atualizar -or -not $inv.ContainsKey($chave)) {
        $achou = $false
        try {
            $esc = $Nome.Replace("'", "''")
            $s = Get-CompartDiskCim -Class Win32_Service -Filter "Name='$esc'"
            if ($s) {
                $achou = $true
                $inv[$chave] = [pscustomobject]@{
                    Nome        = "$($s.Name)"
                    StartMode   = "$($s.StartMode)"
                    State       = "$($s.State)"
                    Delayed     = [bool]$s.DelayedAutoStart
                    DisplayName = "$($s.DisplayName)"
                }
            }
        } catch {
            Write-Log DEBUG "Consulta CIM ao servico $Nome falhou: $($_.Exception.Message)" -NoConsole
        }
        if (-not $achou) {
            # Ultimo recurso: o servico pode existir sem estar visivel no CIM.
            try {
                $sc = Get-Service -Name $Nome -ErrorAction Stop
                $inv[$chave] = [pscustomobject]@{
                    Nome        = "$($sc.Name)"
                    StartMode   = $(if ($sc.PSObject.Properties.Name -contains 'StartType') { "$($sc.StartType)" } else { 'n/d' })
                    State       = "$($sc.Status)"
                    Delayed     = $false
                    DisplayName = "$($sc.DisplayName)"
                }
                $achou = $true
            } catch {
                Write-Log DEBUG "Servico $Nome ausente: $($_.Exception.Message)" -NoConsole
                if ($inv.ContainsKey($chave)) { [void]$inv.Remove($chave) }
            }
        }
    }
    if ($inv.ContainsKey($chave)) { return $inv[$chave] }
    return $null
}

function ConvertTo-DebloatStartType {
    <# Normaliza os vocabularios diferentes de Win32_Service (Auto/Manual/
       Disabled), ServiceController (Automatic/Manual/Disabled) e Set-Service. #>
    param([AllowEmptyString()][AllowNull()][string]$Valor)
    switch -Regex ("$Valor".Trim()) {
        '^(Auto|Automatic)$'          { return 'Automatic' }
        '^Auto.*Delayed.*$'           { return 'Automatic' }
        '^(Manual|Demand)$'           { return 'Manual' }
        '^Disabled$'                  { return 'Disabled' }
        '^Boot$'                      { return 'Boot' }
        '^System$'                    { return 'System' }
        default                       { return '' }
    }
}

function Get-DebloatTarefasInventario {
    <# Carrega o flag Disponivel junto com a tabela. Sem ele, uma falha de
       enumeracao viraria 'tarefa inexistente' - o modulo estaria afirmando
       algo que nao verificou. #>
    if ($null -ne $script:CacheTarefas) { return $script:CacheTarefas }
    $inv = [pscustomobject]@{ Disponivel = $false; Tabela = @{} }
    if (Test-CompartDiskCommand 'Get-ScheduledTask') {
        try {
            foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
                $inv.Tabela["$($t.TaskPath)$($t.TaskName)".ToLowerInvariant()] = $t
            }
            $inv.Disponivel = $true
        } catch {
            Write-Log WARN "Inventario de tarefas agendadas indisponivel: $($_.Exception.Message)"
        }
    }
    $script:CacheTarefas = $inv
    return $inv
}

function Get-DebloatTarefaEstado {
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][string]$Nome,
        [switch]$Atualizar
    )
    $tab   = (Get-DebloatTarefasInventario).Tabela
    $chave = "$Caminho$Nome".ToLowerInvariant()
    if ($Atualizar -or -not $tab.ContainsKey($chave)) {
        if (Test-CompartDiskCommand 'Get-ScheduledTask') {
            try {
                $t = Get-ScheduledTask -TaskName $Nome -TaskPath $Caminho -ErrorAction Stop
                if ($t) { $tab[$chave] = $t }
            } catch {
                Write-Log DEBUG "Tarefa $Caminho$Nome ausente: $($_.Exception.Message)" -NoConsole
                if ($tab.ContainsKey($chave)) { [void]$tab.Remove($chave) }
            }
        }
    }
    if ($tab.ContainsKey($chave)) { return $tab[$chave] }
    return $null
}

function Get-DebloatRegistroEstado {
    <# Le valor E tipo reais. O tipo importa: restaurar um REG_SZ como DWORD
       corromperia a configuracao em vez de devolve-la. #>
    param([Parameter(Mandatory)][string]$Caminho, [Parameter(Mandatory)][string]$Nome)
    $out = [pscustomobject]@{ ChaveExiste = $false; Existe = $false; Valor = $null; Tipo = ''; Erro = '' }
    try {
        if (-not (Test-Path -LiteralPath $Caminho)) { return $out }
        $out.ChaveExiste = $true
        $chave = Get-Item -LiteralPath $Caminho -ErrorAction Stop
        $nomes = @($chave.GetValueNames())
        if ($nomes -notcontains $Nome) { return $out }
        $out.Existe = $true
        $out.Valor  = $chave.GetValue($Nome)
        $out.Tipo   = "$($chave.GetValueKind($Nome))"
    } catch {
        $out.Erro = $_.Exception.Message
        Write-Log DEBUG "Leitura de registro falhou em $Caminho\$Nome : $($out.Erro)" -NoConsole
    }
    return $out
}

# ==============================================================================
# 5. MANIFESTO DE REVERSAO
#    Nao e log: e o plano de volta. Guarda estado anterior, estado posterior,
#    reversibilidade real e o erro quando houver.
# ==============================================================================

$script:ManifestoSchema = 2

function Get-DebloatPastaRestauracao {
    <# Fora do diretorio de sessao: a restauracao precisa sobreviver a sessoes
       futuras, enquanto OutDir e recriado a cada execucao. #>
    $p = Join-Path $Global:CompartDisk.LogDir 'COMPARTDISK_Restauracao'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function New-DebloatManifesto {
    param([string]$Acao, [string]$NivelUsado, [bool]$Simulacao = $false)
    return [pscustomobject]@{
        Produto    = $Global:CompartDisk.Product
        Versao     = $Global:CompartDisk.Version
        Schema     = $script:ManifestoSchema
        Sessao     = $Global:CompartDisk.Session
        Computador = $Global:CompartDisk.Computer
        Usuario    = $Global:CompartDisk.User
        Acao       = $Acao
        Nivel      = $NivelUsado
        Simulacao  = $Simulacao
        Criado     = (Get-Date -Format 's')
        Itens      = (New-Object System.Collections.ArrayList)
    }
}

function Add-DebloatRegistro {
    <# Grava o estado ANTERIOR do item, o posterior confirmado e a
       reversibilidade REAL daquela alteracao especifica - que nem sempre e a
       reversibilidade declarada no catalogo. #>
    param(
        [Parameter(Mandatory)][object]$Manifesto,
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$Resultado,
        [object]$EstadoAnterior = $null,
        [object]$EstadoPosterior = $null,
        [string]$Detalhe = '',
        [string]$Erro = '',
        [object]$Reversivel = $null
    )
    if ($null -eq $Reversivel) {
        $Reversivel = $false
        if ($Item.PSObject.Properties.Name -contains 'Reversivel') { $Reversivel = [bool]$Item.Reversivel }
    }
    # So faz sentido chamar de reversivel o que de fato mudou e tem estado
    # anterior guardado.
    $revReal = ([bool]$Reversivel -and $null -ne $EstadoAnterior -and $Resultado -in @('Aplicado', 'Parcial'))

    [void]$Manifesto.Itens.Add([pscustomobject]@{
        Id              = $Item.Id
        Tipo            = $Item.Tipo
        Alvo            = $Item.Alvo
        Categoria       = $Item.Categoria
        Nivel           = $Item.Nivel
        Resultado       = $Resultado
        EstadoAnterior  = $EstadoAnterior
        EstadoPosterior = $EstadoPosterior
        Reversivel      = [bool]$Reversivel
        ReversivelReal  = $revReal
        Detalhe         = $Detalhe
        Erro            = $Erro
        Quando          = (Get-Date -Format 's')
    })
}

function Save-DebloatManifesto {
    <# Gravacao atomica com validacao: gera o JSON, escreve em arquivo temporario,
       reabre e faz ConvertFrom-Json, e so entao substitui o destino final. Um
       manifesto truncado e pior que manifesto nenhum, porque cria a ilusao de
       que existe caminho de volta. #>
    param([Parameter(Mandatory)][object]$Manifesto, [switch]$Obrigatorio)

    $saida = [pscustomobject]@{ Ok = $false; Caminhos = @(); Erro = '' }
    if (@($Manifesto.Itens).Count -eq 0) {
        Write-Log DEBUG 'Manifesto sem itens: nada a gravar.' -NoConsole
        return $saida
    }

    $nome = 'Debloat_Manifesto_{0}.json' -f $Global:CompartDisk.Session
    $json = $null
    try {
        $copia = $Manifesto | Select-Object * -ExcludeProperty Itens
        $copia | Add-Member -NotePropertyName Itens -NotePropertyValue @($Manifesto.Itens) -Force
        $json = $copia | ConvertTo-Json -Depth 12
    } catch {
        $saida.Erro = "Serializacao do manifesto falhou: $($_.Exception.Message)"
        Write-Log ERR $saida.Erro -ErrorRecord $_
        Set-DebloatResultado 'ERROR' | Out-Null
        return $saida
    }

    $enc      = New-Object System.Text.UTF8Encoding($false)
    $destinos = @(
        (Join-Path (Get-DebloatPastaRestauracao) $nome)
        (Join-Path $Global:CompartDisk.OutDir $nome)
    )
    $gravados = New-Object System.Collections.ArrayList

    foreach ($d in $destinos) {
        $tmp = "$d.tmp"
        try {
            [System.IO.File]::WriteAllText($tmp, $json, $enc)
            $lido = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
            $obj  = $lido | ConvertFrom-Json
            if (-not $obj -or -not $obj.Itens -or @($obj.Itens).Count -ne @($Manifesto.Itens).Count) {
                throw "Releitura do manifesto nao conferiu ($(@($obj.Itens).Count) de $(@($Manifesto.Itens).Count) itens)."
            }
            [System.IO.File]::Copy($tmp, $d, $true)
            [System.IO.File]::Delete($tmp)
            [void]$gravados.Add($d)
        } catch {
            Write-Log WARN "Nao foi possivel gravar o manifesto em: $d" -ErrorRecord $_
            try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } }
            catch { Write-Log DEBUG "Temporario residual em $tmp" -NoConsole }
        }
    }

    foreach ($g in $gravados) { Write-Log OK "Manifesto de reversao: $g" }
    $saida.Caminhos = @($gravados)
    $saida.Ok       = ($gravados.Count -gt 0)

    if (-not $saida.Ok) {
        $saida.Erro = 'Nenhum destino de manifesto pode ser gravado.'
        if ($Obrigatorio) {
            Write-Log ERR 'Alteracoes foram aplicadas e o manifesto NAO pode ser gravado: a acao Restore nao tera como desfaze-las.'
            Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Manifesto de reversao nao pode ser gravado apos alteracoes reais.' `
                -Recommendation 'Verifique permissao e espaco no diretorio de logs. Considere restaurar pelo ponto de restauracao do sistema.'
            Set-DebloatResultado 'ERROR' | Out-Null
        } else {
            Write-Log WARN 'Manifesto nao pode ser gravado.'
            Set-DebloatResultado 'WARN' | Out-Null
        }
    } elseif ($gravados.Count -lt $destinos.Count) {
        Write-Log WARN 'Manifesto gravado em apenas um dos dois destinos previstos.'
    }
    return $saida
}

function Test-DebloatManifesto {
    <# Validacao estrutural antes de qualquer tentativa de reversao. #>
    param([object]$Manifesto, [string]$Origem = '')
    $problemas = New-Object System.Collections.ArrayList

    if ($null -eq $Manifesto) { [void]$problemas.Add('Conteudo vazio ou JSON invalido.') }
    else {
        if (-not ($Manifesto.PSObject.Properties.Name -contains 'Itens')) { [void]$problemas.Add("Campo 'Itens' ausente.") }
        if (-not ($Manifesto.PSObject.Properties.Name -contains 'Produto')) { [void]$problemas.Add("Campo 'Produto' ausente.") }
        if ($Manifesto.PSObject.Properties.Name -contains 'Produto' -and
            "$($Manifesto.Produto)" -ne "$($Global:CompartDisk.Product)") {
            [void]$problemas.Add("Manifesto de outro produto: '$($Manifesto.Produto)'.")
        }
        $schema = 1
        if ($Manifesto.PSObject.Properties.Name -contains 'Schema' -and $Manifesto.Schema) { $schema = [int]$Manifesto.Schema }
        if ($schema -gt $script:ManifestoSchema) {
            [void]$problemas.Add("Schema $schema e mais novo que o suportado ($script:ManifestoSchema).")
        }
        if ($Manifesto.PSObject.Properties.Name -contains 'Simulacao' -and $Manifesto.Simulacao) {
            [void]$problemas.Add('Manifesto gerado em simulacao: nao descreve alteracoes reais.')
        }
        if ($problemas.Count -eq 0) {
            $tiposOk = @('Appx', 'Service', 'Task', 'Registry', 'Componente')
            foreach ($it in @($Manifesto.Itens)) {
                if (-not $it.Tipo -or -not $it.Alvo -or -not $it.Resultado) {
                    [void]$problemas.Add('Ha item sem Tipo, Alvo ou Resultado.')
                    break
                }
                if ($tiposOk -notcontains "$($it.Tipo)") {
                    [void]$problemas.Add("Tipo nao suportado no manifesto: '$($it.Tipo)'.")
                    break
                }
            }
        }
    }

    return [pscustomobject]@{
        Ok        = ($problemas.Count -eq 0)
        Problemas = @($problemas)
        Origem    = $Origem
        Schema    = $(if ($Manifesto -and ($Manifesto.PSObject.Properties.Name -contains 'Schema')) { $Manifesto.Schema } else { 1 })
    }
}

function Get-DebloatUltimoManifesto {
    <# Com -Caminho, respeita EXATAMENTE o arquivo pedido e nunca cai para outro.
       Sem -Caminho, escolhe o mais recente da pasta de restauracao. #>
    param([string]$Caminho = '')

    if ($Caminho) {
        if (-not (Test-Path -LiteralPath $Caminho)) { throw "Manifesto nao encontrado: $Caminho" }
        $bruto = $null
        try { $bruto = Get-Content -LiteralPath $Caminho -Raw -Encoding UTF8 }
        catch { throw "Manifesto ilegivel ($Caminho): $($_.Exception.Message)" }
        if ([string]::IsNullOrWhiteSpace($bruto)) { throw "Manifesto vazio: $Caminho" }
        try { $obj = $bruto | ConvertFrom-Json }
        catch { throw "Manifesto com JSON invalido ($Caminho): $($_.Exception.Message)" }
        Write-Log INFO "Manifesto informado por -ManifestPath: $Caminho"
        return [pscustomobject]@{ Manifesto = $obj; Arquivo = $Caminho }
    }

    $pasta = Get-DebloatPastaRestauracao
    $lista = @(Get-ChildItem -LiteralPath $pasta -Filter 'Debloat_Manifesto_*.json' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)
    foreach ($arq in $lista) {
        try {
            $obj = Get-Content -LiteralPath $arq.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Log WARN "Manifesto ignorado por JSON invalido: $($arq.FullName)"
            continue
        }
        $v = Test-DebloatManifesto -Manifesto $obj -Origem $arq.FullName
        if (-not $v.Ok) {
            Write-Log WARN "Manifesto ignorado ($($arq.Name)): $($v.Problemas -join ' | ')"
            continue
        }
        Write-Log INFO "Manifesto selecionado: $($arq.FullName)"
        return [pscustomobject]@{ Manifesto = $obj; Arquivo = $arq.FullName }
    }
    return $null
}

# ==============================================================================
# 6. EXECUTORES POR TIPO
#    Contrato unico de saida para todos: Resultado, Anterior, Posterior,
#    Detalhe, Encontrado, Erro. Nunca devolvem texto solto nem booleano.
# ==============================================================================

function Format-DebloatAlvo {
    <# Trunca pela ESQUERDA. Em caminho de registro e de tarefa o que distingue
       o item esta no fim: cortar o fim esconde justamente o nome do valor. #>
    param([AllowEmptyString()][string]$Texto, [int]$Largura = 46)
    if ([string]::IsNullOrEmpty($Texto) -or $Texto.Length -le $Largura) { return $Texto }
    return '...' + $Texto.Substring($Texto.Length - ($Largura - 3))
}

function Write-DebloatTabela {
    <# Tabela sempre pelo canal de console. Emitir relatorio pelo stream de
       sucesso de uma funcao e fragil: quem chama pode canaliza-lo para
       Out-Null (e o despacho faz exatamente isso), e o operador ficaria sem
       ver a tabela. Alem disso misturaria texto com o valor de retorno. #>
    param([object[]]$Linhas)
    $Linhas = @($Linhas | Where-Object { $_ })
    if ($Linhas.Count -eq 0) { return }
    # Copia so para exibicao: encurta o alvo no console sem mutilar o dado que
    # vai para o relatorio da sessao.
    $exibicao = $Linhas | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'Alvo') {
            $c = $_ | Select-Object *
            $c.Alvo = Format-DebloatAlvo -Texto "$($_.Alvo)" -Largura 52
            $c
        } else { $_ }
    }
    $texto = $exibicao | Format-Table -AutoSize | Out-String -Width 160
    foreach ($l in ($texto -split "`r?`n")) {
        if ($l.Trim()) { Write-Color ("  " + $l) -Color DarkGray }
    }
}

function New-DebloatSaida {
    param([string]$Resultado = 'Ignorado')
    return [pscustomobject]@{
        Resultado  = $Resultado
        Anterior   = $null
        Posterior  = $null
        Detalhe    = ''
        Encontrado = $false
        Erro       = ''
    }
}

function Test-DebloatAppxAusente {
    <# Reconsulta dirigida a um unico pacote apos a remocao. Devolve $true
       (ausente), $false (ainda presente para algum usuario) ou $null
       (indeterminado). 'Staged' conta como ausente: nao ha instalacao ativa. #>
    param([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][string]$PackageFullName)
    $restantes = $null
    try { $restantes = @(Get-AppxPackage -AllUsers -Name $Nome -ErrorAction Stop) }
    catch {
        try { $restantes = @(Get-AppxPackage -Name $Nome -ErrorAction Stop) }
        catch {
            Write-Log DEBUG "Reconsulta Appx de $Nome falhou: $($_.Exception.Message)" -NoConsole
            return $null
        }
    }
    $iguais = @($restantes | Where-Object { "$($_.PackageFullName)" -eq $PackageFullName })
    if ($iguais.Count -eq 0) { return $true }
    foreach ($r in $iguais) {
        try {
            $ativos = @($r.PackageUserInformation | Where-Object { "$($_.InstallState)" -eq 'Installed' })
            if ($ativos.Count -gt 0) { return $false }
        } catch {
            Write-Log DEBUG "InstallState indisponivel para $Nome" -NoConsole
            return $false
        }
    }
    return $true
}

function Invoke-DebloatAppx {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida = New-DebloatSaida
    $inv   = Get-DebloatAppxInventario
    if (-not $inv.Disponivel) {
        $saida.Resultado = 'NaoSuportado'
        $saida.Detalhe   = 'Modulo Appx indisponivel nesta sessao'
        return $saida
    }

    $alvo   = $Item.Alvo
    $achados = @($inv.Pacotes | Where-Object { "$($_.Name)" -like $alvo })

    # Protecao reconfirmada com o nome REAL de cada pacote: o catalogo pode ter
    # usado curinga, e curinga amplo nao pode arrastar pacote protegido junto.
    $bloqueados = New-Object System.Collections.ArrayList
    $removiveis = New-Object System.Collections.ArrayList
    foreach ($p in $achados) {
        $motivo = Test-DebloatAppxBloqueado -Pacote $p
        if ($motivo) { [void]$bloqueados.Add("$($p.Name) [$motivo]") } else { [void]$removiveis.Add($p) }
    }

    $provInv = Get-DebloatProvInventario
    $prov    = @()
    if ($provInv.Disponivel) {
        foreach ($p in @($provInv.Lista | Where-Object { "$($_.DisplayName)" -like $alvo })) {
            if (Test-AppxProtegido -Nome "$($p.DisplayName)") {
                [void]$bloqueados.Add("$($p.DisplayName) [provisionamento protegido]")
            } else {
                $prov += $p
            }
        }
    }
    $prov = @($prov)

    if ($removiveis.Count -eq 0 -and $prov.Count -eq 0) {
        if ($bloqueados.Count -gt 0) {
            $saida.Encontrado = $true
            $saida.Resultado  = 'Protegido'
            $saida.Detalhe    = "Bloqueado: $($bloqueados -join ', ')"
            return $saida
        }
        $saida.Resultado = 'NaoInstalado'
        $saida.Detalhe   = 'Pacote ausente: estado desejado ja atingido'
        return $saida
    }
    $saida.Encontrado = $true

    # Estado anterior rico: e o que permite ao Restore decidir entre reinstalar
    # localmente e admitir que so a loja resolve.
    $detalhePacotes = @()
    foreach ($p in $removiveis) {
        $local    = "$($p.InstallLocation)"
        $manifest = ''
        if ($local) { $manifest = $local.TrimEnd('\', '/') + '\AppxManifest.xml' }
        $temManifesto = $false
        if ($manifest) {
            try { $temManifesto = (Test-Path -LiteralPath $manifest) }
            catch { Write-Log DEBUG "InstallLocation inacessivel para $($p.Name)" -NoConsole }
        }
        $usuarios = @()
        try { $usuarios = @($p.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId):$($_.InstallState)" }) }
        catch { Write-Log DEBUG "PackageUserInformation indisponivel para $($p.Name)" -NoConsole }

        $detalhePacotes += [pscustomobject]@{
            Nome              = "$($p.Name)"
            PackageFullName   = "$($p.PackageFullName)"
            PackageFamilyName = "$($p.PackageFamilyName)"
            Versao            = "$($p.Version)"
            Arquitetura       = "$($p.Architecture)"
            Assinatura        = "$($p.SignatureKind)"
            InstallLocation   = $local
            ManifestoPresente = $temManifesto
            Usuarios          = $usuarios
            Reinstalacao      = $(if ($temManifesto) { 'Re-registro local possivel enquanto os arquivos permanecerem no disco' }
                                  elseif ("$($p.SignatureKind)" -eq 'Store') { 'Somente pela Microsoft Store' }
                                  else { 'Sem origem local conhecida' })
        }
    }

    $saida.Anterior = [pscustomobject]@{
        Alvo         = $alvo
        Pacotes      = @($detalhePacotes)
        Provisionado = @($prov | ForEach-Object { [pscustomobject]@{ PackageName = "$($_.PackageName)"; DisplayName = "$($_.DisplayName)"; Versao = "$($_.Version)" } })
        Versao       = @($detalhePacotes | ForEach-Object { $_.Versao } | Select-Object -First 1)
        Bloqueados   = @($bloqueados)
    }

    if ($Simular) {
        $saida.Resultado = 'Simulado'
        $saida.Detalhe   = "$($removiveis.Count) instancia(s), $($prov.Count) provisionamento(s)" +
                           $(if ($bloqueados.Count -gt 0) { ", $($bloqueados.Count) bloqueado(s)" } else { '' })
        return $saida
    }

    $confirmados = 0; $falhas = 0; $indeterminados = 0; $naoRemoviveis = 0
    $erros = New-Object System.Collections.ArrayList

    foreach ($p in $removiveis) {
        $pfn = "$($p.PackageFullName)"
        # Pacote cujo payload ja nao esta no disco continua registrado, mas o
        # Remove-AppxPackage nao consegue removê-lo: falha com 0x80070002. O
        # dado ja e coletado acima (ManifestoPresente) e passa a ser usado como
        # pre-condicao, em vez de servir apenas para descrever a restauracao.
        $semPayload = $false
        $det = @($detalhePacotes | Where-Object { "$($_.PackageFullName)" -eq $pfn }) | Select-Object -First 1
        if ($det -and -not $det.ManifestoPresente) { $semPayload = $true }

        Write-Log DEBUG "Removendo Appx $pfn" -NoConsole
        $r = Invoke-SafeCommand { Remove-AppxPackage -Package $pfn -AllUsers -ErrorAction Stop } -Activity "Remover $($p.Name)" -Silent

        # 0x80070002 nao e condicao de escopo nem de permissao: repetir no
        # escopo do usuario falharia de forma identica.
        $determinista = $false
        if (-not $r.Success -and $r.Error) {
            if ($semPayload -or "$($r.Error.Exception.Message)" -match '0x80070002') { $determinista = $true }
        }
        if (-not $r.Success -and -not $determinista) {
            # -AllUsers nao existe/nao e permitido em toda edicao: tenta no
            # escopo do usuario atual antes de declarar falha.
            $r = Invoke-SafeCommand { Remove-AppxPackage -Package $pfn -ErrorAction Stop } -Activity "Remover $($p.Name) (usuario atual)" -Silent
        }
        $ausente = Test-DebloatAppxAusente -Nome "$($p.Name)" -PackageFullName $pfn
        if ($ausente -eq $true) {
            $confirmados++
        } elseif ($null -eq $ausente) {
            $indeterminados++
            [void]$erros.Add("$($p.Name): remocao nao pode ser verificada")
        } elseif ($determinista) {
            $falhas++
            $naoRemoviveis++
            [void]$erros.Add("$($p.Name): nao removivel por Remove-AppxPackage - os arquivos do pacote nao estao no disco e apenas o registro permanece")
        } else {
            $falhas++
            $msg = 'ainda presente apos a remocao'
            if ($r -and -not $r.Success -and $r.Error) { $msg = "$($r.Error.Exception.Message)" }
            [void]$erros.Add("$($p.Name): $msg")
        }
    }

    $provRemovidos = 0; $provFalhas = 0
    foreach ($p in $prov) {
        $pn = "$($p.PackageName)"
        $r = Invoke-SafeCommand { Remove-AppxProvisionedPackage -Online -PackageName $pn -ErrorAction Stop } -Activity "Desprovisionar $($p.DisplayName)" -Silent
        $script:CacheProvSujo = $true
        if (-not $r.Success) {
            $provFalhas++
            [void]$erros.Add("provisionamento $($p.DisplayName): $($r.Error.Exception.Message)")
        }
    }
    if ($prov.Count -gt 0) {
        $depois = Get-DebloatProvInventario
        if ($depois.Disponivel) {
            foreach ($p in $prov) {
                $aindaLa = @($depois.Lista | Where-Object { "$($_.PackageName)" -eq "$($p.PackageName)" })
                if ($aindaLa.Count -eq 0) { $provRemovidos++ }
                elseif ($provFalhas -eq 0) {
                    $provFalhas++
                    [void]$erros.Add("provisionamento $($p.DisplayName): ainda presente apos a remocao")
                }
            }
        } else {
            $indeterminados += $prov.Count
        }
    }

    # Cache local coerente com o que acabou de ser confirmado.
    if ($confirmados -gt 0) {
        $inv.Pacotes = @($inv.Pacotes | Where-Object { "$($_.Name)" -notlike $alvo -or (Test-DebloatAppxBloqueado -Pacote $_) })
    }

    $saida.Posterior = [pscustomobject]@{
        PacotesRemovidos         = $confirmados
        ProvisionamentosRemovidos = $provRemovidos
        Falhas                   = $falhas + $provFalhas
        Indeterminados           = $indeterminados
        NaoRemoviveis            = $naoRemoviveis
    }
    $sufixoNR = $(if ($naoRemoviveis -gt 0) { ", $naoRemoviveis sem arquivos no disco" } else { '' })
    $totalPedido = $removiveis.Count + $prov.Count
    $totalOk     = $confirmados + $provRemovidos

    if ($totalOk -eq $totalPedido -and $totalPedido -gt 0) {
        $saida.Resultado = 'Aplicado'
        $saida.Detalhe   = "$confirmados pacote(s) e $provRemovidos provisionamento(s) removidos e confirmados"
    } elseif ($totalOk -gt 0) {
        $saida.Resultado = 'Parcial'
        $saida.Detalhe   = "$totalOk de $totalPedido confirmados; $($falhas + $provFalhas) falha(s)$sufixoNR, $indeterminados nao verificado(s)"
        $saida.Erro      = ($erros -join ' | ')
    } else {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = "Nenhuma instancia confirmada como removida de $totalPedido$sufixoNR"
        $saida.Erro      = ($erros -join ' | ')
    }
    return $saida
}

function Invoke-DebloatServico {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida = New-DebloatSaida
    $nome  = $Item.Alvo

    $st = Get-DebloatServicoEstado -Nome $nome
    if (-not $st) {
        $saida.Resultado = 'NaoInstalado'
        $saida.Detalhe   = 'Servico inexistente neste build'
        return $saida
    }
    $saida.Encontrado = $true

    # Reconfirmacao com o nome real registrado no sistema.
    if (Test-ServicoProtegido -Nome $st.Nome) {
        $saida.Resultado = 'Protegido'
        $saida.Detalhe   = "Servico protegido: $($st.Nome)"
        return $saida
    }

    $atual   = ConvertTo-DebloatStartType $st.StartMode
    $destino = ConvertTo-DebloatStartType $Item.Dados.Startup
    if (-not $destino) {
        $saida.Resultado = 'NaoSuportado'
        $saida.Detalhe   = "Startup alvo invalido no catalogo: '$($Item.Dados.Startup)'"
        return $saida
    }
    if ($atual -in @('Boot', 'System')) {
        $saida.Resultado = 'Protegido'
        $saida.Detalhe   = "Inicio em nivel de driver ($atual): fora de alcance"
        return $saida
    }

    $saida.Anterior = [pscustomobject]@{
        Nome      = "$($st.Nome)"
        StartType = $(if ($atual) { $atual } else { "$($st.StartMode)" })
        Status    = "$($st.State)"
        Delayed   = [bool]$st.Delayed
    }

    $precisaParar = ($destino -eq 'Disabled' -and "$($st.State)" -eq 'Running')
    if ($atual -eq $destino -and -not $precisaParar) {
        $saida.Resultado = 'JaAplicado'
        $saida.Detalhe   = "Ja em $destino"
        return $saida
    }

    if ($Simular) {
        $saida.Resultado = 'Simulado'
        $saida.Detalhe   = "$($saida.Anterior.StartType)/$($st.State) -> $destino$(if ($precisaParar) { '/Stopped' } else { '' })"
        return $saida
    }

    $erro = ''
    if ($precisaParar) {
        $rp = Invoke-SafeCommand { Stop-Service -Name $nome -Force -ErrorAction Stop } -Activity "Parar $nome" -Silent
        if (-not $rp.Success) {
            $erro = "parada recusada: $($rp.Error.Exception.Message)"
            Write-Log DEBUG "Servico $nome nao parou: $erro" -NoConsole
        }
    }

    $r = Invoke-SafeCommand { Set-Service -Name $nome -StartupType $destino -ErrorAction Stop } -Activity "Servico $nome -> $destino" -Silent
    if (-not $r.Success) {
        $saida.Resultado = 'Falhou'
        $saida.Erro      = "$($r.Error.Exception.Message)"
        $saida.Detalhe   = "Nao foi possivel definir $destino"
        return $saida
    }

    $depois = Get-DebloatServicoEstado -Nome $nome -Atualizar
    if (-not $depois) {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = 'Servico desapareceu da consulta apos a alteracao'
        return $saida
    }
    $final = ConvertTo-DebloatStartType $depois.StartMode
    $saida.Posterior = [pscustomobject]@{ StartType = $final; Status = "$($depois.State)" }

    if ($final -eq $destino) {
        if ($destino -eq 'Disabled' -and "$($depois.State)" -eq 'Running') {
            $saida.Resultado = 'Parcial'
            $saida.Detalhe   = "$($saida.Anterior.StartType) -> $final, mas o servico segue em execucao ate o reinicio"
            $saida.Erro      = $erro
        } else {
            $saida.Resultado = 'Aplicado'
            $saida.Detalhe   = "$($saida.Anterior.StartType)/$($saida.Anterior.Status) -> $final/$($depois.State)"
        }
    } else {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = "Estado final $final difere do solicitado $destino"
        $saida.Erro      = $erro
    }
    return $saida
}

function Invoke-DebloatTarefa {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida = New-DebloatSaida
    if (-not (Test-CompartDiskCommand 'Get-ScheduledTask')) {
        $saida.Resultado = 'NaoSuportado'
        $saida.Detalhe   = 'Modulo ScheduledTasks indisponivel'
        return $saida
    }

    $caminho = "$($Item.Dados.Caminho)"
    $nome    = "$($Item.Dados.Nome)"
    if (-not $caminho -or -not $nome) {
        $pos     = $Item.Alvo.LastIndexOf('\')
        $caminho = $Item.Alvo.Substring(0, $pos + 1)
        $nome    = $Item.Alvo.Substring($pos + 1)
    }

    $tk = Get-DebloatTarefaEstado -Caminho $caminho -Nome $nome
    if (-not $tk) {
        if (-not (Get-DebloatTarefasInventario).Disponivel) {
            $saida.Resultado = 'NaoSuportado'
            $saida.Detalhe   = 'Nao foi possivel enumerar as tarefas agendadas: estado desconhecido'
        } else {
            $saida.Resultado = 'NaoInstalado'
            $saida.Detalhe   = 'Tarefa inexistente neste build'
        }
        return $saida
    }
    $saida.Encontrado = $true

    $completo = "$($tk.TaskPath)$($tk.TaskName)"
    if (Test-TarefaProtegida -CaminhoCompleto $completo) {
        $saida.Resultado = 'Protegido'
        $saida.Detalhe   = "Tarefa de sistema protegida: $completo"
        return $saida
    }

    $estado = "$($tk.State)"
    $saida.Anterior = [pscustomobject]@{ Caminho = "$($tk.TaskPath)"; Nome = "$($tk.TaskName)"; State = $estado }

    if ($estado -eq 'Disabled') {
        $saida.Resultado = 'JaAplicado'
        $saida.Detalhe   = 'Ja desabilitada'
        return $saida
    }
    if ($Simular) {
        $saida.Resultado = 'Simulado'
        $saida.Detalhe   = "$estado -> Disabled"
        return $saida
    }

    $r = Invoke-SafeCommand { Disable-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null } -Activity "Tarefa $nome" -Silent
    if (-not $r.Success) {
        $saida.Resultado = 'Falhou'
        $saida.Erro      = "$($r.Error.Exception.Message)"
        $saida.Detalhe   = 'Desabilitacao recusada'
        return $saida
    }

    $depois = Get-DebloatTarefaEstado -Caminho $caminho -Nome $nome -Atualizar
    $final  = $(if ($depois) { "$($depois.State)" } else { 'ausente' })
    $saida.Posterior = [pscustomobject]@{ State = $final }
    if ($final -eq 'Disabled') {
        $saida.Resultado = 'Aplicado'
        $saida.Detalhe   = "$estado -> Disabled"
    } else {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = "Estado final '$final' nao confirma a desabilitacao"
    }
    return $saida
}

function Invoke-DebloatRegistro {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida   = New-DebloatSaida
    $caminho = "$($Item.Dados.Caminho)"
    $nome    = "$($Item.Dados.Nome)"
    $valor   = $Item.Dados.Valor
    $tipo    = "$($Item.Dados.Tipo)"

    if (Test-RegistroProtegido -Caminho $caminho -Nome $nome) {
        $saida.Resultado = 'Protegido'
        $saida.Detalhe   = 'Ramo ou nome de valor protegido'
        return $saida
    }

    $antes = Get-DebloatRegistroEstado -Caminho $caminho -Nome $nome
    if ($antes.Erro) {
        $saida.Resultado = 'Falhou'
        $saida.Erro      = $antes.Erro
        $saida.Detalhe   = 'Leitura do estado anterior falhou'
        return $saida
    }
    $saida.Encontrado = $true

    # Somente estes tipos sobrevivem intactos ao ciclo JSON -> Restore.
    $restauravel = ((-not $antes.Existe) -or ($antes.Tipo -in @('String', 'ExpandString', 'DWord', 'QWord')))

    $saida.Anterior = [pscustomobject]@{
        Caminho     = $caminho
        Nome        = $nome
        Existia     = $antes.Existe
        ChaveExistia = $antes.ChaveExiste
        Valor       = $(if ($antes.Existe) { "$($antes.Valor)" } else { $null })
        Tipo        = $(if ($antes.Existe) { $antes.Tipo } else { $tipo })
        Restauravel = $restauravel
    }

    if ($antes.Existe -and "$($antes.Valor)" -eq "$valor") {
        $saida.Resultado = 'JaAplicado'
        $saida.Detalhe   = "Ja em $valor"
        return $saida
    }
    if ($Simular) {
        $saida.Resultado = 'Simulado'
        $saida.Detalhe   = "$(if ($antes.Existe) { $antes.Valor } else { '<inexistente>' }) -> $valor"
        return $saida
    }

    $gravou = $false
    try { $gravou = [bool](Set-CompartDiskRegistryValue -Path $caminho -Name $nome -Value $valor -Type $tipo) }
    catch {
        $saida.Resultado = 'Falhou'
        $saida.Erro      = "$($_.Exception.Message)"
        $saida.Detalhe   = 'Gravacao lancou excecao'
        return $saida
    }
    if (-not $gravou) {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = 'Gravacao recusada'
        return $saida
    }

    $depois = Get-DebloatRegistroEstado -Caminho $caminho -Nome $nome
    $saida.Posterior = [pscustomobject]@{ Existe = $depois.Existe; Valor = "$($depois.Valor)"; Tipo = $depois.Tipo }
    if ($depois.Existe -and "$($depois.Valor)" -eq "$valor") {
        $saida.Resultado = 'Aplicado'
        $saida.Detalhe   = "$(if ($antes.Existe) { $antes.Valor } else { '<inexistente>' }) -> $valor"
    } else {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = "Releitura devolveu '$($depois.Valor)' em vez de '$valor'"
    }
    return $saida
}

function Invoke-DebloatItem {
    <# Despachante unico. Concentrar aqui evita que cada acao repita o switch. #>
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)
    switch ($Item.Tipo) {
        'Appx'     { return (Invoke-DebloatAppx     -Item $Item -Simular:$Simular) }
        'Service'  { return (Invoke-DebloatServico  -Item $Item -Simular:$Simular) }
        'Task'     { return (Invoke-DebloatTarefa   -Item $Item -Simular:$Simular) }
        'Registry' { return (Invoke-DebloatRegistro -Item $Item -Simular:$Simular) }
        default    {
            $s = New-DebloatSaida -Resultado 'NaoSuportado'
            $s.Detalhe = "Tipo de item desconhecido: '$($Item.Tipo)'"
            Write-Log WARN $s.Detalhe
            return $s
        }
    }
}

# ==============================================================================
# 7. ORQUESTRACAO
# ==============================================================================

function Invoke-DebloatCategorias {
    <# Motor comum de Analyze, Apps, Services, Tasks, Privacy, Tweaks e Full.
       Uma unica implementacao para todas as acoes garante que a simulacao
       descreva exatamente o que a execucao fara. #>
    param(
        [Parameter(Mandatory)][string[]]$Categorias,
        [Parameter(Mandatory)][object]$Manifesto,
        [switch]$Simular
    )

    $catalogo = Get-DebloatCatalogo
    $selecao  = Select-DebloatItens -Catalogo $catalogo -NivelMaximo $Level -Incluir $Include -Excluir $Exclude

    $itens         = @($selecao.Itens         | Where-Object { $Categorias -contains $_.Categoria })
    $protegidos    = @($selecao.Protegidos    | Where-Object { $Categorias -contains $_.Item.Categoria })
    $promovidos    = @($selecao.Promovidos    | Where-Object { $Categorias -contains $_.Categoria })
    $pendentes     = @($selecao.Pendentes     | Where-Object { $Categorias -contains $_.Categoria })
    $incompativeis = @($selecao.Incompativeis | Where-Object { $Categorias -contains $_.Item.Categoria })

    # SysMain so faz sentido em disco mecanico. Sem confirmacao de que o disco do
    # sistema e SSD, o item e preservado: na duvida, nao altera.
    if (@($itens | Where-Object { $_.Id -eq 'svc:SysMain' }).Count -gt 0) {
        $ssd = Test-SistemaEmSsd
        if ($ssd -ne $true) {
            $itens = @($itens | Where-Object { $_.Id -ne 'svc:SysMain' })
            $razao = $(if ($ssd -eq $false) { 'disco mecanico detectado' } else { 'tipo de midia indeterminado' })
            Write-Log INFO "SysMain preservado ($razao): o Superfetch traz ganho real fora de SSD."
        }
    }

    foreach ($p in $promovidos) {
        Write-Log WARN "-Include promoveu '$($p.Id)' (nivel $($p.Nivel)) acima do nivel corrente $Level."
    }
    if ($pendentes.Count -gt 0) {
        Write-Log INFO ("{0} item(ns) de alto impacto exigem -Include explicito e ficaram de fora: {1}" -f `
            $pendentes.Count, (@($pendentes | ForEach-Object { $_.Id }) -join ', '))
    }

    # Incompativel nao e falha nem omissao: e um item que nao existe nesta
    # plataforma. Entra no relatorio como NaoSuportado, com o motivo, em vez de
    # ser aplicado inerte e contado como sucesso.
    $linhasIncompat = New-Object System.Collections.ArrayList
    if ($incompativeis.Count -gt 0) {
        $w = Get-DebloatWindows
        Write-Log INFO ("{0} item(ns) nao se aplicam a esta plataforma ({1}, build {2}) e foram ignorados." -f `
            $incompativeis.Count, $w.Familia, $w.Build)
        foreach ($x in $incompativeis) {
            Write-Log DEBUG ("Incompativel: {0} - {1}" -f $x.Item.Id, $x.Motivo) -NoConsole
            [void]$linhasIncompat.Add([pscustomobject]@{
                Categoria = $x.Item.Categoria
                Tipo      = $x.Item.Tipo
                Alvo      = $x.Item.Alvo
                Nivel     = $x.Item.Nivel
                Classe    = 'INCOMPATIVEL'
                Resultado = 'NaoSuportado'
                Detalhe   = $x.Motivo
                Motivo    = $x.Item.Motivo
            })
        }
    }

    if ($itens.Count -eq 0 -and $protegidos.Count -eq 0 -and $incompativeis.Count -eq 0) {
        Write-Log WARN "Nenhum item elegivel em: $($Categorias -join ', ') (nivel $Level)."
        return @()
    }

    Write-Log INFO ("{0} item(ns) elegivel(is) em {1} | nivel {2}{3}" -f `
        $itens.Count, ($Categorias -join ', '), $Level, $(if ($Simular) { ' | SIMULACAO' } else { '' }))

    $linhas = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($i in $itens) {
        $n++
        $r = Invoke-DebloatItem -Item $i -Simular:$Simular

        if ($r.Resultado -in @('Aplicado', 'Parcial', 'Falhou', 'Simulado')) {
            Add-DebloatRegistro -Manifesto $Manifesto -Item $i -Resultado $r.Resultado `
                -EstadoAnterior $r.Anterior -EstadoPosterior $r.Posterior -Detalhe $r.Detalhe -Erro $r.Erro
        }
        if ($r.Erro -and $r.Resultado -in @('Falhou', 'Parcial')) {
            Write-Log WARN "[$($i.Id)] $($r.Resultado): $($r.Erro)"
        }
        # EVIDENCIA: no log de 13/08/2026 a acao Apps registrou 16 falhas AppX
        # (0x80070002) e ainda assim finalizou com Resultado=OK, porque nenhuma
        # falha de item chegava a Set-DebloatResultado. Um item que falhou ou
        # ficou parcial contamina o resultado do modulo a partir daqui.
        if (-not $Simular) {
            switch ($r.Resultado) {
                'Falhou'  { Set-DebloatResultado 'WARN' | Out-Null }
                'Parcial' { Set-DebloatResultado 'WARN' | Out-Null }
            }
        }

        [void]$linhas.Add([pscustomobject]@{
            Categoria = $i.Categoria
            Tipo      = $i.Tipo
            Alvo      = $i.Alvo
            Nivel     = $i.Nivel
            Classe    = $(if ($r.Resultado -eq 'NaoInstalado') { 'INEXISTENTE' }
                          elseif ($r.Resultado -eq 'Falhou')   { 'ERRO' }
                          elseif ($r.Resultado -eq 'Protegido'){ (Get-DebloatClasseProtecao -Item $i -Motivo $r.Detalhe) }
                          else { $i.Classe })
            Resultado = $r.Resultado
            Detalhe   = $r.Detalhe
            Motivo    = $i.Motivo
        })

        $cor = switch ($r.Resultado) {
            'Aplicado'     { 'Green' }
            'Simulado'     { 'Cyan' }
            'Parcial'      { 'Yellow' }
            'JaAplicado'   { 'DarkGray' }
            'NaoInstalado' { 'DarkGray' }
            'NaoSuportado' { 'Yellow' }
            'AdiadoReboot' { 'Yellow' }
            'Protegido'    { 'Yellow' }
            'Falhou'       { 'Red' }
            default        { 'DarkGray' }
        }
        if ($r.Resultado -eq 'NaoInstalado') {
            Write-Log DEBUG "[$($i.Id)] ausente do sistema." -NoConsole
        } else {
            Write-Color ("  [{0,3}/{1,3}] {2,-13} {3,-46} {4}" -f $n, $itens.Count, $r.Resultado, `
                (Format-DebloatAlvo $i.Alvo), $r.Detalhe) -Color $cor
        }
    }

    # Itens barrados por protecao aparecem no relatorio em vez de desaparecer.
    # A classe diz em uma palavra por que o item e intocavel.
    foreach ($p in $protegidos) {
        $classe = $(if ($p.PSObject.Properties.Name -contains 'Classe' -and $p.Classe) { $p.Classe }
                    else { Get-DebloatClasseProtecao -Item $p.Item -Motivo $p.Motivo })
        [void]$linhas.Add([pscustomobject]@{
            Categoria = $p.Item.Categoria
            Tipo      = $p.Item.Tipo
            Alvo      = $p.Item.Alvo
            Nivel     = $p.Item.Nivel
            Classe    = $classe
            Resultado = 'Protegido'
            Detalhe   = $p.Motivo
            Motivo    = $p.Item.Motivo
        })
        Write-Color ("  {0,-19} {1,-46} {2}" -f 'Protegido', `
            (Format-DebloatAlvo $p.Item.Alvo), ("[$classe] " + $p.Motivo)) -Color Yellow
    }

    # Incompativeis entram por ultimo, ja formatados acima.
    foreach ($li in $linhasIncompat) {
        [void]$linhas.Add($li)
        Write-Color ("  {0,-19} {1,-46} {2}" -f 'NaoSuportado', `
            (Format-DebloatAlvo $li.Alvo), ('[INCOMPATIVEL] ' + $li.Detalhe)) -Color DarkGray
    }

    # Contabiliza o que realmente aconteceu na categoria, para que o resumo do
    # modulo nao dependa apenas das linhas exibidas no console.
    $nFalhas   = @($linhas | Where-Object { $_.Resultado -eq 'Falhou' }).Count
    $nParciais = @($linhas | Where-Object { $_.Resultado -eq 'Parcial' }).Count
    if (-not $Simular -and ($nFalhas -gt 0 -or $nParciais -gt 0)) {
        Write-Log WARN ("{0}: {1} item(ns) falharam e {2} ficaram parciais de {3} processado(s)." -f `
            ($Categorias -join ', '), $nFalhas, $nParciais, @($linhas).Count)
    }

    return @($linhas)
}

function Invoke-DebloatComponentes {
    <# Limpeza do armazenamento de componentes. Nao duplica Cleanup.ps1: aquele
       trata arquivos temporarios, este trata o WinSxS, que exige DISM. #>
    param(
        [Parameter(Mandatory)][object]$Manifesto,
        [switch]$Simular,
        [bool]$AnalisarWinSxS = $true
    )

    $linhas = New-Object System.Collections.ArrayList
    $item = [pscustomobject]@{
        Id = 'dism:StartComponentCleanup'; Tipo = 'Componente'; Alvo = 'WinSxS'
        Categoria = 'Componentes'; Nivel = $Level; Reversivel = $false
    }

    $dism = "$env:SystemRoot\System32\Dism.exe"
    if (-not (Test-Path -LiteralPath $dism)) {
        Write-Log ERR 'Dism.exe nao localizado. Limpeza de componentes indisponivel.'
        [void]$linhas.Add([pscustomobject]@{
            Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'StartComponentCleanup'; Nivel = 'Safe'
            Resultado = 'NaoSuportado'; Detalhe = 'Dism.exe ausente'; Motivo = 'Limpeza do WinSxS.'
        })
        Set-DebloatResultado 'WARN' | Out-Null
        return @($linhas)
    }

    $recomendado = 'n/d'; $tamanho = 'n/d'
    if ($AnalisarWinSxS) {
        Write-Log INFO 'Analisando o armazenamento de componentes (WinSxS). Pode levar alguns minutos...'
        $an = Invoke-SafeCommand {
            Invoke-NativeCommand -FilePath $dism -Arguments @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') -TimeoutSeconds 1800
        } -Activity 'DISM AnalyzeComponentStore'

        if ($an.Success -and $an.Value -and $an.Value.StdOut) {
            foreach ($l in ($an.Value.StdOut -split "`r?`n")) {
                if ($l -match '(?i)(Component Store Cleanup Recommended|Limpeza .*Recomendada)\s*:\s*(.+)$') { $recomendado = $Matches[2].Trim() }
                if ($l -match '(?i)(Actual Size of Component Store|Tamanho Real d[oa].*Componentes)\s*:\s*(.+)$') { $tamanho = $Matches[2].Trim() }
            }
        } elseif (-not $an.Success) {
            Write-Log WARN "Analise do WinSxS nao concluiu: $($an.Error.Exception.Message)"
        }
        [void]$linhas.Add([pscustomobject]@{
            Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'AnalyzeComponentStore'; Nivel = 'Safe'
            Resultado = $(if ($an.Success) { 'Analisado' } else { 'Falhou' })
            Detalhe = "Tamanho real: $tamanho | Limpeza recomendada: $recomendado"; Motivo = 'Diagnostico do WinSxS.'
        })
        Write-CompartDiskKeyValue 'Tamanho do WinSxS' $tamanho -Pad 24
        Write-CompartDiskKeyValue 'Limpeza recomendada' $recomendado -Pad 24
    }

    $obs = 'Remove versoes superadas de componentes.'
    $argumentos = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($Level -eq 'Aggressive') {
        $argumentos += '/ResetBase'
        $obs = 'Com /ResetBase: libera mais espaco e torna DEFINITIVAS as atualizacoes ja instaladas (deixam de ser desinstalaveis).'
    }

    if ($Simular) {
        [void]$linhas.Add([pscustomobject]@{
            Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'StartComponentCleanup'
            Nivel = $(if ($Level -eq 'Aggressive') { 'Aggressive' } else { 'Safe' })
            Resultado = 'Simulado'; Detalhe = "Seria executado: dism $($argumentos -join ' ')"; Motivo = $obs
        })
        Write-Log INFO 'Simulacao: a limpeza de componentes nao foi executada.'
        return @($linhas)
    }

    # Estado inconsistente e o cenario classico de falha do DISM. Melhor nao
    # comecar do que abortar no meio de uma operacao sobre o Component Store.
    if (Test-DebloatRebootPendente) {
        Write-Log WARN 'Reinicio pendente: a limpeza de componentes foi pulada para nao operar sobre um Component Store em transicao.'
        [void]$linhas.Add([pscustomobject]@{
            Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'StartComponentCleanup'; Nivel = $Level
            Resultado = 'AdiadoReboot'; Detalhe = 'SKIPPED_REBOOT_PENDING: aguarda reinicio para ser executada'; Motivo = $obs
        })
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message 'Limpeza de componentes adiada por reinicio pendente.' `
            -Recommendation 'Reinicie o computador e execute a acao Components novamente.'
        Set-DebloatResultado 'WARN' | Out-Null
        return @($linhas)
    }

    $livre = Get-DebloatEspacoLivre
    if ($livre -gt 0 -and $livre -lt 1GB) {
        Write-Log WARN "Espaco livre insuficiente ($(ConvertTo-CompartDiskSize $livre)): a limpeza de componentes precisa de area de trabalho e foi pulada."
        [void]$linhas.Add([pscustomobject]@{
            Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'StartComponentCleanup'; Nivel = $Level
            Resultado = 'NaoSuportado'; Detalhe = 'Espaco livre abaixo de 1 GB'; Motivo = $obs
        })
        Set-DebloatResultado 'WARN' | Out-Null
        return @($linhas)
    }

    if ($Level -eq 'Aggressive') {
        Write-Log WARN 'Nivel Aggressive: /ResetBase sera aplicado. As atualizacoes ja instaladas deixarao de ser desinstalaveis.'
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message 'Limpeza de componentes com /ResetBase.' `
            -Recommendation 'Depois desta operacao as atualizacoes ja instaladas nao poderao mais ser desinstaladas individualmente.'
    }

    Write-Log INFO 'Executando a limpeza de componentes. Esta etapa costuma demorar...'
    $cl = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $dism -Arguments $argumentos -TimeoutSeconds 3600
    } -Activity 'DISM StartComponentCleanup'

    $codigoDism = $null
    if ($cl.Value -and ($cl.Value.PSObject.Properties.Name -contains 'ExitCode')) { $codigoDism = [int]$cl.Value.ExitCode }
    # 0 = sucesso; 3010 = sucesso exigindo reinicio. Qualquer outro e falha.
    $ok = ($cl.Success -and $null -ne $codigoDism -and $codigoDism -in @(0, 3010))

    $detalhe = $(if ($ok -and $codigoDism -eq 3010) { 'Concluido; exige reinicio para consolidar' }
                 elseif ($ok) { 'Concluido' }
                 elseif ($null -ne $codigoDism) { "DISM retornou codigo $codigoDism" }
                 else { "Falha ao executar o DISM: $($cl.Error.Exception.Message)" })

    [void]$linhas.Add([pscustomobject]@{
        Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'StartComponentCleanup'
        Nivel = $(if ($Level -eq 'Aggressive') { 'Aggressive' } else { 'Safe' })
        Resultado = $(if ($ok) { 'Aplicado' } else { 'Falhou' })
        Detalhe = $detalhe; Motivo = $obs
    })

    if ($ok) {
        Write-Log OK "Armazenamento de componentes compactado. $detalhe"
        Add-DebloatRegistro -Manifesto $Manifesto -Item $item -Resultado 'Aplicado' `
            -EstadoAnterior ([pscustomobject]@{ TamanhoAntes = $tamanho; LimpezaRecomendada = $recomendado }) `
            -EstadoPosterior ([pscustomobject]@{ ExitCode = $codigoDism }) -Detalhe $obs -Reversivel $false
        Add-CompartDiskFinding -Severity OK -Area 'Debloat' -Message 'Armazenamento de componentes compactado.' `
            -Recommendation 'Operacao nao reversivel: o espaco liberado nao volta ao estado anterior.'
        if ($codigoDism -eq 3010) { Set-DebloatResultado 'WARN' | Out-Null }
    } else {
        Write-Log ERR "A limpeza de componentes nao concluiu. $detalhe"
        if ($cl.Value -and $cl.Value.StdErr) {
            $tail = @("$($cl.Value.StdErr)" -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 3)
            foreach ($l in $tail) { Write-Log ERR "DISM: $l" }
        }
        Add-DebloatRegistro -Manifesto $Manifesto -Item $item -Resultado 'Falhou' -Detalhe $detalhe `
            -Erro $(if ($cl.Error) { "$($cl.Error.Exception.Message)" } else { '' }) -Reversivel $false
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message 'Limpeza do armazenamento de componentes nao concluiu.' `
            -Recommendation 'Verifique reinicio pendente, espaco livre e integridade da imagem (DISM /RestoreHealth).'
        Set-DebloatResultado 'WARN' | Out-Null
    }

    Write-Log INFO 'Arquivos temporarios e caches sao tratados pelo modulo Cleanup (menu [4][1]).'
    return @($linhas)
}

function Get-DebloatPontoRestauracaoRecente {
    <# Confirma no sistema se existe ponto de restauracao dentro da janela dada.
       Sem esta checagem, o modulo estaria apenas supondo que o ponto existe. #>
    param([int]$Horas = 24)
    try {
        $pontos = @(Get-CompartDiskCim -Class SystemRestore -Namespace 'root\default')
        if ($pontos.Count -eq 0) { return $null }
        $limite = (Get-Date).AddHours(-1 * $Horas)
        foreach ($p in $pontos) {
            $quando = $null
            $bruto  = $p.CreationTime
            if ($bruto -is [datetime]) { $quando = $bruto }
            elseif ($bruto) {
                $txt = "$bruto"
                if ($txt.Length -ge 14) {
                    try { $quando = [datetime]::ParseExact($txt.Substring(0, 14), 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture) }
                    catch { $quando = $null }
                }
            }
            if ($quando -and $quando -ge $limite) { return $quando }
        }
        return $null
    } catch {
        Write-Log DEBUG "Consulta de pontos de restauracao indisponivel: $($_.Exception.Message)" -NoConsole
        return $null
    }
}

function New-DebloatRestorePoint {
    <# Ponto de restauracao do Windows. Trata explicitamente protecao desligada,
       politica que proibe System Restore e o intervalo minimo de 24 h - e so
       devolve sucesso quando ha ponto confirmado no sistema. #>
    [CmdletBinding()] param(
        [string]$Descricao = 'COMPARTDISK - antes do Debloat',
        [switch]$Simular
    )

    if (-not (Test-CompartDiskCommand 'Checkpoint-Computer')) {
        Write-Log WARN 'Checkpoint-Computer indisponivel nesta edicao do Windows.'
        return $false
    }

    $bloqueio = Get-CompartDiskRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -Default 0
    if ("$bloqueio" -eq '1') {
        Write-Log ERR 'A Restauracao do Sistema esta desabilitada por politica (DisableSR=1). Nenhum ponto pode ser criado.'
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message 'System Restore bloqueado por politica.' `
            -Recommendation 'Politica de dominio ou local impede a criacao de pontos de restauracao. Trate com o administrador do ambiente.'
        return $false
    }

    $recente = Get-DebloatPontoRestauracaoRecente -Horas 24
    if ($recente) {
        Write-Log OK "Ja existe ponto de restauracao de $recente (janela de 24 h do Windows). Ele serve como ponto de retorno."
        return $true
    }

    if ($Simular) {
        Write-Log INFO "SIMULACAO: um ponto de restauracao seria criado agora ('$Descricao'). Nada foi alterado."
        return $true
    }

    # A classe SystemRestoreConfig existe em root\default mesmo com a Protecao do
    # Sistema desligada: ela guarda a configuracao global, nao o estado do volume.
    # Tomar a presenca da classe como prova de protecao ativa suprimia a unica
    # tentativa de recuperacao (Enable-ComputerRestore) exatamente nos sistemas em
    # que ela era necessaria. RPSessionInterval=0 e o que Disable-ComputerRestore
    # grava: so esse valor derruba a presuncao; ausente ou ilegivel mantem o
    # comportamento anterior.
    $protecaoConhecida = $false
    try {
        $rp = @(Get-CompartDiskCim -Class SystemRestoreConfig -Namespace 'root\default') | Select-Object -First 1
        if ($rp) {
            $protecaoConhecida = $true
            Write-Log DEBUG "SystemRestoreConfig presente (RPSessionInterval=$($rp.RPSessionInterval))." -NoConsole
            if ($null -ne $rp.RPSessionInterval -and [int]$rp.RPSessionInterval -eq 0) {
                $protecaoConhecida = $false
                Write-Log WARN 'Restauracao do Sistema desligada no sistema (RPSessionInterval=0).'
            }
        }
    } catch {
        Write-Log DEBUG "SystemRestoreConfig indisponivel: $($_.Exception.Message)" -NoConsole
    }
    if (-not $protecaoConhecida -and (Test-CompartDiskCommand 'Enable-ComputerRestore')) {
        Write-Log WARN "Protecao do Sistema nao confirmada em $env:SystemDrive. Tentando habilita-la (isto altera a configuracao do sistema)."
        $en = Invoke-SafeCommand { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } -Activity 'Habilitar protecao do sistema' -Silent
        if ($en.Success) { Write-Log OK "Protecao do Sistema habilitada em $env:SystemDrive." }
        else { Write-Log WARN "Nao foi possivel habilitar a Protecao do Sistema: $($en.Error.Exception.Message)" }
    }

    Write-Log INFO 'Criando ponto de restauracao do sistema...'
    $r = Invoke-SafeCommand {
        Checkpoint-Computer -Description $Descricao -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    } -Activity 'Checkpoint-Computer'

    $confirmado = Get-DebloatPontoRestauracaoRecente -Horas 1
    if ($r.Success -and $confirmado) {
        Write-Log OK "Ponto de restauracao criado e confirmado: $Descricao ($confirmado)"
        Add-CompartDiskFinding -Severity OK -Area 'Debloat' -Message 'Ponto de restauracao do sistema criado antes das alteracoes.' `
            -Recommendation 'Recuperavel por: Painel de Controle > Recuperacao > Abrir Restauracao do Sistema.'
        return $true
    }
    if ($r.Success -and -not $confirmado) {
        Write-Log WARN 'O comando de criacao retornou sucesso, mas nenhum ponto de restauracao recente foi encontrado na consulta seguinte.'
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message 'Criacao do ponto de restauracao nao pode ser confirmada.' `
            -Recommendation 'Verifique a Protecao do Sistema e o espaco reservado para pontos de restauracao.'
        return $false
    }

    $msg  = $(if ($r.Error) { "$($r.Error.Exception.Message)" } else { 'motivo nao informado' })
    $diag = Get-DebloatRestoreCausa -ErrorRecord $r.Error
    Write-Log WARN "Nao foi possivel criar o ponto de restauracao: $msg"
    Write-Log WARN "Causa identificada: $($diag.Causa)."
    Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message "Ponto de restauracao nao pode ser criado: $($diag.Causa)." `
        -Recommendation $diag.Recomendacao
    return $false
}

function Get-DebloatRestoreCausa {
    <# Identifica a causa da falha do Checkpoint-Computer. A Restauracao do
       Sistema depende do VSS e do provedor swprv: quando um deles esta
       desabilitado, o erro devolvido e o 1058 generico de servico, que sozinho
       nao aponta o responsavel. Nenhum servico e alterado aqui. #>
    param([AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $out = [pscustomobject]@{
        Causa        = 'nao identificada'
        Recomendacao = 'Habilite a Protecao do Sistema em Sistema > Protecao do Sistema, ou use -SkipRestorePoint por sua conta e risco.'
        Servicos     = @()
    }

    $estados = New-Object System.Collections.ArrayList
    $desabilitados = New-Object System.Collections.ArrayList
    $ausentes = New-Object System.Collections.ArrayList
    foreach ($nome in @('VSS', 'swprv')) {
        $st = Get-DebloatServicoEstado -Nome $nome -Atualizar
        if (-not $st) { [void]$ausentes.Add($nome); [void]$estados.Add("$nome=ausente"); continue }
        [void]$estados.Add("$nome=$($st.StartMode)/$($st.State)")
        if ("$($st.StartMode)" -match '(?i)disabled|desativad|desabilitad') { [void]$desabilitados.Add($nome) }
    }
    $out.Servicos = @($estados)

    if ($desabilitados.Count -gt 0) {
        $out.Causa = ("servico(s) necessario(s) a Restauracao do Sistema desabilitado(s): {0} ({1})" -f (@($desabilitados) -join ', '), (@($estados) -join '; '))
        $out.Recomendacao = ("Reative {0} com tipo de inicializacao Manual e repita a operacao. O modulo nao altera servicos automaticamente." -f (@($desabilitados) -join ' e '))
        return $out
    }
    if ($ausentes.Count -gt 0) {
        $out.Causa = ("servico(s) de shadow copy ausente(s): {0}" -f (@($ausentes) -join ', '))
        $out.Recomendacao = 'Componente de shadow copy ausente: avalie a integridade do Windows com DISM /RestoreHealth e SFC /scannow.'
        return $out
    }

    $texto = $(if ($ErrorRecord) { "$($ErrorRecord.Exception.Message)" } else { '' })
    if ($texto -match '(?i)desabilitad|disabled|1058') {
        # EVIDENCIA: no log de 13/08/2026 (tres execucoes) esta ramificacao
        # afirmou "um servico exigido pela Restauracao do Sistema recusou o
        # inicio" imprimindo, na mesma linha, "VSS=Manual/Running;
        # swprv=Manual/Running". A causa contradizia a propria evidencia e
        # mandava o operador investigar dois servicos que estavam em execucao.
        # O 1058 so pode ser atribuido a VSS/swprv quando um deles nao esta
        # rodando; caso contrario a recusa vem de outro servico da cadeia.
        $parados = @($estados | Where-Object { $_ -notmatch '(?i)/(Running|Em execucao|Executando)' })
        if ($parados.Count -gt 0) {
            $out.Causa = ("um servico exigido pela Restauracao do Sistema recusou o inicio ({0})" -f (@($estados) -join '; '))
            $out.Recomendacao = 'Verifique os servicos VSS e swprv e as diretivas que controlam o inicio deles.'
            return $out
        }

        # VSS e swprv em execucao: percorrer a cadeia de dependencia, onde o 1058
        # costuma nascer de fato. Nenhum servico e alterado aqui.
        $cadeia    = New-Object System.Collections.ArrayList
        $cadeiaOff = New-Object System.Collections.ArrayList
        foreach ($nome in @('COMSysApp', 'EventSystem', 'RpcSs', 'DcomLaunch')) {
            $st = Get-DebloatServicoEstado -Nome $nome -Atualizar
            if (-not $st) { [void]$cadeia.Add("$nome=ausente"); continue }
            [void]$cadeia.Add("$nome=$($st.StartMode)/$($st.State)")
            if ("$($st.StartMode)" -match '(?i)disabled|desativad|desabilitad') { [void]$cadeiaOff.Add($nome) }
        }
        $out.Servicos = @($estados) + @($cadeia)

        if ($cadeiaOff.Count -gt 0) {
            $out.Causa = ("servico(s) da cadeia COM+/VSS desabilitado(s): {0} ({1}; {2})" -f `
                (@($cadeiaOff) -join ', '), (@($estados) -join '; '), (@($cadeia) -join '; '))
            $out.Recomendacao = ("Reative {0} com o tipo de inicializacao padrao (Manual) e repita a operacao. O modulo nao altera servicos automaticamente." -f (@($cadeiaOff) -join ' e '))
            return $out
        }

        # Nada desabilitado na cadeia: pode ser a Protecao do Sistema desligada
        # para o volume. RPSessionInterval=0 e o que Disable-ComputerRestore grava.
        $rpsi = Get-CompartDiskRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name 'RPSessionInterval' -Default $null
        if ($null -ne $rpsi -and "$rpsi" -eq '0') {
            $out.Causa = ("Restauracao do Sistema desligada no sistema (RPSessionInterval=0); os servicos de shadow copy estao em execucao ({0})" -f (@($estados) -join '; '))
            $out.Recomendacao = 'Ligue a Protecao do Sistema para o volume do sistema em Sistema > Protecao do Sistema > Configurar e repita a operacao.'
            return $out
        }

        $out.Causa = ("o Windows devolveu erro de servico desabilitado (1058) com os servicos de shadow copy em execucao ({0}) e a cadeia COM+/VSS habilitada ({1}); a recusa nao vem de VSS nem de swprv" -f `
            (@($estados) -join '; '), (@($cadeia) -join '; '))
        $out.Recomendacao = 'Confira em services.msc se algum servico esta Desabilitado por diretiva e se a Protecao do Sistema esta ligada para o volume do sistema; "vssadmin list writers" ajuda a identificar o componente que recusa.'
        return $out
    }
    if ($texto -match '(?i)espaco|space|0x80042306') {
        $out.Causa = 'espaco reservado para pontos de restauracao insuficiente'
        $out.Recomendacao = 'Aumente o espaco reservado em Sistema > Protecao do Sistema > Configurar.'
        return $out
    }
    if ($texto) {
        $out.Causa = ("nao identificada a partir do erro devolvido ({0})" -f (@($estados) -join '; '))
    }
    return $out
}

function Invoke-DebloatBackup {
    <# Retrato do estado atual dos alvos do catalogo, sem alterar nada. Serve
       como rede independente do manifesto de execucao. #>
    param([Parameter(Mandatory)][object]$Manifesto)

    Write-Log INFO 'Coletando o estado atual de todos os alvos do catalogo...'
    $catalogo = Get-DebloatCatalogo
    $linhas = New-Object System.Collections.ArrayList

    foreach ($i in $catalogo) {
        if (Get-DebloatMotivoProtecao -Item $i) { continue }
        $r = Invoke-DebloatItem -Item $i -Simular
        if (-not $r.Encontrado -or $null -eq $r.Anterior) { continue }
        Add-DebloatRegistro -Manifesto $Manifesto -Item $i -Resultado 'Backup' -EstadoAnterior $r.Anterior -Detalhe $r.Detalhe
        [void]$linhas.Add([pscustomobject]@{
            Categoria = $i.Categoria; Tipo = $i.Tipo; Alvo = $i.Alvo
            Nivel = $i.Nivel; Resultado = 'Registrado'; Detalhe = $r.Detalhe; Motivo = $i.Motivo
        })
    }

    Write-Log OK "$($linhas.Count) alvo(s) presentes no sistema tiveram o estado registrado."
    Add-CompartDiskSection -Title 'Backup de estado (Debloat)' -Status OK -Rows @($linhas) `
        -Summary "$($linhas.Count) alvo(s) registrado(s)"
    return @($linhas)
}

# ==============================================================================
# 8. REVERSAO
#    Cada tipo tem seu proprio caminho de volta e sua propria verdade sobre o
#    que e reversivel. Nada e restaurado as cegas e nada e prometido a mais.
# ==============================================================================

function Test-DebloatAppxInstalado {
    param([Parameter(Mandatory)][string]$Nome)
    try { return (@(Get-AppxPackage -Name $Nome -ErrorAction Stop).Count -gt 0) }
    catch {
        Write-Log DEBUG "Consulta Appx de $Nome falhou: $($_.Exception.Message)" -NoConsole
        return $null
    }
}

function Restore-DebloatServico {
    param([Parameter(Mandatory)][object]$Registro, [switch]$Simular)
    $ant  = $Registro.EstadoAnterior
    $nome = "$($Registro.Alvo)"
    $linha = [pscustomobject]@{ Tipo = 'Servico'; Alvo = $nome; Acao = ''; Resultado = 'NaoRestauravel'; Detalhe = '' }

    $destino = ConvertTo-DebloatStartType "$($ant.StartType)"
    if (-not $destino -or $destino -in @('Boot', 'System')) {
        $linha.Detalhe = "Startup anterior nao restauravel: '$($ant.StartType)'"
        return $linha
    }
    if (Test-ServicoProtegido -Nome $nome) {
        $linha.Detalhe = 'Servico protegido; nao e tocado nem na reversao'
        return $linha
    }
    $linha.Acao = "-> $destino"

    $atual = Get-DebloatServicoEstado -Nome $nome -Atualizar
    if (-not $atual) {
        $linha.Detalhe = 'Servico nao existe mais neste sistema'
        return $linha
    }
    $atualTipo   = ConvertTo-DebloatStartType $atual.StartMode
    $precisaIniciar = ("$($ant.Status)" -eq 'Running' -and "$($atual.State)" -ne 'Running')

    if ($atualTipo -eq $destino -and -not $precisaIniciar) {
        $linha.Resultado = 'JaRestaurado'
        $linha.Detalhe   = "Ja em $destino"
        return $linha
    }
    if ($Simular) {
        $linha.Resultado = 'Simulado'
        $linha.Detalhe   = "$atualTipo -> $destino$(if ($precisaIniciar) { ' e iniciar' } else { '' })"
        return $linha
    }

    $alvoStartup = $destino
    if ($destino -eq 'Automatic' -and $ant.Delayed -and $PSVersionTable.PSVersion.Major -ge 6) {
        $alvoStartup = 'AutomaticDelayedStart'
    }
    $r = Invoke-SafeCommand { Set-Service -Name $nome -StartupType $alvoStartup -ErrorAction Stop } -Activity "Restaurar $nome" -Silent
    if (-not $r.Success -and $alvoStartup -ne $destino) {
        $r = Invoke-SafeCommand { Set-Service -Name $nome -StartupType $destino -ErrorAction Stop } -Activity "Restaurar $nome" -Silent
    }
    if (-not $r.Success) {
        $linha.Resultado = 'Falhou'
        $linha.Detalhe   = "$($r.Error.Exception.Message)"
        return $linha
    }

    $depois = Get-DebloatServicoEstado -Nome $nome -Atualizar
    if (-not $depois -or (ConvertTo-DebloatStartType $depois.StartMode) -ne $destino) {
        $linha.Resultado = 'Falhou'
        $linha.Detalhe   = "Estado final nao confirma $destino"
        return $linha
    }

    $obs = ''
    if ($precisaIniciar) {
        $ri = Invoke-SafeCommand { Start-Service -Name $nome -ErrorAction Stop } -Activity "Iniciar $nome" -Silent
        if (-not $ri.Success) { $obs = '; servico nao pode ser reiniciado agora' }
    }
    if ($ant.Delayed -and $alvoStartup -eq $destino -and $destino -eq 'Automatic') {
        $obs += '; o atributo de inicio atrasado nao e reaplicavel por Set-Service nesta versao do PowerShell'
    }
    $linha.Resultado = 'Restaurado'
    $linha.Detalhe   = "$destino confirmado$obs"
    return $linha
}

function Restore-DebloatTarefa {
    param([Parameter(Mandatory)][object]$Registro, [switch]$Simular)
    $ant   = $Registro.EstadoAnterior
    $linha = [pscustomobject]@{ Tipo = 'Tarefa'; Alvo = "$($Registro.Alvo)"; Acao = '-> Ready'; Resultado = 'NaoRestauravel'; Detalhe = '' }

    if (-not (Test-CompartDiskCommand 'Enable-ScheduledTask')) {
        $linha.Detalhe = 'Modulo ScheduledTasks indisponivel'
        return $linha
    }
    $caminho = "$($ant.Caminho)"; $nome = "$($ant.Nome)"
    if (-not $caminho -or -not $nome) {
        $pos     = "$($Registro.Alvo)".LastIndexOf('\')
        $caminho = "$($Registro.Alvo)".Substring(0, $pos + 1)
        $nome    = "$($Registro.Alvo)".Substring($pos + 1)
    }
    if (Test-TarefaProtegida -CaminhoCompleto "$caminho$nome") {
        $linha.Detalhe = 'Tarefa protegida; nao e tocada nem na reversao'
        return $linha
    }
    if ("$($ant.State)" -eq 'Disabled') {
        $linha.Resultado = 'JaRestaurado'
        $linha.Detalhe   = 'Ja estava desabilitada antes da alteracao'
        return $linha
    }

    $atual = Get-DebloatTarefaEstado -Caminho $caminho -Nome $nome -Atualizar
    if (-not $atual) {
        $linha.Detalhe = $(if ((Get-DebloatTarefasInventario).Disponivel) { 'Tarefa nao existe mais neste sistema' }
                           else { 'Nao foi possivel consultar as tarefas agendadas' })
        return $linha
    }
    if ("$($atual.State)" -ne 'Disabled') {
        $linha.Resultado = 'JaRestaurado'
        $linha.Detalhe   = "Ja em $($atual.State)"
        return $linha
    }
    if ($Simular) {
        $linha.Resultado = 'Simulado'
        $linha.Detalhe   = "Disabled -> $($ant.State)"
        return $linha
    }

    $r = Invoke-SafeCommand { Enable-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null } -Activity "Restaurar $nome" -Silent
    if (-not $r.Success) {
        $linha.Resultado = 'Falhou'
        $linha.Detalhe   = "$($r.Error.Exception.Message)"
        return $linha
    }
    $depois = Get-DebloatTarefaEstado -Caminho $caminho -Nome $nome -Atualizar
    if ($depois -and "$($depois.State)" -ne 'Disabled') {
        $linha.Resultado = 'Restaurado'
        $linha.Detalhe   = "Estado final: $($depois.State)"
    } else {
        $linha.Resultado = 'Falhou'
        $linha.Detalhe   = 'A tarefa continua desabilitada apos o comando'
    }
    return $linha
}

function Restore-DebloatRegistro {
    param([Parameter(Mandatory)][object]$Registro, [switch]$Simular)
    $ant   = $Registro.EstadoAnterior
    $linha = [pscustomobject]@{ Tipo = 'Registro'; Alvo = "$($Registro.Alvo)"; Acao = ''; Resultado = 'NaoRestauravel'; Detalhe = '' }

    $caminho = "$($ant.Caminho)"; $nome = "$($ant.Nome)"
    if (-not $caminho -or -not $nome) {
        $partes  = "$($Registro.Alvo)" -split '\\'
        if ($partes.Count -lt 2) { $linha.Detalhe = 'Alvo de registro sem caminho utilizavel'; return $linha }
        $nome    = $partes[-1]
        $caminho = ($partes[0..($partes.Count - 2)]) -join '\'
    }
    if (Test-RegistroProtegido -Caminho $caminho -Nome $nome) {
        $linha.Detalhe = 'Ramo protegido; nao e tocado nem na reversao'
        return $linha
    }

    $tipo = "$($ant.Tipo)"
    if ($ant.Existia -and $tipo -notin @('String', 'ExpandString', 'DWord', 'QWord')) {
        $linha.Detalhe = "Tipo '$tipo' nao e restaurado por este modulo sem risco de corromper o valor"
        return $linha
    }

    $atual = Get-DebloatRegistroEstado -Caminho $caminho -Nome $nome
    if ($atual.Erro) {
        $linha.Resultado = 'Falhou'
        $linha.Detalhe   = $atual.Erro
        return $linha
    }

    if ($ant.Existia) {
        $linha.Acao = "-> $($ant.Valor)"
        if ($atual.Existe -and "$($atual.Valor)" -eq "$($ant.Valor)") {
            $linha.Resultado = 'JaRestaurado'
            $linha.Detalhe   = "Ja em $($ant.Valor)"
            return $linha
        }
        if ($Simular) { $linha.Resultado = 'Simulado'; $linha.Detalhe = "$($atual.Valor) -> $($ant.Valor)"; return $linha }

        $valor = $ant.Valor
        try {
            if ($tipo -eq 'DWord') { $valor = [int]"$valor" }
            elseif ($tipo -eq 'QWord') { $valor = [int64]"$valor" }
            else { $valor = "$valor" }
        } catch {
            $linha.Resultado = 'Falhou'
            $linha.Detalhe   = "Valor anterior '$($ant.Valor)' nao converte para $tipo"
            return $linha
        }

        $gravou = $false
        try { $gravou = [bool](Set-CompartDiskRegistryValue -Path $caminho -Name $nome -Value $valor -Type $tipo) }
        catch { $linha.Resultado = 'Falhou'; $linha.Detalhe = "$($_.Exception.Message)"; return $linha }
        if (-not $gravou) { $linha.Resultado = 'Falhou'; $linha.Detalhe = 'Gravacao recusada'; return $linha }

        $depois = Get-DebloatRegistroEstado -Caminho $caminho -Nome $nome
        if ($depois.Existe -and "$($depois.Valor)" -eq "$($ant.Valor)") {
            $linha.Resultado = 'Restaurado'
            $linha.Detalhe   = "Valor anterior reposto ($tipo)"
        } else {
            $linha.Resultado = 'Falhou'
            $linha.Detalhe   = "Releitura devolveu '$($depois.Valor)'"
        }
        return $linha
    }

    # O valor nao existia antes: restaurar e remove-lo, nao gravar zero.
    $linha.Acao = '-> remover valor'
    if (-not $atual.Existe) {
        $linha.Resultado = 'JaRestaurado'
        $linha.Detalhe   = 'Valor ja ausente'
        return $linha
    }
    if ($Simular) { $linha.Resultado = 'Simulado'; $linha.Detalhe = 'Valor seria removido'; return $linha }

    $r = Invoke-SafeCommand { Remove-ItemProperty -LiteralPath $caminho -Name $nome -Force -ErrorAction Stop } -Activity "Remover $nome" -Silent
    if (-not $r.Success) {
        $linha.Resultado = 'Falhou'
        $linha.Detalhe   = "$($r.Error.Exception.Message)"
        return $linha
    }
    $depois = Get-DebloatRegistroEstado -Caminho $caminho -Nome $nome
    if (-not $depois.Existe) {
        $linha.Resultado = 'Restaurado'
        $linha.Detalhe   = 'Valor removido, como estava antes'
    } else {
        $linha.Resultado = 'Falhou'
        $linha.Detalhe   = 'O valor continua presente apos a remocao'
    }
    return $linha
}

function Restore-DebloatAppx {
    <# Unico caminho honesto de volta: re-registrar o pacote enquanto os arquivos
       seguem no disco. Quando nao ha payload local, o modulo NAO diz que
       restaurou - registra que depende da Microsoft Store. #>
    param([Parameter(Mandatory)][object]$Registro, [switch]$Simular)

    $ant     = $Registro.EstadoAnterior
    $saida   = New-Object System.Collections.ArrayList
    $pacotes = @()
    if ($ant -and ($ant.PSObject.Properties.Name -contains 'Pacotes')) { $pacotes = @($ant.Pacotes) }

    if ($pacotes.Count -eq 0) {
        [void]$saida.Add([pscustomobject]@{
            Tipo = 'Aplicativo'; Alvo = "$($Registro.Alvo)"; Acao = 'reinstalar'
            Resultado = 'NaoRestauravel'; Detalhe = 'Manifesto sem detalhe de pacote (formato antigo): reinstalacao pela Microsoft Store'
        })
        return @($saida)
    }

    foreach ($p in $pacotes) {
        # Manifesto de schema 1 guardava apenas o PackageFullName como texto.
        if ($p -isnot [System.Management.Automation.PSCustomObject] -or -not ($p.PSObject.Properties.Name -contains 'Nome')) {
            [void]$saida.Add([pscustomobject]@{
                Tipo = 'Aplicativo'; Alvo = "$p"; Acao = 'reinstalar'
                Resultado = 'NaoRestauravel'; Detalhe = 'Registro sem origem local: reinstalacao pela Microsoft Store'
            })
            continue
        }

        $nome  = "$($p.Nome)"
        $linha = [pscustomobject]@{ Tipo = 'Aplicativo'; Alvo = $nome; Acao = 'reinstalar'; Resultado = 'NaoRestauravel'; Detalhe = '' }

        $instalado = Test-DebloatAppxInstalado -Nome $nome
        if ($instalado -eq $true) {
            $linha.Resultado = 'JaRestaurado'
            $linha.Detalhe   = 'Aplicativo presente novamente'
            [void]$saida.Add($linha); continue
        }

        $manifestoAppx = ''
        if ("$($p.InstallLocation)") { $manifestoAppx = "$($p.InstallLocation)".TrimEnd('\', '/') + '\AppxManifest.xml' }
        $temPayload = $false
        if ($manifestoAppx) {
            try { $temPayload = (Test-Path -LiteralPath $manifestoAppx) }
            catch { Write-Log DEBUG "InstallLocation inacessivel: $manifestoAppx" -NoConsole }
        }

        if (-not $temPayload -or -not (Test-CompartDiskCommand 'Add-AppxPackage')) {
            $linha.Detalhe = "$($p.Reinstalacao)"
            if (-not $linha.Detalhe) { $linha.Detalhe = 'Sem payload local: reinstalacao pela Microsoft Store' }
            [void]$saida.Add($linha); continue
        }
        if ($Simular) {
            $linha.Resultado = 'Simulado'
            $linha.Detalhe   = 'Re-registro local a partir de AppxManifest.xml'
            [void]$saida.Add($linha); continue
        }

        $r = Invoke-SafeCommand {
            Add-AppxPackage -Register $manifestoAppx -DisableDevelopmentMode -ErrorAction Stop
        } -Activity "Re-registrar $nome" -Silent

        $agora = Test-DebloatAppxInstalado -Nome $nome
        if ($agora -eq $true) {
            $linha.Resultado = 'Restaurado'
            $linha.Detalhe   = 'Re-registrado a partir do payload local'
        } elseif (-not $r.Success) {
            $linha.Resultado = 'Falhou'
            $linha.Detalhe   = "$($r.Error.Exception.Message)"
        } else {
            $linha.Resultado = 'Falhou'
            $linha.Detalhe   = 'Comando aceito, mas o pacote nao aparece na consulta seguinte'
        }
        [void]$saida.Add($linha)
    }

    $prov = @()
    if ($ant -and ($ant.PSObject.Properties.Name -contains 'Provisionado')) { $prov = @($ant.Provisionado) }
    foreach ($pv in $prov) {
        $rotulo = $(if ($pv -is [string]) { "$pv" } else { "$($pv.DisplayName)" })
        [void]$saida.Add([pscustomobject]@{
            Tipo = 'Provisionamento'; Alvo = $rotulo; Acao = 'reprovisionar'
            Resultado = 'NaoRestauravel'
            Detalhe = 'O pacote .appx original nao fica retido no disco; reprovisionar exige a midia de instalacao ou a Store'
        })
    }
    return @($saida)
}

function Invoke-DebloatRestore {
    <# Reversao a partir do manifesto, item a item, com validacao antes e depois.
       Idempotente: a segunda execucao encontra tudo em 'JaRestaurado'. #>
    param([switch]$Simular)

    $carga = $null
    try { $carga = Get-DebloatUltimoManifesto -Caminho $ManifestPath }
    catch {
        Write-Log ERR "Manifesto invalido: $($_.Exception.Message)"
        Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Manifesto informado nao pode ser lido.' `
            -Recommendation "Confira o caminho passado em -ManifestPath e a integridade do arquivo JSON."
        Set-DebloatResultado 'ERROR' | Out-Null
        return @()
    }

    if (-not $carga) {
        Write-Log WARN 'Nenhum manifesto de reversao valido encontrado. Nada a restaurar.'
        Write-Color ''
        Write-Color "  Os manifestos ficam em: $(Get-DebloatPastaRestauracao)" -Color DarkGray
        Set-DebloatResultado 'WARN' | Out-Null
        return @()
    }

    $m = $carga.Manifesto
    $v = Test-DebloatManifesto -Manifesto $m -Origem $carga.Arquivo
    if (-not $v.Ok) {
        Write-Log ERR "Manifesto rejeitado ($($carga.Arquivo)): $($v.Problemas -join ' | ')"
        Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Manifesto de reversao invalido; nenhuma alteracao foi feita.' `
            -Recommendation ($v.Problemas -join ' | ')
        Set-DebloatResultado 'ERROR' | Out-Null
        return @()
    }

    Write-Log INFO "Manifesto de $($m.Criado) | acao '$($m.Acao)' | nivel '$($m.Nivel)' | $(@($m.Itens).Count) registro(s) | schema $($v.Schema)."

    $aplicados = @($m.Itens | Where-Object { "$($_.Resultado)" -in @('Aplicado', 'Parcial') })
    if ($aplicados.Count -gt 0) {
        $alvos = $aplicados
        Write-Log INFO "$($alvos.Count) registro(s) de alteracao real serao avaliados para reversao."
    } else {
        $alvos = @($m.Itens | Where-Object { "$($_.Resultado)" -eq 'Backup' })
        if ($alvos.Count -gt 0) {
            Write-Log INFO "Manifesto sem alteracoes aplicadas: sera usado como retrato de estado ($($alvos.Count) alvo(s))."
        }
    }
    if (@($alvos).Count -eq 0) {
        Write-Log WARN 'O manifesto nao contem registros reversiveis.'
        Set-DebloatResultado 'WARN' | Out-Null
        return @()
    }

    $linhas = New-Object System.Collections.ArrayList
    $apps   = New-Object System.Collections.ArrayList

    foreach ($it in $alvos) {
        if ($null -eq $it.EstadoAnterior) {
            [void]$linhas.Add([pscustomobject]@{
                Tipo = "$($it.Tipo)"; Alvo = "$($it.Alvo)"; Acao = '-'
                Resultado = 'NaoRestauravel'; Detalhe = 'Registro sem estado anterior'
            })
            continue
        }
        if ("$($it.Tipo)" -eq 'Service')       { [void]$linhas.Add((Restore-DebloatServico  -Registro $it -Simular:$Simular)) }
        elseif ("$($it.Tipo)" -eq 'Task')      { [void]$linhas.Add((Restore-DebloatTarefa   -Registro $it -Simular:$Simular)) }
        elseif ("$($it.Tipo)" -eq 'Registry')  { [void]$linhas.Add((Restore-DebloatRegistro -Registro $it -Simular:$Simular)) }
        elseif ("$($it.Tipo)" -eq 'Appx')      { foreach ($l in (Restore-DebloatAppx -Registro $it -Simular:$Simular)) { [void]$apps.Add($l) } }
        elseif ("$($it.Tipo)" -eq 'Componente') {
            [void]$linhas.Add([pscustomobject]@{
                Tipo = 'Componente'; Alvo = "$($it.Alvo)"; Acao = '-'
                Resultado = 'NaoRestauravel'; Detalhe = 'Limpeza do WinSxS e definitiva por natureza'
            })
        } else {
            [void]$linhas.Add([pscustomobject]@{
                Tipo = "$($it.Tipo)"; Alvo = "$($it.Alvo)"; Acao = '-'
                Resultado = 'NaoSuportado'; Detalhe = 'Tipo desconhecido neste manifesto'
            })
        }
    }

    $todas       = @(@($linhas) + @($apps))
    $restaurados = @($todas | Where-Object { $_.Resultado -eq 'Restaurado' }).Count
    $jaOk        = @($todas | Where-Object { $_.Resultado -eq 'JaRestaurado' }).Count
    $simulados   = @($todas | Where-Object { $_.Resultado -eq 'Simulado' }).Count
    $naoRev      = @($todas | Where-Object { $_.Resultado -in @('NaoRestauravel', 'NaoSuportado') }).Count
    $falhas      = @($todas | Where-Object { $_.Resultado -eq 'Falhou' }).Count

    Write-Color ''
    if ($linhas.Count -gt 0) {
        Write-DebloatTabela -Linhas @($linhas)
        Add-CompartDiskSection -Title 'Reversao de alteracoes' -Status $(if ($falhas -gt 0) { 'WARN' } else { 'OK' }) -Rows @($linhas) `
            -Summary "$restaurados restaurado(s), $jaOk ja no estado anterior, $falhas falha(s), $naoRev nao reversivel(is)"
    }

    if ($apps.Count -gt 0) {
        Write-Color ''
        Write-Color '  APLICATIVOS REMOVIDOS' -Color Yellow
        Write-Color '  Sem payload local, a remocao de Appx nao tem volta por este modulo:' -Color DarkGray
        Write-Color '  o pacote precisa ser reinstalado pela Microsoft Store.' -Color DarkGray
        Write-Color ''
        Write-DebloatTabela -Linhas @($apps)
        $pendentesLoja = @($apps | Where-Object { $_.Resultado -eq 'NaoRestauravel' }).Count
        Add-CompartDiskSection -Title 'Aplicativos: situacao da reversao' -Status $(if ($pendentesLoja -gt 0) { 'WARN' } else { 'OK' }) -Rows @($apps) `
            -Summary "$(@($apps | Where-Object { $_.Resultado -eq 'Restaurado' }).Count) re-registrado(s), $pendentesLoja dependente(s) da Store"
        if ($pendentesLoja -gt 0) {
            Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message "$pendentesLoja aplicativo(s) removido(s) nao podem ser restaurados localmente." `
                -Recommendation 'Reinstale pela Microsoft Store. A remocao de Appx sem payload local nao e reversivel por este modulo.'
        }
    }

    if ($falhas -gt 0) { Set-DebloatResultado 'WARN' | Out-Null }
    Write-Log OK ("Reversao concluida: {0} restaurado(s), {1} ja no estado anterior, {2} simulado(s), {3} nao reversivel(is), {4} falha(s)." -f `
        $restaurados, $jaOk, $simulados, $naoRev, $falhas)
    return @($todas)
}

# ==============================================================================
# 9. RELATORIO
# ==============================================================================

function Write-DebloatResumo {
    param([object[]]$Linhas, [string]$Titulo, [switch]$Simulacao)

    $Linhas = @($Linhas | Where-Object { $_ })
    if ($Linhas.Count -eq 0) { return }

    $aplicados  = @($Linhas | Where-Object { $_.Resultado -eq 'Aplicado' }).Count
    $parciais   = @($Linhas | Where-Object { $_.Resultado -eq 'Parcial' }).Count
    $simulados  = @($Linhas | Where-Object { $_.Resultado -eq 'Simulado' }).Count
    $jaOk       = @($Linhas | Where-Object { $_.Resultado -in @('JaAplicado', 'NaoInstalado') }).Count
    $protegidos = @($Linhas | Where-Object { $_.Resultado -eq 'Protegido' }).Count
    $naoSup     = @($Linhas | Where-Object { $_.Resultado -eq 'NaoSuportado' }).Count
    $falhas     = @($Linhas | Where-Object { $_.Resultado -eq 'Falhou' }).Count
    # Adiado por reinicio nao e "nao suportado" (permanente) nem falha: e uma
    # operacao que volta a ser possivel depois do reboot.
    $adiados    = @($Linhas | Where-Object { $_.Resultado -eq 'AdiadoReboot' }).Count

    Write-Color ''
    Write-Color "  $Titulo" -Color White
    if ($Simulacao) {
        Write-Color ("    {0} : {1}" -f 'Alteracoes previstas'.PadRight(26), $simulados) -Color Cyan
    } else {
        Write-Color ("    {0} : {1}" -f 'Alteracoes confirmadas'.PadRight(26), $aplicados) -Color $(if ($aplicados -gt 0) { 'Green' } else { 'DarkGray' })
        if ($parciais -gt 0) { Write-Color ("    {0} : {1}" -f 'Aplicadas em parte'.PadRight(26), $parciais) -Color Yellow }
    }
    Write-Color ("    {0} : {1}" -f 'Ja no estado desejado'.PadRight(26), $jaOk) -Color DarkGray
    if ($protegidos -gt 0) { Write-Color ("    {0} : {1}" -f 'Bloqueados por protecao'.PadRight(26), $protegidos) -Color Yellow }
    if ($naoSup -gt 0)     { Write-Color ("    {0} : {1}" -f 'Nao suportados aqui'.PadRight(26), $naoSup) -Color Yellow }
    if ($adiados -gt 0)    { Write-Color ("    {0} : {1}" -f 'Adiados ate reiniciar'.PadRight(26), $adiados) -Color Yellow }
    if ($falhas -gt 0)     { Write-Color ("    {0} : {1}" -f 'Falhas'.PadRight(26), $falhas) -Color Red }

    $porCategoria = $Linhas | Group-Object Categoria | ForEach-Object {
        [pscustomobject]@{
            Categoria    = $_.Name
            Total        = $_.Count
            Confirmadas  = @($_.Group | Where-Object { $_.Resultado -eq 'Aplicado' }).Count
            Previstas    = @($_.Group | Where-Object { $_.Resultado -eq 'Simulado' }).Count
            Parciais     = @($_.Group | Where-Object { $_.Resultado -eq 'Parcial' }).Count
            JaOk         = @($_.Group | Where-Object { $_.Resultado -in @('JaAplicado', 'NaoInstalado') }).Count
            NaoSuportado = @($_.Group | Where-Object { $_.Resultado -eq 'NaoSuportado' }).Count
            AdiadoReboot = @($_.Group | Where-Object { $_.Resultado -eq 'AdiadoReboot' }).Count
            Protegidas   = @($_.Group | Where-Object { $_.Resultado -eq 'Protegido' }).Count
            Falhas       = @($_.Group | Where-Object { $_.Resultado -eq 'Falhou' }).Count
        }
    }
    Write-Color ''
    Write-DebloatTabela -Linhas @($porCategoria)

    # Quebra por classe de risco: responde "o que o modulo nao tocou, e por que"
    # sem obrigar quem le a interpretar o texto do motivo item a item.
    $porClasse = @($Linhas | Where-Object { $_.PSObject.Properties.Name -contains 'Classe' -and $_.Classe } |
        Group-Object Classe | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Classe = $_.Name; Itens = $_.Count }
        })
    $preservadas = @($porClasse | Where-Object {
        $_.Classe -in @('ESSENCIAL', 'SISTEMA', 'SEGURANCA', 'DEPENDENCIA', 'RECOMENDADO_PRESERVAR', 'INCOMPATIVEL')
    })
    if ($preservadas.Count -gt 0) {
        Write-Color ''
        Write-Color '  Classificacao de risco dos itens nao alterados' -Color White
        Write-DebloatTabela -Linhas @($porClasse)
    }

    $status = $(if ($falhas -gt 0 -or $parciais -gt 0) { 'WARN' } else { 'OK' })
    Add-CompartDiskSection -Title $Titulo -Status $status -Rows @($Linhas) `
        -Summary ("Nivel {0} | confirmadas {1} | parciais {2} | previstas {3} | ja conformes {4} | protegidas {5} | nao suportadas {6} | adiadas por reinicio {7} | falhas {8}" -f `
            $Level, $aplicados, $parciais, $simulados, $jaOk, $protegidos, $naoSup, $adiados, $falhas)

    if ($falhas -gt 0 -or $parciais -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message "$falhas alteracao(oes) falharam e $parciais foram aplicadas apenas em parte." `
            -Recommendation 'Verificar reinicio pendente, politica corporativa ou pacote em uso no momento da alteracao.'
        Set-DebloatResultado 'WARN' | Out-Null
    }
    if ($naoSup -gt 0) {
        $incompat = @($Linhas | Where-Object {
            $_.Resultado -eq 'NaoSuportado' -and
            $_.PSObject.Properties.Name -contains 'Classe' -and $_.Classe -eq 'INCOMPATIVEL'
        }).Count
        $detalhe = $(if ($incompat -gt 0) {
            " Destes, $incompat nao existem nesta build ou edicao do Windows."
        } else { '' })
        Add-CompartDiskFinding -Severity INFO -Area 'Debloat' -Message "$naoSup item(ns) nao sao suportados nesta versao do Windows ou nesta sessao.$detalhe" `
            -Recommendation 'Nenhuma acao necessaria: o alvo nao existe nesta plataforma ou o mecanismo nao esta disponivel aqui. Um ajuste aplicado fora da plataforma correta seria inerte.'
        Set-DebloatResultado 'WARN' | Out-Null
    }
    if ($protegidos -gt 0) {
        $classes = @($Linhas | Where-Object {
            $_.Resultado -eq 'Protegido' -and
            $_.PSObject.Properties.Name -contains 'Classe' -and $_.Classe
        } | ForEach-Object { $_.Classe } | Sort-Object -Unique)
        Add-CompartDiskFinding -Severity INFO -Area 'Debloat' `
            -Message ("{0} item(ns) foram preservados pelas listas de protecao{1}." -f $protegidos,
                      $(if ($classes.Count -gt 0) { ' (' + ($classes -join ', ') + ')' } else { '' })) `
            -Recommendation 'Comportamento esperado: sao componentes de sistema, seguranca ou dependencia. Nenhum nivel deste modulo os alcanca, nem mesmo -Include.'
    }
    if ($aplicados -gt 0 -or $parciais -gt 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Debloat' -Message "$aplicados alteracao(oes) confirmada(s) no nivel $Level." `
            -Recommendation 'Reversivel pela acao Restore deste modulo, exceto a remocao de aplicativos sem payload local.'
    }
    if ($simulados -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Debloat' -Message "$simulados alteracao(oes) identificada(s) em simulacao, nenhuma aplicada." `
            -Recommendation 'Executar a acao correspondente sem -DryRun para aplicar.'
    }
}

# ==============================================================================
# 10. DESPACHO
#     Isolado em funcao para que 'return' encerre apenas a acao corrente: no
#     escopo do script, 'return' pularia a linha final de 'exit' e o modulo
#     devolveria codigo de saida errado ao Core.
# ==============================================================================

$script:CategoriasTodas = @('Aplicativos', 'Servicos', 'Tarefas', 'Privacidade', 'Ajustes')

function Invoke-DebloatDespacho {
    param(
        [Parameter(Mandatory)][object]$Manifesto,
        [Parameter(Mandatory)][bool]$Simular
    )

    switch ($Action) {

        'Analyze' {
            Write-Log INFO 'Simulacao completa. Nenhuma alteracao sera feita no sistema.'
            $l  = Invoke-DebloatCategorias -Categorias $script:CategoriasTodas -Manifesto $Manifesto -Simular
            # Espelha o que 'Full' faria com componentes, sem rodar a analise
            # demorada do WinSxS (que fica na acao Components).
            $lc = Invoke-DebloatComponentes -Manifesto $Manifesto -Simular -AnalisarWinSxS $false
            Write-DebloatResumo -Linhas (@($l) + @($lc)) -Titulo 'Simulacao de Debloat' -Simulacao
            Write-Color ''
            Write-Color '  Nada foi alterado. Para aplicar, use a acao correspondente no menu.' -Color Cyan
        }

        'Apps' {
            $l = Invoke-DebloatCategorias -Categorias @('Aplicativos') -Manifesto $Manifesto -Simular:$Simular
            Write-DebloatResumo -Linhas $l -Titulo 'Remocao de aplicativos' -Simulacao:$Simular
        }

        'Services' {
            $l = Invoke-DebloatCategorias -Categorias @('Servicos') -Manifesto $Manifesto -Simular:$Simular
            Write-DebloatResumo -Linhas $l -Titulo 'Gerenciamento de servicos' -Simulacao:$Simular
        }

        'Tasks' {
            $l = Invoke-DebloatCategorias -Categorias @('Tarefas') -Manifesto $Manifesto -Simular:$Simular
            Write-DebloatResumo -Linhas $l -Titulo 'Gerenciamento de tarefas agendadas' -Simulacao:$Simular
        }

        'Privacy' {
            $l = Invoke-DebloatCategorias -Categorias @('Privacidade') -Manifesto $Manifesto -Simular:$Simular
            Write-DebloatResumo -Linhas $l -Titulo 'Ajustes de privacidade' -Simulacao:$Simular
            Write-Log INFO 'A telemetria propriamente dita e tratada pelo modulo Telemetry (menu [4][2]).'
        }

        'Tweaks' {
            $l = Invoke-DebloatCategorias -Categorias @('Ajustes') -Manifesto $Manifesto -Simular:$Simular
            Write-DebloatResumo -Linhas $l -Titulo 'Ajustes opcionais do Windows' -Simulacao:$Simular
        }

        'Components' {
            $l = Invoke-DebloatComponentes -Manifesto $Manifesto -Simular:$Simular
            Write-DebloatResumo -Linhas $l -Titulo 'Limpeza de componentes' -Simulacao:$Simular
        }

        'Backup' {
            Invoke-DebloatBackup -Manifesto $Manifesto | Out-Null
        }

        'Restore' {
            Invoke-DebloatRestore -Simular:$Simular | Out-Null
        }

        'RestorePoint' {
            if (-not (New-DebloatRestorePoint -Simular:$Simular)) { Set-DebloatResultado 'WARN' | Out-Null }
        }

        'Full' {
            Write-Log INFO "Rotina completa de Debloat no nivel $Level$(if ($Simular) { ' (SIMULACAO)' } else { '' })."

            if (-not $Simular) {
                # --- Fase 2: rede de seguranca do sistema
                if ($SkipRestorePoint) {
                    Write-Log WARN 'Ponto de restauracao ignorado por parametro (-SkipRestorePoint).'
                    Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message 'Rotina completa executada sem ponto de restauracao, por opcao explicita.' `
                        -Recommendation 'A reversao dependera exclusivamente do manifesto deste modulo.'
                    Set-DebloatResultado 'WARN' | Out-Null
                } elseif (-not (New-DebloatRestorePoint)) {
                    Write-Log ERR 'Rotina interrompida: sem ponto de restauracao nao ha rede de seguranca.'
                    # O Launcher nao expoe -SkipRestorePoint em nenhum item de menu:
                    # sem o comando explicito no log, a falha vira um beco sem saida
                    # para quem so usa o menu. O manifesto continua sendo a unica
                    # rede de seguranca nesse caminho, e isso e dito aqui.
                    Write-Log INFO ("Para seguir assumindo o risco, execute manualmente: powershell -ExecutionPolicy Bypass -File `"{0}`" -Action Full -Level {1} -SkipRestorePoint" -f $PSCommandPath, $Level)
                    Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Rotina completa interrompida por ausencia de ponto de restauracao.' `
                        -Recommendation 'Habilitar a Protecao do Sistema, ou reexecutar com -SkipRestorePoint assumindo o risco.'
                    Set-DebloatResultado 'ERROR' | Out-Null
                    return
                }

                # --- Fase 3: retrato do estado anterior
                Invoke-DebloatBackup -Manifesto $Manifesto | Out-Null
                $parcial = Save-DebloatManifesto -Manifesto $Manifesto
                if (-not $parcial.Ok) {
                    Write-Log ERR 'Rotina interrompida: o retrato do estado anterior nao pode ser gravado em disco.'
                    Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Backup de estado nao pode ser persistido antes das alteracoes.' `
                        -Recommendation 'Sem manifesto gravado nao ha caminho de volta. Verifique permissao e espaco no diretorio de logs.'
                    Set-DebloatResultado 'ERROR' | Out-Null
                    return
                }
                Write-Color ''
            }

            # --- Fases 4 a 8: aplicativos, servicos, tarefas, privacidade, ajustes
            $l  = Invoke-DebloatCategorias -Categorias $script:CategoriasTodas -Manifesto $Manifesto -Simular:$Simular

            # --- Fase 9: componentes
            $lc = Invoke-DebloatComponentes -Manifesto $Manifesto -Simular:$Simular

            # --- Fase 10: validacao global e relatorio
            Write-DebloatResumo -Linhas (@($l) + @($lc)) -Titulo 'Debloat completo' -Simulacao:$Simular

            if (-not $Simular) {
                Write-Color ''
                Write-Color '  Reinicie o computador para consolidar as alteracoes de servico e componente.' -Color Yellow
            }
        }
    }
}

$moduloIniciado = $false
$codigo = $null

try {
    $precisaAdmin = @('Apps', 'Services', 'Tasks', 'Privacy', 'Tweaks', 'Components', 'Full', 'Restore', 'RestorePoint') -contains $Action
    if (Start-CompartDiskModule -Name 'Debloat' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet) {
        $moduloIniciado = $true
    } else {
        $result = 'ERROR'
    }

    if ($moduloIniciado) {
        $simular   = ($DryRun -or $Action -eq 'Analyze')
        # Backup e leitura pura: o retrato do estado continua valendo sob -DryRun
        # e por isso nao e marcado como simulacao no manifesto.
        $manifesto = New-DebloatManifesto -Acao $Action -NivelUsado $Level -Simulacao ($simular -and $Action -ne 'Backup')

        # --- Fase 1: validacao previa das acoes que alteram o sistema
        $seguir = $true
        if ($Action -notin @('Analyze', 'Backup')) {
            $pre = Test-DebloatPreconditions
            foreach ($a in $pre.Avisos) { Write-Log WARN $a }
            if ($pre.Avisos.Count -gt 0) { Set-DebloatResultado 'WARN' | Out-Null }
            if (-not $pre.Ok) {
                foreach ($i in $pre.Impeditivos) { Write-Log ERR $i }
                Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Pre-requisitos nao atendidos; nenhuma alteracao foi feita.' `
                    -Recommendation ($pre.Impeditivos -join ' | ')
                Set-DebloatResultado 'ERROR' | Out-Null
                $seguir = $false
            }
        }

        if ($seguir) {
            Invoke-DebloatDespacho -Manifesto $manifesto -Simular $simular

            $houveAlteracao = @($manifesto.Itens | Where-Object { "$($_.Resultado)" -in @('Aplicado', 'Parcial') }).Count -gt 0
            $deveSalvar     = ($Action -ne 'Restore') -and ((-not $simular) -or $Action -eq 'Backup')
            if ($deveSalvar -and @($manifesto.Itens).Count -gt 0) {
                Save-DebloatManifesto -Manifesto $manifesto -Obrigatorio:$houveAlteracao | Out-Null
            }
        }
    }

} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Debloat (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    # Stop so pode ser chamado se Start tiver sido bem sucedido: caso contrario
    # o Core encerraria um modulo que nunca abriu.
    if ($moduloIniciado) { $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet }
}

if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit.ERROR }
exit $codigo
