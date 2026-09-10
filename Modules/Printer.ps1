<#
 COMPARTDISK 1.5.1 - Printer.ps1
 Desenvolvido por Edsilas
 Acoes: Menu | Diagnose | Full | Spooler | Shared | Rpc | DriversPorts
        | Fix011B | Fix0709 | Fix0BC4 | Restore | Report

 ESCOPO E SEGURANCA
 Diagnose, Full, Shared, Rpc, DriversPorts e Report sao ESTRITAMENTE somente
 leitura: nenhuma consulta para servico, grava registro, remove driver, apaga
 fila ou altera politica.

 Spooler, Fix011B, Fix0709, Fix0BC4 e Restore ALTERAM o sistema e seguem sempre
 a mesma cadeia, sem excecao:
     diagnostico -> causa provavel -> bloco de risco -> confirmacao do operador
     -> backup do valor anterior -> aplicacao -> RELEITURA do estado real
     -> resultado.
 "O comando terminou" nunca e tratado como "o problema foi corrigido".

 O modulo NAO remove impressoras, NAO remove drivers, NAO executa reset de rede,
 NAO habilita autenticacao de convidado no SMB e NAO desativa nenhum componente
 de seguranca do Windows por conta propria. As duas correcoes que reduzem uma
 mitigacao (Fix011B e Fix0BC4) sao classificadas como risco ALTO, exibem a
 alternativa recomendada ANTES da propria correcao, exigem confirmacao explicita
 e ficam registradas para reversao pela acao Restore.

 Compativel com Windows 10 / Windows 11, Windows PowerShell 5.1 e
 PowerShell 7.x. Somente componentes nativos do Windows: sem PSGallery, sem
 binario de terceiros. Onde um cmdlet do modulo PrintManagement ou NetTCPIP nao
 existe, o modulo cai para WMI/CIM e para sockets do proprio .NET.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Diagnose', 'Full', 'Spooler', 'Shared', 'Rpc', 'DriversPorts',
                 'Fix011B', 'Fix0709', 'Fix0BC4', 'Restore', 'Report')]
    [string]$Action = 'Menu',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

# ==============================================================================
# CONSTANTES
#
# Caminhos e nomes ficam em UM lugar so: as rotinas de leitura, as de correcao e
# as de reversao precisam falar do MESMO valor, e um caminho digitado duas vezes
# e a forma classica de o backup apontar para uma chave e a gravacao para outra.
# ==============================================================================
$PRN = @{
    PolPrinters   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers'
    PolPointPrint = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
    CtrlPrint     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print'
    UserWindows   = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows'
    Lanman        = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
    FilaSpool     = (Join-Path $env:SystemRoot 'System32\spool\PRINTERS')
    Servico       = 'Spooler'
}

# ==============================================================================
# CATALOGO DE CENARIOS
#
# Estrutura de dados, nao codigo: acrescentar um erro conhecido e acrescentar uma
# linha aqui, sem tocar no motor de diagnostico. O campo Regra e o nome de uma
# funcao Regra* avaliada contra o retrato ja coletado - nenhuma regra
# consulta o sistema por conta propria, para que o diagnostico continue sendo uma
# unica leitura do estado.
# ==============================================================================
$PRN_CENARIOS = @(
    [pscustomobject]@{ Codigo = '0x0000011B'; Titulo = 'Falha ao conectar a impressora compartilhada (RPC negado pelo servidor)';
        Regra = 'Regra011B'; Correcao = 'Fix011B'; Risco = 'ALTO' }
    [pscustomobject]@{ Codigo = '0x00000709'; Titulo = 'Nao foi possivel definir a impressora padrao';
        Regra = 'Regra0709'; Correcao = 'Fix0709'; Risco = 'BAIXO' }
    [pscustomobject]@{ Codigo = '0x00000BC4'; Titulo = 'Nenhuma impressora encontrada / instalacao de driver bloqueada';
        Regra = 'Regra0BC4'; Correcao = 'Fix0BC4'; Risco = 'ALTO' }
    [pscustomobject]@{ Codigo = '0x80070035'; Titulo = 'Caminho de rede nao encontrado (servidor ou SMB inacessivel)';
        Regra = 'Regra80070035'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = '0x80070005'; Titulo = 'Acesso negado ao compartilhamento de impressao';
        Regra = 'Regra80070005'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = '0x00000002'; Titulo = 'Arquivo de driver nao encontrado';
        Regra = 'RegraDriverAusente'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = '0x00000040'; Titulo = 'Sessao com o servidor encerrada durante a impressao';
        Regra = 'Regra00000040'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = '0x00000057'; Titulo = 'Parametro incorreto (porta ou driver incompativel com a impressora)';
        Regra = 'RegraPortaInvalida'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = '0x0000007E'; Titulo = 'Driver do servidor indisponivel para a arquitetura do cliente';
        Regra = 'Regra0000007E'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = '0x0000052E'; Titulo = 'Credenciais recusadas pelo servidor de impressao';
        Regra = 'Regra0000052E'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = 'SPOOLER';    Titulo = 'Servico de spool parado, desabilitado ou reiniciando';
        Regra = 'RegraSpooler'; Correcao = 'Spooler'; Risco = 'BAIXO' }
    [pscustomobject]@{ Codigo = 'FILA';       Titulo = 'Fila de impressao travada com trabalhos retidos';
        Regra = 'RegraFila'; Correcao = 'Spooler'; Risco = 'BAIXO' }
    [pscustomobject]@{ Codigo = 'OFFLINE';    Titulo = 'Impressora marcada como offline ou em estado de erro';
        Regra = 'RegraOffline'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = 'SEM-IMPRESSORA'; Titulo = 'Nenhuma impressora instalada neste perfil';
        Regra = 'RegraSemImpressora'; Correcao = ''; Risco = 'n/a' }
    [pscustomobject]@{ Codigo = 'OUTROS';     Titulo = 'Codigos de erro registrados pelo Windows sem cenario dedicado no catalogo';
        Regra = 'RegraCodigoSemCenario'; Correcao = ''; Risco = 'n/a' }
)

# ==============================================================================
# CAMADA DE LEITURA  (somente leitura, sem excecao)
#
# Todas as sondas devolvem um objeto com o campo Detalhe preenchido quando NAO
# conseguiram medir. Dado ausente, negado ou nao suportado NUNCA e convertido em
# zero, em vazio ou em "saudavel": um servidor que nao respondeu e um servidor
# nao medido, nao um servidor fora do ar.
# ==============================================================================

function Test-PrnTcpPort {
    <# Conexao TCP com tempo limite EFETIVO. Test-NetConnection nao aceita
       timeout e leva dezenas de segundos por alvo indisponivel - com quatro
       portas e varios servidores o diagnostico ficaria inutilizavel.

       Rotina propria, e nao a de Network.ps1: aquelas funcoes vivem dentro do
       modulo de rede e reaproveita-las exigiria executar Network.ps1 inteiro.
       Move-las para Core.ps1 alteraria infraestrutura compartilhada por
       conveniencia deste modulo, o que esta fora do escopo desta alteracao. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Alvo, [Parameter(Mandatory)][int]$Porta, [int]$TimeoutMs = 3000)

    $out = [pscustomobject]@{ Alvo = $Alvo; Porta = $Porta; Ok = $false; Ms = 0; Detalhe = '' }
    $cli  = $null
    $cron = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $cli = New-Object System.Net.Sockets.TcpClient
        $iar = $cli.BeginConnect($Alvo, $Porta, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $out.Detalhe = ('sem resposta em {0} ms' -f $TimeoutMs)
        } else {
            $cli.EndConnect($iar)
            $out.Ok = $true
        }
    } catch {
        $out.Detalhe = $_.Exception.Message
        if ($_.Exception.InnerException) { $out.Detalhe = $_.Exception.InnerException.Message }
    } finally {
        $cron.Stop()
        $out.Ms = [int]$cron.Elapsed.TotalMilliseconds
        if ($cli) { try { $cli.Close() } catch { Write-Log DEBUG "Fechamento de socket: $($_.Exception.Message)" -NoConsole } }
    }
    return $out
}

function Test-PrnDns {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Nome, [int]$TimeoutMs = 3000)

    $out = [pscustomobject]@{ Nome = $Nome; Ok = $false; Enderecos = ''; Detalhe = '' }
    try {
        $task = [System.Net.Dns]::GetHostAddressesAsync($Nome)
        $concluiu = $true
        try { $concluiu = $task.Wait($TimeoutMs) } catch { $concluiu = $true }
        if (-not $concluiu) {
            $out.Detalhe = ('sem resposta em {0} ms' -f $TimeoutMs)
        } elseif ($task.IsFaulted) {
            $out.Detalhe = 'nome nao resolvido'
            try { if ($task.Exception -and $task.Exception.InnerException) { $out.Detalhe = $task.Exception.InnerException.Message } } catch { Write-Log DEBUG 'Detalhe da falha de DNS indisponivel.' -NoConsole }
        } else {
            $addrs = @($task.Result | ForEach-Object { $_.IPAddressToString })
            if ($addrs.Count -gt 0) { $out.Ok = $true; $out.Enderecos = ($addrs -join ', ') }
            else { $out.Detalhe = 'resposta sem enderecos' }
        }
    } catch {
        $out.Detalhe = $_.Exception.Message
    }
    return $out
}

function Test-PrnPing {
    <# ICMP e evidencia AUXILIAR: bloqueio de ICMP e comum em rede corporativa e
       nao prova servidor fora do ar. Por isso este resultado nunca decide
       sozinho - quem decide sao as portas 445 e 135. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Alvo, [int]$TimeoutMs = 1500)

    $out = [pscustomobject]@{ Alvo = $Alvo; Ok = $false; Ms = 0; Detalhe = '' }
    $ping = $null
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $r = $ping.Send($Alvo, $TimeoutMs)
        if ($r -and $r.Status -eq 'Success') {
            $out.Ok = $true
            $out.Ms = [int]$r.RoundtripTime
        } elseif ($r) {
            $out.Detalhe = "$($r.Status)"
        } else {
            $out.Detalhe = 'sem resposta'
        }
    } catch {
        $out.Detalhe = $_.Exception.Message
    } finally {
        if ($ping) { try { $ping.Dispose() } catch { Write-Log DEBUG "Descarte do objeto Ping: $($_.Exception.Message)" -NoConsole } }
    }
    return $out
}

function Get-PrnAmbiente {
    <# Retrato do ambiente antes de qualquer decisao: sem saber a build e o que o
       Windows expoe, o modulo nao pode afirmar que algo "nao existe". #>
    [CmdletBinding()] param()
    $so = $null
    try { $so = Test-WindowsVersion } catch { Write-Log DEBUG "Versao do Windows nao determinada: $($_.Exception.Message)" -NoConsole }
    return [pscustomobject]@{
        Windows       = (Get-CompartDiskOSName)
        Build         = (Get-CompartDiskBuild)
        Arquitetura   = "$($env:PROCESSOR_ARCHITECTURE)"
        Motor         = ('{0} {1}' -f $Global:CompartDisk.Engine, $Global:CompartDisk.PSVersion)
        Administrador = (Test-Administrator)
        PrintMgmt     = (Test-CompartDiskCommand 'Get-Printer')
        DriverCmdlet  = (Test-CompartDiskCommand 'Get-PrinterDriver')
        PortaCmdlet   = (Test-CompartDiskCommand 'Get-PrinterPort')
        Suportado     = [bool]$so
    }
}

function Get-PrnTextoStatus {
    <# Traducao dos codigos do Win32_Printer. Nao inventa estado: o que nao esta
       na tabela sai como o proprio numero, identificado. #>
    param($Status, $Erro, $Offline)
    $s = switch ("$Status") {
        '1'     { 'Outro' }
        '2'     { 'Desconhecido' }
        '3'     { 'Ocioso' }
        '4'     { 'Imprimindo' }
        '5'     { 'Aquecendo' }
        '6'     { 'Impressao parada' }
        '7'     { 'Offline' }
        default { if ("$Status" -eq '') { 'n/d' } else { "codigo $Status" } }
    }
    if ($Offline -eq $true -and $s -ne 'Offline') { $s = "$s (marcada offline)" }
    $e = switch ("$Erro") {
        '3'     { 'pouco papel' }
        '4'     { 'sem papel' }
        '5'     { 'pouco toner' }
        '6'     { 'sem toner' }
        '7'     { 'tampa aberta' }
        '8'     { 'papel preso' }
        '9'     { 'offline' }
        '10'    { 'requer servico' }
        '11'    { 'bandeja de saida cheia' }
        default { '' }
    }
    if ($e) { $s = "$s - $e" }
    return $s
}

