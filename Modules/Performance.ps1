<#
 COMPARTDISK 1.4.6 - Performance.ps1
 Desenvolvido por Edsilas

 Acoes: Analyze | Ultimate | Balanced | Startup | Processes | Services

 Revisao tecnica: correcao de escopo de resultado, eliminacao de falhas silenciosas,
 fluxo DETECTAR -> PREPARAR -> APLICAR -> CONSULTAR -> VALIDAR -> CORRIGIR -> VALIDAR,
 idempotencia real do plano de energia e deteccao de Modern Standby / S0.

 Dependencia: Core.ps1 (mesmo diretorio). Nenhuma funcao nova do Core e exigida:
 este modulo usa exatamente a mesma superficie de API da versao anterior.

 Compatibilidade: Windows PowerShell 5.1 e PowerShell 7.x no Windows, x64 e x86.
 Nenhuma sintaxe exclusiva do PowerShell 7 e utilizada.

 PARAMETROS OPCIONAIS (novos, com padrao que preserva o comportamento anterior):
   -SkipVisualEffects  Nao altera efeitos visuais (padrao: altera, como antes).
   -IncludeDcSettings  Aplica tambem o perfil de desempenho em bateria (padrao: nao).
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Ultimate', 'Balanced', 'Startup', 'Processes', 'Services')]
    [string]$Action = 'Analyze',
    [switch]$Quiet,
    [switch]$SkipVisualEffects,
    [switch]$IncludeDcSettings
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# 0. CARGA DO CORE - com validacao explicita (antes: falha de carga = stacktrace)
# ============================================================================

# Codigos de saida usados apenas quando o Core nao esta disponivel para informa-los.
$script:FallbackExit = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

$script:PerfRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:PerfRoot) -and $MyInvocation.MyCommand.Path) {
    $script:PerfRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($script:PerfRoot)) { $script:PerfRoot = (Get-Location).Path }

$script:CorePath = Join-Path $script:PerfRoot 'Core.ps1'
if (-not (Test-Path -LiteralPath $script:CorePath -PathType Leaf)) {
    [Console]::Error.WriteLine("COMPARTDISK/Performance: Core.ps1 nao encontrado em '$($script:CorePath)'.")
    exit $script:FallbackExit['ERROR']
}
try {
    . $script:CorePath
} catch {
    [Console]::Error.WriteLine("COMPARTDISK/Performance: falha ao carregar Core.ps1 -> $($_.Exception.Message)")
    exit $script:FallbackExit['ERROR']
}

# Funcoes do Core sem as quais o modulo nao pode sequer reportar resultado.
$script:CoreRequired = @(
    'Start-CompartDiskModule', 'Stop-CompartDiskModule', 'Invoke-NativeCommand',
    'Write-Log', 'Add-CompartDiskFinding', 'Add-CompartDiskSection',
    'Set-CompartDiskRegistryValue', 'Write-Color', 'Write-CompartDiskKeyValue'
)
$script:CoreMissing = @()
foreach ($fn in $script:CoreRequired) {
    if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { $script:CoreMissing += $fn }
}
if ($script:CoreMissing.Count -gt 0) {
    [Console]::Error.WriteLine("COMPARTDISK/Performance: Core.ps1 carregado, mas faltam funcoes: $($script:CoreMissing -join ', ')")
    exit $script:FallbackExit['ERROR']
}

# ============================================================================
# 1. CONSTANTES - GUIDs oficiais e documentados pela Microsoft
# ============================================================================

# Planos de energia (power schemes)
$GUID_ULTIMATE = 'e9a42b02-d5df-448d-aa00-03f14749eb61'   # Ultimate Performance
$GUID_HIGH     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'   # High Performance
$GUID_BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'   # Balanced
$GUID_SAVER    = 'a1841308-3541-4fab-bc81-f71556f20b4a'   # Power Saver

# Power Mode overlays (Windows 10 1709+ / Windows 11). Mecanismo nativo usado
# quando o dispositivo nao expoe planos de alto desempenho (tipico em Modern Standby).
$OVL_RECOMMENDED = '00000000-0000-0000-0000-000000000000'
$OVL_BESTPERF    = 'ded574b5-45a0-4f42-8737-46345c09c238'
$OVL_EFFICIENCY  = '961cc777-2547-4f9d-8174-7d86181b8a7a'

# Subgrupos
$SUB_PROCESSOR  = '54533251-82be-4824-96c1-47b60b740d00'
$SUB_PCIEXPRESS = '501a4d13-42af-4429-9fd1-a8218c268e20'
$SUB_USB        = '2a737441-1930-4402-8d77-b2bebba308a3'
$SUB_DISK       = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$SUB_VIDEO      = '7516b95f-f776-4464-8c53-06167f40cc99'
$SUB_SLEEP      = '238c9fa8-0aad-41ed-83f4-97be242c8f20'

# Caminhos de registro (somente leitura, exceto VisualFXSetting)
$REG_POWER      = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$REG_SCHEMES    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$REG_VISUALFX   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
$REG_NLS_CP     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'

# O plano de Desempenho Maximo usa SEMPRE a nomenclatura do proprio Windows.
# Nenhum nome personalizado e atribuido: o plano duplicado herda do modelo do
# sistema o nome localizado ("Desempenho maximo" / "Ultimate Performance"), e
# a reutilizacao entre execucoes e resolvida por GUID e por comparacao de nome
# lido do sistema, nunca por um rotulo proprio.

# Estado de ambiente, preenchido por Initialize-PerfEnvironment
$script:PowercfgPath = $null
$script:PowercfgOk   = $false
$script:IsAdmin      = $false
$script:IsSystem     = $false
$script:HasBattery   = $false
$script:ModernStandby = $false
$script:SleepStates  = $null
$script:HibernateEnabled = $null
$script:OsCaption    = ''

# ============================================================================
# 2. RESULTADO CENTRALIZADO E DETERMINISTICO
#    Antes: $result / $script:result misturados; um WARN podia nao chegar ao final.
#    Agora: uma unica variavel de escopo script, que so escala (nunca rebaixa).
# ============================================================================

$script:ModuleResult = 'OK'
$script:ResultRank   = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-PerfResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'WARN', 'ERROR')]
        [string]$Result
    )
    if ($script:ResultRank[$Result] -gt $script:ResultRank[$script:ModuleResult]) {
        $script:ModuleResult = $Result
    }
}

function Get-PerfExitCode {
    [CmdletBinding()]
    param([string]$Name, [int]$Default)
    try {
        if ($Global:CompartDisk -and $Global:CompartDisk.Exit) {
            $v = $Global:CompartDisk.Exit.$Name
            if ($null -ne $v) { return [int]$v }
        }
    } catch {
        Write-Verbose "Nao foi possivel ler CompartDisk.Exit.$Name -> $($_.Exception.Message)"
    }
    return $Default
}

function Test-PerfCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

# ============================================================================
# 3. CAMADA POWERCFG - toda chamada avalia ExitCode + StdOut + StdErr + excecao
# ============================================================================

