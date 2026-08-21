<#
 COMPARTDISK 1.4.6 - Apps.ps1
 Desenvolvido por Edsilas
 Instalacao de aplicativos de suporte tecnico pelo gerenciador de pacotes do
 Windows (winget), a partir de um catalogo declarativo.
 Acoes: Menu | Install | InstallCategory | InstallAll | List | Central

 ESCOPO DESTE MODULO: instalar o que esta AUSENTE.
 A ATUALIZACAO de programas continua sendo a rotina :MOD_WINGET do Launcher.bat,
 acessivel pela opcao [3] do menu APLICATIVOS. Ela nao e reimplementada aqui:
 uma capacidade, um dono. Este modulo nunca chama "winget upgrade".

 CATALOGO: todos os identificadores foram conferidos em 14/08/2026 contra o
 indice oficial da fonte "winget" (cdn.winget.microsoft.com/cache/source2.msix)
 e contra os manifestos publicados em microsoft/winget-pkgs. Nenhum ID foi
 inferido, e nenhum aplicativo sem pacote oficial recebeu URL substituta.
 Os identificadores de TeamViewer, 7-Zip e Rufus foram conferidos em 15/08/2026
 contra os manifestos publicados em microsoft/winget-pkgs.

 Antes de instalar, Get-WingetPackage confirma o ID na fonte oficial: um ID que
 nao exista mais e reportado como NAO ENCONTRADO, nunca substituido por outro.

 A interacao deste modulo e NUMERICA. Escolher, confirmar e cancelar sao sempre
 numeros. Duas excecoes, as duas na Central de Aplicativos: o nome procurado, que
 e texto e nao escolha de menu (higienizado, nunca vira comando), e a navegacao
 das telas da Central - [P] nova pesquisa e [V] voltar, em todas elas -, com
 tecla fixa porque a quantidade de resultados muda a cada pesquisa e um numero de
 navegacao mudava de lugar junto.

 CENTRAL DE APLICATIVOS (acao Central): pesquisa pelo nome na fonte oficial do
 winget, classifica por relevancia e instala pelo ID exato. E um caminho a mais
 para chegar a uma instalacao - o catalogo declarativo acima continua sendo o
 conjunto curado de ferramentas de suporte tecnico, sem nenhuma alteracao.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Install', 'InstallCategory', 'InstallAll', 'List', 'Central')]
    [string]$Action = 'Menu',
    [string]$Id = '',
    [string]$Category = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

# ------------------------------------------------------------------------------
# CATALOGO DECLARATIVO
# ------------------------------------------------------------------------------
# Incluir um aplicativo novo = acrescentar uma entrada aqui. Os menus, o lote, a
# instalacao total e a verificacao de instalados sao TODOS derivados desta lista;
# nenhum deles conhece nome ou ID de aplicativo.
#
# Campos:
#   Name        rotulo exibido
#   Id          identificador exato no winget ('' quando nao ha pacote valido)
#   Category    categoria do menu (a ordem das categorias vem de $CategoriasOrdem)
#   Description descricao curta exibida no catalogo
#   Native      $true  = recurso ja presente no Windows, nada a instalar
#   Available   $false = sem pacote valido na fonte oficial do winget
#   Publisher   editor conforme o manifesto oficial
#   PackageType tipo de instalador declarado no manifesto
#   Scope       escopo declarado no manifesto (machine/user/portable)
#   Architecture arquiteturas publicadas
#   SuiteId     pacote que ja contem esta ferramenta (evita download redundante)
#   Note        observacao exibida quando Native ou nao disponivel
# ------------------------------------------------------------------------------
$script:CategoriasOrdem = @(
    'Hardware',
    'Windows / Sistema',
    'Rede',
    'Acesso Remoto',
    'Produtividade',
    'Utilitarios'
)

$script:Catalogo = @(
    # --- Hardware ---------------------------------------------------------
    [pscustomobject]@{ Name = 'HWiNFO'; Id = 'REALiX.HWiNFO'; Category = 'Hardware'
        Description = 'Diagnostico e inventario detalhado de hardware'
        Native = $false; Available = $true; Publisher = 'REALiX'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x64, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'CPU-Z'; Id = 'CPUID.CPU-Z'; Category = 'Hardware'
        Description = 'Identificacao de processador, placa-mae e memoria'
        Native = $false; Available = $true; Publisher = 'CPUID'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x64, x86'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'GPU-Z'; Id = 'TechPowerUp.GPU-Z'; Category = 'Hardware'
        Description = 'Identificacao e monitoramento de placa de video'
        Native = $false; Available = $true; Publisher = 'TechPowerUp'; PackageType = 'exe'
        Scope = 'machine'; Architecture = 'x86'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'CrystalDiskInfo'; Id = 'CrystalDewWorld.CrystalDiskInfo'; Category = 'Hardware'
        Description = 'Leitura da saude SMART de discos e SSDs'
        Native = $false; Available = $true; Publisher = 'CrystalDewWorld'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'CrystalDiskMark'; Id = 'CrystalDewWorld.CrystalDiskMark'; Category = 'Hardware'
        Description = 'Teste de desempenho de leitura e escrita em disco'
        Native = $false; Available = $true; Publisher = 'CrystalDewWorld'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'OCCT'; Id = 'OCBase.OCCT.Personal'; Category = 'Hardware'
        Description = 'Teste de estabilidade de processador, memoria e fonte'
        Native = $false; Available = $true; Publisher = 'OCBase'; PackageType = 'portable'
        Scope = 'user'; Architecture = 'x64'; SuiteId = $null; Note = '' }

    # --- Windows / Sistema ------------------------------------------------
    [pscustomobject]@{ Name = 'Sysinternals Suite'; Id = 'Microsoft.Sysinternals.Suite'; Category = 'Windows / Sistema'
        Description = 'Conjunto completo de utilitarios Sysinternals da Microsoft'
        Native = $false; Available = $true; Publisher = 'Microsoft'; PackageType = 'zip (portable)'
        Scope = 'user'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'Process Explorer'; Id = 'Microsoft.Sysinternals.ProcessExplorer'; Category = 'Windows / Sistema'
        Description = 'Gerenciador de processos avancado (tambem incluso na Suite)'
        Native = $false; Available = $true; Publisher = 'Microsoft'; PackageType = 'zip (portable)'
        Scope = 'user'; Architecture = 'x64, x86, arm64'; SuiteId = 'Microsoft.Sysinternals.Suite'; Note = '' }

    [pscustomobject]@{ Name = 'Process Monitor'; Id = 'Microsoft.Sysinternals.ProcessMonitor'; Category = 'Windows / Sistema'
        Description = 'Monitor de arquivo, registro, processo e rede (tambem na Suite)'
        Native = $false; Available = $true; Publisher = 'Microsoft'; PackageType = 'zip (portable)'
        Scope = 'user'; Architecture = 'x64, x86, arm64'; SuiteId = 'Microsoft.Sysinternals.Suite'; Note = '' }

    [pscustomobject]@{ Name = 'Autoruns'; Id = 'Microsoft.Sysinternals.Autoruns'; Category = 'Windows / Sistema'
        Description = 'Inventario completo de itens de inicializacao (tambem na Suite)'
        Native = $false; Available = $true; Publisher = 'Microsoft'; PackageType = 'zip (portable)'
        Scope = 'user'; Architecture = 'x64, x86, arm64'; SuiteId = 'Microsoft.Sysinternals.Suite'; Note = '' }

    [pscustomobject]@{ Name = 'TCPView'; Id = 'Microsoft.Sysinternals.TCPView'; Category = 'Windows / Sistema'
        Description = 'Conexoes TCP e UDP por processo (tambem na Suite)'
        Native = $false; Available = $true; Publisher = 'Microsoft'; PackageType = 'zip (portable)'
        Scope = 'user'; Architecture = 'x64, x86, arm64'; SuiteId = 'Microsoft.Sysinternals.Suite'; Note = '' }

    [pscustomobject]@{ Name = 'RAMMap'; Id = 'Microsoft.Sysinternals.RAMMap'; Category = 'Windows / Sistema'
        Description = 'Analise detalhada do uso de memoria fisica (tambem na Suite)'
        Native = $false; Available = $true; Publisher = 'Microsoft'; PackageType = 'zip (portable)'
        Scope = 'user'; Architecture = 'x64, x86, arm64'; SuiteId = 'Microsoft.Sysinternals.Suite'; Note = '' }

    [pscustomobject]@{ Name = 'WizTree'; Id = 'AntibodySoftware.WizTree'; Category = 'Windows / Sistema'
        Description = 'Mapa de ocupacao de disco por leitura direta da MFT'
        Native = $false; Available = $true; Publisher = 'AntibodySoftware'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x64, x86'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'Everything'; Id = 'voidtools.Everything'; Category = 'Windows / Sistema'
        Description = 'Busca instantanea de arquivos e pastas por nome'
        Native = $false; Available = $true; Publisher = 'voidtools'; PackageType = 'nullsoft'
        Scope = 'machine'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'Notepad++'; Id = 'Notepad++.Notepad++'; Category = 'Windows / Sistema'
        Description = 'Editor de texto e codigo. Nao substitui o Bloco de Notas do Windows'
        Native = $false; Available = $true; Publisher = 'Notepad++'; PackageType = 'nullsoft'
        Scope = 'machine'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    # --- Rede -------------------------------------------------------------
    [pscustomobject]@{ Name = 'Wireshark'; Id = 'WiresharkFoundation.Wireshark'; Category = 'Rede'
        Description = 'Captura e analise de trafego de rede'
        Native = $false; Available = $true; Publisher = 'WiresharkFoundation'; PackageType = 'nullsoft'
        Scope = 'machine'; Architecture = 'x64, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'Nmap'; Id = 'Insecure.Nmap'; Category = 'Rede'
        Description = 'Varredura de portas e descoberta de servicos'
        Native = $false; Available = $true; Publisher = 'Insecure'; PackageType = 'nullsoft'
        Scope = 'user'; Architecture = 'x86'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'Advanced IP Scanner'; Id = 'Famatech.AdvancedIPScanner'; Category = 'Rede'
        Description = 'Descoberta de dispositivos na rede local'
        Native = $false; Available = $true; Publisher = 'Famatech'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x86'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'iperf3'; Id = 'ar51an.iPerf3'; Category = 'Rede'
        Description = 'Medicao de vazao entre dois pontos da rede'
        Native = $false; Available = $true; Publisher = 'ar51an'; PackageType = 'zip (portable)'
        Scope = 'user'; Architecture = 'x64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'PuTTY'; Id = 'PuTTY.PuTTY'; Category = 'Rede'
        Description = 'Cliente SSH, Telnet e serial'
        Native = $false; Available = $true; Publisher = 'PuTTY'; PackageType = 'wix'
        Scope = 'machine'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'WinSCP'; Id = 'WinSCP.WinSCP'; Category = 'Rede'
        Description = 'Transferencia de arquivos por SFTP, SCP e FTP'
        Native = $false; Available = $true; Publisher = 'WinSCP'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x86'; SuiteId = $null; Note = '' }

    # --- Acesso Remoto ----------------------------------------------------
    [pscustomobject]@{ Name = 'TeamViewer'; Id = 'TeamViewer.TeamViewer'; Category = 'Acesso Remoto'
        Description = 'Acesso remoto e suporte tecnico a distancia'
        Native = $false; Available = $true; Publisher = 'TeamViewer'; PackageType = 'nullsoft'
        Scope = 'machine'; Architecture = 'x64, x86'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'AnyDesk'; Id = 'AnyDesk.AnyDesk'; Category = 'Acesso Remoto'
        Description = 'Acesso remoto assistido'
        Native = $false; Available = $true; Publisher = 'AnyDesk'; PackageType = 'exe'
        Scope = 'machine'; Architecture = 'x86'; SuiteId = $null
        Note = 'O instalador exige elevacao (ElevationRequirement: elevationRequired no manifesto oficial).' }

    # --- Produtividade ----------------------------------------------------
    [pscustomobject]@{ Name = 'ONLYOFFICE Desktop Editors'; Id = 'ONLYOFFICE.DesktopEditors'; Category = 'Produtividade'
        Description = 'Suite de escritorio compativel com os formatos do Office'
        Native = $false; Available = $true; Publisher = 'ONLYOFFICE'; PackageType = 'inno'
        Scope = 'machine'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'Google Chrome'; Id = 'Google.Chrome'; Category = 'Produtividade'
        Description = 'Navegador Google Chrome. Nao altera o navegador padrao do sistema'
        Native = $false; Available = $true; Publisher = 'Google'; PackageType = 'wix'
        Scope = 'machine'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }

    # --- Utilitarios ------------------------------------------------------
    # Nenhum aplicativo foi movido das categorias acima para ca: mover mudaria a
    # posicao de opcoes ja conhecidas.
    [pscustomobject]@{ Name = '7-Zip'; Id = '7zip.7zip'; Category = 'Utilitarios'
        Description = 'Compactacao e extracao de arquivos 7z, zip, rar e outros'
        Native = $false; Available = $true; Publisher = '7zip'; PackageType = 'exe, wix'
        Scope = 'machine'; Architecture = 'x64, x86, arm64, arm'; SuiteId = $null; Note = '' }

    [pscustomobject]@{ Name = 'Rufus'; Id = 'Rufus.Rufus'; Category = 'Utilitarios'
        Description = 'Criacao de midia USB inicializavel a partir de imagem ISO'
        Native = $false; Available = $true; Publisher = 'Rufus'; PackageType = 'portable'
        Scope = 'user'; Architecture = 'x64, x86, arm64'; SuiteId = $null; Note = '' }
)

# ------------------------------------------------------------------------------
# CENTRAL DE APLICATIVOS - catalogo de apelidos
# ------------------------------------------------------------------------------
# Tabela declarativa. Incluir um aplicativo popular = acrescentar uma entrada;
# nenhuma funcao precisa mudar.
#
# Esta tabela NAO e uma fonte de pacotes. Ela faz duas coisas, e so estas duas:
#   1. traduz o que o operador digitou ("crome") para o texto que a fonte oficial
#      reconhece ("Google Chrome");
#   2. da preferencia ao pacote esperado quando o winget devolve varios parecidos.
#
# Tudo o que aparece na tela e tudo o que e instalado vem do proprio winget. Um
# identificador que saia do ar aqui degrada para a pesquisa normal: nunca instala
# pacote errado e nunca oferece item que a fonte oficial deixou de confirmar.
#
# Um termo generico ("office", "navegador") aceita mais de uma resposta legitima:
# por isso a entrada declara uma LISTA de identificadores, em ordem de preferencia.
#
# Campos:
#   Ids     identificadores esperados na fonte oficial, do mais provavel para o
#           menos (dica de relevancia: o primeiro pesa mais, e so ele e sondado
#           quando a pesquisa por nome nao o traz)
#   Nome    texto de consulta quando o termo digitado nao encontra nada
#   Termos  apelidos, abreviacoes e erros de digitacao comuns (comparados
#           normalizados: maiusculas, acentos, espacos e hifens sao ignorados)
# ------------------------------------------------------------------------------
$script:ApelidosCentral = @(
    [pscustomobject]@{ Ids = @('Google.Chrome'); Nome = 'Google Chrome'
        Termos = @('chrome', 'crome', 'chorme', 'chrom', 'chr', 'google chrome', 'navegador chrome') }

    [pscustomobject]@{ Ids = @('Mozilla.Firefox'); Nome = 'Mozilla Firefox'
        Termos = @('firefox', 'fire fox', 'firefx', 'mozilla') }

    [pscustomobject]@{ Ids = @('Brave.Brave'); Nome = 'Brave Browser'
        Termos = @('brave', 'brave browser') }

    [pscustomobject]@{ Ids = @('Opera.Opera'); Nome = 'Opera Browser'
        Termos = @('opera') }

    [pscustomobject]@{ Ids = @('7zip.7zip'); Nome = '7-Zip'
        Termos = @('7zip', '7 zip', 'seven zip', 'sevenzip', 'zip') }

    [pscustomobject]@{ Ids = @('RARLab.WinRAR'); Nome = 'WinRAR'
        Termos = @('winrar', 'win rar', 'rar') }

    [pscustomobject]@{ Ids = @('VideoLAN.VLC'); Nome = 'VLC media player'
        Termos = @('vlc', 'videolan', 'vlc player', 'vlc media player') }

    [pscustomobject]@{ Ids = @('Microsoft.VisualStudioCode'); Nome = 'Visual Studio Code'
        Termos = @('vscode', 'vs code', 'code', 'visual code', 'visual studio code') }

    [pscustomobject]@{ Ids = @('Notepad++.Notepad++'); Nome = 'Notepad++'
        Termos = @('notepad', 'notepad++', 'note pad', 'npp') }

    [pscustomobject]@{ Ids = @('Adobe.Acrobat.Reader.64-bit'); Nome = 'Adobe Acrobat Reader'
        Termos = @('adobe reader', 'acrobat', 'adobe acrobat', 'acrobat reader', 'leitor de pdf') }

    [pscustomobject]@{ Ids = @('Microsoft.PowerToys'); Nome = 'Microsoft PowerToys'
        Termos = @('powertoys', 'power toys') }

    [pscustomobject]@{ Ids = @('voidtools.Everything'); Nome = 'Everything'
        Termos = @('everything', 'voidtools') }

    [pscustomobject]@{ Ids = @('Valve.Steam'); Nome = 'Steam'
        Termos = @('steam') }

    [pscustomobject]@{ Ids = @('Discord.Discord'); Nome = 'Discord'
        Termos = @('discord') }

    [pscustomobject]@{ Ids = @('Spotify.Spotify'); Nome = 'Spotify'
        Termos = @('spotify') }

    [pscustomobject]@{ Ids = @('Zoom.Zoom'); Nome = 'Zoom Workplace'
        Termos = @('zoom') }

    [pscustomobject]@{ Ids = @('Telegram.TelegramDesktop'); Nome = 'Telegram Desktop'
        Termos = @('telegram') }

    [pscustomobject]@{ Ids = @('Microsoft.Teams'); Nome = 'Microsoft Teams'
        Termos = @('teams', 'microsoft teams') }

    [pscustomobject]@{ Ids = @('AnyDesk.AnyDesk'); Nome = 'AnyDesk'
        Termos = @('anydesk', 'any desk') }

    [pscustomobject]@{ Ids = @('TeamViewer.TeamViewer'); Nome = 'TeamViewer'
        Termos = @('teamviewer', 'team viewer') }

    [pscustomobject]@{ Ids = @('Git.Git'); Nome = 'Git'
        Termos = @('git') }

    [pscustomobject]@{ Ids = @('OpenJS.NodeJS'); Nome = 'Node.js'
        Termos = @('nodejs', 'node js', 'node') }

    [pscustomobject]@{ Ids = @('TheDocumentFoundation.LibreOffice'); Nome = 'LibreOffice'
        Termos = @('libreoffice', 'libre office') }

    [pscustomobject]@{ Ids = @('OBSProject.OBSStudio'); Nome = 'OBS Studio'
        Termos = @('obs', 'obs studio') }

    [pscustomobject]@{ Ids = @('GIMP.GIMP'); Nome = 'GIMP'
        Termos = @('gimp') }

    [pscustomobject]@{ Ids = @('Audacity.Audacity'); Nome = 'Audacity'
        Termos = @('audacity') }

    [pscustomobject]@{ Ids = @('qBittorrent.qBittorrent'); Nome = 'qBittorrent'
        Termos = @('qbittorrent', 'qbit') }

    [pscustomobject]@{ Ids = @('HandBrake.HandBrake'); Nome = 'HandBrake'
        Termos = @('handbrake', 'hand brake') }

    [pscustomobject]@{ Ids = @('Mozilla.Thunderbird'); Nome = 'Mozilla Thunderbird'
        Termos = @('thunderbird') }

    [pscustomobject]@{ Ids = @('Dropbox.Dropbox'); Nome = 'Dropbox'
        Termos = @('dropbox') }

    [pscustomobject]@{ Ids = @('Malwarebytes.Malwarebytes'); Nome = 'Malwarebytes'
        Termos = @('malwarebytes', 'malware bytes') }

    [pscustomobject]@{ Ids = @('Rufus.Rufus'); Nome = 'Rufus'
        Termos = @('rufus') }

    [pscustomobject]@{ Ids = @('PuTTY.PuTTY'); Nome = 'PuTTY'
        Termos = @('putty') }

    [pscustomobject]@{ Ids = @('WinSCP.WinSCP'); Nome = 'WinSCP'
        Termos = @('winscp', 'win scp') }

    [pscustomobject]@{ Ids = @('WiresharkFoundation.Wireshark'); Nome = 'Wireshark'
        Termos = @('wireshark', 'wire shark') }

    [pscustomobject]@{ Ids = @('REALiX.HWiNFO'); Nome = 'HWiNFO'
        Termos = @('hwinfo', 'hw info') }

    [pscustomobject]@{ Ids = @('CPUID.CPU-Z'); Nome = 'CPU-Z'
        Termos = @('cpuz', 'cpu z') }

    [pscustomobject]@{ Ids = @('CrystalDewWorld.CrystalDiskInfo'); Nome = 'CrystalDiskInfo'
        Termos = @('crystaldiskinfo', 'crystal disk info', 'crystal disk') }
    # --- termos genericos -----------------------------------------------------
    # Ficam por ULTIMO de proposito: em empate de nivel, o apelido de um produto
    # especifico vence o generico. Aqui a lista de identificadores importa - sao
    # respostas legitimas diferentes para o mesmo pedido.
    [pscustomobject]@{ Ids = @('Microsoft.Office', 'TheDocumentFoundation.LibreOffice', 'ONLYOFFICE.DesktopEditors'); Nome = 'Microsoft 365'
        Termos = @('office', 'microsoft office', 'ms office', 'pacote office', 'office 365', 'microsoft 365',
                   'word', 'excel', 'powerpoint', 'planilha', 'editor de planilha') }

    [pscustomobject]@{ Ids = @('Google.Chrome', 'Mozilla.Firefox', 'Brave.Brave'); Nome = 'Google Chrome'
        Termos = @('navegador', 'navegador de internet', 'browser', 'web browser', 'internet') }

    [pscustomobject]@{ Ids = @('AnyDesk.AnyDesk', 'TeamViewer.TeamViewer'); Nome = 'AnyDesk'
        Termos = @('acesso remoto', 'area de trabalho remota', 'suporte remoto', 'remoto') }
)

# ------------------------------------------------------------------------------
# Estado de sessao (cache) - evita repetir consultas caras no mesmo lote
# ------------------------------------------------------------------------------
# Rotulos que o proprio winget publica no NOME do pacote. Nao servem para
# esconder nada: apenas evitam que um canal secundario ou uma versao de
# terceiro passe na frente da principal. Sao comparados PALAVRA a palavra, para
# que "Betaflight" nunca seja confundido com "Beta".
$script:CentralRotulosSecundarios = @('beta', 'alpha', 'dev', 'nightly', 'canary', 'insider', 'insiders',
                                      'preview', 'prerelease', 'unstable', 'snapshot', 'rc')
$script:CentralRotulosNaoOficiais = @('unofficial')

$script:WingetCtx    = $null
$script:CachePacote  = @{}
$script:CacheInternet = $null
$script:Registros    = New-Object System.Collections.ArrayList

# ------------------------------------------------------------------------------
# CAMADA WINGET
# ------------------------------------------------------------------------------
function Get-WingetContexto {
    <# Disponibilidade, caminho e versao do winget. Reaproveita Test-Winget do
       Core.ps1 - a deteccao de capacidade tem um unico dono. #>
    [CmdletBinding()] param()
    if ($script:WingetCtx) { return $script:WingetCtx }

    $w   = Test-Winget
    $ver = $null
    if ($w.Version) {
        $m = [regex]::Match([string]$w.Version, '(\d+)\.(\d+)(\.\d+)*')
        if ($m.Success) { try { $ver = [version]$m.Value } catch { $ver = $null } }
    }

    $script:WingetCtx = [pscustomobject]@{
        Available   = [bool]$w.Available
        Path        = $w.Path
        VersionText = $w.Version
        Version     = $ver
        # --disable-interactivity so existe a partir do winget 1.4. Passa-lo a uma
        # versao anterior faz o proprio winget recusar a linha de comando inteira.
        SemInteracao = ($null -ne $ver -and $ver -ge [version]'1.4')
        SourceOk    = $null
    }
    return $script:WingetCtx
}

function Get-WingetArgsComuns {
    <# Argumentos aplicados a toda invocacao: nunca perguntam nada ao operador e
       nunca aceitam contrato de pacote em nome dele sem que ele tenha escolhido
       instalar (estes aceites valem para a fonte e para o pacote escolhido). #>
    [CmdletBinding()] param()
    $ctx  = Get-WingetContexto
    $argumentos = @('--accept-source-agreements')
    if ($ctx.SemInteracao) { $argumentos += '--disable-interactivity' }
    return $argumentos
}

function Invoke-WingetComando {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )
    $ctx = Get-WingetContexto
    if (-not $ctx.Available) {
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'winget indisponivel'; Success = $false }
    }
    try {
        return Invoke-NativeCommand -FilePath $ctx.Path -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    } catch {
        Write-Log DEBUG ("Falha ao invocar winget ({0}): {1}" -f ($Arguments -join ' '), $_.Exception.Message) -NoConsole
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message; Success = $false }
    }
}