function Get-PrnImpressoras {
    <# Inventario com o TIPO DE CONEXAO resolvido. O tipo define todo o resto do
       diagnostico: uma impressora local nao depende de SMB nem de RPC, e correr
       essas verificacoes contra ela so produziria ruido.

       Servidor e compartilhamento saem do proprio caminho UNC; nao ha suposicao
       a partir do nome amigavel. #>
    [CmdletBinding()] param()

    # REPRODUZIDO em harness: "@($null)" NAO e uma colecao vazia - e uma colecao
    # de UM elemento nulo. Get-CompartDiskCim devolve $null quando a consulta nao
    # responde, entao a guarda "$null -eq $imp" aplicada DEPOIS do "@()" nunca
    # disparava, o laco abaixo rodava uma vez sobre um elemento nulo e o modulo
    # fabricava uma impressora de campos em branco. Numa maquina com o
    # repositorio WMI mudo - exatamente um dos defeitos que esta ferramenta
    # existe para diagnosticar - a analise concluia "1 impressora(s) instalada(s)"
    # e nenhuma regra se aplicava: consulta falha virava retrato saudavel.
    #
    # O teste tem de ser feito ANTES de embrulhar. E, como nos demais coletores
    # deste modulo, $null passou a significar "nao consultado" - diferente de
    # "consultado, nenhuma impressora".
    # -ThrowOnError e obrigatorio aqui, e nao um detalhe: SEM ele
    # Get-CompartDiskCim devolve $null tanto para "a consulta falhou" quanto para
    # "a consulta respondeu e nao ha nenhuma impressora", e os dois estados sao
    # informacao diferente. Com -ThrowOnError a falha das TRES vias (CIM, WMI,
    # CIM/DCOM) lanca, e o retorno vazio continua sendo apenas vazio.
    $bruto = $null
    try {
        $bruto = Get-CompartDiskCim -Class Win32_Printer -ThrowOnError
    } catch {
        Write-Log WARN ('Consulta Win32_Printer nao respondeu: a lista de impressoras NAO foi obtida ({0}).' -f $_.Exception.Message)
        return $null
    }
    $rows = New-Object System.Collections.ArrayList
    $imp  = @()
    if ($null -ne $bruto) { $imp = @($bruto) }

    foreach ($p in $imp) {
        $nome  = "$($p.Name)"
        $porta = "$($p.PortName)"

        # O caminho UNC pode estar no nome, na porta ou em ambos, conforme a
        # forma como a conexao foi criada. Vale o primeiro que for realmente UNC.
        $unc = ''
        if ($nome -match '^\\\\[^\\]+\\.+') { $unc = $nome }
        elseif ($porta -match '^\\\\[^\\]+\\.+') { $unc = $porta }

        $servidor = ''
        $share    = ''
        if ($unc) {
            $partes = $unc.TrimStart('\') -split '\\', 2
            $servidor = $partes[0]
            if ($partes.Count -gt 1) { $share = $partes[1] }
        }

        $tipo = 'Local'
        if ($unc) { $tipo = 'Compartilhada (UNC)' }
        elseif ($porta -match '^(IP_|WSD-)') { $tipo = 'Rede (TCP/IP)' }
        elseif ($porta -match '^\d+\.\d+\.\d+\.\d+') { $tipo = 'Rede (TCP/IP)' }
        elseif ($p.Network -eq $true) { $tipo = 'Rede' }
        elseif ($porta -match '^(USB|DOT4|LPT|COM)') { $tipo = 'Local (fisica)' }

        [void]$rows.Add([pscustomobject]@{
            Impressora  = $nome
            Tipo        = $tipo
            Porta       = $porta
            Driver      = "$($p.DriverName)"
            Padrao      = [bool]$p.Default
            Compartilha = [bool]$p.Shared
            Estado      = (Get-PrnTextoStatus -Status $p.PrinterStatus -Erro $p.DetectedErrorState -Offline $p.WorkOffline)
            Servidor    = $servidor
            Share       = $share
        })
    }
    # A virgula impede o desdobramento: uma funcao que devolve @() vazio nao
    # devolve "colecao vazia", devolve NADA, e a propriedade do chamador vira
    # $null - o mesmo valor que este modulo usa para dizer "nao consultado".
    return ,@($rows)
}

function Get-PrnFila {
    <# Trabalhos retidos. Devolve $null quando a consulta NAO respondeu: fila nao
       consultada e fila vazia sao estados diferentes e nao podem virar o mesmo
       numero zero. #>
    [CmdletBinding()] param()
    # Mesma armadilha e mesma solucao de Get-PrnImpressoras: -ThrowOnError separa
    # "consulta falhou" de "fila vazia", e o "@()" so entra depois disso.
    $bruto = $null
    try {
        $bruto = Get-CompartDiskCim -Class Win32_PrintJob -ThrowOnError
    } catch {
        Write-Log DEBUG ("Consulta Win32_PrintJob nao respondeu: {0}" -f $_.Exception.Message) -NoConsole
        return $null
    }
    $jobs = @()
    if ($null -ne $bruto) { $jobs = @($bruto) }

    $rows = New-Object System.Collections.ArrayList
    foreach ($j in $jobs) {
        [void]$rows.Add([pscustomobject]@{
            Impressora = ("$($j.Name)" -split ',')[0]
            Documento  = "$($j.Document)"
            Dono       = "$($j.Owner)"
            Status     = "$($j.JobStatus)"
            Paginas    = $j.TotalPages
            Enviado    = "$($j.TimeSubmitted)"
        })
    }
    return ,@($rows)
}

function Get-PrnSpooler {
    <# Estado real do servico e das suas dependencias. O Spooler depende de RPCSS:
       diagnosticar o Spooler sem olhar o RPC local produz a conclusao errada
       ("o servico nao inicia") para uma causa que esta um nivel abaixo. #>
    [CmdletBinding()] param()

    $out = [pscustomobject]@{
        Servico       = $PRN.Servico
        Existe        = $false
        Status        = 'n/d'
        Inicializacao = 'n/d'
        Dependencias  = ''
        FilaPasta     = $PRN.FilaSpool
        FilaArquivos  = 'n/d'
        Detalhe       = ''
    }
    try {
        $svc = Get-Service -Name $PRN.Servico -ErrorAction Stop
        $out.Existe = $true
        $out.Status = "$($svc.Status)"
        $deps = @()
        foreach ($d in @($svc.ServicesDependedOn)) { $deps += ('{0}={1}' -f $d.Name, $d.Status) }
        $out.Dependencias = ($deps -join '; ')
    } catch {
        $out.Detalhe = $_.Exception.Message
        return $out
    }

    # StartType so existe no objeto de servico a partir do PowerShell 6. Em 5.1 o
    # dado vem do WMI - nao do palpite de que "servico em execucao esta automatico".
    try {
        $w = Get-CompartDiskCim -Class Win32_Service -Filter ("Name='{0}'" -f $PRN.Servico)
        if ($w) { $out.Inicializacao = "$($w.StartMode)" }
    } catch { Write-Log DEBUG "Modo de inicializacao do Spooler nao lido: $($_.Exception.Message)" -NoConsole }

    try {
        if (Test-Path -LiteralPath $PRN.FilaSpool) {
            $out.FilaArquivos = @(Get-ChildItem -LiteralPath $PRN.FilaSpool -File -ErrorAction Stop).Count
        } else {
            $out.FilaArquivos = 'pasta ausente'
        }
    } catch {
        # Acesso negado sem elevacao e o caso NORMAL aqui: fica declarado como
        # nao medido, jamais como fila vazia.
        $out.FilaArquivos = 'nao legivel (acesso negado ou pasta protegida)'
    }
    return $out
}

function Get-PrnDrivers {
    <# Drivers de impressao instalados. Prefere o cmdlet do PrintManagement, que
       traz a arquitetura; cai para Win32_PrinterDriver onde ele nao existe. #>
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList

    if (Test-CompartDiskCommand 'Get-PrinterDriver') {
        try {
            foreach ($d in @(Get-PrinterDriver -ErrorAction Stop)) {
                [void]$rows.Add([pscustomobject]@{
                    Driver      = "$($d.Name)"
                    Fabricante  = "$($d.Manufacturer)"
                    Versao      = "$($d.DriverVersion)"
                    Arquitetura = "$($d.PrinterEnvironment)"
                    Origem      = 'PrintManagement'
                })
            }
            return ,@($rows)
        } catch {
            Write-Log DEBUG "Get-PrinterDriver falhou: $($_.Exception.Message)" -NoConsole
        }
    }

    # Mesma armadilha e mesma solucao de Get-PrnImpressoras.
    $bruto = $null
    try {
        $bruto = Get-CompartDiskCim -Class Win32_PrinterDriver -ThrowOnError
    } catch {
        Write-Log DEBUG ("Consulta Win32_PrinterDriver nao respondeu: {0}" -f $_.Exception.Message) -NoConsole
        return $null
    }
    $wd = @()
    if ($null -ne $bruto) { $wd = @($bruto) }
    foreach ($d in $wd) {
        # Win32_PrinterDriver.Name vem como "Driver,versao,ambiente".
        $partes = "$($d.Name)" -split ','
        [void]$rows.Add([pscustomobject]@{
            Driver      = $partes[0]
            Fabricante  = "$($d.Manufacturer)"
            Versao      = $(if ($partes.Count -gt 1) { $partes[1] } else { 'n/d' })
            Arquitetura = $(if ($partes.Count -gt 2) { $partes[2] } else { 'n/d' })
            Origem      = 'WMI'
        })
    }
    return ,@($rows)
}

function Get-PrnPortas {
    <# Portas de impressao. Get-PrinterPort cobre todos os monitores; o fallback
       WMI enxerga apenas as portas TCP/IP padrao, e isso fica DECLARADO em vez
       de a lista parcial passar por completa. #>
    [CmdletBinding()] param()
    $rows = New-Object System.Collections.ArrayList

    if (Test-CompartDiskCommand 'Get-PrinterPort') {
        try {
            foreach ($p in @(Get-PrinterPort -ErrorAction Stop)) {
                [void]$rows.Add([pscustomobject]@{
                    Porta    = "$($p.Name)"
                    Monitor  = "$($p.PortMonitor)"
                    Host     = "$($p.PrinterHostAddress)"
                    Numero   = "$($p.PortNumber)"
                    Protocolo = "$($p.Protocol)"
                    Origem   = 'PrintManagement'
                })
            }
            return ,@($rows)
        } catch {
            Write-Log DEBUG "Get-PrinterPort falhou: $($_.Exception.Message)" -NoConsole
        }
    }

    # Mesma armadilha e mesma solucao de Get-PrnImpressoras.
    $bruto = $null
    try {
        $bruto = Get-CompartDiskCim -Class Win32_TCPIPPrinterPort -ThrowOnError
    } catch {
        Write-Log DEBUG ("Consulta Win32_TCPIPPrinterPort nao respondeu: {0}" -f $_.Exception.Message) -NoConsole
        return $null
    }
    $wp = @()
    if ($null -ne $bruto) { $wp = @($bruto) }
    foreach ($p in $wp) {
        [void]$rows.Add([pscustomobject]@{
            Porta     = "$($p.Name)"
            Monitor   = 'Standard TCP/IP Port'
            Host      = "$($p.HostAddress)"
            Numero    = "$($p.PortNumber)"
            Protocolo = "$($p.Protocol)"
            Origem    = 'WMI (somente portas TCP/IP)'
        })
    }
    return ,@($rows)
}

function Get-PrnPoliticas {
    <# Leitura das chaves que governam impressao. Nenhuma gravacao aqui.

       '<inexistente>' e um valor de primeira classe: a AUSENCIA da chave e o
       estado padrao do Windows e significa coisa diferente de zero em quase
       todas estas politicas. #>
    [CmdletBinding()] param()

    $ler = {
        param($Caminho, $Nome)
        $v = Get-CompartDiskRegistryValue -Path $Caminho -Name $Nome -Default '<inexistente>'
        return "$v"
    }

    return [pscustomobject]@{
        RpcAuthnLevelPrivacyEnabled       = (& $ler $PRN.PolPrinters   'RpcAuthnLevelPrivacyEnabled')
        RestrictDriverInstallToAdmins     = (& $ler $PRN.PolPointPrint 'RestrictDriverInstallationToAdministrators')
        PointAndPrintRestricted           = (& $ler $PRN.PolPointPrint 'Restricted')
        NoWarningNoElevationOnInstall     = (& $ler $PRN.PolPointPrint 'NoWarningNoElevationOnInstall')
        UpdatePromptSettings              = (& $ler $PRN.PolPointPrint 'UpdatePromptSettings')
        TrustedServers                    = (& $ler $PRN.PolPointPrint 'TrustedServers')
        ServerList                        = (& $ler $PRN.PolPointPrint 'ServerList')
        InForest                          = (& $ler $PRN.PolPointPrint 'InForest')
        RpcUseNamedPipeProtocol           = (& $ler $PRN.CtrlPrint     'RpcUseNamedPipeProtocol')
        RpcProtocols                      = (& $ler $PRN.CtrlPrint     'RpcProtocols')
        ForceKerberosForRpc               = (& $ler $PRN.CtrlPrint     'ForceKerberosForRpc')
        RpcTcpPort                        = (& $ler $PRN.CtrlPrint     'RpcTcpPort')
        LegacyDefaultPrinterMode          = (& $ler $PRN.UserWindows   'LegacyDefaultPrinterMode')
        ImpressoraPadraoUsuario           = (& $ler $PRN.UserWindows   'Device')
        AllowInsecureGuestAuth            = (& $ler $PRN.Lanman        'AllowInsecureGuestAuth')
    }
}

function Get-PrnServidores {
    <# Servidores de impressao distintos referenciados pelas impressoras UNC. #>
    [CmdletBinding()] param([object[]]$Impressoras)
    $nomes = @($Impressoras | Where-Object { $_.Servidor } | ForEach-Object { $_.Servidor } | Sort-Object -Unique)
    return ,@($nomes)
}

function Test-PrnServidor {
    <# Cadeia de conectividade de um servidor de impressao, em CAMADAS. Cada
       camada responde uma pergunta diferente e o resultado nunca colapsa num
       booleano "online":

         DNS  -> o nome existe?
         ICMP -> responde (auxiliar; bloqueio de ICMP nao prova nada)
         445  -> SMB alcancavel (e por onde a conexao a impressora comeca)
         135  -> mapeador de pontos de extremidade RPC alcancavel
         UNC  -> o compartilhamento realmente aparece?

       Distingue explicitamente "servidor inacessivel" de "servidor acessivel e
       compartilhamento indisponivel". #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Servidor)

    $out = [pscustomobject]@{
        Servidor   = $Servidor
        Dns        = 'n/d'
        Enderecos  = ''
        Icmp       = 'n/d'
        Smb445     = 'n/d'
        Rpc135     = 'n/d'
        Compartilhamentos = 'nao consultado'
        Conclusao  = ''
    }

    $alvo = $Servidor
    $dns  = Test-PrnDns -Nome $Servidor
    if ($dns.Ok) {
        $out.Dns = 'resolvido'
        $out.Enderecos = $dns.Enderecos
        $alvo = ($dns.Enderecos -split ',')[0].Trim()
    } else {
        $out.Dns = ('nao resolvido ({0})' -f $dns.Detalhe)
    }

    $p = Test-PrnPing -Alvo $alvo
    $out.Icmp = $(if ($p.Ok) { ('responde ({0} ms)' -f $p.Ms) } else { ('sem resposta ICMP - {0}' -f $p.Detalhe) })

    $t445 = Test-PrnTcpPort -Alvo $alvo -Porta 445
    $out.Smb445 = $(if ($t445.Ok) { ('aberta ({0} ms)' -f $t445.Ms) } else { ('fechada/filtrada - {0}' -f $t445.Detalhe) })

    $t135 = Test-PrnTcpPort -Alvo $alvo -Porta 135
    $out.Rpc135 = $(if ($t135.Ok) { ('aberta ({0} ms)' -f $t135.Ms) } else { ('fechada/filtrada - {0}' -f $t135.Detalhe) })

    # A enumeracao do compartilhamento so faz sentido depois que 445 respondeu.
    # Chamada antes disso, 'net view' apenas espera o proprio tempo limite e
    # devolve um erro que ja sabiamos.
    if ($t445.Ok) {
        try {
            $nv = Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\net.exe') `
                                       -Arguments @('view', ('\\{0}' -f $Servidor)) -TimeoutSeconds 20
            if ($nv.ExitCode -eq 0) {
                $linhas = @("$($nv.StdOut)" -split "`r?`n" | Where-Object { $_ -match '\S' })
                $out.Compartilhamentos = ('enumerado ({0} linha(s) de resposta)' -f $linhas.Count)
            } else {
                $erro = "$($nv.StdErr)".Trim()
                if (-not $erro) { $erro = "$($nv.StdOut)".Trim() }
                if (-not $erro) { $erro = ('codigo {0}' -f $nv.ExitCode) }
                $out.Compartilhamentos = ('recusado - {0}' -f (($erro -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)))
            }
        } catch {
            $out.Compartilhamentos = ('nao consultado - {0}' -f $_.Exception.Message)
        }
    } else {
        $out.Compartilhamentos = 'nao consultado (445 indisponivel)'
    }

    if (-not $dns.Ok -and -not $t445.Ok -and -not $t135.Ok) {
        $out.Conclusao = 'Servidor INACESSIVEL: o nome nao resolve e nenhuma porta responde.'
    } elseif (-not $t445.Ok) {
        $out.Conclusao = 'Servidor alcancavel na rede, porem SMB (445) indisponivel: a conexao a impressora nao chega a ser negociada.'
    } elseif (-not $t135.Ok) {
        $out.Conclusao = 'SMB disponivel e RPC (135) indisponivel: a instalacao encontra o compartilhamento mas falha ao abrir a fila.'
    } elseif ("$($out.Compartilhamentos)" -like 'recusado*') {
        $out.Conclusao = 'Servidor acessivel e COMPARTILHAMENTO indisponivel ou negado a este usuario.'
    } else {
        $out.Conclusao = 'Servidor acessivel: DNS, SMB e RPC responderam.'
    }
    return $out
}

function Get-PrnEventos {
    <# Erros de impressao REALMENTE registrados pelo Windows nos ultimos dias.

       E a unica fonte local que revela o CODIGO do erro que o usuario viu. Sem
       ela, casar um sintoma com "0x0000011B" seria adivinhacao. O log
       PrintService/Admin costuma estar desabilitado - isso e informado como
       'nao disponivel', nunca como 'nenhum erro'. #>
    [CmdletBinding()]
    param([int]$Dias = 7)

    $out = [pscustomobject]@{
        Consultado = $false
        Detalhe    = ''
        Eventos    = @()
        Codigos    = @()
    }
    if (-not (Test-CompartDiskCommand 'Get-WinEvent')) {
        $out.Detalhe = 'Get-WinEvent indisponivel neste sistema.'
        return $out
    }

    $desde = (Get-Date).AddDays(-[math]::Abs($Dias))
    $linhas = New-Object System.Collections.ArrayList
    $codigos = New-Object System.Collections.ArrayList
    $lidos  = 0
    $falhas = New-Object System.Collections.ArrayList

    $fontes = @(
        @{ Log = 'Microsoft-Windows-PrintService/Admin'; Filtro = $null },
        @{ Log = 'System'; Filtro = @('Spooler', 'PrintService', 'Print') }
    )

    foreach ($f in $fontes) {
        try {
            # -MaxEvents limita o custo: no log System, sete dias de eventos de
            # nivel 1-3 podem ser milhares, e a filtragem por origem acontece
            # depois da leitura. O limite e declarado no resumo quando atingido.
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $f.Log; Level = 1, 2, 3; StartTime = $desde } -MaxEvents 500 -ErrorAction Stop)
            $lidos++
            foreach ($e in $ev) {
                $msg = ''
                try { $msg = "$($e.Message)" } catch { $msg = '' }
                if ($f.Filtro) {
                    $bate = $false
                    foreach ($k in $f.Filtro) {
                        if ("$($e.ProviderName)" -like "*$k*" -or $msg -like "*$k*") { $bate = $true; break }
                    }
                    if (-not $bate) { continue }
                }
                $primeira = ($msg -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
                [void]$linhas.Add([pscustomobject]@{
                    Quando   = $e.TimeCreated
                    Log      = $f.Log
                    Id       = $e.Id
                    Origem   = "$($e.ProviderName)"
                    Mensagem = "$primeira"
                })
                foreach ($m in ([regex]::Matches($msg, '0x[0-9A-Fa-f]{8}'))) {
                    $cod = $m.Value.ToLower()
                    if (-not $codigos.Contains($cod)) { [void]$codigos.Add($cod) }
                }
            }
        } catch {
            # 'Nenhum evento correspondente' e resposta valida e nao e falha.
            if ("$($_.Exception.Message)" -match 'No events were found|Nenhum evento') { $lidos++ }
            else { [void]$falhas.Add(('{0}: {1}' -f $f.Log, $_.Exception.Message)) }
        }
    }

    $out.Consultado = ($lidos -gt 0)
    $out.Eventos    = @($linhas | Sort-Object Quando -Descending)
    $out.Codigos    = @($codigos)
    if ($falhas.Count -gt 0) { $out.Detalhe = ($falhas -join ' | ') }
    if (-not $out.Consultado -and -not $out.Detalhe) { $out.Detalhe = 'Nenhum log de impressao pode ser consultado.' }
    return $out
}

