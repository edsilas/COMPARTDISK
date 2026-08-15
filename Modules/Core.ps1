<#
================================================================================
 COMPARTDISK 1.4.1 - Core.ps1
 Desenvolvido por Edsilas
 Biblioteca central de funcoes reutilizaveis.
 Compativel com Windows PowerShell 5.1 e PowerShell 7.x (pwsh).
 Somente componentes nativos do Windows 10/11. Sem modulos externos, sem PSGallery.
================================================================================
 USO: todo modulo deve iniciar com:
      . (Join-Path $PSScriptRoot 'Core.ps1')
      Start-CompartDiskModule -Name 'Network'
================================================================================
#>

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# Diretorio real do Core (capturado no carregamento, sobrevive ao dot-sourcing)
# ------------------------------------------------------------------------------
$__CompartDiskCoreDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($__CompartDiskCoreDir)) {
    $__CompartDiskCoreDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

if (-not $Global:CompartDisk) { $Global:CompartDisk = @{} }

$Global:CompartDisk.CoreDir    = $__CompartDiskCoreDir
$Global:CompartDisk.Root       = Split-Path -Parent $__CompartDiskCoreDir
$Global:CompartDisk.Version    = '1.4.1'
$Global:CompartDisk.Product    = 'COMPARTDISK'
$Global:CompartDisk.Author     = 'Edsilas'
$Global:CompartDisk.Signature  = 'DESENVOLVIDO POR EDSILAS'
$Global:CompartDisk.Exit       = @{ OK = 0; WARN = 1; ERROR = 2; UNSUPPORTED = 3 }
$Global:CompartDisk.Findings   = New-Object System.Collections.ArrayList
$Global:CompartDisk.Sections   = New-Object System.Collections.ArrayList
$Global:CompartDisk.Caps       = @{}

# Raiz vinda do Launcher tem prioridade
if (-not [string]::IsNullOrWhiteSpace($env:COMPARTDISK_ROOT)) {
    $Global:CompartDisk.Root = $env:COMPARTDISK_ROOT.TrimEnd('\')
}

# ------------------------------------------------------------------------------
# Contexto de sessao (log, saida, identificacao)
# ------------------------------------------------------------------------------
function Initialize-CompartDiskContext {
    [CmdletBinding()]
    param()

    if ($Global:CompartDisk.Initialized) { return }

    $logDir = $env:COMPARTDISK_LOGDIR
    if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = $Global:CompartDisk.Root }

    # Fallback em cadeia: pasta do script -> Desktop -> TEMP
    $candidates = @($logDir, (Join-Path $env:USERPROFILE 'Desktop'), $env:TEMP)
    $chosen = $null
    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
            $probe = Join-Path $c ('.compartdisk_{0}.tmp' -f $PID)
            [System.IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $chosen = $c
            break
        } catch { continue }
    }
    if (-not $chosen) { $chosen = $env:TEMP }

    $logFile = $env:COMPARTDISK_LOGFILE
    if ([string]::IsNullOrWhiteSpace($logFile)) { $logFile = Join-Path $chosen 'Relatorio_Manutencao.txt' }

    $session = $env:COMPARTDISK_SESSION
    if ([string]::IsNullOrWhiteSpace($session)) { $session = (Get-Date -Format 'yyyyMMdd_HHmmss') }

    $outDir = Join-Path $chosen ('COMPARTDISK_Relatorios\{0}' -f $session)
    try { if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null } }
    catch { $outDir = $chosen }

    $Global:CompartDisk.LogDir      = $chosen
    $Global:CompartDisk.LogFile     = $logFile
    $Global:CompartDisk.OutDir      = $outDir
    $Global:CompartDisk.Session     = $session
    $Global:CompartDisk.Computer    = $env:COMPUTERNAME
    $Global:CompartDisk.User        = $env:USERNAME
    $Global:CompartDisk.Engine      = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $Global:CompartDisk.PSVersion   = $PSVersionTable.PSVersion.ToString()
    $Global:CompartDisk.Initialized = $true
}

# ------------------------------------------------------------------------------
# Write-Color : saida colorida resiliente (nunca derruba o modulo)
# ------------------------------------------------------------------------------
function Write-Color {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [switch]$NoNewLine
    )
    try {
        if ($NoNewLine) { Write-Host $Text -ForegroundColor $Color -NoNewline }
        else            { Write-Host $Text -ForegroundColor $Color }
    } catch {
        # Nao usar Write-Output aqui: o texto entraria no stream de saida e
        # passaria a integrar o valor de retorno de quem chamou (ex.: o codigo
        # devolvido por Stop-CompartDiskModule viraria um array).
        try {
            if ($NoNewLine) { [Console]::Out.Write($Text) } else { [Console]::Out.WriteLine($Text) }
        } catch { }
    }
}

function Write-CompartDiskBanner {
    # Mesma gramatica visual do Launcher: margem de 2 espacos, titulo em branco,
    # linha de identidade em cinza e regua fina de 74 colunas.
    param([Parameter(Mandatory)][string]$Title)
    Write-Color ''
    Write-Color ("  {0}" -f $Title) -Color White
    Write-Color ("  {0} {1} - {2}" -f $Global:CompartDisk.Product, $Global:CompartDisk.Version, $Global:CompartDisk.Signature) -Color DarkGray
    Write-Color ("  " + ('-' * 74)) -Color DarkGray
    Write-Color ''
}

function Write-CompartDiskKeyValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][object]$Value,
        [int]$Pad = 26,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    if ($null -eq $Value -or "$Value" -eq '') { $Value = 'n/d' }
    Write-Color ("  {0} : {1}" -f $Key.PadRight($Pad), $Value) -Color $Color
}

# ------------------------------------------------------------------------------
# Interacao numerica (compartilhada pelos modulos com menu proprio)
# ------------------------------------------------------------------------------
function Test-CompartDiskInterativo {
    <# Ha um operador para responder? Em execucao desassistida (-Quiet ou entrada
       redirecionada) nenhum modulo pode parar esperando tecla. #>
    [CmdletBinding()] param([switch]$Quiet)
    if ($Quiet) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { }
    return $true
}

function Test-CompartDiskTecladoDireto {
    <# O console aceita leitura tecla a tecla? Entrada redirecionada, host sem
       RawUI e ambiente sem console de verdade nao aceitam - e nesses casos a
       leitura por linha e o caminho correto, nao uma falha. #>
    [CmdletBinding()] param()
    try {
        if ([Console]::IsInputRedirected) { return $false }
        if (-not $Host.UI.RawUI) { return $false }
        # Consulta que so responde onde existe console real.
        $null = [Console]::KeyAvailable
        return $true
    } catch { return $false }
}

function Read-CompartDiskEntradaOpcao {
    <# Devolve o texto digitado para um menu de 0 a $Maximo. A escolha vale assim
       que o numero digitado nao pode mais crescer para outra opcao valida, sem
       exigir Enter: e o mesmo comportamento do CHOICE que atende os menus do
       Launcher.bat.

       Menu de ate 10 opcoes (0 a 9): a primeira tecla ja decide. Onde existe
       opcao de dois digitos, apenas o prefixo realmente ambiguo (o "1" de um
       menu que vai ate 10, por exemplo) espera a tecla seguinte - e Enter fecha
       a escolha nesse prefixo. Backspace corrige e Esc equivale a [0].

       Sem console (entrada redirecionada, host sem RawUI) a leitura por linha
       continua valendo: nenhum ambiente fica sem menu. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Maximo, [string]$Rotulo = '  Escolha')

    if (-not (Test-CompartDiskTecladoDireto)) { return (Read-Host $Rotulo) }

    Write-Color ("{0}: " -f $Rotulo) -NoNewLine

    $buffer = ''
    while ($true) {
        $tecla = $null
        try { $tecla = [Console]::ReadKey($true) }
        catch {
            # Console perdido durante a leitura: voltar a leitura por linha em
            # vez de deixar o menu sem resposta.
            Write-Color ''
            return (Read-Host $Rotulo)
        }

        if ($tecla.Key -eq [ConsoleKey]::Enter)  { Write-Color ''; return $buffer }
        if ($tecla.Key -eq [ConsoleKey]::Escape) { Write-Color '0'; return '0' }
        if ($tecla.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                $buffer = $buffer.Substring(0, $buffer.Length - 1)
                Write-Color "`b `b" -NoNewLine
            }
            continue
        }

        # Tecla sem caractere util (setas, funcao, controle): ignorada, como no CHOICE.
        if ([char]::IsControl($tecla.KeyChar)) { continue }
        $ch = [string]$tecla.KeyChar

        # Nao numerica: devolvida como esta, para a recusa de sempre.
        if ($ch -notmatch '^\d$') {
            Write-Color $ch -NoNewLine
            Write-Color ''
            return ($buffer + $ch)
        }

        Write-Color $ch -NoNewLine
        $novo = $buffer + $ch

        # [0] nunca cresce: nenhuma opcao valida comeca por zero.
        if ($novo -eq '0') { Write-Color ''; return '0' }

        # Ja passou do maximo, ou nenhum digito adicional caberia: decide agora.
        $n = [int]$novo
        if ($n -gt $Maximo -or ($n * 10) -gt $Maximo) { Write-Color ''; return $novo }

        # Prefixo ambiguo: aguarda a proxima tecla (ou o Enter).
        $buffer = $novo
    }
}

function Read-CompartDiskOpcao {
    <# Le uma opcao NUMERICA entre 0 e $Maximo. Letras sao recusadas: os menus da
       ferramenta sao operados so por numeros. A leitura da tecla fica em
       Read-CompartDiskEntradaOpcao; a validacao e as mensagens sao estas. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Maximo, [string]$Rotulo = '  Escolha')
    while ($true) {
        $entrada = Read-CompartDiskEntradaOpcao -Maximo $Maximo -Rotulo $Rotulo
        if ($null -eq $entrada) { return 0 }
        $entrada = $entrada.Trim()
        if ($entrada -eq '') { continue }
        if ($entrada.Length -gt 3 -or $entrada -notmatch '^\d+$') {
            Write-Color '  Use apenas numeros.' -Color Yellow
            continue
        }
        $n = [int]$entrada
        if ($n -gt $Maximo) {
            Write-Color ("  Opcao invalida. Informe um numero de 0 a {0}." -f $Maximo) -Color Yellow
            continue
        }
        return $n
    }
}