function Test-WingetFonte {
    <# A fonte oficial precisa existir para que qualquer ID seja resolvivel.
       Nao adiciona, nao remove e nao repara fontes: apenas verifica. #>
    [CmdletBinding()] param()
    $ctx = Get-WingetContexto
    if (-not $ctx.Available) { return $false }
    if ($null -ne $ctx.SourceOk) { return $ctx.SourceOk }

    $r  = Invoke-WingetComando -Arguments (@('source', 'list') + (Get-WingetArgsComuns)) -TimeoutSeconds 60
    $ok = ($r.ExitCode -eq 0 -and $r.StdOut -match '(?im)^\s*winget\s')
    $ctx.SourceOk = $ok
    if (-not $ok) { Write-Log WARN 'A fonte oficial "winget" nao respondeu a consulta local de fontes.' }
    return $ok
}

function Test-InternetCache {
    [CmdletBinding()] param()
    if ($null -eq $script:CacheInternet) { $script:CacheInternet = Test-Internet }
    return $script:CacheInternet
}

function Get-WingetInstalledVersion {
    <# Versao instalada de um pacote, ou $null quando ausente.

       O estado instalado/ausente vem do CODIGO DE SAIDA (winget devolve
       0x8A150014 quando nada casa), que e estavel em qualquer idioma. A versao
       vem da tabela, e a tabela e localizada: por isso a linha e localizada pelo
       proprio ID e os campos sao lidos por POSICAO, nunca por cabecalho. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id)

    $r = Invoke-WingetComando -Arguments (@('list', '--id', $Id, '--exact') + (Get-WingetArgsComuns)) -TimeoutSeconds 180
    if ($r.ExitCode -ne 0) { return $null }

    $dados = Get-WingetLinhaPacote -Texto $r.StdOut -Id $Id
    if ($null -eq $dados) {
        # Codigo 0 sem linha reconhecivel: o pacote esta instalado, a versao nao
        # pode ser afirmada. Devolver 'n/d' e honesto; devolver $null diria
        # "nao instalado", o que seria falso.
        return 'n/d'
    }
    if ([string]::IsNullOrWhiteSpace($dados.Version)) { return 'n/d' }
    return $dados.Version
}

function Get-WingetLinhaPacote {
    <# Extrai Versao e Disponivel da saida de "winget list". Colunas:
       Nome | Id | Versao | Disponivel (opcional) | Fonte (opcional).
       Em console estreito o winget trunca celulas com reticencias, entao o ID e
       reconhecido tambem por prefixo truncado. #>
    [CmdletBinding()] param([string]$Texto, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $null }

    foreach ($linha in ($Texto -split "`r?`n")) {
        $l = $linha.Trim()
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        $campos = @([regex]::Split($l, '\s{2,}') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($campos.Count -lt 2) { continue }

        $idx = -1
        for ($i = 0; $i -lt $campos.Count; $i++) {
            $c = $campos[$i]
            if ($c -eq $Id) { $idx = $i; break }
            $cortado = $c.TrimEnd([char]0x2026, '.')
            if ($cortado.Length -ge 8 -and $Id.StartsWith($cortado, [System.StringComparison]::OrdinalIgnoreCase) -and $c -ne $cortado) {
                $idx = $i; break
            }
        }
        if ($idx -lt 0) { continue }

        $versao     = ''
        $disponivel = ''
        if ($campos.Count -gt ($idx + 1)) { $versao = $campos[$idx + 1] }
        if ($campos.Count -gt ($idx + 2)) {
            # O campo seguinte pode ser "Disponivel" ou a fonte. Versao comeca por
            # digito; nome de fonte, nao.
            $prox = $campos[$idx + 2]
            if ($prox -match '^\d') { $disponivel = $prox }
        }
        return [pscustomobject]@{ Version = $versao; Available = $disponivel }
    }
    return $null
}

function Test-WingetInstalled {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id)
    return ($null -ne (Get-WingetInstalledVersion -Id $Id))
}

function Get-WingetPackage {
    <# Confirma que o ID existe na fonte oficial e devolve a versao publicada.
       Usa "winget show --versions": a tabela de versoes nao depende de rotulo
       traduzido, ao contrario do bloco de detalhes. Resultado cacheado por
       sessao para que um lote nao repita a mesma consulta. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id)
    if ($script:CachePacote.ContainsKey($Id)) { return $script:CachePacote[$Id] }

    $r = Invoke-WingetComando -Arguments (@('show', '--id', $Id, '--exact', '--source', 'winget', '--versions') + (Get-WingetArgsComuns)) -TimeoutSeconds 180

    $pkg = [pscustomobject]@{
        Id             = $Id
        Found          = ($r.ExitCode -eq 0)
        LatestVersion  = $null
        ExitCode       = $r.ExitCode
    }

    if ($pkg.Found) {
        $separador = $false
        foreach ($linha in ($r.StdOut -split "`r?`n")) {
            $l = $linha.Trim()
            if ($l -match '^-{3,}$') { $separador = $true; continue }
            if ($separador -and -not [string]::IsNullOrWhiteSpace($l)) {
                $pkg.LatestVersion = ($l -split '\s{2,}')[0].Trim()
                break
            }
        }
    }

    $script:CachePacote[$Id] = $pkg
    return $pkg
}

