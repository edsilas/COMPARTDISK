<#
 COMPARTDISK - Inicializador de execucao remota
 DESENVOLVIDO POR EDSILAS

 Baixa e executa sempre a versao estavel mais recente do COMPARTDISK, sem
 instalacao e sem download manual.

     irm https://raw.githubusercontent.com/edsilas/compartdisk/main/remote.ps1 | iex

 Este arquivo e APENAS um metodo adicional de inicializacao. Ele nao altera,
 substitui nem contorna nenhum fluxo do projeto: ao final, executa o mesmo
 Launcher.bat da distribuicao oficial, com os mesmos menus e modulos.

 Observacoes de implementacao:
 - Executado por "irm | iex", o script nao possui $PSScriptRoot nem parametros
   de linha de comando. Por isso a configuracao vem de variaveis de ambiente.
 - O PowerShell 5.1 do Windows 10 pode negociar TLS 1.0 por padrao, o que faz o
   GitHub recusar a conexao. O protocolo e forcado antes de qualquer requisicao.
#>

#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # acelera muito o Invoke-WebRequest

# ==============================================================================
# CONFIGURACAO
# Sobrescrevivel por variavel de ambiente, para uso corporativo com espelho
# interno ou versao fixada.
# ==============================================================================
$Repo    = if ($env:COMPARTDISK_REPO)  { $env:COMPARTDISK_REPO }  else { 'edsilas/compartdisk' }
$TagFixa = if ($env:COMPARTDISK_TAG)   { $env:COMPARTDISK_TAG }   else { $null }
$Origem  = "https://github.com/$Repo"
$ApiBase = "https://api.github.com/repos/$Repo"

# ==============================================================================
# APRESENTACAO
# ==============================================================================
function Write-Linha {
    param([string]$Texto = '', [string]$Cor = 'Gray')
    if ($Texto) { Write-Host $Texto -ForegroundColor $Cor } else { Write-Host '' }
}
function Write-Marcador {
    param(
        [ValidateSet('OK', 'WARN', 'ERRO', 'INFO')][string]$Nivel,
        [string]$Mensagem
    )
    $mapa = @{
        'OK'   = @{ Tag = '[ OK ]'; Cor = 'Green'  }
        'WARN' = @{ Tag = '[WARN]'; Cor = 'Yellow' }
        'ERRO' = @{ Tag = '[ERRO]'; Cor = 'Red'    }
        'INFO' = @{ Tag = '[INFO]'; Cor = 'DarkGray' }
    }
    Write-Host ('  ' + $mapa[$Nivel].Tag) -ForegroundColor $mapa[$Nivel].Cor -NoNewline
    Write-Host (' ' + $Mensagem) -ForegroundColor Gray
}

function Write-Cabecalho {
    Write-Linha
    Write-Host '  COMPARTDISK' -ForegroundColor White -NoNewline
    Write-Host '  execucao remota' -ForegroundColor DarkGray
    Write-Linha ('  ' + ('-' * 66)) DarkGray
    Write-Linha
    Write-Host '  Origem   ' -ForegroundColor DarkGray -NoNewline
    Write-Host $Origem -ForegroundColor Gray
    Write-Host '  Autoria  ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'DESENVOLVIDO POR EDSILAS' -ForegroundColor Gray
    Write-Linha
}

# ==============================================================================
# REDE
# ==============================================================================
function Initialize-Tls {
    <# O PowerShell 5.1 herda o padrao do .NET, que em Windows 10 pode ser TLS
       1.0. O GitHub exige 1.2 ou superior. Sem isto a conexao e recusada com
       uma mensagem generica de "conexao subjacente fechada". #>
    try {
        $alvo = [Net.SecurityProtocolType]::Tls12
        if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
            $alvo = $alvo -bor [Net.SecurityProtocolType]::Tls13
        }
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor $alvo
    } catch {
        Write-Marcador WARN 'Nao foi possivel ajustar o protocolo TLS. Prosseguindo.'
    }
}