# ------------------------------------------------------------------------------
# Write-Log : motor central de logs (arquivo + console)
# ------------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'DEBUG')][string]$Level = 'INFO',
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Message,
        [string]$Module,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [switch]$NoConsole
    )

    Initialize-CompartDiskContext
    if (-not $Module) { $Module = $Global:CompartDisk.CurrentModule }
    if (-not $Module) { $Module = 'Core' }

    if ($Level -eq 'DEBUG' -and $env:COMPARTDISK_DEBUG -ne '1') { return }

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '[{0}] [{1}] [{2}] {3}' -f $stamp, $Level.PadRight(4), $Module, $Message

    if ($ErrorRecord) {
        $ex   = $ErrorRecord.Exception
        $code = 'n/d'
        try { if ($ex -is [System.ComponentModel.Win32Exception]) { $code = $ex.NativeErrorCode } else { $code = $ex.HResult } } catch {}
        $line += "`r`n    +-- Tipo      : $($ex.GetType().FullName)"
        $line += "`r`n    +-- Codigo    : $code"
        $line += "`r`n    +-- Categoria : $($ErrorRecord.CategoryInfo.Category)"
        $line += "`r`n    +-- Origem    : $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber)"
        if ($ErrorRecord.ScriptStackTrace) {
            $line += "`r`n    +-- StackTrace:"
            foreach ($st in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) { $line += "`r`n        $st" }
        }
    }

    # Gravacao com retry curto (arquivo pode estar sob lock do Batch)
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Add-Content -LiteralPath $Global:CompartDisk.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds 120
        }
    }

    if (-not $NoConsole) {
        $color = switch ($Level) {
            'OK'    { [ConsoleColor]::Green }
            'WARN'  { [ConsoleColor]::Yellow }
            'ERR'   { [ConsoleColor]::Red }
            'INFO'  { [ConsoleColor]::DarkGray }
            'DEBUG' { [ConsoleColor]::DarkGray }
            default { [ConsoleColor]::Gray }
        }
        # Marcador de largura fixa e margem de 2 espacos: a saida do PowerShell
        # fica alinhada em coluna com a do Launcher, formando um fluxo unico.
        $tag = switch ($Level) {
            'OK'    { '[ OK ]' }
            'WARN'  { '[WARN]' }
            'ERR'   { '[ERRO]' }
            'INFO'  { '[INFO]' }
            'DEBUG' { '[DBG ]' }
            default { '[INFO]' }
        }
        Write-Color ("  " + $tag) -Color $color -NoNewLine
        Write-Color (" " + $Message) -Color Gray
        if ($ErrorRecord) { Write-Color ("         {0}" -f $ErrorRecord.Exception.Message) -Color DarkRed }
    }
}

# ------------------------------------------------------------------------------
# Achados (findings) : alimentam o resumo executivo dos relatorios
# ------------------------------------------------------------------------------
function Add-CompartDiskFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('CRIT', 'WARN', 'OK', 'INFO')][string]$Severity,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Message,
        [string]$Recommendation = ''
    )
    [void]$Global:CompartDisk.Findings.Add([pscustomobject]@{
        Severity       = $Severity
        Area           = $Area
        Message        = $Message
        Recommendation = $Recommendation
        Timestamp      = (Get-Date -Format 's')
    })
}

function Add-CompartDiskSection {
    <# $Pairs e IDictionary, nao hashtable.

       Todos os modulos montam os pares com [ordered]@{} porque a ordem E a
       informacao: destino antes de tamanho, tentativa antes de resultado, valor
       antes da conclusao. Um parametro declarado [hashtable] forcava a conversao
       de OrderedDictionary para Hashtable, que nao tem ordem definida - as
       chaves chegavam embaralhadas ao TXT, ao CSV, ao HTML e ao state_*.json, e
       a cada execucao numa ordem diferente. O Report.ps1 chega a reconstruir um
       [ordered] a partir do JSON justamente para preservar a sequencia, e essa
       conversao anulava o esforco.

       IDictionary aceita Hashtable e OrderedDictionary sem converter nenhum dos
       dois, entao quem passa [ordered] mantem a ordem e quem passa hashtable
       continua funcionando como antes. E o mesmo tipo que Audit.ps1 ja usa para
       reconhecer estes dicionarios. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('CRIT', 'WARN', 'OK', 'INFO')][string]$Status = 'INFO',
        [string]$Summary = '',
        [object[]]$Rows = @(),
        [System.Collections.IDictionary]$Pairs
    )
    [void]$Global:CompartDisk.Sections.Add([pscustomobject]@{
        Title   = $Title
        Status  = $Status
        Summary = $Summary
        Rows    = $Rows
        Pairs   = $Pairs
    })
}

# ------------------------------------------------------------------------------
# Ciclo de vida do modulo
# ------------------------------------------------------------------------------
function Start-CompartDiskModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Action = '',
        [switch]$RequireAdmin,
        [switch]$Quiet
    )

    Initialize-CompartDiskContext
    $Global:CompartDisk.CurrentModule = $Name
    $Global:CompartDisk.CurrentAction = $Action
    $Global:CompartDisk.ModuleStart   = Get-Date
    $Global:CompartDisk.ModuleResult  = $Global:CompartDisk.Exit.OK

    if (-not $Quiet) {
        $titulo = if ($Action) { "$Name :: $Action" } else { $Name }
        Write-CompartDiskBanner $titulo
    }

    Write-Log INFO ("Modulo iniciado (Acao='{0}') | PC={1} | User={2} | {3} {4} | {5} Build {6}" -f `
        $Action, $Global:CompartDisk.Computer, $Global:CompartDisk.User, $Global:CompartDisk.Engine, $Global:CompartDisk.PSVersion, `
        (Get-CompartDiskOSName), (Get-CompartDiskBuild)) -NoConsole

    if ($RequireAdmin -and -not (Test-Administrator)) {
        Write-Log ERR 'Privilegios administrativos obrigatorios e ausentes.'
        Add-CompartDiskFinding -Severity CRIT -Area $Name -Message 'Execucao sem privilegios administrativos.' -Recommendation 'Reabrir o Launcher.bat como Administrador.'
        return $false
    }
    return $true
}

function Stop-CompartDiskModule {
    [CmdletBinding()]
    param(
        [ValidateSet('OK', 'WARN', 'ERROR', 'UNSUPPORTED')][string]$Result = 'OK',
        [string]$Message = '',
        [switch]$Quiet
    )

    $elapsed = if ($Global:CompartDisk.ModuleStart) { (Get-Date) - $Global:CompartDisk.ModuleStart } else { [timespan]::Zero }
    $code    = $Global:CompartDisk.Exit[$Result]
    $mod     = $Global:CompartDisk.CurrentModule

    $lvl = switch ($Result) { 'OK' { 'OK' } 'WARN' { 'WARN' } 'ERROR' { 'ERR' } default { 'WARN' } }
    $txt = if ($Message) { $Message } else { "Modulo finalizado" }
    Write-Log $lvl ("{0} | Resultado={1} | Tempo={2:N2}s" -f $txt, $Result, $elapsed.TotalSeconds) -NoConsole

    if (-not $Quiet) {
        $color = switch ($Result) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'DarkGray' } }
        $tagFim = switch ($Result) {
            'OK'          { '[ OK ]' }
            'WARN'        { '[WARN]' }
            'ERROR'       { '[ERRO]' }
            'UNSUPPORTED' { '[ N/D]' }
            default       { '[INFO]' }
        }
        Write-Color ("`n  {0} {1} concluido em {2:N2}s" -f $tagFim, $mod, $elapsed.TotalSeconds) -Color $color
    }

    # Persiste o resultado para agregacao pelo Report.ps1
    try {
        # O nome inclui a acao: opcoes de menu que invocam o mesmo modulo duas
        # vezes (Defender Update+QuickScan, Smart Volumes+Shadow, ...) sobrescreviam
        # o estado da primeira execucao, que sumia do relatorio consolidado.
        $acao   = $Global:CompartDisk.CurrentAction
        $rotulo = if ([string]::IsNullOrWhiteSpace($acao)) { $mod } else { '{0}_{1}' -f $mod, $acao }
        $state = Join-Path $Global:CompartDisk.OutDir ('state_{0}.json' -f $rotulo)
        $payload = [pscustomobject]@{
            Module    = $mod
            Result    = $Result
            Message   = $Message
            Elapsed   = [math]::Round($elapsed.TotalSeconds, 2)
            Timestamp = (Get-Date -Format 's')
            Findings  = @($Global:CompartDisk.Findings)
            Sections  = @($Global:CompartDisk.Sections)
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $state -Encoding UTF8
    } catch {
        Write-Log DEBUG "Falha ao persistir estado do modulo: $($_.Exception.Message)" -NoConsole
    }

    return $code
}

