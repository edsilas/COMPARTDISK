<#
 COMPARTDISK 1.3.1 - Cleanup.ps1
 Desenvolvido por Edsilas
 Acoes: Analyze | Standard | Deep | Browsers | Logs

 ESCOPO E SEGURANCA
 Analyze e ESTRITAMENTE somente leitura: mede, classifica e informa, sem
 remover nada. Standard, Deep, Browsers e Logs removem arquivos e por isso
 toda exclusao passa antes por uma camada de validacao de caminho.

 O modulo NAO encerra processos, NAO para servicos, NAO altera registro,
 NAO mexe em energia, Pagefile ou componentes do Windows, e NAO remove
 dados de navegador alem de cache (cookies, senhas, historico, favoritos,
 extensoes e preferencias ficam intactos).

 Compativel com Windows 10 / Windows 11, Windows PowerShell 5.1 e
 PowerShell 7.x. Somente componentes nativos do Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Standard', 'Deep', 'Browsers', 'Logs')]
    [string]$Action = 'Analyze',
    [switch]$Quiet,
    # Esvaziar a Lixeira e exclusao definitiva de arquivos do usuario, nao
    # limpeza de cache. Permanece no comportamento padrao, mas pode ser omitida.
    [switch]$SkipRecycleBin
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

# ==============================================================================
# ESTADO GLOBAL
# Fonte unica e monotonica: OK -> WARN -> ERROR. Um WARN nunca vira OK no finally.
# ==============================================================================
$script:result     = 'OK'
$script:ResultRank = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-CleanupResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Position = 1)][string]$Reason = ''
    )
    if ($script:ResultRank[$Level] -gt $script:ResultRank[$script:result]) {
        $script:result = $Level
        Write-Log DEBUG ("Resultado do modulo elevado para {0}{1}" -f $Level, $(if ($Reason) { ": $Reason" } else { '' })) -NoConsole
    }
}

function Get-CleanupSectionStatus {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) { 'OK' { return 'OK' } 'WARN' { return 'WARN' } default { return 'CRIT' } }
}

function Get-CleanupFindingSeverity {
    param([Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level)
    switch ($Level) { 'OK' { return 'OK' } 'WARN' { return 'WARN' } default { return 'CRIT' } }
}

function ConvertTo-CleanupArray {
    <# Funcao que devolve @() entrega $null ao chamador, e @($null) tem Count 1. #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    return @(@($Value) | Where-Object { $null -ne $_ })
}

function Get-CleanupSafeText {
    param([AllowNull()][object]$Value, [string]$Default = 'n/d')
    if ($null -eq $Value) { return $Default }
    $t = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $Default }
    return $t
}

# ------------------------------------------------------------------------------
# -Quiet reduz SOMENTE a saida interativa. Logs, findings, sections e resultado
# permanecem inalterados.
# ------------------------------------------------------------------------------
function Write-CleanupTable {
    [CmdletBinding()]
    param([object[]]$Rows, [string[]]$Property)
    if ($script:Quiet) { return }
    $dados = ConvertTo-CleanupArray $Rows
    if ($dados.Count -eq 0) { return }
    try {
        if ($Property) { $texto = $dados | Select-Object -Property $Property | Format-Table -AutoSize | Out-String -Width 200 }
        else           { $texto = $dados | Format-Table -AutoSize | Out-String -Width 200 }
        foreach ($linha in ($texto -split "`r?`n")) {
            if ($linha.Trim()) { Write-Color ("  " + $linha) }
        }
    } catch {
        Write-Log DEBUG "Falha ao formatar tabela: $($_.Exception.Message)" -NoConsole
    }
}

function Write-CleanupLine {
    param([string]$Text, $Color = 'Gray')
    if ($script:Quiet) { return }
    Write-Color $Text -Color $Color
}

# ==============================================================================
# CAMADA DE SEGURANCA DE CAMINHO
# Nenhuma remocao acontece sem passar por Test-CleanupTargetSafety.
# A estrategia e lista de PERMISSAO: o alvo precisa estar sob uma raiz conhecida.
# ==============================================================================
$script:RaizesPermitidas = $null

function Get-CleanupAllowedRoots {
    if ($null -ne $script:RaizesPermitidas) { return $script:RaizesPermitidas }
    $lista = New-Object System.Collections.ArrayList
    foreach ($r in @($env:SystemRoot, $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, $env:TEMP, $env:TMP)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $n = ConvertTo-CleanupNormalizedPath $r
        if ($n -and (@($lista) -notcontains $n)) { [void]$lista.Add($n) }
    }
    $script:RaizesPermitidas = @($lista)
    return $script:RaizesPermitidas
}

# Separador obtido do runtime em vez de fixado: a comparacao de caminhos passa
# a valer em qualquer host, sem alterar o comportamento no Windows.
$script:Sep = [System.IO.Path]::DirectorySeparatorChar

function ConvertTo-CleanupNormalizedPath {
    <# Resolve '..', separadores e barra final. Devolve '' quando o caminho nao
       puder ser normalizado - e caminho nao normalizavel bloqueia a remocao. #>
    param([AllowNull()][object]$Path)
    $p = "$Path"
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    try {
        $full = [System.IO.Path]::GetFullPath($p.Trim())
        if ([string]::IsNullOrWhiteSpace($full)) { return '' }
        $raiz = ''
        try { $raiz = [System.IO.Path]::GetPathRoot($full) } catch { $raiz = '' }
        if ($full.Length -gt $raiz.Length) { $full = $full.TrimEnd($script:Sep) }
        return $full
    } catch {
        Write-Log DEBUG ("Caminho nao normalizavel '{0}': {1}" -f $p, $_.Exception.Message) -NoConsole
        return ''
    }
}

