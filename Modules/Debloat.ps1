<#
 COMPARTDISK 1.3.1 - Debloat.ps1
 Desenvolvido por Edsilas
 Acoes: Analyze | Apps | Services | Tasks | Privacy | Tweaks | Components | Full
        Backup | Restore | RestorePoint

 PRINCIPIOS DESTE MODULO
 1. Simulacao e o padrao. A acao 'Analyze' nunca altera nada, e -DryRun aplica a
    mesma protecao a qualquer outra acao.
 2. Nada e removido por opiniao. Cada item do catalogo declara nivel de risco,
    motivo e reversibilidade, e so entra no nivel escolhido pelo operador.
 3. Listas de protecao vencem o catalogo. Um item protegido nunca e tocado, mesmo
    que seja pedido explicitamente por -Include.
 4. Toda alteracao e registrada em manifesto com o estado ANTERIOR, o que permite
    a acao 'Restore' devolver o sistema ao ponto de partida.
 5. Nao duplica outros modulos. Limpeza de temporarios pertence a Cleanup.ps1,
    telemetria a Telemetry.ps1 e plano de energia a Performance.ps1. Este modulo
    cobre apenas o que aqueles nao cobrem, e delega o resto.
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

$result = 'OK'

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
    'NcsiUwpApp'
    'Windows.CBSPreview'
    'Windows.PrintDialog'
    'Windows.immersivecontrolpanel'
)

# Prefixos de familia sempre protegidos (bibliotecas de runtime e o novo shell
# do Windows 11). Remover qualquer um deles derruba dezenas de aplicativos.
$AppxPrefixosProtegidos = @(
    'Microsoft.VCLibs.'
    'Microsoft.NET.Native.'
    'Microsoft.UI.Xaml.'
    'Microsoft.WindowsAppRuntime.'
    'MicrosoftWindows.Client.'
    'MicrosoftWindows.UndockedDevKit'
    'Microsoft.WindowsPackageManager'
)

# Servicos que sustentam atualizacao, seguranca, rede, audio, sessao e
# instalacao de software. Fora do alcance deste modulo em qualquer nivel.
$ServicosProtegidos = @(
    'wuauserv', 'BITS', 'CryptSvc', 'msiserver', 'TrustedInstaller', 'sppsvc'
    'WinDefend', 'SecurityHealthService', 'wscsvc', 'mpssvc', 'SgrmBroker'
    'EventLog', 'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'PlugPlay', 'Power'
    'Schedule', 'Winmgmt', 'ProfSvc', 'UserManager', 'SamSs', 'LSM'
    'Dhcp', 'Dnscache', 'nsi', 'NlaSvc', 'netprofm', 'LanmanWorkstation'
    'WlanSvc', 'NetSetupSvc', 'WinHttpAutoProxySvc'
    'AudioSrv', 'Audiosrv', 'AudioEndpointBuilder', 'Themes', 'ShellHWDetection'
    'CoreMessagingRegistrar', 'SystemEventsBroker', 'StateRepository'
    'TokenBroker', 'AppXSvc', 'ClipSVC', 'InstallService', 'EntAppSvc'
    'BFE', 'DPS', 'gpsvc', 'KeyIso', 'Netlogon', 'SENS', 'BrokerInfrastructure'
    'DispBrokerDesktopSvc', 'UdkUserSvc', 'CDPUserSvc', 'WpnService'
)

# Ramos de registro fora de alcance. Reaproveita o conceito de ponto unico de
# decisao ja adotado em Test-CompartDiskProtectedPath para o sistema de arquivos.
$RegistroProtegido = @(
    'HKLM:\SYSTEM\CurrentControlSet\Services'
    'HKLM:\SYSTEM\CurrentControlSet\Control'
    'HKLM:\SECURITY'
    'HKLM:\SAM'
)

# ==============================================================================
# 2. CATALOGO DECLARATIVO
#    Cada entrada carrega o nivel minimo em que passa a ser elegivel, o motivo
#    tecnico e se a alteracao pode ser desfeita integralmente pela acao Restore.
# ==============================================================================

function New-CatalogoItem {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Appx', 'Service', 'Task', 'Registry')][string]$Tipo,
        [Parameter(Mandatory)][string]$Alvo,
        [Parameter(Mandatory)][string]$Categoria,
        [Parameter(Mandatory)][ValidateSet('Safe', 'Moderate', 'Aggressive')][string]$Nivel,
        [Parameter(Mandatory)][string]$Motivo,
        [bool]$Reversivel = $true,
        [hashtable]$Dados = @{}
    )
    return [pscustomobject]@{
        Id         = $Id
        Tipo       = $Tipo
        Alvo       = $Alvo
        Categoria  = $Categoria
        Nivel      = $Nivel
        Motivo     = $Motivo
        Reversivel = $Reversivel
        Dados      = $Dados
    }
}