function Initialize-PerfEnvironment {
    [CmdletBinding()]
    param()

    # --- powercfg.exe -------------------------------------------------------
    # Em processo 32-bit sobre Windows x64, System32 sofre redirecionamento WOW64.
    # Sysnative da acesso ao binario nativo. Testamos os candidatos na ordem certa.
    $candidatos = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            [void]$candidatos.Add((Join-Path $env:SystemRoot 'Sysnative\powercfg.exe'))
        }
        [void]$candidatos.Add((Join-Path $env:SystemRoot 'System32\powercfg.exe'))
    }
    try {
        $cmd = Get-Command -Name 'powercfg.exe' -CommandType Application -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { [void]$candidatos.Add($cmd.Source) }
    } catch {
        Write-Verbose "Get-Command powercfg.exe falhou -> $($_.Exception.Message)"
    }
    foreach ($c in $candidatos) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $script:PowercfgPath = $c; break }
    }
    $script:PowercfgOk = (-not [string]::IsNullOrWhiteSpace($script:PowercfgPath))
    if (-not $script:PowercfgOk) {
        Write-Log WARN 'powercfg.exe nao foi localizado. Operacoes de energia serao ignoradas.'
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
            -Message 'powercfg.exe nao encontrado neste sistema.' `
            -Recommendation 'Verificar a integridade do Windows com "sfc /scannow" e "DISM /Online /Cleanup-Image /RestoreHealth".'
        Set-PerfResult 'WARN'
    }

    # --- identidade / privilegio -------------------------------------------
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($id.User -and $id.User.Value -eq 'S-1-5-18') { $script:IsSystem = $true }
    } catch {
        Write-Log WARN "Nao foi possivel determinar o nivel de privilegio: $($_.Exception.Message)"
    }

    # --- SO ------------------------------------------------------------------
    if (Test-PerfCommand 'Get-CompartDiskCim') {
        try {
            $os = Get-CompartDiskCim -Class Win32_OperatingSystem
            if ($os) { $script:OsCaption = ("{0} (build {1})" -f $os.Caption, $os.BuildNumber) }
        } catch {
            Write-Verbose "Win32_OperatingSystem indisponivel -> $($_.Exception.Message)"
        }
        try {
            $bat = @(Get-CompartDiskCim -Class Win32_Battery)
            $script:HasBattery = ($bat.Count -gt 0)
        } catch {
            Write-Verbose "Win32_Battery indisponivel -> $($_.Exception.Message)"
        }
    }

    # --- hibernacao (leitura nativa, independente de idioma) ------------------
    $script:HibernateEnabled = Get-PerfRegistryDword -Path $REG_POWER -Name 'HibernateEnabled'

    # --- Modern Standby / S0 --------------------------------------------------
    $script:SleepStates = Get-PerfSleepCapabilities
    $cs = Get-PerfRegistryDword -Path $REG_POWER -Name 'CsEnabled'
    $temS0 = $false
    if ($script:SleepStates -and $script:SleepStates.Disponiveis) {
        foreach ($s in $script:SleepStates.Disponiveis) { if ($s -match '(?i)\bS0\b') { $temS0 = $true } }
    }
    $script:ModernStandby = (($cs -eq 1) -or $temS0)
}

function Get-PerfRegistryDword {
    <# Leitura defensiva de um DWORD. Retorna $null se ausente ou inacessivel. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        if ($null -eq $item) { return $null }
        return [int]$item.$Name
    } catch {
        Write-Verbose "Registro ausente/inacessivel: $Path\$Name -> $($_.Exception.Message)"
        return $null
    }
}

function Get-PerfRegistryString {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        if ($null -eq $item) { return $null }
        return [string]$item.$Name
    } catch {
        Write-Verbose "Registro ausente/inacessivel: $Path\$Name -> $($_.Exception.Message)"
        return $null
    }
}

# ----------------------------------------------------------------------------
# 3.1 CODIFICACAO DA SAIDA NATIVA
#
# EVIDENCIA: o log trazia "Desempenho M?ximo" e "N?o foi poss?vel" no lugar dos
# acentos. O powercfg.exe NAO escreve UTF-8 quando sua saida e redirecionada:
# usa a pagina de codigo OEM do sistema (850 em pt-BR). Como o Launcher executa
# "chcp 65001", [Console]::OutputEncoding e UTF-8 e era essa a codificacao que o
# .NET usava para decodificar o canal redirecionado - cada byte acentuado do
# powercfg virava U+FFFD, de forma irreversivel.
#
# A correcao fica CONTIDA neste modulo: a saida passa a ser capturada em BYTES e
# so depois decodificada, sem supor a codificacao. A infraestrutura global de
# execucao de processos (Invoke-NativeCommand, no Core.ps1) nao e alterada.
# ----------------------------------------------------------------------------

$script:NativeEncoding = $null

function Get-PerfNativeEncoding {
    <#
      Pagina de codigo OEM real do sistema, resolvida uma unica vez.
      Ordem: registro do proprio Windows (fonte autoritativa) -> cultura
      corrente -> 850. Somente APIs nativas; nenhuma dependencia nova.
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:NativeEncoding) { return $script:NativeEncoding }

    $candidatos = New-Object System.Collections.ArrayList
    $oemcp = Get-PerfRegistryString -Path $REG_NLS_CP -Name 'OEMCP'
    if (-not [string]::IsNullOrWhiteSpace($oemcp)) {
        $n = 0
        if ([int]::TryParse($oemcp.Trim(), [ref]$n)) { [void]$candidatos.Add($n) }
    }
    try {
        [void]$candidatos.Add([int][System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    } catch {
        Write-Verbose "OEMCodePage da cultura corrente indisponivel -> $($_.Exception.Message)"
    }
    [void]$candidatos.Add(850)

    foreach ($cp in $candidatos) {
        # 65001 aqui seria exatamente a suposicao errada que originou o defeito.
        if ($cp -le 0 -or $cp -eq 65001) { continue }
        try {
            $script:NativeEncoding = [System.Text.Encoding]::GetEncoding($cp)
            break
        } catch {
            Write-Verbose "Pagina de codigo $cp indisponivel -> $($_.Exception.Message)"
        }
    }
    if ($null -eq $script:NativeEncoding) { $script:NativeEncoding = [System.Text.Encoding]::Default }
    return $script:NativeEncoding
}

function ConvertFrom-PerfNativeBytes {
    <#
      Decodifica a saida bruta de um executavel nativo SEM assumir UTF-8:
        1) UTF-8 estrito - texto ASCII puro e saida realmente UTF-8 passam intactos;
        2) pagina de codigo OEM - a unica leitura correta para o powercfg em pt-BR.
      A ordem importa: ASCII e UTF-8 valido, entao (1) jamais degrada o que ja
      funcionava, e (2) so entra em acao para bytes que (1) rejeita.
    #>
    [CmdletBinding()]
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $texto = $null
    try {
        $utf8Estrito = New-Object System.Text.UTF8Encoding($false, $true)
        $texto = $utf8Estrito.GetString($Bytes)
    } catch {
        Write-Verbose 'Saida nativa nao e UTF-8 valido; decodificando na pagina de codigo OEM.'
        $texto = (Get-PerfNativeEncoding).GetString($Bytes)
    }
    if ($texto.Length -gt 0 -and $texto[0] -eq [char]0xFEFF) { $texto = $texto.Substring(1) }
    return $texto
}

function Invoke-PerfNativeProcess {
    <#
      Executa um binario nativo capturando stdout/stderr em BYTES.

      Mesma estrutura - e mesmo motivo - do Invoke-NativeCommand do Core: os dois
      canais sao drenados CONCORRENTEMENTE, senao o processo filho trava ao
      encher o buffer do canal ainda nao lido e o tempo limite jamais chega a ser
      avaliado. A unica diferenca esta na captura em bytes, que permite decodificar
      depois na codificacao correta em vez de na codificacao do console.

      Devolve o mesmo formato de Invoke-NativeCommand: {ExitCode,StdOut,StdErr,Success}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = ($Arguments -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc   = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $bufOut = New-Object System.IO.MemoryStream
    $bufErr = New-Object System.IO.MemoryStream
    try {
        [void]$proc.Start()

        # CopyToAsync existe desde o .NET 4.5: nativo no Windows 10/11, valido em
        # Windows PowerShell 5.1 e em PowerShell 7.
        $tarefaOut = $proc.StandardOutput.BaseStream.CopyToAsync($bufOut)
        $tarefaErr = $proc.StandardError.BaseStream.CopyToAsync($bufErr)

        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch { Write-Verbose 'O processo ja havia encerrado ao ser interrompido.' }
                throw "Tempo limite excedido ($TimeoutSeconds s) em $FilePath"
            }
        } else {
            $proc.WaitForExit()
        }

        # Os canais fecham no encerramento do processo: a copia conclui aqui.
        $tarefaOut.Wait()
        $tarefaErr.Wait()

        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = (ConvertFrom-PerfNativeBytes -Bytes $bufOut.ToArray())
            StdErr   = (ConvertFrom-PerfNativeBytes -Bytes $bufErr.ToArray())
            Success  = ($proc.ExitCode -eq 0)
        }
    } finally {
        if ($bufOut) { $bufOut.Dispose() }
        if ($bufErr) { $bufErr.Dispose() }
        if ($proc)   { $proc.Dispose() }
    }
}

function Invoke-PerfPowercfg {
    <#
      Envelope unico para powercfg.exe.
      Sempre retorna um objeto - nunca lanca - com Invoked/ExitCode/StdOut/StdErr/Error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30,
        [string]$Step = ''
    )
    $r = [pscustomobject]@{
        Step      = $Step
        Arguments = ($Arguments -join ' ')
        Invoked   = $false
        ExitCode  = $null
        StdOut    = ''
        StdErr    = ''
        Error     = ''
    }
    if (-not $script:PowercfgOk) {
        $r.Error = 'powercfg.exe indisponivel neste sistema'
        return $r
    }
    try {
        # EVIDENCIA: no log de 13/08/2026 um argumento com espaco chegou ao
        # powercfg como varios parametros separados, porque o executor une os
        # argumentos com espaco, e o comando falhou com "Parametros invalidos".
        # O aspeamento continua necessario para qualquer argumento com espaco -
        # a comecar pelo nome localizado dos planos do Windows.
        $argsSeguros = @()
        foreach ($a in @($Arguments)) {
            $t = "$a"
            if ($t -match '\s' -and -not $t.StartsWith('"')) { $argsSeguros += ('"' + $t + '"') }
            else { $argsSeguros += $t }
        }
        $raw = Invoke-PerfNativeProcess -FilePath $script:PowercfgPath -Arguments $argsSeguros -TimeoutSeconds $TimeoutSeconds
        if ($null -eq $raw) {
            $r.Error = 'a execucao do powercfg retornou nulo (possivel timeout de ' + $TimeoutSeconds + 's)'
            return $r
        }
        $r.Invoked = $true
        if ($null -ne $raw.ExitCode) {
            try { $r.ExitCode = [int]$raw.ExitCode } catch { $r.ExitCode = $null }
        }
        if ($null -ne $raw.StdOut) { $r.StdOut = [string]$raw.StdOut }
        if ($null -ne $raw.StdErr) { $r.StdErr = [string]$raw.StdErr }
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}

function Test-PerfCommandOk {
    <# Sucesso real = executou E retornou ExitCode 0. Ausencia de excecao nao basta. #>
    [CmdletBinding()]
    param($Result)
    return ($null -ne $Result -and $Result.Invoked -and $Result.ExitCode -eq 0)
}

function Get-PerfCommandDetail {
    <# Texto curto e util para o log: por que a chamada falhou. #>
    [CmdletBinding()]
    param($Result)
    if ($null -eq $Result) { return 'resultado nulo' }
    $partes = New-Object System.Collections.ArrayList
    if (-not $Result.Invoked) { [void]$partes.Add("nao executado: $($Result.Error)") }
    else { [void]$partes.Add("ExitCode=$($Result.ExitCode)") }
    $err = ''
    if (-not [string]::IsNullOrWhiteSpace($Result.StdErr)) { $err = $Result.StdErr }
    elseif (-not [string]::IsNullOrWhiteSpace($Result.StdOut)) { $err = $Result.StdOut }
    if (-not [string]::IsNullOrWhiteSpace($err)) {
        $linha = (($err -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($linha) {
            $linha = $linha.Trim()
            if ($linha.Length -gt 160) { $linha = $linha.Substring(0, 160) + '...' }
            [void]$partes.Add("saida='$linha'")
        }
    }
    return ($partes -join '; ')
}

function Write-PerfCommandFailure {
    [CmdletBinding()]
    param($Result, [string]$Step)
    $args_ = ''
    if ($null -ne $Result) { $args_ = $Result.Arguments }
    Write-Log WARN "$Step falhou. Comando: powercfg $args_ | $(Get-PerfCommandDetail $Result)"
}

# ============================================================================
# 4. PLANOS DE ENERGIA - deteccao real, independente de idioma do Windows
#    A saida do powercfg e localizada; por isso o parsing e feito por GUID
#    (formato invariante) e nunca por texto em ingles.
# ============================================================================

$script:GuidPattern = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

function Get-PerfPowerSchemes {
    <# Retorna array de {Guid,Nome,Ativo}. Retorna $null quando a consulta falha. #>
    [CmdletBinding()]
    param()
    $r = Invoke-PerfPowercfg -Arguments @('/list') -TimeoutSeconds 30 -Step 'Listar planos de energia'
    if (-not (Test-PerfCommandOk $r)) {
        Write-PerfCommandFailure -Result $r -Step 'Listagem de planos de energia'
        return $null
    }
    $lista = New-Object System.Collections.ArrayList
    foreach ($linha in ($r.StdOut -split "`r?`n")) {
        $m = [regex]::Match($linha, ($script:GuidPattern + '\s*\(([^)]*)\)\s*(\*)?'))
        if ($m.Success) {
            [void]$lista.Add([pscustomobject]@{
                Guid  = $m.Groups[1].Value.ToLowerInvariant()
                Nome  = $m.Groups[2].Value.Trim()
                Ativo = (-not [string]::IsNullOrEmpty($m.Groups[3].Value))
            })
        }
    }
    return , $lista.ToArray()
}

function Get-PerfActiveScheme {
    <# Fonte de verdade para "qual plano esta realmente ativo". #>
    [CmdletBinding()]
    param()
    $r = Invoke-PerfPowercfg -Arguments @('/getactivescheme') -TimeoutSeconds 20 -Step 'Consultar plano ativo'
    if (-not (Test-PerfCommandOk $r)) {
        Write-PerfCommandFailure -Result $r -Step 'Consulta do plano ativo'
        return $null
    }
    $m = [regex]::Match($r.StdOut, ($script:GuidPattern + '(?:\s*\(([^)]*)\))?'))
    if (-not $m.Success) {
        Write-Log WARN "Plano ativo consultado, mas não foi possível extrair o GUID da saída do powercfg."
        return $null
    }
    return [pscustomobject]@{
        Guid = $m.Groups[1].Value.ToLowerInvariant()
        Nome = $m.Groups[2].Value.Trim()
        Raw  = $r.StdOut.Trim()
    }
}

function Test-PerfSchemeExists {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Schemes, [Parameter(Mandatory = $true)][string]$Guid)
    if ($null -eq $Schemes) { return $false }
    $alvo = $Guid.ToLowerInvariant()
    foreach ($s in $Schemes) { if ($s.Guid -eq $alvo) { return $true } }
    return $false
}

function Set-PerfActiveScheme {
    <#
      APLICAR -> CONSULTAR -> COMPARAR -> CONFIRMAR.
      Idempotente: nao chama /setactive se o plano ja e o ativo, salvo -Force
      (necessario para efetivar alteracoes feitas no plano em uso).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Guid,
        [Parameter(Mandatory = $true)][string]$Nome,
        [switch]$Force,
        [switch]$Silent
    )
    $alvo = $Guid.ToLowerInvariant()

    if (-not $Force) {
        $atual = Get-PerfActiveScheme
        if ($atual -and $atual.Guid -eq $alvo) {
            if (-not $Silent) { Write-Log OK "Plano '$Nome' já está ativo. Nenhuma alteração necessária." }
            return $true
        }
    }

    $r = Invoke-PerfPowercfg -Arguments @('/setactive', $Guid) -TimeoutSeconds 30 -Step "Ativar plano $Nome"
    if (-not (Test-PerfCommandOk $r)) {
        Write-PerfCommandFailure -Result $r -Step "Ativacao do plano '$Nome'"
        return $false
    }

    # VALIDACAO: a ausencia de erro nao prova que o plano ficou ativo.
    # Politicas de grupo podem aceitar o comando e reverter o estado.
    Start-Sleep -Milliseconds 250
    $depois = Get-PerfActiveScheme
    if ($null -eq $depois) {
        Write-Log WARN "Plano '$Nome' aplicado, mas não foi possível confirmar o estado ativo."
        return $false
    }
    if ($depois.Guid -ne $alvo) {
        Write-Log WARN "Comando aceito, mas o plano ativo continua '$($depois.Nome)' ($($depois.Guid)) em vez de '$Nome'."
        return $false
    }
    # O nome exibido vem da releitura, nunca do parametro: confirmar GUID nao
    # autoriza afirmar um nome que o sistema pode nao ter aceitado.
    $nomeConfirmado = "$($depois.Nome)"
    if ([string]::IsNullOrWhiteSpace($nomeConfirmado)) { $nomeConfirmado = $Nome }
    if (-not $Silent) {
        Write-Log OK "Plano de energia ativo confirmado: $nomeConfirmado ($alvo)."
        if ($nomeConfirmado -ne $Nome) {
            Write-Log INFO "O plano ativo é o esperado pelo GUID, mas responde pelo nome '$nomeConfirmado' e não '$Nome'."
        }
    }
    return $true
}

$script:PerfUltimateNameKeys = $null

function ConvertTo-PerfNameKey {
    <#
      Chave de comparacao de nomes de plano: minusculas, sem acentuacao, sem
      espacos e sem pontuacao.

      E o que impede que "Desempenho Maximo", "Desempenho maximo" e
      "DESEMPENHO MAXIMO" sejam tratados como planos diferentes - ou seja, o que
      impede que uma diferenca de capitalizacao ou de acentuacao provoque a
      criacao de uma duplicata. Retorna string vazia quando nao ha o que comparar.
    #>
    [CmdletBinding()]
    param([string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    # FormD separa a letra do sinal diacritico; descartamos apenas o sinal.
    foreach ($ch in $Nome.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        if ([char]::IsLetterOrDigit($ch)) { [void]$sb.Append([char]::ToLowerInvariant($ch)) }
    }
    return $sb.ToString()
}

function Get-PerfUltimateNameKeys {
    <#
      Chaves de nome que identificam o plano de Desempenho Maximo do Windows.

      FONTE PRIMARIA - o proprio sistema: 'powercfg /query <GUID canonico>' e uma
      consulta somente leitura e, quando o modelo e resolvivel, devolve o nome
      localizado exato, sem nenhum nome fixo no codigo. Falha silenciosa de
      proposito: a ausencia do modelo e justamente o caso normal aqui e nao e
      erro nenhum.

      FONTE SECUNDARIA - os nomes dos idiomas atendidos pelo projeto. Existem
      apenas para evitar a duplicacao no caminho comum. Um idioma fora desta
      lista nao quebra nada: cai na etapa (3) de Resolve-PerfPerformanceScheme,
      que ja reconhece a copia redundante pelo nome lido do sistema e a descarta.
      Por isso nenhum nome de outro idioma e adivinhado aqui - um palpite errado
      poderia casar com o plano Alto Desempenho, que e outro plano.
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:PerfUltimateNameKeys) { return $script:PerfUltimateNameKeys }

    $chaves = New-Object System.Collections.ArrayList
    $q = Invoke-PerfPowercfg -Arguments @('/query', $GUID_ULTIMATE) -TimeoutSeconds 20 -Step 'Consultar o nome do modelo de Desempenho Maximo'
    if (Test-PerfCommandOk $q) {
        $m = [regex]::Match($q.StdOut, ($script:GuidPattern + '\s*\(([^)]*)\)'))
        if ($m.Success) {
            $k = ConvertTo-PerfNameKey -Nome $m.Groups[2].Value
            if ($k) { [void]$chaves.Add($k) }
        }
    }
    foreach ($n in @('Desempenho Máximo', 'Ultimate Performance')) {
        $k = ConvertTo-PerfNameKey -Nome $n
        if ($k -and -not $chaves.Contains($k)) { [void]$chaves.Add($k) }
    }
    $script:PerfUltimateNameKeys = $chaves.ToArray()
    return $script:PerfUltimateNameKeys
}

function Find-PerfUltimateSchemes {
    <#
      Planos JA EXISTENTES que sao o Desempenho Maximo do Windows - tipicamente
      duplicatas criadas por uma execucao anterior, que recebem GUID proprio.

      Os GUIDs canonicos de Equilibrado, Alto Desempenho e Economia de Energia
      sao excluidos explicitamente: sao planos distintos e conhecidos por GUID, e
      nenhum deles pode ser confundido com o Desempenho Maximo por semelhanca de
      nome. O GUID continua decidindo; o nome so reconhece o que, por definicao,
      nao tem GUID previsivel.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Schemes)
    $achados = New-Object System.Collections.ArrayList
    if ($null -eq $Schemes) { return , $achados.ToArray() }

    $chaves    = @(Get-PerfUltimateNameKeys)
    $canonicos = @($GUID_BALANCED, $GUID_HIGH, $GUID_SAVER)
    foreach ($s in $Schemes) {
        if ($canonicos -contains $s.Guid) { continue }
        if ($chaves -contains (ConvertTo-PerfNameKey -Nome $s.Nome)) { [void]$achados.Add($s) }
    }
    return , $achados.ToArray()
}

function Resolve-PerfPerformanceScheme {
    <#
      Resolve o plano de Desempenho Maximo do Windows de forma IDEMPOTENTE,
      SEMPRE com a nomenclatura do proprio sistema.

      ORDEM DE RESOLUCAO - criar e o ULTIMO recurso, nunca o primeiro:
        (1) GUID canonico presente na listagem;
        (2) plano derivado ja presente (a duplicata de uma execucao anterior);
        (3) so entao duplicar o modelo do Windows, uma unica vez.

      POR QUE A ETAPA (2) EXISTE: 'powercfg /duplicatescheme' devolve um GUID
      ALEATORIO. A partir da segunda execucao o GUID canonico nao aparece mais na
      listagem, e a etapa (1) sozinha concluia - erradamente - que o plano estava
      ausente. O resultado observado era um plano criado e descartado a cada
      execucao, com as mensagens "encontrado", "ausente", "criando" e "copia
      redundante descartada" na mesma saida.

      O GUID segue sendo o identificador: e por GUID que o plano e ativado e
      configurado depois daqui. O nome participa apenas do reconhecimento da
      duplicata - cujo GUID e, por definicao, imprevisivel - e ainda assim de
      forma normalizada, de modo que maiusculas, acentuacao e espacos nao decidem
      nada.

      Nenhum /changename e executado: renomear produziria um rotulo proprio nas
      Opcoes de Energia. Nenhum plano preexistente e removido.

      Retorna {Guid,Nome,Origem} ou $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Schemes,
        $Ativo
    )

    # (1) GUID canonico presente
    if (Test-PerfSchemeExists -Schemes $Schemes -Guid $GUID_ULTIMATE) {
        $nome = ($Schemes | Where-Object { $_.Guid -eq $GUID_ULTIMATE } | Select-Object -First 1).Nome
        Write-Log OK "Plano '$nome' encontrado (GUID canônico). Reutilizando - nada será duplicado."
        return [pscustomobject]@{ Guid = $GUID_ULTIMATE; Nome = $nome; Origem = 'existente' }
    }

    # (2) Duplicata ja existente. REGRA ABSOLUTA: havendo um plano de Desempenho
    #     Maximo valido, ele e reutilizado e NADA e criado.
    # A coleta e feita em dois passos de proposito: 'Find-PerfUltimateSchemes'
    # devolve o array com o idioma ", $lista.ToArray()" usado em todo o modulo, e
    # envolver a CHAMADA em @( ) nao desempacota esse array - produziria sempre um
    # unico elemento, que seria o proprio array. Atribuir primeiro e so entao
    # normalizar com @( ) sobre a VARIAVEL da a contagem correta.
    $achados = Find-PerfUltimateSchemes -Schemes $Schemes
    $candidatos = @()
    if ($null -ne $achados) { $candidatos = @($achados) }
    if ($candidatos.Count -gt 0) {
        # O plano ATIVO tem preferencia: se o usuario ja esta em Desempenho
        # Maximo, nao se troca de plano nem se toca em outro.
        $escolhido = $null
        if ($Ativo) { $escolhido = @($candidatos | Where-Object { $_.Guid -eq $Ativo.Guid }) | Select-Object -First 1 }
        if ($null -eq $escolhido) { $escolhido = @($candidatos | Where-Object { $_.Ativo }) | Select-Object -First 1 }
        if ($null -eq $escolhido) { $escolhido = $candidatos[0] }

        Write-Log OK "Plano '$($escolhido.Nome)' encontrado. Reutilizando - nada será duplicado."
        if ($candidatos.Count -gt 1) {
            # Entradas antigas de mesmo nome sao apenas reportadas: remove-las
            # nao faz parte desta operacao e poderia descartar um plano do usuario.
            Write-Log INFO "Este sistema tem $($candidatos.Count) planos com esse nome. Será reutilizado o de GUID $($escolhido.Guid); nenhum outro será criado ou removido."
        }
        return [pscustomobject]@{ Guid = $escolhido.Guid; Nome = "$($escolhido.Nome)"; Origem = 'existente' }
    }

    # (3) criar. Snapshot antes para identificar por diferenca o GUID gerado.
    Write-Log INFO "Plano 'Desempenho Máximo' não encontrado."
    Write-Log INFO 'Criando a partir do modelo suportado pelo Windows...'
    $antes = @($Schemes)

    $d = Invoke-PerfPowercfg -Arguments @('/duplicatescheme', $GUID_ULTIMATE) -TimeoutSeconds 60 -Step 'Duplicar plano de Desempenho Maximo'
    if (-not (Test-PerfCommandOk $d)) {
        Write-Log WARN "Este dispositivo não expõe o plano Desempenho Máximo. Detalhe: $(Get-PerfCommandDetail $d)"
        return $null
    }

    # VALIDACAO: ExitCode 0 nao prova criacao. Relistamos e comparamos.
    $depois = Get-PerfPowerSchemes
    if ($null -eq $depois) {
        Write-Log WARN 'Duplicação executada, mas a relistagem de planos falhou. Criação não confirmada.'
        return $null
    }
    if (Test-PerfSchemeExists -Schemes $depois -Guid $GUID_ULTIMATE) {
        $nome = ($depois | Where-Object { $_.Guid -eq $GUID_ULTIMATE } | Select-Object -First 1).Nome
        Write-Log OK "Plano criado com sucesso, sob o nome do sistema: '$nome' (GUID $GUID_ULTIMATE)."
        return [pscustomobject]@{ Guid = $GUID_ULTIMATE; Nome = $nome; Origem = 'criado' }
    }

    $guidsAntes = @($antes | ForEach-Object { $_.Guid })
    $novos = @($depois | Where-Object { $guidsAntes -notcontains $_.Guid })
    if ($novos.Count -eq 0) {
        Write-Log WARN 'A duplicação retornou sucesso, mas nenhum plano novo apareceu na listagem. Criação não confirmada.'
        return $null
    }
    $novo = $novos[0]
    $nomeNovo = "$($novo.Nome)"

    # ULTIMA REDE DE PROTECAO contra duplicata, para os idiomas cujo nome nao
    # consta em Get-PerfUltimateNameKeys: se um plano de mesmo nome ja existia
    # antes da duplicacao, esta copia e redundante - descartamos a que acabamos de
    # criar e reutilizamos a anterior. Sem isto, cada execucao em um idioma nao
    # previsto acrescentaria mais um plano identico.
    $previo = @($antes | Where-Object { (ConvertTo-PerfNameKey -Nome $_.Nome) -eq (ConvertTo-PerfNameKey -Nome $nomeNovo) -and $_.Guid -ne $novo.Guid }) | Select-Object -First 1
    if ($previo) {
        $ativoAgora = Get-PerfActiveScheme
        $ehAtivo = ($ativoAgora -and $ativoAgora.Guid -eq $novo.Guid)
        if (-not $ehAtivo) {
            $del = Invoke-PerfPowercfg -Arguments @('/delete', $novo.Guid) -TimeoutSeconds 30 -Step 'Descartar copia redundante do plano'
            if (Test-PerfCommandOk $del) {
                Write-Log OK "Cópia redundante descartada. Reutilizando o plano '$nomeNovo' já existente (GUID $($previo.Guid))."
            } else {
                Write-Log WARN "Não foi possível descartar a cópia redundante do plano. Detalhe: $(Get-PerfCommandDetail $del)"
                Set-PerfResult 'WARN'
            }
        } else {
            Write-Log INFO 'A cópia recém-criada já está ativa; ela será mantida e nenhum plano será removido.'
            return [pscustomobject]@{ Guid = $novo.Guid; Nome = $nomeNovo; Origem = 'criado' }
        }
        return [pscustomobject]@{ Guid = $previo.Guid; Nome = "$($previo.Nome)"; Origem = 'existente' }
    }

    Write-Log OK "Plano criado com sucesso, sob o nome do sistema: '$nomeNovo' (GUID $($novo.Guid))."
    return [pscustomobject]@{ Guid = $novo.Guid; Nome = $nomeNovo; Origem = 'criado' }
}

# ============================================================================
# 5. CAPACIDADE DE SUSPENSAO / MODERN STANDBY
# ============================================================================

function Get-PerfSleepCapabilities {
    <#
      Interpreta "powercfg /a". O texto e localizado, entao a classificacao usa a
      ESTRUTURA da saida (1o bloco = disponiveis, 2o bloco = indisponiveis) e os
      tokens S0..S4, que nao sao traduzidos.
    #>
    [CmdletBinding()]
    param()
    $r = Invoke-PerfPowercfg -Arguments @('/a') -TimeoutSeconds 30 -Step 'Consultar estados de suspensao'

    # 'powercfg /a' costuma retornar codigo diferente de zero em dispositivos que
    # nao expoem parte dos estados de suspensao, ainda assim imprimindo a relacao
    # completa. Descartar essa saida pelo codigo de retorno jogava fora informacao
    # valida. Aproveita-la NAO esconde falha: quando nao ha saida utilizavel, o
    # aviso e emitido com o detalhe tecnico e a funcao devolve $null como antes.
    $temSaida = ($null -ne $r -and $r.Invoked -and $r.StdOut -match '\bS[0-4]\b')
    if (-not (Test-PerfCommandOk $r)) {
        if (-not $temSaida) {
            Write-Log WARN 'Não foi possível obter os detalhes dos estados de suspensão.'
            Write-PerfCommandFailure -Result $r -Step 'Consulta de estados de suspensão'
            return $null
        }
        # Aviso, nunca falha fatal: o perfil de desempenho continua sendo aplicado.
        Write-Log WARN 'Não foi possível obter todos os detalhes dos estados de suspensão. A operação continua com as informações disponíveis.'
        Write-Log INFO "Detalhe técnico: powercfg /a | $(Get-PerfCommandDetail $r)"
    }
    $disp = New-Object System.Collections.ArrayList
    $indisp = New-Object System.Collections.ArrayList
    $bloco = 0
    foreach ($linha in ($r.StdOut -split "`r?`n")) {
        if ($linha -match ':\s*$') { $bloco++; continue }
        if ([string]::IsNullOrWhiteSpace($linha)) { continue }
        $t = $linha.Trim()
        if ($t -notmatch '\bS[0-4]\b') { continue }
        if ($bloco -le 1) { [void]$disp.Add($t) } else { [void]$indisp.Add($t) }
    }
    return [pscustomobject]@{
        Disponiveis   = $disp.ToArray()
        Indisponiveis = $indisp.ToArray()
        Raw           = $r.StdOut.Trim()
    }
}

# ============================================================================
# 6. CONFIGURACOES DE ENERGIA - consulta e aplicacao com validacao posterior
# ============================================================================

function Get-PerfSettingIndexFromRegistry {
    <#
      Le o indice efetivo de UMA configuracao direto do registro do plano.

      Este e o mecanismo de confirmacao para configuracoes OCULTAS: o
      'powercfg /query' omite settings marcadas como ocultas (Attributes=1), de
      modo que a saida textual nao serve de criterio de sucesso para elas. Ja o
      valor gravado por '/setacvalueindex' aparece SEMPRE em ACSettingIndex
      (ou DCSettingIndex) sob o GUID do plano - inclusive quando a configuracao
      e oculta. Somente leitura.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string]$SubGuid,
        [Parameter(Mandatory = $true)][string]$SettingGuid,
        [ValidateSet('AC', 'DC')][string]$Line = 'AC'
    )
    $caminho = Join-Path (Join-Path (Join-Path $REG_SCHEMES $SchemeGuid) $SubGuid) $SettingGuid
    $nome = $(if ($Line -eq 'DC') { 'DCSettingIndex' } else { 'ACSettingIndex' })
    return (Get-PerfRegistryDword -Path $caminho -Name $nome)
}

function Get-PerfSettingState {
    <#
      Consulta uma configuracao. Retorna {Exists,Ac,Dc,Motivo}.
      Parsing resiliente a idioma: tenta o rotulo em ingles e, se nao casar, usa a
      posicao (os dois ultimos indices hexadecimais sao sempre AC e depois DC).
      Fallback final: registro do proprio Windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string]$SubGuid,
        [Parameter(Mandatory = $true)][string]$SettingGuid
    )
    # 'Presente' distingue as duas causas de Exists=$false, que nao sao a mesma
    # coisa: a consulta ter falhado (configuracao ausente do plano/hardware) e a
    # consulta ter funcionado sem que o indice atual pudesse ser lido. O log de
    # 13/08/2026 chamava as duas de "nao suportado" e depois somava as duas em
    # "nao existe(m) neste hardware", afirmando mais do que a evidencia permite.
    $out = [pscustomobject]@{ Exists = $false; Presente = $false; Ac = $null; Dc = $null; Motivo = '' }

    $q = Invoke-PerfPowercfg -Arguments @('/query', $SchemeGuid, $SubGuid, $SettingGuid) -TimeoutSeconds 30 -Step 'Consultar configuracao'
    if (-not (Test-PerfCommandOk $q)) {
        $out.Motivo = "configuracao nao exposta neste plano/hardware ($(Get-PerfCommandDetail $q))"
        return $out
    }
    $out.Presente = $true

    $mAc = [regex]::Match($q.StdOut, '(?im)^\s*Current AC Power Setting Index:\s*0x([0-9A-Fa-f]+)\s*$')
    $mDc = [regex]::Match($q.StdOut, '(?im)^\s*Current DC Power Setting Index:\s*0x([0-9A-Fa-f]+)\s*$')
    if ($mAc.Success) { $out.Ac = [Convert]::ToInt64($mAc.Groups[1].Value, 16) }
    if ($mDc.Success) { $out.Dc = [Convert]::ToInt64($mDc.Groups[1].Value, 16) }

    if ($null -eq $out.Ac -or $null -eq $out.Dc) {
        $hex = [regex]::Matches($q.StdOut, '0x([0-9A-Fa-f]{1,16})')
        if ($hex.Count -ge 2) {
            if ($null -eq $out.Ac) { $out.Ac = [Convert]::ToInt64($hex[$hex.Count - 2].Groups[1].Value, 16) }
            if ($null -eq $out.Dc) { $out.Dc = [Convert]::ToInt64($hex[$hex.Count - 1].Groups[1].Value, 16) }
        }
    }

    if ($null -eq $out.Ac) {
        $p = Join-Path (Join-Path (Join-Path $REG_SCHEMES $SchemeGuid) $SubGuid) $SettingGuid
        $ac = Get-PerfRegistryDword -Path $p -Name 'ACSettingIndex'
        $dc = Get-PerfRegistryDword -Path $p -Name 'DCSettingIndex'
        if ($null -ne $ac) { $out.Ac = $ac }
        if ($null -ne $dc) { $out.Dc = $dc }
    }

    if ($null -eq $out.Ac) {
        $out.Motivo = 'configuracao presente, mas o valor atual nao pode ser lido'
        return $out
    }
    $out.Exists = $true
    return $out
}

function Set-PerfSettingValue {
    <#
      APLICAR -> CONFIRMAR -> REGISTRAR.
      Status: ALREADY | APPLIED | UNVERIFIED | FAIL | SKIP
      Nunca registra sucesso sem confirmar o valor efetivo.

      CONFIGURACOES OCULTAS: o 'powercfg /query' omite settings marcadas como
      ocultas pelo Windows (Attributes=1) - caso de modo de boost, politica de
      resfriamento e nucleos minimos de core parking em boa parte das
      instalacoes. Antes, o indice ilegivel fazia a funcao devolver SKIP sem
      sequer tentar escrever, e justamente as tres configuracoes que sustentam o
      desempenho maximo do processador nunca eram aplicadas.

      A escrita, porem, funciona nessas configuracoes. Entao: quando a consulta
      confirma que a configuracao existe mas o indice atual nao pode ser lido, a
      escrita passa a ser TENTADA e o resultado e confirmado pelo
      ACSettingIndex/DCSettingIndex do registro, que o proprio powercfg grava sob
      o GUID do plano. Sem essa confirmacao, nada e reportado como aplicado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)][string]$SubGuid,
        [Parameter(Mandatory = $true)][string]$SettingGuid,
        [Parameter(Mandatory = $true)][int]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateSet('AC', 'DC')][string]$Line = 'AC'
    )
    $res = [pscustomobject]@{
        Configuracao = $Label; Linha = $Line; Desejado = $Value
        Anterior = $null; Efetivo = $null; Status = 'SKIP'; Detalhe = ''
    }

    $antes = Get-PerfSettingState -SchemeGuid $SchemeGuid -SubGuid $SubGuid -SettingGuid $SettingGuid

    # Unico caso em que nada e tentado: a consulta provou que a configuracao nao
    # existe neste plano/hardware. Indice ilegivel NAO e prova de ausencia.
    if (-not $antes.Presente) {
        $res.Status  = 'SKIP'
        $res.Detalhe = $antes.Motivo
        Write-Log WARN "[$Line] $Label : não suportado - $($antes.Motivo)."
        return $res
    }

    $atual = $antes.Ac
    if ($Line -eq 'DC') { $atual = $antes.Dc }

    # O indice pode nao ter vindo do powercfg por ser configuracao oculta; o
    # registro ainda pode conhece-lo se ela ja foi gravada alguma vez.
    if ($null -eq $atual) {
        $atual = Get-PerfSettingIndexFromRegistry -SchemeGuid $SchemeGuid -SubGuid $SubGuid -SettingGuid $SettingGuid -Line $Line
    }
    $res.Anterior = $atual
    $oculta = ($null -eq $atual)

    # IDEMPOTENCIA: nada e escrito se o valor ja esta correto.
    if ($null -ne $atual -and [int]$atual -eq $Value) {
        $res.Status = 'ALREADY'; $res.Efetivo = $atual
        Write-Log OK "[$Line] $Label : já estava em $(Format-PerfValue -Label $Label -Value $atual). Nenhuma escrita realizada."
        return $res
    }

    if ($oculta) {
        Write-Log INFO "[$Line] $Label : valor atual não exposto pelo powercfg (configuração oculta). Aplicando e confirmando pelo registro."
    }

    $verbo = '/setacvalueindex'
    if ($Line -eq 'DC') { $verbo = '/setdcvalueindex' }
    $a = Invoke-PerfPowercfg -Arguments @($verbo, $SchemeGuid, $SubGuid, $SettingGuid, ([string]$Value)) -TimeoutSeconds 30 -Step "Aplicar $Label"
    if (-not (Test-PerfCommandOk $a)) {
        $res.Status  = 'FAIL'
        $res.Detalhe = (Get-PerfCommandDetail $a)
        Write-Log WARN "[$Line] $Label : falha ao aplicar - $($res.Detalhe)."
        return $res
    }

    # ---------- CONFIRMAR ----------
    # 1) caminho normal (powercfg), 2) registro. O registro e a fonte que
    #    responde por configuracao oculta, e o powercfg acabou de grava-lo.
    $depois  = Get-PerfSettingState -SchemeGuid $SchemeGuid -SubGuid $SubGuid -SettingGuid $SettingGuid
    $efetivo = $depois.Ac
    if ($Line -eq 'DC') { $efetivo = $depois.Dc }
    $origem  = 'powercfg'
    if ($null -eq $efetivo) {
        $efetivo = Get-PerfSettingIndexFromRegistry -SchemeGuid $SchemeGuid -SubGuid $SubGuid -SettingGuid $SettingGuid -Line $Line
        $origem  = 'registro'
    }
    $res.Efetivo = $efetivo

    if ($null -eq $efetivo) {
        # Comando aceito, nenhuma via de leitura respondeu: nao ha prova de que a
        # alteracao valeu, entao nao se afirma sucesso.
        $res.Status  = 'UNVERIFIED'
        $res.Detalhe = 'comando aceito, mas não foi possível confirmar o valor efetivo nem pelo powercfg nem pelo registro'
        Write-Log WARN "[$Line] $Label : comando aceito, porém sem confirmação do valor efetivo. Não contabilizado como aplicado."
        return $res
    }

    if ([int]$efetivo -eq $Value) {
        $res.Status  = 'APPLIED'
        $res.Detalhe = "confirmado pelo $origem"
        $de = $(if ($null -eq $atual) { 'valor anterior não exposto' } else { Format-PerfValue -Label $Label -Value $atual })
        Write-Log OK "[$Line] $Label : $de -> $(Format-PerfValue -Label $Label -Value $efetivo) (confirmado pelo $origem)."
    } else {
        $res.Status  = 'UNVERIFIED'
        $res.Detalhe = "comando aceito, mas o valor relido ($origem) não corresponde ao solicitado"
        Write-Log WARN "[$Line] $Label : comando aceito, porém o valor efetivo é $efetivo e não $Value. Possível bloqueio por política."
    }
    return $res
}

function Format-PerfValue {
    <# Traducao dos indices para texto legivel, conforme documentacao da Microsoft. #>
    [CmdletBinding()]
    param([string]$Label, $Value)
    if ($null -eq $Value) { return 'n/d' }
    $v = [int]$Value
    switch -Regex ($Label) {
        'boost'      { $m = @{0='Desabilitado';1='Habilitado';2='Agressivo';3='Eficiente habilitado';4='Eficiente agressivo';5='Agressivo garantido';6='Eficiente agressivo garantido'}; if ($m.ContainsKey($v)) { return "$v ($($m[$v]))" }; return "$v" }
        'resfriamento' { if ($v -eq 0) { return '0 (Passivo)' } elseif ($v -eq 1) { return '1 (Ativo)' }; return "$v" }
        'PCI Express' { $m = @{0='Desligado';1='Economia moderada';2='Economia maxima'}; if ($m.ContainsKey($v)) { return "$v ($($m[$v]))" }; return "$v" }
        'USB'        { if ($v -eq 0) { return '0 (Desabilitado)' } elseif ($v -eq 1) { return '1 (Habilitado)' }; return "$v" }
        'ocioso'     { if ($v -eq 0) { return '0 (Estados de ocioso ativos)' } elseif ($v -eq 1) { return '1 (Estados de ocioso desativados)' }; return "$v" }
        'estado (min|max)|processador' { return "$v%" }
        'Desligar|Suspender|Hibernar'  { if ($v -eq 0) { return 'Nunca' }; return "$v s" }
        default { return "$v" }
    }
}

# ============================================================================
# 7. POWER MODE OVERLAY - unico caminho nativo em muitos dispositivos S0
# ============================================================================

function Get-PerfActiveOverlay {
    <# Leitura do overlay ativo. Retorna $null se o SO nao expuser o valor. #>
    [CmdletBinding()]
    param()
    $g = Get-PerfRegistryString -Path $REG_SCHEMES -Name 'ActiveOverlayAcPowerScheme'
    if ([string]::IsNullOrWhiteSpace($g)) { return $null }
    return $g.Trim('{', '}').ToLowerInvariant()
}

function Set-PerfOverlay {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Guid, [Parameter(Mandatory = $true)][string]$Nome)

    $antes = Get-PerfActiveOverlay
    if ($null -ne $antes -and $antes -eq $Guid.ToLowerInvariant()) {
        Write-Log OK "Modo de energia do Windows ja estava em '$Nome'. Nenhuma alteracao necessaria."
        return $true
    }
    $r = Invoke-PerfPowercfg -Arguments @('/overlaysetactive', $Guid) -TimeoutSeconds 30 -Step "Aplicar modo de energia $Nome"
    if (-not (Test-PerfCommandOk $r)) {
        Write-Log WARN "Modo de energia do Windows nao disponivel neste sistema. Detalhe: $(Get-PerfCommandDetail $r)"
        return $false
    }
    Start-Sleep -Milliseconds 250
    $depois = Get-PerfActiveOverlay
    if ($null -eq $depois) {
        Write-Log WARN "Modo de energia '$Nome' aplicado, mas este Windows nao expoe o valor para confirmacao. Nao sera contabilizado como validado."
        return $false
    }
    if ($depois -eq $Guid.ToLowerInvariant()) {
        Write-Log OK "Modo de energia do Windows confirmado: $Nome."
        return $true
    }
    Write-Log WARN "Comando aceito, mas o modo de energia efetivo continua $depois."
    return $false
}

# ============================================================================
# 8. EFEITOS VISUAIS (HKCU - por usuario)
# ============================================================================

function Get-PerfVisualFx {
    [CmdletBinding()]
    param()
    return Get-PerfRegistryDword -Path $REG_VISUALFX -Name 'VisualFXSetting'
}

function Set-PerfVisualFx {
    <#
      Ajusta VisualFXSetting e CONFIRMA relendo o registro.
      A confirmacao por leitura e a fonte de verdade - o retorno da funcao do Core
      e apenas um indicio.
      Valores: 0 = Windows decide, 1 = melhor aparencia, 2 = melhor desempenho, 3 = personalizado.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateRange(0, 3)][int]$Value)

    if ($script:IsSystem) {
        Write-Log WARN 'Execução como SYSTEM: efeitos visuais não serão alterados (HKCU apontaria para o perfil do SYSTEM, não para o usuário).'
        return 'SKIP'
    }

    $antes = Get-PerfVisualFx
    if ($null -ne $antes -and $antes -eq $Value) {
        Write-Log OK "Efeitos visuais já estavam no valor desejado ($Value). Nenhuma escrita realizada."
        return 'ALREADY'
    }

    $existe = $false
    try { $existe = Test-Path -LiteralPath $REG_VISUALFX } catch { $existe = $false }
    if (-not $existe) {
        try {
            New-Item -Path $REG_VISUALFX -Force -ErrorAction Stop | Out-Null
            Write-Log INFO 'Chave de efeitos visuais criada (ausente no perfil do usuário).'
        } catch {
            Write-Log WARN "Não foi possível criar a chave de efeitos visuais: $($_.Exception.Message)"
            return 'FAIL'
        }
    }

    $retornoCore = $null
    try {
        $retornoCore = Set-CompartDiskRegistryValue -Path $REG_VISUALFX -Name 'VisualFXSetting' -Value $Value -Type DWord
    } catch {
        Write-Log WARN "Exceção ao gravar VisualFXSetting: $($_.Exception.Message)"
        return 'FAIL'
    }

    $depois = Get-PerfVisualFx
    if ($null -ne $depois -and $depois -eq $Value) {
        Write-Log OK "Efeitos visuais gravados e confirmados por leitura (VisualFXSetting=$depois)."
        Write-Log INFO 'A aparência só muda por completo após reiniciar o Explorer ou fazer novo logon.'
        return 'APPLIED'
    }
    Write-Log WARN "Efeitos visuais não confirmados. Valor lido após a gravação: $depois (retorno do Core: $retornoCore). Pode haver política de grupo em vigor."
    return 'FAIL'
}

# ============================================================================
# 9. PERFIL DE DESEMPENHO
#    Somente configuracoes nativas, documentadas e reversiveis.
#    Aplicar=$true  -> ajustadas pela acao Ultimate
#    Aplicar=$false -> apenas diagnosticadas; alteracao teria impacto em
#                      estabilidade, seguranca, temperatura ou autonomia.
# ============================================================================

function Get-PerfProfileDefinition {
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Rotulo = 'Estado mínimo do processador'; Sub = $SUB_PROCESSOR; Setting = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Ac = 100; Dc = $null; Aplicar = $true }
        [pscustomobject]@{ Rotulo = 'Estado máximo do processador'; Sub = $SUB_PROCESSOR; Setting = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Ac = 100; Dc = 100;  Aplicar = $true }
        [pscustomobject]@{ Rotulo = 'Modo de boost do processador'; Sub = $SUB_PROCESSOR; Setting = 'be337238-0d82-4146-a960-4f3749d470c7'; Ac = 2;   Dc = 2;    Aplicar = $true }
        [pscustomobject]@{ Rotulo = 'Política de resfriamento do sistema'; Sub = $SUB_PROCESSOR; Setting = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'; Ac = 1; Dc = $null; Aplicar = $true }
        [pscustomobject]@{ Rotulo = 'Núcleos mínimos do processador (core parking)'; Sub = $SUB_PROCESSOR; Setting = '0cc5b647-c1df-4637-891a-dec35c318583'; Ac = 100; Dc = 100; Aplicar = $true }
        [pscustomobject]@{ Rotulo = 'PCI Express - gerenciamento de energia do link'; Sub = $SUB_PCIEXPRESS; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Ac = $null; Dc = $null; Aplicar = $false }
        [pscustomobject]@{ Rotulo = 'Suspensão seletiva USB'; Sub = $SUB_USB; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Ac = $null; Dc = $null; Aplicar = $false }
        [pscustomobject]@{ Rotulo = 'Desligar disco rígido após'; Sub = $SUB_DISK; Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Ac = $null; Dc = $null; Aplicar = $false }
        # --- diagnostico apenas (nunca alteradas automaticamente) -------------
        # PCI Express, USB e disco saem do conjunto aplicado: nenhum deles altera
        # a capacidade de processamento da CPU, e mexer neles atingiria portas USB
        # e desligamento de HD/SSD - efeitos fora do escopo de desempenho maximo
        # do processador. Continuam sendo lidos e exibidos no diagnostico.
        [pscustomobject]@{ Rotulo = 'Desativar estados de ocioso do processador'; Sub = $SUB_PROCESSOR; Setting = '5d76a2ca-e8c0-402f-a133-2158492d58ad'; Ac = $null; Dc = $null; Aplicar = $false }
        [pscustomobject]@{ Rotulo = 'Desligar vídeo após'; Sub = $SUB_VIDEO; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Ac = $null; Dc = $null; Aplicar = $false }
        [pscustomobject]@{ Rotulo = 'Suspender após'; Sub = $SUB_SLEEP; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Ac = $null; Dc = $null; Aplicar = $false }
        [pscustomobject]@{ Rotulo = 'Hibernar após'; Sub = $SUB_SLEEP; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364'; Ac = $null; Dc = $null; Aplicar = $false }
    )
}

# ============================================================================
# 10. ACAO ULTIMATE
#     DETECTAR -> PREPARAR -> APLICAR -> CONSULTAR -> VALIDAR -> CORRIGIR ->
#     VALIDAR NOVAMENTE -> RESULTADO
# ============================================================================

function Invoke-PerfUltimate {
    [CmdletBinding()]
    param()

    if (-not $script:PowercfgOk) {
        Set-PerfResult 'ERROR'
        Write-Log ERR 'powercfg.exe indisponivel: a acao Ultimate nao pode ser executada.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Desempenho' `
            -Message 'Nao foi possivel aplicar o perfil de desempenho: powercfg.exe ausente.' `
            -Recommendation 'Reparar o Windows com "sfc /scannow" antes de repetir a operacao.'
        return
    }

    # ---------- DETECTAR ----------
    Write-Log INFO 'Detectando planos de energia disponíveis...'
    $planos = Get-PerfPowerSchemes
    if ($null -eq $planos) {
        Set-PerfResult 'ERROR'
        Write-Log ERR 'Não foi possível listar os planos de energia. Operação interrompida sem alterar nada.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Desempenho' `
            -Message 'A listagem de planos de energia (powercfg /list) falhou.' `
            -Recommendation 'Executar como administrador e verificar se o servico Power (Power) esta em execucao.'
        return
    }
    $planoInicial = Get-PerfActiveScheme
    if ($planoInicial) { Write-Log INFO "Plano atual: $($planoInicial.Nome) ($($planoInicial.Guid))." }

    if ($script:ModernStandby) {
        Write-Log INFO 'Dispositivo com Modern Standby (S0). Planos de alto desempenho podem estar ocultos pelo fabricante - isso não é um defeito.'
    }

    # ---------- PREPARAR: alvo com cadeia de fallback explicita ----------
    $alvo = $null
    $viaFallback = $false

    $alvo = Resolve-PerfPerformanceScheme -Schemes $planos -Ativo $planoInicial

    if ($null -eq $alvo) {
        Write-Log INFO 'Aplicando o plano Alto Desempenho como alternativa nativa.'
        $viaFallback = $true
        if (Test-PerfSchemeExists -Schemes $planos -Guid $GUID_HIGH) {
            $nomeHigh = ($planos | Where-Object { $_.Guid -eq $GUID_HIGH } | Select-Object -First 1).Nome
            $alvo = [pscustomobject]@{ Guid = $GUID_HIGH; Nome = $nomeHigh; Origem = 'fallback' }
        } else {
            Write-Log INFO 'Alto Desempenho nao aparece na listagem. Tentando ativacao direta do GUID nativo...'
            if (Set-PerfActiveScheme -Guid $GUID_HIGH -Nome 'Alto Desempenho' -Silent) {
                $alvo = [pscustomobject]@{ Guid = $GUID_HIGH; Nome = 'Alto Desempenho'; Origem = 'fallback' }
                Write-Log OK 'Plano Alto Desempenho ativado e confirmado.'
            }
        }
    }

    # ---------- Fallback final: Power Mode overlay (dispositivos S0) ----------
    if ($null -eq $alvo) {
        Set-PerfResult 'WARN'
        Write-Log WARN 'Nenhum plano de alto desempenho pode ser criado ou ativado neste dispositivo.'
        Write-Log INFO 'Tentando o modo de energia nativo do Windows (Melhor desempenho)...'
        if (Set-PerfOverlay -Guid $OVL_BESTPERF -Nome 'Melhor desempenho') {
            Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
                -Message 'Planos Desempenho Maximo e Alto Desempenho indisponiveis. Foi aplicado e validado o modo de energia "Melhor desempenho" do Windows.' `
                -Recommendation 'Comum em notebooks com Modern Standby: o fabricante oculta os planos classicos e o Windows usa o controle deslizante de energia.'
        } else {
            Write-Log WARN 'Nenhum plano ou modo de desempenho solicitado pode ser aplicado. O sistema permanece exatamente como estava.'
            Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
                -Message 'Nao foi possivel aplicar nenhum perfil de desempenho neste dispositivo.' `
                -Recommendation 'Verificar politicas de grupo corporativas em Configuracao do Computador > Modelos Administrativos > Sistema > Gerenciamento de Energia.'
        }
        Invoke-PerfVisualEffectsForAction -Alvo 2
        return
    }

    # ---------- APLICAR + VALIDAR o plano ----------
    # Anunciar "Ativando" para um plano que ja esta ativo produzia duas mensagens
    # contraditorias em sequencia. Set-PerfActiveScheme continua sendo chamada:
    # e ela quem confirma o estado real, independentemente do que foi anunciado.
    if (-not ($planoInicial -and $planoInicial.Guid -eq $alvo.Guid)) {
        Write-Log INFO "Ativando o plano '$($alvo.Nome)'..."
    }
    if (-not (Set-PerfActiveScheme -Guid $alvo.Guid -Nome $alvo.Nome)) {
        # O plano existe mas nao pode ser ativado: tenta o fallback antes de desistir.
        Set-PerfResult 'WARN'
        if ($alvo.Guid -ne $GUID_HIGH) {
            Write-Log INFO 'Tentando Alto Desempenho como alternativa...'
            if (Set-PerfActiveScheme -Guid $GUID_HIGH -Nome 'Alto Desempenho') {
                $alvo = [pscustomobject]@{ Guid = $GUID_HIGH; Nome = 'Alto Desempenho'; Origem = 'fallback' }
                $viaFallback = $true
            } else { $alvo = $null }
        } else { $alvo = $null }

        if ($null -eq $alvo) {
            Write-Log WARN 'Nenhum plano de desempenho pôde ser ativado. Nenhuma configuração será alterada.'
            Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
                -Message 'O plano de energia de desempenho nao pode ser ativado.' `
                -Recommendation 'Politicas de grupo corporativas podem bloquear a alteracao do plano de energia.'
            Invoke-PerfVisualEffectsForAction -Alvo 2
            return
        }
    }

    if ($viaFallback) {
        Set-PerfResult 'WARN'
        Write-Log WARN "Desempenho Máximo indisponível neste dispositivo. '$($alvo.Nome)' foi aplicado e validado como alternativa."
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
            -Message "Plano Desempenho Maximo indisponivel; '$($alvo.Nome)' foi aplicado e validado em seu lugar." `
            -Recommendation 'O plano Desempenho Maximo nao e exposto em parte dos notebooks e dispositivos com Modern Standby.'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Desempenho' `
            -Message "Plano de energia definido e validado como '$($alvo.Nome)'." `
            -Recommendation 'Em notebooks, planos de alto desempenho reduzem a autonomia da bateria.'
    }

    # ---------- APLICAR configuracoes, uma a uma, com validacao ----------
    Write-Log INFO 'Aplicando configurações de desempenho suportadas pelo dispositivo...'
    $resultados = New-Object System.Collections.ArrayList
    $perfil = Get-PerfProfileDefinition

    foreach ($cfg in $perfil) {
        if (-not $cfg.Aplicar) { continue }
        if ($null -ne $cfg.Ac) {
            $r = Set-PerfSettingValue -SchemeGuid $alvo.Guid -SubGuid $cfg.Sub -SettingGuid $cfg.Setting `
                -Value ([int]$cfg.Ac) -Label $cfg.Rotulo -Line 'AC'
            [void]$resultados.Add($r)
        }
        if ($IncludeDcSettings -and $null -ne $cfg.Dc) {
            $r = Set-PerfSettingValue -SchemeGuid $alvo.Guid -SubGuid $cfg.Sub -SettingGuid $cfg.Setting `
                -Value ([int]$cfg.Dc) -Label $cfg.Rotulo -Line 'DC'
            [void]$resultados.Add($r)
        }
    }

    if (-not $IncludeDcSettings) {
        Write-Log INFO 'Configurações em bateria (DC) preservadas. Use -IncludeDcSettings para alterá-las também.'
    }

    # ---------- EFETIVAR: alteracoes no plano em uso so valem apos reativa-lo ----------
    $escritas = @($resultados | Where-Object { $_.Status -eq 'APPLIED' })
    if ($escritas.Count -gt 0) {
        Write-Log INFO 'Reaplicando o plano para efetivar as alterações no sistema em execução...'
        if (Set-PerfActiveScheme -Guid $alvo.Guid -Nome $alvo.Nome -Force -Silent) {
            Write-Log OK 'Plano reaplicado e confirmado; as alterações estão em vigor.'
        } else {
            Set-PerfResult 'WARN'
            Write-Log WARN 'As alterações foram gravadas no plano, mas a reativação não pôde ser confirmada. Elas terão efeito no próximo logon.'
        }
    }

    # ---------- VALIDAR NOVAMENTE (releitura final independente) ----------
    Write-Log INFO 'Revalidando as configurações gravadas...'
    $divergentes = New-Object System.Collections.ArrayList
    foreach ($r in $resultados) {
        if ($r.Status -ne 'APPLIED' -and $r.Status -ne 'ALREADY') { continue }
        $cfg = $perfil | Where-Object { $_.Rotulo -eq $r.Configuracao } | Select-Object -First 1
        if ($null -eq $cfg) { continue }
        $st = Get-PerfSettingState -SchemeGuid $alvo.Guid -SubGuid $cfg.Sub -SettingGuid $cfg.Setting
        $efet = $st.Ac
        if ($r.Linha -eq 'DC') { $efet = $st.Dc }
        # Configuracao oculta nao aparece no powercfg: a revalidacao usa a mesma
        # segunda via da aplicacao, senao um item corretamente aplicado seria
        # rebaixado a UNVERIFIED so por nao ser exibido.
        if ($null -eq $efet) {
            $efet = Get-PerfSettingIndexFromRegistry -SchemeGuid $alvo.Guid -SubGuid $cfg.Sub -SettingGuid $cfg.Setting -Line $r.Linha
        }
        if ($null -eq $efet -or [int]$efet -ne [int]$r.Desejado) {
            $r.Status = 'UNVERIFIED'
            $r.Efetivo = $efet
            $r.Detalhe = 'divergência detectada na revalidação final'
            [void]$divergentes.Add($r.Configuracao)
        }
    }
    if ($divergentes.Count -gt 0) {
        Set-PerfResult 'WARN'
        Write-Log WARN "Revalidação final: $($divergentes.Count) configuração(ões) não permaneceram com o valor solicitado ($($divergentes -join ', '))."
    } else {
        Write-Log OK 'Revalidação final: todas as configurações gravadas permanecem com o valor esperado.'
    }

    # ---------- CONTABILIZAR ----------
    $nAplic = @($resultados | Where-Object { $_.Status -eq 'APPLIED' }).Count
    $nJa    = @($resultados | Where-Object { $_.Status -eq 'ALREADY' }).Count
    $nSkip  = @($resultados | Where-Object { $_.Status -eq 'SKIP' }).Count
    $nFalha = @($resultados | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'UNVERIFIED' }).Count

    if ($nFalha -gt 0) {
        Set-PerfResult 'WARN'
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
            -Message "$nFalha configuracao(oes) de energia nao pode(m) ser aplicada(s) ou confirmada(s)." `
            -Recommendation 'Verificar politicas de grupo de gerenciamento de energia e privilegios administrativos.'
    }
    if ($nSkip -gt 0) {
        Write-Log INFO "$nSkip configuração(ões) não foi(ram) aplicada(s): ausente(s) neste plano/hardware ou com o valor atual ilegível. Nenhuma escrita foi tentada."
    }

    if ($resultados.Count -gt 0) {
        Write-Color ''
        $resultados | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Configuracoes de energia aplicadas' `
            -Status $(if ($nFalha -gt 0) { 'WARN' } else { 'OK' }) -Rows ($resultados.ToArray()) `
            -Summary "$nAplic aplicada(s), $nJa ja conforme, $nSkip nao aplicada(s), $nFalha com falha"
    }

    # ---------- Hibernacao: decisao consciente de NAO alterar ----------
    Write-Log INFO 'Hibernação e Inicialização Rápida preservadas: desativá-las não aumenta desempenho e quebra recursos do Windows.'

    # ---------- Efeitos visuais ----------
    Invoke-PerfVisualEffectsForAction -Alvo 2

    # ---------- VALIDACAO FINAL DO PLANO ATIVO ----------
    # Nao basta ter mandado ativar: confirma-se que o plano em vigor E o plano de
    # Desempenho Maximo pretendido, comparando GUID com o alvo resolvido e, quando
    # o plano canonico existe, tambem o nome que o proprio Windows lhe da.
    $final = Get-PerfActiveScheme
    $planoConfirmado = $false
    $motivoPlano = 'nao foi possivel consultar o plano ativo'
    if ($final) {
        if ($final.Guid -eq $alvo.Guid) {
            $planoConfirmado = $true
            $motivoPlano = 'GUID do plano ativo confere com o plano de Desempenho Maximo aplicado'
            $listaFinal = Get-PerfPowerSchemes
            if ($listaFinal) {
                $canonico = @($listaFinal | Where-Object { $_.Guid -eq $GUID_ULTIMATE }) | Select-Object -First 1
                if ($canonico -and "$($canonico.Nome)" -ne "$($final.Nome)") {
                    $planoConfirmado = $false
                    $motivoPlano = "o plano ativo ('$($final.Nome)') nao corresponde ao plano de Desempenho Maximo do Windows ('$($canonico.Nome)')"
                }
            }
        } else {
            $motivoPlano = "o plano ativo e '$($final.Nome)' ($($final.Guid)), diferente do plano aplicado ($($alvo.Guid))"
        }
    }

    if ($planoConfirmado) {
        Write-Log OK "Plano ativo validado: '$($final.Nome)'."
        Add-CompartDiskFinding -Severity OK -Area 'Desempenho' `
            -Message "Plano de Desempenho Maximo do Windows ativo e confirmado: '$($final.Nome)'."
    } else {
        Set-PerfResult 'WARN'
        Write-Log WARN "Validação do plano ativo: $motivoPlano."
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
            -Message "O plano de Desempenho Maximo nao pode ser confirmado como ativo: $motivoPlano." `
            -Recommendation 'Conferir em Painel de Controle > Opcoes de Energia qual plano esta selecionado.'
    }

    # ---------- Estado final confirmado ----------
    if ($final) {
        Write-Color ''
        Write-Output $final.Raw
        Add-CompartDiskSection -Title 'Estado final de energia' -Status $(if ($planoConfirmado) { 'OK' } else { 'WARN' }) -Pairs ([ordered]@{
            'Plano ativo'      = $final.Nome
            'GUID'             = $final.Guid
            'Plano confirmado' = $(if ($planoConfirmado) { 'Sim' } else { "Nao - $motivoPlano" })
            'Origem do plano'  = $alvo.Origem
            'Modern Standby'   = $(if ($script:ModernStandby) { 'Sim (S0)' } else { 'Nao' })
            'Ajustes em bateria' = $(if ($IncludeDcSettings) { 'Aplicados' } else { 'Preservados' })
        })
    }
}

function Invoke-PerfVisualEffectsForAction {
    <#
      Centraliza a regra de efeitos visuais para que Ultimate e Balanced nao
      dupliquem logica e para que o comportamento seja coerente com a acao.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Alvo)

    if ($SkipVisualEffects) {
        Write-Log INFO 'Efeitos visuais não alterados (-SkipVisualEffects).'
        return
    }
    $st = Set-PerfVisualFx -Value $Alvo
    if ($st -eq 'FAIL') {
        Set-PerfResult 'WARN'
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
            -Message 'Os efeitos visuais não puderam ser alterados e o valor não foi confirmado no registro.' `
            -Recommendation 'Uma política de grupo pode controlar os efeitos visuais deste usuário.'
    }
}