function Get-PrnRetrato {
    <# UMA leitura completa do estado. Todas as regras avaliam este mesmo retrato:
       assim o diagnostico e coerente consigo mesmo e nenhuma regra consulta o
       sistema por conta propria no meio da analise.

       -ComRede controla a parte cara: sem impressora UNC nao ha servidor para
       sondar, e sondar assim mesmo so gastaria tempo do operador. #>
    [CmdletBinding()]
    param([switch]$ComRede, [switch]$ComEventos, [int]$Dias = 7)

    $imp = Get-PrnImpressoras
    $retrato = [pscustomobject]@{
        Ambiente    = (Get-PrnAmbiente)
        Impressoras = $imp
        Fila        = (Get-PrnFila)
        Spooler     = (Get-PrnSpooler)
        Drivers     = (Get-PrnDrivers)
        Portas      = (Get-PrnPortas)
        Politicas   = (Get-PrnPoliticas)
        Servidores  = @()
        Eventos     = $null
    }

    if ($ComRede) {
        foreach ($s in (Get-PrnServidores -Impressoras $imp)) {
            Write-Log INFO ("Sondando servidor de impressao '{0}' (DNS, ICMP, 445, 135, compartilhamento)..." -f $s)
            $retrato.Servidores += (Test-PrnServidor -Servidor $s)
        }
    }
    if ($ComEventos) { $retrato.Eventos = (Get-PrnEventos -Dias $Dias) }
    return $retrato
}

# ==============================================================================
# REGRAS
#
# Cada regra recebe o retrato e devolve o mesmo contrato:
#   Aplica    - a condicao foi observada
#   Evidencia - O QUE foi lido que sustenta a conclusao
#   Severidade- CRIT / WARN / INFO
#   Acao      - recomendacao textual
#
# Uma regra JAMAIS afirma "este e o seu erro" a partir de um codigo que nao foi
# observado. Quando o codigo aparece no log de eventos, a regra diz "observado";
# quando apenas as pre-condicoes batem, diz "condicao compativel".
# ==============================================================================

function New-PrnRegraResultado {
    param([bool]$Aplica, [string]$Evidencia, [string]$Severidade = 'WARN', [string]$Acao = '')
    return [pscustomobject]@{ Aplica = $Aplica; Evidencia = $Evidencia; Severidade = $Severidade; Acao = $Acao }
}

function Test-PrnCodigoObservado {
    param($Retrato, [string]$Codigo)
    if (-not $Retrato.Eventos) { return $false }
    if (-not $Retrato.Eventos.Consultado) { return $false }
    return (@($Retrato.Eventos.Codigos) -contains $Codigo.ToLower())
}

function Get-PrnUnc { param($Retrato) return ,@($Retrato.Impressoras | Where-Object { $_.Tipo -eq 'Compartilhada (UNC)' }) }

function Get-PrnSemLista {
    <# Guarda unica das regras que dependem da lista de impressoras.

       Sem ela, com a lista NAO consultada, "nenhuma impressora compartilhada",
       "nenhuma impressora offline" e "nenhuma impressora instalada" continuavam
       sendo escritas - afirmacoes que a consulta nao sustenta. E o mesmo defeito
       dos coletores, um nivel acima: ausencia de dado virando ausencia de
       problema.

       Devolve o resultado pronto para ser retornado quando nao ha lista, e $null
       quando ha - de modo que a regra siga normalmente. #>
    param($Retrato)
    if ($null -ne $Retrato.Impressoras) { return $null }
    return (New-PrnRegraResultado $false 'Nao avaliado: a lista de impressoras nao pode ser consultada nesta execucao.' 'INFO')
}

function Regra011B {
    param($Retrato)
    $semLista = Get-PrnSemLista $Retrato
    if ($semLista) { return $semLista }
    $unc = Get-PrnUnc $Retrato
    if ($unc.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhuma impressora compartilhada (UNC) instalada: o erro 0x0000011B nao se aplica a impressora local ou TCP/IP direta.' 'INFO')
    }
    # A correcao so faz sentido depois que a cadeia de rede esta de pe. Servidor
    # inacessivel produz OUTRO erro, e mexer no registro nesse caso seria trocar
    # uma protecao de seguranca por nada.
    $inacessivel = @($Retrato.Servidores | Where-Object { "$($_.Conclusao)" -like 'Servidor INACESSIVEL*' -or "$($_.Smb445)" -notlike 'aberta*' })
    if ($Retrato.Servidores.Count -gt 0 -and $inacessivel.Count -eq $Retrato.Servidores.Count) {
        return (New-PrnRegraResultado $false ('Servidor(es) de impressao sem SMB disponivel: a causa esta na conectividade, nao na politica RPC. Servidores: {0}' -f (($inacessivel | ForEach-Object { $_.Servidor }) -join ', ')) 'INFO')
    }
    $pol = "$($Retrato.Politicas.RpcAuthnLevelPrivacyEnabled)"
    $observado = Test-PrnCodigoObservado $Retrato '0x0000011b'
    $sev = 'INFO'
    if ($observado) { $sev = 'WARN' }
    $ev = ('{0} impressora(s) compartilhada(s); RpcAuthnLevelPrivacyEnabled = {1}; codigo 0x0000011B no log de eventos: {2}.' -f `
            $unc.Count, $pol, $(if ($observado) { 'OBSERVADO' } else { 'nao observado' }))
    if ($pol -eq '0') {
        return (New-PrnRegraResultado $false ($ev + ' A politica JA esta em 0: a correcao classica do 0x0000011B ja foi aplicada nesta maquina.') 'INFO')
    }
    return (New-PrnRegraResultado $true $ev $sev 'Aplicar a correcao [2] somente apos confirmar que o servidor de impressao esta atualizado.')
}

function Regra0709 {
    param($Retrato)
    $semLista = Get-PrnSemLista $Retrato
    if ($semLista) { return $semLista }
    $padrao = @($Retrato.Impressoras | Where-Object { $_.Padrao })
    $legacy = "$($Retrato.Politicas.LegacyDefaultPrinterMode)"
    $device = "$($Retrato.Politicas.ImpressoraPadraoUsuario)"
    $observado = Test-PrnCodigoObservado $Retrato '0x00000709'

    if ($Retrato.Impressoras.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhuma impressora instalada: nao ha impressora padrao a definir.' 'INFO')
    }

    # "O Windows gerencia a impressora padrao" e o PADRAO DE FABRICA do Windows
    # 10/11 e NAO e defeito. Tratar isso sozinho como hipotese compativel faria a
    # regra disparar em praticamente toda maquina - ruido, nao diagnostico.
    # A hipotese so passa a ser compativel diante de evidencia real:
    #   - o codigo 0x00000709 aparece no log de eventos; ou
    #   - nenhuma impressora esta marcada como padrao; ou
    #   - o valor Device do perfil aponta para uma impressora que nao existe mais.
    $gerenciadoPeloWindows = ($legacy -ne '1')
    $nomeDevice = ''
    if ($device -ne '<inexistente>') { $nomeDevice = ($device -split ',')[0] }
    $deviceOrfao = ($nomeDevice -and (@($Retrato.Impressoras | ForEach-Object { "$($_.Impressora)" }) -notcontains $nomeDevice))

    $ev = ('LegacyDefaultPrinterMode = {0} ({1}); valor Device do perfil = {2}; impressora marcada como padrao: {3}; codigo 0x00000709 no log: {4}.' -f `
            $legacy,
            $(if ($gerenciadoPeloWindows) { 'o Windows gerencia a impressora padrao - configuracao padrao do sistema' } else { 'gestao automatica desligada' }),
            $device,
            $(if ($padrao.Count -gt 0) { $padrao[0].Impressora } else { 'NENHUMA' }),
            $(if ($observado) { 'OBSERVADO' } else { 'nao observado' }))

    if ($observado) {
        return (New-PrnRegraResultado $true ($ev + ' O erro foi realmente registrado pelo Windows.') 'WARN' 'Correcao [3]: desliga a gestao automatica e fixa a impressora padrao escolhida.')
    }
    if ($padrao.Count -eq 0) {
        return (New-PrnRegraResultado $true ($ev + ' Nenhuma impressora esta marcada como padrao.') 'WARN' 'Correcao [3]: fixar a impressora padrao.')
    }
    if ($deviceOrfao) {
        return (New-PrnRegraResultado $true ($ev + (' O perfil aponta para "{0}", que nao consta entre as impressoras instaladas.' -f $nomeDevice)) 'WARN' 'Correcao [3]: fixar uma impressora padrao existente.')
    }
    return (New-PrnRegraResultado $false ($ev + ' Impressora padrao definida e valida, e nenhum 0x00000709 registrado: sem evidencia deste cenario.') 'INFO')
}

function Regra0BC4 {
    param($Retrato)
    $semLista = Get-PrnSemLista $Retrato
    if ($semLista) { return $semLista }
    $unc = Get-PrnUnc $Retrato
    $restrict = "$($Retrato.Politicas.RestrictDriverInstallToAdmins)"
    $observado = Test-PrnCodigoObservado $Retrato '0x00000bc4'
    $admin = [bool]$Retrato.Ambiente.Administrador

    # Ausente conta como 1: apos a atualizacao de agosto de 2021 o Windows trata a
    # chave ausente como restricao ATIVA. Ler '<inexistente>' como 0 inverteria o
    # diagnostico.
    $restritivo = ($restrict -eq '<inexistente>' -or $restrict -eq '1')
    if (-not $restritivo) {
        return (New-PrnRegraResultado $false ('RestrictDriverInstallationToAdministrators = {0}: a instalacao de driver por Point and Print nao esta restrita.' -f $restrict) 'INFO')
    }
    if ($unc.Count -eq 0 -and -not $observado) {
        return (New-PrnRegraResultado $false 'Nenhuma impressora compartilhada instalada e nenhum 0x00000BC4 no log: sem evidencia deste cenario.' 'INFO')
    }
    $ev = ('RestrictDriverInstallationToAdministrators = {0} (restricao ativa); sessao com privilegio administrativo: {1}; impressoras compartilhadas: {2}; codigo 0x00000BC4 no log: {3}.' -f `
            $restrict, $(if ($admin) { 'sim' } else { 'NAO' }), $unc.Count, $(if ($observado) { 'OBSERVADO' } else { 'nao observado' }))
    return (New-PrnRegraResultado $true $ev $(if ($observado) { 'WARN' } else { 'INFO' }) 'Antes da correcao [4]: instalar o driver com uma conta administrativa resolve sem reduzir a mitigacao.')
}

function Regra80070035 {
    param($Retrato)
    $ruins = @($Retrato.Servidores | Where-Object { "$($_.Smb445)" -notlike 'aberta*' })
    if ($ruins.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhum servidor de impressao com SMB (445) indisponivel.' 'INFO')
    }
    $ev = ('SMB (445) indisponivel em: {0}.' -f (($ruins | ForEach-Object { ('{0} [{1}]' -f $_.Servidor, $_.Smb445) }) -join '; '))
    return (New-PrnRegraResultado $true $ev 'CRIT' 'Tratar rede, firewall e disponibilidade do servidor. Nenhuma alteracao local de impressao corrige caminho de rede inacessivel.')
}

function Regra80070005 {
    param($Retrato)
    $neg = @($Retrato.Servidores | Where-Object { "$($_.Compartilhamentos)" -like 'recusado*' })
    if ($neg.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhuma recusa de acesso observada na enumeracao dos compartilhamentos.' 'INFO')
    }
    $ev = ('Compartilhamento recusado em: {0}.' -f (($neg | ForEach-Object { ('{0} [{1}]' -f $_.Servidor, $_.Compartilhamentos) }) -join '; '))
    return (New-PrnRegraResultado $true $ev 'WARN' 'Verificar permissoes de impressao no servidor e as credenciais usadas por este usuario. O modulo NAO altera permissoes nem armazena credenciais.')
}

function RegraDriverAusente {
    param($Retrato)
    if ($null -eq $Retrato.Drivers) {
        return (New-PrnRegraResultado $false 'Lista de drivers nao pode ser consultada: a verificacao nao foi feita.' 'INFO')
    }
    $instalados = @($Retrato.Drivers | ForEach-Object { "$($_.Driver)" })
    $orfas = @($Retrato.Impressoras | Where-Object { $_.Driver -and ($instalados -notcontains "$($_.Driver)") })
    if ($orfas.Count -eq 0) {
        return (New-PrnRegraResultado $false ('Todos os drivers referenciados pelas impressoras constam entre os {0} driver(s) instalado(s).' -f $instalados.Count) 'INFO')
    }
    $ev = ('Impressora(s) apontando para driver nao instalado: {0}.' -f (($orfas | ForEach-Object { ('{0} -> {1}' -f $_.Impressora, $_.Driver) }) -join '; '))
    return (New-PrnRegraResultado $true $ev 'WARN' 'Reinstalar o driver do fabricante para a arquitetura correta. O modulo NAO remove drivers automaticamente.')
}

function Regra00000040 {
    param($Retrato)
    $suspeitos = @($Retrato.Servidores | Where-Object { "$($_.Smb445)" -like 'aberta*' -and "$($_.Icmp)" -like 'sem resposta*' })
    $observado = Test-PrnCodigoObservado $Retrato '0x00000040'
    if ($suspeitos.Count -eq 0 -and -not $observado) {
        return (New-PrnRegraResultado $false 'Nenhuma evidencia de sessao SMB interrompida.' 'INFO')
    }
    $ev = ('Codigo 0x00000040 no log: {0}; servidores com SMB aberto e ICMP instavel: {1}.' -f `
            $(if ($observado) { 'OBSERVADO' } else { 'nao observado' }),
            $(if ($suspeitos.Count -gt 0) { (($suspeitos | ForEach-Object { $_.Servidor }) -join ', ') } else { 'nenhum' }))
    return (New-PrnRegraResultado $true $ev 'WARN' 'Investigar estabilidade do enlace e tempo limite de sessao SMB no servidor. Sem acao local segura.')
}

function RegraPortaInvalida {
    param($Retrato)
    if ($null -eq $Retrato.Portas) {
        return (New-PrnRegraResultado $false 'Lista de portas nao pode ser consultada: a verificacao nao foi feita.' 'INFO')
    }
    $nomes = @($Retrato.Portas | ForEach-Object { "$($_.Porta)" })
    # Impressora UNC nao usa porta local: comparar nesse caso geraria falso positivo.
    $locais = @($Retrato.Impressoras | Where-Object { $_.Tipo -ne 'Compartilhada (UNC)' -and $_.Porta })
    $orfas  = @($locais | Where-Object { $nomes -notcontains "$($_.Porta)" })
    if ($orfas.Count -eq 0) {
        return (New-PrnRegraResultado $false ('Todas as portas usadas por impressoras locais constam entre as {0} porta(s) enumerada(s).' -f $nomes.Count) 'INFO')
    }
    $ev = ('Impressora(s) apontando para porta nao enumerada: {0}.' -f (($orfas | ForEach-Object { ('{0} -> {1}' -f $_.Impressora, $_.Porta) }) -join '; '))
    $obs = ''
    if (@($Retrato.Portas | Where-Object { "$($_.Origem)" -like 'WMI*' }).Count -gt 0) {
        $obs = ' Atencao: a enumeracao caiu para WMI e enxerga apenas portas TCP/IP padrao, entao portas USB/WSD aparecem aqui sem que haja defeito.'
    }
    return (New-PrnRegraResultado $true ($ev + $obs) 'WARN' 'Conferir a porta na propriedade da impressora. O modulo NAO recria portas automaticamente.')
}