function Test-CleanupPathUnder {
    <# $true quando $Child esta estritamente DENTRO de $Parent. Comparacao por
       segmento: 'C:\Windows\Temp2' nao e filho de 'C:\Windows\Temp'. #>
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    $c = $Child.TrimEnd($script:Sep); $p = $Parent.TrimEnd($script:Sep)
    if ($c.Length -le $p.Length) { return $false }
    return $c.StartsWith($p + $script:Sep, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CleanupForbiddenPaths {
    $itens = @(
        $env:SystemRoot
        (Join-Path $env:SystemRoot 'System32')
        (Join-Path $env:SystemRoot 'SysWOW64')
        (Join-Path $env:SystemRoot 'WinSxS')
        (Join-Path $env:SystemRoot 'assembly')
        (Join-Path $env:SystemRoot 'System32\config')
        (Join-Path $env:SystemRoot 'SoftwareDistribution')
        $env:SystemDrive
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:ProgramData
        $env:USERPROFILE
        $env:LOCALAPPDATA
        $env:APPDATA
        (Join-Path $env:SystemDrive 'Users')
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($i in $itens) {
        if ([string]::IsNullOrWhiteSpace($i)) { continue }
        $n = ConvertTo-CleanupNormalizedPath $i
        if ($n -and (@($out) -notcontains $n)) { [void]$out.Add($n) }
    }
    return @($out)
}

function Test-CleanupTargetSafety {
    <# Valida um alvo ANTES de qualquer remocao. Retorna
       { Ok, Motivo, Caminho, Existe, Tipo, Reparse }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $out = [pscustomobject]@{
        Ok = $false; Motivo = ''; Caminho = ''; Existe = $false; Tipo = 'n/d'; Reparse = $false
    }

    $norm = ConvertTo-CleanupNormalizedPath $Path
    if (-not $norm) { $out.Motivo = 'caminho vazio ou nao normalizavel'; return $out }
    $out.Caminho = $norm

    if ($norm.StartsWith('\\')) { $out.Motivo = 'caminho UNC nao e alvo valido de limpeza'; return $out }
    if (-not [System.IO.Path]::IsPathRooted($norm)) { $out.Motivo = 'caminho relativo nao e alvo valido'; return $out }
    # Raiz de volume: comparada contra a raiz real do caminho, e nao por padrao
    # textual, para cobrir 'C:\', '\\?\C:\' e qualquer variacao do host.
    $raizVol = ''
    try { $raizVol = [System.IO.Path]::GetPathRoot($norm) } catch { $raizVol = '' }
    if ($raizVol -and $norm.TrimEnd($script:Sep).Length -le $raizVol.TrimEnd($script:Sep).Length) {
        $out.Motivo = 'raiz de volume nunca e alvo de limpeza'; return $out
    }

    foreach ($p in (Get-CleanupForbiddenPaths)) {
        if ($norm.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) {
            $out.Motivo = ('caminho protegido do sistema: {0}' -f $p); return $out
        }
    }

    # O alvo pode estar SOB uma raiz permitida ou SER uma delas: %TEMP% e alvo
    # legitimo. As raizes que jamais podem ser esvaziadas (Windows, LOCALAPPDATA,
    # APPDATA, ProgramData) ja foram recusadas pela lista de proibidos acima.
    $dentro = $false
    foreach ($r in (Get-CleanupAllowedRoots)) {
        if ($norm.Equals($r, [System.StringComparison]::OrdinalIgnoreCase) -or
            (Test-CleanupPathUnder -Child $norm -Parent $r)) { $dentro = $true; break }
    }
    if (-not $dentro) {
        $out.Motivo = 'fora das raizes permitidas (Windows, AppData, ProgramData ou TEMP)'
        return $out
    }

    if (-not (Test-Path -LiteralPath $norm)) {
        $out.Ok = $true; $out.Existe = $false; $out.Tipo = 'inexistente'
        $out.Motivo = 'alvo inexistente'
        return $out
    }
    $out.Existe = $true

    try {
        $item = Get-Item -LiteralPath $norm -Force -ErrorAction Stop
        $out.Tipo = $(if ($item.PSIsContainer) { 'diretorio' } else { 'arquivo' })
        $out.Reparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    } catch {
        $out.Motivo = ('alvo inacessivel: {0}' -f $_.Exception.Message)
        return $out
    }

    if ($out.Reparse) {
        # Remover conteudo atraves de junction/symlink alcancaria outra arvore.
        $out.Motivo = 'o proprio alvo e um ponto de nova analise (junction/symlink)'
        return $out
    }

    $out.Ok = $true
    $out.Motivo = 'validado'
    return $out
}

function Get-CleanupReparseChildren {
    <# Nomes de itens de primeiro nivel que SAO ou CONTEM ponto de nova analise.
       Sao devolvidos para virar exclusao: Remove-Item -Recurse no Windows
       PowerShell 5.1 pode atravessar junction e apagar a arvore de destino. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $nomes = New-Object System.Collections.ArrayList
    try {
        foreach ($filho in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            $ehReparse = $false
            try { $ehReparse = [bool]($filho.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } catch { $ehReparse = $false }
            if ($ehReparse) { [void]$nomes.Add($filho.Name); continue }
            if (-not $filho.PSIsContainer) { continue }
            # Varredura apenas de diretorios (barata) em busca de reparse aninhado.
            try {
                $netos = @(Get-ChildItem -LiteralPath $filho.FullName -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
                if ($netos.Count -gt 0) { [void]$nomes.Add($filho.Name) }
            } catch {
                Write-Log DEBUG ("Varredura de reparse em '{0}': {1}" -f $filho.FullName, $_.Exception.Message) -NoConsole
            }
        }
    } catch {
        Write-Log DEBUG ("Enumeracao para reparse em '{0}': {1}" -f $Path, $_.Exception.Message) -NoConsole
    }
    return @($nomes)
}

# ==============================================================================
# MEDICAO
# Falha de medicao NAO vira "0 bytes".
# ==============================================================================
function Measure-CleanupPath {
    <# Retorna { Ok, Existe, Bytes, Arquivos, Detalhe }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $out = [pscustomobject]@{ Ok = $false; Existe = $false; Bytes = 0; Arquivos = 0; Detalhe = '' }
    if (-not (Test-Path -LiteralPath $Path)) {
        $out.Ok = $true; $out.Detalhe = 'inexistente'
        return $out
    }
    $out.Existe = $true
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $out.Bytes = [long]$fi.Length; $out.Arquivos = 1; $out.Ok = $true
            return $out
        }
    } catch {
        $out.Detalhe = ('nao foi possivel medir o arquivo: {0}' -f $_.Exception.Message)
        return $out
    }

    $m = Invoke-SafeCommand { Get-CompartDiskFolderSize -Path $Path } -Activity ("Medir {0}" -f $Path) -Silent
    if (-not $m.Success -or $null -eq $m.Value) {
        $out.Detalhe = ('medicao indisponivel: {0}' -f $(if ($m.Error) { $m.Error.Exception.Message } else { 'sem retorno' }))
        return $out
    }
    $v = $m.Value
    try { $out.Bytes = [long]$v.Bytes } catch { $out.Bytes = 0 }
    try { $out.Arquivos = [int]$v.Files } catch { $out.Arquivos = 0 }
    try { $out.Existe = [bool]$v.Exists } catch { $out.Existe = $true }
    $out.Ok = $true
    return $out
}

function Get-CleanupFreeSpace {
    <# Espaco livre do volume do sistema. Falha de consulta NUNCA e reportada
       como zero: devolve Ok=$false com o motivo. #>
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Ok = $false; Bytes = 0; Metodo = 'n/d'; Detalhe = '' }
    $unidade = "$env:SystemDrive"
    if ([string]::IsNullOrWhiteSpace($unidade)) {
        $out.Detalhe = 'SystemDrive indefinido'
        return $out
    }
    try {
        $d = @(ConvertTo-CleanupArray (Get-CompartDiskCim -Class Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $unidade))) | Select-Object -First 1
        if ($d -and $null -ne $d.FreeSpace) {
            $out.Ok = $true; $out.Bytes = [long]$d.FreeSpace; $out.Metodo = 'Win32_LogicalDisk'
            return $out
        }
        $out.Detalhe = ('Win32_LogicalDisk nao devolveu espaco livre para {0}' -f $unidade)
    } catch {
        $out.Detalhe = ('consulta Win32_LogicalDisk falhou: {0}' -f $_.Exception.Message)
        Write-Log DEBUG "Win32_LogicalDisk: $($_.Exception.Message)" -NoConsole
    }
    try {
        $di = New-Object System.IO.DriveInfo($unidade)
        if ($di.IsReady) {
            $out.Ok = $true; $out.Bytes = [long]$di.AvailableFreeSpace; $out.Metodo = 'System.IO.DriveInfo'; $out.Detalhe = ''
            return $out
        }
        $out.Detalhe += ' volume nao esta pronto'
    } catch {
        $out.Detalhe += (' DriveInfo falhou: {0}' -f $_.Exception.Message)
    }
    return $out
}

# ==============================================================================
# CATALOGO DE ALVOS
# Grupo     : Padrao | Profundo | Navegadores  (preservado)
# Categoria : Temporarios | Cache | Diagnostico | Navegador
#
# IncluirPadrao e IdadeMinimaDias dao precisao a limpeza: em vez de esvaziar um
# diretorio inteiro, apenas os artefatos que realmente pertencem ao cache alvo
# sao removidos. Ambos sao convertidos em -ExcludeNames para o Core, o que
# preserva Remove-CompartDiskPathSafely como unico motor de remocao.
# ==============================================================================
function Get-CleanupTargets {
    param([switch]$IncludeDeep, [switch]$IncludeBrowsers, [switch]$IncludeLogs)

    $t = New-Object System.Collections.ArrayList

    $add = {
        param($nome, $caminho, $grupo, $categoria, $descricao,
              $manterRaiz = $true, $excluir = @(), $excluirPadrao = @(),
              $incluirPadrao = @(), $idadeMinimaDias = 0)
        [void]$t.Add([pscustomobject]@{
            Nome = $nome; Caminho = $caminho; Grupo = $grupo; Categoria = $categoria
            Descricao = $descricao; ManterRaiz = $manterRaiz
            Excluir = @($excluir); ExcluirPadrao = @($excluirPadrao)
            IncluirPadrao = @($incluirPadrao); IdadeMinimaDias = [int]$idadeMinimaDias
        })
    }

    # --- Padrao: caches temporarios de baixo risco -----------------------------
    # Na execucao remota o proprio pacote e extraido em %TEMP%\COMPARTDISK_<id>,
    # o trace de inicializacao vive em %TEMP%\COMPARTDISK_Bootstrap.log e o
    # LOGDIR pode ter caido para %TEMP% com o log da sessao dentro. Limpar o TEMP
    # sem essas excecoes apagaria a propria instancia em execucao.
    & $add 'Temp do usuario' $env:TEMP 'Padrao' 'Temporarios' `
        'Arquivos temporarios do usuario atual' $true @() @('COMPARTDISK_*', 'Relatorio_Manutencao*')
    & $add 'Temp do Windows' (Join-Path $env:SystemRoot 'Temp') 'Padrao' 'Temporarios' `
        'Arquivos temporarios do sistema'
    & $add 'Cache do Windows Update' (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') 'Padrao' 'Cache' `
        'Pacotes baixados pelo Windows Update; downloads em andamento ficam bloqueados e sao preservados'
    & $add 'Delivery Optimization' (Join-Path $env:SystemRoot 'SoftwareDistribution\DeliveryOptimization') 'Padrao' 'Cache' `
        'Cache de distribuicao P2P de atualizacoes; limpar nao corrige erros do Windows Update'
    # Somente os bancos de cache de miniaturas e icones: o restante da pasta
    # Explorer guarda outros artefatos que nao sao cache e permanece intacto.
    & $add 'Cache de miniaturas e icones' (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') 'Padrao' 'Cache' `
        'Bancos thumbcache_*.db e iconcache_*.db; demais artefatos do Explorer sao preservados' `
        $true @() @() @('thumbcache_*.db', 'iconcache_*.db')
    & $add 'INetCache' (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache') 'Padrao' 'Cache' `
        'Cache de conteudo web do WinINet'

    # --- Profundo: diagnostico e caches mais sensiveis -------------------------
    # WER e CrashDumps sao dados de DIAGNOSTICO, nao cache: saem do conjunto
    # padrao e passam a exigir a acao Deep, declarada como abrangente.
    if ($IncludeDeep) {
        & $add 'Relatorios de erro (WER) pendentes' (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue') 'Profundo' 'Diagnostico' `
            'Relatorios de erro ainda nao enviados; remover elimina evidencia de falhas'
        & $add 'Relatorios de erro (WER) arquivados' (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive') 'Profundo' 'Diagnostico' `
            'Historico de relatorios de erro; remover elimina evidencia de falhas'
        & $add 'CrashDumps do usuario' (Join-Path $env:LOCALAPPDATA 'CrashDumps') 'Profundo' 'Diagnostico' `
            'Despejos de falha de aplicativos; uteis para investigar travamentos'
        # Somente .pf antigos: Layout.ini e ReadyBoot permanecem. O cache e
        # reconstruido pelo Windows, com atividade de disco nas primeiras cargas.
        & $add 'Prefetch' (Join-Path $env:SystemRoot 'Prefetch') 'Profundo' 'Cache' `
            'Arquivos .pf com mais de 30 dias; o cache e reconstruido pelo Windows' `
            $true @('Layout.ini', 'ReadyBoot') @() @('*.pf') 30
        # Logs de servicing: apenas os rotacionados e antigos. O arquivo ativo
        # (CBS.log / dism.log) fica de fora e continua disponivel para analise.
        & $add 'Logs do CBS (rotacionados)' (Join-Path $env:SystemRoot 'Logs\CBS') 'Profundo' 'Diagnostico' `
            'Logs de servicing arquivados com mais de 7 dias; CBS.log ativo e preservado' `
            $true @('CBS.log') @() @('CbsPersist_*.log', 'CbsPersist_*.cab', '*.cab') 7
        & $add 'Logs do DISM (antigos)' (Join-Path $env:SystemRoot 'Logs\DISM') 'Profundo' 'Diagnostico' `
            'Logs do DISM com mais de 7 dias; dism.log ativo e preservado' `
            $true @('dism.log') @() @() 7
        & $add 'Logs do WindowsUpdate (antigos)' (Join-Path $env:SystemRoot 'Logs\WindowsUpdate') 'Profundo' 'Diagnostico' `
            'Rastreamentos .etl com mais de 7 dias' `
            $true @() @() @('*.etl') 7
        & $add 'Cache de fontes' (Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache') 'Profundo' 'Cache' `
            'Arquivos .dat do cache de fontes; os em uso pelo servico permanecem bloqueados e sao preservados' `
            $true @() @() @('*.dat')
        & $add 'Downloaded Program Files' (Join-Path $env:SystemRoot 'Downloaded Program Files') 'Profundo' 'Cache' `
            'Cache legado de controles ActiveX'
    }

    # --- Logs: dumps de sistema ------------------------------------------------
    # Pertencem a acao Logs porque e ela que o menu declara como "Logs de
    # Eventos e Arquivos de Crash/Dumps". Ficam FORA de Deep de proposito: o
    # menu pergunta ao operador antes de apagar dumps, e Deep executa mesmo
    # quando a resposta e nao.
    if ($IncludeLogs) {
        & $add 'Minidumps do sistema' (Join-Path $env:SystemRoot 'Minidump') 'Logs' 'Diagnostico' `
            'Despejos reduzidos de falha do sistema (BSOD); sao a evidencia primaria para investigar travamentos'
        & $add 'Despejo completo (MEMORY.DMP)' (Join-Path $env:SystemRoot 'MEMORY.DMP') 'Logs' 'Diagnostico' `
            'Despejo completo de memoria da ultima falha; costuma ser grande e e insubstituivel para analise de BSOD' $false
    }

    # --- Navegadores: exclusivamente diretorios de cache -----------------------
    # Nenhum dado de sessao e tocado: cookies, senhas, historico, favoritos,
    # extensoes, Local State e Preferences nao constam da lista.
    if ($IncludeBrowsers) {
        $navegadores = @(
            @{ N = 'Microsoft Edge'; P = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') }
            @{ N = 'Google Chrome';  P = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') }
            @{ N = 'Brave';          P = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') }
        )
        # Lista deliberadamente identica a do fallback Batch (:FB_LIMPEZA).
        # "Network" NAO entra: guarda Cookies e TransportSecurity, nao cache.
        $subcaches = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache')
        foreach ($nav in $navegadores) {
            if (-not (Test-Path -LiteralPath $nav.P)) { continue }
            $perfis = @()
            try { $perfis = @(Get-ChildItem -LiteralPath $nav.P -Directory -ErrorAction Stop) }
            catch { Write-Log DEBUG ("Perfis de {0} inacessiveis: {1}" -f $nav.N, $_.Exception.Message) -NoConsole; continue }
            foreach ($perfil in $perfis) {
                if ($perfil.Name -notmatch '^(Default|Profile \d+|Guest Profile)$') { continue }
                foreach ($sc in $subcaches) {
                    $full = Join-Path $perfil.FullName $sc
                    if (Test-Path -LiteralPath $full) {
                        & $add ("{0} / {1} / {2}" -f $nav.N, $perfil.Name, $sc) $full 'Navegadores' 'Navegador' `
                            'Diretorio de cache do navegador'
                    }
                }
            }
        }
        # Firefox: somente cache2. places.sqlite, logins, cookies, extensoes e
        # dados de sessao vivem em APPDATA e nao sao alcancados por este alvo.
        $ff = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $ff) {
            $perfisFf = @()
            try { $perfisFf = @(Get-ChildItem -LiteralPath $ff -Directory -ErrorAction Stop) }
            catch { Write-Log DEBUG ("Perfis do Firefox inacessiveis: {0}" -f $_.Exception.Message) -NoConsole }
            foreach ($p in $perfisFf) {
                $c = Join-Path $p.FullName 'cache2'
                if (Test-Path -LiteralPath $c) {
                    & $add ("Firefox / {0} / cache2" -f $p.Name) $c 'Navegadores' 'Navegador' 'Diretorio de cache do Firefox'
                }
            }
        }
    }

    return @($t)
}

function Resolve-CleanupExclusions {
    <# Converte IncluirPadrao, IdadeMinimaDias, reparse points e as exclusoes
       declaradas em uma lista concreta de nomes para -ExcludeNames do Core.
       Retorna { Nomes[], Padroes[], Protegidos, Recentes, ForaDoPadrao, Reparse }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Target, [Parameter(Mandatory)][string]$Path)

    $out = [pscustomobject]@{
        Nomes = @(); Padroes = @(); Protegidos = 0; Recentes = 0; ForaDoPadrao = 0; Reparse = 0
    }
    $nomes = New-Object System.Collections.ArrayList
    foreach ($n in (ConvertTo-CleanupArray $Target.Excluir)) { [void]$nomes.Add("$n") }
    $out.Protegidos = $nomes.Count

    # Reparse points de primeiro nivel (ou que contenham reparse aninhado).
    foreach ($n in (Get-CleanupReparseChildren -Path $Path)) {
        if (@($nomes) -notcontains $n) { [void]$nomes.Add($n); $out.Reparse++ }
    }

    $incluir = ConvertTo-CleanupArray $Target.IncluirPadrao
    $idade   = [int]$Target.IdadeMinimaDias
    if ($incluir.Count -gt 0 -or $idade -gt 0) {
        $corte = (Get-Date).AddDays(-$idade)
        $filhos = @()
        try { $filhos = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop) }
        catch {
            Write-Log DEBUG ("Enumeracao para filtro em '{0}': {1}" -f $Path, $_.Exception.Message) -NoConsole
            # Sem enumerar nao ha como aplicar o filtro com seguranca: nada e removido.
            $out.Nomes = @($nomes)
            $out.Padroes = @(ConvertTo-CleanupArray $Target.ExcluirPadrao)
            return $out
        }
        foreach ($f in $filhos) {
            if (@($nomes) -contains $f.Name) { continue }
            if ($incluir.Count -gt 0) {
                $casa = $false
                foreach ($pat in $incluir) { if ($f.Name -like $pat) { $casa = $true; break } }
                if (-not $casa) { [void]$nomes.Add($f.Name); $out.ForaDoPadrao++; continue }
            }
            if ($idade -gt 0) {
                $dt = $null
                try { $dt = $f.LastWriteTime } catch { $dt = $null }
                if ($null -eq $dt -or $dt -gt $corte) { [void]$nomes.Add($f.Name); $out.Recentes++ }
            }
        }
    }

    $out.Nomes = @($nomes)
    $out.Padroes = @(ConvertTo-CleanupArray $Target.ExcluirPadrao)
    return $out
}

# ==============================================================================
# ACAO: ANALYZE  (estritamente somente leitura)
# Mede, classifica e informa. Nao remove, nao esvazia lixeira, nao limpa DNS,
# nao toca em log de eventos. O resultado e separado por grupo para que o
# numero exibido corresponda a acao que o operador for executar.
# ==============================================================================
function Invoke-CleanupAnalysis {
    param([object[]]$Targets)

    $alvos = ConvertTo-CleanupArray $Targets
    Write-Log INFO ("Analisando {0} alvo(s) sem remover nada..." -f $alvos.Count)

    $rows = New-Object System.Collections.ArrayList
    $falhasMedicao = 0
    $inacessiveis  = 0

    foreach ($t in $alvos) {
        $seg = Test-CleanupTargetSafety -Path $t.Caminho
        $estado = 'existente'
        $bytes = 0; $arquivos = 0; $detalhe = ''

        if (-not $seg.Ok) {
            $estado = 'bloqueado por protecao'
            $detalhe = $seg.Motivo
            $inacessiveis++
        } elseif (-not $seg.Existe) {
            $estado = 'inexistente'
            $detalhe = 'nao presente neste sistema'
        } else {
            $m = Measure-CleanupPath -Path $seg.Caminho
            if (-not $m.Ok) {
                $estado = 'medicao indisponivel'
                $detalhe = $m.Detalhe
                $falhasMedicao++
            } else {
                $bytes = $m.Bytes; $arquivos = $m.Arquivos
                if ($bytes -eq 0 -and $arquivos -eq 0) { $estado = 'vazio' }
            }
        }

        [void]$rows.Add([pscustomobject]@{
            Grupo     = $t.Grupo
            Categoria = $t.Categoria
            Alvo      = $t.Nome
            Estado    = $estado
            Arquivos  = $arquivos
            Bytes     = $bytes
            Tamanho   = (ConvertTo-CompartDiskSize $bytes)
            Caminho   = $seg.Caminho
            Detalhe   = $detalhe
            Descricao = $t.Descricao
        })
    }

    $todas = @($rows)
    $existentes = @($todas | Where-Object { $_.Estado -eq 'existente' })
    $ordenado = @($todas | Sort-Object -Property @{ Expression = 'Bytes'; Descending = $true }, @{ Expression = 'Alvo' })

    function Get-CleanupGroupBytes {
        param([string[]]$Grupos)
        $soma = 0
        foreach ($r in $todas) { if (@($Grupos) -contains $r.Grupo) { $soma += [long]$r.Bytes } }
        return $soma
    }

    $bPadrao = Get-CleanupGroupBytes @('Padrao')
    $bDeep   = Get-CleanupGroupBytes @('Padrao', 'Profundo', 'Navegadores')
    $bNav    = Get-CleanupGroupBytes @('Navegadores')
    $bLogs   = Get-CleanupGroupBytes @('Logs')

    Write-CleanupTable -Rows $ordenado -Property @('Grupo', 'Categoria', 'Alvo', 'Estado', 'Arquivos', 'Tamanho')

    Write-CleanupLine ''
    Write-CleanupLine '  Potencial por acao (estimativa; o espaco realmente liberado depende de arquivos em uso):' 'White'
    Write-CleanupLine ("  {0} : {1}" -f 'Standard'.PadRight(12), (ConvertTo-CompartDiskSize $bPadrao)) 'Green'
    Write-CleanupLine ("  {0} : {1}" -f 'Deep'.PadRight(12), (ConvertTo-CompartDiskSize $bDeep)) 'Green'
    Write-CleanupLine ("  {0} : {1}" -f 'Browsers'.PadRight(12), (ConvertTo-CompartDiskSize $bNav)) 'Green'
    Write-CleanupLine ("  {0} : {1}" -f 'Logs'.PadRight(12), (ConvertTo-CompartDiskSize $bLogs)) 'Yellow'

    $pares = [ordered]@{
        'Alvos avaliados'          = $todas.Count
        'Alvos existentes'         = $existentes.Count
        'Alvos inexistentes'       = @($todas | Where-Object { $_.Estado -eq 'inexistente' }).Count
        'Alvos vazios'             = @($todas | Where-Object { $_.Estado -eq 'vazio' }).Count
        'Medicao indisponivel'     = $falhasMedicao
        'Bloqueados por protecao'  = $inacessiveis
        'Potencial - Standard'     = (ConvertTo-CompartDiskSize $bPadrao)
        'Potencial - Deep'         = (ConvertTo-CompartDiskSize $bDeep)
        'Potencial - Browsers'     = (ConvertTo-CompartDiskSize $bNav)
        'Potencial - Logs (dumps)' = (ConvertTo-CompartDiskSize $bLogs)
        'Natureza dos numeros'     = 'estimativa de conteudo medido, nao garantia de espaco liberado'
    }

    $nivel = 'OK'
    if ($falhasMedicao -gt 0 -or $inacessiveis -gt 0) { $nivel = 'WARN' }

    Add-CompartDiskSection -Title 'Analise de limpeza (simulacao)' -Status (Get-CleanupSectionStatus $nivel) `
        -Rows $ordenado -Pairs $pares `
        -Summary ("Standard {0} | Deep {1} | Browsers {2} | Logs {3}" -f `
            (ConvertTo-CompartDiskSize $bPadrao), (ConvertTo-CompartDiskSize $bDeep), `
            (ConvertTo-CompartDiskSize $bNav), (ConvertTo-CompartDiskSize $bLogs))

    if ($nivel -eq 'WARN') {
        Add-CompartDiskFinding -Severity WARN -Area 'Limpeza' `
            -Message ("Analise concluida com {0} alvo(s) sem medicao e {1} bloqueado(s) por protecao: os totais estao subestimados." -f $falhasMedicao, $inacessiveis) `
            -Recommendation 'Executar como administrador para medir os alvos do sistema; alvos bloqueados por protecao nunca sao removidos.'
        Set-CleanupResult 'WARN' 'analise com medicoes indisponiveis'
    } else {
        Add-CompartDiskFinding -Severity INFO -Area 'Limpeza' `
            -Message ("Analise concluida sobre {0} alvo(s) existente(s): Standard removeria ate {1}; Deep, ate {2}; Browsers, ate {3}." -f `
                $existentes.Count, (ConvertTo-CompartDiskSize $bPadrao), `
                (ConvertTo-CompartDiskSize $bDeep), (ConvertTo-CompartDiskSize $bNav)) `
            -Recommendation 'Os valores sao estimativas: arquivos em uso permanecem e o ganho real no volume e medido durante a limpeza.'
    }
    if ($bLogs -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Limpeza' `
            -Message ("{0} em despejos de falha (Minidump/MEMORY.DMP) seriam removidos apenas pela acao Logs." -f (ConvertTo-CompartDiskSize $bLogs)) `
            -Recommendation 'Despejos sao a evidencia primaria de BSOD: coletar o diagnostico necessario antes de remove-los.'
    }
    Write-Log OK ("Analise concluida (nenhuma alteracao aplicada). Standard: {0} | Deep: {1}." -f `
        (ConvertTo-CompartDiskSize $bPadrao), (ConvertTo-CompartDiskSize $bDeep))
}

# ==============================================================================
# EXECUCAO DA LIMPEZA (Standard | Deep | Browsers)
# Fluxo por alvo: validar -> medir antes -> resolver exclusoes -> remover ->
# medir depois -> registrar. Nenhum alvo e removido sem passar pela camada de
# seguranca, e a raiz do alvo e sempre preservada.
# ==============================================================================
function Test-CleanupBrowserRunning {
    <# Cache de navegador aberto fica bloqueado. O modulo NAO encerra processos:
       apenas informa, para que o operador entenda os itens ignorados. #>
    [CmdletBinding()] param()
    $mapa = @{ 'msedge' = 'Microsoft Edge'; 'chrome' = 'Google Chrome'; 'brave' = 'Brave'; 'firefox' = 'Firefox' }
    $ativos = New-Object System.Collections.ArrayList
    foreach ($proc in $mapa.Keys) {
        try {
            $p = @(Get-Process -Name $proc -ErrorAction SilentlyContinue)
            if ($p.Count -gt 0 -and (@($ativos) -notcontains $mapa[$proc])) { [void]$ativos.Add($mapa[$proc]) }
        } catch {
            Write-Log DEBUG ("Consulta de processo '{0}': {1}" -f $proc, $_.Exception.Message) -NoConsole
        }
    }
    return @($ativos)
}

function Invoke-CleanupTarget {
    <# Remove o conteudo de UM alvo, com validacao antes e depois. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Target)

    $out = [pscustomobject]@{
        Grupo = $Target.Grupo; Categoria = $Target.Categoria; Alvo = $Target.Nome
        Estado = 'nao processado'; Caminho = ''; BytesAntes = 0; BytesDepois = 0
        BytesLiberados = 0; Removidos = 0; Bloqueados = 0; Preservados = 0
        Detalhe = ''
    }

    $seg = Test-CleanupTargetSafety -Path $Target.Caminho
    $out.Caminho = $seg.Caminho
    if (-not $seg.Ok) {
        $out.Estado = 'bloqueado por protecao'
        $out.Detalhe = $seg.Motivo
        return $out
    }
    if (-not $seg.Existe) {
        $out.Estado = 'inexistente'
        $out.Detalhe = 'nao presente neste sistema'
        return $out
    }

    $antes = Measure-CleanupPath -Path $seg.Caminho
    if ($antes.Ok) { $out.BytesAntes = $antes.Bytes } else { $out.Detalhe = $antes.Detalhe }

    # Alvo do tipo arquivo (MEMORY.DMP): removido de forma individual.
    if ($seg.Tipo -eq 'arquivo') {
        $r = Invoke-SafeCommand { Remove-Item -LiteralPath $seg.Caminho -Force -ErrorAction Stop } `
                -Activity ("Remover {0}" -f $Target.Nome) -Silent
        if ($r.Success -and -not (Test-Path -LiteralPath $seg.Caminho)) {
            $out.Estado = 'removido'; $out.Removidos = 1; $out.BytesLiberados = $out.BytesAntes
        } else {
            $out.Estado = 'bloqueado'
            $out.Bloqueados = 1
            $out.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'o arquivo permaneceu no disco apos a remocao' })
        }
        return $out
    }

    $exc = Resolve-CleanupExclusions -Target $Target -Path $seg.Caminho
    $out.Preservados = @($exc.Nomes).Count

    $rem = Invoke-SafeCommand {
        Remove-CompartDiskPathSafely -Path $seg.Caminho -KeepRoot:$Target.ManterRaiz `
            -ExcludeNames $exc.Nomes -ExcludePatterns $exc.Padroes
    } -Activity ("Limpar {0}" -f $Target.Nome) -Silent

    if (-not $rem.Success -or $null -eq $rem.Value) {
        $out.Estado = 'falhou'
        $out.Detalhe = $(if ($rem.Error) { $rem.Error.Exception.Message } else { 'a remocao nao devolveu resultado' })
        return $out
    }
    $v = $rem.Value
    try { $out.Removidos = [int]$v.Removed } catch { $out.Removidos = 0 }
    try { $out.Bloqueados = [int]$v.Failed } catch { $out.Bloqueados = 0 }
    try { $out.BytesLiberados = [long]$v.BytesFreed } catch { $out.BytesLiberados = 0 }
    $ignorado = $false
    try { $ignorado = [bool]$v.Skipped } catch { $ignorado = $false }

    if ($ignorado) {
        $out.Estado = 'recusado pelo Core'
        $out.Detalhe = 'Remove-CompartDiskPathSafely classificou o caminho como protegido'
        return $out
    }

    # Pos-validacao: a raiz precisa continuar existindo e o conteudo medido de novo.
    $depois = Measure-CleanupPath -Path $seg.Caminho
    if ($depois.Ok) { $out.BytesDepois = $depois.Bytes }
    if ($Target.ManterRaiz -and -not (Test-Path -LiteralPath $seg.Caminho)) {
        $out.Estado = 'raiz removida'
        $out.Detalhe = 'a raiz do alvo deveria ter sido preservada'
        return $out
    }

    if ($out.Bloqueados -gt 0) {
        $out.Estado = 'parcial'
        $out.Detalhe = ("{0} item(ns) em uso ou inacessivel(is)" -f $out.Bloqueados)
    } elseif ($out.Removidos -eq 0) {
        $out.Estado = 'nada a remover'
    } else {
        $out.Estado = 'limpo'
    }
    return $out
}

function Invoke-Cleanup {
    param([object[]]$Targets, [switch]$IsBrowsers)

    $alvos = ConvertTo-CleanupArray $Targets
    if ($alvos.Count -eq 0) {
        Write-Log WARN 'Nenhum alvo de limpeza aplicavel a esta acao neste sistema.'
        Add-CompartDiskSection -Title 'Limpeza executada' -Status WARN -Summary 'Nenhum alvo aplicavel'
        Add-CompartDiskFinding -Severity WARN -Area 'Limpeza' `
            -Message 'Nenhum alvo de limpeza aplicavel foi encontrado neste sistema.' `
            -Recommendation 'Verificar se os diretorios esperados existem e se a execucao tem permissao para acessa-los.'
        Set-CleanupResult 'WARN' 'nenhum alvo aplicavel'
        return
    }

    $espacoAntes = Get-CleanupFreeSpace
    if (-not $espacoAntes.Ok) {
        Write-Log WARN ('Espaco livre inicial nao pode ser consultado: {0}' -f (Get-CleanupSafeText $espacoAntes.Detalhe 'motivo desconhecido'))
    }

    if ($IsBrowsers) {
        $abertos = Test-CleanupBrowserRunning
        if (@($abertos).Count -gt 0) {
            Write-Log INFO ("Navegador(es) em execucao: {0}. Arquivos de cache em uso serao ignorados; o modulo nao encerra processos." -f (@($abertos) -join ', '))
        }
    }

    Write-Log INFO ("Processando {0} alvo(s) de limpeza..." -f $alvos.Count)
    $rows = New-Object System.Collections.ArrayList
    foreach ($t in $alvos) {
        $r = Invoke-CleanupTarget -Target $t
        [void]$rows.Add($r)
        switch ($r.Estado) {
            'limpo'    { Write-Log OK ("{0}: {1} liberados em {2} item(ns)." -f $r.Alvo, (ConvertTo-CompartDiskSize $r.BytesLiberados), $r.Removidos) }
            'removido' { Write-Log OK ("{0}: {1} liberados." -f $r.Alvo, (ConvertTo-CompartDiskSize $r.BytesLiberados)) }
            'parcial'  { Write-Log WARN ("{0}: {1} liberados, {2} item(ns) em uso ou inacessivel(is)." -f $r.Alvo, (ConvertTo-CompartDiskSize $r.BytesLiberados), $r.Bloqueados) }
            'nada a remover' { Write-Log INFO ("{0}: nada a remover." -f $r.Alvo) }
            'inexistente'    { Write-Log INFO ("{0}: alvo inexistente neste sistema." -f $r.Alvo) }
            default    { Write-Log WARN ("{0}: {1} ({2})." -f $r.Alvo, $r.Estado, (Get-CleanupSafeText $r.Detalhe '')) }
        }
    }

    $todas       = @($rows)
    $liberado    = 0; $bloqueados = 0; $removidos = 0
    foreach ($r in $todas) { $liberado += [long]$r.BytesLiberados; $bloqueados += [int]$r.Bloqueados; $removidos += [int]$r.Removidos }
    $limpos      = @($todas | Where-Object { $_.Estado -eq 'limpo' -or $_.Estado -eq 'removido' }).Count
    $parciais    = @($todas | Where-Object { $_.Estado -eq 'parcial' }).Count
    $inexistentes= @($todas | Where-Object { $_.Estado -eq 'inexistente' }).Count
    $falhos      = @($todas | Where-Object { $_.Estado -eq 'falhou' -or $_.Estado -eq 'raiz removida' -or $_.Estado -eq 'recusado pelo Core' -or $_.Estado -eq 'bloqueado por protecao' -or $_.Estado -eq 'bloqueado' })

    # ------------------------------------------------------------------ lixeira
    $lixeira = [pscustomobject]@{ Executada = $false; Ok = $false; Detalhe = 'nao aplicavel a esta acao' }
    if (-not $IsBrowsers) {
        if ($script:SkipRecycleBin) {
            $lixeira.Detalhe = 'omitida a pedido (-SkipRecycleBin)'
        } elseif (-not (Test-CompartDiskCommand 'Clear-RecycleBin')) {
            $lixeira.Detalhe = 'cmdlet Clear-RecycleBin indisponivel nesta instalacao'
        } else {
            # Exclusao DEFINITIVA de arquivos do usuario: nao e limpeza de cache.
            Write-Log WARN 'Esvaziando a Lixeira: exclusao definitiva e irreversivel de arquivos do usuario.'
            $lixeira.Executada = $true
            $r = Invoke-SafeCommand { Clear-RecycleBin -Force -ErrorAction Stop } -Activity 'Esvaziar lixeira' -Silent
            if ($r.Success) {
                $lixeira.Ok = $true; $lixeira.Detalhe = 'esvaziada'
                Write-Log OK 'Lixeira esvaziada (exclusao definitiva).'
            } else {
                $lixeira.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
                Write-Log WARN ('A Lixeira nao pode ser esvaziada: {0}' -f $lixeira.Detalhe)
            }
        }
    }

    # --------------------------------------------------------------- cache DNS
    # Nao libera espaco em disco: e reportado a parte e nunca somado aos bytes.
    $dns = [pscustomobject]@{ Executada = $false; Ok = $false; Detalhe = 'nao aplicavel a esta acao' }
    if (-not $IsBrowsers) {
        $ipcfg = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
        if (-not (Test-Path -LiteralPath $ipcfg)) {
            $dns.Detalhe = 'ipconfig.exe nao localizado'
        } else {
            $dns.Executada = $true
            $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $ipcfg -Arguments @('/flushdns') -TimeoutSeconds 60 } -Activity 'Limpar cache DNS' -Silent
            if ($r.Success -and $null -ne $r.Value -and [int]$r.Value.ExitCode -eq 0) {
                $dns.Ok = $true; $dns.Detalhe = 'cache DNS local limpo (nao libera espaco em disco)'
                Write-Log OK 'Cache DNS local limpo.'
            } else {
                $dns.Detalhe = $(if ($null -ne $r.Value) { ('codigo {0}' -f $r.Value.ExitCode) } elseif ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })
                Write-Log WARN ('O cache DNS nao pode ser limpo: {0}' -f $dns.Detalhe)
            }
        }
    }

    # ------------------------------------------------------------- ganho real
    $espacoDepois = Get-CleanupFreeSpace
    $ganhoTexto = 'nao calculado'
    $ganhoOk = $false
    $ganho = 0
    if ($espacoAntes.Ok -and $espacoDepois.Ok) {
        $ganho = [long]($espacoDepois.Bytes - $espacoAntes.Bytes)
        $ganhoOk = $true
        # [long] explicito: com delta acima de 2 GB, [math]::Max(0, ...) escolheria
        # a sobrecarga Int32 e estouraria a conversao.
        $ganhoTexto = (ConvertTo-CompartDiskSize ([math]::Max([long]0, $ganho)))
        if ($ganho -lt 0) { $ganhoTexto = ('0 B (o volume perdeu {0} durante a execucao por gravacoes de outros processos)' -f (ConvertTo-CompartDiskSize ([math]::Abs($ganho)))) }
    } else {
        $motivo = $(if (-not $espacoAntes.Ok) { $espacoAntes.Detalhe } else { $espacoDepois.Detalhe })
        $ganhoTexto = ('nao calculado: {0}' -f (Get-CleanupSafeText $motivo 'consulta de espaco indisponivel'))
    }

    Write-CleanupLine ''
    Write-CleanupTable -Rows $todas -Property @('Grupo', 'Categoria', 'Alvo', 'Estado', 'Removidos', 'Bloqueados')
    Write-CleanupLine ''
    Write-CleanupLine ("  {0} : {1}" -f 'Soma logica dos alvos'.PadRight(30), (ConvertTo-CompartDiskSize $liberado)) 'Green'
    Write-CleanupLine ("  {0} : {1}" -f ("Ganho real em $env:SystemDrive").PadRight(30), $ganhoTexto) $(if ($ganhoOk) { 'Green' } else { 'Yellow' })
    if ($bloqueados -gt 0) { Write-CleanupLine ("  {0} : {1}" -f 'Itens em uso (preservados)'.PadRight(30), $bloqueados) 'Yellow' }

    # ------------------------------------------------------------------ status
    $nivel = 'OK'
    if ($falhos.Count -gt 0 -or $parciais -gt 0 -or $bloqueados -gt 0) { $nivel = 'WARN' }
    if (-not $ganhoOk) { $nivel = 'WARN' }
    if ($dns.Executada -and -not $dns.Ok) { $nivel = 'WARN' }
    if ($lixeira.Executada -and -not $lixeira.Ok) { $nivel = 'WARN' }
    # 'nada a remover' e resultado legitimo: numa segunda execucao o alvo ja esta
    # limpo, e isso NAO e falha. Só failures reais elevam o estado.
    if (@($todas | Where-Object { $_.Estado -eq 'bloqueado por protecao' }).Count -eq $todas.Count) { $nivel = 'ERROR' }
    Set-CleanupResult $nivel 'resultado consolidado da limpeza'

    $pares = [ordered]@{
        'Alvos processados'        = $todas.Count
        'Alvos limpos'             = $limpos
        'Alvos parciais'           = $parciais
        'Alvos ja limpos'          = @($todas | Where-Object { $_.Estado -eq 'nada a remover' }).Count
        'Alvos inexistentes'       = $inexistentes
        'Alvos com falha'          = $falhos.Count
        'Itens removidos'          = $removidos
        'Itens em uso (preservados)' = $bloqueados
        'Soma logica liberada'     = (ConvertTo-CompartDiskSize $liberado)
        'Ganho real no volume'     = $ganhoTexto
        'Lixeira'                  = $(if ($lixeira.Executada) { $lixeira.Detalhe } else { $lixeira.Detalhe })
        'Cache DNS'                = $(if ($dns.Executada) { $dns.Detalhe } else { $dns.Detalhe })
        'Status final'             = $nivel
    }
    Add-CompartDiskSection -Title 'Limpeza executada' -Status (Get-CleanupSectionStatus $nivel) -Rows $todas -Pairs $pares `
        -Summary ("{0} de {1} alvo(s) limpo(s); soma logica {2}; ganho real {3}" -f $limpos, $todas.Count, (ConvertTo-CompartDiskSize $liberado), $ganhoTexto)

    $jaLimpos = @($todas | Where-Object { $_.Estado -eq 'nada a remover' }).Count
    $msg = ("{0} removidos dos alvos selecionados em {1} item(ns); {2} item(ns) permaneceram em uso; {3} alvo(s) ja estavam limpos; ganho real no volume: {4}." -f `
        (ConvertTo-CompartDiskSize $liberado), $removidos, $bloqueados, $jaLimpos, $ganhoTexto)
    $rec = ''
    if ($bloqueados -gt 0) { $rec = 'Itens em uso sao preservados por seguranca: repetir apos fechar as aplicacoes que os mantem abertos.' }
    if ($falhos.Count -gt 0) { $rec = 'Conferir os alvos com falha na tabela da secao antes de repetir a operacao.' }
    if (-not $ganhoOk) { $rec = ('O ganho real nao pode ser medido ({0}); a soma logica permanece valida como referencia.' -f (Get-CleanupSafeText $espacoAntes.Detalhe '')) }

    Add-CompartDiskFinding -Severity (Get-CleanupFindingSeverity $nivel) -Area 'Limpeza' -Message $msg -Recommendation $rec
    if ($lixeira.Executada -and $lixeira.Ok) {
        Add-CompartDiskFinding -Severity INFO -Area 'Limpeza' `
            -Message 'A Lixeira foi esvaziada: os arquivos que estavam nela foram excluidos em definitivo.' `
            -Recommendation 'Usar -SkipRecycleBin quando a Lixeira nao deva ser tocada.'
    }
    $diag = @($todas | Where-Object { $_.Categoria -eq 'Diagnostico' -and ($_.Removidos -gt 0) })
    if (@($diag).Count -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Limpeza' `
            -Message ("{0} alvo(s) de dados de diagnostico foram limpos (WER, dumps ou logs de servicing)." -f @($diag).Count) `
            -Recommendation 'Para investigacoes futuras, coletar o diagnostico necessario antes de repetir a limpeza desses alvos.'
    }
    if ($nivel -eq 'OK') { Write-Log OK $msg } else { Write-Log WARN $msg }
}

# ==============================================================================
# ACAO: LOGS  (modificadora, com backup obrigatorio)
#
# REGRA ABSOLUTA: um log so e limpo depois que a exportacao dele foi validada.
# Backup falhou -> log NAO e limpo.
#
# O conjunto e explicitamente definido (System, Application, Security, Setup).
# A versao anterior enumerava TODOS os canais com 'wevtutil el' e limpava todos,
# exportando apenas tres: centenas de canais operacionais - inclusive os de
# seguranca e de aplicacoes - eram apagados sem qualquer copia. Canais fora da
# lista passam a ser preservados.
# ==============================================================================
$script:LogsSelecionados = @('System', 'Application', 'Security', 'Setup')

function Test-CleanupBackupFile {
    <# Backup so vale se o arquivo existe, foi gravado NESTA execucao, tem
       conteudo e pode ser lido. Test-Path sozinho aceitaria arquivo antigo. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][datetime]$Desde, [long]$TamanhoMinimo = 1)
    $out = [pscustomobject]@{ Ok = $false; Bytes = 0; Detalhe = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $out.Detalhe = 'arquivo de backup nao foi criado'; return $out }
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $out.Bytes = [long]$fi.Length
        if ($fi.LastWriteTime -lt $Desde.AddSeconds(-5)) { $out.Detalhe = 'arquivo preexistente: nao foi gravado por esta execucao'; return $out }
        if ($fi.Length -lt $TamanhoMinimo) { $out.Detalhe = ('arquivo com {0} byte(s), abaixo do minimo esperado' -f $fi.Length); return $out }
        $fs = [System.IO.File]::OpenRead($fi.FullName)
        try {
            $buf = New-Object byte[] 16
            if ($fs.Read($buf, 0, 16) -le 0) { $out.Detalhe = 'arquivo de backup nao pode ser lido'; return $out }
        } finally { $fs.Dispose() }
        $out.Ok = $true
    } catch {
        $out.Detalhe = $_.Exception.Message
    }
    return $out
}

function Get-CleanupAvailableLogs {
    param([Parameter(Mandatory)][string]$WevtUtil)
    $out = [pscustomobject]@{ Ok = $false; Nomes = @(); Total = 0; Detalhe = '' }
    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $WevtUtil -Arguments @('el') -TimeoutSeconds 120 } -Activity 'wevtutil el' -Silent
    if (-not $r.Success -or $null -eq $r.Value -or [int]$r.Value.ExitCode -ne 0) {
        $out.Detalhe = $(if ($r.Error) { $r.Error.Exception.Message } else { ('wevtutil el retornou codigo {0}' -f $(if ($r.Value) { $r.Value.ExitCode } else { 'n/d' })) })
        return $out
    }
    $nomes = New-Object System.Collections.ArrayList
    foreach ($linha in ("$($r.Value.StdOut)" -split "`r?`n")) {
        $n = $linha.Trim()
        if ($n) { [void]$nomes.Add($n) }
    }
    $out.Ok = $true; $out.Nomes = @($nomes); $out.Total = $nomes.Count
    return $out
}

function Clear-EventLogs {
    Write-Log WARN 'Limpar logs de eventos reduz a capacidade de investigacao posterior. Cada log selecionado so sera limpo apos backup validado.'

    $wevtutil = Join-Path $env:SystemRoot 'System32\wevtutil.exe'
    if (-not (Test-Path -LiteralPath $wevtutil)) {
        Write-Log ERR 'wevtutil.exe nao localizado: nenhum log foi tocado.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Limpeza' `
            -Message 'wevtutil.exe nao localizado: a limpeza de logs de eventos nao pode ser executada.' `
            -Recommendation 'Componente nativo ausente: avaliar a integridade do Windows com DISM /RestoreHealth e SFC /scannow.'
        Add-CompartDiskSection -Title 'Logs de eventos' -Status CRIT -Summary 'wevtutil.exe indisponivel; nenhum log alterado'
        Set-CleanupResult 'ERROR' 'wevtutil ausente'
        return
    }

    # Diretorio exclusivo por execucao: preserva backups anteriores e evita que
    # 'wevtutil epl' falhe por arquivo ja existente (o que, na versao anterior,
    # fazia a segunda execucao limpar os logs sem backup nenhum).
    $raizBkp = Join-Path $Global:CompartDisk.OutDir 'EventLogs_Backup'
    $carimbo = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $destino = Join-Path $raizBkp $carimbo
    $sufixo = 1
    while (Test-Path -LiteralPath $destino) {
        $destino = Join-Path $raizBkp ('{0}_{1}' -f $carimbo, $sufixo)
        $sufixo++
        if ($sufixo -gt 50) { break }
    }
    $prep = Invoke-SafeCommand { New-Item -ItemType Directory -Path $destino -Force -ErrorAction Stop | Out-Null } -Activity 'Criar diretorio de backup' -Silent
    if (-not $prep.Success -or -not (Test-Path -LiteralPath $destino -PathType Container)) {
        $motivo = $(if ($prep.Error) { $prep.Error.Exception.Message } else { 'o diretorio nao existe apos a criacao' })
        Write-Log ERR ('Diretorio de backup dos logs nao pode ser preparado: {0}. Nenhum log foi limpo.' -f $motivo)
        Add-CompartDiskFinding -Severity CRIT -Area 'Limpeza' `
            -Message ('Limpeza de logs abortada: o diretorio de backup nao pode ser preparado ({0}).' -f $motivo) `
            -Recommendation 'Definir COMPARTDISK_LOGDIR para um diretorio gravavel e repetir.'
        Add-CompartDiskSection -Title 'Logs de eventos' -Status CRIT -Summary 'Abortado: destino de backup indisponivel; nenhum log alterado'
        Set-CleanupResult 'ERROR' 'destino de backup indisponivel'
        return
    }

    $disponiveis = Get-CleanupAvailableLogs -WevtUtil $wevtutil
    if (-not $disponiveis.Ok) {
        Write-Log WARN ('Nao foi possivel enumerar os canais de log: {0}. A selecao fixa sera tentada mesmo assim.' -f $disponiveis.Detalhe)
    }

    $linhas = New-Object System.Collections.ArrayList
    foreach ($log in $script:LogsSelecionados) {
        $reg = [pscustomobject]@{
            Log = $log; Existe = 'n/d'; Backup = ''; BackupBytes = 0
            Exportado = 'nao'; Limpo = 'nao'; Resultado = 'nao processado'; Detalhe = ''
        }

        if ($disponiveis.Ok -and (@($disponiveis.Nomes) -notcontains $log)) {
            $reg.Existe = 'nao'; $reg.Resultado = 'inexistente'
            $reg.Detalhe = 'canal nao existe neste sistema'
            [void]$linhas.Add($reg); continue
        }
        $reg.Existe = 'sim'

        $inicio = Get-Date
        $arquivo = Join-Path $destino ("{0}.evtx" -f ($log -replace '[\\/:*?"<>|]', '_'))
        $reg.Backup = $arquivo

        $e = Invoke-SafeCommand {
            Invoke-NativeCommand -FilePath $wevtutil -Arguments @('epl', "`"$log`"", "`"$arquivo`"") -TimeoutSeconds 300
        } -Activity ("Exportar log {0}" -f $log) -Silent

        $exportOk = ($e.Success -and $null -ne $e.Value -and [int]$e.Value.ExitCode -eq 0)
        $val = Test-CleanupBackupFile -Path $arquivo -Desde $inicio -TamanhoMinimo 1024
        if (-not $exportOk -or -not $val.Ok) {
            $motivo = ''
            if (-not $exportOk) {
                $motivo = $(if ($null -ne $e.Value) { ('wevtutil epl retornou {0}: {1}' -f $e.Value.ExitCode, ("$($e.Value.StdErr)" -split "`r?`n" | Select-Object -First 1)) }
                            elseif ($e.Error) { $e.Error.Exception.Message } else { 'exportacao nao concluida' })
            } else { $motivo = $val.Detalhe }
            $reg.Resultado = 'preservado (backup falhou)'
            $reg.Detalhe = $motivo
            Write-Log WARN ("Log '{0}' NAO foi limpo: o backup nao pode ser validado ({1})." -f $log, $motivo)
            [void]$linhas.Add($reg); continue
        }

        $reg.Exportado = 'sim'
        $reg.BackupBytes = $val.Bytes
        Write-Log OK ("Backup do log '{0}' validado ({1})." -f $log, (ConvertTo-CompartDiskSize $val.Bytes))

        $c = Invoke-SafeCommand {
            Invoke-NativeCommand -FilePath $wevtutil -Arguments @('cl', "`"$log`"") -TimeoutSeconds 120
        } -Activity ("Limpar log {0}" -f $log) -Silent
        if ($c.Success -and $null -ne $c.Value -and [int]$c.Value.ExitCode -eq 0) {
            $reg.Limpo = 'sim'; $reg.Resultado = 'limpo com backup'
            Write-Log OK ("Log '{0}' limpo; copia preservada em {1}." -f $log, $arquivo)
        } else {
            $reg.Resultado = 'backup ok, limpeza recusada'
            $reg.Detalhe = $(if ($null -ne $c.Value) { ('wevtutil cl retornou {0}: {1}' -f $c.Value.ExitCode, ("$($c.Value.StdErr)" -split "`r?`n" | Select-Object -First 1)) }
                             elseif ($c.Error) { $c.Error.Exception.Message } else { 'limpeza nao concluida' })
            Write-Log WARN ("Log '{0}' nao pode ser limpo: {1}" -f $log, $reg.Detalhe)
        }
        [void]$linhas.Add($reg)
    }

    $todos       = @($linhas)
    $exportados  = @($todos | Where-Object { $_.Exportado -eq 'sim' })
    $limpos      = @($todos | Where-Object { $_.Limpo -eq 'sim' })
    $preservados = @($todos | Where-Object { $_.Resultado -eq 'preservado (backup falhou)' })
    $inexistentes= @($todos | Where-Object { $_.Resultado -eq 'inexistente' })
    $naoLimpos   = @($todos | Where-Object { $_.Resultado -eq 'backup ok, limpeza recusada' })
    $bytesBkp    = 0
    foreach ($l in $todos) { $bytesBkp += [long]$l.BackupBytes }

    Write-CleanupLine ''
    Write-CleanupTable -Rows $todos -Property @('Log', 'Existe', 'Exportado', 'Limpo', 'Resultado')

    # ------------------------------------------------------------------- dumps
    $dumps = @(Get-CleanupTargets -IncludeLogs | Where-Object { $_.Grupo -eq 'Logs' })
    $linhasDump = New-Object System.Collections.ArrayList
    $bytesDump = 0
    foreach ($d in $dumps) {
        $r = Invoke-CleanupTarget -Target $d
        [void]$linhasDump.Add($r)
        $bytesDump += [long]$r.BytesLiberados
        switch ($r.Estado) {
            'removido'    { Write-Log OK ("{0}: {1} liberados." -f $r.Alvo, (ConvertTo-CompartDiskSize $r.BytesLiberados)) }
            'limpo'       { Write-Log OK ("{0}: {1} liberados em {2} item(ns)." -f $r.Alvo, (ConvertTo-CompartDiskSize $r.BytesLiberados), $r.Removidos) }
            'inexistente' { Write-Log INFO ("{0}: nao presente neste sistema." -f $r.Alvo) }
            'nada a remover' { Write-Log INFO ("{0}: nada a remover." -f $r.Alvo) }
            default       { Write-Log WARN ("{0}: {1} ({2})." -f $r.Alvo, $r.Estado, (Get-CleanupSafeText $r.Detalhe '')) }
        }
    }
    $dumpsFalhos = @($linhasDump | Where-Object { $_.Estado -eq 'bloqueado' -or $_.Estado -eq 'falhou' -or $_.Estado -eq 'parcial' -or $_.Estado -eq 'bloqueado por protecao' })

    # ------------------------------------------------------------------ status
    $nivel = 'OK'
    if ($preservados.Count -gt 0 -or $naoLimpos.Count -gt 0 -or @($dumpsFalhos).Count -gt 0) { $nivel = 'WARN' }
    if (-not $disponiveis.Ok) { $nivel = 'WARN' }
    if ($exportados.Count -eq 0 -and $inexistentes.Count -lt $todos.Count) { $nivel = 'ERROR' }
    Set-CleanupResult $nivel 'resultado consolidado da limpeza de logs'

    $pares = [ordered]@{
        'Canais existentes no sistema' = $(if ($disponiveis.Ok) { $disponiveis.Total } else { 'nao enumerado' })
        'Canais selecionados'          = ($script:LogsSelecionados -join ', ')
        'Canais preservados'           = $(if ($disponiveis.Ok) { [math]::Max(0, $disponiveis.Total - $limpos.Count) } else { 'nao enumerado' })
        'Logs exportados'              = $exportados.Count
        'Logs limpos'                  = $limpos.Count
        'Logs nao limpos (sem backup)' = $preservados.Count
        'Logs nao limpos (recusados)'  = $naoLimpos.Count
        'Logs inexistentes'            = $inexistentes.Count
        'Tamanho dos backups'          = (ConvertTo-CompartDiskSize $bytesBkp)
        'Diretorio de backup'          = $destino
        'Dumps liberados'              = (ConvertTo-CompartDiskSize $bytesDump)
        'Status final'                 = $nivel
    }
    Add-CompartDiskSection -Title 'Logs de eventos' -Status (Get-CleanupSectionStatus $nivel) -Rows $todos -Pairs $pares `
        -Summary ("{0} de {1} canal(is) selecionado(s) limpo(s) com backup validado" -f $limpos.Count, $todos.Count)
    if (@($linhasDump).Count -gt 0) {
        Add-CompartDiskSection -Title 'Despejos de falha (dumps)' -Status $(if (@($dumpsFalhos).Count -gt 0) { 'WARN' } else { 'INFO' }) `
            -Rows @($linhasDump) -Summary ("{0} liberados em despejos de falha" -f (ConvertTo-CompartDiskSize $bytesDump))
    }

    $msg = ("{0} de {1} canal(is) selecionado(s) limpo(s), todos com backup validado em {2}; {3} preservado(s) por falha de backup; {4} em despejos removidos." -f `
        $limpos.Count, $todos.Count, $destino, $preservados.Count, (ConvertTo-CompartDiskSize $bytesDump))
    $rec = 'Os canais fora da selecao fixa nao sao tocados. Para investigacoes futuras, colete o diagnostico necessario antes de repetir esta acao.'
    if ($preservados.Count -gt 0) {
        $rec = 'Os canais sem backup validado NAO foram limpos, por seguranca. Executar como administrador e repetir; o canal Security costuma exigir privilegio adicional.'
    }
    Add-CompartDiskFinding -Severity (Get-CleanupFindingSeverity $nivel) -Area 'Limpeza' -Message $msg -Recommendation $rec
    Add-CompartDiskFinding -Severity INFO -Area 'Limpeza' `
        -Message 'A limpeza de logs de eventos e de despejos remove evidencia usada em auditoria e em analise de falhas.' `
        -Recommendation ("As copias dos canais limpos estao em {0} e podem ser abertas no Visualizador de Eventos." -f $destino)
    if ($nivel -eq 'OK') { Write-Log OK $msg } elseif ($nivel -eq 'WARN') { Write-Log WARN $msg } else { Write-Log ERR $msg }
}

# ==============================================================================
# DESPACHO
# Analyze e Browsers atuam sobre dados do usuario atual e nao exigem elevacao:
# sem administrador a analise apenas enxerga menos, e isso e reportado.
# Standard, Deep e Logs alcancam Windows, ProgramData e o log de eventos, e
# por isso exigem administrador.
# ==============================================================================
$codigo = $Global:CompartDisk.Exit.ERROR
try {
    $precisaAdmin = @('Standard', 'Deep', 'Logs') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Cleanup' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # Sem isto o estado persistido para o Report.ps1 sairia como OK enquanto
        # o modulo devolvia codigo de erro.
        Set-CleanupResult 'ERROR' 'privilegios administrativos ausentes'
    } else {
        if (-not $precisaAdmin -and -not (Test-Administrator)) {
            Write-Log INFO 'Execucao sem privilegios administrativos: alvos do sistema podem nao ser medidos ou acessados por completo.'
        }
        switch ($Action) {
            'Analyze' {
                # Somente leitura: o conjunto completo e medido e apresentado por
                # grupo, para que o numero corresponda a acao que sera executada.
                Invoke-CleanupAnalysis -Targets (Get-CleanupTargets -IncludeDeep -IncludeBrowsers -IncludeLogs)
            }
            'Standard' {
                Invoke-Cleanup -Targets (Get-CleanupTargets)
            }
            'Deep' {
                Invoke-Cleanup -Targets (Get-CleanupTargets -IncludeDeep -IncludeBrowsers)
            }
            'Browsers' {
                Invoke-Cleanup -Targets @(Get-CleanupTargets -IncludeBrowsers | Where-Object { $_.Grupo -eq 'Navegadores' }) -IsBrowsers
            }
            'Logs' {
                Clear-EventLogs
            }
        }
    }
} catch {
    Set-CleanupResult 'ERROR' 'excecao nao tratada'
    Write-Log ERR "Falha nao tratada no modulo Cleanup (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Limpeza' `
        -Message ("Excecao no modulo durante a acao '{0}': {1}" -f $Action, $_.Exception.Message) `
        -Recommendation 'Consultar o log detalhado da sessao para a etapa exata e o codigo do erro.'
} finally {
    $codigo = Stop-CompartDiskModule -Result $script:result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$script:result] }
}
exit ([int]$codigo)