# ============================================================================
# 11. ACAO BALANCED - restauracao coerente, sem reset agressivo
# ============================================================================

function Invoke-PerfBalanced {
    [CmdletBinding()]
    param()

    if (-not $script:PowercfgOk) {
        Set-PerfResult 'ERROR'
        Write-Log ERR 'powercfg.exe indisponivel: a acao Balanced nao pode ser executada.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Desempenho' `
            -Message 'Nao foi possivel restaurar o plano equilibrado: powercfg.exe ausente.' `
            -Recommendation 'Reparar o Windows com "sfc /scannow" antes de repetir a operacao.'
        return
    }

    Write-Log INFO 'Detectando planos de energia disponiveis...'
    $planos = Get-PerfPowerSchemes
    if ($null -ne $planos -and -not (Test-PerfSchemeExists -Schemes $planos -Guid $GUID_BALANCED)) {
        Write-Log WARN 'O plano Equilibrado nao aparece na listagem deste dispositivo. A ativacao sera tentada mesmo assim.'
    }

    $planoOk = Set-PerfActiveScheme -Guid $GUID_BALANCED -Nome 'Equilibrado (padrao)'
    if ($planoOk) {
        Add-CompartDiskFinding -Severity OK -Area 'Desempenho' `
            -Message 'Plano de energia restaurado e validado como Equilibrado (padrao do Windows).'
    } else {
        Set-PerfResult 'WARN'
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
            -Message 'Falha ao restaurar o plano de energia Equilibrado.' `
            -Recommendation 'Politicas de grupo corporativas podem bloquear a alteracao do plano de energia.'
    }

    # --- Modo de energia: desfaz apenas o que a acao Ultimate pode ter aplicado ---
    $ovl = Get-PerfActiveOverlay
    if ($null -eq $ovl) {
        Write-Log INFO 'Este Windows nao expoe o modo de energia (controle deslizante). Nada a restaurar.'
    } elseif ($ovl -eq $OVL_BESTPERF) {
        Write-Log INFO 'Modo de energia esta em "Melhor desempenho". Restaurando para o recomendado...'
        if (-not (Set-PerfOverlay -Guid $OVL_RECOMMENDED -Nome 'Equilibrado / recomendado')) {
            Set-PerfResult 'WARN'
        }
    } elseif ($ovl -eq $OVL_EFFICIENCY) {
        Write-Log INFO 'Modo de energia esta em "Melhor eficiencia" por escolha do usuario. Preservado.'
    } else {
        Write-Log OK 'Modo de energia ja esta no valor recomendado.'
    }

    # --- Efeitos visuais: NAO destruir preferencia pessoal -----------------
    # Restaura apenas se estiver no valor "melhor desempenho" (2), que e o que a
    # acao Ultimate aplica. Preferencias 1 (aparencia) e 3 (personalizado) ficam intactas.
    if ($SkipVisualEffects) {
        Write-Log INFO 'Efeitos visuais nao alterados (-SkipVisualEffects).'
    } else {
        $fx = Get-PerfVisualFx
        if ($null -eq $fx) {
            Write-Log INFO 'Efeitos visuais nunca foram alterados neste perfil. Nada a restaurar.'
        } elseif ($fx -eq 2) {
            Write-Log INFO 'Efeitos visuais estao em "melhor desempenho". Devolvendo o controle ao Windows...'
            if ((Set-PerfVisualFx -Value 0) -eq 'FAIL') {
                Set-PerfResult 'WARN'
                Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
                    -Message 'Os efeitos visuais nao puderam ser restaurados e o valor nao foi confirmado no registro.' `
                    -Recommendation 'Uma politica de grupo pode controlar os efeitos visuais deste usuario.'
            }
        } elseif ($fx -eq 3) {
            Write-Log OK 'Efeitos visuais estao em configuracao personalizada do usuario. Preservados.'
        } elseif ($fx -eq 1) {
            Write-Log OK 'Efeitos visuais estao em "melhor aparencia" por escolha do usuario. Preservados.'
        } else {
            Write-Log OK 'Efeitos visuais ja estao sob controle automatico do Windows.'
        }
    }

    Write-Log INFO 'Planos de desempenho criados anteriormente NAO foram removidos - a remocao seria irreversivel e nao e necessaria.'

    $final = Get-PerfActiveScheme
    if ($final) {
        Write-Color ''
        Write-Output $final.Raw
        Add-CompartDiskSection -Title 'Estado final de energia' -Status $(if ($planoOk) { 'OK' } else { 'WARN' }) -Pairs ([ordered]@{
            'Plano ativo' = $final.Nome
            'GUID'        = $final.Guid
        })
    }
}

# ============================================================================
# 12. ACAO ANALYZE - diagnostico ampliado, sem alterar nada
# ============================================================================

function Get-PerfSafeRows {
    <# Executa uma funcao de diagnostico do Core sem derrubar o modulo inteiro. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [hashtable]$Parameters)
    if (-not (Test-PerfCommand $Name)) {
        Write-Log WARN "Funcao de diagnostico '$Name' indisponivel no Core.ps1. Etapa ignorada."
        Set-PerfResult 'WARN'
        return $null
    }
    try {
        if ($Parameters) { return & $Name @Parameters }
        return & $Name
    } catch {
        Set-PerfResult 'WARN'
        Write-Log WARN "Falha em '$Name': $($_.Exception.Message)"
        return $null
    }
}

function Show-PerfPowerAnalysis {
    [CmdletBinding()]
    param()

    Write-Color ''
    Write-Color '  ENERGIA' -Color White

    # Preserva a saida original do Core.
    $energia = Get-PerfSafeRows -Name 'Get-CompartDiskPowerInfo'
    if ($energia -and $energia.Keys) {
        foreach ($k in @($energia.Keys)) { Write-CompartDiskKeyValue $k $energia[$k] -Pad 24 }
        Add-CompartDiskSection -Title 'Energia' -Status INFO -Pairs $energia
    }

    if (-not $script:PowercfgOk) {
        Write-Log WARN 'powercfg.exe indisponivel: o diagnostico detalhado de energia foi ignorado.'
        return
    }

    $planos = Get-PerfPowerSchemes
    $ativo  = Get-PerfActiveScheme

    $pares = [ordered]@{}
    if ($ativo) {
        $pares['Plano ativo'] = $ativo.Nome
        $pares['GUID do plano'] = $ativo.Guid
    } else {
        $pares['Plano ativo'] = 'nao foi possivel consultar'
    }
    if ($planos) {
        $pares['Planos disponiveis'] = $planos.Count
        $pares['Desempenho Maximo']  = $(if (Test-PerfSchemeExists -Schemes $planos -Guid $GUID_ULTIMATE) { 'presente' } else { 'ausente' })
        $pares['Alto Desempenho']    = $(if (Test-PerfSchemeExists -Schemes $planos -Guid $GUID_HIGH) { 'presente' } else { 'ausente' })
        $pares['Equilibrado']        = $(if (Test-PerfSchemeExists -Schemes $planos -Guid $GUID_BALANCED) { 'presente' } else { 'ausente' })
        $pares['Economia de energia'] = $(if (Test-PerfSchemeExists -Schemes $planos -Guid $GUID_SAVER) { 'presente' } else { 'ausente' })
    }
    $pares['Modern Standby (S0)'] = $(if ($script:ModernStandby) { 'Sim' } else { 'Nao' })
    if ($script:SleepStates) {
        if ($script:SleepStates.Disponiveis.Count -gt 0) { $pares['Suspensao disponivel'] = ($script:SleepStates.Disponiveis -join ' | ') }
        if ($script:SleepStates.Indisponiveis.Count -gt 0) { $pares['Suspensao indisponivel'] = ($script:SleepStates.Indisponiveis -join ' | ') }
    }
    $pares['Hibernacao'] = $(if ($script:HibernateEnabled -eq 1) { 'habilitada' } elseif ($script:HibernateEnabled -eq 0) { 'desabilitada' } else { 'nao consultavel' })
    $pares['Alimentacao'] = $(if ($script:HasBattery) { 'com bateria (AC/DC)' } else { 'somente AC' })
    $ovl = Get-PerfActiveOverlay
    if ($null -ne $ovl) {
        $nomeOvl = 'personalizado'
        if ($ovl -eq $OVL_RECOMMENDED) { $nomeOvl = 'Equilibrado / recomendado' }
        elseif ($ovl -eq $OVL_BESTPERF) { $nomeOvl = 'Melhor desempenho' }
        elseif ($ovl -eq $OVL_EFFICIENCY) { $nomeOvl = 'Melhor eficiencia' }
        $pares['Modo de energia'] = $nomeOvl
    }

    Write-Color ''
    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 24 }
    Add-CompartDiskSection -Title 'Energia (detalhado)' -Status INFO -Pairs $pares

    # --- configuracoes criticas do plano ativo (AC e DC) --------------------
    if ($ativo) {
        $linhas = New-Object System.Collections.ArrayList
        foreach ($cfg in (Get-PerfProfileDefinition)) {
            $st = Get-PerfSettingState -SchemeGuid $ativo.Guid -SubGuid $cfg.Sub -SettingGuid $cfg.Setting
            if (-not $st.Exists) {
                [void]$linhas.Add([pscustomobject]@{ Configuracao = $cfg.Rotulo; AC = 'nao suportada'; DC = 'nao suportada' })
                continue
            }
            [void]$linhas.Add([pscustomobject]@{
                Configuracao = $cfg.Rotulo
                AC = (Format-PerfValue -Label $cfg.Rotulo -Value $st.Ac)
                DC = (Format-PerfValue -Label $cfg.Rotulo -Value $st.Dc)
            })
        }
        if ($linhas.Count -gt 0) {
            Write-Color ''
            Write-Color '  CONFIGURACOES DE ENERGIA DO PLANO ATIVO' -Color White
            $linhas | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
            Add-CompartDiskSection -Title 'Configuracoes de energia (plano ativo)' -Status INFO -Rows ($linhas.ToArray())
        }

        # --- inconsistencias, apenas diagnostico -----------------------------
        $incons = New-Object System.Collections.ArrayList
        if ($ativo.Guid -eq $GUID_SAVER) { [void]$incons.Add('O plano ativo e Economia de energia, que limita deliberadamente o desempenho.') }
        $stMax = Get-PerfSettingState -SchemeGuid $ativo.Guid -SubGuid $SUB_PROCESSOR -SettingGuid 'bc5038f7-23e0-4960-96da-33abaf5935ec'
        if ($stMax.Exists -and $null -ne $stMax.Ac -and $stMax.Ac -lt 100) {
            [void]$incons.Add("Estado maximo do processador limitado a $($stMax.Ac)% na tomada, o que reduz o desempenho de pico.")
        }
        $stMin = Get-PerfSettingState -SchemeGuid $ativo.Guid -SubGuid $SUB_PROCESSOR -SettingGuid '893dee8e-2bef-41e0-89c6-b55d0929964c'
        if ($script:HasBattery -and $stMin.Exists -and $null -ne $stMin.Dc -and $stMin.Dc -ge 100) {
            [void]$incons.Add('Estado minimo do processador em 100% na bateria: consumo elevado sem ganho perceptivel.')
        }
        $stIdle = Get-PerfSettingState -SchemeGuid $ativo.Guid -SubGuid $SUB_PROCESSOR -SettingGuid '5d76a2ca-e8c0-402f-a133-2158492d58ad'
        if ($stIdle.Exists -and $stIdle.Ac -eq 1) {
            [void]$incons.Add('Estados de ocioso do processador desativados: aumenta consumo e temperatura sem ganho consistente.')
        }
        if ($planos) {
            # Duplicidade e contada pelo nome que o proprio Windows da ao plano,
            # lido do GUID canonico. Sem o plano canonico presente nao ha nome de
            # referencia, e nada e afirmado.
            $refUlt = @($planos | Where-Object { $_.Guid -eq $GUID_ULTIMATE }) | Select-Object -First 1
            if ($refUlt) {
                $nomeUlt = "$($refUlt.Nome)"
                $dups = @($planos | Where-Object { "$($_.Nome)" -eq $nomeUlt })
                if ($dups.Count -gt 1) { [void]$incons.Add("Existem $($dups.Count) planos com o nome '$nomeUlt'. Os extras podem ser removidos em Opcoes de energia.") }
            }
        }
        foreach ($i in $incons) {
            Set-PerfResult 'WARN'
            Write-Log WARN $i
            Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' -Message $i `
                -Recommendation 'Revisar em Painel de Controle > Opcoes de Energia > Alterar configuracoes do plano.'
        }
        if ($incons.Count -eq 0) {
            Add-CompartDiskFinding -Severity OK -Area 'Desempenho' -Message 'Nenhuma inconsistencia de energia detectada no plano ativo.'
        }
    }
}

function Get-PerfProcessSnapshot {
    <#
      Leitura defensiva: a propriedade CPU lanca AccessDenied em processos
      protegidos. O loop isola cada processo para que um erro nao derrube a analise.
    #>
    [CmdletBinding()]
    param([int]$Top = 8)
    $lista = New-Object System.Collections.ArrayList
    $procs = @()
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue)
    } catch {
        Write-Log WARN "Nao foi possivel enumerar processos: $($_.Exception.Message)"
        return $null
    }
    foreach ($p in $procs) {
        $cpu = $null
        try { $cpu = $p.CPU } catch { $cpu = $null }
        $ws = 0
        try { $ws = [math]::Round($p.WorkingSet64 / 1MB, 1) } catch { $ws = 0 }
        [void]$lista.Add([pscustomobject]@{
            Processo      = $p.ProcessName
            PID           = $p.Id
            'CPU total(s)' = $(if ($null -ne $cpu) { [math]::Round([double]$cpu, 1) } else { 0 })
            'Memoria(MB)'  = $ws
        })
    }
    return , (@($lista | Sort-Object -Property 'CPU total(s)' -Descending | Select-Object -First $Top))
}