function Regra0000007E {
    param($Retrato)
    $semLista = Get-PrnSemLista $Retrato
    if ($semLista) { return $semLista }
    $unc = Get-PrnUnc $Retrato
    $observado = Test-PrnCodigoObservado $Retrato '0x0000007e'
    if ($unc.Count -eq 0 -and -not $observado) {
        return (New-PrnRegraResultado $false 'Sem impressora compartilhada e sem 0x0000007E no log.' 'INFO')
    }
    $ev = ('Arquitetura do cliente: {0}; impressoras compartilhadas: {1}; codigo 0x0000007E no log: {2}.' -f `
            $Retrato.Ambiente.Arquitetura, $unc.Count, $(if ($observado) { 'OBSERVADO' } else { 'nao observado' }))
    return (New-PrnRegraResultado $observado $ev 'WARN' 'O servidor precisa publicar o driver para a arquitetura do cliente, ou a impressora deve ser criada como porta TCP/IP local com driver do fabricante.')
}

function Regra0000052E {
    param($Retrato)
    $observado = Test-PrnCodigoObservado $Retrato '0x0000052e'
    $neg = @($Retrato.Servidores | Where-Object { "$($_.Compartilhamentos)" -like 'recusado*' })
    if (-not $observado -and $neg.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhuma recusa de credencial observada.' 'INFO')
    }
    $ev = ('Codigo 0x0000052E no log: {0}; enumeracao recusada em {1} servidor(es).' -f `
            $(if ($observado) { 'OBSERVADO' } else { 'nao observado' }), $neg.Count)
    return (New-PrnRegraResultado $true $ev 'WARN' 'Credenciais recusadas pelo servidor. O modulo NAO grava, NAO le e NAO altera credenciais: a correcao e no Gerenciador de Credenciais ou na conta de dominio.')
}

function RegraSpooler {
    param($Retrato)
    $sp = $Retrato.Spooler
    if (-not $sp.Existe) {
        return (New-PrnRegraResultado $true ('Servico Spooler nao pode ser consultado: {0}' -f $sp.Detalhe) 'CRIT' 'Sem o servico de spool nao ha impressao. Verificar a integridade do Windows (opcao [5] do menu principal).')
    }
    $parado = ("$($sp.Status)" -ne 'Running')
    $desabilitado = ("$($sp.Inicializacao)" -eq 'Disabled')
    if (-not $parado -and -not $desabilitado) {
        return (New-PrnRegraResultado $false ('Spooler em execucao (inicializacao {0}). Dependencias: {1}' -f $sp.Inicializacao, $sp.Dependencias) 'INFO')
    }
    $ev = ('Spooler: status={0}, inicializacao={1}, dependencias={2}.' -f $sp.Status, $sp.Inicializacao, $sp.Dependencias)
    return (New-PrnRegraResultado $true $ev 'CRIT' 'Correcao [6]: reiniciar o servico e, se estiver Desabilitado, devolver a inicializacao para Automatico.')
}

function RegraFila {
    param($Retrato)
    if ($null -eq $Retrato.Fila) {
        return (New-PrnRegraResultado $false 'Fila de impressao nao pode ser consultada: a verificacao nao foi feita.' 'INFO')
    }
    $travados = @($Retrato.Fila | Where-Object { "$($_.Status)" -match 'Error|Deleting|Paused|Offline|Retained' })
    if ($Retrato.Fila.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhum trabalho na fila de impressao.' 'INFO')
    }
    if ($travados.Count -eq 0) {
        return (New-PrnRegraResultado $false ('{0} trabalho(s) na fila, nenhum em estado de erro.' -f $Retrato.Fila.Count) 'INFO')
    }
    $ev = ('{0} de {1} trabalho(s) em estado problematico: {2}.' -f $travados.Count, $Retrato.Fila.Count, (($travados | ForEach-Object { ('{0}/{1}' -f $_.Impressora, $_.Status) }) -join '; '))
    return (New-PrnRegraResultado $true $ev 'WARN' 'Correcao [6]: limpar a fila. Os trabalhos retidos sao PERDIDOS e precisam ser reenviados.')
}

function RegraOffline {
    param($Retrato)
    $semLista = Get-PrnSemLista $Retrato
    if ($semLista) { return $semLista }
    $off = @($Retrato.Impressoras | Where-Object { "$($_.Estado)" -match 'Offline|offline|papel|toner|tampa|preso|servico' })
    if ($off.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhuma impressora em estado offline ou de erro.' 'INFO')
    }
    $ev = (($off | ForEach-Object { ('{0}: {1}' -f $_.Impressora, $_.Estado) }) -join '; ')
    return (New-PrnRegraResultado $true $ev 'WARN' 'Estado reportado pelo proprio dispositivo. Conferir energia, cabo/rede e suprimentos antes de qualquer alteracao no Windows.')
}

function RegraSemImpressora {
    param($Retrato)
    if ($null -eq $Retrato.Impressoras) {
        return (New-PrnRegraResultado $true 'A lista de impressoras NAO pode ser consultada: o repositorio WMI nao respondeu. Isto nao significa ausencia de impressoras.' 'CRIT' 'Verificar a integridade do repositorio WMI antes de qualquer conclusao sobre impressao. A opcao [5] do menu principal (SFC/DISM) trata a integridade do Windows.')
    }
    if ($Retrato.Impressoras.Count -gt 0) {
        return (New-PrnRegraResultado $false ('{0} impressora(s) instalada(s) neste perfil.' -f $Retrato.Impressoras.Count) 'INFO')
    }
    return (New-PrnRegraResultado $true 'Nenhuma impressora instalada neste perfil de usuario.' 'WARN' 'Instalar por Configuracoes / Impressoras e scanners, ou conectar ao compartilhamento do servidor.')
}

function RegraCodigoSemCenario {
    <# Rede de seguranca do catalogo. Sem ela, um codigo REALMENTE registrado
       pelo Windows que ainda nao tem cenario dedicado sairia do diagnostico em
       silencio - o operador leria "nenhuma hipotese compativel" sobre uma
       maquina que acabou de gravar um erro de impressao no log.

       Acrescentar o cenario ao catalogo faz o codigo migrar daqui para a sua
       propria linha, sem alterar esta funcao. #>
    param($Retrato)
    if (-not $Retrato.Eventos -or -not $Retrato.Eventos.Consultado) {
        return (New-PrnRegraResultado $false 'Log de eventos nao consultado nesta verificacao.' 'INFO')
    }
    $catalogados = @($PRN_CENARIOS | ForEach-Object { "$($_.Codigo)".ToLower() } | Where-Object { $_ -like '0x*' })
    $sobra = @($Retrato.Eventos.Codigos | Where-Object { $catalogados -notcontains $_ })
    if ($sobra.Count -eq 0) {
        return (New-PrnRegraResultado $false 'Nenhum codigo de erro fora do catalogo foi registrado no periodo.' 'INFO')
    }
    $ev = ('Codigo(s) registrado(s) pelo Windows sem cenario dedicado: {0}. O catalogo deste modulo ainda nao classifica a causa provavel destes codigos.' -f ($sobra -join ', '))
    return (New-PrnRegraResultado $true $ev 'WARN' 'Consultar o evento correspondente na lista acima. Nenhuma correcao automatica e oferecida para codigo sem cenario classificado.')
}

function Invoke-PrnAnalise {
    <# Aplica TODAS as regras do catalogo ao retrato e devolve a analise ordenada
       por severidade. Regras que nao se aplicam nao somem: aparecem como
       hipoteses DESCARTADAS, com o motivo. Um diagnostico que so mostra o que
       deu errado esconde metade do trabalho e obriga o operador a repetir as
       mesmas verificacoes na mao. #>
    [CmdletBinding()]
    param($Retrato)

    $peso = @{ 'CRIT' = 0; 'WARN' = 1; 'INFO' = 2 }
    $lin = New-Object System.Collections.ArrayList
    foreach ($c in $PRN_CENARIOS) {
        $r = $null
        try {
            $r = & $c.Regra $Retrato
        } catch {
            $r = New-PrnRegraResultado $false ('Regra nao pode ser avaliada: {0}' -f $_.Exception.Message) 'INFO'
            Write-Log DEBUG ("Falha ao avaliar a regra {0}: {1}" -f $c.Regra, $_.Exception.Message) -NoConsole
        }
        [void]$lin.Add([pscustomobject]@{
            Codigo     = $c.Codigo
            Cenario    = $c.Titulo
            Situacao   = $(if ($r.Aplica) { 'COMPATIVEL' } else { 'DESCARTADO' })
            Severidade = $r.Severidade
            Evidencia  = $r.Evidencia
            Acao       = $r.Acao
            Correcao   = $c.Correcao
            Risco      = $c.Risco
            Aplica     = [bool]$r.Aplica
        })
    }
    return ,@($lin | Sort-Object -Property @{ Expression = { [int](-not $_.Aplica) } }, @{ Expression = { $peso["$($_.Severidade)"] } }, @{ Expression = 'Codigo' })
}

# ==============================================================================
# APRESENTACAO
# ==============================================================================

function Write-PrnRetrato {
    <# Publica o retrato em tela e registra as MESMAS informacoes como secoes, de
       modo que o relatorio consolidado e o state_*.json contenham exatamente o
       que o operador viu. #>
    [CmdletBinding()]
    param($Retrato, [switch]$Completo)

    $a = $Retrato.Ambiente
    Write-CompartDiskTitulo 'AMBIENTE'
    Write-CompartDiskKeyValue 'Windows'        $a.Windows
    Write-CompartDiskKeyValue 'Build'          $a.Build
    Write-CompartDiskKeyValue 'Arquitetura'    $a.Arquitetura
    Write-CompartDiskKeyValue 'Motor'          $a.Motor
    Write-CompartDiskKeyValue 'Administrador'  $(if ($a.Administrador) { 'sim' } else { 'nao (diagnostico segue; correcoes exigem elevacao)' })
    Write-CompartDiskKeyValue 'PrintManagement' $(if ($a.PrintMgmt) { 'disponivel' } else { 'ausente (usando WMI)' })
    Add-CompartDiskSection -Title 'Ambiente de impressao' -Status INFO -Pairs ([ordered]@{
        Windows = $a.Windows; Build = $a.Build; Arquitetura = $a.Arquitetura; Motor = $a.Motor
        Administrador = $a.Administrador; PrintManagement = $a.PrintMgmt
    })

    if ($null -eq $Retrato.Impressoras) {
        Write-CompartDiskTitulo 'IMPRESSORAS'
        Write-CompartDiskTexto 'Nao consultadas: a classe Win32_Printer nao respondeu. Isto NAO significa que nao ha impressoras.'
        Add-CompartDiskSection -Title 'Impressoras' -Status WARN -Summary 'Nao consultadas (Win32_Printer indisponivel)'
    } elseif ($Retrato.Impressoras.Count -gt 0) {
        Write-CompartDiskTitulo ('IMPRESSORAS ({0})' -f $Retrato.Impressoras.Count)
        Write-CompartDiskTable -Rows $Retrato.Impressoras
        Add-CompartDiskSection -Title 'Impressoras' -Status INFO -Rows $Retrato.Impressoras -Summary ('{0} impressora(s)' -f $Retrato.Impressoras.Count)
    } else {
        Write-CompartDiskTitulo 'IMPRESSORAS (0)'
        Write-CompartDiskTexto 'Nenhuma impressora instalada neste perfil.'
        Add-CompartDiskSection -Title 'Impressoras' -Status WARN -Summary 'Nenhuma impressora instalada'
    }

    $sp = $Retrato.Spooler
    Write-CompartDiskTitulo 'SERVICO DE SPOOL'
    Write-CompartDiskKeyValue 'Status'         $sp.Status
    Write-CompartDiskKeyValue 'Inicializacao'  $sp.Inicializacao
    Write-CompartDiskKeyValue 'Dependencias'   $sp.Dependencias
    Write-CompartDiskKeyValue 'Arquivos na fila' $sp.FilaArquivos
    Add-CompartDiskSection -Title 'Servico de spool' -Status $(if ("$($sp.Status)" -eq 'Running') { 'OK' } else { 'WARN' }) -Pairs ([ordered]@{
        Servico = $sp.Servico; Status = $sp.Status; Inicializacao = $sp.Inicializacao
        Dependencias = $sp.Dependencias; Pasta = $sp.FilaPasta; ArquivosNaFila = $sp.FilaArquivos
        Detalhe = $sp.Detalhe
    })

    if ($null -eq $Retrato.Fila) {
        Write-CompartDiskTitulo 'FILA DE IMPRESSAO'
        Write-CompartDiskTexto 'Nao consultada: a classe Win32_PrintJob nao respondeu. Isto NAO significa fila vazia.'
        Add-CompartDiskSection -Title 'Fila de impressao' -Status WARN -Summary 'Nao consultada (Win32_PrintJob indisponivel)'
    } elseif ($Retrato.Fila.Count -gt 0) {
        Write-CompartDiskTitulo ('FILA DE IMPRESSAO ({0} trabalho(s))' -f $Retrato.Fila.Count)
        Write-CompartDiskTable -Rows $Retrato.Fila
        Add-CompartDiskSection -Title 'Fila de impressao' -Status INFO -Rows $Retrato.Fila -Summary ('{0} trabalho(s)' -f $Retrato.Fila.Count)
    } else {
        Add-CompartDiskSection -Title 'Fila de impressao' -Status OK -Summary 'Nenhum trabalho na fila'
    }

    if ($Completo) {
        if ($null -eq $Retrato.Drivers) {
            Write-CompartDiskTitulo 'DRIVERS DE IMPRESSAO'
            Write-CompartDiskTexto 'Nao consultados: nem o cmdlet nem o WMI responderam.'
            Add-CompartDiskSection -Title 'Drivers de impressao' -Status WARN -Summary 'Nao consultados'
        } else {
            Write-CompartDiskTitulo ('DRIVERS DE IMPRESSAO ({0})' -f $Retrato.Drivers.Count)
            Write-CompartDiskTable -Rows $Retrato.Drivers
            Add-CompartDiskSection -Title 'Drivers de impressao' -Status INFO -Rows $Retrato.Drivers -Summary ('{0} driver(s)' -f $Retrato.Drivers.Count)
        }

        if ($null -eq $Retrato.Portas) {
            Write-CompartDiskTitulo 'PORTAS DE IMPRESSAO'
            Write-CompartDiskTexto 'Nao consultadas: nem o cmdlet nem o WMI responderam.'
            Add-CompartDiskSection -Title 'Portas de impressao' -Status WARN -Summary 'Nao consultadas'
        } else {
            Write-CompartDiskTitulo ('PORTAS DE IMPRESSAO ({0})' -f $Retrato.Portas.Count)
            Write-CompartDiskTable -Rows $Retrato.Portas
            Add-CompartDiskSection -Title 'Portas de impressao' -Status INFO -Rows $Retrato.Portas -Summary ('{0} porta(s)' -f $Retrato.Portas.Count)
        }

        $p = $Retrato.Politicas
        Write-CompartDiskTitulo 'POLITICAS E CHAVES DE IMPRESSAO'
        Write-CompartDiskTexto '"<inexistente>" e o estado padrao do Windows e NAO equivale a zero.'
        $pares = [ordered]@{}
        foreach ($prop in $p.PSObject.Properties) { $pares[$prop.Name] = "$($prop.Value)" }
        foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 34 }
        Add-CompartDiskSection -Title 'Politicas de impressao' -Status INFO -Pairs $pares
    }

    if ($Retrato.Servidores.Count -gt 0) {
        Write-CompartDiskTitulo ('SERVIDORES DE IMPRESSAO ({0})' -f $Retrato.Servidores.Count)
        Write-CompartDiskTable -Rows $Retrato.Servidores -Lista
        Add-CompartDiskSection -Title 'Servidores de impressao' -Status INFO -Rows $Retrato.Servidores -Summary ('{0} servidor(es) sondado(s)' -f $Retrato.Servidores.Count)
    }

    if ($Retrato.Eventos) {
        $ev = $Retrato.Eventos
        Write-CompartDiskTitulo 'ERROS DE IMPRESSAO REGISTRADOS PELO WINDOWS'
        if (-not $ev.Consultado) {
            Write-CompartDiskTexto ('Log nao consultado: {0}' -f $ev.Detalhe)
            Add-CompartDiskSection -Title 'Eventos de impressao' -Status WARN -Summary 'Log nao consultado'
        } elseif ($ev.Eventos.Count -eq 0) {
            Write-CompartDiskTexto 'Nenhum erro de impressao registrado no periodo consultado.'
            Add-CompartDiskSection -Title 'Eventos de impressao' -Status OK -Summary 'Nenhum erro no periodo'
        } else {
            Write-CompartDiskTable -Rows @($ev.Eventos) -First 15
            if ($ev.Codigos.Count -gt 0) {
                Write-CompartDiskTexto ('Codigos de erro observados: {0}' -f ($ev.Codigos -join ', '))
            }
            Add-CompartDiskSection -Title 'Eventos de impressao' -Status WARN -Rows @($ev.Eventos) -Summary ('{0} evento(s); codigos: {1}' -f $ev.Eventos.Count, $(if ($ev.Codigos.Count -gt 0) { ($ev.Codigos -join ', ') } else { 'nenhum codigo extraido' }))
        }
    }
}