# ------------------------------------------------------------------------------
# Execucao defensiva
# ------------------------------------------------------------------------------
function Invoke-SafeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$ScriptBlock,
        [string]$Activity = 'Operacao',
        [switch]$Critical,
        [object]$Default = $null,
        [switch]$Silent
    )
    $result = [pscustomobject]@{ Success = $false; Value = $Default; Error = $null; Activity = $Activity }
    try {
        $result.Value   = & $ScriptBlock
        $result.Success = $true
        if (-not $Silent) { Write-Log DEBUG "OK: $Activity" -NoConsole }
    } catch {
        $result.Error = $_
        $lvl = if ($Critical) { 'ERR' } else { 'WARN' }
        Write-Log $lvl ("Falha em '{0}': {1}" -f $Activity, $_.Exception.Message) -ErrorRecord $_ -NoConsole:$Silent
        if ($Critical) { throw }
    }
    return $result
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$ScriptBlock,
        [int]$Retries = 3,
        [int]$DelaySeconds = 2,
        [switch]$Exponential,
        [string]$Activity = 'Operacao'
    )
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            if ($attempt -eq $Retries) {
                Write-Log ERR ("'{0}' falhou apos {1} tentativas." -f $Activity, $Retries) -ErrorRecord $_
                throw
            }
            $wait = if ($Exponential) { $DelaySeconds * [math]::Pow(2, $attempt - 1) } else { $DelaySeconds }
            Write-Log WARN ("'{0}' tentativa {1}/{2} falhou. Nova tentativa em {3}s." -f $Activity, $attempt, $Retries, $wait)
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-NativeCommand {
    <# Executa um executavel nativo capturando saida e codigo de retorno. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0,
        [switch]$PassThruOutput
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = ($Arguments -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()

        # Os dois canais precisam ser drenados CONCORRENTEMENTE. Ler stdout ate o
        # fim e so depois stderr trava quando o processo filho enche o buffer do
        # canal ainda nao lido (~4 KB) - e o WaitForExit abaixo jamais chegaria a
        # ser avaliado, tornando o tempo limite inoperante. 'takeown /r' e
        # 'pnputil /export-driver' produzem volume suficiente para isso.
        # ReadToEndAsync existe desde o .NET 4.5: nativo no Windows 10/11, valido
        # em Windows PowerShell 5.1 e em PowerShell 7.
        $tarefaOut = $proc.StandardOutput.ReadToEndAsync()
        $tarefaErr = $proc.StandardError.ReadToEndAsync()

        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch {}
                throw "Tempo limite excedido ($TimeoutSeconds s) em $FilePath"
            }
        } else {
            $proc.WaitForExit()
        }

        $stdout = $tarefaOut.Result
        $stderr = $tarefaErr.Result
        $out = [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Success  = ($proc.ExitCode -eq 0)
        }
        # Write-Host, nao Write-Output: emitir no stream de sucesso faz o retorno
        # virar um array [string, pscustomobject] e $r.ExitCode passa a depender de
        # enumeracao de membro em vez de acesso direto.
        if ($PassThruOutput -and $stdout) { Write-Host $stdout }
        return $out
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