function Show-PerfSystemLoad {
    [CmdletBinding()]
    param()

    # --- CPU instantaneo (comportamento original preservado) ----------------
    $cpu = 'n/d'
    if (Test-PerfCommand 'Get-CompartDiskCim') {
        try {
            $c = Get-CompartDiskCim -Class Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            if ($c) { $cpu = "$($c.PercentProcessorTime)%" }
        } catch {
            Write-Log WARN "Contador instantaneo de CPU indisponivel: $($_.Exception.Message)"
        }
    }

    $hw = Get-PerfSafeRows -Name 'Get-CompartDiskHardwareInfo'
    $pares = [ordered]@{ 'CPU (instantaneo)' = $cpu }
    if ($hw) {
        $pares['RAM total']      = $hw['RAM total']
        $pares['RAM disponivel'] = $hw['RAM disponivel']
        $pares['RAM em uso (%)'] = $hw['RAM em uso (%)']
    }
    $pares['Processos ativos'] = (@(Get-Process -ErrorAction SilentlyContinue).Count)

    # --- detalhes de CPU ----------------------------------------------------
    if (Test-PerfCommand 'Get-CompartDiskCim') {
        try {
            $cpus = @(Get-CompartDiskCim -Class Win32_Processor)
            if ($cpus.Count -gt 0) {
                $nucleos = 0; $threads = 0
                foreach ($c in $cpus) {
                    if ($null -ne $c.NumberOfCores) { $nucleos += [int]$c.NumberOfCores }
                    if ($null -ne $c.NumberOfLogicalProcessors) { $threads += [int]$c.NumberOfLogicalProcessors }
                }
                $pares['Processador']  = $cpus[0].Name
                $pares['Nucleos']      = $nucleos
                $pares['Threads']      = $threads
                if ($cpus[0].MaxClockSpeed)     { $pares['Frequencia nominal'] = "$($cpus[0].MaxClockSpeed) MHz" }
                if ($cpus[0].CurrentClockSpeed) { $pares['Frequencia atual']   = "$($cpus[0].CurrentClockSpeed) MHz" }
            }
        } catch {
            Write-Log WARN "Detalhes do processador indisponiveis: $($_.Exception.Message)"
        }
        try {
            $pf = Get-CompartDiskCim -Class Win32_PageFileUsage
            if ($pf) { $pares['Arquivo de paginacao'] = "$($pf.CurrentUsage) MB de $($pf.AllocatedBaseSize) MB" }
            else { $pares['Arquivo de paginacao'] = 'gerenciado pelo sistema ou ausente' }
        } catch {
            Write-Log WARN "Informacoes de arquivo de paginacao indisponiveis: $($_.Exception.Message)"
        }
        try {
            $os = Get-CompartDiskCim -Class Win32_OperatingSystem
            if ($os -and $os.TotalVirtualMemorySize -and $os.FreeVirtualMemory) {
                $usoV = [math]::Round((($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize) * 100, 1)
                $pares['Memoria confirmada (%)'] = "$usoV%"
                if ($usoV -ge 90) {
                    Set-PerfResult 'WARN'
                    Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
                        -Message "Pressao de memoria elevada: $usoV% da memoria confirmada em uso." `
                        -Recommendation 'Fechar aplicativos ociosos ou avaliar a ampliacao da memoria RAM.'
                }
            }
        } catch {
            Write-Log WARN "Metricas de memoria virtual indisponiveis: $($_.Exception.Message)"
        }
    }

    # --- estado de boost do plano ativo -------------------------------------
    if ($script:PowercfgOk) {
        $ativo = Get-PerfActiveScheme
        if ($ativo) {
            $st = Get-PerfSettingState -SchemeGuid $ativo.Guid -SubGuid $SUB_PROCESSOR -SettingGuid 'be337238-0d82-4146-a960-4f3749d470c7'
            if ($st.Exists) { $pares['Boost do processador'] = (Format-PerfValue -Label 'Modo de boost do processador' -Value $st.Ac) }
            else { $pares['Boost do processador'] = 'nao exposto por este hardware' }
        }
    }

    Write-Color ''
    foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 24 }
    Add-CompartDiskSection -Title 'Carga do sistema' -Status OK -Pairs $pares
}

function Show-PerfStartupAnalysis {
    [CmdletBinding()]
    param([switch]$Detalhado)

    $startup = Get-PerfSafeRows -Name 'Get-CompartDiskStartupItems'
    $itens = @()
    if ($startup) { $itens = @($startup) }
    if ($itens.Count -eq 0) {
        Write-Log INFO 'Nenhum item de inicializacao encontrado ou lista indisponivel.'
        return
    }

    Write-Color ''
    Write-Color ("  ITENS DE INICIALIZACAO: {0}" -f $itens.Count) -Color White

    if ($Detalhado) {
        # Mostra todas as colunas realmente fornecidas pelo Core, sem presumir nomes.
        $itens | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output
    } else {
        $cols = @()
        $disponiveis = @($itens[0].PSObject.Properties.Name)
        foreach ($c in @('Nome', 'Comando', 'Local', 'Usuario', 'Origem', 'Status')) {
            if ($disponiveis -contains $c) { $cols += $c }
        }
        if ($cols.Count -eq 0) { $cols = $disponiveis }
        $itens | Select-Object -Property $cols | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Output
    }

    $status = 'OK'
    if ($itens.Count -gt 12) { $status = 'WARN' }
    Add-CompartDiskSection -Title 'Itens de inicializacao' -Status $status -Rows $itens -Summary "$($itens.Count) item(ns)"

    if ($itens.Count -gt 12) {
        Add-CompartDiskFinding -Severity WARN -Area 'Desempenho' `
            -Message "$($itens.Count) programas configurados para iniciar com o Windows." `
            -Recommendation 'Revisar em Gerenciador de Tarefas > Aplicativos de inicializacao. Este modulo nao desativa itens automaticamente.'
        Set-PerfResult 'WARN'
    }
}

function Show-PerfServicesAnalysis {
    <# -Completo reproduz a saida integral da acao 'Services' da versao anterior. #>
    [CmdletBinding()]
    param([switch]$Completo)

    $svc = Get-PerfSafeRows -Name 'Get-CompartDiskServiceDiagnostics'
    if ($null -eq $svc) {
        # Antes: lista vazia/nula caia no "else" e reportava tudo OK - um falso positivo.
        Write-Log WARN 'Diagnostico de servicos indisponivel. Nada sera afirmado sobre os servicos essenciais.'
        Add-CompartDiskFinding -Severity WARN -Area 'Servicos' `
            -Message 'Nao foi possivel obter o diagnostico dos servicos essenciais.' `
            -Recommendation 'Verificar se o servico "Windows Management Instrumentation" esta em execucao.'
        Set-PerfResult 'WARN'
        return
    }
    $linhas = @($svc)
    if ($linhas.Count -eq 0) {
        Write-Log WARN 'A consulta de servicos retornou uma lista vazia; nenhum servico foi avaliado.'
        Set-PerfResult 'WARN'
        return
    }

    if ($Completo) {
        Write-Color ''
        $linhas | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    }

    $problemas = @($linhas | Where-Object { $_.Diagnostico -ne 'OK' })
    if ($problemas.Count -gt 0) {
        Write-Color ''
        $problemas | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Servicos essenciais com desvio' -Status WARN -Rows $problemas
        foreach ($p in $problemas) {
            Add-CompartDiskFinding -Severity WARN -Area 'Servicos' `
                -Message "Servico '$($p.Servico)' esta $($p.Estado) (inicio: $($p.Inicio))." `
                -Recommendation 'Restaurar o tipo de inicializacao padrao e iniciar o servico. Este modulo nao altera servicos automaticamente.'
        }
        Set-PerfResult 'WARN'
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Servicos' -Message 'Todos os servicos essenciais operando normalmente.'
    }
    Add-CompartDiskSection -Title 'Servicos essenciais' -Status $(if ($problemas.Count -gt 0) { 'WARN' } else { 'OK' }) -Rows $linhas
}

function Show-Analysis {
    <# Nome preservado da versao anterior. Somente diagnostico: nada e alterado. #>
    [CmdletBinding()]
    param()

    Show-PerfPowerAnalysis

    # --- Processos (comportamento original preservado e ampliado) -----------
    $proc = Get-PerfSafeRows -Name 'Get-CompartDiskProcessDiagnostics' -Parameters @{ Top = 12 }
    if ($proc) {
        Write-Color ''
        Write-Color '  MAIORES CONSUMIDORES DE MEMORIA' -Color White
        $proc | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Processos (top memoria)' -Status INFO -Rows $proc
    }

    $topCpu = Get-PerfProcessSnapshot -Top 8
    if ($topCpu -and @($topCpu).Count -gt 0) {
        Write-Color ''
        Write-Color '  MAIORES CONSUMIDORES DE CPU (tempo acumulado desde o inicio do processo)' -Color White
        $topCpu | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
        Add-CompartDiskSection -Title 'Processos (top CPU acumulada)' -Status INFO -Rows (@($topCpu))
    }

    Show-PerfSystemLoad
    Show-PerfStartupAnalysis
    Show-PerfServicesAnalysis

    Write-Log OK 'Analise de desempenho concluida.'
}

# ============================================================================
# 13. EXECUCAO
# ============================================================================

# O Start deve ocorrer FORA do try/finally principal. Na versao anterior, o
# "exit" apos um Start malsucedido ainda disparava o finally e chamava
# Stop-CompartDiskModule -Result 'OK' para um modulo que nunca iniciou.
$script:Started = $false
try {
    $precisaAdmin = @('Ultimate', 'Balanced') -contains $Action
    $script:Started = [bool](Start-CompartDiskModule -Name 'Performance' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)
} catch {
    [Console]::Error.WriteLine("COMPARTDISK/Performance: falha ao iniciar o modulo -> $($_.Exception.Message)")
    exit (Get-PerfExitCode -Name 'ERROR' -Default $script:FallbackExit['ERROR'])
}
if (-not $script:Started) {
    exit (Get-PerfExitCode -Name 'ERROR' -Default $script:FallbackExit['ERROR'])
}

$codigo = $null
try {
    Initialize-PerfEnvironment

    if (-not [string]::IsNullOrWhiteSpace($script:OsCaption)) {
        Write-Log INFO "Sistema: $($script:OsCaption) | PowerShell $($PSVersionTable.PSVersion) | Administrador: $(if ($script:IsAdmin) { 'sim' } else { 'nao' })"
    }
    if (@('Ultimate', 'Balanced') -contains $Action -and -not $script:IsAdmin) {
        # Salvaguarda: se o Core permitir prosseguir sem elevacao, o usuario
        # precisa saber que as alteracoes de energia provavelmente falharao.
        Set-PerfResult 'WARN'
        Write-Log WARN 'A acao solicitada altera configuracoes do sistema, mas o processo nao esta elevado. Varias alteracoes tendem a falhar.'
    }

    switch ($Action) {
        'Analyze'   { Show-Analysis }
        'Ultimate'  { Invoke-PerfUltimate }
        'Balanced'  { Invoke-PerfBalanced }
        'Startup'   { Show-PerfStartupAnalysis -Detalhado }
        'Processes' {
            $p = Get-PerfSafeRows -Name 'Get-CompartDiskProcessDiagnostics' -Parameters @{ Top = 25 }
            if ($p) {
                $p | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
                Add-CompartDiskSection -Title 'Processos' -Status INFO -Rows $p
            }
            $topCpu = Get-PerfProcessSnapshot -Top 12
            if ($topCpu -and @($topCpu).Count -gt 0) {
                Write-Color ''
                Write-Color '  MAIORES CONSUMIDORES DE CPU (tempo acumulado)' -Color White
                $topCpu | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
                Add-CompartDiskSection -Title 'Processos (top CPU acumulada)' -Status INFO -Rows (@($topCpu))
            }
            Write-Log INFO 'Acao meramente diagnostica: nenhum processo foi encerrado, suspenso ou teve prioridade alterada.'
        }
        'Services'  { Show-PerfServicesAnalysis -Completo }
    }
} catch {
    Set-PerfResult 'ERROR'
    try {
        Write-Log ERR "Falha nao tratada no modulo Performance (Acao=$Action)." -ErrorRecord $_
    } catch {
        [Console]::Error.WriteLine("COMPARTDISK/Performance: $($_.Exception.Message)")
    }
    try {
        Add-CompartDiskFinding -Severity CRIT -Area 'Desempenho' -Message "Excecao no modulo: $($_.Exception.Message)"
    } catch {
        Write-Verbose 'Nao foi possivel registrar o achado da excecao.'
    }
} finally {
    # Fonte unica de verdade: o resultado escalonado durante toda a execucao.
    $result = $script:ModuleResult
    try {
        $raw = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
        if ($raw -is [array] -and $raw.Count -gt 0) { $raw = $raw[$raw.Count - 1] }
        if ($null -ne $raw) {
            try { $codigo = [int]$raw } catch { $codigo = $null }
        }
    } catch {
        [Console]::Error.WriteLine("COMPARTDISK/Performance: falha ao finalizar o modulo -> $($_.Exception.Message)")
    }
}

# Antes: "exit $codigo" com $codigo nulo encerrava com 0 mesmo apos erro.
if ($null -eq $codigo) {
    $codigo = Get-PerfExitCode -Name $script:ModuleResult -Default $script:FallbackExit[$script:ModuleResult]
}
exit $codigo