function Install-WingetPackage {
    <# Instala UM pacote pelo ID exato, na fonte oficial, sem interatividade.
       Nao atualiza, nao remove, nao aceita URL e nao aceita fonte de terceiros. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Id)

    $argumentos = @(
        'install', '--id', $Id, '--exact',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements'
    ) + (Get-WingetArgsComuns)

    Write-Log INFO ("Executando: winget {0}" -f ($argumentos -join ' ')) -NoConsole
    $r = Invoke-WingetComando -Arguments $argumentos -TimeoutSeconds 1800

    $cauda = ''
    if ($r.StdErr) { $cauda = ($r.StdErr -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ' }
    if (-not $cauda -and $r.StdOut) { $cauda = ($r.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ' }
    Write-Log DEBUG ("winget install {0} -> codigo {1} | {2}" -f $Id, $r.ExitCode, $cauda) -NoConsole

    return $r
}

function Get-WingetResult {
    <# Traduz o codigo de saida do winget para o vocabulario de resultado do
       COMPARTDISK. Os codigos vem de AppInstallerErrors.h (winget-cli).

       O winget devolve HRESULT: em Int32 o valor chega negativo, e um teste
       ingenuo do tipo "codigo maior que zero" classificaria erro como sucesso. #>
    [CmdletBinding()] param([Parameter(Mandatory)][int]$ExitCode)

    # 0xFFFFFFFF sem sufixo e lido como Int32 (-1) pelo PowerShell, e a mascara
    # devolveria o proprio valor negativo. O sufixo L forca Int64.
    $u   = [uint32]([int64]$ExitCode -band 0xFFFFFFFFL)
    $hex = '0x{0:X8}' -f $u

    switch ($u) {
        0          { return (New-AppsResultado 'INSTALADO' $hex 'Instalacao concluida.') }
        1602       { return (New-AppsResultado 'CANCELADO' $hex 'Instalacao cancelada durante a execucao do instalador.') }
        1603       { return (New-AppsResultado 'ERRO' $hex 'O instalador terminou com erro fatal (1603).') }
        1618       { return (New-AppsResultado 'ERRO' $hex 'Outra instalacao esta em andamento no Windows (1618).') }
        3010       { return (New-AppsResultado 'REINICIALIZACAO NECESSARIA' $hex 'Instalado; o Windows precisa ser reiniciado para concluir.') }
        0x8A150005L { return (New-AppsResultado 'CANCELADO' $hex 'Operacao interrompida.') }
        0x8A150008L { return (New-AppsResultado 'ERRO' $hex 'Falha ao baixar o instalador.') }
        0x8A15000BL { return (New-AppsResultado 'FONTE INDISPONIVEL' $hex 'Fontes do winget invalidas.') }
        0x8A15000FL { return (New-AppsResultado 'FONTE INDISPONIVEL' $hex 'Dados da fonte ausentes.') }
        0x8A150010L { return (New-AppsResultado 'NAO DISPONIVEL' $hex 'Nenhum instalador aplicavel a esta arquitetura ou edicao.') }
        0x8A150012L { return (New-AppsResultado 'FONTE INDISPONIVEL' $hex 'A fonte informada nao existe neste sistema.') }
        0x8A150014L { return (New-AppsResultado 'NAO ENCONTRADO' $hex 'Nenhum pacote com este identificador na fonte oficial.') }
        0x8A150019L { return (New-AppsResultado 'ACESSO NEGADO' $hex 'A operacao exige privilegio administrativo.') }
        0x8A15003AL { return (New-AppsResultado 'ACESSO NEGADO' $hex 'Operacao bloqueada por politica da organizacao.') }
        0x8A15003FL { return (New-AppsResultado 'FONTE INDISPONIVEL' $hex 'Falha de integridade dos dados da fonte.') }
        0x8A150046L { return (New-AppsResultado 'FONTE INDISPONIVEL' $hex 'Contrato da fonte nao aceito.') }
        0x8A150061L { return (New-AppsResultado 'JA INSTALADO' $hex 'O pacote ja esta instalado.') }
        0x8A150101L { return (New-AppsResultado 'ERRO' $hex 'O aplicativo esta em uso; feche-o e repita.') }
        0x8A150102L { return (New-AppsResultado 'ERRO' $hex 'Ja existe uma instalacao em andamento.') }
        0x8A150103L { return (New-AppsResultado 'ERRO' $hex 'Arquivo em uso durante a instalacao.') }
        0x8A150104L { return (New-AppsResultado 'ERRO' $hex 'Dependencia ausente.') }
        0x8A150105L { return (New-AppsResultado 'ERRO' $hex 'Espaco em disco insuficiente.') }
        0x8A150106L { return (New-AppsResultado 'ERRO' $hex 'Memoria insuficiente.') }
        0x8A150107L { return (New-AppsResultado 'SEM INTERNET' $hex 'Sem conectividade para baixar o pacote.') }
        0x8A150109L { return (New-AppsResultado 'REINICIALIZACAO NECESSARIA' $hex 'Reinicie o computador para concluir a instalacao.') }
        0x8A15010AL { return (New-AppsResultado 'REINICIALIZACAO NECESSARIA' $hex 'O instalador exige reinicializacao antes de prosseguir.') }
        0x8A15010BL { return (New-AppsResultado 'REINICIALIZACAO NECESSARIA' $hex 'O instalador iniciou uma reinicializacao.') }
        0x8A15010CL { return (New-AppsResultado 'CANCELADO' $hex 'Instalacao cancelada.') }
        0x8A15010DL { return (New-AppsResultado 'JA INSTALADO' $hex 'O pacote ja esta instalado.') }
        0x8A15010FL { return (New-AppsResultado 'ACESSO NEGADO' $hex 'Instalacao bloqueada por politica.') }
        0x8A150113L { return (New-AppsResultado 'NAO DISPONIVEL' $hex 'Sistema nao suportado por este pacote.') }
        0x80070005L { return (New-AppsResultado 'ACESSO NEGADO' $hex 'Acesso negado pelo Windows.') }
        default    { return (New-AppsResultado 'ERRO' $hex ('O winget terminou com o codigo {0}.' -f $hex)) }
    }
}

function New-AppsResultado {
    param([string]$Status, [string]$Code, [string]$Message)
    return [pscustomobject]@{ Status = $Status; Code = $Code; Message = $Message }
}

# ------------------------------------------------------------------------------
# CATALOGO - consultas derivadas
# ------------------------------------------------------------------------------
function Get-AppsCatalogo { return $script:Catalogo }

function Get-AppsCategorias {
    <# Ordem fixa das categorias; categorias vazias continuam visiveis para que a
       numeracao do menu nao mude quando um aplicativo for acrescentado. #>
    return $script:CategoriasOrdem
}

function Get-AppsPorCategoria {
    param([Parameter(Mandatory)][string]$Categoria)
    return @($script:Catalogo | Where-Object { $_.Category -eq $Categoria })
}

function Resolve-AppPorId {
    <# Todo alvo precisa existir no catalogo interno. E tambem a barreira que
       impede que um -Id arbitrario chegue a linha de comando do winget. #>
    param([string]$Identificador)
    if ([string]::IsNullOrWhiteSpace($Identificador)) { return $null }
    $alvo = $Identificador.Trim()
    foreach ($app in $script:Catalogo) {
        if ($app.Id -and $app.Id -eq $alvo) { return $app }
    }
    foreach ($app in $script:Catalogo) {
        if ($app.Id -and $app.Id.Equals($alvo, [System.StringComparison]::OrdinalIgnoreCase)) { return $app }
        if ($app.Name.Equals($alvo, [System.StringComparison]::OrdinalIgnoreCase)) { return $app }
    }
    return $null
}

function Resolve-Categoria {
    param([string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return $null }
    $alvo = $Nome.Trim()
    foreach ($c in $script:CategoriasOrdem) {
        if ($c.Equals($alvo, [System.StringComparison]::OrdinalIgnoreCase)) { return $c }
    }
    # Aceita a forma sem espacos ("Windows/Sistema") e sem acento de menu
    foreach ($c in $script:CategoriasOrdem) {
        if (($c -replace '\s', '').Equals(($alvo -replace '\s', ''), [System.StringComparison]::OrdinalIgnoreCase)) { return $c }
    }
    return $null
}

# ------------------------------------------------------------------------------
# CENTRAL DE APLICATIVOS - pesquisa tolerante
# ------------------------------------------------------------------------------
# Camada de pesquisa: recebe o que o operador digitou, normaliza, consulta o
# catalogo local de apelidos, consulta a fonte oficial do winget, consolida,
# remove duplicidades e classifica por relevancia.
#
# Nada aqui instala nada e nada aqui monta comando a partir de texto livre: o
# termo e higienizado, viaja entre aspas como VALOR do parametro --query e o
# identificador oferecido e sempre o que a fonte oficial devolveu.
# ------------------------------------------------------------------------------
function Get-AppsTermoSeguro {
    <# Higieniza o texto digitado. Sobra apenas o que um nome de programa usa;
       o resto vira espaco. Um termo iniciado por '-' seria lido pelo winget como
       opcao de linha de comando, entao esses separadores caem do inicio. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }
    $t = $Texto.Trim()
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60) }
    $t = ($t -replace '[^\p{L}\p{Nd} \.\+\-_#]', ' ')
    $t = ($t -replace '\s{2,}', ' ').Trim()
    $t = $t.TrimStart('-', '.', '+', '_', '#').Trim()
    return $t
}

function Get-AppsTermoNormalizado {
    <# Forma de comparacao: minusculas, sem acento e sem separador. Assim
       "7 Zip", "7-zip" e "7ZIP" viram a mesma coisa, e "VS Code" vira "vscode".

       So SEPARADOR e pontuacao caem: letra de qualquer alfabeto permanece.
       Descartar tudo que nao fosse a-z0-9 fazia um nome como "XXoffice YY" em
       alfabeto nao latino colapsar para "office" e virar correspondencia
       EXATA falsa, na frente do proprio pacote procurado. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Texto.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return (($sb.ToString().ToLowerInvariant()) -replace '[^\p{L}\p{Nd}]', '')
}

function Get-AppsPalavras {
    <# Palavras do texto, normalizadas uma a uma. Permite comparar termo e nome
       PALAVRA a palavra, sem depender da ordem, e reconhecer rotulos como
       "beta" sem confundir com um nome que apenas contenha essas letras.
       Palavra de uma letra so nao entra: nao distingue nada. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return @() }
    $saida = New-Object System.Collections.ArrayList
    foreach ($parte in ($Texto -split '[\s\.\-_/\\+,;:()\[\]]+')) {
        $n = Get-AppsTermoNormalizado $parte
        if ($n.Length -ge 2) { [void]$saida.Add($n) }
    }
    return @($saida)
}

# ------------------------------------------------------------------------------
# CENTRAL DE APLICATIVOS - preferencia de idioma
# ------------------------------------------------------------------------------
# Muitos pacotes do winget publicam uma variante por localidade
# ("Mozilla.Firefox.af", "Mozilla.Firefox.pt-BR"). Sem tratamento, dezenas delas
# tomam a primeira pagina e escondem o pacote base.
#
# A preferencia e um fator ADICIONAL de relevancia, nunca um filtro: nenhuma
# variante deixa de aparecer por causa disto. E a localidade vem do IDENTIFICADOR
# publicado - o unico dado estrutural que a fonte oficial oferece. Editor NAO
# indica idioma ("Mozilla" nao torna um pacote pt-BR) e NOME EXIBIDO tambem nao:
# "Mozilla Firefox (en-US)" e o rotulo do pacote BASE "Mozilla.Firefox", e diz
# qual o idioma padrao dele - nao que ele seja a variante en-US, que tem
# identificador proprio ("Mozilla.Firefox.en-US").
#
# Sao tres coisas distintas, e o modulo nao as mistura:
#   pacote base      "Mozilla.Firefox"        - o aplicativo em si
#   variante de idioma "Mozilla.Firefox.pt-BR" - traducao publicada a parte
#   outra variante   "Mozilla.Firefox.ESR"    - outra edicao do mesmo aplicativo
#
# Ha ainda o pacote publicado com o nome em OUTRA ESCRITA e sem localidade no
# identificador ("Lenovo.LenovoVoice", exibido como um nome em chines). Nao ha
# localidade a declarar ali, e inventar uma seria adivinhar; mas a escrita do
# nome e evidencia objetiva e entra como fator de idioma, do mesmo peso das
# demais localidades. O nome continua sendo exibido como o winget o devolveu -
# o COMPARTDISK classifica, nunca traduz nem transcreve.
# ------------------------------------------------------------------------------
$script:CentralIdiomas    = $null
$script:CentralLocalidades = $null

function Get-AppsIdiomasConhecidos {
    <# Conjunto de codigos de idioma (duas letras) e de localidades completas sem
       separador ("ptbr", "enus"). Vem das culturas do proprio .NET, nao de uma
       tabela inventada, e e montado uma vez por sessao.

       So codigo conhecido e aceito: assim "esr", "dev", "vpn" e "beta" nunca sao
       confundidos com idioma. #>
    [CmdletBinding()] param()
    if ($null -ne $script:CentralIdiomas) { return $script:CentralIdiomas }

    $idiomas     = New-Object 'System.Collections.Generic.HashSet[string]'
    $localidades = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        foreach ($c in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::NeutralCultures)) {
            $n = $c.TwoLetterISOLanguageName
            if ($n -and $n.Length -eq 2) { [void]$idiomas.Add($n.ToLowerInvariant()) }
        }
        foreach ($c in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures)) {
            if ($c.Name) { [void]$localidades.Add(($c.Name -replace '-', '').ToLowerInvariant()) }
        }
    } catch { Write-Log DEBUG ('Central: lista de culturas indisponivel: {0}' -f $_.Exception.Message) -NoConsole }

    if ($idiomas.Count -lt 20) {
        # Ambiente sem a lista de culturas: conjunto minimo, suficiente para as
        # localidades que aparecem nos pacotes do winget.
        foreach ($n in @('af','an','ar','be','bg','bn','bs','ca','cs','cy','da','de','el','en','es','et','eu',
                         'fa','fi','fr','ga','gd','gl','gu','he','hi','hr','hu','hy','id','is','it','ja','ka',
                         'kk','km','kn','ko','lt','lv','mk','mr','ms','nb','ne','nl','nn','pa','pl','pt','ro',
                         'ru','si','sk','sl','sq','sr','sv','ta','te','th','tr','uk','ur','uz','vi','zh')) {
            [void]$idiomas.Add($n)
        }
        foreach ($n in @('ptbr','ptpt','enus','engb')) { [void]$localidades.Add($n) }
    }

    $script:CentralIdiomas     = $idiomas
    $script:CentralLocalidades = $localidades
    return $script:CentralIdiomas
}

function Get-AppsCodigoLocalidade {
    <# Devolve a localidade NORMALIZADA quando o texto for de fato um codigo de
       idioma conhecido: "pt-BR", "pt_br", "PTBR" e "ptbr" viram todos "ptbr".
       Devolve '' quando nao for.

       A normalizacao existe apenas para comparar. O texto original continua
       intacto: o COMPARTDISK nunca reescreve o nome que o winget devolveu. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }
    $null = Get-AppsIdiomasConhecidos
    $t = ($Texto.Trim() -replace '[_\s]', '-').ToLowerInvariant()

    if ($t -match '^[a-z]{2}$') {
        if ($script:CentralIdiomas.Contains($t)) { return $t }
        return ''
    }
    if ($t -match '^[a-z]{2}-[a-z0-9]{2,4}$') {
        if ($script:CentralIdiomas.Contains($t.Substring(0, 2))) { return ($t -replace '-', '') }
        return ''
    }
    # Forma sem separador ("ptbr"). Exige localidade real: sem isso "beta" seria
    # lido como "be-ta" e viraria bielorrusso.
    if ($t -match '^[a-z]{4}$' -and $script:CentralLocalidades.Contains($t)) { return $t }
    return ''
}

function Get-AppsLocalidade {
    <# Classifica UM resultado em duas dimensoes independentes: a localidade que
       ele declara e o tipo de pacote que ele e.

       A evidencia e o IDENTIFICADOR publicado, e so ele. O nome exibido e texto
       de vitrine: "Mozilla Firefox (en-US)" e como a fonte apresenta o pacote
       BASE "Mozilla.Firefox" - informa o idioma padrao dele, nao que ele seja a
       variante en-US. A variante de idioma tem identificador proprio, e e por
       ele que ela e reconhecida ("Mozilla.Firefox.pt-BR").

       O sufixo do nome entra APENAS para confirmar um segmento do identificador
       que a lista de culturas do .NET nao conhece. Sozinho ele nunca cria uma
       localidade - se criasse, todo pacote base rotulado "(en-US)" viraria uma
       traducao de si mesmo.

       Campos:
         Codigo   localidade normalizada, para comparar ('ptbr'); '' quando nao ha
         Locale   a localidade como o pacote a publica ('pt-BR'); '' quando nao ha
         Tipo     'Explicit' localidade declarada no identificador
                  'Base'     pacote base - o aplicativo em si, sem localidade
                  'Unknown'  outra variante do pacote (ESR, MSIX); idioma nao declarado
         Base     $true somente para o pacote base
         Variante 'Base', 'Locale' ou o segmento publicado da variante ('ESR', 'MSIX')

       Localidade e variante NAO se misturam: "Mozilla.Firefox.ESR" e outra
       edicao do aplicativo, nunca um idioma chamado "ESR". #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Item)

    $codigo    = ''
    $publicado = ''
    $tipo      = 'Base'
    $base      = $true
    $variante  = 'Base'

    # Sufixo entre parenteses do nome, quando houver: "Mozilla Firefox (pt-BR)".
    # Guardado so para a confirmacao logo abaixo.
    $sufixo = ''
    $m = [regex]::Match([string]$Item.Name, '\(([A-Za-z]{2,3}(?:[-_][A-Za-z]{2,4})?)\)\s*$')
    if ($m.Success) { $sufixo = ($m.Groups[1].Value -replace '[_-]', '').ToLowerInvariant() }

    # Tres segmentos no minimo: assim "netless-io.flat" nunca vira localidade.
    # Com dois, o identificador E o pacote base ("Mozilla.Firefox").
    $partes = @([string]$Item.Id -split '\.')
    if ($partes.Count -ge 3) {
        $ultimo = $partes[$partes.Count - 1]
        $c = Get-AppsCodigoLocalidade $ultimo
        if (-not $c -and $sufixo) {
            # A lista de culturas do .NET varia com o sistema e nao cobre codigos
            # como "ast". Quando o identificador E o nome declaram a MESMA coisa
            # ("Mozilla.Firefox.ast" com "Mozilla Firefox (ast)"), a propria
            # fonte ja confirmou que aquilo e uma localidade - "Google.Chrome.Dev"
            # e "Mozilla.Firefox.ESR" nao tem esse par e continuam de fora.
            $normal = ($ultimo -replace '[_-]', '').ToLowerInvariant()
            if ($normal -eq $sufixo -and $normal -match '^[a-z]{2,6}$') { $c = $normal }
        }
        if ($c) {
            # Localidade explicita: "Mozilla.Firefox.pt-BR".
            $codigo = $c; $publicado = $ultimo; $tipo = 'Explicit'; $base = $false; $variante = 'Locale'
        } else {
            # Segmento final que NAO e idioma conhecido: e outra edicao do mesmo
            # aplicativo ("Mozilla.Firefox.ESR", "Mozilla.Firefox.MSIX"). Nao e o
            # pacote base e nao tem idioma declarado - as duas coisas ao mesmo
            # tempo, e nenhuma delas vira a outra.
            $tipo = 'Unknown'; $base = $false; $variante = $ultimo
        }
    }

    return [pscustomobject]@{
        Codigo   = $codigo
        Locale   = $publicado
        Tipo     = $tipo
        Base     = $base
        Variante = $variante
    }
}

