<#
 COMPARTDISK 1.4.2 - Smart.ps1
 Desenvolvido por Edsilas
 Acoes: Status | Detail | Volumes | Shadow | Spaces
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Detail', 'Volumes', 'Shadow', 'Spaces')]
    [string]$Action = 'Status',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

# ==============================================================================
# ESTADO GLOBAL
# Monotonico: OK -> WARN -> ERROR, e nunca regride.
#
# Antes, cada funcao atribuia o resultado diretamente. Em Detail, Show-DiskHealth
# podia marcar ERROR por nao conseguir enumerar disco algum e a analise de
# contadores logo abaixo rebaixava para WARN: o modulo devolvia "atencao" ao
# Launcher para uma execucao em que nenhum disco foi sequer identificado.
# Mesmo padrao ja adotado por Drivers.ps1, Debloat.ps1 e Repair.ps1.
# ==============================================================================
$script:result = 'OK'
$script:ResultRank = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }

function Set-SmartResult {
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Position = 1)][string]$Reason = ''
    )
    if ($script:ResultRank[$Level] -gt $script:ResultRank[$script:result]) {
        $script:result = $Level
        Write-Log DEBUG ("Resultado do modulo elevado para {0}{1}" -f $Level, $(if ($Reason) { ": $Reason" } else { '' })) -NoConsole
    }
}

function Write-SmartTable {
    <# -Quiet reduz APENAS a saida interativa. Logs, findings, sections e
       resultado permanecem inalterados.

       Antes, as tabelas eram emitidas com "| Out-String | Write-Output", o que
       coloca texto no stream de sucesso do script e ignora completamente o
       -Quiet: o modo silencioso continuava despejando tabelas no console. #>
    param([object[]]$Rows, [switch]$Lista)
    if ($script:Quiet) { return }
    $dados = @($Rows | Where-Object { $null -ne $_ })
    if ($dados.Count -eq 0) { return }
    try {
        $texto = $(if ($Lista) { $dados | Format-List | Out-String -Width 200 }
                   else        { $dados | Format-Table -AutoSize | Out-String -Width 240 })
        foreach ($linha in ($texto -split "`r?`n")) {
            if ($linha.Trim()) { Write-Color ("  " + $linha) }
        }
    } catch {
        Write-Log DEBUG "Falha ao formatar tabela para exibicao: $($_.Exception.Message)" -NoConsole
    }
}

function ConvertTo-SmartPercent {
    <# Percentual a partir de texto, sem lancar e sem inventar zero.
       Devolve $null quando o valor nao pode ser interpretado.

       Antes, Show-Volumes fazia [double]("$($v.UsadoPct)" -replace '%',''):
       qualquer valor nao numerico lancava excecao, o catch global marcava o
       modulo inteiro como ERROR e os volumes restantes deixavam de ser
       analisados. #>
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return $null }
    $t = "$Valor".Trim().TrimEnd('%').Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    $d = 0.0
    # A cultura corrente vem primeiro porque o valor foi formatado por ela;
    # a invariante cobre origem que use ponto decimal.
    if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::CurrentCulture, [ref]$d)) { return $d }
    if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function ConvertTo-SmartInteiro {
    <# Inteiro nao negativo, ou $null. Contador ausente nao vira zero: zero
       significa "nenhum erro", e isso e uma afirmacao que o modulo nao pode
       fazer quando o dado nao existe. #>
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return $null }
    $t = "$Valor".Trim()
    if ($t -notmatch '^\d+$') { return $null }
    $n = 0
    if ([int]::TryParse($t, [ref]$n)) { return $n }
    return $null
}

# Contadores de confiabilidade coletados UMA vez por execucao. Status e Detail
# liam os mesmos discos duas vezes: Get-CompartDiskDiskInfo ja consulta
# Get-PhysicalDisk e Get-StorageReliabilityCounter por disco, e Show-Detail
# repetia as duas consultas logo em seguida.
$script:CacheConfiab = $null