function Write-PrnAnalise {
    <# Hipoteses compativeis primeiro, descartadas depois - com o motivo do
       descarte, que e informacao de diagnostico e nao ruido. #>
    [CmdletBinding()] param($Analise)

    $compat = @($Analise | Where-Object { $_.Aplica })
    $desc   = @($Analise | Where-Object { -not $_.Aplica })

    # Achados e secoes sao registrados SEMPRE; -Quiet reduz apenas a saida
    # interativa, exatamente como no restante do projeto. Silenciar o registro
    # esvaziaria o relatorio consolidado de quem roda desassistido.
    $mudo = [bool]$Global:CompartDisk.Quiet

    Write-CompartDiskTitulo ('HIPOTESES COMPATIVEIS COM O ESTADO OBSERVADO ({0})' -f $compat.Count)
    if ($compat.Count -eq 0) {
        Write-CompartDiskTexto 'Nenhuma condicao problematica conhecida foi identificada no subsistema de impressao.'
    } else {
        foreach ($h in $compat) {
            if (-not $mudo) {
                $tag = Get-CompartDiskTagStatus $h.Severidade
                $cor = Get-CompartDiskCorStatus $h.Severidade
                Write-Color ''
                Write-Color ('  {0} {1}  {2}' -f $tag, $h.Codigo, $h.Cenario) -Color $cor
                Write-Color ('        Evidencia: {0}' -f $h.Evidencia) -Color Gray
                if ($h.Acao) { Write-Color ('        Acao     : {0}' -f $h.Acao) -Color Gray }
                if ($h.Correcao) { Write-Color ('        Correcao : opcao [{0}] deste menu, risco {1}' -f (Get-PrnTeclaCorrecao $h.Correcao), $h.Risco) -Color Gray }
            }
            Add-CompartDiskFinding -Severity $h.Severidade -Area 'Impressao' -Message ('{0} - {1} | {2}' -f $h.Codigo, $h.Cenario, $h.Evidencia) -Recommendation $h.Acao
        }
    }

    Write-CompartDiskTitulo ('HIPOTESES DESCARTADAS ({0})' -f $desc.Count)
    if (-not $mudo) {
        foreach ($h in $desc) {
            Write-Color ('  [ -- ] {0}  {1}' -f $h.Codigo, $h.Evidencia) -Color DarkGray
        }
    }
    Add-CompartDiskSection -Title 'Analise de causa provavel' -Status $(if ($compat.Count -gt 0) { 'WARN' } else { 'OK' }) `
        -Rows @($Analise | Select-Object Codigo, Situacao, Severidade, Cenario, Evidencia) `
        -Summary ('{0} hipotese(s) compativel(is), {1} descartada(s)' -f $compat.Count, $desc.Count)
}

function Get-PrnTeclaCorrecao {
    param([string]$Correcao)
    switch ($Correcao) {
        'Fix011B' { '2' }
        'Fix0709' { '3' }
        'Fix0BC4' { '4' }
        'Spooler' { '6' }
        default   { '-' }
    }
}

# ==============================================================================
# BACKUP E REVERSAO
#
# Registro proprio, em arquivo unico, com apenas o que ESTE modulo gravou. A
# reversao nunca toca em valor que o modulo nao tenha alterado, nunca restaura
# estado de outra maquina e nunca desfaz configuracao anterior ao modulo.
# ==============================================================================

function Get-PrnArquivoRestauracao {
    <# Fora da pasta da sessao de proposito: uma correcao aplicada hoje precisa
       poder ser revertida na proxima abertura da ferramenta, e OutDir muda a
       cada execucao. LogDir ja foi validado como gravavel pelo Core. #>
    [CmdletBinding()] param()
    $base = $Global:CompartDisk.LogDir
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $Global:CompartDisk.Root }
    $pasta = Join-Path $base 'COMPARTDISK_Relatorios'
    try { if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null } } catch { $pasta = $base }
    return (Join-Path $pasta 'Impressao_Restauracao.json')
}

function Get-PrnValorRegistro {
    <# Valor E tipo. Restaurar sem o tipo original transformaria um REG_SZ em
       REG_DWORD na volta.

       'Legivel' existe por um motivo especifico e nao decorativo: um unico
       try/catch em volta de Get-ItemPropertyValue trata "valor nao existe" e
       "leitura negada" como a MESMA coisa, e as duas viram '<inexistente>'. O
       backup gravaria entao "nao havia valor" para uma chave que existia, e a
       reversao APAGARIA um valor que precisava voltar. Aqui a ausencia so e
       afirmada depois de a chave ter sido aberta e a lista de valores lida; o
       que nao pode ser lido sai com Legivel = $false e aborta a alteracao. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caminho, [Parameter(Mandatory)][string]$Nome)

    $out = [pscustomobject]@{ Existe = $false; Valor = '<inexistente>'; Tipo = 'DWord'; Legivel = $true; Detalhe = '' }
    try {
        if (Test-Path -LiteralPath $Caminho) {
            $item = Get-Item -LiteralPath $Caminho -ErrorAction Stop
            if (@($item.Property) -contains $Nome) {
                $out.Valor  = Get-ItemPropertyValue -LiteralPath $Caminho -Name $Nome -ErrorAction Stop
                $out.Existe = $true
                try { $out.Tipo = "$($item.GetValueKind($Nome))" }
                catch { Write-Log DEBUG ("Tipo de {0}\{1} nao determinado: {2}" -f $Caminho, $Nome, $_.Exception.Message) -NoConsole }
            }
            # Chave aberta e valor ausente da lista: '<inexistente>' e o estado REAL.
        }
        # Chave inexistente: '<inexistente>' tambem e o estado real.
    } catch {
        $out.Legivel = $false
        $out.Detalhe = $_.Exception.Message
        Write-Log WARN ("Nao foi possivel LER {0}\{1}: {2}" -f $Caminho, $Nome, $_.Exception.Message)
    }
    return $out
}

function Get-PrnRestauracoes {
    <# REPRODUZIDO em harness: com "$txt | ConvertFrom-Json" o Windows PowerShell
       5.1 emite o array desserializado como UM UNICO item de pipeline, e "@(...)"
       em volta produz um array CONTENDO o array. A partir da segunda entrada o
       registro de reversao virava uma colecao de um elemento sem as propriedades
       esperadas: Set-PrnRestauracaoAplicada falhava com "a propriedade 'Aplicado'
       nao foi encontrada" e a opcao [10] nao teria o que restaurar.

       -InputObject atribuido a variavel nao passa pelo pipeline, e o "@()"
       seguinte normaliza os dois formatos que ConvertTo-Json produz: objeto
       unico quando ha uma entrada, array quando ha varias.

       Aqui NAO se usa o truque da virgula (",@(...)"), ao contrario dos
       coletores deste modulo: todos os chamadores desta funcao envolvem a
       chamada em "@(...)", e nesse caso a virgula produziria uma colecao de um
       elemento contendo a colecao - o mesmo defeito, por outro caminho. #>
    [CmdletBinding()] param()
    $arq = Get-PrnArquivoRestauracao
    if (-not (Test-Path -LiteralPath $arq)) { return @() }
    try {
        $txt = Get-Content -LiteralPath $arq -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($txt)) { return @() }
        $dados = ConvertFrom-Json -InputObject $txt -ErrorAction Stop
        if ($null -eq $dados) { return @() }
        return @($dados)
    } catch {
        Write-Log WARN ("Registro de reversao ilegivel ({0}): {1}" -f $arq, $_.Exception.Message)
        return @()
    }
}

function Save-PrnRestauracoes {
    [CmdletBinding()] param([object[]]$Itens)
    $arq = Get-PrnArquivoRestauracao
    try {
        @($Itens) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $arq -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        Write-Log ERR ("Nao foi possivel gravar o registro de reversao em {0}." -f $arq) -ErrorRecord $_
        return $false
    }
}

function Add-PrnRestauracao {
    <# Grava a entrada ANTES da alteracao. Uma correcao aplicada sem registro de
       reversao seria uma correcao irreversivel, e a opcao [10] passaria a mentir
       sobre o que consegue desfazer. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Registro', 'Servico')][string]$Tipo,
        [Parameter(Mandatory)][string]$Operacao,
        [Parameter(Mandatory)][string]$Caminho,
        [string]$Nome = '',
        [string]$TipoValor = '',
        [Parameter(Mandatory)][AllowNull()]$ValorAnterior,
        [AllowNull()]$ValorNovo
    )
    $itens = @(Get-PrnRestauracoes)
    $novo = [pscustomobject]@{
        Id            = ([guid]::NewGuid().ToString('N'))
        Timestamp     = (Get-Date -Format 's')
        Sessao        = $Global:CompartDisk.Session
        Computador    = $Global:CompartDisk.Computer
        Usuario       = $Global:CompartDisk.User
        Windows       = (Get-CompartDiskOSName)
        Tipo          = $Tipo
        Operacao      = $Operacao
        Caminho       = $Caminho
        Nome          = $Nome
        TipoValor     = $TipoValor
        ValorAnterior = "$ValorAnterior"
        ValorNovo     = "$ValorNovo"
        Aplicado      = 'pendente'
        Revertido     = $false
        RevertidoEm   = ''
    }
    $itens += $novo
    if (-not (Save-PrnRestauracoes -Itens $itens)) { return $null }
    Write-Log INFO ("Backup registrado: {0}\{1} valor anterior '{2}'." -f $Caminho, $Nome, $novo.ValorAnterior) -NoConsole
    return $novo.Id
}

function Set-PrnRestauracaoAplicada {
    [CmdletBinding()] param([string]$Id, [string]$Estado)
    if (-not $Id) { return }
    $itens = @(Get-PrnRestauracoes)
    foreach ($i in $itens) { if ($i.Id -eq $Id) { $i.Aplicado = $Estado } }
    [void](Save-PrnRestauracoes -Itens $itens)
}

# ==============================================================================
# PRE-CONDICOES E CONFIRMACAO
# ==============================================================================

function Test-PrnPrivilegio {
    [CmdletBinding()] param([string]$Operacao)
    if (Test-Administrator) { return $true }
    Write-Log ERR ('[!] Esta operacao requer privilegios administrativos: {0}' -f $Operacao)
    Write-Log INFO 'Feche esta janela e reabra o Launcher.bat com Executar como administrador.'
    Add-CompartDiskFinding -Severity WARN -Area 'Impressao' -Message ("Operacao '{0}' nao executada: sessao sem privilegio administrativo." -f $Operacao) -Recommendation 'Reabrir o Launcher.bat como Administrador. Nenhuma alteracao foi aplicada.'
    return $false
}

function Confirm-PrnAlteracao {
    <# Bloco de risco obrigatorio antes de QUALQUER alteracao. Sem operador para
       responder, a resposta e NAO: um modulo de impressao nunca deve aplicar
       correcao sozinho dentro de uma execucao desassistida. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Problema,
        [Parameter(Mandatory)][string]$Correcao,
        [Parameter(Mandatory)][string[]]$Alteracoes,
        [Parameter(Mandatory)][ValidateSet('BAIXO', 'MEDIO', 'ALTO')][string]$Risco,
        [string]$Alternativa = '',
        [string[]]$Consequencias = @(),
        [switch]$Quiet
    )

    $cor = switch ($Risco) { 'BAIXO' { 'Green' } 'MEDIO' { 'Yellow' } 'ALTO' { 'Red' } }

    Write-Color ''
    Write-Color '  [!] ALTERACAO NECESSARIA' -Color Yellow
    Write-Color ''
    Write-Color '  Problema identificado:' -Color Gray
    Write-Color ("    {0}" -f $Problema)
    Write-Color ''
    Write-Color '  Correcao proposta:' -Color Gray
    Write-Color ("    {0}" -f $Correcao)
    Write-Color ''
    Write-Color '  Alteracoes que serao feitas:' -Color Gray
    foreach ($a in $Alteracoes) { Write-Color ("    - {0}" -f $a) }
    if ($Consequencias.Count -gt 0) {
        Write-Color ''
        Write-Color '  Consequencias:' -Color Gray
        foreach ($c in $Consequencias) { Write-Color ("    - {0}" -f $c) -Color Yellow }
    }
    if ($Alternativa) {
        Write-Color ''
        Write-Color '  Alternativa recomendada (nao reduz nenhuma protecao):' -Color Gray
        Write-Color ("    {0}" -f $Alternativa) -Color Cyan
    }
    Write-Color ''
    Write-Color ("  Risco: {0}" -f $Risco) -Color $cor
    Write-Color ''
    Write-Color '  Todos os valores anteriores sao gravados e podem ser desfeitos pela opcao [10].' -Color DarkGray
    Write-Color ''

    if (-not (Test-CompartDiskInterativo -Quiet:$Quiet)) {
        Write-Log WARN 'Execucao sem operador: a alteracao NAO foi aplicada. Nenhuma correcao e aplicada automaticamente por este modulo.'
        return $false
    }

    Write-Color '  [1] Confirmar e aplicar' -Color Cyan
    Write-Color '  [0] Cancelar' -Color DarkGray
    Write-Color ''
    $opc = Read-CompartDiskOpcao -Maximo 1
    if ($opc -ne 1) {
        Write-Log INFO 'Operacao cancelada pelo operador. Nenhuma alteracao foi aplicada.'
        return $false
    }
    return $true
}

function Set-PrnRegistroComBackup {
    <# Cadeia completa de UMA gravacao: le o valor atual e o tipo -> registra o
       backup -> grava -> RELE o valor -> devolve o que realmente ficou.
       Set-CompartDiskRegistryValue ja confirma por releitura; aqui a releitura e
       repetida de forma independente porque e ela que decide o texto exibido ao
       operador. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][string]$Nome,
        [Parameter(Mandatory)]$Valor,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')][string]$Tipo = 'DWord',
        [Parameter(Mandatory)][string]$Operacao
    )

    $antes = Get-PrnValorRegistro -Caminho $Caminho -Nome $Nome
    if (-not $antes.Legivel) {
        # Sem leitura confiavel do valor atual nao existe backup, e sem backup a
        # alteracao seria irreversivel. Melhor nao alterar.
        Write-Log ERR ('Alteracao ABORTADA: o valor atual de {0}\{1} nao pode ser lido ({2}). Sem backup confiavel nao ha reversao possivel.' -f $Caminho, $Nome, $antes.Detalhe)
        return [pscustomobject]@{ Ok = $false; Antes = 'nao legivel'; Depois = 'nao alterado'; Detalhe = 'valor atual ilegivel: alteracao nao aplicada' }
    }
    $tipoBackup = $(if ($antes.Existe) { $antes.Tipo } else { $Tipo })
    $id = Add-PrnRestauracao -Tipo 'Registro' -Operacao $Operacao -Caminho $Caminho -Nome $Nome `
                             -TipoValor $tipoBackup -ValorAnterior $antes.Valor -ValorNovo $Valor
    if (-not $id) {
        Write-Log ERR 'Alteracao ABORTADA: sem registro de reversao nao ha como desfazer a mudanca.'
        return [pscustomobject]@{ Ok = $false; Antes = $antes.Valor; Depois = $antes.Valor; Detalhe = 'backup nao gravado' }
    }

    $ok = Set-CompartDiskRegistryValue -Path $Caminho -Name $Nome -Value $Valor -Type $Tipo
    $depois = Get-PrnValorRegistro -Caminho $Caminho -Nome $Nome
    $confirmado = ($ok -and "$($depois.Valor)" -eq "$Valor")
    Set-PrnRestauracaoAplicada -Id $id -Estado $(if ($confirmado) { 'sim' } else { 'nao confirmado' })

    return [pscustomobject]@{
        Ok      = $confirmado
        Antes   = $antes.Valor
        Depois  = $depois.Valor
        Detalhe = $(if ($confirmado) { 'confirmado por releitura' } else { 'a releitura nao devolveu o valor esperado' })
    }
}

function Set-PrnResult {
    <# O resultado do modulo so PIORA: uma correcao bem-sucedida depois de uma
       falha nao apaga a falha. #>
    param([ValidateSet('OK', 'WARN', 'ERROR', 'UNSUPPORTED')][string]$Novo)
    $ordem = @{ 'OK' = 0; 'UNSUPPORTED' = 1; 'WARN' = 2; 'ERROR' = 3 }
    if ($ordem[$Novo] -gt $ordem[$script:result]) { $script:result = $Novo }
}

# ==============================================================================
# DIAGNOSTICOS
# ==============================================================================

function Invoke-PrnDiagnostico {
    <# Diagnostico automatico. A cadeia e CONDICIONAL: a sondagem de servidores
       so acontece quando existe impressora compartilhada, e o log de eventos so
       e lido uma vez. Verificacao desnecessaria nao vira tempo de espera. #>
    [CmdletBinding()] param([switch]$Completo, [switch]$Quiet)

    Write-Log INFO 'Coletando o estado do subsistema de impressao (somente leitura)...'
    $imp = Get-PrnImpressoras
    $temUnc = (@($imp | Where-Object { $_.Tipo -eq 'Compartilhada (UNC)' }).Count -gt 0)
    if (-not $temUnc) {
        Write-Log INFO 'Nenhuma impressora compartilhada: a sondagem de servidor, SMB e RPC nao se aplica e sera omitida.'
    }

    $retrato = Get-PrnRetrato -ComRede:$temUnc -ComEventos
    Write-PrnRetrato -Retrato $retrato -Completo:$Completo
    $analise = Invoke-PrnAnalise -Retrato $retrato
    Write-PrnAnalise -Analise $analise

    $criticos = @($analise | Where-Object { $_.Aplica -and $_.Severidade -eq 'CRIT' })
    $avisos   = @($analise | Where-Object { $_.Aplica -and $_.Severidade -eq 'WARN' })
    if ($criticos.Count -gt 0) { Set-PrnResult 'WARN' }
    elseif ($avisos.Count -gt 0) { Set-PrnResult 'WARN' }

    Write-Log OK 'Diagnostico concluido. Nenhuma alteracao foi aplicada ao sistema.'
    return [pscustomobject]@{ Retrato = $retrato; Analise = $analise }
}

function Invoke-PrnDiagnosticoRede {
    <# Apenas a camada de rede: servidor, SMB e RPC. #>
    [CmdletBinding()] param()
    $imp = Get-PrnImpressoras
    # Sem "@()" em volta: Get-PrnServidores devolve a colecao como UM item, e
    # envolve-la de novo produziria uma colecao de um elemento - Count 1 mesmo
    # sem nenhum servidor, e o desvio abaixo nunca seria tomado.
    $srv = Get-PrnServidores -Impressoras $imp
    if ($srv.Count -eq 0) {
        Write-Log INFO 'Nenhuma impressora compartilhada (UNC) instalada: nao ha servidor de impressao a diagnosticar.'
        Add-CompartDiskSection -Title 'Diagnostico RPC/SMB' -Status INFO -Summary 'Nenhum servidor de impressao referenciado'
        return
    }
    $retrato = Get-PrnRetrato -ComRede
    Write-CompartDiskTitulo ('SERVIDORES DE IMPRESSAO ({0})' -f $retrato.Servidores.Count)
    Write-CompartDiskTable -Rows $retrato.Servidores -Lista
    foreach ($s in $retrato.Servidores) {
        $sev = 'OK'
        if ("$($s.Conclusao)" -notlike 'Servidor acessivel:*') { $sev = 'WARN' }
        if ("$($s.Conclusao)" -like 'Servidor INACESSIVEL*') { $sev = 'CRIT' }
        Add-CompartDiskFinding -Severity $sev -Area 'Impressao/Rede' -Message ('{0}: {1}' -f $s.Servidor, $s.Conclusao) `
            -Recommendation ('DNS={0} | ICMP={1} | 445={2} | 135={3} | compartilhamentos={4}' -f $s.Dns, $s.Icmp, $s.Smb445, $s.Rpc135, $s.Compartilhamentos)
        if ($sev -ne 'OK') { Set-PrnResult 'WARN' }
    }
    Add-CompartDiskSection -Title 'Diagnostico RPC/SMB' -Status INFO -Rows $retrato.Servidores -Summary ('{0} servidor(es) sondado(s)' -f $retrato.Servidores.Count)
    Write-Log OK 'Diagnostico de rede de impressao concluido (somente leitura).'
}