# ------------------------------------------------------------------------------
# Testes de ambiente / capacidades
# ------------------------------------------------------------------------------
function Test-Administrator {
    [CmdletBinding()] param()
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-PowerShell {
    <# Retorna objeto com edicao, versao e suporte a recursos. #>
    [CmdletBinding()] param()
    $v = $PSVersionTable.PSVersion
    return [pscustomobject]@{
        Version    = $v.ToString()
        Major      = $v.Major
        Edition    = $(if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' })
        Is7Plus    = ($v.Major -ge 7)
        Is51       = ($v.Major -eq 5 -and $v.Minor -ge 1)
        Supported  = ($v.Major -ge 5)
        CLRVersion = $(if ($PSVersionTable.CLRVersion) { $PSVersionTable.CLRVersion.ToString() } else { 'n/d' })
        Language   = $ExecutionContext.SessionState.LanguageMode.ToString()
    }
}

function Test-WindowsVersion {
    <# Identifica Windows 10/11, build, edicao e se e suportado pela ferramenta. #>
    [CmdletBinding()] param()
    $os    = Get-CompartDiskCim -Class Win32_OperatingSystem
    $build = 0
    try { $build = [int](Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber') } catch {}
    if ($build -eq 0 -and $os) { $build = [int]($os.BuildNumber) }

    $ubr = 0
    try { $ubr = [int](Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR') } catch {}
    $displayVersion = ''
    try { $displayVersion = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion' } catch {
        try { $displayVersion = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'ReleaseId' } catch {}
    }

    $isWin11 = ($build -ge 22000)
    return [pscustomobject]@{
        Caption        = $(if ($os) { $os.Caption } else { 'n/d' })
        Build          = $build
        UBR            = $ubr
        FullBuild      = "$build.$ubr"
        DisplayVersion = $displayVersion
        Family         = $(if ($isWin11) { 'Windows 11' } elseif ($build -ge 10240) { 'Windows 10' } else { 'Legado' })
        IsWindows11    = $isWin11
        IsWindows10    = (-not $isWin11 -and $build -ge 10240)
        Supported      = ($build -ge 10240)
        Architecture   = $(if ($os) { $os.OSArchitecture } else { $env:PROCESSOR_ARCHITECTURE })
        InstallDate    = $(if ($os) { $os.InstallDate } else { $null })
        LastBoot       = $(if ($os) { $os.LastBootUpTime } else { $null })
    }
}

function Get-CompartDiskOSName { try { (Test-WindowsVersion).Caption } catch { 'n/d' } }
function Get-CompartDiskBuild   { try { (Test-WindowsVersion).FullBuild } catch { 'n/d' } }

function Test-Winget {
    [CmdletBinding()] param()
    try {
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $cmd) { return [pscustomobject]@{ Available = $false; Version = $null; Path = $null } }
        $r = Invoke-NativeCommand -FilePath $cmd.Source -Arguments @('--version') -TimeoutSeconds 30
        return [pscustomobject]@{
            Available = $r.Success
            Version   = ($r.StdOut -replace '\s', '')
            Path      = $cmd.Source
        }
    } catch { return [pscustomobject]@{ Available = $false; Version = $null; Path = $null } }
}

function Test-WingetAvailability {
    <# Estado ESTRUTURADO do ambiente WinGet - dono unico da decisao.
       O modulo de aplicativos, o de preparacao e o Launcher leem daqui, para que
       nao existam tres diagnosticos diferentes discordando entre si.

       State: Available | Outdated | Broken | Missing | Blocked | Unsupported | Unknown

       "winget.exe nao encontrado" NAO e prova de que o App Installer nao existe:
       o executavel e um alias de execucao que some quando o pacote perde o
       registro no perfil, com o pacote ainda instalado. Por isso o pacote AppX e
       consultado antes de qualquer conclusao.

       Nunca lanca: um diagnostico que derruba o modulo nao serve para nada. #>
    [CmdletBinding()]
    param([switch]$Refresh, [switch]$Completo, [switch]$TestarConectividade)

    if ($Global:CompartDisk.WingetState -and -not $Refresh) { return $Global:CompartDisk.WingetState }

    $r = [pscustomobject]@{
        State               = 'Unknown'
        Reason              = ''
        Executable          = $null
        Version             = $null
        VersionText         = $null
        AppInstaller        = 'Nao verificado'
        AppInstallerVersion = $null
        PackageStatus       = $null
        Registered          = $false
        Provisioned         = $false
        StoreAvailable      = $null
        PolicyBlocked       = $false
        PolicyDetail        = ''
        SourcesOk           = $null
        Online              = $null
        Supported           = $true
        Admin               = $false
        Windows             = $null
        StoreProductId      = '9NBLGGH4NNS1'
        PackageFamily       = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
        PackageName         = 'Microsoft.DesktopAppInstaller'
        MinBuild            = 17763
        Detail              = @()
    }
    $notas = New-Object System.Collections.ArrayList
    $anota = { param($t) [void]$notas.Add($t) }

    try { $r.Admin = Test-Administrator } catch { }

    # --- 1. sistema operacional --------------------------------------------
    try { $r.Windows = Test-WindowsVersion } catch { }
    if ($r.Windows -and $r.Windows.Build -gt 0 -and $r.Windows.Build -lt $r.MinBuild) {
        $r.Supported = $false
        $r.State     = 'Unsupported'
        $r.Reason    = ('O App Installer exige Windows 10 versao 1809 (build {0}) ou superior; esta maquina esta na build {1}.' -f $r.MinBuild, $r.Windows.Build)
        & $anota $r.Reason
        $r.Detail = @($notas)
        $Global:CompartDisk.WingetState = $r
        return $r
    }

    # --- 2. politica --------------------------------------------------------
    # Somente leitura. O COMPARTDISK nunca altera politica para habilitar o WinGet.
    $polApp = Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' 'EnableAppInstaller'
    $polCli = Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' 'EnableWindowsPackageManagerCommandLineInterfaces'
    if ($null -ne $polApp -and [int]$polApp -eq 0) {
        $r.PolicyBlocked = $true
        $r.PolicyDetail  = 'Politica "Enable App Installer" desativada (EnableAppInstaller=0).'
    } elseif ($null -ne $polCli -and [int]$polCli -eq 0) {
        $r.PolicyBlocked = $true
        $r.PolicyDetail  = 'Politica "Enable App Installer Command Line Interfaces" desativada.'
    }
    if ($r.PolicyBlocked) { & $anota $r.PolicyDetail }

    # --- 3. pacote AppX do App Installer ------------------------------------
    if (Test-CompartDiskCommand 'Get-AppxPackage') { $null = $true } else { $null = Import-CompartDiskModule 'Appx' }
    if (Test-CompartDiskCommand 'Get-AppxPackage') {
        try {
            $pkg = Get-AppxPackage -Name $r.PackageName -ErrorAction Stop | Select-Object -First 1
            if ($pkg) {
                $r.Registered          = $true
                $r.AppInstaller        = 'Presente'
                $r.AppInstallerVersion = [string]$pkg.Version
                try { $r.PackageStatus = [string]$pkg.Status } catch { }
                & $anota ('App Installer registrado no perfil (versao {0}).' -f $r.AppInstallerVersion)
            } else {
                $r.AppInstaller = 'Ausente'
                & $anota 'App Installer nao esta registrado para este usuario.'
            }
        } catch {
            $r.AppInstaller = 'Nao verificavel'
            & $anota ('Consulta ao pacote AppX falhou: {0}' -f $_.Exception.Message)
        }
    } else {
        $r.AppInstaller = 'Nao verificavel'
        & $anota 'Cmdlets AppX indisponiveis neste motor: o estado do pacote nao pode ser afirmado.'
    }

    # Provisionamento na imagem (exige privilegio) - permite reparo sem download.
    if ($Completo -and $r.Admin -and (Test-CompartDiskCommand 'Get-AppxProvisionedPackage')) {
        try {
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                    Where-Object { $_.DisplayName -eq $r.PackageName } | Select-Object -First 1
            if ($prov) { $r.Provisioned = $true; & $anota 'Pacote provisionado na imagem do Windows.' }
        } catch { & $anota ('Consulta de pacotes provisionados falhou: {0}' -f $_.Exception.Message) }
    }

    # --- 4. Microsoft Store -------------------------------------------------
    $lojaRemovida = Get-CompartDiskRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore'
    if ($null -ne $lojaRemovida -and [int]$lojaRemovida -eq 1) {
        $r.StoreAvailable = $false
        & $anota 'Microsoft Store removida por politica (RemoveWindowsStore=1).'
    } elseif (Test-CompartDiskCommand 'Get-AppxPackage') {
        try { $r.StoreAvailable = [bool](Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop) } catch { $r.StoreAvailable = $null }
    }

    # --- 5. executavel ------------------------------------------------------
    $w = Test-Winget          # reaproveita a deteccao ja existente, sem duplica-la
    if ($w.Path) { $r.Executable = $w.Path }
    if (-not $r.Executable -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        # Alias de execucao do App Installer. E o caminho que some quando o
        # registro do pacote se perde, com o pacote ainda instalado.
        try {
            $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path -LiteralPath $alias) { $r.Executable = $alias }
        } catch { }
    }
    if ($w.Available) {
        $r.VersionText = $w.Version
        $m = [regex]::Match([string]$w.Version, '(\d+)\.(\d+)(\.\d+)*')
        if ($m.Success) { try { $r.Version = [version]$m.Value } catch { } }
    }

    # --- 6. conclusao -------------------------------------------------------
    if ($w.Available) {
        # Executou "--version" com sucesso. Confirma com "--info", que exercita
        # a inicializacao completa do gerenciador.
        $infoOk = $true
        try {
            $info = Invoke-NativeCommand -FilePath $r.Executable -Arguments @('--info') -TimeoutSeconds 60
            $infoOk = ($info.ExitCode -eq 0)
            if (-not $infoOk) { & $anota ('"winget --info" retornou codigo {0}.' -f $info.ExitCode) }
        } catch { $infoOk = $false; & $anota ('"winget --info" falhou: {0}' -f $_.Exception.Message) }

        if (-not $infoOk) {
            $r.State  = 'Broken'
            $r.Reason = 'O winget responde a --version mas falha ao inicializar (--info).'
        } elseif ($r.Version -and $r.Version -lt [version]'1.4') {
            $r.State  = 'Outdated'
            $r.Reason = ('Versao {0} e anterior a 1.4: parte dos parametros usados pelo COMPARTDISK nao existe nela.' -f $r.VersionText)
        } else {
            $r.State  = 'Available'
            $r.Reason = 'WinGet disponivel e funcional.'
        }
    } elseif ($r.PolicyBlocked) {
        $r.State  = 'Blocked'
        $r.Reason = $r.PolicyDetail
    } elseif ($r.Registered) {
        $r.State  = 'Broken'
        $r.Reason = 'O App Installer esta instalado, mas o winget nao executa. O registro do pacote no perfil pode ter se perdido.'
    } elseif ($r.AppInstaller -eq 'Nao verificavel' -and -not $r.Executable) {
        $r.State  = 'Unknown'
        $r.Reason = 'Nao foi possivel confirmar o estado do App Installer neste ambiente.'
    } else {
        $r.State  = 'Missing'
        $r.Reason = 'O App Installer (que fornece o WinGet) nao esta disponivel para este usuario.'
    }

    # --- 7. fontes e conectividade -----------------------------------------
    if ($Completo -and ($r.State -eq 'Available' -or $r.State -eq 'Outdated')) {
        try {
            $src = Invoke-NativeCommand -FilePath $r.Executable -Arguments @('source', 'list', '--accept-source-agreements') -TimeoutSeconds 60
            $r.SourcesOk = ($src.ExitCode -eq 0 -and $src.StdOut -match '(?im)^\s*winget\s')
            if (-not $r.SourcesOk) { & $anota 'A fonte oficial "winget" nao respondeu a consulta local de fontes.' }
        } catch { $r.SourcesOk = $false; & $anota ('Consulta de fontes falhou: {0}' -f $_.Exception.Message) }
    }
    if ($TestarConectividade) {
        try { $r.Online = (Test-Internet).Online } catch { $r.Online = $null }
    }

    if (-not $r.Reason) { $r.Reason = 'Estado indeterminado.' }
    & $anota ('Resultado: {0} - {1}' -f $r.State, $r.Reason)
    $r.Detail = @($notas)

    $Global:CompartDisk.WingetState = $r
    return $r
}

function Test-WMI {
    [CmdletBinding()] param()
    try {
        if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
            $null = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            return $true
        }
        # PowerShell 7 removeu Get-WmiObject: valida o repositorio via CIM/DCOM
        $opt = New-CimSessionOption -Protocol Dcom
        $s   = New-CimSession -SessionOption $opt -ErrorAction Stop
        try { $null = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem -ErrorAction Stop; return $true }
        finally { Remove-CimSession $s -ErrorAction SilentlyContinue }
    } catch { return $false }
}

function Test-CIM {
    [CmdletBinding()] param()
    try { $null = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; return $true } catch { return $false }
}

function Get-CompartDiskCim {
    <# Acesso unificado ao repositorio: CIM -> WMI -> CIM/DCOM. Nunca lanca por padrao. #>
    [CmdletBinding()]
    param(
        [string]$Class,
        [string]$Namespace = 'root\cimv2',
        [string]$Filter,
        [string]$Query,
        [switch]$ThrowOnError
    )
    if (-not $Class -and -not $Query) { throw 'Get-CompartDiskCim exige -Class ou -Query.' }
    $splat = @{ ErrorAction = 'Stop' }
    if ($Query) { $splat['Query'] = $Query } else { $splat['ClassName'] = $Class }
    if ($Filter -and -not $Query) { $splat['Filter'] = $Filter }
    $splat['Namespace'] = $Namespace

    try { return Get-CimInstance @splat } catch { $first = $_ }

    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        try {
            $w = @{ Namespace = $Namespace; ErrorAction = 'Stop' }
            if ($Query) { $w['Query'] = $Query } else { $w['Class'] = $Class }
            if ($Filter -and -not $Query) { $w['Filter'] = $Filter }
            return Get-WmiObject @w
        } catch { }
    }

    try {
        $opt = New-CimSessionOption -Protocol Dcom
        $s   = New-CimSession -SessionOption $opt -ErrorAction Stop
        try { $splat['CimSession'] = $s; return Get-CimInstance @splat }
        finally { Remove-CimSession $s -ErrorAction SilentlyContinue }
    } catch { }

    Write-Log DEBUG ("Consulta indisponivel: {0}\{1} -> {2}" -f $Namespace, $Class, $first.Exception.Message) -NoConsole
    if ($ThrowOnError) { throw $first }
    return $null
}

function Import-CompartDiskModule {
    <# Importa modulo nativo do Windows com tolerancia a PowerShell 7 (-SkipEditionCheck). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (Get-Module -Name $Name) { return $true }
    try { Import-Module $Name -ErrorAction Stop -WarningAction SilentlyContinue; return $true } catch { }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        try { Import-Module $Name -SkipEditionCheck -ErrorAction Stop -WarningAction SilentlyContinue; return $true } catch { }
        try {
            $p = Join-Path $env:SystemRoot ('System32\WindowsPowerShell\v1.0\Modules\{0}' -f $Name)
            if (Test-Path -LiteralPath $p) { Import-Module $p -SkipEditionCheck -ErrorAction Stop -WarningAction SilentlyContinue; return $true }
        } catch { }
    }
    Write-Log DEBUG "Modulo nativo indisponivel: $Name" -NoConsole
    return $false
}

function Test-CompartDiskCommand {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Test-TPM {
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Present = $false; Ready = $false; Enabled = $false; Activated = $false; Version = 'n/d'; Manufacturer = 'n/d'; Status = 'Ausente' }
    try {
        $tpm = Get-CompartDiskCim -Class Win32_Tpm -Namespace 'root\CIMV2\Security\MicrosoftTpm'
        if ($tpm) {
            $out.Present      = $true
            $out.Enabled      = [bool]$tpm.IsEnabled_InitialValue
            $out.Activated    = [bool]$tpm.IsActivated_InitialValue
            $out.Ready        = ($out.Enabled -and $out.Activated)
            $out.Manufacturer = "$($tpm.ManufacturerIdTxt)".Trim()
            $out.Version      = "$($tpm.SpecVersion)".Split(',')[0].Trim()
            $out.Status       = if ($out.Ready) { 'Pronto' } else { 'Presente mas nao pronto' }
        } elseif (Test-CompartDiskCommand 'Get-Tpm') {
            $t = Get-Tpm -ErrorAction Stop
            $out.Present = $t.TpmPresent; $out.Ready = $t.TpmReady; $out.Enabled = $t.TpmEnabled
            $out.Activated = $t.TpmActivated
            $out.Status = if ($t.TpmReady) { 'Pronto' } else { 'Nao pronto' }
        }
    } catch { Write-Log DEBUG "Test-TPM: $($_.Exception.Message)" -NoConsole }
    return $out
}

function Test-SecureBoot {
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Supported = $false; Enabled = $false; FirmwareType = 'n/d'; Status = 'n/d' }
    try {
        $fw = 'Legacy BIOS'
        try {
            $v = Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'PEFirmwareType' -ErrorAction Stop
            $fw = if ($v -eq 2) { 'UEFI' } else { 'Legacy BIOS' }
        } catch { }
        $out.FirmwareType = $fw

        if (Test-CompartDiskCommand 'Confirm-SecureBootUEFI') {
            try {
                $out.Enabled   = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
                $out.Supported = $true
                $out.Status    = if ($out.Enabled) { 'Habilitado' } else { 'Desabilitado' }
            } catch {
                $out.Supported = ($fw -eq 'UEFI')
                $out.Status    = if ($fw -eq 'UEFI') { 'Nao configurado' } else { 'Nao suportado (Legacy BIOS)' }
            }
        }
    } catch { Write-Log DEBUG "Test-SecureBoot: $($_.Exception.Message)" -NoConsole }
    return $out
}