function Get-DebloatCatalogo {
    <# Fonte unica de verdade. Toda acao deriva daqui, o que mantem simulacao,
       execucao e relatorio sempre coerentes entre si. #>
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
    # muda conforme o fabricante e a regiao do equipamento.
    $terceiros = @(
        '*CandyCrush*', '*BubbleWitch*', 'king.com.*', '*Spotify*', '*Disney*'
        '*Netflix*', '*Facebook*', '*Twitter*', '*TikTok*', '*Instagram*'
        '*LinkedIn*', '*Duolingo*', '*EclipseManager*', '*ActiproSoftware*'
        '*AdobeSystemsIncorporated.AdobePhotoshopExpress*', '*Dolby*'
        '*PrimeVideo*', '*Amazon.com.Amazon*', '*Hulu*', '*Booking.com*'
        '*iHeartRadio*', '*Plex*', '*Sidia.LiveWallpaper*', '*RoyalRevolt*'
        '*Wunderlist*', '*Flipboard*', '*Asphalt*', '*MarchofEmpires*'
    )
    foreach ($t in $terceiros) {
        & $add (New-CatalogoItem -Id "app:$t" -Tipo Appx -Alvo $t -Categoria 'Aplicativos' `
            -Nivel Safe -Motivo 'Aplicativo comercial pre-instalado pelo fabricante.' -Reversivel $false)
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
    $appsAggressive = @(
        @{ N = 'Microsoft.ScreenSketch'; M = 'Ferramenta de Captura; assume a tecla Print Screen no Windows 11.' }
        @{ N = 'Microsoft.WindowsCalculator'; M = 'Calculadora do Windows.' }
        @{ N = 'Microsoft.XboxIdentityProvider'; M = 'Autenticacao Xbox; alguns jogos dependem dela para login.' }
        @{ N = 'Microsoft.WindowsFeedback'; M = 'Componente legado de feedback.' }
    )
    foreach ($a in $appsAggressive) {
        & $add (New-CatalogoItem -Id "app:$($a.N)" -Tipo Appx -Alvo $a.N -Categoria 'Aplicativos' `
            -Nivel Aggressive -Motivo $a.M -Reversivel $false)
    }

    # ---------- SERVICOS ----------
    # DiagTrack e dmwappushservice ficam de fora de proposito: pertencem ao
    # modulo Telemetry.ps1. Duplicar aqui criaria duas fontes de verdade.
    $servicos = @(
        @{ N = 'MapsBroker'; Startup = 'Disabled'; L = 'Safe'; M = 'Gerenciador de mapas baixados; sem uso se o app Mapas foi removido.' }
        @{ N = 'RetailDemo'; Startup = 'Disabled'; L = 'Safe'; M = 'Modo de demonstracao de loja; irrelevante fora do varejo.' }
        @{ N = 'WMPNetworkSvc'; Startup = 'Disabled'; L = 'Safe'; M = 'Compartilhamento de midia do Windows Media Player.' }
        @{ N = 'Fax'; Startup = 'Disabled'; L = 'Safe'; M = 'Servico de fax analogico.' }
        @{ N = 'RemoteRegistry'; Startup = 'Disabled'; L = 'Safe'; M = 'Acesso remoto ao registro; superficie de ataque sem uso domestico.' }
        @{ N = 'PrintNotify'; Startup = 'Manual'; L = 'Safe'; M = 'Notificacoes de impressora; a fila continua funcionando.' }
        @{ N = 'WerSvc'; Startup = 'Manual'; L = 'Moderate'; M = 'Relatorio de erros do Windows.' }
        @{ N = 'lfsvc'; Startup = 'Manual'; L = 'Moderate'; M = 'Geolocalizacao; alguns aplicativos de clima e mapas dependem dela.' }
        @{ N = 'XblAuthManager'; Startup = 'Manual'; L = 'Moderate'; M = 'Autenticacao Xbox Live.' }
        @{ N = 'XblGameSave'; Startup = 'Manual'; L = 'Moderate'; M = 'Salvamento na nuvem do Xbox.' }
        @{ N = 'XboxNetApiSvc'; Startup = 'Manual'; L = 'Moderate'; M = 'Rede do Xbox Live.' }
        @{ N = 'XboxGipSvc'; Startup = 'Manual'; L = 'Moderate'; M = 'Acessorios Xbox conectados por USB.' }
        @{ N = 'SysMain'; Startup = 'Disabled'; L = 'Moderate'; M = 'Superfetch; ganho nulo em SSD e custo de I/O em segundo plano.' }
        @{ N = 'WSearch'; Startup = 'Disabled'; L = 'Aggressive'; M = 'Indexacao do Windows Search; desativa a busca do menu Iniciar.' }
        @{ N = 'TabletInputService'; Startup = 'Manual'; L = 'Aggressive'; M = 'Teclado virtual e escrita a caneta.' }
    )
    foreach ($s in $servicos) {
        & $add (New-CatalogoItem -Id "svc:$($s.N)" -Tipo Service -Alvo $s.N -Categoria 'Servicos' `
            -Nivel $s.L -Motivo $s.M -Reversivel $true -Dados @{ Startup = $s.Startup })
    }

    # ---------- TAREFAS AGENDADAS ----------
    # As seis tarefas de telemetria classica pertencem ao Telemetry.ps1.
    $tarefas = @(
        @{ N = '\Microsoft\Windows\Application Experience\StartupAppTask'; L = 'Safe'; M = 'Coleta de dados de aplicativos de inicializacao.' }
        @{ N = '\Microsoft\Windows\Application Experience\PcaPatchDbTask'; L = 'Safe'; M = 'Banco de compatibilidade de aplicativos.' }
        @{ N = '\Microsoft\Windows\Windows Error Reporting\QueueReporting'; L = 'Safe'; M = 'Envio de relatorios de erro a Microsoft.' }
        @{ N = '\Microsoft\Windows\CloudExperienceHost\CreateObjectTask'; L = 'Safe'; M = 'Experiencia de nuvem na primeira execucao.' }
        @{ N = '\Microsoft\Windows\Maps\MapsToastTask'; L = 'Safe'; M = 'Notificacoes do aplicativo Mapas.' }
        @{ N = '\Microsoft\Windows\Maps\MapsUpdateTask'; L = 'Safe'; M = 'Atualizacao de mapas offline.' }
        @{ N = '\Microsoft\Windows\Retail Demo\CleanupOfflineContent'; L = 'Safe'; M = 'Limpeza do modo demonstracao de loja.' }
        @{ N = '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'; L = 'Safe'; M = 'Coleta de feedback por cenario.' }
        @{ N = '\Microsoft\Windows\DiskFootprint\Diagnostics'; L = 'Moderate'; M = 'Diagnostico de uso de disco.' }
        @{ N = '\Microsoft\Windows\Shell\FamilySafetyMonitor'; L = 'Moderate'; M = 'Monitoramento de controle dos pais.' }
        @{ N = '\Microsoft\Windows\Shell\FamilySafetyRefreshTask'; L = 'Moderate'; M = 'Atualizacao do controle dos pais.' }
        @{ N = '\Microsoft\Office\OfficeTelemetryAgentLogOn'; L = 'Moderate'; M = 'Telemetria do Microsoft Office.' }
        @{ N = '\Microsoft\Office\OfficeTelemetryAgentFallBack'; L = 'Moderate'; M = 'Telemetria do Microsoft Office.' }
        @{ N = '\Microsoft\Windows\Windows Media Sharing\UpdateLibrary'; L = 'Moderate'; M = 'Biblioteca compartilhada do Media Player.' }
    )
    foreach ($t in $tarefas) {
        & $add (New-CatalogoItem -Id "task:$($t.N)" -Tipo Task -Alvo $t.N -Categoria 'Tarefas' `
            -Nivel $t.L -Motivo $t.M -Reversivel $true)
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
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; N = 'BingSearchEnabled'; V = 0; L = 'Safe'; M = 'Busca da web dentro do menu Iniciar.' }
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

    # ---------- AJUSTES OPCIONAIS ----------
    $adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $tweaks = @(
        @{ P = $adv; N = 'HideFileExt'; V = 0; L = 'Safe'; M = 'Exibe a extensao dos arquivos; reduz risco de arquivo disfarcado.' }
        @{ P = $adv; N = 'LaunchTo'; V = 1; L = 'Safe'; M = 'Explorer abre em Este Computador em vez de Acesso Rapido.' }
        @{ P = $adv; N = 'ShowTaskViewButton'; V = 0; L = 'Safe'; M = 'Oculta o botao de Visao de Tarefas na barra.' }
        @{ P = $adv; N = 'TaskbarDa'; V = 0; L = 'Safe'; M = 'Oculta Widgets na barra de tarefas (Windows 11).' }
        @{ P = $adv; N = 'TaskbarMn'; V = 0; L = 'Safe'; M = 'Oculta o Chat na barra de tarefas (Windows 11).' }
        @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; N = 'EnableFeeds'; V = 0; L = 'Safe'; M = 'Desativa Noticias e Interesses (Windows 10).' }
        @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard'; N = 'Disabled'; V = 1; L = 'Moderate'; M = 'Acoes sugeridas ao copiar texto.' }
        @{ P = 'HKLM:\SYSTEM\CurrentControlSet\Policies'; N = 'NtfsDisableLastAccessUpdate'; V = 1; L = 'Moderate'; M = 'Reduz escrita de metadados NTFS a cada leitura.' }
        @{ P = $adv; N = 'ShowSyncProviderNotifications'; V = 0; L = 'Moderate'; M = 'Anuncios do OneDrive dentro do Explorer.' }
        @{ P = 'HKCU:\Control Panel\Desktop'; N = 'MenuShowDelay'; V = 200; L = 'Aggressive'; M = 'Reduz o atraso de abertura de menus de 400 ms para 200 ms.' }
    )
    foreach ($t in $tweaks) {
        $tipoReg = if ($t.P -eq 'HKCU:\Control Panel\Desktop') { 'String' } else { 'DWord' }
        $valor   = if ($tipoReg -eq 'String') { "$($t.V)" } else { $t.V }
        & $add (New-CatalogoItem -Id "reg:$($t.P)\$($t.N)" -Tipo Registry -Alvo "$($t.P)\$($t.N)" `
            -Categoria 'Ajustes' -Nivel $t.L -Motivo $t.M -Reversivel $true `
            -Dados @{ Caminho = $t.P; Nome = $t.N; Valor = $valor; Tipo = $tipoReg })
    }

    return @($c)
}