function Get-SmartConfiabilidade {
    <# Mapa DeviceId -> { Disco, Bus, Midia, Contador, Erro }. Uma falha em um
       disco nao interrompe os demais e nao desaparece: fica registrada no
       proprio mapa para o relatorio poder mostra-la. #>
    [CmdletBinding()] param()
    if ($null -ne $script:CacheConfiab) { return $script:CacheConfiab }

    $mapa = @{}
    $disponivel = (Test-CompartDiskCommand 'Get-PhysicalDisk') -and (Test-CompartDiskCommand 'Get-StorageReliabilityCounter')
    if (-not $disponivel) {
        $script:CacheConfiab = [pscustomobject]@{ Disponivel = $false; Mapa = $mapa }
        return $script:CacheConfiab
    }

    $fisicos = @()
    $r = Invoke-SafeCommand { @(Get-PhysicalDisk -ErrorAction Stop) } -Activity 'Get-PhysicalDisk' -Silent
    if ($r.Success -and $null -ne $r.Value) { $fisicos = @($r.Value) }
    else { Write-Log WARN 'Nao foi possivel enumerar discos fisicos pelo subsistema de armazenamento.' -ErrorRecord $r.Error }

    foreach ($d in $fisicos) {
        $id = "$($d.DeviceId)"
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $rc = Invoke-SafeCommand { $d | Get-StorageReliabilityCounter -ErrorAction Stop } -Activity "Contadores de $id" -Silent
        $mapa[$id] = [pscustomobject]@{
            Disco     = "$($d.FriendlyName)"
            Bus       = "$($d.BusType)"
            Midia     = "$($d.MediaType)"
            Contador  = $(if ($rc.Success) { $rc.Value } else { $null })
            Erro      = $(if (-not $rc.Success -and $rc.Error) { $rc.Error.Exception.Message } else { '' })
        }
    }
    $script:CacheConfiab = [pscustomobject]@{ Disponivel = $true; Mapa = $mapa }
    return $script:CacheConfiab
}

function Get-SmartEvidencia {
    <# Classifica QUE evidencia existe para aquele disco. Distingue leitura de
       atributo SMART do estado agregado que o controlador publica.

       Antes, um disco USB cujo controlador nao expoe SMART reportava
       HealthStatus 'Healthy' e o modulo emitia "Disco X: saude Healthy" como se
       tivesse lido atributos - um falso negativo silencioso em exatamente o
       caso que mais precisa de aviso. #>
    param([Parameter(Mandatory)][object]$Disco, [object]$Confiab)

    $temPredicao = ($Disco.PSObject.Properties['SMART_Falha'] -and "$($Disco.SMART_Falha)" -in @('SIM', 'Nao'))
    $temContador = $false
    if ($Confiab -and $Confiab.Contador) {
        foreach ($p in @('PowerOnHours', 'Temperature', 'ReadErrorsTotal', 'Wear')) {
            if ($null -ne $Confiab.Contador.$p) { $temContador = $true; break }
        }
    }

    if ($temPredicao -and $temContador) { return 'SMART completo (predicao de falha + contadores de confiabilidade)' }
    if ($temPredicao)                   { return 'SMART parcial (predicao de falha do controlador)' }
    if ($temContador)                   { return 'Contadores de confiabilidade do subsistema de armazenamento' }
    return ''
}