function Test-Conectividade {
    try {
        $r = Invoke-WebRequest -Uri 'https://api.github.com' -Method Head `
                               -UseBasicParsing -TimeoutSec 15
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch { return $false }
}

function Invoke-ComRetentativa {
    <# Falhas de rede momentaneas sao comuns. Tres tentativas com espera
       progressiva evitam abortar por um soluco de conexao. #>
    param(
        [Parameter(Mandatory)][scriptblock]$Acao,
        [int]$Tentativas = 3,
        [string]$Descricao = 'operacao'
    )
    for ($i = 1; $i -le $Tentativas; $i++) {
        try { return & $Acao }
        catch {
            if ($i -eq $Tentativas) { throw }
            $espera = $i * 2
            Write-Marcador WARN "Falha ao $Descricao (tentativa $i de $Tentativas). Nova tentativa em ${espera}s."
            Start-Sleep -Seconds $espera
        }
    }
}

# ==============================================================================
# DESCOBERTA DA VERSAO
# ==============================================================================
function Get-HashPublicado {
    <# As notas da release publicam o SHA-256 do pacote. Extrai-lo permite
       validar a integridade sem exigir arquivo adicional no repositorio. #>
    param([AllowNull()][string]$Corpo)
    if (-not $Corpo) { return $null }
    $m = [regex]::Match($Corpo, '(?im)SHA-?256\s*[:\s]\s*([0-9a-f]{64})')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Get-VersaoMaisRecente {
    <# Consulta a release estavel mais recente. Pre-releases sao ignoradas pelo
       endpoint /releases/latest, que e exatamente o comportamento desejado. #>
    $url = if ($TagFixa) { "$ApiBase/releases/tags/$TagFixa" } else { "$ApiBase/releases/latest" }

    $dados = Invoke-ComRetentativa -Descricao 'consultar a versao mais recente' -Acao {
        Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{
            'Accept'     = 'application/vnd.github+json'
            'User-Agent' = 'COMPARTDISK-Bootstrap'
        }
    }

    $asset = $dados.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1

    [pscustomobject]@{
        Tag       = $dados.tag_name
        Nome      = $dados.name
        Publicado = $dados.published_at
        Url       = if ($asset) { $asset.browser_download_url } else { $dados.zipball_url }
        Arquivo   = if ($asset) { $asset.name } else { "compartdisk-$($dados.tag_name).zip" }
        Tamanho   = if ($asset) { $asset.size } else { 0 }
        Hash      = Get-HashPublicado -Corpo $dados.body
        TemAsset  = [bool]$asset
    }
}

# ==============================================================================
# DOWNLOAD E VALIDACAO
# ==============================================================================
function Get-Pacote {
    param([Parameter(Mandatory)]$Versao, [Parameter(Mandatory)][string]$Destino)

    Invoke-ComRetentativa -Descricao 'baixar o pacote' -Acao {
        Invoke-WebRequest -Uri $Versao.Url -OutFile $Destino -UseBasicParsing -TimeoutSec 300 `
                          -Headers @{ 'User-Agent' = 'COMPARTDISK-Bootstrap' }
    }

    if (-not (Test-Path -LiteralPath $Destino)) {
        throw 'O download terminou sem gerar o arquivo.'
    }
    $tam = (Get-Item -LiteralPath $Destino).Length
    if ($tam -lt 10KB) {
        throw "O arquivo baixado tem apenas $tam bytes e nao pode ser um pacote valido."
    }
    return $tam
}