function Test-AppsEscritaNaoLatina {
    <# $true quando o texto TEM letras e NENHUMA delas e latina - "联想语音助手",
       "日本語", "한국어". Qualquer letra latina, inclusive acentuada, devolve
       $false: "Acao", "Ação" e ate "Lenovo 联想" sao texto latino.

       Isto NAO e deteccao de idioma e NAO vira localidade: e a constatacao
       objetiva de que o nome publicado esta em outra escrita. Localidade
       continua vindo do identificador, e de mais nada. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return $false }
    $temLetra = $false
    foreach ($c in $Texto.ToCharArray()) {
        if (-not [char]::IsLetter($c)) { continue }
        $temLetra = $true
        # Latim basico, suplemento Latin-1, Latin Extended-A/B e Additional:
        # cobre o alfabeto latino inteiro, do portugues ao vietnamita.
        $u = [int][char]$c
        if (($u -ge 0x0041 -and $u -le 0x005A) -or ($u -ge 0x0061 -and $u -le 0x007A) -or
            ($u -ge 0x00AA -and $u -le 0x00BA) -or ($u -ge 0x00C0 -and $u -le 0x024F) -or
            ($u -ge 0x1E00 -and $u -le 0x1EFF)) { return $false }
    }
    return $temLetra
}

function Get-AppsPrioridadeIdioma {
    <# REGRA CENTRAL DE IDIOMA DO COMPARTDISK - mudar a preferencia e mudar ESTA
       funcao, e mais nenhuma.

       Ordem: pt-BR, pacote base, portugues (pt / pt-PT), en-US (e en), demais
       localidades. A experiencia da Central e em portugues do Brasil, entao a
       traducao pt-BR vem na frente; logo atras vem o pacote base, que representa
       o aplicativo em si e nao uma de suas traducoes.

       Pacote SEM localidade declarada pesa igual ao base: e o caso de
       "Mozilla.Firefox.ESR" e "Mozilla.Firefox.MSIX", que sao outras edicoes do
       aplicativo, nao traducoes. A diferenca entre eles e o pacote base ja vem
       da correspondencia com o que foi digitado - esta funcao trata de IDIOMA, e
       nao inventa um desempate de variante que a relevancia ja resolve.

       -EscritaNaoLatina cobre o pacote que nao declara localidade nenhuma e
       publica o nome em outra escrita: sem localidade no identificador nao ha o
       que declarar, mas ele tambem nao e o aplicativo "em portugues nem em
       ingles" - pesa como as demais localidades.

       O valor e um peso somado a relevancia, nunca um corte: variante em idioma
       estrangeiro continua na lista, so nao ocupa a frente da versao em
       portugues, do pacote base nem da versao em ingles. #>
    [CmdletBinding()] param([AllowNull()][string]$Localidade, [switch]$Base, [switch]$EscritaNaoLatina)

    if ($EscritaNaoLatina -and [string]::IsNullOrEmpty($Localidade)) { return -60 }
    if ($Base -or [string]::IsNullOrEmpty($Localidade)) { return 120 }
    switch ($Localidade) {
        'ptbr'  { return 140 }
        'pt'    { return  70 }
        'ptpt'  { return  70 }
        'enus'  { return  50 }
        'en'    { return  50 }
        default { return -60 }
    }
}

function Get-AppsDistancia {
    <# Distancia de edicao (Levenshtein) entre dois textos ja normalizados. E o
       que permite achar "Google Chrome" a partir de "crome". Duas linhas de
       trabalho apenas: o custo e desprezivel para nomes de programa. #>
    [CmdletBinding()] param([string]$A, [string]$B)

    if ($A -eq $B) { return 0 }
    if ([string]::IsNullOrEmpty($A)) { return $B.Length }
    if ([string]::IsNullOrEmpty($B)) { return $A.Length }

    $n = $A.Length
    $m = $B.Length
    $ant = New-Object 'int[]' ($m + 1)
    $atu = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $ant[$j] = $j }

    for ($i = 1; $i -le $n; $i++) {
        $atu[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $custo = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $atu[$j] = [math]::Min([math]::Min($atu[$j - 1] + 1, $ant[$j] + 1), $ant[$j - 1] + $custo)
        }
        [array]::Copy($atu, $ant, $m + 1)
    }
    return $ant[$m]
}

function Get-AppsSemelhanca {
    <# 0 a 1. Textos longos sao truncados: o custo cresce com o produto dos
       tamanhos e nome de programa nao precisa de mais que isso. #>
    [CmdletBinding()] param([string]$A, [string]$B, [double]$Minimo = 0)

    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return 0.0 }
    if ($A.Length -gt 48) { $A = $A.Substring(0, 48) }
    if ($B.Length -gt 48) { $B = $B.Substring(0, 48) }
    $maior = [math]::Max($A.Length, $B.Length)
    if ($maior -eq 0) { return 0.0 }

    # A distancia nunca e menor que a diferenca de tamanho. Quando so isso ja
    # reprova o limite pedido, a matriz inteira nao precisa ser calculada - o que
    # importa numa pesquisa ampla, em que o winget devolve lista longa.
    if ($Minimo -gt 0) {
        $folga = [math]::Abs($A.Length - $B.Length)
        if ((1.0 - ($folga / [double]$maior)) -lt $Minimo) { return 0.0 }
    }
    return (1.0 - ([double](Get-AppsDistancia -A $A -B $B) / $maior))
}

function Find-AppsApelido {
    <# Melhor entrada do catalogo de apelidos para o termo ja normalizado.
       Informa tambem se a correspondencia foi exata: apelido exato pesa mais na
       classificacao do que uma aproximacao. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$TermoNormalizado)

    if ($TermoNormalizado.Length -lt 2) { return $null }
    $t = $TermoNormalizado
    $melhor = $null

    foreach ($entrada in $script:ApelidosCentral) {
        foreach ($apelido in $entrada.Termos) {
            $a = Get-AppsTermoNormalizado $apelido
            if ($a.Length -eq 0) { continue }

            $nivel = 0
            $exato = $false
            if ($a -eq $t) { $nivel = 3; $exato = $true }
            elseif ($t.Length -ge 3 -and $a.StartsWith($t, [System.StringComparison]::Ordinal)) { $nivel = 2 }
            elseif ($a.Length -ge 3 -and $t.StartsWith($a, [System.StringComparison]::Ordinal)) { $nivel = 2 }
            elseif ((Get-AppsSemelhanca -A $t -B $a) -ge 0.75) { $nivel = 1 }
            if ($nivel -eq 0) { continue }

            if ($null -eq $melhor -or $nivel -gt $melhor.Nivel) {
                $melhor = [pscustomobject]@{ Entrada = $entrada; Nivel = $nivel; Exato = $exato }
            }
            if ($exato) { return $melhor }
        }
    }
    return $melhor
}

function Test-AppsIdentificadorPacote {
    <# Um identificador do winget e "Editor.Pacote": letras, digitos e os
       separadores que os manifestos publicam. Recusa numero de versao (so
       digitos e pontos) e celula truncada pela largura do console, que traz
       reticencias e nunca serviria para instalar. #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) { return $false }
    if ($Texto.Length -lt 3 -or $Texto.Length -gt 128) { return $false }
    if ($Texto -notmatch '^[A-Za-z0-9][A-Za-z0-9_\+\-\.]*$') { return $false }
    if ($Texto -notmatch '\.') { return $false }
    if ($Texto -notmatch '[A-Za-z]') { return $false }
    # Celula truncada pelo winget: reticencias em ponto a ponto ('Editor.Pac...')
    # ou o caractere de reticencias, que o regex acima ja recusa.
    if ($Texto -match '\.\.' -or $Texto.EndsWith('.')) { return $false }
    return $true
}

function ConvertFrom-AppsTabelaWinget {
    <# Converte a tabela do "winget search" em itens. Os rotulos do cabecalho sao
       traduzidos pelo idioma do Windows; a regua de tracos que separa cabecalho
       de dados, nao. Por isso os dados comecam depois da regua e os campos sao
       lidos por POSICAO - a mesma regra ja aplicada a "winget list". #>
    [CmdletBinding()] param([AllowNull()][string]$Texto)

    $itens = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Texto)) { return @() }

    $vistos = @{}
    $dados  = $false
    $ordem  = 0
    foreach ($linha in ($Texto -split "`r?`n")) {
        $l = $linha.Trim()
        if (-not $dados) {
            if ($l -match '^-{3,}$') { $dados = $true }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($l)) { continue }

        $campos = @([regex]::Split($l, '\s{2,}') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($campos.Count -lt 2) { continue }

        # O primeiro campo e sempre o nome; o identificador e o primeiro campo
        # seguinte com forma de identificador.
        $nome = $campos[0]
        $id   = $null
        $pos  = -1
        for ($i = 1; $i -lt $campos.Count; $i++) {
            if (Test-AppsIdentificadorPacote $campos[$i]) { $id = $campos[$i]; $pos = $i; break }
        }

        # Quando o nome preenche a coluna inteira, sobra UM espaco entre ele e o
        # identificador e os dois chegam no mesmo campo. Recuperar o ultimo termo
        # do campo evita descartar um pacote legitimo - foi o que escondia o
        # "Microsoft 365 Apps for enterprise" numa pesquisa por "office".
        if (-not $id) {
            $partes = @($nome -split '\s+' | Where-Object { $_ -ne '' })
            if ($partes.Count -ge 2 -and (Test-AppsIdentificadorPacote $partes[-1])) {
                $id   = $partes[-1]
                $nome = ($partes[0..($partes.Count - 2)] -join ' ')
                $pos  = 0
            }
        }
        if (-not $id) { continue }

        # Colunas seguintes ao identificador: a versao e, na ultima posicao, a
        # fonte. Sao informativas - a classificacao usa nome, pacote e editor -,
        # entao campo ausente ou fora do lugar nunca invalida o resultado.
        $versao = ''
        $fonte  = ''
        $ultimo = $campos[$campos.Count - 1]
        if ($campos.Count -gt ($pos + 2) -and $ultimo -match '^[A-Za-z][A-Za-z0-9\-]*$') { $fonte = $ultimo }
        if ($campos.Count -gt ($pos + 1)) {
            $candidato = $campos[$pos + 1]
            if ($candidato -ne $fonte -and $candidato -notmatch '\s') { $versao = $candidato }
        }

        $chave = $id.ToLowerInvariant()
        if ($vistos.ContainsKey($chave)) { continue }
        $vistos[$chave] = $true

        [void]$itens.Add([pscustomobject]@{
            Name      = $nome
            Id        = $id
            # Moniker do editor: e a primeira parte do proprio identificador
            # publicado na fonte oficial, nao um nome inventado aqui.
            Publisher = ($id -split '\.')[0]
            Version   = $versao
            Source    = $(if ($fonte) { $fonte } else { 'winget' })
            # Posicao devolvida pela fonte oficial: e a opiniao do proprio
            # winget sobre relevancia, aproveitada apenas como desempate.
            Ordem     = $ordem
        })
        $ordem++
    }
    return @($itens)
}

function Search-AppsWinget {
    <# UMA consulta a fonte oficial, ja convertida em itens. Nao classifica e nao
       decide nada: quem decide relevancia e Get-AppsPesquisa.

       O termo viaja entre aspas como valor de --query. Invoke-NativeCommand nao
       usa shell (UseShellExecute = $false), entao nao ha linha de comando para
       um caractere do termo escapar. #>
    [CmdletBinding()] param([string]$Consulta, [string]$IdExato)

    $argumentos = @('search')
    if ($IdExato) {
        if (-not (Test-AppsIdentificadorPacote $IdExato)) { return @() }
        $argumentos += @('--id', $IdExato, '--exact')
    } else {
        if ([string]::IsNullOrWhiteSpace($Consulta)) { return @() }
        $argumentos += @('--query', ('"{0}"' -f $Consulta))
    }
    $argumentos += @('--source', 'winget')
    $argumentos += (Get-WingetArgsComuns)

    $r = Invoke-WingetComando -Arguments $argumentos -TimeoutSeconds 120
    if ($r.ExitCode -ne 0) {
        # "Nenhum pacote encontrado" tambem chega aqui: e resultado vazio, nao
        # falha. O motivo fica no log para quem for investigar.
        Write-Log DEBUG ("Central: winget {0} -> codigo {1}" -f ($argumentos -join ' '), $r.ExitCode) -NoConsole
        return @()
    }
    return (ConvertFrom-AppsTabelaWinget -Texto $r.StdOut)
}