function Show-DiskHealth {
    $discos = @(Get-CompartDiskDiskInfo)
    if ($discos.Count -eq 0) {
        Write-Log ERR 'Nao foi possivel enumerar discos fisicos (WMI/Storage inoperantes).'
        Add-CompartDiskSection -Title 'Discos fisicos' -Status CRIT -Summary 'Nenhum disco enumerado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Disco' `
            -Message 'Nenhum disco fisico pode ser enumerado: o diagnostico de saude nao pode ser realizado.' `
            -Recommendation 'Validar o repositorio WMI (winmgmt) e o servico de armazenamento, e repetir a consulta.'
        Set-SmartResult 'ERROR' 'nenhum disco enumerado'
        return
    }

    $confiab = Get-SmartConfiabilidade
    $linhas  = New-Object System.Collections.ArrayList
    $piorStatus = 'OK'
    $semSuporte = 0

    foreach ($d in $discos) {
        $saude = "$($d.Saude)"
        $id    = "$($d.Id)"
        $c     = $(if ($confiab.Mapa.ContainsKey($id)) { $confiab.Mapa[$id] } else { $null })
        $evid  = Get-SmartEvidencia -Disco $d -Confiab $c
        $bus   = "$($d.Barramento)"
        $nvme  = ($bus -match '(?i)nvme')

        # Estado por disco, com vocabulario explicito. 'Healthy' vindo apenas do
        # agregado do controlador nao e o mesmo que atributo SMART lido.
        $estado = 'Unknown'
        $sev    = 'INFO'
        $msg    = ''
        $rec    = ''

        if ($saude -match 'Unhealthy|Warning|Pred Fail|Degraded|Error|NonRecover|Lost Comm|No Contact') {
            $estado = 'Critical'; $sev = 'CRIT'
            $msg = "Disco '$($d.Modelo)' com saude '$saude'."
            $rec = 'Fazer backup imediato e planejar substituicao.'
            Set-SmartResult 'WARN' "disco em estado '$saude'"
        }
        elseif ($saude -match 'Healthy|^OK$') {
            if ($evid) {
                $estado = 'Healthy'; $sev = 'OK'
                $msg = "Disco '$($d.Modelo)': saude $saude, confirmada por $evid."
            } else {
                # Sem nenhuma evidencia SMART, tudo o que se pode afirmar e que o
                # controlador nao reporta problema.
                $estado = 'NotSupported'; $sev = 'INFO'; $semSuporte++
                $msg = "Disco '$($d.Modelo)': o controlador reporta '$saude', porem nenhum atributo SMART pode ser lido."
                $rec = 'Comum em gaveta USB, controladora RAID e disco virtual, que nao repassam SMART ao Windows. O estado real do disco nao pode ser confirmado por esta ferramenta.'
            }
        }
        else {
            $estado = 'Unknown'; $sev = 'INFO'
            $msg = "Disco '$($d.Modelo)' com saude nao classificada: '$saude'."
            $rec = 'Conferir o estado do disco no utilitario do fabricante.'
        }

        if ($rec) { Add-CompartDiskFinding -Severity $sev -Area 'Disco' -Message $msg -Recommendation $rec }
        else      { Add-CompartDiskFinding -Severity $sev -Area 'Disco' -Message $msg }
        if ($sev -eq 'CRIT') { $piorStatus = 'CRIT' }
        elseif ($sev -eq 'WARN' -and $piorStatus -eq 'OK') { $piorStatus = 'WARN' }

        # Predicao de falha do proprio dispositivo: o sinal mais forte disponivel.
        if ($d.PSObject.Properties['SMART_Falha'] -and $d.SMART_Falha -eq 'SIM') {
            $estado = 'Critical'; $piorStatus = 'CRIT'
            Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "SMART preve falha iminente em '$($d.Modelo)'." -Recommendation 'Substituir o disco com urgencia apos backup completo.'
            Set-SmartResult 'WARN' 'predicao de falha SMART'
        }

        # Desgaste. Em NVMe o contador corresponde ao Percentage Used da
        # especificacao; em SSD SATA e o desgaste reportado pelo controlador.
        # Antes o padrao exigia '^(\d+)%$', o que descartava silenciosamente
        # qualquer valor fracionario como '12,5%'.
        $w = ConvertTo-SmartPercent $d.Desgaste
        if ($null -ne $w) {
            $rotulo = $(if ($nvme) { 'Percentage Used (NVMe)' } else { 'desgaste' })
            if ($w -ge 80) {
                Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message ("Disco '{0}' com {1} de {2}." -f $d.Modelo, "$w%", $rotulo) -Recommendation 'Planejar substituicao.'
                $piorStatus = 'CRIT'
                Set-SmartResult 'WARN' 'desgaste elevado'
            } elseif ($w -ge 50) {
                Add-CompartDiskFinding -Severity WARN -Area 'Disco' -Message ("Disco '{0}' com {1} de {2}." -f $d.Modelo, "$w%", $rotulo)
                if ($piorStatus -eq 'OK') { $piorStatus = 'WARN' }
            }
        }

        [void]$linhas.Add([pscustomobject]@{
            Id          = $d.Id
            Modelo      = $d.Modelo
            Barramento  = $bus
            Midia       = $d.Midia
            Tamanho     = $d.Tamanho
            Saude       = $saude
            Estado      = $estado
            Evidencia   = $(if ($evid) { $evid } else { 'nenhuma leitura SMART disponivel' })
            Fonte       = $d.Fonte
            Temperatura = $d.Temperatura
            HorasLigado = $d.HorasLigado
            Desgaste    = $d.Desgaste
        })
    }

    Write-Color ''
    Write-SmartTable -Rows @($linhas)
    Add-CompartDiskSection -Title 'Discos fisicos' -Status $piorStatus -Rows @($linhas) `
        -Summary ("{0} disco(s); {1} sem leitura SMART" -f $discos.Count, $semSuporte) `
        -Pairs ([ordered]@{
            'Discos enumerados'      = $discos.Count
            'Sem leitura SMART'      = $semSuporte
            'Metodo de enumeracao'   = @($discos | ForEach-Object { "$($_.Fonte)" } | Sort-Object -Unique) -join ', '
            'Contadores disponiveis' = $(if ($confiab.Disponivel) { 'Sim' } else { 'Nao (Get-StorageReliabilityCounter indisponivel)' })
        })

    if ($semSuporte -gt 0) {
        Write-Log INFO ("{0} disco(s) nao expoem atributos SMART ao Windows." -f $semSuporte)
    }
    Write-Log INFO 'Nota: HealthStatus reflete o agregado reportado pelo controlador; nao substitui a leitura completa de atributos SMART do fabricante.'
    Write-Log OK 'Saude dos discos avaliada.'
}