function Test-BitLocker {
    [CmdletBinding()] param()
    $result = New-Object System.Collections.ArrayList
    try {
        if (Import-CompartDiskModule 'BitLocker') {
            foreach ($v in (Get-BitLockerVolume -ErrorAction Stop)) {
                [void]$result.Add([pscustomobject]@{
                    MountPoint       = $v.MountPoint
                    VolumeType       = "$($v.VolumeType)"
                    ProtectionStatus = "$($v.ProtectionStatus)"
                    VolumeStatus     = "$($v.VolumeStatus)"
                    EncryptionMethod = "$($v.EncryptionMethod)"
                    Percentage       = $v.EncryptionPercentage
                    Protectors       = (($v.KeyProtector | ForEach-Object { $_.KeyProtectorType }) -join ', ')
                    Source           = 'Cmdlet'
                })
            }
        }
    } catch { Write-Log DEBUG "Get-BitLockerVolume: $($_.Exception.Message)" -NoConsole }

    if ($result.Count -eq 0) {
        # Fallback nativo: WMI Win32_EncryptableVolume
        try {
            $vols = Get-CompartDiskCim -Class Win32_EncryptableVolume -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption'
            $mapProt = @{ 0 = 'Off'; 1 = 'On'; 2 = 'Unknown' }
            $mapConv = @{ 0 = 'FullyDecrypted'; 1 = 'FullyEncrypted'; 2 = 'EncryptionInProgress'; 3 = 'DecryptionInProgress'; 4 = 'EncryptionPaused'; 5 = 'DecryptionPaused' }
            foreach ($v in $vols) {
                $st = $null
                try { $st = $v | Invoke-CimMethod -MethodName GetConversionStatus -ErrorAction Stop } catch {}
                [void]$result.Add([pscustomobject]@{
                    MountPoint       = $v.DriveLetter
                    VolumeType       = 'n/d'
                    ProtectionStatus = $mapProt[[int]$v.ProtectionStatus]
                    VolumeStatus     = $(if ($st) { $mapConv[[int]$st.ConversionStatus] } else { 'n/d' })
                    EncryptionMethod = "$($v.EncryptionMethod)"
                    Percentage       = $(if ($st) { $st.EncryptionPercentage } else { $null })
                    Protectors       = 'n/d'
                    Source           = 'WMI'
                })
            }
        } catch { Write-Log DEBUG "Win32_EncryptableVolume: $($_.Exception.Message)" -NoConsole }
    }

    if ($result.Count -eq 0) {
        # Ultimo recurso: manage-bde
        try {
            $exe = Join-Path $env:SystemRoot 'System32\manage-bde.exe'
            if (Test-Path -LiteralPath $exe) {
                $r = Invoke-NativeCommand -FilePath $exe -Arguments @('-status') -TimeoutSeconds 90
                if ($r.StdOut) {
                    [void]$result.Add([pscustomobject]@{
                        MountPoint = 'n/d'; VolumeType = 'n/d'; ProtectionStatus = 'Ver saida bruta'
                        VolumeStatus = 'n/d'; EncryptionMethod = 'n/d'; Percentage = $null
                        Protectors = 'n/d'; Source = 'manage-bde'
                    })
                    $Global:CompartDisk.BitLockerRaw = $r.StdOut
                }
            }
        } catch { }
    }
    return @($result)
}

function Test-Internet {
    [CmdletBinding()]
    param(
        [string[]]$Targets = @('www.msftconnecttest.com', 'dns.msftncsi.com', '8.8.8.8'),
        [int]$TimeoutMs = 3000
    )
    $out = [pscustomobject]@{ Online = $false; Method = 'n/d'; Latency = $null; DnsOk = $false; Target = $null }
    try {
        $prof = Get-CompartDiskCim -Class MSFT_NetConnectionProfile -Namespace 'root\StandardCimv2'
        if ($prof) { $out.Method = 'NetConnectionProfile' }
    } catch { }

    foreach ($t in $Targets) {
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $reply = $ping.Send($t, $TimeoutMs)
            if ($reply.Status -eq 'Success') {
                $out.Online  = $true
                $out.Latency = $reply.RoundtripTime
                $out.Target  = $t
                $out.Method  = 'ICMP'
                break
            }
        } catch { continue }
    }

    try {
        $null = [System.Net.Dns]::GetHostEntry('www.microsoft.com')
        $out.DnsOk = $true
    } catch { $out.DnsOk = $false }

    if (-not $out.Online) {
        # ICMP pode estar bloqueado por politica: valida HTTP
        try {
            $req = [System.Net.WebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
            $req.Timeout = $TimeoutMs
            $resp = $req.GetResponse()
            $resp.Close()
            $out.Online = $true
            $out.Method = 'HTTP'
        } catch { }
    }
    return $out
}

function Get-CompartDiskCapabilities {
    <# Mapa unico de capacidades do ambiente, cacheado por sessao. #>
    [CmdletBinding()] param([switch]$Refresh)
    if ($Global:CompartDisk.Caps.Count -gt 0 -and -not $Refresh) { return $Global:CompartDisk.Caps }
    $c = @{}
    $c.Admin      = Test-Administrator
    $c.PowerShell = Test-PowerShell
    $c.Windows    = Test-WindowsVersion
    $c.CIM        = Test-CIM
    $c.WMI        = Test-WMI
    $c.Winget     = Test-Winget
    # Estado estruturado do ambiente WinGet (Available/Broken/Missing/...). O campo
    # acima permanece como estava: quem so precisa saber "existe ou nao" continua
    # lendo $c.Winget.Available.
    $c.WingetEnv  = Test-WingetAvailability
    $c.Defender   = (Test-CompartDiskCommand 'Get-MpComputerStatus') -or (Import-CompartDiskModule 'Defender')
    $c.BitLocker  = (Import-CompartDiskModule 'BitLocker')
    $c.Storage    = (Test-CompartDiskCommand 'Get-PhysicalDisk')
    $c.NetTCPIP   = (Test-CompartDiskCommand 'Get-NetIPConfiguration')
    $c.Firewall   = (Test-CompartDiskCommand 'Get-NetFirewallProfile')
    $c.PnPUtil    = (Test-Path (Join-Path $env:SystemRoot 'System32\pnputil.exe'))
    $c.DISM       = (Test-CompartDiskCommand 'Get-WindowsImage') -or (Test-Path (Join-Path $env:SystemRoot 'System32\Dism.exe'))
    $Global:CompartDisk.Caps = $c
    return $c
}

# ------------------------------------------------------------------------------
# Utilitarios
# ------------------------------------------------------------------------------
function ConvertTo-CompartDiskSize {
    param([Parameter(Mandatory)][AllowNull()][object]$Bytes, [int]$Decimals = 2)
    if ($null -eq $Bytes) { return 'n/d' }
    $b = [double]$Bytes
    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    $i = 0
    while ($b -ge 1024 -and $i -lt ($units.Count - 1)) { $b /= 1024; $i++ }
    return ('{0} {1}' -f [math]::Round($b, $Decimals), $units[$i])
}

function Get-CompartDiskFolderSize {
    param([Parameter(Mandatory)][string]$Path)
    $r = [pscustomobject]@{ Path = $Path; Bytes = 0; Files = 0; Exists = $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $r }
        $r.Exists = $true
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        if ($items) {
            $m = $items | Measure-Object -Property Length -Sum
            $r.Bytes = [long]$m.Sum
            $r.Files = [int]$m.Count
        }
    } catch { Write-Log DEBUG "Get-CompartDiskFolderSize '$Path': $($_.Exception.Message)" -NoConsole }
    return $r
}