function Get-AppsRelevancia {
    <# Pontua UM resultado diante do termo pesquisado, na ordem de prioridade da
       Central: correspondencia exata, inicio do nome, parte do nome; depois as
       evidencias fracas (palavras soltas do termo, semelhanca textual, editor);
       o restante fica por ultimo. Sobre isso incidem o apelido conhecido, o
       editor oficial e as penalizacoes.

       O desempate favorece o texto mais proximo em tamanho, que costuma ser o
       produto principal ("Google Chrome" antes de "Google Chrome Beta").

       Devolve a pontuacao e se o item merece DESTAQUE: destaque e correspondencia
       direta (ou apelido conhecido) sem nenhuma penalizacao. E o que separa
       "melhores resultados" de "mais resultados relacionados" na tela - nunca o
       que decide se um resultado aparece. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$TermoNormalizado,
        [string[]]$Palavras = @(),
        [string[]]$IdsPreferidos = @(),
        [int]$BonusApelido = 0,
        [switch]$TemEditorOficial
    )

    $t    = $TermoNormalizado
    $nome = Get-AppsTermoNormalizado $Item.Name
    $id   = Get-AppsTermoNormalizado $Item.Id
    $pub  = Get-AppsTermoNormalizado $Item.Publisher

    # Parte do identificador que nomeia o PACOTE, sem o moniker do editor:
    # "Netpack.XFB" -> "xfb". Comparar o identificador inteiro fazia todo pacote
    # de um editor chamado "Netpack" responder a "net" como se o NOME comecasse
    # por "net" - o editor tem tier proprio, mais baixo, e e onde isso pertence.
    $pacote = $id
    $bruto  = [string]$Item.Id
    $corte  = $bruto.IndexOf('.')
    if ($corte -ge 0) { $pacote = Get-AppsTermoNormalizado $bruto.Substring($corte + 1) }
    if ($nome.Length -eq 0) { $nome = $pacote }

    # Palavras do nome, calculadas UMA vez: servem para a correspondencia por
    # palavra completa, para a cobertura do termo e para os rotulos, mais abaixo.
    $palavrasNome = @(Get-AppsPalavras -Texto $Item.Name)

    # ESCADA DE CORRESPONDENCIA. A ordem e a prioridade, e o nome do aplicativo
    # pesa mais que o identificador: "Editor.Pacote" e dado tecnico, nao e como
    # a pessoa chama o programa. Editor vem por ultimo, como fator secundario.
    #
    #   nome exato > palavra completa do nome > inicio do nome > pacote exato >
    #   parte do nome > inicio do pacote > parte do pacote > editor
    #
    # $alvo guarda o texto que produziu a correspondencia: e contra ele que a
    # proximidade e medida mais abaixo.
    $base = 100
    $alvo = $nome
    if     ($nome -eq $t)                  { $base = 1000 }
    elseif ($palavrasNome -contains $t)    { $base = 950 }
    elseif ($nome.StartsWith($t, [System.StringComparison]::Ordinal)) { $base = 900 }
    elseif ($pacote -eq $t -or $id -eq $t) { $base = 860; $alvo = $pacote }
    elseif ($nome.Contains($t))            { $base = 800 }
    elseif ($pacote.StartsWith($t, [System.StringComparison]::Ordinal)) { $base = 780; $alvo = $pacote }
    elseif ($pacote.Contains($t))          { $base = 700; $alvo = $pacote }
    else {
        # Sem correspondencia direta vale a MELHOR das evidencias fracas, nunca
        # a primeira que aparecer: palavras do termo espalhadas pelo nome,
        # semelhanca textual e, por ultimo, coincidencia so no editor.
        if ($Palavras.Count -ge 2) {
            $casadas = 0
            foreach ($p in $Palavras) {
                if ($nome.Contains($p) -or $pacote.Contains($p)) { $casadas++ }
            }
            if ($casadas -gt 0) {
                $pontos = $(if ($casadas -eq $Palavras.Count) { 680 }
                            else { 400 + [int](200 * ($casadas / [double]$Palavras.Count)) })
                if ($pontos -gt $base) { $base = $pontos; $alvo = $nome }
            }
        }

        $sem = [math]::Max((Get-AppsSemelhanca -A $t -B $nome   -Minimo 0.62),
                           (Get-AppsSemelhanca -A $t -B $pacote -Minimo 0.62))
        if ($sem -ge 0.62) {
            $pontos = 300 + [int](300 * $sem)
            if ($pontos -gt $base) { $base = $pontos; $alvo = $nome }
        }

        if ($pub.Length -gt 0 -and $pub.Contains($t) -and $base -lt 550) { $base = 550; $alvo = $pub }
    }

    # O primeiro identificador do apelido e o mais provavel; os seguintes sao
    # alternativas legitimas do mesmo pedido e pesam um pouco menos.
    $bonus = 0
    for ($k = 0; $k -lt $IdsPreferidos.Count; $k++) {
        if ($IdsPreferidos[$k] -eq $Item.Id) {
            $bonus = [int]($BonusApelido * (1.0 - (0.15 * $k)))
            break
        }
    }

    # Quanto do texto que casou o termo explica. Medir sempre contra o nome dava
    # o bonus MAXIMO a qualquer nome mais curto que o termo, ainda que o
    # casamento tivesse vindo de outro campo - "XFB" pontuava cheio para "net".
    $prox = 0
    if ($alvo.Length -gt 0) {
        $prox = [int](120 * ($t.Length / [double][math]::Max($alvo.Length, $t.Length)))
    }

    # COBERTURA. Numa pesquisa de varias palavras, o resultado que atende TODAS
    # vale mais que o que atende uma so: "google chrome" tem de separar o Chrome
    # de qualquer outro programa do Google. Palavra completa conta inteiro;
    # aparecer apenas como pedaco conta metade.
    $cobertura = 0
    if ($Palavras.Count -ge 2) {
        $peso = 0.0
        foreach ($p in $Palavras) {
            if ($palavrasNome -contains $p)              { $peso += 1.0 }
            elseif ($nome.Contains($p) -or $pacote.Contains($p)) { $peso += 0.5 }
        }
        $cobertura = [int](100 * ($peso / [double]$Palavras.Count))
    }

    # POSICAO. Termo logo na primeira palavra do nome e evidencia mais forte do
    # que termo no fim. Peso pequeno de proposito: e desempate, nao criterio.
    $posicao = 0
    for ($k = 0; $k -lt $palavrasNome.Count; $k++) {
        if ($palavrasNome[$k] -eq $t -or $palavrasNome[$k].StartsWith($t, [System.StringComparison]::Ordinal)) {
            $posicao = [math]::Max(0, 24 - (8 * $k))
            break
        }
    }

    # A fonte oficial tambem tem opiniao sobre relevancia. Ela entra como
    # desempate leve - nunca no lugar da correspondencia com o que foi digitado.
    $ordem = 0
    if ($null -ne $Item.Ordem) { $ordem = [math]::Max(0, 40 - (4 * [int]$Item.Ordem)) }

    # EDITOR OFICIAL. O unico vinculo que os dados do winget permitem AFIRMAR e
    # este: o moniker do editor, no proprio identificador publicado, e igual ao
    # que foi procurado. "Google.Chrome" responde por "google"; "arjun-g" nao.
    # Nada e inferido a partir de nome de empresa conhecida, e pacote de
    # terceiro nunca e removido - apenas deixa de ocupar o lugar do oficial.
    $extra = 0
    $penalizado = $false
    $oficial = ($pub.Length -gt 0 -and ($pub -eq $t -or $Palavras -contains $pub))
    if ($oficial) { $extra += 150 }
    elseif ($TemEditorOficial -and $base -ge 800) { $extra -= 100; $penalizado = $true }

    # Rotulos que o proprio winget publica no nome. Comparados palavra a palavra
    # para nao confundir "Betaflight" com "Beta". Se o operador pediu o rotulo,
    # ele nao penaliza nada.
    foreach ($palavra in $palavrasNome) {
        if ($Palavras -contains $palavra) { continue }
        if ($script:CentralRotulosNaoOficiais -contains $palavra) { $extra -= 120; $penalizado = $true; continue }
        if ($script:CentralRotulosSecundarios -contains $palavra) { $extra -= 80; $penalizado = $true }
    }

    # PREFERENCIA DE IDIOMA. Fator adicional, jamais filtro. Se o operador pediu
    # a localidade ("firefox af"), ela deixa de pesar contra.
    $local = Get-AppsLocalidade -Item $Item
    if ($local.Codigo -and ($Palavras -contains $local.Codigo)) {
        $idioma = 120
    } else {
        # Nome publicado em outra escrita, sem localidade no identificador. Quem
        # procura EM outra escrita esta procurando o que foi publicado nela, e
        # nesse caso o fator nao se aplica a ninguem.
        $outraEscrita = $false
        if (-not (Test-AppsEscritaNaoLatina -Texto $TermoNormalizado)) {
            $outraEscrita = (Test-AppsEscritaNaoLatina -Texto $Item.Name)
        }
        $idioma = Get-AppsPrioridadeIdioma -Localidade $local.Codigo -Base:$local.Base -EscritaNaoLatina:$outraEscrita
    }
    # Variante em idioma estrangeiro sai do destaque: continua listada, em "mais
    # resultados relacionados", em vez de tomar a frente do pacote base.
    $estrangeira = ($idioma -lt 0)
    if ($estrangeira) { $penalizado = $true }

    return [pscustomobject]@{
        Score    = ($base + $bonus + $prox + $cobertura + $posicao + $ordem + $extra + $idioma)
        Destaque = (($base -ge 780 -or $bonus -gt 0) -and -not $penalizado)
        Estrangeira = $estrangeira
    }
}