function Invoke-PrnDiagnosticoDriversPortas {
    [CmdletBinding()] param()
    $retrato = Get-PrnRetrato
    $retrato.Servidores = @()
    Write-PrnRetrato -Retrato $retrato -Completo

    foreach ($regra in @('RegraDriverAusente', 'RegraPortaInvalida')) {
        $r = & $regra $retrato
        $sev = $(if ($r.Aplica) { $r.Severidade } else { 'OK' })
        Add-CompartDiskFinding -Severity $sev -Area 'Impressao/Drivers' -Message $r.Evidencia -Recommendation $r.Acao
        if ($r.Aplica) { Set-PrnResult 'WARN' }
    }
    Write-Log OK 'Diagnostico de drivers e portas concluido (somente leitura).'
}

function Invoke-PrnDiagnosticoCompartilhada {
    <# Cadeia especifica da impressora compartilhada, na ordem em que o Windows a
       percorre. Cada etapa reduz o espaco de hipoteses da etapa seguinte. #>
    [CmdletBinding()] param()

    $retrato = Get-PrnRetrato -ComRede -ComEventos
    if ($null -eq $retrato.Impressoras) {
        # Sem a lista, "nenhuma impressora compartilhada" seria uma afirmacao que
        # a consulta nao sustenta.
        Write-Log ERR 'A lista de impressoras nao pode ser consultada: nao ha como afirmar se existe impressora compartilhada nesta maquina.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Impressao' -Message 'Win32_Printer nao respondeu; diagnostico de impressora compartilhada nao realizado.' -Recommendation 'Verificar a integridade do repositorio WMI antes de concluir qualquer coisa sobre impressao.'
        Add-CompartDiskSection -Title 'Impressora compartilhada' -Status WARN -Summary 'Nao verificada (Win32_Printer indisponivel)'
        Set-PrnResult 'ERROR'
        return
    }
    $unc = Get-PrnUnc $retrato
    if ($unc.Count -eq 0) {
        Write-Log INFO 'Nenhuma impressora compartilhada (UNC) instalada neste perfil.'
        Write-CompartDiskTexto 'Para conectar: Configuracoes / Bluetooth e dispositivos / Impressoras e scanners / Adicionar dispositivo, ou executar o caminho UNC do servidor.'
        Add-CompartDiskSection -Title 'Impressora compartilhada' -Status INFO -Summary 'Nenhuma impressora UNC instalada'
        return
    }

    Write-CompartDiskTitulo ('IMPRESSORAS COMPARTILHADAS ({0})' -f $unc.Count)
    Write-CompartDiskTable -Rows $unc
    Write-CompartDiskTitulo 'CADEIA DE VERIFICACAO'
    foreach ($s in $retrato.Servidores) {
        Write-Color ''
        Write-Color ('  Servidor {0}' -f $s.Servidor) -Color White
        Write-CompartDiskKeyValue 'DNS'              $s.Dns
        Write-CompartDiskKeyValue 'Enderecos'        $s.Enderecos
        Write-CompartDiskKeyValue 'ICMP (auxiliar)'  $s.Icmp
        Write-CompartDiskKeyValue 'SMB  TCP 445'     $s.Smb445
        Write-CompartDiskKeyValue 'RPC  TCP 135'     $s.Rpc135
        Write-CompartDiskKeyValue 'Compartilhamentos' $s.Compartilhamentos
        Write-Color ('  -> {0}' -f $s.Conclusao) -Color $(if ("$($s.Conclusao)" -like 'Servidor acessivel:*') { 'Green' } else { 'Yellow' })
    }

    $sp = $retrato.Spooler
    Write-CompartDiskTitulo 'SPOOLER LOCAL'
    Write-CompartDiskKeyValue 'Status' $sp.Status
    Write-CompartDiskKeyValue 'Inicializacao' $sp.Inicializacao

    $analise = Invoke-PrnAnalise -Retrato $retrato
    Write-PrnAnalise -Analise $analise
    Add-CompartDiskSection -Title 'Impressora compartilhada' -Status INFO -Rows $unc -Summary ('{0} impressora(s) UNC em {1} servidor(es)' -f $unc.Count, $retrato.Servidores.Count)
    if (@($analise | Where-Object { $_.Aplica -and $_.Severidade -ne 'INFO' }).Count -gt 0) { Set-PrnResult 'WARN' }
    Write-Log OK 'Diagnostico da impressora compartilhada concluido (somente leitura).'
}

# ==============================================================================
# CORRECOES
# ==============================================================================

function Repair-PrnSpooler {
    <# Nivel 1: reinicio controlado do servico e limpeza autorizada da fila.
       Exige elevacao porque o Windows recusa parar o servico e apagar a fila a
       quem nao e administrador - e sem isso a rotina afirmaria uma limpeza que
       nao aconteceu. #>
    [CmdletBinding()] param([switch]$Quiet)

    $sp = Get-PrnSpooler
    if (-not $sp.Existe) {
        Write-Log ERR ('Servico Spooler nao pode ser consultado: {0}' -f $sp.Detalhe)
        Add-CompartDiskFinding -Severity CRIT -Area 'Impressao' -Message 'Servico de spool ausente ou inacessivel.' -Recommendation 'Verificar a integridade do Windows pela opcao [5] do menu principal (SFC/DISM).'
        Set-PrnResult 'ERROR'
        return
    }

    Write-CompartDiskTitulo 'ESTADO ATUAL DO SPOOLER'
    Write-CompartDiskKeyValue 'Status'           $sp.Status
    Write-CompartDiskKeyValue 'Inicializacao'    $sp.Inicializacao
    Write-CompartDiskKeyValue 'Dependencias'     $sp.Dependencias
    Write-CompartDiskKeyValue 'Arquivos na fila' $sp.FilaArquivos

    # RPCSS abaixo do Spooler: se ele nao esta de pe, reiniciar o Spooler nao
    # resolve e o operador precisa saber disso ANTES de autorizar a limpeza.
    if ("$($sp.Dependencias)" -match 'RpcSs=(\w+)') {
        $estadoRpc = $Matches[1]
        if ($estadoRpc -ne 'Running') {
            Write-Log ERR ('Dependencia RpcSs esta em {0}. Reiniciar o Spooler nao resolve enquanto o RPC local nao estiver em execucao.' -f $estadoRpc)
            Add-CompartDiskFinding -Severity CRIT -Area 'Impressao' -Message ("Servico RPC local (RpcSs) em '{0}'." -f $estadoRpc) -Recommendation 'O RPC local e pre-requisito de quase todo o Windows. Tratar antes de qualquer acao de impressao.'
            Set-PrnResult 'ERROR'
            return
        }
    }

    if (-not (Test-PrnPrivilegio -Operacao 'reiniciar o Spooler e limpar a fila de impressao')) { Set-PrnResult 'WARN'; return }

    $fila = Get-PrnFila
    if ($null -ne $fila -and $fila.Count -gt 0) {
        Write-CompartDiskTitulo ('TRABALHOS QUE SERAO PERDIDOS ({0})' -f $fila.Count)
        Write-CompartDiskTable -Rows $fila
    }

    $alteracoes = @()
    $precisaHabilitar = ("$($sp.Inicializacao)" -eq 'Disabled')
    if ($precisaHabilitar) { $alteracoes += 'Alterar a inicializacao do servico Spooler de Disabled para Automatic' }
    $alteracoes += 'Parar o servico Spooler'
    $alteracoes += ('Remover os arquivos de {0}' -f $sp.FilaPasta)
    $alteracoes += 'Iniciar o servico Spooler'

    $consequencias = @('Os trabalhos ainda na fila sao PERDIDOS e precisam ser reenviados.')
    if (-not (Confirm-PrnAlteracao -Problema ('Spooler em {0} / inicializacao {1} / fila: {2}' -f $sp.Status, $sp.Inicializacao, $sp.FilaArquivos) `
                                   -Correcao 'Reinicio controlado do servico de spool com limpeza da fila de impressao' `
                                   -Alteracoes $alteracoes -Risco 'BAIXO' -Consequencias $consequencias -Quiet:$Quiet)) {
        Set-PrnResult 'WARN'
        return
    }

    if ($precisaHabilitar) {
        $id = Add-PrnRestauracao -Tipo 'Servico' -Operacao 'Inicializacao do Spooler' -Caminho $PRN.Servico -Nome 'StartType' -ValorAnterior $sp.Inicializacao -ValorNovo 'Automatic'
        try {
            Set-Service -Name $PRN.Servico -StartupType Automatic -ErrorAction Stop
            $rel = Get-PrnSpooler
            if ("$($rel.Inicializacao)" -match 'Auto') {
                Write-Log OK ('Inicializacao do Spooler alterada para {0} (confirmado por releitura).' -f $rel.Inicializacao)
                Set-PrnRestauracaoAplicada -Id $id -Estado 'sim'
            } else {
                Write-Log WARN ('A inicializacao do Spooler continua em {0} apos a alteracao.' -f $rel.Inicializacao)
                Set-PrnRestauracaoAplicada -Id $id -Estado 'nao confirmado'
                Set-PrnResult 'WARN'
            }
        } catch {
            Write-Log ERR 'Falha ao alterar a inicializacao do servico Spooler.' -ErrorRecord $_
            Set-PrnRestauracaoAplicada -Id $id -Estado 'falhou'
            Set-PrnResult 'ERROR'
            return
        }
    }

    $parou = @(Set-CompartDiskServiceState -Name @($PRN.Servico) -Action Stop)
    if (-not $parou[0].Success) {
        Write-Log ERR ('O Spooler nao parou ({0}). A fila NAO foi tocada.' -f $parou[0].Detail)
        Add-CompartDiskFinding -Severity WARN -Area 'Impressao' -Message 'Spooler nao pode ser parado; a limpeza da fila foi abortada.' -Recommendation 'Verificar processos que mantem o servico ocupado e repetir. Nenhum arquivo da fila foi removido.'
        Set-PrnResult 'ERROR'
        [void](Set-CompartDiskServiceState -Name @($PRN.Servico) -Action Start)
        return
    }

    $removidos = 0
    $falhas    = 0
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $sp.FilaPasta -File -ErrorAction Stop)) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removidos++ }
            catch { $falhas++; Write-Log DEBUG ("Arquivo da fila nao removido: {0} - {1}" -f $f.Name, $_.Exception.Message) -NoConsole }
        }
    } catch {
        Write-Log WARN ('A pasta da fila nao pode ser lida: {0}' -f $_.Exception.Message)
        $falhas = -1
    }

    [void](Set-CompartDiskServiceState -Name @($PRN.Servico) -Action Start)

    # VALIDACAO: releitura do estado real, nunca o retorno dos comandos acima.
    $depois = Get-PrnSpooler
    Write-CompartDiskTitulo 'VALIDACAO'
    Write-CompartDiskKeyValue 'Status do Spooler'  $depois.Status
    Write-CompartDiskKeyValue 'Inicializacao'      $depois.Inicializacao
    Write-CompartDiskKeyValue 'Arquivos removidos' $(if ($falhas -lt 0) { 'pasta nao legivel' } else { $removidos })
    Write-CompartDiskKeyValue 'Falhas na remocao'  $(if ($falhas -lt 0) { 'n/d' } else { $falhas })
    Write-CompartDiskKeyValue 'Arquivos na fila'   $depois.FilaArquivos

    $ok = ("$($depois.Status)" -eq 'Running')
    Add-CompartDiskSection -Title 'Correcao do Spooler' -Status $(if ($ok) { 'OK' } else { 'WARN' }) -Pairs ([ordered]@{
        StatusAntes = $sp.Status; StatusDepois = $depois.Status
        InicializacaoAntes = $sp.Inicializacao; InicializacaoDepois = $depois.Inicializacao
        ArquivosRemovidos = $removidos; FalhasNaRemocao = $falhas; ArquivosNaFilaDepois = $depois.FilaArquivos
    })

    if ($ok) {
        Write-Log OK 'Servico de spool em execucao apos o reinicio (confirmado por releitura).'
        Add-CompartDiskFinding -Severity OK -Area 'Impressao' -Message ('Spooler reiniciado; {0} arquivo(s) removido(s) da fila.' -f $removidos)
    } else {
        Write-Log ERR ('O Spooler NAO voltou a executar (status {0}). O problema persiste.' -f $depois.Status)
        Add-CompartDiskFinding -Severity CRIT -Area 'Impressao' -Message ('Spooler em {0} apos o reinicio.' -f $depois.Status) -Recommendation 'Nenhuma alteracao adicional sera aplicada automaticamente. Verificar dependencias do servico e integridade do Windows.'
        Set-PrnResult 'ERROR'
    }
}

