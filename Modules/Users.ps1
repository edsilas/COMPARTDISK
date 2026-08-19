<#
 COMPARTDISK 1.4.4 - Users.ps1
 Desenvolvido por Edsilas
 Acoes: List | Groups | Audit | ClearPassword | SetPassword | EnableAdmin | DisableAdmin
 Toda alteracao de conta e registrada no log como evento de seguranca.
#>
[CmdletBinding()]
param(
    [ValidateSet('List', 'Groups', 'Audit', 'ClearPassword', 'SetPassword', 'EnableAdmin', 'DisableAdmin')]
    [string]$Action = 'List',
    [string]$User = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

# Identificadores independentes de idioma. Nome de grupo e de conta sao traduzidos
# em cada instalacao do Windows; SID e RID nao.
$script:SidAdministradores = 'S-1-5-32-544'
$script:RidEspeciais = @{
    500 = 'Administrador interno'
    501 = 'Convidado'
    503 = 'DefaultAccount (sistema)'
    504 = 'WDAGUtilityAccount (Application Guard)'
}
$script:CaminhoWinlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

# ------------------------------------------------------------------------------
# Ambiente: capacidade real, indice de contas, identidade do Administrador interno
# ------------------------------------------------------------------------------
function Get-ContasCapability {
    <# Capacidade REAL do ambiente, nao apenas a existencia do nome do comando.

       No PowerShell 7 o diretorio de modulos do Windows PowerShell continua no
       PSModulePath, entao Get-Command ENCONTRA Get-LocalUser, mas a importacao
       falha por incompatibilidade de edicao e o cmdlet nao executa.
       Import-CompartDiskModule ja resolve isso (-SkipEditionCheck e, se preciso,
       o caminho em System32); sem essa tentativa o modulo cairia para CIM/net.exe
       num ambiente em que os cmdlets funcionam perfeitamente. #>
    [CmdletBinding()] param()
    if ($script:Cap) { return $script:Cap }
    [void](Import-CompartDiskModule 'Microsoft.PowerShell.LocalAccounts')
    # A sondagem e feita para TODA acao, inclusive as somente leitura: ela nao pode
    # derrubar o modulo se %SystemRoot% estiver ausente ou o caminho for invalido.
    $net = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
            $p = Join-Path $env:SystemRoot 'System32\net.exe'
            if (Test-Path -LiteralPath $p) { $net = $p }
        }
    } catch { }
    $script:Cap = [pscustomobject]@{
        GetLocalUser        = (Test-CompartDiskCommand 'Get-LocalUser')
        SetLocalUser        = (Test-CompartDiskCommand 'Set-LocalUser')
        EnableLocalUser     = ((Test-CompartDiskCommand 'Enable-LocalUser') -and (Test-CompartDiskCommand 'Disable-LocalUser'))
        GetLocalGroup       = (Test-CompartDiskCommand 'Get-LocalGroup')
        GetLocalGroupMember = (Test-CompartDiskCommand 'Get-LocalGroupMember')
        NetExe              = $net
        Admin               = (Test-Administrator)
    }
    Write-Log DEBUG ("Capacidade de contas: LocalAccounts={0} | Grupos={1} | net.exe={2} | Admin={3}" -f `
        $script:Cap.GetLocalUser, $script:Cap.GetLocalGroup, [bool]$script:Cap.NetExe, $script:Cap.Admin) -NoConsole
    return $script:Cap
}

function Get-LocalUserSidIndex {
    <# Indice Nome -> SID/estado, coletado UMA vez por execucao (-Refresh so apos
       uma alteracao de conta).

       Existe porque Get-CompartDiskLocalUsers (Collectors, compartilhado com
       Audit.ps1) nao publica o SID, e tanto o Administrador interno quanto as
       contas especiais precisam ser reconhecidos por RID - nunca por nome
       traduzido. Tambem evita a terceira enumeracao de contas que a auditoria
       fazia (List + Groups + busca do Administrador). #>
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:IndiceSid -and -not $Refresh) { return $script:IndiceSid }

    $contas = @{}
    $erro   = $null
    $origem = 'n/d'
    $cap    = Get-ContasCapability

    if ($cap.GetLocalUser) {
        $r = Invoke-SafeCommand { Get-LocalUser -ErrorAction Stop } -Activity 'Get-LocalUser (indice)' -Silent
        if ($r.Success) {
            foreach ($u in @($r.Value)) {
                $contas["$($u.Name)"] = [pscustomobject]@{
                    Nome = "$($u.Name)"; SID = "$($u.SID.Value)"; Habilitado = $u.Enabled; Origem = 'LocalAccounts'
                }
            }
            if ($contas.Count -gt 0) { $origem = 'LocalAccounts' }
        } else { $erro = $r.Error }
    }

    # Queda para CIM apenas quando o caminho estruturado nao produziu nada.
    if ($contas.Count -eq 0) {
        try {
            foreach ($u in @(Get-CompartDiskCim -Class Win32_UserAccount -Filter 'LocalAccount=True')) {
                if (-not $u) { continue }
                $contas["$($u.Name)"] = [pscustomobject]@{
                    Nome = "$($u.Name)"; SID = "$($u.SID)"; Habilitado = (-not $u.Disabled); Origem = 'CIM'
                }
            }
            if ($contas.Count -gt 0) { $origem = 'CIM' }
        } catch { if (-not $erro) { $erro = $_ } }
    }

    $script:IndiceSid = [pscustomobject]@{
        Contas     = $contas
        Disponivel = ($contas.Count -gt 0)
        Origem     = $origem
        Erro       = $erro
    }
    return $script:IndiceSid
}

function Get-BuiltinAdminAccount {
    <# A conta interna de Administrador termina sempre em -500, em qualquer idioma
       e mesmo depois de renomeada. Comparar com 'Administrator'/'Administrador'
       erraria duas vezes: nao acharia a conta num Windows traduzido e poderia
       acertar uma conta comum que tenha recebido esse nome.

       Distingue "nao existe" de "nao foi possivel consultar": tratar os dois como
       a mesma coisa transformaria uma falha de consulta em ausencia de conta. #>
    [CmdletBinding()] param()
    $idx   = Get-LocalUserSidIndex
    $conta = $null
    foreach ($c in $idx.Contas.Values) {
        if ("$($c.SID)" -match '-500$') { $conta = $c; break }
    }
    $motivo = ''
    if (-not $conta) {
        $motivo = if (-not $idx.Disponivel) { 'a enumeracao de contas locais falhou' } else { 'nenhuma conta local possui RID 500' }
    }
    return [pscustomobject]@{
        Encontrada  = [bool]$conta
        Nome        = $(if ($conta) { $conta.Nome } else { $null })
        SID         = $(if ($conta) { $conta.SID } else { $null })
        Habilitado  = $(if ($conta) { $conta.Habilitado } else { $null })
        Consultavel = $idx.Disponivel
        Motivo      = $motivo
    }
}

function Get-RidDaConta {
    param([string]$Sid)
    if ("$Sid" -match '-(\d+)$') { return [int]$matches[1] }
    return -1
}

function Write-LogSeguranca {
    <# Formato unico para toda alteracao de conta, sobre a infraestrutura de log do
       Core (nao ha segundo sistema de log):
       acao -> conta afetada -> operador -> computador -> resultado -> motivo.
       Nenhuma senha, SecureString ou segredo entra aqui. #>
    param(
        [Parameter(Mandatory)][string]$Acao,
        [Parameter(Mandatory)][string]$Conta,
        [Parameter(Mandatory)][string]$Resultado,
        [string]$Motivo = '',
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR')][string]$Nivel = 'OK'
    )
    $txt = "{0} | conta='{1}' | operador='{2}' | computador='{3}' | resultado={4}" -f `
        $Acao, $Conta, $Global:CompartDisk.User, $Global:CompartDisk.Computer, $Resultado
    if ($Motivo) { $txt += " | motivo=$Motivo" }
    Write-Log $Nivel $txt
}