function Show-Detail {
    Show-DiskHealth

    $confiab = Get-SmartConfiabilidade
    if (-not $confiab.Disponivel) {
        Write-Log WARN 'Contadores de confiabilidade indisponiveis nesta plataforma.'
        Add-CompartDiskSection -Title 'Contadores de confiabilidade' -Status WARN `
            -Summary 'Get-StorageReliabilityCounter indisponivel'
        Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
            -Message 'Os contadores de confiabilidade nao estao disponiveis nesta plataforma: o detalhamento de horas, temperatura e erros nao pode ser coletado.' `
            -Recommendation 'A avaliacao de saude permanece limitada ao estado agregado do controlador.'
        Set-SmartResult 'WARN' 'contadores indisponiveis'
        return
    }

    $rows   = New-Object System.Collections.ArrayList
    $falhas = New-Object System.Collections.ArrayList
    $piorStatus = 'OK'

    foreach ($id in ($confiab.Mapa.Keys | Sort-Object)) {
        $e = $confiab.Mapa[$id]
        # Antes, a falha por disco era engolida com "catch { continue }": nenhum
        # log, nenhum finding. Com todos os discos falhando, a funcao terminava
        # em silencio e o modulo reportava OK.
        if (-not $e.Contador) {
            [void]$falhas.Add([pscustomobject]@{
                Disco  = $e.Disco
                Motivo = $(if ($e.Erro) { $e.Erro } else { 'o dispositivo nao devolveu contadores' })
            })
            continue
        }
        $r = $e.Contador
        $nvme = ("$($e.Bus)" -match '(?i)nvme')

        [void]$rows.Add([pscustomobject]@{
            Disco            = $e.Disco
            Barramento       = $e.Bus
            Temperatura      = $(if ($null -ne $r.Temperature) { "$($r.Temperature) C" } else { 'n/d' })
            TempMaxima       = $(if ($null -ne $r.TemperatureMax) { "$($r.TemperatureMax) C" } else { 'n/d' })
            HorasLigado      = $(if ($null -ne $r.PowerOnHours) { $r.PowerOnHours } else { 'n/d' })
            CiclosStartStop  = $(if ($null -ne $r.StartStopCycleCount) { $r.StartStopCycleCount } else { 'n/d' })
            ErrosLeitura     = $(if ($null -ne $r.ReadErrorsTotal) { $r.ReadErrorsTotal } else { 'n/d' })
            ErrosLeituraCorr = $(if ($null -ne $r.ReadErrorsCorrected) { $r.ReadErrorsCorrected } else { 'n/d' })
            ErrosEscrita     = $(if ($null -ne $r.WriteErrorsTotal) { $r.WriteErrorsTotal } else { 'n/d' })
            ErrosNaoCorrig   = $(if ($null -ne $r.ReadErrorsUncorrected) { $r.ReadErrorsUncorrected } else { 'n/d' })
            Desgaste         = $(if ($null -ne $r.Wear) { "$($r.Wear)%" } else { 'n/d' })
            Indicador        = $(if ($nvme) { 'Desgaste = Percentage Used (NVMe)' } else { 'Desgaste reportado pelo controlador' })
        })
    }

    if ($rows.Count -gt 0) {
        Write-Color ''
        Write-SmartTable -Rows @($rows) -Lista

        foreach ($r in $rows) {
            # Contador ausente permanece ausente: 'n/d' nao vira zero, porque
            # zero afirmaria que nao ha erro algum.
            $naoCorrig = ConvertTo-SmartInteiro $r.ErrosNaoCorrig
            if ($null -ne $naoCorrig -and $naoCorrig -gt 0) {
                Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Disco '$($r.Disco)' com erros de leitura nao corrigidos." -Recommendation 'Backup imediato e substituicao.'
                Set-SmartResult 'WARN' 'erros de leitura nao corrigidos'
                $piorStatus = 'CRIT'
            }
            $temp = ConvertTo-SmartInteiro ("$($r.Temperatura)" -replace '\s*C$', '')
            if ($null -ne $temp -and $temp -ge 65) {
                Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
                    -Message "Disco '$($r.Disco)' operando a $temp C." `
                    -Recommendation 'Verificar ventilacao e fluxo de ar. Temperatura alta reduz a vida util do dispositivo.'
                Set-SmartResult 'WARN' 'temperatura elevada'
                if ($piorStatus -eq 'OK') { $piorStatus = 'WARN' }
            }
        }
    }

    if ($falhas.Count -gt 0) {
        if ($piorStatus -eq 'OK') { $piorStatus = 'WARN' }
        Write-Log WARN ("{0} disco(s) nao devolveram contadores de confiabilidade." -f $falhas.Count)
        Write-SmartTable -Rows @($falhas)
        Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
            -Message ("{0} disco(s) nao devolveram contadores de confiabilidade: o detalhamento desses dispositivos esta incompleto." -f $falhas.Count) `
            -Recommendation 'Comum em gaveta USB, controladora RAID e disco virtual. O estado desses discos nao pode ser confirmado aqui.'
        Set-SmartResult 'WARN' 'contadores parciais'
    }

    if ($rows.Count -eq 0 -and $falhas.Count -eq 0) {
        Write-Log WARN 'Nenhum disco devolveu contadores de confiabilidade.'
        Add-CompartDiskSection -Title 'Contadores de confiabilidade' -Status WARN -Summary 'Nenhum dado coletado'
        Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
            -Message 'Nenhum disco devolveu contadores de confiabilidade.' `
            -Recommendation 'Verificar se o subsistema de armazenamento responde e se ha privilegio suficiente.'
        Set-SmartResult 'WARN' 'nenhum contador coletado'
        return
    }

    Add-CompartDiskSection -Title 'Contadores de confiabilidade' -Status $piorStatus -Rows @($rows) `
        -Summary ("{0} disco(s) com contadores, {1} sem" -f $rows.Count, $falhas.Count) `
        -Pairs ([ordered]@{
            'Discos com contadores' = $rows.Count
            'Discos sem contadores' = $falhas.Count
            'Observacao'            = 'Available Spare, Critical Warning e Media Errors do NVMe nao sao expostos pelo subsistema nativo do Windows e nao constam deste relatorio.'
        })
}

function Show-Volumes {
    $vols = @(Get-CompartDiskVolumeInfo)
    if ($vols.Count -eq 0) {
        # Antes, a lista vazia produzia uma secao vazia com status OK e nenhum
        # log: a falha de coleta desaparecia do relatorio.
        Write-Log ERR 'Nenhum volume logico pode ser enumerado.'
        Add-CompartDiskSection -Title 'Volumes logicos' -Status CRIT -Summary 'Nenhum volume enumerado'
        Add-CompartDiskFinding -Severity CRIT -Area 'Disco' `
            -Message 'Nenhum volume logico pode ser enumerado: a analise de espaco nao pode ser realizada.' `
            -Recommendation 'Validar o repositorio WMI (winmgmt) e repetir a consulta.'
        Set-SmartResult 'ERROR' 'nenhum volume enumerado'
        return
    }

    Write-Color ''
    Write-SmartTable -Rows $vols

    $piorStatus = 'OK'
    $semLeitura = 0
    foreach ($v in $vols) {
        # ConvertTo-SmartPercent devolve $null em vez de lancar: um volume com
        # percentual ilegivel deixava de analisar TODOS os volumes seguintes,
        # porque a excecao subia ate o catch global do modulo.
        $pct = ConvertTo-SmartPercent $v.UsadoPct
        if ($null -eq $pct) {
            $semLeitura++
            Add-CompartDiskFinding -Severity INFO -Area 'Disco' `
                -Message "Volume $($v.Volume): percentual de uso nao pode ser interpretado ('$($v.UsadoPct)')." `
                -Recommendation 'O espaco deste volume nao foi avaliado nesta execucao.'
            if ($piorStatus -eq 'OK') { $piorStatus = 'WARN' }
            continue
        }
        if ($pct -ge 95) {
            Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Volume $($v.Volume) com $pct% de uso." -Recommendation 'Liberar espaco imediatamente: risco de instabilidade do Windows.'
            Set-SmartResult 'WARN' "volume $($v.Volume) quase cheio"
            $piorStatus = 'CRIT'
        } elseif ($pct -ge 85) {
            Add-CompartDiskFinding -Severity WARN -Area 'Disco' -Message "Volume $($v.Volume) com $pct% de uso." -Recommendation 'Executar a limpeza profunda.'
            if ($piorStatus -eq 'OK') { $piorStatus = 'WARN' }
        } else {
            Add-CompartDiskFinding -Severity OK -Area 'Disco' -Message "Volume $($v.Volume): $($v.Livre) livres."
        }
    }
    Add-CompartDiskSection -Title 'Volumes logicos' -Status $piorStatus -Rows $vols `
        -Summary ("{0} volume(s) analisado(s)" -f $vols.Count) `
        -Pairs ([ordered]@{
            'Volumes enumerados'      = $vols.Count
            'Sem percentual legivel'  = $semLeitura
        })

    if (Test-CompartDiskCommand 'Get-Volume') {
        $rows = New-Object System.Collections.ArrayList
        $vv = Invoke-SafeCommand { @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter }) } -Activity 'Get-Volume' -Silent
        if (-not $vv.Success) {
            Write-Log WARN 'O estado dos volumes pelo subsistema de armazenamento nao pode ser consultado.' -ErrorRecord $vv.Error
            Set-SmartResult 'WARN' 'Get-Volume falhou'
        }
        foreach ($v in @($vv.Value)) {
            [void]$rows.Add([pscustomobject]@{
                Letra = $v.DriveLetter; Rotulo = $v.FileSystemLabel; Sistema = $v.FileSystem
                Saude = "$($v.HealthStatus)"; Operacional = "$($v.OperationalStatus)"
                # Get-Partition nao expoe tamanho de cluster; .Size e o tamanho da
                # particao - a coluna publicava um numero que nao era o que o rotulo
                # dizia, e duplicava a tabela de volumes logicos.
                TamanhoCluster = $(if ($v.PSObject.Properties['AllocationUnitSize'] -and $v.AllocationUnitSize) { "$($v.AllocationUnitSize) bytes" } else { 'n/d' })
            })
        }
        if ($rows.Count -gt 0) {
            # Saude por volume: 'Healthy' e o unico estado que nao exige atencao.
            $piorVol = 'OK'
            foreach ($rv in $rows) {
                if ("$($rv.Saude)" -and "$($rv.Saude)" -notmatch '(?i)^healthy$') {
                    Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
                        -Message "Volume $($rv.Letra): estado '$($rv.Saude)' / operacional '$($rv.Operacional)'." `
                        -Recommendation 'Verificar o sistema de arquivos deste volume com a acao Chkdsk do modulo Repair.'
                    Set-SmartResult 'WARN' "volume $($rv.Letra) nao saudavel"
                    $piorVol = 'WARN'
                }
            }
            Add-CompartDiskSection -Title 'Estado dos volumes (Storage)' -Status $piorVol -Rows @($rows)
        }
    }
    Write-Log OK 'Volumes analisados.'
}