function Set-PrnImpressoraPadrao {
    <# Define a impressora padrao pelo caminho nativo, com releitura. Nao grava o
       valor Device na mao: quem monta essa string e o Windows, e escreve-la
       diretamente produz uma impressora padrao que o proprio sistema nao
       reconhece. O valor anterior fica registrado para reversao. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Nome)

    $antes = Get-PrnValorRegistro -Caminho $PRN.UserWindows -Nome 'Device'
    if (-not $antes.Legivel) {
        Write-Log ERR ('Alteracao ABORTADA: a impressora padrao atual nao pode ser lida ({0}). Sem backup nao ha reversao.' -f $antes.Detalhe)
        return $false
    }
    $id = Add-PrnRestauracao -Tipo 'Registro' -Operacao 'Impressora padrao do usuario' -Caminho $PRN.UserWindows `
                             -Nome 'Device' -TipoValor 'String' -ValorAnterior $antes.Valor -ValorNovo $Nome
    if (-not $id) { return $false }

    $aplicado = $false
    $inst = $null
    try { $inst = @(Get-CompartDiskCim -Class Win32_Printer) | Where-Object { "$($_.Name)" -eq $Nome } | Select-Object -First 1 } catch { Write-Log DEBUG "Instancia Win32_Printer nao obtida: $($_.Exception.Message)" -NoConsole }
    if ($inst) {
        try {
            if (Test-CompartDiskCommand 'Invoke-CimMethod') {
                $r = Invoke-CimMethod -InputObject $inst -MethodName SetDefaultPrinter -ErrorAction Stop
                $aplicado = ($r.ReturnValue -eq 0)
            }
        } catch { Write-Log DEBUG "Invoke-CimMethod SetDefaultPrinter: $($_.Exception.Message)" -NoConsole }
        if (-not $aplicado) {
            try { $inst.SetDefaultPrinter() | Out-Null; $aplicado = $true }
            catch { Write-Log DEBUG "SetDefaultPrinter direto: $($_.Exception.Message)" -NoConsole }
        }
    }
    if (-not $aplicado) {
        # Ultimo recurso nativo, presente em todas as edicoes suportadas.
        try {
            $r = Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\rundll32.exe') `
                                      -Arguments @('printui.dll,PrintUIEntry', '/y', '/n', ('"{0}"' -f $Nome)) -TimeoutSeconds 30
            $aplicado = ($r.ExitCode -eq 0)
        } catch { Write-Log DEBUG "rundll32 printui: $($_.Exception.Message)" -NoConsole }
    }

    # VALIDACAO por releitura do proprio Windows.
    $atual = @(Get-PrnImpressoras | Where-Object { $_.Padrao }) | Select-Object -First 1
    $confirmado = ($atual -and "$($atual.Impressora)" -eq $Nome)
    Set-PrnRestauracaoAplicada -Id $id -Estado $(if ($confirmado) { 'sim' } else { 'nao confirmado' })

    if ($confirmado) {
        Write-Log OK ("Impressora padrao definida como '{0}' (confirmado por releitura)." -f $Nome)
    } else {
        Write-Log WARN ("A impressora padrao continua em '{0}' apos a alteracao." -f $(if ($atual) { $atual.Impressora } else { 'nenhuma' }))
    }
    return $confirmado
}