function Get-AppsPesquisa {
    <# Pesquisa completa: normaliza, consulta o catalogo local, consulta o winget,
       consolida, remove duplicidades e classifica.

       Devolve a lista INTEIRA ja classificada: nenhum resultado valido do winget
       e descartado aqui. Quem exibe decide quantos cabem na tela.

       Desempenho: uma consulta ao winget no caso comum. A segunda so acontece
       quando o apelido apontou um pacote que a primeira consulta nao trouxe, e a
       terceira so quando a primeira nao trouxe absolutamente nada. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Termo, [int]$Maximo = 0)

    $t = Get-AppsTermoNormalizado $Termo
    if ($t.Length -eq 0) { return @() }
    $palavras = @(Get-AppsPalavras -Texto $Termo)

    $preferidos = @()
    $bonus      = 0
    $apelido    = Find-AppsApelido -TermoNormalizado $t
    if ($apelido) {
        $preferidos = @($apelido.Entrada.Ids)
        $bonus      = $(if ($apelido.Exato) { 500 } else { 250 })
        Write-Log DEBUG ("Central: apelido reconhecido para '{0}' -> {1}" -f $Termo, ($preferidos -join ', ')) -NoConsole
    }

    # A palavra do operador e SEMPRE pesquisada: um apelido nunca sequestra a
    # intencao de quem digitou.
    $itens = @(Search-AppsWinget -Consulta $Termo)

    if ($apelido) {
        # Uma sondagem no maximo, sempre no identificador principal: as demais
        # alternativas do apelido chegam pela propria pesquisa por nome.
        $principal = $preferidos[0]
        if (-not (@($itens) | Where-Object { $_.Id -eq $principal })) {
            $itens = @($itens) + @(Search-AppsWinget -IdExato $principal)
        }
        if (@($itens).Count -eq 0) {
            $itens = @(Search-AppsWinget -Consulta $apelido.Entrada.Nome)
        }
    }

    $vistos = @{}
    $lista  = New-Object System.Collections.ArrayList
    foreach ($it in @($itens)) {
        if ($null -eq $it -or [string]::IsNullOrWhiteSpace($it.Id)) { continue }
        $chave = $it.Id.ToLowerInvariant()
        if ($vistos.ContainsKey($chave)) { continue }
        $vistos[$chave] = $true
        [void]$lista.Add($it)
    }

    # A pergunta "existe pacote do proprio editor procurado?" e do CONJUNTO, nao
    # de um item: por isso a pontuacao vem depois de consolidar a lista.
    $temOficial = $false
    foreach ($it in $lista) {
        $p = Get-AppsTermoNormalizado $it.Publisher
        if ($p.Length -gt 0 -and ($p -eq $t -or $palavras -contains $p)) { $temOficial = $true; break }
    }

    foreach ($it in $lista) {
        $r = Get-AppsRelevancia -Item $it -TermoNormalizado $t -Palavras $palavras `
                -IdsPreferidos $preferidos -BonusApelido $bonus -TemEditorOficial:$temOficial
        Add-Member -InputObject $it -NotePropertyName 'Score'       -NotePropertyValue $r.Score       -Force
        Add-Member -InputObject $it -NotePropertyName 'Destaque'    -NotePropertyValue $r.Destaque    -Force
        Add-Member -InputObject $it -NotePropertyName 'Estrangeira' -NotePropertyValue $r.Estrangeira -Force
    }

    # Destaque antes de pontuacao: sem isso um item penalizado com pontuacao alta
    # se intercalaria entre os destaques e o agrupamento da tela deixaria de ser
    # contiguo. Dentro de cada grupo vale a pontuacao, e o nome desempata.
    $comparador = @(
        @{ Expression = 'Destaque'; Descending = $true },
        @{ Expression = 'Score';    Descending = $true },
        @{ Expression = 'Name';     Descending = $false }
    )
    $ordenada = @($lista | Sort-Object -Property $comparador)

    # SEGUNDA ETAPA - diversidade. Variacoes do mesmo pacote ("Google.Chrome",
    # "Google.Chrome.Beta", "Mozilla.Firefox.ESR", "Mozilla.Firefox.af") sao
    # reconhecidas pela familia do identificador publicado: os dois primeiros
    # segmentos. A melhor de cada familia mantem o lugar; as irmas recuam, e
    # recuam mais a cada irma - e o que impede que dezenas de traducoes do mesmo
    # aplicativo tomem a primeira pagina. Nao e filtro: nada sai da lista, e o
    # destaque de ninguem muda aqui.
    $familias    = @{}
    $estrangeiras = @{}
    foreach ($it in $ordenada) {
        $partes  = @([string]$it.Id -split '\.')
        $familia = $(if ($partes.Count -ge 2) { ($partes[0] + '.' + $partes[1]) } else { [string]$it.Id })
        $familia = $familia.ToLowerInvariant()

        if (-not $familias.ContainsKey($familia)) { $familias[$familia] = $true; continue }

        if ($it.Estrangeira) {
            # O recuo cresce a cada traducao seguinte: e o que impede que dezenas
            # de localidades do mesmo aplicativo tomem a primeira pagina.
            if ($estrangeiras.ContainsKey($familia)) { $estrangeiras[$familia]++ } else { $estrangeiras[$familia] = 1 }
            $it.Score = $it.Score - [math]::Min(180, 30 + (30 * $estrangeiras[$familia]))
        } else {
            # Base, pt-BR, pt-PT e en-US recuam por igual: a ordem entre elas
            # continua sendo a da preferencia de idioma, nao a da fila.
            $it.Score = $it.Score - 60
        }
    }
    $ordenada = @($ordenada | Sort-Object -Property $comparador)

    if ($Maximo -gt 0) { return @($ordenada | Select-Object -First $Maximo) }
    return $ordenada
}

function New-AppsItemCentral {
    <# Converte um resultado da pesquisa no mesmo formato do catalogo, para que a
       instalacao siga exatamente o caminho ja validado do modulo - inclusive a
       confirmacao do identificador na fonte oficial e a verificacao final. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Item)

    return [pscustomobject]@{
        Name         = $Item.Name
        Id           = $Item.Id
        Category     = 'Central de Aplicativos'
        Description  = ''
        Native       = $false
        Available    = $true
        Publisher    = $Item.Publisher
        PackageType  = 'n/d'
        Scope        = 'n/d'
        Architecture = 'n/d'
        SuiteId      = $null
        Note         = ''
    }
}

# ------------------------------------------------------------------------------
# INSTALACAO
# ------------------------------------------------------------------------------
function Get-AppsCorStatus {
    param([string]$Status)
    switch ($Status) {
        'INSTALADO'                  { return [ConsoleColor]::Green }
        'JA INSTALADO'               { return [ConsoleColor]::DarkGray }
        'RECURSO NATIVO'             { return [ConsoleColor]::Cyan }
        'REINICIALIZACAO NECESSARIA' { return [ConsoleColor]::Yellow }
        'NAO DISPONIVEL'             { return [ConsoleColor]::Yellow }
        'NAO ENCONTRADO'             { return [ConsoleColor]::Yellow }
        'CANCELADO'                  { return [ConsoleColor]::Yellow }
        default                      { return [ConsoleColor]::Red }
    }
}

function Invoke-AppInstalacao {
    <# Instala UM aplicativo do catalogo e devolve o registro do desfecho.
       Nunca lanca: uma falha individual nao pode interromper um lote. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$App)

    $reg = [pscustomobject]@{
        Name             = $App.Name
        Id               = $App.Id
        Category         = $App.Category
        Status           = 'ERRO'
        Code             = ''
        Message          = ''
        InstalledVersion = ''
        AvailableVersion = ''
        Verified         = $false
    }

    try {
        # 1. Recurso nativo: nada a instalar, e nenhum ID inventado.
        if ($App.Native) {
            $reg.Status  = 'RECURSO NATIVO'
            $reg.Message = $App.Note
            return $reg
        }

        # 2. Sem pacote oficial: o COMPARTDISK nao substitui por download avulso.
        if (-not $App.Available -or [string]::IsNullOrWhiteSpace($App.Id)) {
            $reg.Status  = 'NAO DISPONIVEL'
            $reg.Message = $App.Note
            return $reg
        }

        # 3. winget presente.
        $ctx = Get-WingetContexto
        if (-not $ctx.Available) {
            $reg.Status  = 'ERRO'
            $reg.Message = 'winget indisponivel neste sistema.'
            return $reg
        }

        # 4. Ja atendido pela suite? Evita baixar de novo a mesma ferramenta.
        if ($App.SuiteId) {
            $vSuite = Get-WingetInstalledVersion -Id $App.SuiteId
            if ($vSuite) {
                $reg.Status           = 'JA INSTALADO'
                $reg.InstalledVersion = $vSuite
                $reg.Verified         = $true
                $reg.Message          = ('Ja atendido por {0} (instalado: {1}).' -f $App.SuiteId, $vSuite)
                return $reg
            }
        }

        # 5. Ja instalado individualmente?
        $vAtual = Get-WingetInstalledVersion -Id $App.Id
        if ($vAtual) {
            $reg.Status           = 'JA INSTALADO'
            $reg.InstalledVersion = $vAtual
            $reg.Verified         = $true
            $reg.Message          = 'Presente no sistema; nada foi alterado.'
            return $reg
        }

        # 6. O ID existe na fonte oficial?
        $pkg = Get-WingetPackage -Id $App.Id
        if (-not $pkg.Found) {
            $res = Get-WingetResult -ExitCode $pkg.ExitCode
            if ($res.Status -eq 'INSTALADO' -or $res.Status -eq 'ERRO') {
                # Consulta falhou por outro motivo que nao "inexistente": nao
                # afirmar que o pacote nao existe.
                $net = Test-InternetCache
                if (-not $net.Online) {
                    $reg.Status  = 'SEM INTERNET'
                    $reg.Message = 'Nao foi possivel consultar a fonte oficial: sem conectividade.'
                    return $reg
                }
                $reg.Status  = 'FONTE INDISPONIVEL'
                $reg.Code    = $res.Code
                $reg.Message = 'Nao foi possivel consultar o pacote na fonte oficial.'
                return $reg
            }
            $reg.Status  = $res.Status
            $reg.Code    = $res.Code
            $reg.Message = $res.Message
            return $reg
        }
        $reg.AvailableVersion = [string]$pkg.LatestVersion

        # 7. Instalar.
        $r   = Install-WingetPackage -Id $App.Id
        $res = Get-WingetResult -ExitCode $r.ExitCode
        $reg.Status  = $res.Status
        $reg.Code    = $res.Code
        $reg.Message = $res.Message

        # 8. Verificar o estado final. Codigo 0 sozinho nao e prova de instalacao.
        if ($res.Status -eq 'INSTALADO' -or $res.Status -eq 'REINICIALIZACAO NECESSARIA') {
            $vFinal = Get-WingetInstalledVersion -Id $App.Id
            if ($vFinal) {
                $reg.InstalledVersion = $vFinal
                $reg.Verified         = $true
            } else {
                $reg.Verified = $false
                $reg.Message  = $res.Message + ' Estado final nao confirmado por "winget list".'
                Write-Log WARN ("{0}: o winget relatou conclusao, mas o pacote nao aparece como instalado." -f $App.Name) -NoConsole
            }
        }

        if ($res.Status -eq 'JA INSTALADO') {
            $reg.InstalledVersion = [string](Get-WingetInstalledVersion -Id $App.Id)
            $reg.Verified         = [bool]$reg.InstalledVersion
        }

        return $reg
    } catch {
        $reg.Status  = 'ERRO'
        $reg.Message = $_.Exception.Message
        Write-Log ERR ("Falha ao instalar {0}." -f $App.Name) -ErrorRecord $_ -NoConsole
        return $reg
    }
}

function Write-AppsLinhaLote {
    param([int]$Indice, [int]$Total, [string]$Nome, [string]$Status)
    $largura = 32
    $nome = $Nome
    if ($nome.Length -gt $largura) { $nome = $nome.Substring(0, $largura) }
    $pontos = '.' * [math]::Max(3, ($largura - $nome.Length + 3))
    Write-Color ("  [{0}/{1}] {2} {3} " -f $Indice, $Total, $nome, $pontos) -Color Gray -NoNewLine
    Write-Color $Status -Color (Get-AppsCorStatus $Status)
}

function Invoke-AppsLote {
    <# Executa a lista inteira. Falha individual NAO interrompe o lote. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object[]]$Aplicativos, [string]$Titulo = 'Instalacao em lote')

    Write-Log INFO ("{0}: {1} aplicativo(s) na fila." -f $Titulo, $Aplicativos.Count)
    Write-Color ''

    $registros = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($app in $Aplicativos) {
        $i++
        $reg = Invoke-AppInstalacao -App $app
        [void]$registros.Add($reg)
        [void]$script:Registros.Add($reg)
        Write-AppsLinhaLote -Indice $i -Total $Aplicativos.Count -Nome $app.Name -Status $reg.Status
        Write-Log INFO ("{0} [{1}] -> {2} {3} {4}" -f $app.Name, $app.Id, $reg.Status, $reg.Code, $reg.Message) -NoConsole
    }
    return $registros
}

function Get-AppsResumo {
    param([object[]]$Registros)
    $r = [pscustomobject]@{
        Instalados     = @($Registros | Where-Object { $_.Status -eq 'INSTALADO' }).Count
        JaInstalados   = @($Registros | Where-Object { $_.Status -eq 'JA INSTALADO' }).Count
        NaoDisponiveis = @($Registros | Where-Object { $_.Status -eq 'NAO DISPONIVEL' -or $_.Status -eq 'NAO ENCONTRADO' }).Count
        Nativos        = @($Registros | Where-Object { $_.Status -eq 'RECURSO NATIVO' }).Count
        Reinicializar  = @($Registros | Where-Object { $_.Status -eq 'REINICIALIZACAO NECESSARIA' }).Count
        Falhas         = @($Registros | Where-Object { $_.Status -eq 'ERRO' -or $_.Status -eq 'ACESSO NEGADO' -or $_.Status -eq 'SEM INTERNET' -or $_.Status -eq 'FONTE INDISPONIVEL' -or $_.Status -eq 'CANCELADO' }).Count
        Total          = @($Registros).Count
    }
    return $r
}

function Write-AppsResumo {
    param([object[]]$Registros)
    $s = Get-AppsResumo -Registros $Registros

    Write-Color ''
    Write-Color '  RESUMO DA INSTALACAO' -Color White
    Write-Color ("  " + ('-' * 74)) -Color DarkGray
    Write-Color ''
    Write-CompartDiskKeyValue 'Instalados'       $s.Instalados     -Pad 18 -Color Green
    Write-CompartDiskKeyValue 'Ja instalados'    $s.JaInstalados   -Pad 18 -Color Gray
    Write-CompartDiskKeyValue 'Nao disponiveis'  $s.NaoDisponiveis -Pad 18 -Color Yellow
    Write-CompartDiskKeyValue 'Falhas'           $s.Falhas         -Pad 18 -Color $(if ($s.Falhas -gt 0) { 'Red' } else { 'Gray' })
    if ($s.Nativos -gt 0)       { Write-CompartDiskKeyValue 'Recursos nativos'  $s.Nativos       -Pad 18 -Color Cyan }
    if ($s.Reinicializar -gt 0) { Write-CompartDiskKeyValue 'Exigem reinicio'   $s.Reinicializar -Pad 18 -Color Yellow }
    Write-Color ''

    foreach ($reg in ($Registros | Where-Object { $_.Status -ne 'INSTALADO' -and $_.Status -ne 'JA INSTALADO' })) {
        Write-Color ("  {0,-30} {1} - {2}" -f $reg.Name, $reg.Status, $reg.Message) -Color DarkGray
    }
    return $s
}

function Add-AppsRelatorio {
    <# Publica o desfecho nas secoes e achados que alimentam os relatorios. #>
    param([object[]]$Registros, [string]$Titulo)
    if (-not $Registros -or @($Registros).Count -eq 0) { return }

    $s = Get-AppsResumo -Registros $Registros
    $linhas = @($Registros | ForEach-Object {
        [pscustomobject]@{
            Aplicativo = $_.Name
            Categoria  = $_.Category
            Pacote     = $(if ($_.Id) { $_.Id } else { 'n/d' })
            Resultado  = $_.Status
            Versao     = $(if ($_.InstalledVersion) { $_.InstalledVersion } else { 'n/d' })
            Disponivel = $(if ($_.AvailableVersion) { $_.AvailableVersion } else { 'n/d' })
            Detalhe    = $_.Message
        }
    })

    $status = 'OK'
    if ($s.Falhas -gt 0) { $status = 'WARN' }
    Add-CompartDiskSection -Title $Titulo -Status $status -Rows $linhas -Summary (
        'Instalados: {0} | Ja instalados: {1} | Nao disponiveis: {2} | Falhas: {3}' -f $s.Instalados, $s.JaInstalados, $s.NaoDisponiveis, $s.Falhas)

    if ($s.Instalados -gt 0) {
        Add-CompartDiskFinding -Severity OK -Area 'Aplicativos' -Message ("{0} aplicativo(s) instalado(s) via winget." -f $s.Instalados)
    }
    foreach ($reg in ($Registros | Where-Object { $_.Status -eq 'ERRO' -or $_.Status -eq 'ACESSO NEGADO' -or $_.Status -eq 'SEM INTERNET' -or $_.Status -eq 'FONTE INDISPONIVEL' })) {
        Add-CompartDiskFinding -Severity WARN -Area 'Aplicativos' -Message ("{0}: {1} - {2}" -f $reg.Name, $reg.Status, $reg.Message) -Recommendation 'Repetir a instalacao deste item isoladamente e consultar o log da sessao.'
    }
    foreach ($reg in ($Registros | Where-Object { $_.Status -eq 'REINICIALIZACAO NECESSARIA' })) {
        Add-CompartDiskFinding -Severity WARN -Area 'Aplicativos' -Message ("{0} exige reinicializacao para concluir." -f $reg.Name) -Recommendation 'Reiniciar o computador.'
    }
}

# ------------------------------------------------------------------------------
# INTERFACE - somente numerica
# ------------------------------------------------------------------------------
# Entrada numerica e deteccao de modo interativo vivem no Core.ps1: os menus
# deste modulo e os de Winget.ps1 usam exatamente a mesma implementacao.
function Test-ModoInterativo { return (Test-CompartDiskInterativo -Quiet:$Quiet) }

function Write-AppsCabecalho {
    <# Delega ao ponto unico do Core: limpa a tela e desenha titulo e regua.
       Mantido como nome local para nao mexer nos pontos de chamada. #>
    param([string]$Titulo)
    Write-CompartDiskMenuCabecalho -Titulo $Titulo -Quiet:$Quiet
}

function Show-WingetIndisponivel {
    <# O estado detalhado vem do Core (Test-WingetAvailability), o mesmo que a
       area de preparacao usa: as duas telas nunca discordam sobre o diagnostico. #>
    $amb = $null
    try { $amb = Test-WingetAvailability } catch { }

    Write-AppsCabecalho 'WINGET INDISPONIVEL'
    Write-Color '  O Windows nao possui o WinGet disponivel neste ambiente.' -Color Yellow
    Write-Color '  A instalacao de aplicativos nao pode continuar.' -Color Yellow
    if ($amb -and $amb.Reason) {
        Write-Color ''
        Write-Color ("  Estado detectado: {0}" -f $amb.State) -Color DarkGray
        Write-Color ("  {0}" -f $amb.Reason) -Color DarkGray
    }
    Write-Color ''
    Write-Color '  No menu Aplicativos, a opcao [1] Verificar / preparar WinGet diagnostica o' -Color Gray
    Write-Color '  ambiente e prepara o App Installer por metodos oficiais do Windows.' -Color Gray
    Write-Color ''
    Write-Color '  [1] Voltar' -Color Cyan
    Write-Color '  [0] Menu principal de aplicativos' -Color DarkGray
    Write-Color ''
    if (Test-ModoInterativo) { [void](Read-CompartDiskOpcao -Maximo 1) }
}

function Show-AppsAposLote {
    <# Rodape numerico do resumo: [1] volta ao menu anterior, [0] ao menu do modulo. #>
    Write-Color ''
    Write-Color '  [1] Voltar' -Color Cyan
    Write-Color '  [0] Menu principal de aplicativos' -Color DarkGray
    Write-Color ''
    if (-not (Test-ModoInterativo)) { return 0 }
    return (Read-CompartDiskOpcao -Maximo 1)
}

function Show-DetalheApp {
    <# Linha secundaria exibida sob o nome quando o item nao e instalavel. #>
    param([object]$App)
    if ($App.Native)        { Write-Color '      Recurso nativo do Windows' -Color Cyan; return }
    if (-not $App.Available) { Write-Color '      Status: Nao disponivel via WinGet' -Color Yellow; return }
}

function Show-MenuCategoria {
    <# Menu de uma categoria. Numeracao derivada do catalogo:
       [1..N] aplicativos | [N+1] instalar todos | [0] voltar. #>
    param([Parameter(Mandatory)][string]$Categoria)

    $apps = Get-AppsPorCategoria -Categoria $Categoria
    while ($true) {
        Write-AppsCabecalho ($Categoria.ToUpper())

        if ($apps.Count -eq 0) {
            Write-Color '  Nenhum aplicativo cadastrado nesta categoria.' -Color DarkGray
            Write-Color '  A categoria existe como ponto de extensao do catalogo.' -Color DarkGray
            Write-Color ''
            Write-Color '  [0] Voltar' -Color DarkGray
            Write-Color ''
            if (-not (Test-ModoInterativo)) { return }
            [void](Read-CompartDiskOpcao -Maximo 0)
            return
        }

        for ($i = 0; $i -lt $apps.Count; $i++) {
            Write-Color ("  [{0}] {1}" -f ($i + 1), $apps[$i].Name) -Color Cyan
            Show-DetalheApp -App $apps[$i]
        }
        Write-Color ("  [{0}] Instalar todos" -f ($apps.Count + 1)) -Color Cyan
        Write-Color '  [0] Voltar' -Color DarkGray
        Write-Color ''

        if (-not (Test-ModoInterativo)) { return }
        $opc = Read-CompartDiskOpcao -Maximo ($apps.Count + 1)
        if ($opc -eq 0) { return }

        if ($opc -eq ($apps.Count + 1)) {
            $rc = Invoke-LoteCategoria -Categoria $Categoria -Aplicativos $apps
            if ($rc -eq 0) { return }
            continue
        }

        # Instalacao individual: executa e volta ao menu desta categoria.
        $app = $apps[$opc - 1]
        Write-Color ''
        Write-Log INFO ("Instalacao individual solicitada: {0}" -f $app.Name)
        $reg = Invoke-AppInstalacao -App $app
        [void]$script:Registros.Add($reg)
        Write-ResultadoIndividual -Registro $reg
        Add-AppsRelatorio -Registros @($reg) -Titulo ('Instalacao de aplicativo - {0}' -f $app.Name)
        Set-ResultadoModulo -Registros @($reg)

        # O menu da categoria e redesenhado a seguir, o que limpa a tela. Sem
        # esta parada o operador nunca leria o desfecho da instalacao. Mesmo
        # padrao numerico das demais telas de resultado do modulo.
        if (Test-ModoInterativo) {
            Write-Color '  [0] Voltar' -Color DarkGray
            Write-Color ''
            [void](Read-CompartDiskOpcao -Maximo 0)
        }
    }
}

function Write-ResultadoIndividual {
    param([object]$Registro)
    $cor = Get-AppsCorStatus $Registro.Status
    switch ($Registro.Status) {
        'INSTALADO' {
            Write-Log OK ("{0} instalado com sucesso." -f $Registro.Name)
            if ($Registro.InstalledVersion) { Write-Color ("       Versao: {0}" -f $Registro.InstalledVersion) -Color DarkGray }
            if (-not $Registro.Verified)    { Write-Color '       Estado final nao confirmado por "winget list".' -Color Yellow }
        }
        'JA INSTALADO' {
            Write-Log OK ("{0} - ja instalado - ignorado." -f $Registro.Name)
            if ($Registro.InstalledVersion) { Write-Color ("       Versao instalada: {0}" -f $Registro.InstalledVersion) -Color DarkGray }
            if ($Registro.Message)          { Write-Color ("       {0}" -f $Registro.Message) -Color DarkGray }
        }
        'RECURSO NATIVO' {
            Write-Log INFO ("{0} - recurso nativo do Windows - nada a instalar." -f $Registro.Name)
            if ($Registro.Message) { Write-Color ("       {0}" -f $Registro.Message) -Color DarkGray }
        }
        'NAO DISPONIVEL' {
            Write-Log WARN ("{0} - nao disponivel via WinGet." -f $Registro.Name)
            if ($Registro.Message) { Write-Color ("       {0}" -f $Registro.Message) -Color DarkGray }
        }
        default {
            Write-Log WARN ("{0} - {1} - {2}" -f $Registro.Name, $Registro.Status, $Registro.Message)
            if ($Registro.Code) { Write-Color ("       Codigo do winget: {0}" -f $Registro.Code) -Color DarkGray }
        }
    }
    Write-Color ''
}

function Invoke-LoteCategoria {
    <# [Instalar todos] de uma categoria: verifica, lista, confirma, executa.
       Devolve 1 para permanecer no menu da categoria e 0 para voltar ao menu
       principal de aplicativos - a navegacao segue a escolha numerica real. #>
    param([string]$Categoria, [object[]]$Aplicativos)

    Write-AppsCabecalho 'INSTALACAO EM LOTE'
    Write-Color ("  {0}" -f $Categoria) -Color White
    Write-Color ''
    Write-Color '  Verificando o estado atual dos aplicativos...' -Color DarkGray
    Write-Color ''

    $i = 0
    $pendentes = New-Object System.Collections.ArrayList
    foreach ($app in $Aplicativos) {
        $i++
        $estado = Get-EstadoApp -App $app
        Write-Color ("  {0}. {1,-32} {2}" -f $i, $app.Name, $estado.Rotulo) -Color $estado.Cor
        if ($estado.Instalavel) { [void]$pendentes.Add($app) }
    }

    Write-Color ''
    if ($pendentes.Count -eq 0) {
        Write-Color '  Nenhum item pendente: nada seria instalado.' -Color DarkGray
        Write-Color ''
        Write-Color '  [0] Voltar' -Color DarkGray
        Write-Color ''
        if (Test-ModoInterativo) { [void](Read-CompartDiskOpcao -Maximo 0) }
        return 1
    }

    Write-Color ("  Serao instalados {0} de {1} itens. Os demais permanecem como estao." -f $pendentes.Count, $Aplicativos.Count) -Color Gray
    Write-Color ''
    Write-Color '  [1] Confirmar instalacao' -Color Cyan
    Write-Color '  [0] Cancelar' -Color DarkGray
    Write-Color ''

    if (Test-ModoInterativo) {
        $opc = Read-CompartDiskOpcao -Maximo 1
        if ($opc -ne 1) {
            Write-Log INFO 'Instalacao em lote cancelada pelo operador. Nada foi alterado.'
            return 1
        }
    }

    $registros = Invoke-AppsLote -Aplicativos $pendentes.ToArray() -Titulo ('Instalacao em lote - {0}' -f $Categoria)
    Write-AppsResumo -Registros $registros | Out-Null
    Add-AppsRelatorio -Registros $registros -Titulo ('Instalacao em lote - {0}' -f $Categoria)
    Set-ResultadoModulo -Registros $registros
    return (Show-AppsAposLote)
}

function Get-EstadoApp {
    <# Estado atual de um item, para as telas de confirmacao e de verificacao. #>
    param([object]$App)

    if ($App.Native) {
        return [pscustomobject]@{ Rotulo = 'Recurso nativo do Windows'; Cor = [ConsoleColor]::Cyan; Instalavel = $false; Version = ''; Available = '' }
    }
    if (-not $App.Available -or [string]::IsNullOrWhiteSpace($App.Id)) {
        return [pscustomobject]@{ Rotulo = 'Nao disponivel via WinGet'; Cor = [ConsoleColor]::Yellow; Instalavel = $false; Version = ''; Available = '' }
    }

    $ctx = Get-WingetContexto
    if (-not $ctx.Available) {
        return [pscustomobject]@{ Rotulo = 'winget indisponivel'; Cor = [ConsoleColor]::Red; Instalavel = $false; Version = ''; Available = '' }
    }

    if ($App.SuiteId) {
        $vs = Get-WingetInstalledVersion -Id $App.SuiteId
        if ($vs) {
            return [pscustomobject]@{ Rotulo = ('Ja atendido pela Sysinternals Suite ({0})' -f $vs); Cor = [ConsoleColor]::DarkGray; Instalavel = $false; Version = $vs; Available = '' }
        }
    }

    $r = Invoke-WingetComando -Arguments (@('list', '--id', $App.Id, '--exact') + (Get-WingetArgsComuns)) -TimeoutSeconds 180
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Rotulo = 'Nao instalado'; Cor = [ConsoleColor]::Gray; Instalavel = $true; Version = ''; Available = '' }
    }
    $dados = Get-WingetLinhaPacote -Texto $r.StdOut -Id $App.Id
    $versao = 'n/d'
    $disp   = ''
    if ($dados) {
        if ($dados.Version)   { $versao = $dados.Version }
        if ($dados.Available) { $disp   = $dados.Available }
    }
    $rotulo = ('Instalado - {0}' -f $versao)
    if ($disp) { $rotulo += (' (atualizacao disponivel: {0})' -f $disp) }
    return [pscustomobject]@{ Rotulo = $rotulo; Cor = [ConsoleColor]::DarkGray; Instalavel = $false; Version = $versao; Available = $disp }
}

function Show-MenuInstalar {
    <# Menu principal da area de instalacao. As categorias e a numeracao derivam
       do catalogo: acrescentar uma categoria nao exige mexer neste codigo. #>
    $cats = Get-AppsCategorias
    $nTodos = $cats.Count + 1
    $nVer   = $cats.Count + 2

    while ($true) {
        Write-AppsCabecalho 'INSTALAR APLICATIVOS'
        for ($i = 0; $i -lt $cats.Count; $i++) {
            $qtd = (Get-AppsPorCategoria -Categoria $cats[$i]).Count
            Write-Color ("  [{0}] {1}" -f ($i + 1), $cats[$i]) -Color Cyan -NoNewLine
            Write-Color ("   ({0} aplicativo(s))" -f $qtd) -Color DarkGray
        }
        Write-Color ("  [{0}] Instalar todos os aplicativos" -f $nTodos) -Color Cyan
        Write-Color ("  [{0}] Ver aplicativos instalados" -f $nVer) -Color Cyan
        Write-Color '  [0] Voltar' -Color DarkGray
        Write-Color ''

        if (-not (Test-ModoInterativo)) { return }
        $opc = Read-CompartDiskOpcao -Maximo $nVer
        if ($opc -eq 0) { return }
        if ($opc -eq $nTodos) { Invoke-InstalarTodos; continue }
        if ($opc -eq $nVer)   { Show-AppsInstalados; continue }
        Show-MenuCategoria -Categoria $cats[$opc - 1]
    }
}

function Invoke-InstalarTodos {
    <# [Instalar todos os aplicativos]: lista tudo, confirma com [1], e so entao
       executa. Itens ja instalados sao ignorados durante a execucao. #>
    Write-AppsCabecalho 'INSTALAR TODOS OS APLICATIVOS'

    foreach ($cat in (Get-AppsCategorias)) {
        $apps = Get-AppsPorCategoria -Categoria $cat
        if ($apps.Count -eq 0) { continue }
        Write-Color ("  {0}" -f $cat) -Color White
        foreach ($a in $apps) {
            Write-Color ("  - {0}" -f $a.Name) -Color Gray -NoNewLine
            if ($a.Native)         { Write-Color '   (recurso nativo do Windows)' -Color Cyan }
            elseif (-not $a.Available) { Write-Color '   (nao disponivel via WinGet)' -Color Yellow }
            else                   { Write-Color '' }
        }
        Write-Color ''
    }

    Write-Color '  Aplicativos ja instalados sao ignorados automaticamente.' -Color DarkGray
    Write-Color '  Esta operacao NAO atualiza o que ja esta instalado.' -Color DarkGray
    Write-Color ''
    Write-Color '  [1] Confirmar instalacao completa' -Color Cyan
    Write-Color '  [0] Cancelar' -Color DarkGray
    Write-Color ''

    if (Test-ModoInterativo) {
        $opc = Read-CompartDiskOpcao -Maximo 1
        if ($opc -ne 1) {
            Write-Log INFO 'Instalacao completa cancelada pelo operador. Nada foi alterado.'
            return
        }
    }

    $todos = @(Get-AppsCatalogo)
    $registros = Invoke-AppsLote -Aplicativos $todos -Titulo 'Instalacao de todos os aplicativos'
    Write-AppsResumo -Registros $registros | Out-Null
    Add-AppsRelatorio -Registros $registros -Titulo 'Instalacao de todos os aplicativos'
    Set-ResultadoModulo -Registros $registros
    [void](Show-AppsAposLote)
}

function Show-AppsInstalados {
    <# [Ver aplicativos instalados]: estado atual de cada item do catalogo. #>
    Write-AppsCabecalho 'APLICATIVOS INSTALADOS'

    $ctx = Get-WingetContexto
    if (-not $ctx.Available) {
        Show-WingetIndisponivel
        return
    }

    Write-Color ("  Consultando {0} aplicativos do catalogo..." -f (Get-AppsCatalogo).Count) -Color DarkGray
    Write-Color ''

    $linhas = New-Object System.Collections.ArrayList
    $n = 0
    $instalados = 0
    foreach ($cat in (Get-AppsCategorias)) {
        $apps = Get-AppsPorCategoria -Categoria $cat
        if ($apps.Count -eq 0) { continue }
        Write-Color ("  {0}" -f $cat) -Color White
        foreach ($app in $apps) {
            $n++
            $estado = Get-EstadoApp -App $app
            Write-Color ("  [{0}] {1}" -f $n, $app.Name) -Color Cyan
            Write-Color ("      {0}" -f $estado.Rotulo) -Color $estado.Cor
            if ($estado.Version -and $estado.Version -ne '' -and -not $app.Native -and $app.Available) { $instalados++ }
            [void]$linhas.Add([pscustomobject]@{
                Aplicativo = $app.Name
                Categoria  = $app.Category
                Pacote     = $(if ($app.Id) { $app.Id } else { 'n/d' })
                Instalado  = $(if ($estado.Version) { $estado.Version } else { 'nao' })
                Disponivel = $(if ($estado.Available) { $estado.Available } else { 'n/d' })
                Status     = $estado.Rotulo
            })
        }
        Write-Color ''
    }

    Write-Color ("  {0} de {1} itens do catalogo presentes no sistema." -f $instalados, $n) -Color Gray
    Add-CompartDiskSection -Title 'Catalogo de aplicativos - estado atual' -Status INFO -Rows @($linhas) -Summary (
        '{0} de {1} itens presentes no sistema.' -f $instalados, $n)

    Write-Color ''
    Write-Color '  [0] Voltar' -Color DarkGray
    Write-Color ''
    if (Test-ModoInterativo) { [void](Read-CompartDiskOpcao -Maximo 0) }
}

# ------------------------------------------------------------------------------
# CENTRAL DE APLICATIVOS - telas
# ------------------------------------------------------------------------------
# Mesma gramatica das demais telas do modulo: cabecalho do Core e opcoes entre
# colchetes. A navegacao da Central tem tecla FIXA em TODAS as telas - [P] nova
# pesquisa, [V] voltar -, e os numeros ficam so para escolher aplicativo, onde
# ha lista. Read-CentralOpcao e o ponto unico dessa regra. A unica coisa digitada
# em toda a Central e o nome do aplicativo procurado - e ele nunca vira comando.
# ------------------------------------------------------------------------------
# Quantos resultados cabem na tela: 8 itens, cada um escolhido por uma tecla so.
$script:CentralMaxResultados = 8

function Read-CentralOpcao {
    <# Leitor UNICO das telas da Central: a mesma regra vale em TODOS os estados,
       com ou sem resultados.

           [P] nova pesquisa   [V] voltar   [1..Maximo] escolher aplicativo

       A navegacao tem tecla FIXA porque a quantidade de resultados muda a cada
       pesquisa - preso a numero, o "nova pesquisa" mudava de lugar junto. Os
       numeros ficam so para escolher aplicativo, e so onde ha lista: com
       -Maximo 0 (telas sem resultado) apenas [P] e [V] sao aceitos.

       A TECLA continua sendo lida pelo Core (Read-CompartDiskEntradaOpcao), com
       o mesmo comportamento de CHOICE do restante da ferramenta: so a validacao
       e local, porque estas sao as unicas telas do modulo em que letra e escolha
       valida. Entrada invalida e recusada e a tela volta a perguntar, como em
       Read-CompartDiskOpcao.

       Devolve 'P', 'V' ou o numero escolhido, sempre como texto. #>
    [CmdletBinding()]
    param([int]$Maximo = 0, [string]$Rotulo = '  Escolha')
    while ($true) {
        $entrada = Read-CompartDiskEntradaOpcao -Maximo $Maximo -Rotulo $Rotulo
        if ($null -eq $entrada) { return 'V' }
        $entrada = $entrada.Trim()
        if ($entrada -eq '') { continue }
        # -eq de string no PowerShell nao diferencia caixa: 'p' e 'v' entram aqui.
        if ($entrada -eq 'P') { return 'P' }
        if ($entrada -eq 'V') { return 'V' }
        if ($Maximo -lt 1) {
            Write-Color '  Use [P] para nova pesquisa ou [V] para voltar.' -Color Yellow
            continue
        }
        if ($entrada.Length -gt 3 -or $entrada -notmatch '^\d+$') {
            Write-Color '  Use o número de um resultado, [P] para nova pesquisa ou [V] para voltar.' -Color Yellow
            continue
        }
        $n = [int]$entrada
        if ($n -lt 1 -or $n -gt $Maximo) {
            Write-Color ("  Opção inválida. Informe de 1 a {0}, [P] para nova pesquisa ou [V] para voltar." -f $Maximo) -Color Yellow
            continue
        }
        return ([string]$n)
    }
}

function Read-AppsTermoPesquisa {
    <# Le e higieniza o nome procurado. Texto vazio significa voltar. #>
    [CmdletBinding()] param()
    $bruto = ''
    try { $bruto = Read-Host '  Aplicativo' } catch { return '' }
    return (Get-AppsTermoSeguro -Texto $bruto)
}

function Show-CentralPesquisa {
    <# Tela inicial: uma pergunta so, em linguagem de quem nao conhece o winget. #>
    Write-AppsCabecalho 'CENTRAL DE APLICATIVOS'
    Write-Color '  Digite o nome do aplicativo que você quer instalar.' -Color Gray
    Write-Color '  Não precisa acertar o nome exato: "crome", "7 zip" e "vs code" funcionam.' -Color DarkGray
    Write-Color ''
    Write-Color '  Deixe em branco e tecle Enter para sair da pesquisa.' -Color DarkGray
    Write-Color ''
    if (-not (Test-ModoInterativo)) { return '' }
    return (Read-AppsTermoPesquisa)
}

function Show-CentralTermoVazio {
    <# Enter sem termo. Pesquisar seria consulta inutil e uma tela vazia nao
       ensina nada: diz o que fazer e deixa escolher. $true = pesquisar de novo. #>
    Write-AppsCabecalho 'CENTRAL DE APLICATIVOS'
    Write-Color '  Digite o nome ou parte do nome do aplicativo.' -Color Yellow
    Write-Color '  Exemplos: chrome, 7 zip, vs code, vlc.' -Color DarkGray
    Write-Color ''
    Write-Color '  [P] Nova pesquisa' -Color Cyan
    Write-Color '  [V] Voltar' -Color DarkGray
    Write-Color ''
    if (-not (Test-ModoInterativo)) { return $false }
    return ((Read-CentralOpcao) -eq 'P')
}

function Write-CentralItem {
    <# Uma entrada da lista: numero, nome e, abaixo, editor e pacote. E o que o
       operador precisa para distinguir dois homonimos sem virar tela tecnica. #>
    param([int]$Numero, [object]$Item)
    Write-Color ("  [{0}] {1}" -f $Numero, $Item.Name) -Color Cyan
    Write-Color ("      {0}   |   {1}" -f $Item.Publisher, $Item.Id) -Color DarkGray
}

function Show-CentralSemResultado {
    <# Nenhum resultado. Distingue "nao existe com esse nome" de "nao deu para
       consultar": sem rede a fonte oficial nao responde, e dizer que o
       aplicativo nao existe seria falso. Devolve $true para pesquisar de novo. #>
    param([string]$Termo)

    Write-AppsCabecalho 'CENTRAL DE APLICATIVOS'
    Write-Color ("  Pesquisa: {0}" -f $Termo) -Color Gray
    Write-Color ''
    $net = $null
    try { $net = Test-InternetCache } catch { }
    if ($net -and -not $net.Online) {
        Write-Log WARN 'Nao foi possivel consultar a fonte oficial: sem conectividade.'
        Write-Color '  Verifique a conexão com a internet e tente novamente.' -Color DarkGray
    } else {
        Write-Log WARN ("Nenhum aplicativo encontrado para: {0}" -f $Termo)
        Write-Color '  Tente escrever de outra forma ou use apenas parte do nome.' -Color DarkGray
    }
    Write-Color '  Nenhuma alteração foi realizada.' -Color DarkGray
    Write-Color ''
    Write-Color '  [P] Nova pesquisa' -Color Cyan
    Write-Color '  [V] Voltar' -Color DarkGray
    Write-Color ''
    if (-not (Test-ModoInterativo)) { return $false }
    return ((Read-CentralOpcao) -eq 'P')
}

function Show-CentralResultados {
    <# Lista classificada. Os numeros sao dos aplicativos - [1..N] -, e a
       navegacao tem tecla fixa: [P] nova pesquisa e [V] voltar. Preso a numero,
       o "nova pesquisa" mudava de lugar a cada pesquisa; assim nao muda.

       Os itens sao separados em "melhores" e "relacionados" quando a distancia
       de pontuacao justifica: agrupar ajuda o operador a ver de imediato o que
       responde ao que ele pediu. Nada e escondido - a numeracao e continua e
       todo resultado do winget continua na tela. #>
    param([string]$Termo, [object[]]$Resultados, [int]$Total = 0)

    Write-AppsCabecalho 'CENTRAL DE APLICATIVOS'
    Write-Color ("  Pesquisa: {0}" -f $Termo) -Color Gray
    Write-Color ''

    # O corte e a QUALIDADE da correspondencia, nao uma janela de pontos: um
    # bonus grande num item so nao pode empurrar todo o resto para "relacionados".
    # Como a lista ja vem ordenada e todo item em destaque pontua acima dos
    # demais, os destaques ocupam o inicio.
    $melhores = 0
    while ($melhores -lt $Resultados.Count -and $Resultados[$melhores].Destaque) { $melhores++ }
    $separar = ($melhores -gt 0 -and $melhores -lt $Resultados.Count)

    Write-Color $(if ($separar) { '  Melhores resultados:' } else { '  Resultados encontrados:' }) -Color White
    Write-Color ''
    for ($i = 0; $i -lt $Resultados.Count; $i++) {
        if ($separar -and $i -eq $melhores) {
            Write-Color ''
            Write-Color '  Mais resultados relacionados:' -Color White
            Write-Color ''
        }
        Write-CentralItem -Numero ($i + 1) -Item $Resultados[$i]
    }

    Write-Color ''
    if ($Total -gt $Resultados.Count) {
        Write-Color ("  Exibindo os {0} resultados mais relevantes de {1} encontrados." -f $Resultados.Count, $Total) -Color DarkGray
        Write-Color '  Refine a pesquisa para encontrar um aplicativo específico.' -Color DarkGray
        Write-Color ''
    }
    Write-Color '  [P] Nova pesquisa' -Color Cyan
    Write-Color '  [V] Voltar' -Color DarkGray
    Write-Color ''

    if (-not (Test-ModoInterativo)) { return [pscustomobject]@{ Acao = 'Voltar'; Item = $null } }
    $opc = Read-CentralOpcao -Maximo $Resultados.Count
    if ($opc -eq 'V') { return [pscustomobject]@{ Acao = 'Voltar'; Item = $null } }
    if ($opc -eq 'P') { return [pscustomobject]@{ Acao = 'Nova';   Item = $null } }
    return [pscustomobject]@{ Acao = 'Instalar'; Item = $Resultados[[int]$opc - 1] }
}

function Show-CentralParada {
    <# Parada de leitura antes de a proxima tela limpar o console. Segue a mesma
       regra de navegacao das demais telas da Central: [V] volta para a lista de
       resultados. Nao ha numero aqui - nao ha o que escolher. #>
    Write-Color '  [V] Voltar' -Color DarkGray
    Write-Color ''
    if (Test-ModoInterativo) { [void](Read-CentralOpcao) }
}

function Invoke-CentralInstalacao {
    <# Confirma e instala UM resultado da pesquisa.

       A instalacao em si e a mesma de todo o modulo (Invoke-AppInstalacao):
       confirma o identificador na fonte oficial, instala pelo ID exato e so
       entao verifica o estado final consultando o sistema. Aqui ficam apenas a
       conferencia previa de "ja instalado" e a confirmacao do operador. #>
    [CmdletBinding()] param([Parameter(Mandatory)][object]$Item)

    Write-AppsCabecalho 'INSTALAR APLICATIVO'

    # Barreira final: nenhum texto que nao tenha forma de identificador do winget
    # chega a linha de comando de instalacao.
    if (-not (Test-AppsIdentificadorPacote $Item.Id)) {
        Write-Log WARN 'O identificador deste resultado nao pode ser validado. Nenhuma instalacao foi tentada.'
        Write-Color '  Nenhuma alteração foi realizada.' -Color DarkGray
        Write-Color ''
        Show-CentralParada
        return
    }

    Write-CompartDiskKeyValue 'Aplicativo' $Item.Name      -Pad 12
    Write-CompartDiskKeyValue 'Editor'     $Item.Publisher -Pad 12
    Write-CompartDiskKeyValue 'Pacote'     $Item.Id        -Pad 12
    if ($Item.PSObject.Properties['Version'] -and $Item.Version) {
        Write-CompartDiskKeyValue 'Versão'   $Item.Version   -Pad 12
    }
    Write-CompartDiskKeyValue 'Fonte'      'winget (fonte oficial da Microsoft)' -Pad 12
    Write-Color ''

    # Instalar o que ja existe seria trabalho perdido: como o restante do modulo,
    # a Central instala apenas o que estiver ausente e nunca atualiza.
    Write-Color '  Verificando se já está instalado...' -Color DarkGray
    $versao = $null
    try { $versao = Get-WingetInstalledVersion -Id $Item.Id } catch { }
    if ($versao) {
        Write-Color ''
        Write-Log OK ("{0} ja esta instalado neste computador." -f $Item.Name)
        if ($versao -ne 'n/d') { Write-Color ("       Versão instalada: {0}" -f $versao) -Color DarkGray }
        Write-Color '       Para atualizar o que já está instalado, use a opção [3] Atualizar' -Color DarkGray
        Write-Color '       aplicativos (WinGet), no menu Aplicativos.' -Color DarkGray
        Write-Log INFO ("Central: {0} [{1}] ja instalado - nada a fazer." -f $Item.Name, $Item.Id) -NoConsole
        Write-Color ''
        Show-CentralParada
        return
    }

    Write-Color ''
    Write-Color '  Deseja instalar este aplicativo?' -Color White
    Write-Color ''
    Write-Color '  [1] Sim, instalar' -Color Cyan
    Write-Color '  [0] Não, cancelar' -Color DarkGray
    Write-Color ''
    if (Test-ModoInterativo) {
        if ((Read-CompartDiskOpcao -Maximo 1) -ne 1) {
            Write-Log INFO ("Instalacao cancelada pelo operador: {0}. Nada foi alterado." -f $Item.Name)
            Write-Color ''
            Show-CentralParada
            return
        }
    }

    Write-Color ''
    Write-Log INFO ("Instalando {0}..." -f $Item.Name)
    Write-Log INFO ("Central: instalacao solicitada - {0} [{1}] | fonte winget" -f $Item.Name, $Item.Id) -NoConsole

    $reg = Invoke-AppInstalacao -App (New-AppsItemCentral -Item $Item)
    [void]$script:Registros.Add($reg)

    Write-Color ''
    Write-ResultadoIndividual -Registro $reg
    if ($reg.Status -ne 'INSTALADO' -and $reg.Status -ne 'JA INSTALADO' -and $reg.Status -ne 'REINICIALIZACAO NECESSARIA') {
        Write-Color '  Nenhuma alteração adicional foi realizada.' -Color DarkGray
        Write-Color ''
    }

    Add-AppsRelatorio -Registros @($reg) -Titulo ('Central de aplicativos - {0}' -f $Item.Name)
    Set-ResultadoModulo -Registros @($reg)
    Write-Log INFO ("Central: {0} [{1}] -> {2} {3} {4}" -f $Item.Name, $Item.Id, $reg.Status, $reg.Code, $reg.Message) -NoConsole

    Show-CentralParada
}

function Show-CentralAplicativos {
    <# Fluxo completo: pesquisar, escolher, confirmar, instalar. Depois de
       instalar, a lista de resultados volta - da para instalar mais de um item
       da mesma pesquisa sem repetir a consulta. #>
    while ($true) {
        $termo = Show-CentralPesquisa
        if ([string]::IsNullOrWhiteSpace($termo)) {
            if (Show-CentralTermoVazio) { continue }
            return
        }

        Write-Color ''
        Write-Color '  Procurando na fonte oficial do WinGet...' -Color DarkGray
        Write-Log INFO ("Central de aplicativos: termo pesquisado '{0}'." -f $termo) -NoConsole

        $encontrados = @()
        try {
            $encontrados = @(Get-AppsPesquisa -Termo $termo)
        } catch {
            Write-Log ERR 'Nao foi possivel concluir a pesquisa de aplicativos.' -ErrorRecord $_ -NoConsole
            $encontrados = @()
        }

        if ($encontrados.Count -eq 0) {
            Write-Log INFO ("Central: nenhum resultado para '{0}'." -f $termo) -NoConsole
            if (-not (Show-CentralSemResultado -Termo $termo)) { return }
            continue
        }

        # A classificacao ja aconteceu: aqui so cabe o que entra na tela. Uma
        # pesquisa de uma letra devolve centenas de itens e nao pode despejar
        # tudo no console nem exigir rolagem para escolher.
        $resultados = @($encontrados | Select-Object -First $script:CentralMaxResultados)

        Write-Log INFO ("Central: {0} resultado(s) para '{1}' | exibidos: {2} | melhor: {3}" -f `
            $encontrados.Count, $termo, $resultados.Count, $resultados[0].Id) -NoConsole

        $novaPesquisa = $false
        while (-not $novaPesquisa) {
            $escolha = Show-CentralResultados -Termo $termo -Resultados $resultados -Total $encontrados.Count
            switch ($escolha.Acao) {
                'Voltar'   { return }
                'Nova'     { $novaPesquisa = $true }
                'Instalar' { Invoke-CentralInstalacao -Item $escolha.Item }
            }
        }
    }
}

