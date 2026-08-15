<#
 COMPARTDISK 1.4.3 - Apps.ps1
 Desenvolvido por Edsilas
 Instalacao de aplicativos de suporte tecnico pelo gerenciador de pacotes do
 Windows (winget), a partir de um catalogo declarativo.
 Acoes: Menu | Install | InstallCategory | InstallAll | List

 ESCOPO DESTE MODULO: instalar o que esta AUSENTE.
 A ATUALIZACAO de programas continua sendo a rotina :MOD_WINGET do Launcher.bat,
 acessivel pela opcao [1] do menu APLICATIVOS. Ela nao e reimplementada aqui:
 uma capacidade, um dono. Este modulo nunca chama "winget upgrade".

 CATALOGO: todos os identificadores foram conferidos em 14/08/2026 contra o
 indice oficial da fonte "winget" (cdn.winget.microsoft.com/cache/source2.msix)
 e contra os manifestos publicados em microsoft/winget-pkgs. Nenhum ID foi
 inferido, e nenhum aplicativo sem pacote oficial recebeu URL substituta.
 Os identificadores de TeamViewer, 7-Zip e Rufus foram conferidos em 15/08/2026
 contra os manifestos publicados em microsoft/winget-pkgs.

 Antes de instalar, Get-WingetPackage confirma o ID na fonte oficial: um ID que
 nao exista mais e reportado como NAO ENCONTRADO, nunca substituido por outro.

 Toda a interacao deste modulo e NUMERICA. Nenhuma tecla de letra e aceita para
 escolher, confirmar, cancelar ou voltar.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Install', 'InstallCategory', 'InstallAll', 'List')]
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
# Estado de sessao (cache) - evita repetir consultas caras no mesmo lote
# ------------------------------------------------------------------------------
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
    param([string]$Titulo)
    Write-Color ''
    Write-Color ("  {0}" -f $Titulo) -Color White
    Write-Color ("  " + ('-' * 74)) -Color DarkGray
    Write-Color ''
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
    Write-Color '  No menu Aplicativos, a opcao [3] Verificar / preparar WinGet diagnostica o' -Color Gray
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
        Write-Log WARN 'Use a opcao [3] Verificar / preparar WinGet, no menu Aplicativos.'
        Add-CompartDiskFinding -Severity WARN -Area 'Aplicativos' -Message ('Winget indisponivel ({0}): instalacao de aplicativos nao executada.' -f $(if ($amb) { $amb.State } else { 'desconhecido' })) -Recommendation 'Usar a opcao [3] Verificar / preparar WinGet no menu de aplicativos.'
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
    }

} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Apps (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Aplicativos' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