# ------------------------------------------------------------------------------
# List
# ------------------------------------------------------------------------------
function Show-Users {
    $u = @(Get-CompartDiskLocalUsers)
    if ($u.Count -eq 0) {
        Write-Log WARN 'Nenhuma conta local enumerada.'
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message 'Nao foi possivel enumerar as contas locais.' -Recommendation 'Verificar o modulo LocalAccounts e o repositorio WMI (winmgmt /verifyrepository).'
        $script:result = 'WARN'
        return
    }
    Write-Color ''
    $u | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Contas locais' -Status OK -Rows $u -Summary "$($u.Count) conta(s)"

    $idx   = Get-LocalUserSidIndex
    $admin = Get-BuiltinAdminAccount

    $semSenhaDesabilitadas = New-Object System.Collections.ArrayList
    $semInformacao         = New-Object System.Collections.ArrayList

    foreach ($c in $u) {
        $nome = "$($c.Usuario)"
        if (-not $nome) { continue }

        $rid = -1
        if ($idx.Disponivel -and $idx.Contas.ContainsKey($nome)) { $rid = Get-RidDaConta -Sid $idx.Contas[$nome].SID }
        $rotuloEspecial = $(if ($script:RidEspeciais.ContainsKey($rid)) { " [$($script:RidEspeciais[$rid])]" } else { '' })

        # Exigencia de senha desconhecida NAO e exigencia satisfeita: sem essa
        # separacao, um ambiente que nao publica PasswordRequired sairia do
        # relatorio com a mesma aparencia de um ambiente auditado e conforme.
        if ($null -eq $c.SenhaRequerida -or "$($c.SenhaRequerida)" -eq '' -or "$($c.SenhaRequerida)" -eq 'n/d') {
            [void]$semInformacao.Add($nome)
            continue
        }
        if ($c.SenhaRequerida -ne $false) { continue }

        if ($c.Habilitado -eq $true) {
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' `
                -Message "Conta '$nome'$rotuloEspecial habilitada sem exigencia de senha." `
                -Recommendation 'Definir uma senha ou desabilitar a conta.'
            $script:result = 'WARN'
        } elseif ($c.Habilitado -eq $false) {
            # Conta desabilitada nao concede acesso: e informacao, nao vulnerabilidade.
            [void]$semSenhaDesabilitadas.Add("$nome$rotuloEspecial")
        } else {
            [void]$semInformacao.Add($nome)
        }
    }

    if ($semSenhaDesabilitadas.Count -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' `
            -Message ("{0} conta(s) sem exigencia de senha, porem DESABILITADA(s): {1}." -f $semSenhaDesabilitadas.Count, (($semSenhaDesabilitadas | Select-Object -First 8) -join ', ')) `
            -Recommendation 'Manter desabilitadas. Sem habilitacao, nao concedem acesso.'
    }
    if ($semInformacao.Count -gt 0) {
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' `
            -Message ("{0} conta(s) sem informacao de exigencia de senha ou de estado: {1}." -f $semInformacao.Count, (($semInformacao | Select-Object -First 8) -join ', ')) `
            -Recommendation 'Reexecutar com o modulo LocalAccounts disponivel para avaliacao completa.'
    }

    if ($admin.Encontrada) {
        if ($admin.Habilitado -eq $true) {
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' `
                -Message "Conta interna de Administrador ('$($admin.Nome)', RID 500) esta habilitada." `
                -Recommendation 'Manter desabilitada em ambiente corporativo; usar contas nominais.'
            $script:result = 'WARN'
        } elseif ($null -eq $admin.Habilitado) {
            Add-CompartDiskFinding -Severity INFO -Area 'Contas' `
                -Message "Estado da conta interna de Administrador ('$($admin.Nome)') nao pode ser determinado." `
                -Recommendation 'Reexecutar com o modulo LocalAccounts disponivel.'
        }
    } elseif (-not $admin.Consultavel) {
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' `
            -Message "Conta interna de Administrador nao verificada ($($admin.Motivo))." `
            -Recommendation 'Reexecutar apos restabelecer a consulta de contas locais.'
    }

    Write-Log OK "$($u.Count) conta(s) local(is) listada(s)."
}

# ------------------------------------------------------------------------------
# Groups
# ------------------------------------------------------------------------------
function Show-Groups {
    $cap    = Get-ContasCapability
    $rows   = New-Object System.Collections.ArrayList
    $indice = New-Object System.Collections.ArrayList
    $grupos = $null
    $origem = 'n/d'

    if ($cap.GetLocalGroup) {
        # -ErrorAction SilentlyContinue engolia a falha de Get-LocalGroup e o modulo
        # seguia com a lista VAZIA, registrando "Grupos locais listados" como OK.
        $g = Invoke-SafeCommand { Get-LocalGroup -ErrorAction Stop } -Activity 'Get-LocalGroup' -Silent
        if ($g.Success -and @($g.Value).Count -gt 0) { $grupos = @($g.Value); $origem = 'LocalAccounts' }
    }
    if (-not $grupos) {
        $c = @(Get-CompartDiskCim -Class Win32_Group -Filter 'LocalAccount=True')
        if ($c.Count -gt 0 -and $c[0]) { $grupos = $c; $origem = 'CIM' }
    }
    if (-not $grupos) {
        Write-Log WARN 'Nao foi possivel enumerar os grupos locais.'
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message 'Grupos locais nao puderam ser enumerados.' -Recommendation 'Verificar o modulo LocalAccounts e o repositorio WMI.'
        $script:result = 'WARN'
        return
    }

    foreach ($g in $grupos) {
        $nome = "$($g.Name)"
        $sid  = ''
        try { $sid = $(if ($g.SID -is [string]) { "$($g.SID)" } else { "$($g.SID.Value)" }) } catch { $sid = '' }

        $textoMembros = 'n/d'
        $totalNum     = $null

        if ($origem -eq 'LocalAccounts' -and $cap.GetLocalGroupMember) {
            $m = Invoke-SafeCommand { @(Get-LocalGroupMember -Group $g -ErrorAction Stop) } -Activity "Membros de '$nome'" -Silent
            if ($m.Success) {
                $nomes = @(@($m.Value) | ForEach-Object { "$($_.Name)" } | Where-Object { $_ })
                $totalNum     = $nomes.Count
                $textoMembros = $(if ($totalNum -gt 0) { ($nomes -join '; ') } else { '(vazio)' })
            } else {
                # Get-LocalGroupMember falha de verdade em cenarios comuns (SID orfao
                # de conta removida, membro de dominio irresolvivel). Devolver
                # "(vazio)" ali afirmaria que o grupo nao tem membros - justamente o
                # contrario do que a consulta informou.
                $textoMembros = 'n/d (falha ao consultar os membros)'
            }
        } elseif ($origem -eq 'CIM') {
            $textoMembros = 'n/d (fallback CIM nao lista membros)'
        }

        [void]$rows.Add([pscustomobject]@{
            Grupo     = $nome
            Descricao = $g.Description
            Membros   = $textoMembros
            Total     = $(if ($null -ne $totalNum) { $totalNum } else { 'n/d' })
        })
        [void]$indice.Add([pscustomobject]@{ Nome = $nome; SID = $sid; Total = $totalNum })
    }

    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Grupos locais' -Status INFO -Rows @($rows) -Summary ("{0} grupo(s) | origem: {1}" -f $rows.Count, $origem)

    # Identificacao pelo SID do grupo interno de administradores (S-1-5-32-544),
    # valido em qualquer idioma. A expressao textual fica apenas como ultimo
    # recurso, quando nenhum SID pode ser lido: 'Administrador|Administrators' nao
    # casa com 'Administratoren' nem com 'Administrateurs'.
    $adm = @($indice | Where-Object { $_.SID -eq $script:SidAdministradores }) | Select-Object -First 1
    if (-not $adm) {
        $adm = @($indice | Where-Object { -not $_.SID -and $_.Nome -match 'Administrador|Administrators|Administratoren|Administrateurs' }) | Select-Object -First 1
    }

    if (-not $adm) {
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message 'Grupo interno de administradores (S-1-5-32-544) nao identificado na enumeracao.' -Recommendation 'Reexecutar com o modulo LocalAccounts disponivel.'
    } elseif ($null -eq $adm.Total) {
        # Sem a contagem, o principio do menor privilegio nao pode ser avaliado.
        # Antes, 'n/d' era comparado com 3: a comparacao virava texto ('n/d' -gt '3'
        # e verdadeiro) e TODA execucao pelo fallback publicava o achado
        # "Grupo de administradores possui n/d membros".
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' `
            -Message "Membros do grupo '$($adm.Nome)' nao puderam ser listados." `
            -Recommendation 'Revisar manualmente os administradores locais (principio do menor privilegio).'
    } elseif ($adm.Total -gt 3) {
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' `
            -Message "Grupo de administradores ('$($adm.Nome)') possui $($adm.Total) membros." `
            -Recommendation 'Revisar o principio do menor privilegio: quantidade e sinal de revisao, nao vulnerabilidade por si so.'
        # Achado WARN sem resultado WARN e sinal mascarado: o relatorio consolidado
        # registrava o modulo como OK enquanto publicava o achado.
        $script:result = 'WARN'
    }
    Write-Log OK ("{0} grupo(s) local(is) listado(s)." -f $rows.Count)
}

# ------------------------------------------------------------------------------
# Audit
# ------------------------------------------------------------------------------
function Show-AccountPolicy {
    $cap = Get-ContasCapability
    if (-not $cap.NetExe) {
        Write-Log WARN 'net.exe nao localizado em System32: politica de contas nao consultada.'
        Add-CompartDiskSection -Title 'Politica de contas' -Status WARN -Summary 'Nao verificada (net.exe ausente)'
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message 'Politica de contas nao verificada: net.exe ausente.' -Recommendation 'Verificar a integridade de %SystemRoot%\System32.'
        return
    }

    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $cap.NetExe -Arguments @('accounts') -TimeoutSeconds 30 } -Activity 'net accounts'
    if (-not $r.Success) {
        $detalhe = "$($r.Error.Exception.Message)"
        Write-Log WARN "Politica de contas nao verificada: $detalhe"
        Add-CompartDiskSection -Title 'Politica de contas' -Status WARN -Summary 'Nao verificada (falha ao executar net accounts)'
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message "Politica de contas nao verificada ($detalhe)." -Recommendation 'Reexecutar; verificar o servico Servidor e a integridade de net.exe.'
        return
    }

    $stdout = "$($r.Value.StdOut)"
    $stderr = "$($r.Value.StdErr)".Trim()
    $codigo = $r.Value.ExitCode

    # Codigo de saida e stderr nao eram avaliados: uma consulta recusada com saida
    # parcial era interpretada como politica valida e publicada como tal.
    if ($codigo -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
        $detalhe = $(if ($stderr) { $stderr }
                     elseif ([string]::IsNullOrWhiteSpace($stdout)) { "net accounts retornou $codigo sem saida" }
                     else { "net accounts retornou $codigo (saida descartada por nao ser confiavel)" })
        Write-Log WARN "Politica de contas nao verificada: $detalhe"
        Add-CompartDiskSection -Title 'Politica de contas' -Status WARN -Summary "Nao verificada ($detalhe)"
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message "Politica de contas nao verificada ($detalhe)." -Recommendation 'Em dominio, a politica efetiva vem do controlador; consultar pelo GPO aplicado.'
        return
    }

    Write-Output $stdout
    $pares = [ordered]@{}
    foreach ($linha in ($stdout -split '\r?\n')) {
        $t = "$linha".Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t -match '^(.+?):\s+(\S.*)$') {
            $chave = "$($matches[1])".Trim()
            $valor = "$($matches[2])".Trim()
            if ($chave -and $valor) { $pares[$chave] = $valor }
        }
    }

    if ($pares.Count -gt 0) {
        # As chaves permanecem no idioma do Windows: traduzi-las exigiria uma tabela
        # por idioma e produziria rotulos errados no primeiro idioma nao previsto.
        Add-CompartDiskSection -Title 'Politica de contas' -Status INFO -Pairs $pares -Summary "$($pares.Count) parametro(s)"
    } else {
        # Formato nao reconhecido preserva o texto original em vez de publicar uma
        # politica vazia, que no relatorio pareceria uma politica valida.
        $bruto = @(($stdout -split '\r?\n') | Where-Object { "$_".Trim() } | ForEach-Object { [pscustomobject]@{ Linha = "$_".Trim() } })
        Add-CompartDiskSection -Title 'Politica de contas' -Status INFO -Rows $bruto -Summary 'Saida original preservada (formato nao reconhecido)'
        Write-Log WARN 'Politica de contas: formato de saida nao reconhecido; texto original preservado no relatorio.'
    }
}

function ConvertFrom-LogonFailureEvent {
    <# Extrai os campos estruturados do EventData do 4625.

       A primeira linha de Message e sempre "Falha ao fazer logon em uma conta." -
       quinze linhas identicas e sem informacao. Os dados uteis (conta, dominio,
       tipo de logon, origem, processo, motivo) estao no EventData, que e nomeado e
       nao depende do idioma. O texto continua como queda quando o XML nao pode ser
       lido. #>
    param([Parameter(Mandatory)]$Evento)

    $mapaLogon = @{
        '2' = 'Interativo (teclado)'; '3' = 'Rede'; '4' = 'Lote'; '5' = 'Servico'
        '7' = 'Desbloqueio de estacao'; '8' = 'Rede (senha em texto claro)'
        '9' = 'Nova credencial'; '10' = 'Area de trabalho remota'; '11' = 'Interativo em cache'
    }
    $mapaStatus = @{
        '0xC0000064' = 'Conta inexistente'; '0xC000006A' = 'Senha incorreta'
        '0xC000006D' = 'Nome ou credencial invalidos'; '0xC000006E' = 'Restricao de conta'
        '0xC000006F' = 'Fora do horario permitido'; '0xC0000070' = 'Estacao de trabalho nao permitida'
        '0xC0000071' = 'Senha expirada'; '0xC0000072' = 'Conta desabilitada'
        '0xC0000133' = 'Relogio fora de sincronia com o controlador'
        '0xC000015B' = 'Tipo de logon nao concedido a esta conta'
        '0xC0000193' = 'Conta expirada'; '0xC0000224' = 'Troca de senha obrigatoria'
        '0xC0000234' = 'Conta bloqueada'; '0xC0000413' = 'Recusado por politica de autenticacao'
    }

    $d = @{}
    try {
        $xml = [xml]$Evento.ToXml()
        foreach ($item in $xml.Event.EventData.Data) {
            if ($item.Name) { $d["$($item.Name)"] = "$($item.'#text')".Trim() }
        }
    } catch { }

    $vazio = { param($v) if ([string]::IsNullOrWhiteSpace($v) -or $v -eq '-') { $null } else { $v } }

    $conta   = & $vazio $d['TargetUserName']
    $dominio = & $vazio $d['TargetDomainName']
    $estacao = & $vazio $d['WorkstationName']
    $ip      = & $vazio $d['IpAddress']
    $proc    = & $vazio $d['ProcessName']
    $tipo    = "$($d['LogonType'])"
    $sub     = "$($d['SubStatus'])"
    $st      = "$($d['Status'])"

    $origem = @($estacao, $ip | Where-Object { $_ }) -join ' / '
    $codigo = $(if ($sub -and $sub -notmatch '^0x0+$') { $sub } else { $st })

    $motivo = $null
    if ($codigo -and $mapaStatus.ContainsKey($codigo)) { $motivo = "$($mapaStatus[$codigo]) ($codigo)" }
    elseif ($codigo) { $motivo = "Codigo $codigo" }
    if (-not $motivo) {
        # Sem EventData legivel, o texto e a unica fonte restante.
        try { $motivo = (("$($Evento.Message)" -split '\r?\n') | Where-Object { "$_".Trim() } | Select-Object -First 1) } catch { }
    }

    return [pscustomobject]@{
        Data       = $Evento.TimeCreated
        Evento     = $Evento.Id
        Conta      = $(if ($conta) { $conta } else { 'n/d' })
        Dominio    = $(if ($dominio) { $dominio } else { 'n/d' })
        Computador = "$($Evento.MachineName)"
        TipoLogon  = $(if ($mapaLogon.ContainsKey($tipo)) { "$($mapaLogon[$tipo]) ($tipo)" } elseif ($tipo) { "Tipo $tipo" } else { 'n/d' })
        Origem     = $(if ($origem) { $origem } else { 'n/d' })
        Processo   = $(if ($proc) { $proc } else { 'n/d' })
        Motivo     = $(if ($motivo) { $motivo } else { 'n/d' })
    }
}

function Show-LogonFailures {
    $dias   = 7
    $limite = 50

    $eventos = $null
    $erro    = $null
    try {
        $eventos = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddDays(-$dias) } -MaxEvents $limite -ErrorAction Stop)
    } catch { $erro = $_ }

    if ($erro) {
        # Classificacao pelo IDENTIFICADOR do erro, nao pelo texto da mensagem: o
        # texto e traduzido e a comparacao literal com 'No events were found' ja
        # jogava a ausencia legitima de eventos, em Windows nao ingles, no ramo de
        # "nao foi possivel verificar".
        $id   = "$($erro.FullyQualifiedErrorId)"
        $ex   = $erro.Exception
        # Comparacao pelo NOME do tipo, nao por [tipo]: um literal de tipo que nao
        # resolva no motor em uso lancaria dentro do proprio tratamento do erro.
        $tipo = ''
        try { $tipo = $ex.GetType().FullName } catch { }

        if ($id -like 'NoMatchingEventsFound*') {
            Write-Log OK "Nenhuma falha de logon (evento 4625) nos ultimos $dias dias."
            Add-CompartDiskFinding -Severity OK -Area 'Contas' -Message "Nenhuma falha de logon relevante nos ultimos $dias dias."
            return
        }

        # Consulta que falhou nao e ausencia de falhas: sem privilegio o log de
        # Seguranca recusa leitura, e afirmar "nenhuma falha" transforma um erro de
        # acesso em atestado de seguranca. A acao Audit nao exige elevacao.
        $motivo =
            if ($id -like 'NoMatchingLogsFound*' -or $tipo -eq 'System.Diagnostics.Eventing.Reader.EventLogNotFoundException') {
                'o log de Seguranca nao existe neste sistema'
            } elseif (-not (Test-Administrator)) {
                'execucao sem privilegio administrativo'
            } elseif ($tipo -match 'UnauthorizedAccess|EventLogException' -or $id -match 'AccessDenied|Unauthorized|EventLogException') {
                'acesso ao log de Seguranca negado mesmo com privilegio administrativo'
            } else {
                "o log de Seguranca nao pode ser lido ($($ex.Message))"
            }

        Write-Log WARN "Falhas de logon nao verificadas: $motivo."
        Add-CompartDiskSection -Title "Falhas de logon ($dias dias)" -Status WARN -Summary "Nao verificado ($motivo)"
        Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message "Falhas de logon nao verificadas ($motivo)." -Recommendation 'Reexecutar como Administrador para auditar o log de Seguranca.'
        return
    }

    if ($eventos.Count -eq 0) {
        Write-Log OK "Nenhuma falha de logon (evento 4625) nos ultimos $dias dias."
        Add-CompartDiskFinding -Severity OK -Area 'Contas' -Message "Nenhuma falha de logon relevante nos ultimos $dias dias."
        return
    }

    $n       = $eventos.Count
    $noLimite = ($n -ge $limite)
    $det     = @($eventos | ForEach-Object { ConvertFrom-LogonFailureEvent -Evento $_ })
    $contas  = @($det | ForEach-Object { $_.Conta }  | Where-Object { $_ -and $_ -ne 'n/d' } | Sort-Object -Unique)
    $origens = @($det | ForEach-Object { $_.Origem } | Where-Object { $_ -and $_ -ne 'n/d' } | Sort-Object -Unique)

    # Volume proporcional a severidade: uma senha digitada errada nao e o mesmo
    # evento de seguranca que uma sequencia continua de tentativas.
    $sev = $(if ($noLimite -or $n -gt 5) { 'WARN' } else { 'INFO' })

    $texto = "$n falha(s) de autenticacao (evento 4625) nos ultimos $dias dias"
    if ($noLimite) { $texto += " - limite de $limite eventos atingido, o total real pode ser maior" }
    if ($contas.Count -gt 0)  { $texto += ". Contas: " + (($contas | Select-Object -First 5) -join ', ') }
    if ($origens.Count -gt 0) { $texto += ". Origens: " + (($origens | Select-Object -First 5) -join ', ') }
    $texto += '.'

    Write-Log $(if ($sev -eq 'WARN') { 'WARN' } else { 'INFO' }) $texto
    Add-CompartDiskFinding -Severity $sev -Area 'Contas' -Message $texto -Recommendation 'Investigar a origem em caso de volume anormal, conta unica repetida ou origem de rede desconhecida.'
    Add-CompartDiskSection -Title "Falhas de logon ($dias dias)" -Status $sev -Rows @($det | Select-Object -First 15) `
        -Summary ("{0} evento(s){1}" -f $n, $(if ($noLimite) { " (limite de $limite atingido)" } else { '' }))
    if ($sev -eq 'WARN') { $script:result = 'WARN' }
}

function Show-AutoLogon {
    <# Somente leitura. Nada em Winlogon e alterado por este modulo. #>
    $auto = Get-CompartDiskRegistryValue -Path $script:CaminhoWinlogon -Name 'AutoAdminLogon'
    if ("$auto" -ne '1') { return }

    $usuario = "$(Get-CompartDiskRegistryValue -Path $script:CaminhoWinlogon -Name 'DefaultUserName' -Default '')".Trim()
    $dominio = "$(Get-CompartDiskRegistryValue -Path $script:CaminhoWinlogon -Name 'DefaultDomainName' -Default '')".Trim()

    # A senha NUNCA e lida. GetValueNames() confirma apenas a EXISTENCIA do valor:
    # ler DefaultPassword traria a senha em texto claro para a memoria do processo
    # e para o risco de acabar num log, num relatorio ou numa mensagem de erro.
    # $null = nao foi possivel verificar; nao pode virar "nao ha senha gravada".
    $temSenha = $null
    try { $temSenha = ((Get-Item -LiteralPath $script:CaminhoWinlogon -ErrorAction Stop).GetValueNames() -contains 'DefaultPassword') }
    catch { Write-Log DEBUG "Winlogon: nomes de valor nao enumerados ($($_.Exception.Message))" -NoConsole }

    $textoSenha = $(if ($null -eq $temSenha) { 'Nao verificado' } elseif ($temSenha) { 'Sim (valor nao lido nem exibido)' } else { 'Nao localizada' })
    $alvo = $(if ($usuario) { $(if ($dominio) { "$dominio\$usuario" } else { $usuario }) } else { 'conta nao declarada em DefaultUserName' })

    Write-Log WARN "Logon automatico ativo (AutoAdminLogon=1) para: $alvo."
    Add-CompartDiskSection -Title 'Logon automatico' -Status WARN -Pairs ([ordered]@{
        'AutoAdminLogon'               = 'Ativo'
        'Conta configurada'            = $alvo
        'Senha armazenada no registro' = $textoSenha
    })
    Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Logon automatico ativo para '$alvo'." -Recommendation 'Desativar em ambiente com acesso fisico compartilhado.'
    if ($temSenha -eq $true) {
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message 'A senha do logon automatico esta gravada no registro (Winlogon\DefaultPassword).' -Recommendation 'Reconfigurar por netplwiz, que guarda a credencial no LSA em vez do registro.'
    }
    $script:result = 'WARN'
}

function Show-Audit {
    # Cada etapa e independente: uma consulta que falha nao pode cancelar as
    # demais, senao uma auditoria inteira se perde por causa de um unico
    # provedor indisponivel.
    $etapas = @(
        @{ Nome = 'contas locais';     Bloco = { Show-Users } }
        @{ Nome = 'grupos locais';     Bloco = { Show-Groups } }
        @{ Nome = 'politica de contas'; Bloco = { Show-AccountPolicy } }
        @{ Nome = 'falhas de logon';   Bloco = { Show-LogonFailures } }
        @{ Nome = 'logon automatico';  Bloco = { Show-AutoLogon } }
    )
    foreach ($e in $etapas) {
        try {
            # Chamada direta (nao via Invoke-SafeCommand): o bloco escreve tabelas no
            # stream de saida, que seriam capturadas em vez de exibidas.
            & $e.Bloco
        } catch {
            Write-Log WARN "Etapa '$($e.Nome)' da auditoria falhou; as demais continuam." -ErrorRecord $_
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' `
                -Message ("Etapa '{0}' da auditoria de contas falhou: {1}" -f $e.Nome, $_.Exception.Message) `
                -Recommendation 'Reexecutar; verificar privilegios e o repositorio WMI.'
            $script:result = 'WARN'
        }
    }
}

# ------------------------------------------------------------------------------
# Credenciais
# ------------------------------------------------------------------------------
function Test-SecureStringIgual {
    <# Compara duas senhas sem materializa-las em texto claro gerenciado.

       A versao anterior chamava PtrToStringAuto nos dois BSTR apenas para
       comparar: isso criava duas String gerenciadas contendo a senha, que o
       coletor de lixo so recupera em algum momento futuro e que nao podem ser
       zeradas. Aqui a comparacao ocorre diretamente sobre a memoria NAO
       gerenciada do BSTR, zerada e liberada por ZeroFreeBSTR no finally - nenhuma
       copia gerenciada chega a existir.

       O BSTR guarda o comprimento em BYTES nos 4 bytes anteriores ao ponteiro e os
       caracteres em UTF-16. #>
    param([Parameter(Mandatory)][securestring]$A, [Parameter(Mandatory)][securestring]$B)
    if ($A.Length -ne $B.Length) { return $false }
    $pa = [IntPtr]::Zero
    $pb = [IntPtr]::Zero
    try {
        $pa = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($A)
        $pb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($B)
        $na = [Runtime.InteropServices.Marshal]::ReadInt32($pa, -4)
        $nb = [Runtime.InteropServices.Marshal]::ReadInt32($pb, -4)
        if ($na -ne $nb) { return $false }
        for ($i = 0; $i -lt $na; $i += 2) {
            if ([Runtime.InteropServices.Marshal]::ReadInt16($pa, $i) -ne [Runtime.InteropServices.Marshal]::ReadInt16($pb, $i)) { return $false }
        }
        return $true
    } finally {
        if ($pa -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pa) }
        if ($pb -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pb) }
    }
}

function Set-SenhaViaAdsi {
    <# Devolve $true/$false conforme a confirmacao por PasswordAge, ou $null quando
       a confirmacao nao pode ser lida. Lanca em caso de falha real da alteracao. #>
    param([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][securestring]$Senha)
    $ptr  = [IntPtr]::Zero
    $adsi = $null
    try {
        $adsi = [ADSI]("WinNT://./{0},user" -f $Nome)
        $ptr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha)
        # SetPassword so aceita String: esta copia gerenciada e inevitavel. Ela e
        # criada o mais tarde possivel, passada direto como argumento (sem variavel
        # que a mantenha viva no escopo) e usada uma unica vez. O BSTR e zerado e
        # liberado no finally, inclusive se SetPassword lancar.
        $adsi.SetPassword([Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr))
        $adsi.SetInfo()
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    # Verificacao pos-operacao disponivel no proprio caminho ADSI.
    try {
        $adsi.RefreshCache()
        $idade = [int]$adsi.PasswordAge.Value
        return ($idade -ge 0 -and $idade -le 120)
    } catch { return $null }
}

function Get-SenhaDefinidaEm {
    <# Carimbo PasswordLastSet, unico dado que o Windows expoe para comprovar que a
       senha realmente mudou. Win32_UserAccount nao publica esse campo, entao no
       caminho CIM a leitura simplesmente nao esta disponivel - e isso e reportado
       como "nao confirmado", nunca como sucesso. #>
    param([Parameter(Mandatory)][string]$Nome)
    $out = [pscustomobject]@{ Lido = $false; Valor = $null }
    if (-not (Get-ContasCapability).GetLocalUser) { return $out }
    $r = Invoke-SafeCommand { Get-LocalUser -Name $Nome -ErrorAction Stop } -Activity "PasswordLastSet de $Nome" -Silent
    if ($r.Success -and $r.Value) {
        $out.Lido  = $true
        $out.Valor = (@($r.Value)[0]).PasswordLastSet
    }
    return $out
}

function Confirm-AlteracaoSenha {
    <# Verificacao pos-operacao. "Set-LocalUser nao lancou excecao" nao prova que a
       senha mudou - e a mesma exigencia que Set-CompartDiskRegistryValue ja aplica
       ao registro. Quando nada pode ser lido, o resultado e 'nao-confirmado',
       nunca 'confirmado'. #>
    param([Parameter(Mandatory)][string]$Nome, $Antes, $DicaAdsi)
    $depois = Get-SenhaDefinidaEm -Nome $Nome
    if ($depois.Lido) {
        if (-not $Antes -or -not $Antes.Lido) {
            if ($null -ne $depois.Valor) { return [pscustomobject]@{ Estado = 'confirmado'; Detalhe = '' } }
        } elseif ("$($Antes.Valor)" -ne "$($depois.Valor)") {
            return [pscustomobject]@{ Estado = 'confirmado'; Detalhe = '' }
        } else {
            return [pscustomobject]@{ Estado = 'nao-confirmado'; Detalhe = 'PasswordLastSet nao mudou apos a operacao' }
        }
    }
    if ($DicaAdsi -eq $true)  { return [pscustomobject]@{ Estado = 'confirmado'; Detalhe = 'confirmado por PasswordAge (ADSI)' } }
    if ($DicaAdsi -eq $false) { return [pscustomobject]@{ Estado = 'nao-confirmado'; Detalhe = 'PasswordAge nao indica alteracao recente' } }
    return [pscustomobject]@{ Estado = 'nao-confirmado'; Detalhe = 'PasswordLastSet indisponivel neste ambiente' }
}

function Resolve-ContaLocal {
    <# Localiza a conta pelo indice ja coletado e classifica a ORIGEM do principal.
       Distingue tres situacoes que nao podem ser confundidas: conta inexistente,
       conta existente e consulta indisponivel. #>
    param([Parameter(Mandatory)][string]$Nome)
    $cap = Get-ContasCapability
    $idx = Get-LocalUserSidIndex
    $out = [pscustomobject]@{
        Encontrada = $false; Consultavel = $idx.Disponivel; Nome = $Nome
        SID = $null; Habilitado = $null; Tipo = 'Desconhecido'; Origem = $idx.Origem
    }
    if ($idx.Disponivel -and $idx.Contas.ContainsKey($Nome)) {
        $c = $idx.Contas[$Nome]
        $out.Encontrada = $true
        $out.Nome       = $c.Nome      # grafia canonica devolvida pelo Windows
        $out.SID        = $c.SID
        $out.Habilitado = $c.Habilitado
    }
    if (-not $out.Encontrada) { return $out }

    if ($cap.GetLocalUser) {
        # Por -Name (grafia canonica vinda do indice, ja sem curinga): a consulta da
        # origem nao deve depender de uma conversao de SID que pode falhar e derrubar
        # a classificacao para 'Desconhecido' sem necessidade.
        $r = Invoke-SafeCommand { Get-LocalUser -Name $out.Nome -ErrorAction Stop } -Activity "Origem de $($out.Nome)" -Silent
        if ($r.Success -and $r.Value) {
            $ps = ''
            try { $ps = "$((@($r.Value)[0]).PrincipalSource)" } catch { }
            if ($ps) { $out.Tipo = $ps }
        }
    }
    return $out
}

function Show-AvisoLogonAutomatico {
    param([Parameter(Mandatory)][string]$Nome)
    $auto = Get-CompartDiskRegistryValue -Path $script:CaminhoWinlogon -Name 'AutoAdminLogon'
    if ("$auto" -ne '1') { return }

    # AutoAdminLogon=1 nao diz QUAL conta entra sozinha; DefaultUserName diz. Avisar
    # "este computador entra sozinho" para uma conta que nao e a do logon automatico
    # induz o operador a um diagnostico errado.
    $contaAuto = "$(Get-CompartDiskRegistryValue -Path $script:CaminhoWinlogon -Name 'DefaultUserName' -Default '')".Trim()
    $curta     = $(if ($contaAuto) { ($contaAuto -split '\\')[-1] } else { '' })

    Write-Color ''
    if ($curta -and $curta -eq $Nome) {
        Write-Color "  Este computador entra no Windows automaticamente com a conta '$Nome'." -Color Yellow
        Write-Color '  Ao alterar a senha, o logon automatico deixara de funcionar e o Windows' -Color Yellow
        Write-Color '  passara a pedir a senha em todo login.' -Color Yellow
    } elseif ($curta) {
        Write-Color "  Este computador tem logon automatico ativo para a conta '$curta'," -Color Yellow
        Write-Color "  que NAO e a conta '$Nome' selecionada para alteracao." -Color Yellow
    } else {
        Write-Color '  Este computador tem logon automatico ativo, mas a conta usada nao esta' -Color Yellow
        Write-Color '  declarada no registro. Verifique antes de continuar.' -Color Yellow
    }
    Write-Color ''
}

function Test-OrigemDaContaAceita {
    <# Guarda de origem do principal, aplicada a SetPassword E a ClearPassword.
       Alterar (ou remover) a senha local de uma conta Microsoft nao altera a
       credencial da Microsoft e costuma impedir a entrada no Windows. #>
    param([Parameter(Mandatory)]$Conta, [Parameter(Mandatory)][string]$Rotulo)

    switch ("$($Conta.Tipo)") {
        'MicrosoftAccount' {
            Write-Color ''
            Write-Color "  A conta '$($Conta.Nome)' e uma CONTA MICROSOFT (entra com e-mail)." -Color Yellow
            Write-Color '  Alterar a senha por aqui nao altera a senha da Microsoft e pode' -Color Yellow
            Write-Color '  impedir a entrada no Windows.' -Color Yellow
            Write-Color ''
            Write-Color '  Troque em: account.microsoft.com  (ou pelo celular)' -Color Gray
            Write-Color ''
            Write-LogSeguranca -Acao $Rotulo -Conta $Conta.Nome -Resultado 'recusado' -Motivo 'conta Microsoft; nenhuma alteracao realizada' -Nivel WARN
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Operacao recusada: '$($Conta.Nome)' e conta Microsoft." -Recommendation 'Alterar a senha em account.microsoft.com.'
            $script:result = 'WARN'
            return $false
        }
        { $_ -in @('ActiveDirectory', 'AzureAD') } {
            Write-Color ''
            Write-Color "  A conta '$($Conta.Nome)' pertence a um diretorio ($_), nao ao SAM local." -Color Yellow
            Write-Color '  A senha deve ser alterada pelo diretorio de origem.' -Color Yellow
            Write-Color ''
            Write-LogSeguranca -Acao $Rotulo -Conta $Conta.Nome -Resultado 'recusado' -Motivo "conta de diretorio ($_); nenhuma alteracao realizada" -Nivel WARN
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Operacao recusada: '$($Conta.Nome)' e conta de diretorio ($_)." -Recommendation 'Alterar a senha no diretorio de origem.'
            $script:result = 'WARN'
            return $false
        }
        'Local' { return $true }
        default {
            # Origem desconhecida nao e origem local. No caminho CIM, PrincipalSource
            # nao existe, e a versao anterior lia $null e seguia adiante como se a
            # conta fosse local - a guarda de conta Microsoft ficava inativa
            # exatamente onde nao havia como verifica-la.
            Write-Color ''
            Write-Color "  O Windows nao informou a origem da conta '$($Conta.Nome)' neste ambiente." -Color Yellow
            Write-Color '  Se voce entra no Windows com um E-MAIL (conta Microsoft), NAO continue:' -Color Yellow
            Write-Color '  troque a senha em account.microsoft.com.' -Color Yellow
            Write-Color ''
            $ok = Read-Host '  Confirma que a conta e LOCAL? Digite S para continuar (qualquer outra tecla cancela)'
            if ($ok -notmatch '^[Ss]$') {
                Write-Log INFO 'Operacao cancelada pelo operador. Nenhuma alteracao foi feita.'
                Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message "$Rotulo cancelado: origem da conta '$($Conta.Nome)' nao pode ser confirmada."
                return $false
            }
            Write-Log WARN "Origem da conta '$($Conta.Nome)' nao verificavel; operador confirmou tratar-se de conta local."
            return $true
        }
    }
}

function Set-UserPassword {
    param([string]$Nome, [switch]$Clear)

    $rotulo = $(if ($Clear) { 'ClearPassword' } else { 'SetPassword' })
    $cap    = Get-ContasCapability

    if ([string]::IsNullOrWhiteSpace($Nome)) {
        Write-Log ERR 'Nenhum usuario informado.'
        $script:result = 'ERROR'
        return
    }
    $Nome = $Nome.Trim()

    # Get-LocalUser -Name aceita curinga: "Admin*" pode devolver varias contas, e
    # $conta como array faria a verificacao de PrincipalSource comparar a concatenacao
    # dos valores - a guarda de conta Microsoft deixaria de casar. Nome de conta do
    # Windows nunca contem curinga: recusar e mais seguro que adivinhar.
    if ($Nome -match '[\*\?\[\]]') {
        Write-Log ERR "Nome de conta invalido: '$Nome'. Informe o nome exato, sem curingas."
        $script:result = 'ERROR'
        return
    }

    if (-not $cap.Admin) {
        Write-Log ERR "$rotulo exige privilegio administrativo. Nenhuma alteracao foi feita."
        $script:result = 'ERROR'
        return
    }

    $conta = Resolve-ContaLocal -Nome $Nome
    if (-not $conta.Encontrada) {
        if (-not $conta.Consultavel) {
            Write-Log ERR "Nao foi possivel consultar as contas locais para localizar '$Nome'. Nenhuma alteracao foi feita."
        } else {
            Write-Log ERR "Conta local '$Nome' nao encontrada. Verifique a grafia exata (use a acao List)."
        }
        $script:result = 'ERROR'
        return
    }
    $Nome = $conta.Nome

    if (-not (Test-OrigemDaContaAceita -Conta $conta -Rotulo $rotulo)) { return }

    if (-not $cap.SetLocalUser -and -not $cap.NetExe -and $Clear) {
        Write-Log ERR 'Nenhum metodo disponivel para remover a senha (Set-LocalUser ausente e net.exe nao localizado).'
        $script:result = 'ERROR'
        return
    }

    Show-AvisoLogonAutomatico -Nome $Nome

    # --------------------------------------------------------------------------
    if ($Clear) {
        Write-Log WARN "OPERACAO SENSIVEL: removendo a senha da conta local '$Nome'."
        Write-Color ''
        Write-Color "  Conta que sera alterada: $Nome" -Color White
        Write-Color '  Uma conta sem senha permite logon local sem autenticacao.' -Color Yellow
        Write-Color '  Esta acao sera registrada no log de manutencao.' -Color Yellow
        Write-Color ''
        $c = Read-Host "  Digite exatamente REMOVER para confirmar (qualquer outra entrada cancela)"
        # -cne, nao -ne: a comparacao de cadeias do PowerShell ignora a caixa por
        # padrao, entao 'remover' e 'ReMoVeR' passavam por uma confirmacao cujo texto
        # promete "exatamente REMOVER". A friccao deliberada desta confirmacao so
        # existe se a palavra for exigida como escrita.
        if ($c -cne 'REMOVER') {
            Write-Log INFO 'Operacao cancelada pelo operador. Nenhuma senha foi alterada.'
            Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message "Remocao de senha da conta '$Nome' cancelada pelo operador."
            return
        }

        $antes    = Get-SenhaDefinidaEm -Nome $Nome
        $aplicado = $false
        $motivo   = ''

        if ($cap.SetLocalUser) {
            $r = Invoke-SafeCommand { Set-LocalUser -Name $Nome -Password ([securestring]::new()) -ErrorAction Stop } -Activity "Remover senha de $Nome"
            $aplicado = $r.Success
            if (-not $aplicado) { $motivo = "$($r.Error.Exception.Message)" }
        } else {
            # Queda para net.exe: aqui ela e segura porque a senha vazia vai na
            # propria linha de comando e nenhum prompt interativo e aberto.
            $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $cap.NetExe -Arguments @('user', ('"{0}"' -f $Nome), '""') -TimeoutSeconds 60 } -Activity "net user $Nome (remover senha)"
            if (-not $r.Success) {
                $motivo = "$($r.Error.Exception.Message)"
            } elseif ($r.Value.ExitCode -ne 0) {
                $motivo = ("net user retornou {0}: {1}" -f $r.Value.ExitCode, ("$($r.Value.StdErr)".Trim()))
            } else {
                $aplicado = $true
            }
        }

        if (-not $aplicado) {
            Write-Color ''
            Write-Color '  A senha NAO foi removida. Motivo informado pelo Windows:' -Color Red
            Write-Color ("  " + $motivo) -Color Red
            Write-Color ''
            Write-LogSeguranca -Acao $rotulo -Conta $Nome -Resultado 'falha' -Motivo $motivo -Nivel ERR
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Falha ao remover a senha da conta '$Nome'." -Recommendation 'Verificar a politica de senha e os privilegios administrativos.'
            $script:result = 'ERROR'
            return
        }

        $conf = Confirm-AlteracaoSenha -Nome $Nome -Antes $antes
        Write-LogSeguranca -Acao $rotulo -Conta $Nome -Resultado $conf.Estado -Motivo $conf.Detalhe -Nivel $(if ($conf.Estado -eq 'confirmado') { 'OK' } else { 'WARN' })
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' `
            -Message ("Senha removida da conta local '{0}' ({1})." -f $Nome, $(if ($conf.Estado -eq 'confirmado') { 'alteracao confirmada por releitura' } else { "sem confirmacao: $($conf.Detalhe)" })) `
            -Recommendation 'Definir uma nova senha assim que o acesso for restabelecido.'
        $script:result = 'WARN'
        return
    }

    # --------------------------------------------------------------------------
    Write-Color ''
    Write-Color "  Conta que sera alterada: $Nome" -Color White
    Write-Color '  A senha nao aparece na tela enquanto voce digita. Isso e normal.' -Color DarkGray
    Write-Color '  Anote a senha antes de digitar. Pressione Enter vazio para cancelar.' -Color DarkGray
    Write-Color ''

    $senha = $null
    $conf2 = $null
    try {
        $senha = Read-Host "  Nova senha para '$Nome'" -AsSecureString

        # Enter vazio e cancelamento, exatamente como a linha acima promete. Antes, a
        # entrada vazia so era avaliada depois da confirmacao e terminava em ERRO
        # tecnico, contrariando o texto exibido ao operador.
        if ($null -eq $senha -or $senha.Length -eq 0) {
            Write-Log INFO 'Operacao cancelada pelo operador (nenhuma senha digitada). Nada foi alterado.'
            Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message "Troca de senha da conta '$Nome' cancelada pelo operador."
            return
        }

        $conf2 = Read-Host "  Confirme a senha" -AsSecureString
        if (-not (Test-SecureStringIgual -A $senha -B $conf2)) {
            Write-Log ERR 'As senhas nao coincidem. Operacao cancelada. Nenhuma senha foi alterada.'
            $script:result = 'ERROR'
            return
        }
        $conf2.Dispose(); $conf2 = $null

        Write-Color ''
        Write-Color "  Confirmar a troca de senha da conta '$Nome'?" -Color Yellow
        $ok = Read-Host '  Digite S para confirmar (qualquer outra tecla cancela)'
        if ($ok -notmatch '^[Ss]$') {
            Write-Log INFO 'Operacao cancelada pelo operador. Nenhuma senha foi alterada.'
            Add-CompartDiskFinding -Severity INFO -Area 'Contas' -Message "Troca de senha da conta '$Nome' cancelada pelo operador."
            return
        }

        $antes    = Get-SenhaDefinidaEm -Nome $Nome
        $aplicado = $false
        $motivo   = ''
        $dicaAdsi = $null

        if ($cap.SetLocalUser) {
            $r = Invoke-SafeCommand { Set-LocalUser -Name $Nome -Password $senha -ErrorAction Stop } -Activity "Definir senha de $Nome"
            $aplicado = $r.Success
            if (-not $aplicado) { $motivo = "$($r.Error.Exception.Message)" }
        } else {
            # Sem o modulo LocalAccounts, a interface ADSI WinNT e o equivalente
            # nativo. net.exe NAO serve aqui: com a saida redirecionada por
            # Invoke-NativeCommand, o prompt de "net user <conta> *" ficaria invisivel
            # e a ferramenta pareceria travada.
            $r = Invoke-SafeCommand { Set-SenhaViaAdsi -Nome $Nome -Senha $senha } -Activity "ADSI SetPassword de $Nome"
            $aplicado = $r.Success
            if ($aplicado) { $dicaAdsi = $r.Value } else { $motivo = "$($r.Error.Exception.Message)" }
        }

        if (-not $aplicado) {
            # Requisitos de tamanho, complexidade e historico sao politica do Windows:
            # o modulo nao os reimplementa, apenas devolve a recusa com o motivo. Uma
            # senha recusada e erro de operacao, nao excecao nao tratada do modulo -
            # por isso nao sobe ate o catch global, que a marcaria como CRIT.
            Write-Color ''
            Write-Color '  A senha NAO foi alterada. Motivo informado pelo Windows:' -Color Red
            Write-Color ("  " + $motivo) -Color Red
            Write-Color '  Tamanho, complexidade e historico sao definidos pela politica do Windows.' -Color DarkGray
            Write-Color ''
            Write-LogSeguranca -Acao $rotulo -Conta $Nome -Resultado 'falha' -Motivo $motivo -Nivel ERR
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Falha ao redefinir a senha da conta '$Nome'." -Recommendation 'Verificar a politica de senha do Windows (net accounts) e repetir a operacao.'
            $script:result = 'ERROR'
            return
        }

        $verif = Confirm-AlteracaoSenha -Nome $Nome -Antes $antes -DicaAdsi $dicaAdsi
        Write-LogSeguranca -Acao $rotulo -Conta $Nome -Resultado $verif.Estado -Motivo $verif.Detalhe -Nivel $(if ($verif.Estado -eq 'confirmado') { 'OK' } else { 'WARN' })
        Write-Color ''
        Write-Color '  Guarde a senha em local seguro. Ela sera pedida no proximo login.' -Color Yellow
        Write-Color ''
        if ($verif.Estado -eq 'confirmado') {
            Add-CompartDiskFinding -Severity OK -Area 'Contas' -Message "Senha redefinida para a conta '$Nome' (confirmada por releitura)."
        } else {
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Senha da conta '$Nome' aplicada sem confirmacao ($($verif.Detalhe))." -Recommendation 'Testar o logon antes de encerrar a sessao atual.'
            $script:result = 'WARN'
        }
    } finally {
        # SecureString e IDisposable: descartar zera o buffer criptografado em vez de
        # deixa-lo residente ate a coleta de lixo.
        if ($conf2) { try { $conf2.Dispose() } catch { } }
        if ($senha) { try { $senha.Dispose() } catch { } }
    }
}

# ------------------------------------------------------------------------------
# Administrador interno
# ------------------------------------------------------------------------------
function Set-BuiltinAdmin {
    param([bool]$Habilitar)

    $cap       = Get-ContasCapability
    $rotulo    = $(if ($Habilitar) { 'EnableAdmin' }  else { 'DisableAdmin' })
    $acao      = $(if ($Habilitar) { 'habilitar' }    else { 'desabilitar' })
    $acaoFeita = $(if ($Habilitar) { 'habilitada' }   else { 'desabilitada' })

    if (-not $cap.Admin) {
        Write-Log ERR "$rotulo exige privilegio administrativo. Nenhuma alteracao foi feita."
        $script:result = 'ERROR'
        return
    }

    $admin = Get-BuiltinAdminAccount
    if (-not $admin.Encontrada) {
        Write-Log ERR "Conta interna de Administrador (SID -500) nao localizada: $($admin.Motivo)."
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Conta interna de Administrador nao localizada ($($admin.Motivo))." -Recommendation 'Confirmar a integridade do banco de contas locais (SAM).'
        $script:result = 'ERROR'
        return
    }

    # Guarda de escopo: a operacao so pode atingir a conta de RID 500. Uma conta
    # administrativa comum - inclusive uma renomeada para "Administrador" - nunca
    # chega aqui, porque a selecao e por SID e nunca por nome.
    if ("$($admin.SID)" -notmatch '-500$') {
        Write-Log ERR 'Selecao de conta inconsistente (SID sem RID 500). Operacao abortada.'
        $script:result = 'ERROR'
        return
    }
    $nome = $admin.Nome
    Write-Log INFO "Preparando para $acao a conta interna '$nome' (SID $($admin.SID))."

    # Idempotencia: estado ja correto e sucesso, nao uma nova alteracao.
    if ($null -ne $admin.Habilitado -and ([bool]$admin.Habilitado) -eq $Habilitar) {
        Write-LogSeguranca -Acao $rotulo -Conta $nome -Resultado 'sem-alteracao' -Motivo "a conta ja estava $acaoFeita" -Nivel OK
        Add-CompartDiskFinding -Severity $(if ($Habilitar) { 'WARN' } else { 'OK' }) -Area 'Contas' `
            -Message "Conta interna de Administrador '$nome' ja estava $acaoFeita." `
            -Recommendation $(if ($Habilitar) { 'Definir senha forte imediatamente e desabilitar apos o uso.' } else { '' })
        if ($Habilitar) { $script:result = 'WARN' }
        return
    }

    if ($Habilitar) {
        Write-Color ''
        Write-Color '  A conta interna de Administrador nao possui senha por padrao.' -Color Yellow
        Write-Color '  Recomendacao corporativa: manter desabilitada e usar contas nominais.' -Color Yellow
        Write-Color ''
    }

    $aplicado = $false
    $motivo   = ''

    if ($cap.EnableLocalUser) {
        # Preferencia por -SID: mesmo alvo identificado na deteccao, sem depender de o
        # nome permanecer inalterado entre a consulta e a alteracao. Se a conversao do
        # SID nao for possivel, usa-se o nome DA CONTA JA SELECIONADA PELO RID 500 - a
        # selecao continua sendo por SID, apenas a chamada muda de forma.
        $sidObj = $null
        try { $sidObj = [System.Security.Principal.SecurityIdentifier]$admin.SID } catch { }
        $r = Invoke-SafeCommand {
            if ($sidObj) {
                if ($Habilitar) { Enable-LocalUser -SID $sidObj -ErrorAction Stop }
                else            { Disable-LocalUser -SID $sidObj -ErrorAction Stop }
            } else {
                if ($Habilitar) { Enable-LocalUser -Name $nome -ErrorAction Stop }
                else            { Disable-LocalUser -Name $nome -ErrorAction Stop }
            }
        } -Activity "$acao conta $nome"
        $aplicado = $r.Success
        if (-not $aplicado) { $motivo = "$($r.Error.Exception.Message)" }
    } elseif ($cap.NetExe) {
        $flag = $(if ($Habilitar) { '/active:yes' } else { '/active:no' })
        $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $cap.NetExe -Arguments @('user', ('"{0}"' -f $nome), $flag) -TimeoutSeconds 60 } -Activity "net user $nome $flag"
        if (-not $r.Success) {
            $motivo = "$($r.Error.Exception.Message)"
        } elseif ($r.Value.ExitCode -ne 0) {
            $motivo = ("net user retornou {0}: {1}" -f $r.Value.ExitCode, ("$($r.Value.StdErr)".Trim()))
        } else {
            $aplicado = $true
        }
    } else {
        $motivo = 'nenhum metodo disponivel (cmdlets LocalAccounts ausentes e net.exe nao localizado)'
    }

    if (-not $aplicado) {
        Write-Log ERR ("Falha ao {0} a conta interna '{1}': {2}" -f $acao, $nome, $motivo)
        Write-LogSeguranca -Acao $rotulo -Conta $nome -Resultado 'falha' -Motivo $motivo -Nivel ERR
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Nao foi possivel $acao a conta interna de Administrador '$nome'." -Recommendation 'Verificar diretiva de grupo e privilegios administrativos.'
        $script:result = 'ERROR'
        return
    }

    # Releitura obrigatoria: "o cmdlet nao lancou" nao prova que o estado mudou.
    [void](Get-LocalUserSidIndex -Refresh)
    $novo    = Get-BuiltinAdminAccount
    $estado  = 'nao-confirmado'
    $detalhe = 'estado posterior nao pode ser lido'
    if ($novo.Encontrada -and $null -ne $novo.Habilitado) {
        if (([bool]$novo.Habilitado) -eq $Habilitar) { $estado = 'confirmado'; $detalhe = '' }
        else { $estado = 'divergente'; $detalhe = "a conta continua $(if ($novo.Habilitado) { 'habilitada' } else { 'desabilitada' })" }
    }

    if ($estado -eq 'divergente') {
        Write-Log ERR ("A conta interna '{0}' NAO foi {1}: {2}." -f $nome, $acaoFeita, $detalhe)
        Write-LogSeguranca -Acao $rotulo -Conta $nome -Resultado 'falha' -Motivo $detalhe -Nivel ERR
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "A conta interna de Administrador '$nome' nao foi $acaoFeita ($detalhe)." -Recommendation 'Verificar diretiva de grupo que force o estado da conta.'
        $script:result = 'ERROR'
        return
    }

    Write-LogSeguranca -Acao $rotulo -Conta $nome -Resultado $estado -Motivo $detalhe -Nivel $(if ($estado -eq 'confirmado') { 'OK' } else { 'WARN' })
    Write-Log OK "Conta '$nome' $acaoFeita por $($Global:CompartDisk.User)."

    if ($Habilitar) {
        Write-Color ''
        Write-Color '  DEFINA UMA SENHA FORTE PARA ESTA CONTA IMEDIATAMENTE.' -Color Yellow
        Write-Color '  Ate la, qualquer pessoa com acesso fisico entra por ela sem digitar nada.' -Color Yellow
        Write-Color '  Desabilite a conta assim que terminar de usa-la.' -Color Yellow
        Write-Color ''
        # A conta fica habilitada e, por padrao, sem senha: e condicao relevante de
        # seguranca mesmo quando a operacao foi bem-sucedida.
        $script:result = 'WARN'
    }

    $sufixo = $(if ($estado -eq 'confirmado') { 'estado confirmado por releitura' } else { "estado nao confirmado: $detalhe" })
    Add-CompartDiskFinding -Severity $(if ($Habilitar) { 'WARN' } else { 'OK' }) -Area 'Contas' `
        -Message "Conta interna de Administrador '$nome' foi $acaoFeita ($sufixo)." `
        -Recommendation $(if ($Habilitar) { 'Definir senha forte imediatamente e desabilitar apos o uso.' } else { '' })
    if ($estado -ne 'confirmado' -and -not $Habilitar) { $script:result = 'WARN' }
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('ClearPassword', 'SetPassword', 'EnableAdmin', 'DisableAdmin') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Users' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # O estado persistido em state_Users_<Acao>.json vem de $result, e o finally
        # roda mesmo com este exit. Sair sem marcar o resultado gravava
        # "Resultado=OK" para uma execucao RECUSADA por falta de privilegio, e o
        # relatorio consolidado herdava esse OK enquanto o processo devolvia 2.
        $result = 'ERROR'
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'List'          { Show-Users }
        'Groups'        { Show-Groups }
        'Audit'         { Show-Audit }
        'ClearPassword' { Set-UserPassword -Nome $User -Clear }
        'SetPassword'   { Set-UserPassword -Nome $User }
        'EnableAdmin'   { Set-BuiltinAdmin -Habilitar $true }
        'DisableAdmin'  { Set-BuiltinAdmin -Habilitar $false }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Users (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Contas' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