function Repair-Prn0709 {
    <# Nivel 2, escopo do USUARIO: nao exige elevacao e nao toca em HKLM. Pedir
       administrador aqui seria elevar sem necessidade. #>
    [CmdletBinding()] param([switch]$Quiet)

    # -ComEventos e obrigatorio aqui: sem o log lido, Test-PrnCodigoObservado
    # devolve sempre falso e o ramo "o erro foi realmente registrado" da Regra0709
    # nunca poderia ser alcancado - a correcao decidiria sem a unica evidencia
    # direta de que o 0x00000709 aconteceu nesta maquina.
    $retrato = Get-PrnRetrato -ComEventos
    $r = Regra0709 $retrato
    Write-CompartDiskTitulo 'DIAGNOSTICO DO CENARIO 0x00000709'
    Write-CompartDiskTexto $r.Evidencia

    if (-not $r.Aplica) {
        # Diferente de Fix011B e Fix0BC4: aqui nada de seguranca e reduzido, a
        # alteracao e do perfil do usuario e a reversao e imediata. Recusar de
        # plano impediria uma preferencia legitima, entao o modulo diz que NAO
        # encontrou o defeito e deixa a decisao com o operador.
        Write-Log INFO 'Nenhuma condicao compativel com 0x00000709 foi observada.'
        Add-CompartDiskFinding -Severity OK -Area 'Impressao' -Message '0x00000709: condicao nao observada.' -Recommendation $r.Evidencia
        if (-not (Test-CompartDiskInterativo -Quiet:$Quiet)) {
            Write-Log INFO 'Execucao sem operador e sem defeito observado: nenhuma alteracao aplicada.'
            return
        }
        Write-Color ''
        Write-Color '  O ajuste continua disponivel como PREFERENCIA (escopo do usuario, risco BAIXO, reversivel pela opcao [10]).' -Color Gray
        Write-Color ''
        Write-Color '  [1] Ajustar mesmo assim' -Color Cyan
        Write-Color '  [0] Voltar' -Color DarkGray
        Write-Color ''
        if ((Read-CompartDiskOpcao -Maximo 1) -ne 1) {
            Write-Log INFO 'Nenhuma alteracao aplicada.'
            return
        }
    }
    if ($null -eq $retrato.Impressoras) {
        Write-Log ERR 'A lista de impressoras nao pode ser consultada: sem ela nao ha como escolher uma impressora padrao com seguranca.'
        Set-PrnResult 'ERROR'
        return
    }
    if ($retrato.Impressoras.Count -eq 0) {
        Write-Log WARN 'Nenhuma impressora instalada: nao ha impressora padrao a definir.'
        Set-PrnResult 'WARN'
        return
    }

    $legacy = "$($retrato.Politicas.LegacyDefaultPrinterMode)"
    if ($legacy -ne '1') {
        $alt = 'Configuracoes / Bluetooth e dispositivos / Impressoras e scanners: desmarcar "Permitir que o Windows gerencie minha impressora padrao".'
        if (Confirm-PrnAlteracao -Problema 'O Windows esta gerenciando a impressora padrao e a substitui pela ultima utilizada, o que produz o erro 0x00000709 ao fixar uma impressora.' `
                                 -Correcao 'Desligar a gestao automatica da impressora padrao para este usuario' `
                                 -Alteracoes @(('{0}\LegacyDefaultPrinterMode = 1 (REG_DWORD)' -f $PRN.UserWindows)) `
                                 -Risco 'BAIXO' -Alternativa $alt -Quiet:$Quiet) {
            $res = Set-PrnRegistroComBackup -Caminho $PRN.UserWindows -Nome 'LegacyDefaultPrinterMode' -Valor 1 -Tipo DWord -Operacao 'Desligar gestao automatica da impressora padrao'
            Write-CompartDiskTitulo 'VALIDACAO'
            Write-CompartDiskKeyValue 'LegacyDefaultPrinterMode antes'  $res.Antes
            Write-CompartDiskKeyValue 'LegacyDefaultPrinterMode depois' $res.Depois
            Write-CompartDiskKeyValue 'Confirmacao'                     $res.Detalhe
            if (-not $res.Ok) { Set-PrnResult 'WARN' }
        } else {
            Set-PrnResult 'WARN'
        }
    } else {
        Write-Log INFO 'A gestao automatica da impressora padrao ja esta desligada (LegacyDefaultPrinterMode=1).'
    }

    if (-not (Test-CompartDiskInterativo -Quiet:$Quiet)) {
        Write-Log INFO 'Execucao sem operador: a escolha da impressora padrao nao foi oferecida.'
        return
    }

    Write-CompartDiskTitulo 'DEFINIR A IMPRESSORA PADRAO'
    $lista = @($retrato.Impressoras)
    for ($i = 0; $i -lt $lista.Count; $i++) {
        $marca = $(if ($lista[$i].Padrao) { ' (padrao atual)' } else { '' })
        Write-Color ('  [{0}] {1}{2}' -f ($i + 1), $lista[$i].Impressora, $marca) -Color Cyan
    }
    Write-Color '  [0] Nao alterar a impressora padrao' -Color DarkGray
    Write-Color ''
    $opc = Read-CompartDiskOpcao -Maximo $lista.Count
    if ($opc -eq 0) {
        Write-Log INFO 'Impressora padrao nao alterada por escolha do operador.'
        return
    }
    $alvo = $lista[$opc - 1].Impressora
    if (-not (Set-PrnImpressoraPadrao -Nome $alvo)) { Set-PrnResult 'WARN' }

    $final = @(Get-PrnImpressoras | Where-Object { $_.Padrao }) | Select-Object -First 1
    Add-CompartDiskSection -Title 'Correcao 0x00000709' -Status $(if ($final -and "$($final.Impressora)" -eq $alvo) { 'OK' } else { 'WARN' }) -Pairs ([ordered]@{
        LegacyDefaultPrinterMode = (Get-CompartDiskRegistryValue -Path $PRN.UserWindows -Name 'LegacyDefaultPrinterMode' -Default '<inexistente>')
        ImpressoraSolicitada     = $alvo
        ImpressoraPadraoAtual    = $(if ($final) { $final.Impressora } else { 'nenhuma' })
    })
}

function Repair-PrnPoliticaSeguranca {
    <# Nucleo comum de Fix011B e Fix0BC4. As duas reduzem uma MITIGACAO de
       seguranca do Windows e por isso compartilham exatamente o mesmo rito:
       diagnostico -> recusa quando a causa provavel esta em outro lugar ->
       alternativa que NAO reduz protecao, exibida antes -> risco ALTO ->
       confirmacao -> backup -> gravacao -> releitura -> validacao explicita do
       que NAO foi provado. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Codigo,
        [Parameter(Mandatory)][string]$Regra,
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][string]$Nome,
        [Parameter(Mandatory)][string]$Problema,
        [Parameter(Mandatory)][string]$Correcao,
        [Parameter(Mandatory)][string]$Alternativa,
        [Parameter(Mandatory)][string[]]$Consequencias,
        [switch]$Quiet
    )

    $retrato = Get-PrnRetrato -ComRede -ComEventos
    $r = & $Regra $retrato
    Write-CompartDiskTitulo ('DIAGNOSTICO DO CENARIO {0}' -f $Codigo)
    Write-CompartDiskTexto $r.Evidencia

    if (-not $r.Aplica) {
        Write-Log WARN ('A condicao de {0} NAO foi observada. Nenhuma alteracao de seguranca sera aplicada.' -f $Codigo)
        Write-CompartDiskTexto 'Reduzir uma protecao do Windows sem que a causa correspondente esteja presente troca seguranca por nada.'
        Add-CompartDiskFinding -Severity INFO -Area 'Impressao' -Message ('{0}: correcao recusada, condicao nao observada.' -f $Codigo) -Recommendation $r.Evidencia
        # Mostra o que a analise encontrou no lugar, para o operador nao ficar sem rumo.
        Write-PrnAnalise -Analise (Invoke-PrnAnalise -Retrato $retrato)
        return
    }

    if (-not (Test-PrnPrivilegio -Operacao ('alterar a politica de impressao para o cenario {0}' -f $Codigo))) { Set-PrnResult 'WARN'; return }

    if (-not (Confirm-PrnAlteracao -Problema $Problema -Correcao $Correcao `
                                   -Alteracoes @(('{0}\{1} = 0 (REG_DWORD)' -f $Caminho, $Nome)) `
                                   -Risco 'ALTO' -Alternativa $Alternativa -Consequencias $Consequencias -Quiet:$Quiet)) {
        Set-PrnResult 'WARN'
        return
    }

    $res = Set-PrnRegistroComBackup -Caminho $Caminho -Nome $Nome -Valor 0 -Tipo DWord -Operacao ('Correcao ' + $Codigo)

    Write-CompartDiskTitulo 'VALIDACAO'
    Write-CompartDiskKeyValue ('{0} antes' -f $Nome)  $res.Antes
    Write-CompartDiskKeyValue ('{0} depois' -f $Nome) $res.Depois
    Write-CompartDiskKeyValue 'Confirmacao'           $res.Detalhe

    $sp = Get-PrnSpooler
    Write-CompartDiskKeyValue 'Spooler'               $sp.Status
    foreach ($s in $retrato.Servidores) {
        Write-CompartDiskKeyValue ('Servidor {0}' -f $s.Servidor) $s.Conclusao
    }

    if ($res.Ok) {
        Write-Log OK ('Politica gravada e confirmada por releitura ({0} = 0).' -f $Nome)
        Write-CompartDiskTexto 'A alteracao passa a valer em NOVAS conexoes de impressao. Reiniciar o Spooler ou o computador pode ser necessario.'
        Write-CompartDiskTexto 'O que esta validacao NAO prova: que uma pagina sera impressa. Isso so pode ser confirmado por um teste de impressao real.'
        Add-CompartDiskFinding -Severity WARN -Area 'Impressao/Seguranca' -Message ('{0}: {1}\{2} alterado de {3} para 0 (mitigacao reduzida).' -f $Codigo, $Caminho, $Nome, $res.Antes) `
            -Recommendation 'Reverter pela opcao [10] assim que o servidor de impressao estiver atualizado. A alteracao esta registrada para reversao.'
        Set-PrnResult 'WARN'
    } else {
        Write-Log ERR ('A gravacao NAO foi confirmada: {0}. O problema persiste e nenhuma alteracao adicional sera aplicada automaticamente.' -f $res.Detalhe)
        Add-CompartDiskFinding -Severity CRIT -Area 'Impressao' -Message ('{0}: gravacao de {1} nao confirmada por releitura.' -f $Codigo, $Nome) -Recommendation 'Verificar diretiva de grupo, permissoes da chave e redirecionamento de colmeia.'
        Set-PrnResult 'ERROR'
    }
    Add-CompartDiskSection -Title ('Correcao ' + $Codigo) -Status $(if ($res.Ok) { 'WARN' } else { 'CRIT' }) -Pairs ([ordered]@{
        Chave = ('{0}\{1}' -f $Caminho, $Nome); ValorAntes = $res.Antes; ValorDepois = $res.Depois
        Confirmacao = $res.Detalhe; SpoolerAposCorrecao = $sp.Status
    })
}

function Repair-Prn011B {
    [CmdletBinding()] param([switch]$Quiet)
    Repair-PrnPoliticaSeguranca -Codigo '0x0000011B' -Regra 'Regra011B' `
        -Caminho $PRN.PolPrinters -Nome 'RpcAuthnLevelPrivacyEnabled' `
        -Problema 'O servidor de impressao exige um nivel de autenticacao RPC que este cliente nao consegue negociar, e a conexao a impressora compartilhada falha com 0x0000011B.' `
        -Correcao 'Desligar a exigencia de privacidade na autenticacao RPC de impressao neste cliente (RpcAuthnLevelPrivacyEnabled = 0).' `
        -Alternativa 'Atualizar o SERVIDOR de impressao com as atualizacoes cumulativas do Windows. Essa e a correcao oficial e nao reduz protecao nenhuma no cliente.' `
        -Consequencias @(
            'Reduz uma mitigacao do cliente contra falsificacao no spooler de impressao (CVE-2021-1678).',
            'A alteracao vale para TODAS as impressoras compartilhadas desta maquina, nao apenas para a que apresentou o erro.'
        ) -Quiet:$Quiet
}

function Repair-Prn0BC4 {
    [CmdletBinding()] param([switch]$Quiet)
    Repair-PrnPoliticaSeguranca -Codigo '0x00000BC4' -Regra 'Regra0BC4' `
        -Caminho $PRN.PolPointPrint -Nome 'RestrictDriverInstallationToAdministrators' `
        -Problema 'A instalacao do driver vindo do servidor de impressao esta restrita a administradores, e a conexao termina em 0x00000BC4 / "nenhuma impressora encontrada".' `
        -Correcao 'Permitir que usuarios sem privilegio instalem driver por Point and Print (RestrictDriverInstallationToAdministrators = 0).' `
        -Alternativa 'Instalar a impressora UMA vez com uma conta administrativa, ou publicar o driver por diretiva. O usuario passa a conectar sem que a restricao precise ser removida.' `
        -Consequencias @(
            'Reduz a mitigacao do PrintNightmare (CVE-2021-34527): qualquer servidor de impressao alcancavel passa a poder entregar driver a este computador.',
            'A restricao ausente no registro tem o MESMO efeito de 1: gravar 0 e uma mudanca real de postura, nao a volta ao padrao.'
        ) -Quiet:$Quiet
}

# ==============================================================================
# REVERSAO
# ==============================================================================

function Invoke-PrnReversao {
    <# Desfaz SOMENTE o que este modulo gravou, nesta maquina, e que ainda nao
       foi revertido. Nunca toca em valor de origem desconhecida, nunca restaura
       estado anterior ao modulo e nunca aceita registro de outro computador. #>
    [CmdletBinding()] param([switch]$Quiet)

    $todos = @(Get-PrnRestauracoes)
    # Ordem DECRESCENTE de tempo: quando o mesmo alvo foi alterado mais de uma
    # vez, o valor mais ANTIGO e escrito por ultimo e prevalece. Restaurar na
    # ordem cronologica deixaria o penultimo valor no lugar do original.
    $meus  = @($todos |
        Where-Object { "$($_.Computador)" -eq "$($Global:CompartDisk.Computer)" -and -not $_.Revertido -and "$($_.Aplicado)" -ne 'falhou' } |
        Sort-Object -Property Timestamp -Descending)

    Write-CompartDiskTitulo 'ALTERACOES REGISTRADAS POR ESTE MODULO'
    Write-CompartDiskKeyValue 'Arquivo de registro' (Get-PrnArquivoRestauracao)
    Write-CompartDiskKeyValue 'Total registrado'    $todos.Count
    Write-CompartDiskKeyValue 'Pendente de reversao nesta maquina' $meus.Count

    if ($meus.Count -eq 0) {
        Write-Log INFO 'Nenhuma alteracao deste modulo pendente de reversao nesta maquina.'
        Add-CompartDiskSection -Title 'Reversao de alteracoes' -Status OK -Summary 'Nada a reverter'
        return
    }

    Write-CompartDiskTable -Rows @($meus | Select-Object Timestamp, Operacao, Tipo, Caminho, Nome, ValorAnterior, ValorNovo, Aplicado)

    $precisaAdmin = @($meus | Where-Object { "$($_.Caminho)" -like 'HKLM:*' -or "$($_.Tipo)" -eq 'Servico' })
    if ($precisaAdmin.Count -gt 0 -and -not (Test-PrnPrivilegio -Operacao 'reverter alteracoes em HKLM ou em servico')) {
        Set-PrnResult 'WARN'
        return
    }

    if (-not (Confirm-PrnAlteracao -Problema ('{0} alteracao(oes) aplicada(s) por este modulo continuam em vigor.' -f $meus.Count) `
                                   -Correcao 'Restaurar cada valor exatamente como estava antes da correcao' `
                                   -Alteracoes @($meus | ForEach-Object { ('{0}\{1}: {2} -> {3}' -f $_.Caminho, $_.Nome, $_.ValorNovo, $_.ValorAnterior) }) `
                                   -Risco 'MEDIO' `
                                   -Consequencias @('O comportamento anterior a correcao volta, incluindo o erro que motivou a alteracao.') -Quiet:$Quiet)) {
        Set-PrnResult 'WARN'
        return
    }

    $resultados = New-Object System.Collections.ArrayList
    foreach ($it in $meus) {
        $linha = [pscustomobject]@{ Operacao = $it.Operacao; Alvo = ('{0}\{1}' -f $it.Caminho, $it.Nome); Resultado = ''; Detalhe = '' }
        try {
            if ("$($it.Tipo)" -eq 'Servico') {
                $modo = switch ("$($it.ValorAnterior)") {
                    'Auto'     { 'Automatic' }
                    'Automatic'{ 'Automatic' }
                    'Manual'   { 'Manual' }
                    'Disabled' { 'Disabled' }
                    default    { '' }
                }
                if (-not $modo) { throw ("Modo de inicializacao anterior desconhecido: '{0}'" -f $it.ValorAnterior) }
                Set-Service -Name $it.Caminho -StartupType $modo -ErrorAction Stop
                $rel = Get-PrnSpooler
                if ("$($rel.Inicializacao)" -eq "$($it.ValorAnterior)" -or ("$($rel.Inicializacao)" -match 'Auto' -and $modo -eq 'Automatic')) {
                    $linha.Resultado = 'revertido'; $linha.Detalhe = ('inicializacao = {0} (confirmado)' -f $rel.Inicializacao)
                } else {
                    $linha.Resultado = 'nao confirmado'; $linha.Detalhe = ('inicializacao = {0}' -f $rel.Inicializacao)
                }
            } elseif ("$($it.ValorAnterior)" -eq '<inexistente>') {
                Remove-ItemProperty -LiteralPath $it.Caminho -Name $it.Nome -Force -ErrorAction Stop
                $conf = Get-PrnValorRegistro -Caminho $it.Caminho -Nome $it.Nome
                if (-not $conf.Existe) { $linha.Resultado = 'revertido'; $linha.Detalhe = 'valor removido (confirmado)' }
                else { $linha.Resultado = 'nao confirmado'; $linha.Detalhe = ('valor ainda presente: {0}' -f $conf.Valor) }
            } else {
                $tipo = "$($it.TipoValor)"
                if ([string]::IsNullOrWhiteSpace($tipo)) { $tipo = 'DWord' }
                $valor = $it.ValorAnterior
                if ($tipo -in @('DWord', 'QWord')) { $valor = [int64]$it.ValorAnterior }
                if (-not (Test-Path -LiteralPath $it.Caminho)) { New-Item -Path $it.Caminho -Force | Out-Null }
                New-ItemProperty -LiteralPath $it.Caminho -Name $it.Nome -Value $valor -PropertyType $tipo -Force | Out-Null
                $conf = Get-PrnValorRegistro -Caminho $it.Caminho -Nome $it.Nome
                if ("$($conf.Valor)" -eq "$($it.ValorAnterior)") { $linha.Resultado = 'revertido'; $linha.Detalhe = ('valor = {0} (confirmado)' -f $conf.Valor) }
                else { $linha.Resultado = 'nao confirmado'; $linha.Detalhe = ('releitura devolveu {0}' -f $conf.Valor) }
            }
        } catch {
            $linha.Resultado = 'falhou'
            $linha.Detalhe   = $_.Exception.Message
        }
        [void]$resultados.Add($linha)
    }

    # So marca como revertido o que a RELEITURA confirmou.
    $confirmados = 0
    foreach ($it in $todos) {
        $res = @($resultados | Where-Object { $_.Alvo -eq ('{0}\{1}' -f $it.Caminho, $it.Nome) -and $_.Operacao -eq $it.Operacao }) | Select-Object -First 1
        if ($res -and $res.Resultado -eq 'revertido' -and -not $it.Revertido) {
            $it.Revertido = $true
            $it.RevertidoEm = (Get-Date -Format 's')
            $confirmados++
        }
    }
    [void](Save-PrnRestauracoes -Itens $todos)

    Write-CompartDiskTitulo 'RESULTADO DA REVERSAO'
    Write-CompartDiskTable -Rows @($resultados)
    Add-CompartDiskSection -Title 'Reversao de alteracoes' -Status $(if ($confirmados -eq $meus.Count) { 'OK' } else { 'WARN' }) `
        -Rows @($resultados) -Summary ('{0} de {1} alteracao(oes) revertida(s) e confirmada(s)' -f $confirmados, $meus.Count)

    if ($confirmados -eq $meus.Count) {
        Write-Log OK ('{0} alteracao(oes) revertida(s) e confirmada(s) por releitura.' -f $confirmados)
    } else {
        Write-Log WARN ('{0} de {1} alteracao(oes) revertida(s). As demais continuam registradas e podem ser tentadas novamente.' -f $confirmados, $meus.Count)
        Set-PrnResult 'WARN'
    }
}

# ==============================================================================
# MENU
#
# O menu vive no modulo, e nao no Launcher.bat, pelo mesmo motivo de Apps.ps1 e
# Winget.ps1: sao onze escolhas, com uma de dois digitos, e o CHOICE do Batch
# trabalha com uma tecla so. Read-CompartDiskOpcao ja resolve o prefixo ambiguo
# ("1" de um menu que vai ate 10) sem exigir Enter.
# ==============================================================================

function Write-PrnOpcao {
    <# Uma linha de opcao na gramatica EXATA dos submenus do Launcher.bat:
       tres espacos de margem, a tecla entre colchetes em ciano (C_CIANO, ESC[36m)
       e o texto em cinza claro (C_TEXTO, ESC[37m), separados de modo que o texto
       comece sempre na mesma coluna, tanto em [1] quanto em [10].

       Write-Color pinta a linha inteira de uma cor so, entao a linha e composta
       em tres chamadas com -NoNewLine. Continua sendo o primitivo do Core: nao
       ha sistema de cores paralelo, nem sequencia ANSI escrita a mao. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tecla,
        [Parameter(Mandatory)][string]$Texto,
        [switch]$Voltar
    )
    Write-Color '   ' -NoNewLine
    Write-Color ('[{0}]' -f $Tecla) -Color $(if ($Voltar) { [ConsoleColor]::DarkGray } else { [ConsoleColor]::DarkCyan }) -NoNewLine
    Write-Color ($(if ($Tecla.Length -ge 2) { ' ' } else { '  ' }) + $Texto) -Color Gray
}

function Write-PrnRodape {
    <# Bloco de rodape na gramatica dos submenus do Launcher.bat: regua de 74,
       contexto em cinza e assinatura.

       O estado do subsistema fica AQUI, e nao no cabecalho, porque e onde
       :MENU_APLICATIVOS ja coloca as suas linhas de dica - abaixo da regua,
       acima da assinatura. Antes essas linhas ficavam logo sob o titulo, que e
       posicao que nenhum outro submenu do projeto usa.

       O conteudo e o mesmo de antes: spooler, contagem de impressoras e
       privilegio. Consultas baratas e somente leitura. #>
    [CmdletBinding()] param()
    $sp = $null
    $n  = 'n/d'
    $u  = 'n/d'
    try {
        $sp  = Get-PrnSpooler
        $imp = Get-PrnImpressoras
        if ($null -eq $imp) {
            $n = 'nao consultadas (WMI nao respondeu)'
            $u = 'n/d'
        } else {
            $n = $imp.Count
            $u = @($imp | Where-Object { $_.Tipo -eq 'Compartilhada (UNC)' }).Count
        }
    } catch { Write-Log DEBUG "Linha de estado do menu nao montada: $($_.Exception.Message)" -NoConsole }

    $cor = [ConsoleColor]::Yellow
    $txt = 'n/d'
    if ($sp) {
        $txt = ('{0} / inicializacao {1}' -f $sp.Status, $sp.Inicializacao)
        if ("$($sp.Status)" -eq 'Running') { $cor = [ConsoleColor]::Green } else { $cor = [ConsoleColor]::Red }
    }

    # Regua identica a dos submenus do Launcher.bat: dois espacos de margem e 74
    # tracos, a mesma medida usada por Write-CompartDiskMenuCabecalho no Core.
    Write-Color ("  " + ('-' * 74)) -Color DarkGray
    Write-Color ('  Spooler     : {0}' -f $txt) -Color $cor
    Write-Color ('  Impressoras : {0} instalada(s), {1} compartilhada(s) (UNC)' -f $n, $u) -Color DarkGray
    Write-Color ('  Privilegio  : {0}' -f $(if (Test-Administrator) { 'administrador' } else { 'padrao (diagnostico completo; correcoes exigem elevacao)' })) -Color DarkGray
    Write-Color '  [1] [5] [7] [8] [9] nao alteram nada. [2] [3] [4] [6] [10] pedem confirmacao.' -Color DarkGray
    Write-Color ("  COMPARTDISK {0}" -f $Global:CompartDisk.Version) -Color DarkGray
    Write-Color ("  {0}" -f $Global:CompartDisk.Signature) -Color DarkGray
    Write-Color ''
}

function Show-PrnMenu {
    [CmdletBinding()] param([switch]$Quiet)

    if (-not (Test-CompartDiskInterativo -Quiet:$Quiet)) {
        Write-Log INFO 'Execucao sem operador: o menu nao pode ser exibido. Executando o diagnostico automatico, que nao altera o sistema.'
        [void](Invoke-PrnDiagnostico -Quiet:$Quiet)
        return
    }

    while ($true) {
        # Cabecalho pelo ponto UNICO do Core, o mesmo que Apps.ps1 e Winget.ps1
        # usam: limpa a tela e desenha titulo e regua. O titulo segue a caixa
        # mista e sem acento dos demais submenus ("Hardware e Discos", "Reparo
        # Critico"), nao a caixa alta que este menu usava.
        Write-CompartDiskMenuCabecalho -Titulo 'Diagnostico e Reparo de Impressao' -Quiet:$Quiet
        Write-PrnOpcao -Tecla '1'  -Texto 'Diagnostico automatico'
        Write-PrnOpcao -Tecla '2'  -Texto 'Corrigir erro 0x0000011B'
        Write-PrnOpcao -Tecla '3'  -Texto 'Corrigir erro 0x00000709'
        Write-PrnOpcao -Tecla '4'  -Texto 'Corrigir erro 0x00000BC4'
        Write-PrnOpcao -Tecla '5'  -Texto 'Corrigir impressora compartilhada'
        Write-PrnOpcao -Tecla '6'  -Texto 'Corrigir Spooler de Impressao'
        Write-PrnOpcao -Tecla '7'  -Texto 'Diagnostico RPC / SMB'
        Write-PrnOpcao -Tecla '8'  -Texto 'Diagnostico de drivers e portas'
        Write-PrnOpcao -Tecla '9'  -Texto 'Diagnostico completo'
        Write-PrnOpcao -Tecla '10' -Texto 'Restaurar alteracoes'
        Write-Color ''
        Write-PrnOpcao -Tecla '0'  -Texto 'Voltar' -Voltar
        Write-Color ''
        Write-PrnRodape

        # Mesmo rotulo do CHOICE dos submenus do Launcher.bat ("  Opcao: "), em
        # vez do "Escolha" padrao de Read-CompartDiskOpcao.
        $opc = Read-CompartDiskOpcao -Maximo 10 -Rotulo '  Opcao'
        if ($opc -eq 0) { return }

        # Cada opcao roda dentro do seu proprio try: uma falha em qualquer uma
        # devolve o operador ao menu, nunca derruba o modulo nem o Launcher.
        try {
            switch ($opc) {
                1  { [void](Invoke-PrnDiagnostico -Quiet:$Quiet) }
                2  { Repair-Prn011B -Quiet:$Quiet }
                3  { Repair-Prn0709 -Quiet:$Quiet }
                4  { Repair-Prn0BC4 -Quiet:$Quiet }
                5  { Invoke-PrnDiagnosticoCompartilhada }
                6  { Repair-PrnSpooler -Quiet:$Quiet }
                7  { Invoke-PrnDiagnosticoRede }
                8  { Invoke-PrnDiagnosticoDriversPortas }
                9  {
                        $d = Invoke-PrnDiagnostico -Completo -Quiet:$Quiet
                        if ($d) {
                            New-Report -Name 'Impressao' -Title 'Diagnostico do subsistema de impressao' -Format TXT, CSV, JSON, HTML | Out-Null
                        }
                   }
                10 { Invoke-PrnReversao -Quiet:$Quiet }
            }
        } catch {
            Write-Log ERR ('Falha na opcao [{0}] do menu de impressao.' -f $opc) -ErrorRecord $_
            Add-CompartDiskFinding -Severity CRIT -Area 'Impressao' -Message ("Excecao na opcao [{0}]: {1}" -f $opc, $_.Exception.Message)
            Set-PrnResult 'ERROR'
        }

        Write-Color ''
        Write-PrnOpcao -Tecla '0' -Texto 'Voltar ao menu' -Voltar
        Write-Color ''
        [void](Read-CompartDiskOpcao -Maximo 0 -Rotulo '  Opcao')
    }
}

# ==============================================================================
# CICLO DE VIDA
# ==============================================================================
try {
    if (-not (Start-CompartDiskModule -Name 'Printer' -Action $Action -Quiet:$Quiet)) { exit $Global:CompartDisk.Exit.ERROR }

    switch ($Action) {
        'Menu'         { Show-PrnMenu -Quiet:$Quiet }
        'Diagnose'     { [void](Invoke-PrnDiagnostico -Quiet:$Quiet) }
        'Full'         { [void](Invoke-PrnDiagnostico -Completo -Quiet:$Quiet) }
        'Spooler'      { Repair-PrnSpooler -Quiet:$Quiet }
        'Shared'       { Invoke-PrnDiagnosticoCompartilhada }
        'Rpc'          { Invoke-PrnDiagnosticoRede }
        'DriversPorts' { Invoke-PrnDiagnosticoDriversPortas }
        'Fix011B'      { Repair-Prn011B -Quiet:$Quiet }
        'Fix0709'      { Repair-Prn0709 -Quiet:$Quiet }
        'Fix0BC4'      { Repair-Prn0BC4 -Quiet:$Quiet }
        'Restore'      { Invoke-PrnReversao -Quiet:$Quiet }
        'Report'       {
            [void](Invoke-PrnDiagnostico -Completo -Quiet:$Quiet)
            New-Report -Name 'Impressao' -Title 'Diagnostico do subsistema de impressao' -Format TXT, CSV, JSON, HTML | Out-Null
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Printer (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Impressao' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $oQue = switch ($Action) {
        'Menu'         { 'Diagnostico e reparo do subsistema de impressao do Windows' }
        'Diagnose'     { 'Estado de impressoras, spooler, fila, politicas e servidores' }
        'Full'         { 'Estado completo de impressao, incluindo drivers, portas e politicas' }
        'Spooler'      { 'Reinicio controlado do servico de spool e limpeza da fila' }
        'Shared'       { 'Cadeia de conexao das impressoras compartilhadas' }
        'Rpc'          { 'Conectividade de rede, SMB e RPC dos servidores de impressao' }
        'DriversPorts' { 'Drivers e portas de impressao instalados' }
        'Fix011B'      { 'Correcao do cenario 0x0000011B' }
        'Fix0709'      { 'Correcao do cenario 0x00000709' }
        'Fix0BC4'      { 'Correcao do cenario 0x00000BC4' }
        'Restore'      { 'Reversao das alteracoes aplicadas por este modulo' }
        'Report'       { 'Diagnostico completo de impressao e geracao do relatorio' }
        default        { '' }
    }
    Write-CompartDiskSummary -Result $result -Verificacao $oQue
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