function Test-Integridade {
    <# Validacao em duas camadas: assinatura de arquivo ZIP e, quando o hash
       estiver publicado nas notas da release, comparacao SHA-256. #>
    param([Parameter(Mandatory)][string]$Arquivo, [AllowNull()][string]$HashEsperado)

    # Le apenas os 4 primeiros bytes: carregar o pacote inteiro na memoria so
    # para conferir a assinatura seria desperdicio em arquivos grandes.
    $assinatura = New-Object byte[] 4
    $fs = [System.IO.File]::OpenRead($Arquivo)
    try { [void]$fs.Read($assinatura, 0, 4) } finally { $fs.Dispose() }

    if ($assinatura[0] -ne 0x50 -or $assinatura[1] -ne 0x4B) {
        throw 'O conteudo baixado nao e um arquivo ZIP valido. Download corrompido ou bloqueado por proxy.'
    }
    Write-Marcador OK 'Assinatura de arquivo ZIP confirmada.'

    if (-not $HashEsperado) {
        Write-Marcador WARN 'A release nao publica SHA-256. Validacao de hash indisponivel nesta versao.'
        return $false
    }

    $calculado = (Get-FileHash -LiteralPath $Arquivo -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($calculado -ne $HashEsperado) {
        throw ("Integridade recusada.`n" +
               "           esperado : $HashEsperado`n" +
               "           calculado: $calculado")
    }
    Write-Marcador OK 'Integridade SHA-256 conferida com o valor publicado.'
    return $true
}

function Expand-Pacote {
    param([Parameter(Mandatory)][string]$Arquivo, [Parameter(Mandatory)][string]$Destino)

    if (Test-Path -LiteralPath $Destino) {
        Remove-Item -LiteralPath $Destino -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null

    try {
        Expand-Archive -LiteralPath $Arquivo -DestinationPath $Destino -Force
    } catch {
        # Fallback para ambientes onde o cmdlet foi removido da imagem
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Arquivo, $Destino)
    }

    # O pacote pode ou nao ter uma pasta raiz; localiza o Launcher onde estiver.
    $launcher = Get-ChildItem -LiteralPath $Destino -Filter 'Launcher.bat' -Recurse -File |
                Select-Object -First 1
    if (-not $launcher) {
        throw 'O pacote extraido nao contem Launcher.bat. Conteudo invalido.'
    }

    $raiz = $launcher.Directory.FullName
    if (-not (Test-Path -LiteralPath (Join-Path $raiz 'Modules\Core.ps1'))) {
        throw 'O pacote extraido nao contem a pasta Modules. Conteudo incompleto.'
    }

    $modulos = @(Get-ChildItem -LiteralPath (Join-Path $raiz 'Modules') -Filter '*.ps1' -File).Count
    Write-Marcador OK "Pacote extraido e verificado ($modulos modulos PowerShell)."
    return $raiz
}

# ==============================================================================
# PRIVILEGIO
# ==============================================================================
function Test-Administrador {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ==============================================================================
# FLUXO PRINCIPAL
# ==============================================================================
$temp    = $null
$pacote  = $null
$codigo  = 0

try {
    Clear-Host
    Write-Cabecalho
    Initialize-Tls

    # --- privilegio -----------------------------------------------------------
    if (-not (Test-Administrador)) {
        Write-Marcador WARN 'Esta sessao nao possui privilegio administrativo.'
        Write-Linha
        Write-Linha '  O COMPARTDISK precisa de privilegio de administrador para reparar o' DarkGray
        Write-Linha '  Windows, alterar a rede e ler informacoes de hardware.' DarkGray
        Write-Linha
        Write-Linha '  Feche esta janela e execute novamente em um PowerShell iniciado com' DarkGray
        Write-Linha '  "Executar como administrador".' DarkGray
        Write-Linha
        Write-Marcador INFO 'Nenhuma alteracao foi feita no sistema.'
        Write-Linha
        return
    }
    Write-Marcador OK 'Privilegio administrativo confirmado.'

    # --- conectividade --------------------------------------------------------
    if (-not (Test-Conectividade)) {
        throw ("Nao foi possivel alcancar o GitHub.`n" +
               "           Verifique a conexao com a internet, o proxy corporativo ou o firewall.`n" +
               "           Alternativa: baixe o pacote manualmente em $Origem/releases")
    }
    Write-Marcador OK 'Conexao com o GitHub estabelecida.'

    # --- versao ---------------------------------------------------------------
    $versao = Get-VersaoMaisRecente
    Write-Marcador OK "Versao estavel mais recente: $($versao.Tag)"
    if (-not $versao.TemAsset) {
        Write-Marcador WARN 'A release nao possui pacote anexado. Usando o codigo-fonte da tag.'
    }

    Write-Linha
    Write-Host '  Versao   ' -ForegroundColor DarkGray -NoNewline
    Write-Host $versao.Tag -ForegroundColor White
    Write-Host '  Pacote   ' -ForegroundColor DarkGray -NoNewline
    Write-Host $versao.Arquivo -ForegroundColor Gray
    if ($versao.Publicado) {
        Write-Host '  Publicado' -ForegroundColor DarkGray -NoNewline
        Write-Host (' ' + ([datetime]$versao.Publicado).ToLocalTime().ToString('dd/MM/yyyy HH:mm')) -ForegroundColor Gray
    }
    Write-Linha

    # --- download -------------------------------------------------------------
    $temp   = Join-Path $env:TEMP ('COMPARTDISK_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $pacote = Join-Path $temp $versao.Arquivo

    Write-Marcador INFO 'Baixando o pacote...'
    $tamanho = Get-Pacote -Versao $versao -Destino $pacote
    Write-Marcador OK ("Download concluido ({0:N2} MB)." -f ($tamanho / 1MB))

    # --- integridade e extracao ----------------------------------------------
    [void](Test-Integridade -Arquivo $pacote -HashEsperado $versao.Hash)
    $raiz = Expand-Pacote -Arquivo $pacote -Destino (Join-Path $temp 'app')

    # --- execucao -------------------------------------------------------------
    Write-Linha
    Write-Linha ('  ' + ('-' * 66)) DarkGray
    Write-Marcador OK 'Iniciando o COMPARTDISK...'
    Write-Linha

    # A partir daqui o controle e do Launcher.bat: os mesmos menus, modulos e
    # fluxos da instalacao local. O parametro /elevated informa que o privilegio
    # ja foi verificado, evitando uma segunda solicitacao do UAC.
    $launcher = Join-Path $raiz 'Launcher.bat'
    $proc = Start-Process -FilePath $env:ComSpec `
                          -ArgumentList '/c', "`"$launcher`"", '/elevated' `
                          -WorkingDirectory $raiz -NoNewWindow -Wait -PassThru
    $codigo = $proc.ExitCode

    Write-Linha
    Write-Marcador OK "Sessao encerrada (codigo $codigo)."
}
catch {
    $codigo = 1
    Write-Linha
    Write-Marcador ERRO $_.Exception.Message
    Write-Linha
    Write-Linha '  Alternativas:' DarkGray
    Write-Linha "    1. Baixar o pacote manualmente em $Origem/releases" DarkGray
    Write-Linha '    2. Verificar proxy, firewall ou antivirus corporativo' DarkGray
    Write-Linha '    3. Relatar o problema em ' DarkGray
    Write-Linha "       $Origem/issues" DarkGray
    Write-Linha
}
finally {
    # Os arquivos temporarios nunca permanecem no disco: a execucao remota nao
    # deve deixar residuo, ao contrario da instalacao local.
    if ($temp -and (Test-Path -LiteralPath $temp)) {
        try {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Stop
            Write-Marcador INFO 'Arquivos temporarios removidos.'
        } catch {
            Write-Marcador WARN "Nao foi possivel remover: $temp"
        }
    }
    Write-Linha
}