function Test-CompartDiskProtectedPath {
    <# Ponto unico de decisao sobre caminhos que nunca podem ser removidos nem ter
       propriedade/ACL reescritas.

       A normalizacao e aplicada aos DOIS lados da comparacao. Antes, a lista
       guardava "C:\" enquanto o alvo era normalizado para "C:": a raiz do disco -
       justamente o caminho mais destrutivo - nunca casava e passava batido.
       docs/MANUAL-TECNICO.md ja declarava a raiz como protegida. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AdditionalPaths = @()
    )
    $base = @(
        "$env:SystemRoot"
        "$env:SystemRoot\System32"
        "$env:SystemDrive\"
        "$env:ProgramFiles"
    )
    # "C:" (sem barra) e um caminho RELATIVO A UNIDADE: Resolve-Path devolve o
    # diretorio corrente daquela unidade, nunca a raiz, e a guarda passava batido.
    $alvo = "$Path"
    if ($alvo -match '^[A-Za-z]:$') { $alvo = "$alvo\" }
    $norm = try { (Resolve-Path -LiteralPath $alvo -ErrorAction Stop).Path } catch { $alvo }
    $norm = "$norm".TrimEnd('\')
    foreach ($p in @($base + $AdditionalPaths)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ("$p".TrimEnd('\') -eq $norm) { return $true }
    }
    return $false
}

function Remove-CompartDiskPathSafely {
    <# Remocao idempotente e defensiva do CONTEUDO de um caminho.

       -KeepRoot preserva a pasta alvo. Sem ele a pasta tambem e removida ao final -
       e o padrao, porque o unico chamador que precisa disso e o reset de GPO, onde
       o Windows recria a pasta no gpupdate seguinte. Todos os alvos de limpeza
       passam -KeepRoot explicitamente.

       Caminhos criticos do sistema sao recusados por Test-CompartDiskProtectedPath. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$KeepRoot,
        [string[]]$ExcludeNames = @(),
        [string[]]$ExcludePatterns = @()
    )
    $out = [pscustomobject]@{ Path = $Path; Removed = 0; Failed = 0; BytesFreed = 0; Skipped = $false }

    $norm = try { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\') } catch { $Path.TrimEnd('\') }
    if (Test-CompartDiskProtectedPath -Path $Path -AdditionalPaths @("$env:USERPROFILE")) {
        Write-Log WARN "Caminho protegido, remocao recusada: $norm"
        $out.Skipped = $true
        return $out
    }
    if (-not (Test-Path -LiteralPath $Path)) { $out.Skipped = $true; return $out }

    $items = @()
    try { $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch { }
    foreach ($item in $items) {
        if ($ExcludeNames -contains $item.Name) { continue }
        $preservar = $false
        foreach ($padrao in $ExcludePatterns) {
            if ($item.Name -like $padrao) { $preservar = $true; break }
        }
        if ($preservar) { continue }
        try {
            $size = 0
            if ($item.PSIsContainer) {
                $size = (Get-CompartDiskFolderSize -Path $item.FullName).Bytes
            } else { $size = $item.Length }
            if ($PSCmdlet.ShouldProcess($item.FullName, 'Remover')) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $out.Removed++
                $out.BytesFreed += $size
            }
        } catch {
            $out.Failed++
            Write-Log DEBUG "Bloqueado (em uso): $($item.FullName)" -NoConsole
        }
    }
    if (-not $KeepRoot) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $out
}

function Set-CompartDiskRegistryValue {
    <# Escrita idempotente no registro, com backup do valor anterior no log. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')][string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        $old = $null
        try { $old = Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop } catch { $old = '<inexistente>' }
        if ("$old" -eq "$Value") {
            Write-Log DEBUG "Registro ja no estado desejado: $Path\$Name = $Value" -NoConsole
            return $true
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null

        # EVIDENCIA: no log de 13/08/2026 o modulo Telemetry registrou varias
        # gravacoes como OK sem nenhuma releitura. "New-ItemProperty nao lancou"
        # nao prova que o valor ficou gravado: diretiva, ACL ou redirecionamento
        # de colmeia podem aceitar a chamada e manter o valor anterior.
        $confirmado = $false
        $lido = '<nao lido>'
        try {
            $lido = Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
            if ($Type -in @('Binary', 'MultiString')) {
                # Tipos compostos nao comparam de forma confiavel como texto:
                # confirma-se a presenca do valor, nao a igualdade literal.
                $confirmado = $true
            } else {
                $confirmado = ("$lido" -eq "$Value")
            }
        } catch {
            Write-Log DEBUG "Releitura de $Path\$Name falhou: $($_.Exception.Message)" -NoConsole
        }

        if (-not $confirmado) {
            Write-Log WARN "Registro gravado sem confirmacao: $Path\$Name esperava '$Value' e a releitura devolveu '$lido'."
            return $false
        }
        Write-Log OK "Registro: $Path\$Name  ($old -> $Value) (confirmado por releitura)" -NoConsole
        return $true
    } catch {
        Write-Log WARN "Falha ao gravar $Path\$Name" -ErrorRecord $_
        return $false
    }
}

function Get-CompartDiskRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, $Default = $null)
    try { return Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop } catch { return $Default }
}

function Set-CompartDiskServiceState {
    <# Para/inicia servicos de forma tolerante, respeitando dependencias. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][ValidateSet('Stop', 'Start')][string]$Action,
        [int]$TimeoutSeconds = 30
    )
    $res = New-Object System.Collections.ArrayList
    foreach ($n in $Name) {
        $item = [pscustomobject]@{ Service = $n; Action = $Action; Success = $false; Detail = '' }
        try {
            $svc = Get-Service -Name $n -ErrorAction Stop
            if ($Action -eq 'Stop') {
                if ($svc.Status -eq 'Stopped') { $item.Success = $true; $item.Detail = 'Ja parado' }
                else {
                    Stop-Service -Name $n -Force -ErrorAction Stop -WarningAction SilentlyContinue
                    $svc.WaitForStatus('Stopped', [timespan]::FromSeconds($TimeoutSeconds))
                    $item.Success = $true; $item.Detail = 'Parado'
                }
            } else {
                if ($svc.Status -eq 'Running') { $item.Success = $true; $item.Detail = 'Ja em execucao' }
                else {
                    Start-Service -Name $n -ErrorAction Stop
                    $svc.WaitForStatus('Running', [timespan]::FromSeconds($TimeoutSeconds))
                    $item.Success = $true; $item.Detail = 'Iniciado'
                }
            }
        } catch {
            $item.Detail = $_.Exception.Message
            Write-Log WARN ("Servico '{0}' nao respondeu a '{1}': {2}" -f $n, $Action, $_.Exception.Message) -NoConsole
        }
        [void]$res.Add($item)
    }
    return @($res)
}

# ------------------------------------------------------------------------------
# Relatorios: TXT / CSV / JSON / HTML
# ------------------------------------------------------------------------------
function Write-CompartDiskReportFile {
    <# Escrita ATOMICA e verificada de um arquivo de relatorio.

       A gravacao direta no caminho final deixava dois modos de falha silenciosos:
       uma interrupcao no meio da escrita produzia um arquivo truncado com aparencia
       de valido, e uma falha de escrita destruia o relatorio anterior antes de
       falhar. Grava-se num temporario, confere-se o conteudo e so entao ele
       substitui o arquivo final - se qualquer etapa falhar, o relatorio anterior
       permanece intacto e a excecao sobe para quem chamou.

       Codificacao: "Set-Content -Encoding UTF8" grava BOM no Windows PowerShell 5.1
       e NAO grava no PowerShell 7, produzindo bytes diferentes conforme o motor - e
       o Launcher prefere o pwsh 7. Sem BOM, o Excel abre o CSV com acentuacao
       corrompida (a, e, c com til e cedilha). O padrao passa a ser explicito e
       igual nos dois motores: BOM em TXT/CSV/HTML, sem BOM em JSON. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [bool]$Bom = $true
    )
    $tmp = "$Path.tmp"
    try {
        # Um diretorio ocupando o caminho de destino faria Move-Item mover o
        # temporario para DENTRO dele. Verificar so o "tamanho" nao pega isso: em
        # PowerShell, .Length devolve 1 para qualquer objeto escalar - inclusive um
        # DirectoryInfo - entao tamanho maior que zero nao prova que existe arquivo.
        if (Test-Path -LiteralPath $Path -PathType Container) { throw "o caminho de destino e um diretorio: $Path" }

        [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($Bom)))
        $fiTmp = Get-Item -LiteralPath $tmp -ErrorAction Stop
        if ($fiTmp.PSIsContainer -or $fiTmp.Length -le 0) { throw "conteudo vazio apos a escrita de $([System.IO.Path]::GetFileName($Path))" }

        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($fi.PSIsContainer -or $fi.Length -le 0) { throw "arquivo final invalido ou vazio: $Path" }
        return $fi.FullName
    } finally {
        # O temporario nunca pode sobreviver a uma falha.
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function New-Report {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [object]$Data,
        [ValidateSet('TXT', 'CSV', 'JSON', 'HTML')][string[]]$Format = @('TXT', 'CSV', 'JSON', 'HTML'),
        [string]$Title = 'Relatorio de Manutencao',
        [string]$OutputDirectory,
        [switch]$Open
    )

    Initialize-CompartDiskContext
    if (-not $OutputDirectory) { $OutputDirectory = $Global:CompartDisk.OutDir }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    if (-not $Data) {
        $Data = [ordered]@{
            Meta     = New-CompartDiskReportMeta
            Sections = @($Global:CompartDisk.Sections)
            Findings = @($Global:CompartDisk.Findings)
        }
    }

    $base     = Join-Path $OutputDirectory ('{0}_{1}' -f $Name, $Global:CompartDisk.Session)
    $produced = New-Object System.Collections.ArrayList

    foreach ($f in $Format) {
        try {
            switch ($f) {
                'JSON' {
                    # UTF-8 SEM marca de ordem de bytes: o JSON e declarado para
                    # consumo automatizado e parsers estritos recusam o BOM.
                    [void]$produced.Add((Write-CompartDiskReportFile -Path "$base.json" -Content ($Data | ConvertTo-Json -Depth 10) -Bom:$false))
                }
                'TXT' {
                    [void]$produced.Add((Write-CompartDiskReportFile -Path "$base.txt" -Content (ConvertTo-CompartDiskText -Data $Data -Title $Title)))
                }
                'CSV' {
                    $rows = ConvertTo-CompartDiskFlatRows -Data $Data
                    if ($rows.Count -gt 0) {
                        $csv = ($rows | ConvertTo-Csv -NoTypeInformation -Delimiter ';') -join "`r`n"
                        [void]$produced.Add((Write-CompartDiskReportFile -Path "$base.csv" -Content $csv))
                    } else {
                        Write-Log DEBUG 'CSV nao gerado: nenhuma linha achatada a publicar.' -NoConsole
                    }
                }
                'HTML' {
                    [void]$produced.Add((Write-CompartDiskReportFile -Path "$base.html" -Content (ConvertTo-CompartDiskHtml -Data $Data -Title $Title)))
                }
            }
        } catch {
            Write-Log WARN "Falha ao gerar relatorio $f" -ErrorRecord $_
        }
    }

    foreach ($p in $produced) { Write-Log OK "Relatorio gerado: $p" }

    if ($Open) {
        $html = $produced | Where-Object { $_ -like '*.html' } | Select-Object -First 1
        if ($html) { try { Start-Process $html } catch { Write-Log WARN "Nao foi possivel abrir o relatorio automaticamente." } }
    }
    return @($produced)
}