function Set-ResultadoModulo {
    <# Classificacao do modulo: falha parcial e WARN; falha total e ERROR. #>
    param([object[]]$Registros)
    $s = Get-AppsResumo -Registros $Registros
    if ($s.Total -eq 0) { return }
    if ($s.Falhas -eq 0) {
        if ($script:result -eq 'OK' -and $s.Reinicializar -gt 0) { $script:result = 'WARN' }
        return
    }
    if ($s.Falhas -eq $s.Total) { $script:result = 'ERROR'; return }
    if ($script:result -ne 'ERROR') { $script:result = 'WARN' }
}

# ------------------------------------------------------------------------------
# EXECUCAO
# ------------------------------------------------------------------------------
try {
    if (-not (Start-CompartDiskModule -Name 'Apps' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }

    $ctx = Get-WingetContexto
    if (-not $ctx.Available) {
        # Diagnostico estruturado do Core: distingue ausente, quebrado, bloqueado
        # por politica e Windows incompativel - o log deixa de dizer so "ausente".
        $amb = $null
        try { $amb = Test-WingetAvailability } catch { }
        if ($amb) {
            Write-Log ERR ('Winget indisponivel ({0}). {1}' -f $amb.State, $amb.Reason)
        } else {
            Write-Log ERR 'Winget ausente ou indisponivel neste sistema. A instalacao de aplicativos nao pode continuar.'
        }
        Write-Log WARN 'Use a opcao [1] Verificar / preparar WinGet, no menu Aplicativos.'
        Add-CompartDiskFinding -Severity WARN -Area 'Aplicativos' -Message ('Winget indisponivel ({0}): instalacao de aplicativos nao executada.' -f $(if ($amb) { $amb.State } else { 'desconhecido' })) -Recommendation 'Usar a opcao [1] Verificar / preparar WinGet no menu de aplicativos.'
        if (Test-ModoInterativo) { Show-WingetIndisponivel }
        $codigo = Stop-CompartDiskModule -Result 'UNSUPPORTED' -Message 'Winget indisponivel' -Quiet:$Quiet
        exit $codigo
    }

    Write-Log INFO ("Winget detectado: {0}" -f $ctx.VersionText) -NoConsole
    if (-not (Test-Administrator)) {
        Write-Log WARN 'Execucao sem privilegio administrativo: pacotes de escopo de maquina podem solicitar elevacao ou falhar.'
    }
    [void](Test-WingetFonte)

    switch ($Action) {

        'Menu' {
            if (-not (Test-ModoInterativo)) {
                # Determinismo em execucao desassistida: nenhum prompt e nenhuma
                # instalacao implicita. As acoes automatizaveis sao Install,
                # InstallCategory, InstallAll e List.
                Write-Log WARN 'Acao Menu exige console interativo. Em automacao use -Action Install/-InstallCategory/-InstallAll/-List.'
                $result = 'UNSUPPORTED'
                break
            }
            Show-MenuInstalar
        }

        'Install' {
            $app = Resolve-AppPorId -Identificador $Id
            if (-not $app) {
                Write-Log ERR ("Aplicativo '{0}' nao pertence ao catalogo do COMPARTDISK. Nenhuma instalacao foi tentada." -f $Id)
                $result = 'ERROR'
                break
            }
            Write-Log INFO ("Instalacao solicitada: {0} [{1}]" -f $app.Name, $app.Id)
            $reg = Invoke-AppInstalacao -App $app
            [void]$script:Registros.Add($reg)
            Write-ResultadoIndividual -Registro $reg
            Add-AppsRelatorio -Registros @($reg) -Titulo ('Instalacao de aplicativo - {0}' -f $app.Name)
            Set-ResultadoModulo -Registros @($reg)
        }

        'InstallCategory' {
            $cat = Resolve-Categoria -Nome $Category
            if (-not $cat) {
                Write-Log ERR ("Categoria '{0}' inexistente. Categorias validas: {1}" -f $Category, ((Get-AppsCategorias) -join ', '))
                $result = 'ERROR'
                break
            }
            $apps = Get-AppsPorCategoria -Categoria $cat
            if ($apps.Count -eq 0) {
                Write-Log WARN ("A categoria '{0}' nao possui aplicativos cadastrados." -f $cat)
                $result = 'UNSUPPORTED'
                break
            }
            if (Test-ModoInterativo) {
                Invoke-LoteCategoria -Categoria $cat -Aplicativos $apps
            } else {
                $registros = Invoke-AppsLote -Aplicativos $apps -Titulo ('Instalacao em lote - {0}' -f $cat)
                Write-AppsResumo -Registros $registros | Out-Null
                Add-AppsRelatorio -Registros $registros -Titulo ('Instalacao em lote - {0}' -f $cat)
                Set-ResultadoModulo -Registros $registros
            }
        }

        'InstallAll' {
            if (Test-ModoInterativo) {
                Invoke-InstalarTodos
            } else {
                $registros = Invoke-AppsLote -Aplicativos @(Get-AppsCatalogo) -Titulo 'Instalacao de todos os aplicativos'
                Write-AppsResumo -Registros $registros | Out-Null
                Add-AppsRelatorio -Registros $registros -Titulo 'Instalacao de todos os aplicativos'
                Set-ResultadoModulo -Registros $registros
            }
        }

        'List' { Show-AppsInstalados }

        'Central' {
            if (-not (Test-ModoInterativo)) {
                # A Central e uma pesquisa conduzida por um operador: sem console nao
                # ha o que perguntar nem o que confirmar, e instalar por conta propria
                # seria acao implicita. As acoes automatizaveis continuam sendo
                # Install, InstallCategory, InstallAll e List.
                Write-Log WARN 'Acao Central exige console interativo. Em automacao use -Action Install/-InstallCategory/-InstallAll/-List.'
                $result = 'UNSUPPORTED'
                break
            }
            Show-CentralAplicativos
        }
    }

} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Apps (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Aplicativos' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