# ==============================================================================
# 3. FILTRAGEM, PROTECAO E VALIDACAO
# ==============================================================================

$NiveisOrdem = @{ Safe = 1; Moderate = 2; Aggressive = 3 }

function Test-AppxProtegido {
    <# Protecao por nome exato ou por prefixo de familia. Aplicada antes de
       qualquer outra regra, inclusive antes de -Include. #>
    param([Parameter(Mandatory)][string]$Nome)
    if ($AppxProtegidos -contains $Nome) { return $true }
    foreach ($p in $AppxPrefixosProtegidos) {
        if ($Nome.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-ItemProtegido {
    param([Parameter(Mandatory)][object]$Item)
    switch ($Item.Tipo) {
        'Appx'     { return (Test-AppxProtegido -Nome $Item.Alvo) }
        'Service'  { return ($ServicosProtegidos -contains $Item.Alvo) }
        'Registry' {
            foreach ($r in $RegistroProtegido) {
                if ("$($Item.Dados.Caminho)".StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
        }
        default    { return $false }
    }
}

function Select-DebloatItens {
    <# Aplica, nesta ordem: nivel -> -Include -> -Exclude -> listas de protecao.
       A protecao vem por ultimo justamente para nao poder ser contornada. #>
    param(
        [Parameter(Mandatory)][object[]]$Catalogo,
        [string]$NivelMaximo = 'Safe',
        [string[]]$Incluir = @(),
        [string[]]$Excluir = @()
    )
    $teto = $NiveisOrdem[$NivelMaximo]
    $sel  = New-Object System.Collections.ArrayList

    foreach ($i in $Catalogo) {
        $elegivel = ($NiveisOrdem[$i.Nivel] -le $teto)

        if ($Incluir.Count -gt 0) {
            $elegivel = $false
            foreach ($p in $Incluir) {
                if ($i.Id -like $p -or $i.Alvo -like $p -or $i.Categoria -like $p) { $elegivel = $true; break }
            }
        }
        if (-not $elegivel) { continue }

        $vetado = $false
        foreach ($p in $Excluir) {
            if ($i.Id -like $p -or $i.Alvo -like $p -or $i.Categoria -like $p) { $vetado = $true; break }
        }
        if ($vetado) { continue }

        if (Test-ItemProtegido -Item $i) {
            Write-Log DEBUG "Item protegido ignorado: $($i.Id)" -NoConsole
            continue
        }
        [void]$sel.Add($i)
    }
    return @($sel)
}

function Test-DebloatPreconditions {
    <# Validacao previa. Devolve objeto com Ok e a lista de impedimentos, para
       que o chamador decida entre abortar e prosseguir com ressalva. #>
    [CmdletBinding()] param()
    $avisos     = New-Object System.Collections.ArrayList
    $impeditivos = New-Object System.Collections.ArrayList

    $w = Test-WindowsVersion
    if (-not $w.Supported) {
        [void]$impeditivos.Add("Build $($w.Build) fora do escopo suportado (Windows 10/11).")
    }

    if (-not (Test-Administrator)) {
        [void]$impeditivos.Add('Privilegios administrativos ausentes.')
    }

    if (Test-CompartDiskPendingReboot) {
        [void]$avisos.Add('Ha reinicio pendente. Alteracoes de servico e componente podem nao se consolidar ate reiniciar.')
    }

    if (-not (Test-CompartDiskCommand 'Get-AppxPackage')) {
        if (-not (Import-CompartDiskModule 'Appx')) {
            [void]$avisos.Add('Modulo Appx indisponivel: a remocao de aplicativos sera ignorada.')
        }
    }

    if (-not (Test-CompartDiskCommand 'Get-ScheduledTask')) {
        [void]$avisos.Add('Modulo ScheduledTasks indisponivel: as tarefas agendadas serao ignoradas.')
    }

    $livre = 0
    try {
        $d = Get-CompartDiskCim -Class Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
        if ($d) { $livre = [double]$d.FreeSpace }
    } catch { }
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
       disco mecanico e custo de I/O em estado solido. #>
    try {
        if (-not (Test-CompartDiskCommand 'Get-PhysicalDisk')) { return $null }
        $tipos = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object -ExpandProperty MediaType -ErrorAction SilentlyContinue)
        if ($tipos.Count -eq 0) { return $null }
        if ($tipos -contains 'HDD') { return $false }
        return ($tipos -contains 'SSD')
    } catch { return $null }
}

# ==============================================================================
# 4. MANIFESTO DE REVERSAO
# ==============================================================================

function Get-DebloatPastaRestauracao {
    <# Fora do diretorio de sessao: a restauracao precisa sobreviver a sessoes
       futuras, enquanto OutDir e recriado a cada execucao. #>
    $p = Join-Path $Global:CompartDisk.LogDir 'COMPARTDISK_Restauracao'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function New-DebloatManifesto {
    param([string]$Acao, [string]$NivelUsado)
    return [pscustomobject]@{
        Produto    = $Global:CompartDisk.Product
        Versao     = $Global:CompartDisk.Version
        Sessao     = $Global:CompartDisk.Session
        Computador = $Global:CompartDisk.Computer
        Usuario    = $Global:CompartDisk.User
        Acao       = $Acao
        Nivel      = $NivelUsado
        Criado     = (Get-Date -Format 's')
        Itens      = (New-Object System.Collections.ArrayList)
    }
}

function Add-DebloatRegistro {
    <# Grava o estado ANTERIOR do item. E este campo que torna a acao Restore
       possivel; sem ele havia apenas um log narrativo, nao um plano de volta. #>
    param(
        [Parameter(Mandatory)][object]$Manifesto,
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$Resultado,
        [object]$EstadoAnterior = $null,
        [string]$Detalhe = ''
    )
    [void]$Manifesto.Itens.Add([pscustomobject]@{
        Id             = $Item.Id
        Tipo           = $Item.Tipo
        Alvo           = $Item.Alvo
        Categoria      = $Item.Categoria
        Nivel          = $Item.Nivel
        Resultado      = $Resultado
        EstadoAnterior = $EstadoAnterior
        Reversivel     = $Item.Reversivel
        Detalhe        = $Detalhe
        Quando         = (Get-Date -Format 's')
    })
}

function Save-DebloatManifesto {
    param([Parameter(Mandatory)][object]$Manifesto)
    if ($Manifesto.Itens.Count -eq 0) { return $null }
    $nome = 'Debloat_Manifesto_{0}.json' -f $Global:CompartDisk.Session
    $json = $Manifesto | ConvertTo-Json -Depth 10
    $enc  = New-Object System.Text.UTF8Encoding($false)

    $destinos = @(
        (Join-Path $Global:CompartDisk.OutDir $nome)
        (Join-Path (Get-DebloatPastaRestauracao) $nome)
    )
    $gravados = New-Object System.Collections.ArrayList
    foreach ($d in $destinos) {
        try {
            [System.IO.File]::WriteAllText($d, $json, $enc)
            [void]$gravados.Add($d)
        } catch {
            Write-Log WARN "Nao foi possivel gravar o manifesto em: $d" -ErrorRecord $_
        }
    }
    foreach ($g in $gravados) { Write-Log OK "Manifesto de reversao: $g" }
    return @($gravados)
}

function Get-DebloatUltimoManifesto {
    param([string]$Caminho = '')
    if ($Caminho) {
        if (-not (Test-Path -LiteralPath $Caminho)) { throw "Manifesto nao encontrado: $Caminho" }
        return (Get-Content -LiteralPath $Caminho -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    $pasta = Get-DebloatPastaRestauracao
    $ult = Get-ChildItem -LiteralPath $pasta -Filter 'Debloat_Manifesto_*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $ult) { return $null }
    Write-Log INFO "Manifesto selecionado: $($ult.FullName)"
    return (Get-Content -LiteralPath $ult.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ==============================================================================
# 5. EXECUTORES POR TIPO
#    Cada um devolve um objeto uniforme, o que permite ao relatorio e ao
#    manifesto tratarem aplicativos, servicos, tarefas e registro do mesmo jeito.
# ==============================================================================

function Invoke-DebloatAppx {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida = [pscustomobject]@{ Resultado = 'Ignorado'; Anterior = $null; Detalhe = ''; Encontrado = $false }

    if (-not (Test-CompartDiskCommand 'Get-AppxPackage')) {
        $saida.Detalhe = 'Modulo Appx indisponivel'
        return $saida
    }

    $pacotes = @()
    try {
        $pacotes = @(Get-AppxPackage -AllUsers -Name $Item.Alvo -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.IsFramework -and -not $_.NonRemovable })
    } catch {
        try { $pacotes = @(Get-AppxPackage -Name $Item.Alvo -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework }) } catch { }
    }

    $prov = @()
    try {
        if (Test-CompartDiskCommand 'Get-AppxProvisionedPackage') {
            $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                      Where-Object { $_.DisplayName -like $Item.Alvo })
        }
    } catch { }

    if ($pacotes.Count -eq 0 -and $prov.Count -eq 0) {
        $saida.Detalhe = 'Nao instalado'
        return $saida
    }
    $saida.Encontrado = $true

    # Reconfirma a protecao com o nome real do pacote: o catalogo pode ter usado
    # curinga, e um curinga amplo nao pode arrastar um pacote protegido junto.
    $bloqueados = @($pacotes | Where-Object { Test-AppxProtegido -Nome $_.Name })
    # A reconfirmacao cobria apenas $pacotes. Um curinga que casasse um pacote
    # PROVISIONADO protegido e nao instalado para nenhum usuario passava direto,
    # porque $bloqueados ficava vazio. Nenhum curinga do catalogo atual exercita esse
    # caminho; a guarda fecha o buraco para os que vierem.
    $prov = @($prov | Where-Object { -not (Test-AppxProtegido -Nome "$($_.DisplayName)") })
    if ($bloqueados.Count -gt 0) {
        $saida.Resultado = 'Protegido'
        $saida.Detalhe   = "Pacote protegido: $(($bloqueados | ForEach-Object { $_.Name }) -join ', ')"
        return $saida
    }

    $saida.Anterior = [pscustomobject]@{
        Pacotes      = @($pacotes | ForEach-Object { $_.PackageFullName })
        Provisionado = @($prov | ForEach-Object { $_.PackageName })
        Versao       = @($pacotes | ForEach-Object { "$($_.Version)" }) | Select-Object -First 1
    }

    if ($Simular) {
        $saida.Resultado = 'Simulado'
        $saida.Detalhe   = "$($pacotes.Count) instancia(s), $($prov.Count) provisionamento(s)"
        return $saida
    }

    $removidos = 0; $falhas = 0
    foreach ($p in $pacotes) {
        $r = Invoke-SafeCommand {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
        } -Activity "Remover $($p.Name)" -Silent
        if ($r.Success) { $removidos++ }
        else {
            # -AllUsers falha em algumas edicoes; tenta no escopo do usuario atual.
            $r2 = Invoke-SafeCommand { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop } -Activity "Remover $($p.Name) (usuario)" -Silent
            if ($r2.Success) { $removidos++ } else { $falhas++ }
        }
    }
    foreach ($p in $prov) {
        $r = Invoke-SafeCommand {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop
        } -Activity "Desprovisionar $($p.DisplayName)" -Silent
        if (-not $r.Success) { $falhas++ }
    }

    if ($removidos -gt 0 -or ($prov.Count -gt 0 -and $falhas -eq 0)) {
        $saida.Resultado = 'Aplicado'
        $saida.Detalhe   = "$removidos removido(s), $($prov.Count) desprovisionado(s), $falhas falha(s)"
    } else {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = "Nenhuma instancia pode ser removida ($falhas falha(s))"
    }
    return $saida
}

function Invoke-DebloatServico {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida = [pscustomobject]@{ Resultado = 'Ignorado'; Anterior = $null; Detalhe = ''; Encontrado = $false }
    $svc = $null
    try { $svc = Get-Service -Name $Item.Alvo -ErrorAction Stop } catch { $saida.Detalhe = 'Servico inexistente neste build'; return $saida }
    $saida.Encontrado = $true

    $inicioAtual = 'n/d'
    try {
        $w = Get-CompartDiskCim -Class Win32_Service -Filter "Name='$($Item.Alvo)'"
        if ($w) { $inicioAtual = "$($w.StartMode)" }
    } catch { }

    $saida.Anterior = [pscustomobject]@{ StartType = $inicioAtual; Status = "$($svc.Status)" }
    $destino = $Item.Dados.Startup

    if ("$inicioAtual" -eq "$destino" -and $svc.Status -ne 'Running') {
        $saida.Resultado = 'JaAplicado'
        $saida.Detalhe   = "Ja em $destino"
        return $saida
    }

    if ($Simular) {
        $saida.Resultado = 'Simulado'
        $saida.Detalhe   = "$inicioAtual/$($svc.Status) -> $destino/Stopped"
        return $saida
    }

    $r = Invoke-SafeCommand {
        if ($svc.Status -eq 'Running') { Stop-Service -Name $Item.Alvo -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Item.Alvo -StartupType $destino -ErrorAction Stop
    } -Activity "Servico $($Item.Alvo) -> $destino" -Silent

    if ($r.Success) {
        $saida.Resultado = 'Aplicado'
        $saida.Detalhe   = "$inicioAtual -> $destino"
    } else {
        $saida.Resultado = 'Falhou'
        $saida.Detalhe   = "$($r.Error.Exception.Message)"
    }
    return $saida
}

function Invoke-DebloatTarefa {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida = [pscustomobject]@{ Resultado = 'Ignorado'; Anterior = $null; Detalhe = ''; Encontrado = $false }
    if (-not (Test-CompartDiskCommand 'Get-ScheduledTask')) { $saida.Detalhe = 'Modulo ScheduledTasks indisponivel'; return $saida }

    $nome    = Split-Path $Item.Alvo -Leaf
    $caminho = (Split-Path $Item.Alvo -Parent) + '\'
    $tk = $null
    try { $tk = Get-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop } catch { $saida.Detalhe = 'Tarefa inexistente neste build'; return $saida }
    $saida.Encontrado = $true
    $saida.Anterior   = [pscustomobject]@{ State = "$($tk.State)" }

    if ("$($tk.State)" -eq 'Disabled') { $saida.Resultado = 'JaAplicado'; $saida.Detalhe = 'Ja desabilitada'; return $saida }
    if ($Simular) { $saida.Resultado = 'Simulado'; $saida.Detalhe = "$($tk.State) -> Disabled"; return $saida }

    $r = Invoke-SafeCommand { Disable-ScheduledTask -TaskName $nome -TaskPath $caminho -ErrorAction Stop | Out-Null } -Activity "Tarefa $nome" -Silent
    if ($r.Success) { $saida.Resultado = 'Aplicado'; $saida.Detalhe = "$($tk.State) -> Disabled" }
    else            { $saida.Resultado = 'Falhou';   $saida.Detalhe = "$($r.Error.Exception.Message)" }
    return $saida
}

function Invoke-DebloatRegistro {
    param([Parameter(Mandatory)][object]$Item, [switch]$Simular)

    $saida = [pscustomobject]@{ Resultado = 'Ignorado'; Anterior = $null; Detalhe = ''; Encontrado = $true }
    $caminho = $Item.Dados.Caminho
    $nome    = $Item.Dados.Nome
    $valor   = $Item.Dados.Valor
    $tipo    = $Item.Dados.Tipo

    $atual = Get-CompartDiskRegistryValue -Path $caminho -Name $nome -Default '<inexistente>'
    $saida.Anterior = [pscustomobject]@{ Valor = "$atual"; Tipo = $tipo; Existia = ("$atual" -ne '<inexistente>') }

    if ("$atual" -eq "$valor") { $saida.Resultado = 'JaAplicado'; $saida.Detalhe = "Ja em $valor"; return $saida }
    if ($Simular) { $saida.Resultado = 'Simulado'; $saida.Detalhe = "$atual -> $valor"; return $saida }

    if (Set-CompartDiskRegistryValue -Path $caminho -Name $nome -Value $valor -Type $tipo) {
        $saida.Resultado = 'Aplicado'; $saida.Detalhe = "$atual -> $valor"
    } else {
        $saida.Resultado = 'Falhou';   $saida.Detalhe = 'Gravacao recusada'
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
    }
}

# ==============================================================================
# 6. ORQUESTRACAO
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
    $itens = Select-DebloatItens -Catalogo $catalogo -NivelMaximo $Level -Incluir $Include -Excluir $Exclude |
             Where-Object { $Categorias -contains $_.Categoria }

    if ($itens.Count -eq 0) {
        Write-Log WARN "Nenhum item elegivel em: $($Categorias -join ', ') (nivel $Level)."
        return @()
    }

    # SysMain so faz sentido em disco mecanico. Manter o item no catalogo e
    # decidir aqui preserva a transparencia: o relatorio mostra por que ficou.
    $ssd = Test-SistemaEmSsd
    if ($ssd -eq $false) {
        $itens = @($itens | Where-Object { $_.Id -ne 'svc:SysMain' })
        Write-Log INFO 'Disco mecanico detectado: SysMain preservado (o Superfetch traz ganho real nesse hardware).'
    }

    Write-Log INFO ("{0} item(ns) elegivel(is) em {1} | nivel {2}{3}" -f `
        $itens.Count, ($Categorias -join ', '), $Level, $(if ($Simular) { ' | SIMULACAO' } else { '' }))

    $linhas = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($i in $itens) {
        $n++
        $r = Invoke-DebloatItem -Item $i -Simular:$Simular

        if ($r.Resultado -ne 'Ignorado') {
            Add-DebloatRegistro -Manifesto $Manifesto -Item $i -Resultado $r.Resultado `
                -EstadoAnterior $r.Anterior -Detalhe $r.Detalhe
        }

        [void]$linhas.Add([pscustomobject]@{
            Categoria = $i.Categoria
            Tipo      = $i.Tipo
            Alvo      = $i.Alvo
            Nivel     = $i.Nivel
            Resultado = $r.Resultado
            Detalhe   = $r.Detalhe
            Motivo    = $i.Motivo
        })

        $cor = switch ($r.Resultado) {
            'Aplicado'   { 'Green' }
            'Simulado'   { 'Cyan' }
            'JaAplicado' { 'DarkGray' }
            'Protegido'  { 'Yellow' }
            'Falhou'     { 'Red' }
            default      { 'DarkGray' }
        }
        if ($r.Resultado -ne 'Ignorado') {
            Write-Color ("  [{0,3}/{1,3}] {2,-11} {3,-46} {4}" -f $n, $itens.Count, $r.Resultado, `
                $(if ($i.Alvo.Length -gt 46) { $i.Alvo.Substring(0, 43) + '...' } else { $i.Alvo }), $r.Detalhe) -Color $cor
        }
    }
    return @($linhas)
}

function Invoke-DebloatComponentes {
    <# Limpeza do armazenamento de componentes. Nao duplica Cleanup.ps1: aquele
       trata arquivos temporarios, este trata o WinSxS, que exige DISM. #>
    param([Parameter(Mandatory)][object]$Manifesto, [switch]$Simular)

    $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
    if (-not (Test-Path -LiteralPath $dism)) {
        Write-Log ERR 'Dism.exe nao localizado. Limpeza de componentes indisponivel.'
        $script:result = 'WARN'
        return @()
    }

    $linhas = New-Object System.Collections.ArrayList

    Write-Log INFO 'Analisando o armazenamento de componentes (WinSxS). Pode levar alguns minutos...'
    $an = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $dism -Arguments @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') -TimeoutSeconds 1800
    } -Activity 'DISM AnalyzeComponentStore'

    $recomendado = 'n/d'; $tamanho = 'n/d'
    if ($an.Success -and $an.Value.StdOut) {
        foreach ($l in ($an.Value.StdOut -split "`r?`n")) {
            if ($l -match '(?i)(Component Store Cleanup Recommended|Limpeza .*Recomendada)\s*:\s*(.+)$') { $recomendado = $matches[2].Trim() }
            if ($l -match '(?i)(Actual Size of Component Store|Tamanho Real d[oa].*Componentes)\s*:\s*(.+)$') { $tamanho = $matches[2].Trim() }
        }
    }
    [void]$linhas.Add([pscustomobject]@{
        Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'AnalyzeComponentStore'
        Nivel = 'Safe'; Resultado = $(if ($an.Success) { 'Analisado' } else { 'Falhou' })
        Detalhe = "Tamanho real: $tamanho | Limpeza recomendada: $recomendado"; Motivo = 'Diagnostico do WinSxS.'
    })
    Write-CompartDiskKeyValue 'Tamanho do WinSxS' $tamanho -Pad 24
    Write-CompartDiskKeyValue 'Limpeza recomendada' $recomendado -Pad 24

    if ($Simular) {
        Write-Log INFO 'Simulacao: a limpeza de componentes nao foi executada.'
        return @($linhas)
    }

    $argumentos = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    $obs  = 'Remove versoes superadas de componentes.'
    if ($Level -eq 'Aggressive') {
        $argumentos += '/ResetBase'
        $obs   = 'Com /ResetBase: libera mais espaco, mas impede desinstalar as atualizacoes ja aplicadas.'
        Write-Log WARN 'Nivel Aggressive: /ResetBase sera aplicado. As atualizacoes ja instaladas deixarao de ser desinstalaveis.'
    }

    Write-Log INFO 'Executando a limpeza de componentes. Esta etapa costuma demorar...'
    $cl = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $dism -Arguments $argumentos -TimeoutSeconds 3600
    } -Activity 'DISM StartComponentCleanup'

    $ok = ($cl.Success -and $cl.Value.ExitCode -eq 0)
    [void]$linhas.Add([pscustomobject]@{
        Categoria = 'Componentes'; Tipo = 'DISM'; Alvo = 'StartComponentCleanup'
        Nivel = $(if ($Level -eq 'Aggressive') { 'Aggressive' } else { 'Safe' })
        Resultado = $(if ($ok) { 'Aplicado' } else { 'Falhou' })
        Detalhe = $(if ($ok) { 'Concluido' } else { "Codigo $($cl.Value.ExitCode)" }); Motivo = $obs
    })

    if ($ok) {
        Write-Log OK 'Armazenamento de componentes compactado.'
        Add-DebloatRegistro -Manifesto $Manifesto -Item ([pscustomobject]@{
            Id = 'dism:StartComponentCleanup'; Tipo = 'Componente'; Alvo = 'WinSxS'
            Categoria = 'Componentes'; Nivel = $Level; Reversivel = $false
        }) -Resultado 'Aplicado' -Detalhe $obs
        Add-CompartDiskFinding -Severity OK -Area 'Debloat' -Message 'Armazenamento de componentes compactado.' `
            -Recommendation 'Operacao nao reversivel; o espaco liberado nao volta ao estado anterior.'
    } else {
        Write-Log WARN 'A limpeza de componentes nao concluiu. Verifique se ha reinicio pendente.'
        $script:result = 'WARN'
    }

    Write-Log INFO 'Arquivos temporarios e caches sao tratados pelo modulo Cleanup (menu [4][1]).'
    return @($linhas)
}

function New-DebloatRestorePoint {
    <# Ponto de restauracao do Windows. Trata explicitamente os dois motivos
       classicos de falha: protecao desligada e o intervalo minimo de 24 h. #>
    [CmdletBinding()] param([string]$Descricao = 'COMPARTDISK - antes do Debloat')

    if (-not (Test-CompartDiskCommand 'Checkpoint-Computer')) {
        Write-Log WARN 'Checkpoint-Computer indisponivel nesta edicao do Windows.'
        return $false
    }

    $protegido = $false
    try {
        $rp = Get-CompartDiskCim -Class SystemRestoreConfig -Namespace 'root\default'
        if ($rp) { $protegido = $true }
    } catch { }
    if (-not $protegido) {
        try {
            $d = Get-CompartDiskCim -Query "SELECT * FROM Win32_ShadowCopy" -Namespace 'root\cimv2'
            if ($d) { $protegido = $true }
        } catch { }
    }

    if (Test-CompartDiskCommand 'Enable-ComputerRestore') {
        Invoke-SafeCommand { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } `
            -Activity 'Habilitar protecao do sistema' -Silent | Out-Null
    }

    Write-Log INFO 'Criando ponto de restauracao do sistema...'
    $r = Invoke-SafeCommand {
        Checkpoint-Computer -Description $Descricao -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    } -Activity 'Checkpoint-Computer'

    if ($r.Success) {
        Write-Log OK "Ponto de restauracao criado: $Descricao"
        Add-CompartDiskFinding -Severity OK -Area 'Debloat' -Message 'Ponto de restauracao do sistema criado antes das alteracoes.' `
            -Recommendation 'Recuperavel por: Painel de Controle > Recuperacao > Abrir Restauracao do Sistema.'
        return $true
    }

    $msg = "$($r.Error.Exception.Message)"
    if ($msg -match '(?i)1440|frequen') {
        Write-Log WARN 'O Windows limita a um ponto de restauracao a cada 24 h e ja existe um recente. Ele servira igualmente como ponto de retorno.'
        return $true
    }
    Write-Log WARN "Nao foi possivel criar o ponto de restauracao: $msg"
    Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message 'Ponto de restauracao nao pode ser criado.' `
        -Recommendation 'Habilite a Protecao do Sistema em Sistema > Protecao do Sistema, ou use -SkipRestorePoint por sua conta e risco.'
    return $false
}

function Invoke-DebloatBackup {
    <# Retrato do estado atual dos alvos do catalogo, sem alterar nada. Serve
       como rede independente do manifesto de execucao. #>
    param([Parameter(Mandatory)][object]$Manifesto)

    Write-Log INFO 'Coletando o estado atual de todos os alvos do catalogo...'
    $catalogo = Get-DebloatCatalogo
    $linhas = New-Object System.Collections.ArrayList

    foreach ($i in $catalogo) {
        if (Test-ItemProtegido -Item $i) { continue }
        $r = Invoke-DebloatItem -Item $i -Simular
        if (-not $r.Encontrado) { continue }
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

function Invoke-DebloatRestore {
    <# Reversao a partir do manifesto. Servicos, tarefas e registro voltam ao
       valor exato anterior; aplicativos sao apenas listados, porque o pacote
       original nao fica retido no disco apos a remocao. #>
    param([switch]$Simular)

    $m = Get-DebloatUltimoManifesto -Caminho $ManifestPath
    if (-not $m) {
        Write-Log WARN 'Nenhum manifesto de reversao encontrado. Nada a restaurar.'
        Write-Color ''
        Write-Color "  Os manifestos ficam em: $(Get-DebloatPastaRestauracao)" -Color DarkGray
        $script:result = 'WARN'
        return @()
    }

    Write-Log INFO "Manifesto de $($m.Criado) | acao '$($m.Acao)' | nivel '$($m.Nivel)' | $($m.Itens.Count) registro(s)."
    $linhas = New-Object System.Collections.ArrayList
    $apps = New-Object System.Collections.ArrayList
    $revertidos = 0; $falhas = 0

    foreach ($it in @($m.Itens)) {
        if ($it.Resultado -notin @('Aplicado', 'Backup')) { continue }
        $ant = $it.EstadoAnterior
        if (-not $ant) { continue }

        switch ($it.Tipo) {
            'Service' {
                $destino = "$($ant.StartType)"
                if ($destino -eq 'Auto') { $destino = 'Automatic' }
                if ($destino -notin @('Automatic', 'Manual', 'Disabled')) { continue }
                if ($Simular) {
                    [void]$linhas.Add([pscustomobject]@{ Tipo = 'Servico'; Alvo = $it.Alvo; Acao = "-> $destino"; Resultado = 'Simulado' })
                    continue
                }
                $r = Invoke-SafeCommand { Set-Service -Name $it.Alvo -StartupType $destino -ErrorAction Stop } -Activity "Restaurar $($it.Alvo)" -Silent
                if ($r.Success) {
                    if ("$($ant.Status)" -eq 'Running') { Invoke-SafeCommand { Start-Service -Name $it.Alvo -ErrorAction Stop } -Activity "Iniciar $($it.Alvo)" -Silent | Out-Null }
                    $revertidos++
                    [void]$linhas.Add([pscustomobject]@{ Tipo = 'Servico'; Alvo = $it.Alvo; Acao = "-> $destino"; Resultado = 'Revertido' })
                } else {
                    $falhas++
                    [void]$linhas.Add([pscustomobject]@{ Tipo = 'Servico'; Alvo = $it.Alvo; Acao = "-> $destino"; Resultado = 'Falhou' })
                }
            }
            'Task' {
                if ("$($ant.State)" -eq 'Disabled') { continue }
                $nome = Split-Path $it.Alvo -Leaf
                $cam  = (Split-Path $it.Alvo -Parent) + '\'
                if ($Simular) {
                    [void]$linhas.Add([pscustomobject]@{ Tipo = 'Tarefa'; Alvo = $nome; Acao = '-> Ready'; Resultado = 'Simulado' })
                    continue
                }
                $r = Invoke-SafeCommand { Enable-ScheduledTask -TaskName $nome -TaskPath $cam -ErrorAction Stop | Out-Null } -Activity "Restaurar $nome" -Silent
                if ($r.Success) { $revertidos++; [void]$linhas.Add([pscustomobject]@{ Tipo = 'Tarefa'; Alvo = $nome; Acao = '-> Ready'; Resultado = 'Revertido' }) }
                else            { $falhas++;     [void]$linhas.Add([pscustomobject]@{ Tipo = 'Tarefa'; Alvo = $nome; Acao = '-> Ready'; Resultado = 'Falhou' }) }
            }
            'Registry' {
                $partes  = $it.Alvo -split '\\'
                $valNome = $partes[-1]
                $caminho = ($partes[0..($partes.Count - 2)]) -join '\'
                if ($Simular) {
                    $alvoTxt = $(if ($ant.Existia) { "-> $($ant.Valor)" } else { '-> remover valor' })
                    [void]$linhas.Add([pscustomobject]@{ Tipo = 'Registro'; Alvo = $it.Alvo; Acao = $alvoTxt; Resultado = 'Simulado' })
                    continue
                }
                if ($ant.Existia) {
                    if (Set-CompartDiskRegistryValue -Path $caminho -Name $valNome -Value $ant.Valor -Type $ant.Tipo) {
                        $revertidos++; [void]$linhas.Add([pscustomobject]@{ Tipo = 'Registro'; Alvo = $it.Alvo; Acao = "-> $($ant.Valor)"; Resultado = 'Revertido' })
                    } else {
                        $falhas++; [void]$linhas.Add([pscustomobject]@{ Tipo = 'Registro'; Alvo = $it.Alvo; Acao = "-> $($ant.Valor)"; Resultado = 'Falhou' })
                    }
                } else {
                    # O valor nao existia: devolver ao estado anterior e remove-lo,
                    # e nao gravar zero, que seria uma configuracao nova.
                    $r = Invoke-SafeCommand { Remove-ItemProperty -LiteralPath $caminho -Name $valNome -Force -ErrorAction Stop } -Activity "Remover $valNome" -Silent
                    if ($r.Success) { $revertidos++; [void]$linhas.Add([pscustomobject]@{ Tipo = 'Registro'; Alvo = $it.Alvo; Acao = '-> removido'; Resultado = 'Revertido' }) }
                    else            { $falhas++;     [void]$linhas.Add([pscustomobject]@{ Tipo = 'Registro'; Alvo = $it.Alvo; Acao = '-> removido'; Resultado = 'Falhou' }) }
                }
            }
            'Appx' {
                [void]$apps.Add([pscustomobject]@{ Aplicativo = $it.Alvo; Versao = "$($ant.Versao)"; Reinstalacao = 'Microsoft Store' })
            }
        }
    }

    Write-Color ''
    if ($linhas.Count -gt 0) {
        $linhas | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
        Add-CompartDiskSection -Title 'Reversao de alteracoes' -Status OK -Rows @($linhas) `
            -Summary "$revertidos revertido(s), $falhas falha(s)"
    }

    if ($apps.Count -gt 0) {
        Write-Color ''
        Write-Color '  APLICATIVOS REMOVIDOS - reinstalacao manual' -Color Yellow
        Write-Color '  A remocao de Appx nao guarda o pacote original no disco. Estes precisam' -Color DarkGray
        Write-Color '  ser reinstalados pela Microsoft Store:' -Color DarkGray
        Write-Color ''
        $apps | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
        Add-CompartDiskSection -Title 'Aplicativos a reinstalar pela loja' -Status WARN -Rows @($apps) `
            -Summary "$($apps.Count) aplicativo(s)"
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message "$($apps.Count) aplicativo(s) removido(s) exigem reinstalacao pela Microsoft Store." `
            -Recommendation 'A remocao de aplicativos da loja nao e reversivel localmente.'
    }

    if ($falhas -gt 0) { $script:result = 'WARN' }
    Write-Log OK "Reversao concluida: $revertidos item(ns) restaurado(s), $falhas falha(s), $($apps.Count) aplicativo(s) apenas listado(s)."
    return @($linhas)
}

# ==============================================================================
# 7. RELATORIO
# ==============================================================================

function Write-DebloatResumo {
    param([object[]]$Linhas, [string]$Titulo, [switch]$Simulacao)

    if (-not $Linhas -or $Linhas.Count -eq 0) { return }

    $aplicados = @($Linhas | Where-Object { $_.Resultado -eq 'Aplicado' }).Count
    $simulados = @($Linhas | Where-Object { $_.Resultado -eq 'Simulado' }).Count
    $jaOk      = @($Linhas | Where-Object { $_.Resultado -eq 'JaAplicado' }).Count
    $protegidos= @($Linhas | Where-Object { $_.Resultado -eq 'Protegido' }).Count
    $falhas    = @($Linhas | Where-Object { $_.Resultado -eq 'Falhou' }).Count

    Write-Color ''
    Write-Color "  $Titulo" -Color White
    if ($Simulacao) {
        Write-Color ("    {0} : {1}" -f 'Alteracoes previstas'.PadRight(26), $simulados) -Color Cyan
    } else {
        Write-Color ("    {0} : {1}" -f 'Alteracoes aplicadas'.PadRight(26), $aplicados) -Color $(if ($aplicados -gt 0) { 'Green' } else { 'DarkGray' })
    }
    Write-Color ("    {0} : {1}" -f 'Ja no estado desejado'.PadRight(26), $jaOk) -Color DarkGray
    if ($protegidos -gt 0) { Write-Color ("    {0} : {1}" -f 'Bloqueados por protecao'.PadRight(26), $protegidos) -Color Yellow }
    if ($falhas -gt 0)     { Write-Color ("    {0} : {1}" -f 'Falhas'.PadRight(26), $falhas) -Color Red }

    $porCategoria = $Linhas | Group-Object Categoria | ForEach-Object {
        [pscustomobject]@{
            Categoria = $_.Name
            Total     = $_.Count
            Aplicados = @($_.Group | Where-Object { $_.Resultado -in @('Aplicado', 'Simulado') }).Count
            JaOk      = @($_.Group | Where-Object { $_.Resultado -eq 'JaAplicado' }).Count
            Falhas    = @($_.Group | Where-Object { $_.Resultado -eq 'Falhou' }).Count
        }
    }
    Write-Color ''
    $porCategoria | Format-Table -AutoSize | Out-String -Width 160 | Write-Output

    $status = if ($falhas -gt 0) { 'WARN' } else { 'OK' }
    Add-CompartDiskSection -Title $Titulo -Status $status -Rows @($Linhas) `
        -Summary ("Nivel {0} | aplicadas {1} | simuladas {2} | ja conformes {3} | falhas {4}" -f $Level, $aplicados, $simulados, $jaOk, $falhas)

    if ($falhas -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Debloat' -Message "$falhas alteracao(oes) nao pode(m) ser aplicada(s)." `
            -Recommendation 'Verificar reinicio pendente ou politica corporativa que bloqueie a alteracao.'
        $script:result = 'WARN'
    }
    if ($aplicados -gt 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Debloat' -Message "$aplicados alteracao(oes) aplicada(s) no nivel $Level." `
            -Recommendation 'Reversivel pela acao Restore deste modulo, exceto a remocao de aplicativos.'
    }
    if ($simulados -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Debloat' -Message "$simulados alteracao(oes) identificada(s) em simulacao, nenhuma aplicada." `
            -Recommendation 'Executar a acao correspondente sem -DryRun para aplicar.'
    }
}

# ==============================================================================
# 8. DESPACHO
# ==============================================================================
try {
    $precisaAdmin = @('Apps', 'Services', 'Tasks', 'Privacy', 'Tweaks', 'Components', 'Full', 'Restore', 'RestorePoint') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Debloat' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    $simular = ($DryRun -or $Action -eq 'Analyze')
    $manifesto = New-DebloatManifesto -Acao $Action -NivelUsado $Level

    # --- Validacao previa: vale para toda acao que altera o sistema
    if ($Action -notin @('Analyze', 'Backup')) {
        $pre = Test-DebloatPreconditions
        foreach ($a in $pre.Avisos) { Write-Log WARN $a }
        if (-not $pre.Ok) {
            foreach ($i in $pre.Impeditivos) { Write-Log ERR $i }
            Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Pre-requisitos nao atendidos; nenhuma alteracao foi feita.' `
                -Recommendation ($pre.Impeditivos -join ' | ')
            $result = 'ERROR'
            # 'return' e nao 'exit': 'exit' dentro do try dispara o finally, que chama
            # Stop-CompartDiskModule de novo e duplica a linha de encerramento no log
            # justamente num caminho de erro. O codigo de saida final e o mesmo.
            return
        }
    }

    switch ($Action) {

        'Analyze' {
            Write-Log INFO 'Simulacao completa. Nenhuma alteracao sera feita no sistema.'
            $todas = @('Aplicativos', 'Servicos', 'Tarefas', 'Privacidade', 'Ajustes')
            $l = Invoke-DebloatCategorias -Categorias $todas -Manifesto $manifesto -Simular
            Write-DebloatResumo -Linhas $l -Titulo 'Simulacao de Debloat' -Simulacao
            Write-Color ''
            Write-Color '  Nada foi alterado. Para aplicar, use a acao correspondente no menu.' -Color Cyan
        }

        'Apps'       { $l = Invoke-DebloatCategorias -Categorias @('Aplicativos') -Manifesto $manifesto -Simular:$simular
                       Write-DebloatResumo -Linhas $l -Titulo 'Remocao de aplicativos' -Simulacao:$simular }

        'Services'   { $l = Invoke-DebloatCategorias -Categorias @('Servicos') -Manifesto $manifesto -Simular:$simular
                       Write-DebloatResumo -Linhas $l -Titulo 'Gerenciamento de servicos' -Simulacao:$simular }

        'Tasks'      { $l = Invoke-DebloatCategorias -Categorias @('Tarefas') -Manifesto $manifesto -Simular:$simular
                       Write-DebloatResumo -Linhas $l -Titulo 'Gerenciamento de tarefas agendadas' -Simulacao:$simular }

        'Privacy'    { $l = Invoke-DebloatCategorias -Categorias @('Privacidade') -Manifesto $manifesto -Simular:$simular
                       Write-DebloatResumo -Linhas $l -Titulo 'Ajustes de privacidade' -Simulacao:$simular
                       Write-Log INFO 'A telemetria propriamente dita e tratada pelo modulo Telemetry (menu [4][2]).' }

        'Tweaks'     { $l = Invoke-DebloatCategorias -Categorias @('Ajustes') -Manifesto $manifesto -Simular:$simular
                       Write-DebloatResumo -Linhas $l -Titulo 'Ajustes opcionais do Windows' -Simulacao:$simular }

        'Components' { $l = Invoke-DebloatComponentes -Manifesto $manifesto -Simular:$simular
                       Add-CompartDiskSection -Title 'Limpeza de componentes' -Status OK -Rows @($l) `
                            -Summary 'Armazenamento de componentes (WinSxS)' }

        'Backup'     { Invoke-DebloatBackup -Manifesto $manifesto | Out-Null }

        'Restore'    { Invoke-DebloatRestore -Simular:$DryRun | Out-Null }

        'RestorePoint' {
            if (-not (New-DebloatRestorePoint)) {
                $result = 'WARN'
            }
        }

        'Full' {
            Write-Log INFO "Rotina completa de Debloat no nivel $Level$(if ($simular) { ' (SIMULACAO)' } else { '' })."

            if (-not $simular) {
                if ($SkipRestorePoint) {
                    Write-Log WARN 'Ponto de restauracao ignorado por parametro (-SkipRestorePoint).'
                } elseif (-not (New-DebloatRestorePoint)) {
                    Write-Log ERR 'Rotina interrompida: sem ponto de restauracao nao ha rede de seguranca.'
                    Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message 'Rotina completa interrompida por ausencia de ponto de restauracao.' `
                        -Recommendation 'Habilitar a Protecao do Sistema, ou reexecutar com -SkipRestorePoint assumindo o risco.'
                    $result = 'ERROR'
                    return
                }
                Invoke-DebloatBackup -Manifesto $manifesto | Out-Null
                Write-Color ''
            }

            $todas = @('Aplicativos', 'Servicos', 'Tarefas', 'Privacidade', 'Ajustes')
            $l = Invoke-DebloatCategorias -Categorias $todas -Manifesto $manifesto -Simular:$simular
            $lc = Invoke-DebloatComponentes -Manifesto $manifesto -Simular:$simular
            Write-DebloatResumo -Linhas (@($l) + @($lc)) -Titulo 'Debloat completo' -Simulacao:$simular

            if (-not $simular) {
                Write-Color ''
                Write-Color '  Reinicie o computador para consolidar as alteracoes de servico e componente.' -Color Yellow
            }
        }
    }

    if ($Action -notin @('Analyze', 'Restore') -and -not $simular) {
        Save-DebloatManifesto -Manifesto $manifesto | Out-Null
    }

} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Debloat (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Debloat' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