function New-CompartDiskReportMeta {
    $w = Test-WindowsVersion
    $p = Test-PowerShell
    $cs = Get-CompartDiskCim -Class Win32_ComputerSystem
    return [ordered]@{
        Ferramenta    = "COMPARTDISK $($Global:CompartDisk.Version)"
        Autor         = $Global:CompartDisk.Author
        GeradoEm      = (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
        Computador    = $Global:CompartDisk.Computer
        Dominio       = $(if ($cs) { $cs.Domain } else { 'n/d' })
        Usuario       = $Global:CompartDisk.User
        Administrador = (Test-Administrator)
        Windows       = $w.Caption
        Familia       = $w.Family
        Versao        = $w.DisplayVersion
        Build         = $w.FullBuild
        Arquitetura   = $w.Architecture
        PowerShell    = "$($p.Edition) $($p.Version)"
        Sessao        = $Global:CompartDisk.Session
    }
}

function ConvertTo-CompartDiskText {
    param([Parameter(Mandatory)][object]$Data, [string]$Title = 'Relatorio')
    $sb = New-Object System.Text.StringBuilder
    $w  = { param($t) [void]$sb.AppendLine($t) }

    & $w ('=' * 78)
    & $w ("  $Title".ToUpper())
    & $w ('=' * 78)

    if ($Data.Meta) {
        & $w ''
        & $w '-- IDENTIFICACAO ------------------------------------------------------------'
        foreach ($k in $Data.Meta.Keys) { & $w ("  {0} : {1}" -f "$k".PadRight(16), $Data.Meta[$k]) }
    }

    $findings = @($Data.Findings)
    if ($findings.Count -gt 0) {
        & $w ''
        & $w '-- RESUMO EXECUTIVO ---------------------------------------------------------'
        foreach ($sev in @('CRIT', 'WARN', 'OK', 'INFO')) {
            $n = @($findings | Where-Object { $_.Severity -eq $sev }).Count
            & $w ("  {0} : {1}" -f $sev.PadRight(6), $n)
        }
        foreach ($sev in @('CRIT', 'WARN')) {
            $itens = @($findings | Where-Object { $_.Severity -eq $sev })
            if ($itens.Count -eq 0) { continue }
            & $w ''
            & $w ("  [{0}]" -f $(if ($sev -eq 'CRIT') { 'ITENS CRITICOS' } else { 'ITENS EM ATENCAO' }))
            foreach ($i in $itens) {
                & $w ("   - ({0}) {1}" -f $i.Area, $i.Message)
                if ($i.Recommendation) { & $w ("       Recomendacao: {0}" -f $i.Recommendation) }
            }
        }
    }

    foreach ($s in @($Data.Sections)) {
        & $w ''
        & $w ('-- {0} {1}' -f $s.Title.ToUpper(), ('-' * [math]::Max(1, (74 - $s.Title.Length))))
        if ($s.Summary) { & $w ("  {0}" -f $s.Summary) }
        if ($s.Pairs) {
            foreach ($k in $s.Pairs.Keys) { & $w ("  {0} : {1}" -f "$k".PadRight(26), $s.Pairs[$k]) }
        }
        $rows = @($s.Rows)
        if ($rows.Count -gt 0) {
            & $w ''
            try { & $w (($rows | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()) }
            catch { foreach ($r in $rows) { & $w ("  {0}" -f ($r | Out-String).Trim()) } }
        }
    }

    & $w ''
    & $w ('=' * 78)
    & $w ("  Fim do relatorio - COMPARTDISK {0}" -f $Global:CompartDisk.Version)
    & $w ("  {0}" -f $Global:CompartDisk.Signature)
    return $sb.ToString()
}

function ConvertTo-CompartDiskFlatRows {
    param([Parameter(Mandatory)][object]$Data)
    $rows = New-Object System.Collections.ArrayList
    foreach ($f in @($Data.Findings)) {
        [void]$rows.Add([pscustomobject]@{
            Tipo = 'Achado'; Secao = $f.Area; Severidade = $f.Severity
            Campo = ''; Valor = $f.Message; Recomendacao = $f.Recommendation
        })
    }
    foreach ($s in @($Data.Sections)) {
        if ($s.Pairs) {
            foreach ($k in $s.Pairs.Keys) {
                [void]$rows.Add([pscustomobject]@{
                    Tipo = 'Propriedade'; Secao = $s.Title; Severidade = $s.Status
                    Campo = "$k"; Valor = "$($s.Pairs[$k])"; Recomendacao = ''
                })
            }
        }
        foreach ($r in @($s.Rows)) {
            $props = $r.PSObject.Properties
            $desc  = ($props | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' | '
            [void]$rows.Add([pscustomobject]@{
                Tipo = 'Registro'; Secao = $s.Title; Severidade = $s.Status
                Campo = ''; Valor = $desc; Recomendacao = ''
            })
        }
    }
    return @($rows)
}

function ConvertTo-CompartDiskHtmlEncoded {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'n/d' }
    $s = "$Value"
    $s = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
    return $s
}

function ConvertTo-CompartDiskHtml {
    param([Parameter(Mandatory)][object]$Data, [string]$Title = 'Relatorio de Manutencao')

    $css = @'
:root{
  --bg:#0d1117; --panel:#151b23; --panel-2:#1b2129; --rule:#252d38;
  --ink:#c9d3de; --ink-dim:#7d8a99; --ink-bright:#eef3f8;
  --crit:#e5484d; --warn:#e3a008; --ok:#3dd68c; --info:#4c8dff; --accent:#4c8dff;
  --mono:"Cascadia Mono","Cascadia Code",Consolas,"Lucida Console",monospace;
  --sans:"Segoe UI Variable Text","Segoe UI",Tahoma,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);font-size:14px;line-height:1.55}
.wrap{max-width:1240px;margin:0 auto;padding:0 24px 64px}
header{border-bottom:1px solid var(--rule);background:linear-gradient(180deg,#11161d,#0d1117);position:sticky;top:0;z-index:9}
.hd{max-width:1240px;margin:0 auto;padding:20px 24px 16px;display:flex;flex-wrap:wrap;gap:18px;align-items:flex-end;justify-content:space-between}
h1{font-family:var(--mono);font-size:19px;letter-spacing:.14em;text-transform:uppercase;color:var(--ink-bright);margin:0 0 4px;font-weight:600}
.sub{font-family:var(--mono);font-size:11.5px;color:var(--ink-dim);letter-spacing:.06em}
.counts{display:flex;gap:8px;flex-wrap:wrap}
.count{font-family:var(--mono);font-size:11px;letter-spacing:.09em;padding:7px 13px;border:1px solid var(--rule);background:var(--panel);border-radius:2px;display:flex;gap:9px;align-items:baseline}
.count b{font-size:17px;font-weight:600}
.count.c b{color:var(--crit)} .count.w b{color:var(--warn)} .count.o b{color:var(--ok)} .count.i b{color:var(--info)}
.toolbar{max-width:1240px;margin:0 auto;padding:12px 24px 0;display:flex;gap:10px;flex-wrap:wrap}
input[type=search]{flex:1;min-width:220px;background:var(--panel);border:1px solid var(--rule);color:var(--ink);padding:9px 12px;font-family:var(--mono);font-size:12px;border-radius:2px}
input[type=search]:focus{outline:2px solid var(--info);outline-offset:1px}
button.tb{background:var(--panel);border:1px solid var(--rule);color:var(--ink-dim);font-family:var(--mono);font-size:11px;letter-spacing:.08em;padding:9px 14px;cursor:pointer;border-radius:2px}
button.tb:hover{color:var(--ink-bright);border-color:var(--ink-dim)}
button.tb:focus-visible{outline:2px solid var(--info);outline-offset:1px}
h2.sec{font-family:var(--mono);font-size:12px;letter-spacing:.18em;text-transform:uppercase;color:var(--ink-dim);margin:38px 0 12px;padding-bottom:7px;border-bottom:1px solid var(--rule)}
.card{background:var(--panel);border:1px solid var(--rule);border-left:3px solid var(--rule);border-radius:2px;margin:0 0 10px;overflow:hidden}
.card.crit{border-left-color:var(--crit)} .card.warn{border-left-color:var(--warn)}
.card.ok{border-left-color:var(--ok)} .card.info{border-left-color:var(--info)}
summary{cursor:pointer;padding:13px 16px;display:flex;gap:14px;align-items:center;list-style:none;user-select:none}
summary::-webkit-details-marker{display:none}
summary:focus-visible{outline:2px solid var(--info);outline-offset:-2px}
.tok{font-family:var(--mono);font-size:11px;font-weight:600;letter-spacing:.05em;white-space:nowrap}
.card.crit .tok{color:var(--crit)} .card.warn .tok{color:var(--warn)}
.card.ok .tok{color:var(--ok)} .card.info .tok{color:var(--info)}
.tt{color:var(--ink-bright);font-weight:600;font-size:14.5px}
.sm{color:var(--ink-dim);font-size:12.5px;margin-left:auto;text-align:right}
.body{padding:2px 16px 18px;border-top:1px solid var(--rule)}
dl{display:grid;grid-template-columns:minmax(150px,240px) 1fr;gap:1px;margin:14px 0 0;background:var(--rule);border:1px solid var(--rule)}
dt,dd{background:var(--panel-2);margin:0;padding:8px 12px}
dt{font-family:var(--mono);font-size:11.5px;color:var(--ink-dim);letter-spacing:.03em}
dd{color:var(--ink-bright);word-break:break-word}
table{width:100%;border-collapse:collapse;margin-top:14px;font-size:12.5px}
th{font-family:var(--mono);font-size:10.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-dim);text-align:left;padding:8px 10px;border-bottom:1px solid var(--rule);white-space:nowrap}
td{padding:8px 10px;border-bottom:1px solid var(--rule);vertical-align:top;word-break:break-word}
tr:last-child td{border-bottom:none}
tbody tr:hover td{background:var(--panel-2)}
.finding{display:grid;grid-template-columns:64px 150px 1fr;gap:12px;padding:11px 16px;border-bottom:1px solid var(--rule);align-items:start}
.finding:last-child{border-bottom:none}
.finding .area{font-family:var(--mono);font-size:11.5px;color:var(--ink-dim)}
.finding .rec{display:block;color:var(--ink-dim);font-size:12px;margin-top:4px;padding-left:11px;border-left:2px solid var(--rule)}
.empty{padding:16px;color:var(--ink-dim);font-family:var(--mono);font-size:12px}
.brand{font-family:var(--mono);font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--accent);margin-bottom:6px}
footer{margin-top:48px;padding-top:18px;border-top:1px solid var(--rule);color:var(--ink-dim);font-family:var(--mono);font-size:11px;letter-spacing:.05em}
.hidden{display:none}
@media(max-width:720px){
  dl{grid-template-columns:1fr}
  .finding{grid-template-columns:1fr;gap:4px}
  .sm{margin-left:0;text-align:left;width:100%}
  table{display:block;overflow-x:auto}
}
@media print{body{background:#fff;color:#000}.card,dt,dd{background:#fff}header{position:static}.toolbar{display:none}details{display:block}details>.body{display:block!important}}
@media(prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
'@

    $js = @'
(function(){
  var q=document.getElementById("q");
  if(q){q.addEventListener("input",function(){
    var t=q.value.toLowerCase();
    document.querySelectorAll("[data-searchable]").forEach(function(el){
      var hit = t==="" || el.textContent.toLowerCase().indexOf(t)>-1;
      el.classList.toggle("hidden",!hit);
      if(t!=="" && hit && el.tagName==="DETAILS"){el.open=true;}
    });
  });}
  var ex=document.getElementById("expand"), co=document.getElementById("collapse");
  if(ex){ex.addEventListener("click",function(){document.querySelectorAll("details").forEach(function(d){d.open=true;});});}
  if(co){co.addEventListener("click",function(){document.querySelectorAll("details").forEach(function(d){d.open=false;});});}
})();
'@

    $findings = @($Data.Findings)
    $nCrit = @($findings | Where-Object { $_.Severity -eq 'CRIT' }).Count
    $nWarn = @($findings | Where-Object { $_.Severity -eq 'WARN' }).Count
    $nOk   = @($findings | Where-Object { $_.Severity -eq 'OK' }).Count
    $nInfo = @($findings | Where-Object { $_.Severity -eq 'INFO' }).Count

    $meta = $Data.Meta
    $sb = New-Object System.Text.StringBuilder
    $a  = { param($t) [void]$sb.AppendLine($t) }

    & $a '<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">'
    & $a '<meta name="viewport" content="width=device-width,initial-scale=1">'
    & $a ('<title>{0} - {1}</title>' -f (ConvertTo-CompartDiskHtmlEncoded $Title), (ConvertTo-CompartDiskHtmlEncoded $Global:CompartDisk.Computer))
    & $a ('<style>{0}</style></head><body>' -f $css)

    & $a '<header><div class="hd"><div>'
    & $a ('<div class="brand">{0} &middot; {1}</div>' -f `
        (ConvertTo-CompartDiskHtmlEncoded $Global:CompartDisk.Product), `
        (ConvertTo-CompartDiskHtmlEncoded $Global:CompartDisk.Signature))
    & $a ('<h1>{0}</h1>' -f (ConvertTo-CompartDiskHtmlEncoded $Title))
    & $a ('<div class="sub">{0} &middot; {1} &middot; gerado em {2}</div>' -f `
        (ConvertTo-CompartDiskHtmlEncoded $(if ($meta) { $meta.Computador } else { $env:COMPUTERNAME })), `
        (ConvertTo-CompartDiskHtmlEncoded $(if ($meta) { $meta.Windows } else { '' })), `
        (ConvertTo-CompartDiskHtmlEncoded $(if ($meta) { $meta.GeradoEm } else { (Get-Date) })))
    & $a '</div><div class="counts">'
    & $a ('<span class="count c">CRITICO <b>{0}</b></span>' -f $nCrit)
    & $a ('<span class="count w">ATENCAO <b>{0}</b></span>' -f $nWarn)
    & $a ('<span class="count o">OK <b>{0}</b></span>' -f $nOk)
    & $a ('<span class="count i">INFO <b>{0}</b></span>' -f $nInfo)
    & $a '</div></div>'
    & $a '<div class="toolbar"><input type="search" id="q" placeholder="filtrar secoes, propriedades e achados..." aria-label="Filtrar conteudo">'
    & $a '<button class="tb" id="expand" type="button">EXPANDIR TUDO</button><button class="tb" id="collapse" type="button">RECOLHER TUDO</button></div>'
    & $a '</header><div class="wrap">'

    # -- Identificacao
    if ($meta) {
        & $a '<h2 class="sec">Identificacao</h2><div class="card info"><div class="body"><dl>'
        foreach ($k in $meta.Keys) {
            & $a ('<dt>{0}</dt><dd>{1}</dd>' -f (ConvertTo-CompartDiskHtmlEncoded $k), (ConvertTo-CompartDiskHtmlEncoded $meta[$k]))
        }
        & $a '</dl></div></div>'
    }

    # -- Resumo executivo
    & $a '<h2 class="sec">Resumo executivo</h2>'
    if ($findings.Count -eq 0) {
        & $a '<div class="card info"><div class="empty">Nenhum achado registrado nesta execucao.</div></div>'
    } else {
        foreach ($grp in @(@{ S = 'CRIT'; C = 'crit'; L = 'Itens criticos' }, @{ S = 'WARN'; C = 'warn'; L = 'Itens em atencao' }, @{ S = 'OK'; C = 'ok'; L = 'Itens conformes' }, @{ S = 'INFO'; C = 'info'; L = 'Informativos' })) {
            $itens = @($findings | Where-Object { $_.Severity -eq $grp.S })
            if ($itens.Count -eq 0) { continue }
            & $a ('<details open class="card {0}" data-searchable><summary><span class="tok">[{1}]</span><span class="tt">{2}</span><span class="sm">{3} registro(s)</span></summary><div class="body">' -f $grp.C, $grp.S, $grp.L, $itens.Count)
            foreach ($i in $itens) {
                & $a '<div class="finding">'
                & $a ('<span class="tok">[{0}]</span>' -f $i.Severity)
                & $a ('<span class="area">{0}</span>' -f (ConvertTo-CompartDiskHtmlEncoded $i.Area))
                & $a ('<span>{0}' -f (ConvertTo-CompartDiskHtmlEncoded $i.Message))
                if ($i.Recommendation) { & $a ('<span class="rec">{0}</span>' -f (ConvertTo-CompartDiskHtmlEncoded $i.Recommendation)) }
                & $a '</span></div>'
            }
            & $a '</div></details>'
        }
    }

    # -- Secoes
    $sections = @($Data.Sections)
    if ($sections.Count -gt 0) {
        & $a '<h2 class="sec">Diagnostico detalhado</h2>'
        foreach ($s in $sections) {
            $cls = switch ("$($s.Status)") { 'CRIT' { 'crit' } 'WARN' { 'warn' } 'OK' { 'ok' } default { 'info' } }
            & $a ('<details class="card {0}" data-searchable><summary><span class="tok">[{1}]</span><span class="tt">{2}</span><span class="sm">{3}</span></summary><div class="body">' -f `
                $cls, (ConvertTo-CompartDiskHtmlEncoded $s.Status), (ConvertTo-CompartDiskHtmlEncoded $s.Title), (ConvertTo-CompartDiskHtmlEncoded $s.Summary))

            if ($s.Pairs) {
                & $a '<dl>'
                foreach ($k in $s.Pairs.Keys) {
                    & $a ('<dt>{0}</dt><dd>{1}</dd>' -f (ConvertTo-CompartDiskHtmlEncoded $k), (ConvertTo-CompartDiskHtmlEncoded $s.Pairs[$k]))
                }
                & $a '</dl>'
            }

            $rows = @($s.Rows)
            if ($rows.Count -gt 0) {
                $cols = @()
                foreach ($r in $rows) { foreach ($p in $r.PSObject.Properties) { if ($cols -notcontains $p.Name) { $cols += $p.Name } } }
                & $a '<table><thead><tr>'
                foreach ($c in $cols) { & $a ('<th>{0}</th>' -f (ConvertTo-CompartDiskHtmlEncoded $c)) }
                & $a '</tr></thead><tbody>'
                foreach ($r in $rows) {
                    & $a '<tr>'
                    foreach ($c in $cols) { & $a ('<td>{0}</td>' -f (ConvertTo-CompartDiskHtmlEncoded $r.$c)) }
                    & $a '</tr>'
                }
                & $a '</tbody></table>'
            }
            if (-not $s.Pairs -and $rows.Count -eq 0) { & $a '<div class="empty">Sem dados coletados para esta secao.</div>' }
            & $a '</div></details>'
        }
    }

    & $a ('<footer>COMPARTDISK {0} &middot; {1} &middot; sessao {2} &middot; log: {3}</footer>' -f `
        $Global:CompartDisk.Version, (ConvertTo-CompartDiskHtmlEncoded $Global:CompartDisk.Signature), `
        (ConvertTo-CompartDiskHtmlEncoded $Global:CompartDisk.Session), (ConvertTo-CompartDiskHtmlEncoded $Global:CompartDisk.LogFile))
    & $a '</div>'
    & $a ('<script>{0}</script>' -f $js)
    & $a '</body></html>'

    return $sb.ToString()
}

# ------------------------------------------------------------------------------
# Carrega os coletores de dados (usados por Audit, Report e Hardware)
# ------------------------------------------------------------------------------
$__collectors = Join-Path $__CompartDiskCoreDir 'Collectors.ps1'
if (Test-Path -LiteralPath $__collectors) {
    . $__collectors
}

Initialize-CompartDiskContext