function Show-Shadow {
    $s = @(Get-CompartDiskShadowCopies)
    if ($s.Count -eq 0) {
        Write-Log INFO 'Nenhuma copia de sombra (Shadow Copy) presente.'
        Add-CompartDiskSection -Title 'Copias de sombra' -Status INFO -Summary 'Nenhuma copia presente'
        Add-CompartDiskFinding -Severity INFO -Area 'Disco' -Message 'Nenhum ponto de restauracao/shadow copy encontrado.' -Recommendation 'Considerar habilitar a Protecao do Sistema para recuperacao rapida.'
        return
    }
    Write-SmartTable -Rows $s
    Add-CompartDiskSection -Title 'Copias de sombra' -Status INFO -Rows $s -Summary "$($s.Count) copia(s)"
    Write-Log OK "$($s.Count) copia(s) de sombra listada(s)."
}

function Show-Spaces {
    if (-not (Test-CompartDiskCommand 'Get-StoragePool')) {
        Write-Log WARN 'Storage Spaces indisponivel nesta plataforma.'
        Add-CompartDiskSection -Title 'Storage Spaces' -Status INFO -Summary 'Recurso indisponivel nesta plataforma'
        # UNSUPPORTED e um desfecho proprio no vocabulario do projeto (codigo 3)
        # e nao entra no ranking OK/WARN/ERROR. So e aplicado quando nada pior
        # foi registrado antes, para nao mascarar uma falha ja detectada.
        if ($script:result -eq 'OK') { $script:result = 'UNSUPPORTED' }
        return
    }
    $rp = Invoke-SafeCommand { @(Get-StoragePool -ErrorAction Stop | Where-Object { -not $_.IsPrimordial }) } -Activity 'Get-StoragePool' -Silent
    if (-not $rp.Success) {
        Write-Log WARN 'Nao foi possivel consultar os pools de armazenamento.' -ErrorRecord $rp.Error
        Add-CompartDiskSection -Title 'Storage Spaces' -Status WARN -Summary 'Consulta nao concluida'
        Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
            -Message 'A consulta de pools de armazenamento nao pode ser concluida.' `
            -Recommendation 'Verificar o servico de armazenamento e o privilegio da sessao.'
        Set-SmartResult 'WARN' 'consulta de pools falhou'
        return
    }
    $pools = @($rp.Value)
    if ($pools.Count -eq 0) {
        Write-Log INFO 'Nenhum pool de armazenamento configurado.'
        Add-CompartDiskSection -Title 'Storage Spaces' -Status INFO -Summary 'Nenhum pool configurado'
        return
    }
    $rows = @($pools | ForEach-Object {
        [pscustomobject]@{
            Pool = $_.FriendlyName; Saude = "$($_.HealthStatus)"; Operacional = "$($_.OperationalStatus)"
            Tamanho = (ConvertTo-CompartDiskSize $_.Size); Alocado = (ConvertTo-CompartDiskSize $_.AllocatedSize)
        }
    })
    $piorPool = 'OK'
    foreach ($p in $rows) {
        if ("$($p.Saude)" -notmatch '(?i)^healthy$') {
            Add-CompartDiskFinding -Severity WARN -Area 'Disco' `
                -Message "Pool '$($p.Pool)' com saude '$($p.Saude)' e estado operacional '$($p.Operacional)'." `
                -Recommendation 'Verificar os discos que compoem o pool antes de gravar novos dados.'
            Set-SmartResult 'WARN' "pool $($p.Pool) nao saudavel"
            $piorPool = 'WARN'
        }
    }
    Write-SmartTable -Rows $rows
    Add-CompartDiskSection -Title 'Storage Spaces' -Status $piorPool -Rows $rows -Summary ("{0} pool(s)" -f $rows.Count)
}

$codigo = $Global:CompartDisk.Exit.ERROR
try {
    if (-not (Start-CompartDiskModule -Name 'Smart' -Action $Action -Quiet:$Quiet)) {
        # O exit direto anterior disparava o finally com o estado ainda em 'OK':
        # o modulo saia com codigo de erro e gravava state_Smart_*.json dizendo
        # OK, e o relatorio consolidado nao via a falha.
        Set-SmartResult 'ERROR' 'modulo nao pode ser iniciado'
    } else {
        switch ($Action) {
            'Status'  { Show-DiskHealth }
            'Detail'  { Show-Detail }
            'Volumes' { Show-Volumes }
            'Shadow'  { Show-Shadow }
            'Spaces'  { Show-Spaces }
        }
    }
} catch {
    Set-SmartResult 'ERROR' 'excecao nao tratada'
    Write-Log ERR "Falha nao tratada no modulo Smart (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Disco' -Message "Excecao no modulo: $($_.Exception.Message)" `
        -Recommendation 'Consultar o log detalhado da sessao. Os discos ja analisados antes da falha constam do relatorio.'
} finally {
    $codigo = Stop-CompartDiskModule -Result $script:result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$script:result] }
}
exit ([int]$codigo)
