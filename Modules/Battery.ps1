<#
 COMPARTDISK 1.4.6 - Battery.ps1
 Desenvolvido por Edsilas
 Acoes: Info | Report | Sleep
#>
[CmdletBinding()]
param(
    [ValidateSet('Info', 'Report', 'Sleep')]
    [string]$Action = 'Info',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'
$powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'

function Set-BatteryResult {
    <# O resultado escala e nunca regride: sem isso o estado final seria o da ultima
       bateria avaliada, e uma bateria saudavel apagaria o aviso de outra degradada. #>
    param([ValidateSet('OK', 'WARN', 'ERROR')][string]$Estado)
    $peso = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }
    if ($peso[$Estado] -gt $peso["$($script:result)"]) { $script:result = $Estado }
}

function Get-BatteryNumero {
    <# Converte para numero somente quando o valor E numerico e finito. Devolve
       $null caso contrario, para que nenhum calculo prossiga sobre dado ausente. #>
    param([AllowNull()][object]$Valor)
    if ($null -eq $Valor) { return $null }
    $t = "$Valor".Trim()
    if ($t -eq '' -or $t -eq 'n/d') { return $null }
    $n = 0.0
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
        return $n
    }
    return $null
}

function Test-Bateria {
    <# Devolve { Ok, Baterias, Erro }.

       Consulta que FALHA e ausencia de bateria sao coisas diferentes:
       Get-CompartDiskCim devolve $null nos dois casos, e a versao anterior
       publicava "Nenhuma bateria presente no sistema" tambem quando o repositorio
       WMI recusava a leitura num notebook. -ThrowOnError separa os dois. #>
    $out = [pscustomobject]@{ Ok = $false; Baterias = @(); Erro = '' }
    $r = Invoke-SafeCommand { Get-CompartDiskCim -Class Win32_Battery -ThrowOnError } -Activity 'Win32_Battery' -Silent
    if (-not $r.Success) {
        $out.Erro = $(if ($r.Error) { "$($r.Error.Exception.Message)" } else { 'falha nao identificada' })
        Write-Log WARN ("A consulta de bateria falhou: {0}" -f $out.Erro)
        Add-CompartDiskFinding -Severity WARN -Area 'Bateria' `
            -Message ("Presenca de bateria nao verificada: a consulta ao WMI falhou ({0})." -f $out.Erro) `
            -Recommendation 'Validar o repositorio WMI (winmgmt /verifyrepository). A ausencia de resposta nao significa ausencia de bateria.'
        Set-BatteryResult 'WARN'
        return $out
    }
    $out.Ok = $true
    $out.Baterias = @(@($r.Value) | Where-Object { $null -ne $_ })
    if ($out.Baterias.Count -eq 0) {
        Write-Log WARN 'Nenhuma bateria detectada (desktop ou bateria ausente).'
        Add-CompartDiskFinding -Severity INFO -Area 'Bateria' -Message 'Nenhuma bateria presente no sistema.'
    }
    return $out
}

function Get-BatteryCapacidades {
    <# Capacidade projetada e capacidade de carga total, consultadas UMA vez por
       execucao.

       Antes, as duas classes de root\wmi eram consultadas DENTRO do laco de
       baterias e sempre com 'Select-Object -First 1': num equipamento com duas
       baterias, a segunda recebia a capacidade e a saude da primeira, e o mesmo
       achado era publicado duas vezes. #>
    [CmdletBinding()] param()
    $out = [pscustomobject]@{ Disponivel = $false; Itens = @(); Metodo = 'n/d'; Detalhe = '' }

    $rs = Invoke-SafeCommand { Get-CompartDiskCim -Class BatteryStaticData -Namespace 'root\wmi' -ThrowOnError } -Activity 'BatteryStaticData' -Silent
    $rf = Invoke-SafeCommand { Get-CompartDiskCim -Class BatteryFullChargedCapacity -Namespace 'root\wmi' -ThrowOnError } -Activity 'BatteryFullChargedCapacity' -Silent

    if (-not $rs.Success -or -not $rf.Success) {
        $out.Detalhe = 'as classes de capacidade do namespace root\wmi nao responderam'
        return $out
    }
    $est = @(@($rs.Value) | Where-Object { $null -ne $_ })
    $ful = @(@($rf.Value) | Where-Object { $null -ne $_ })
    if ($est.Count -eq 0 -or $ful.Count -eq 0) {
        $out.Detalhe = 'o firmware nao publica capacidade projetada ou capacidade de carga total'
        return $out
    }
    if ($est.Count -ne $ful.Count) {
        # Sem pareamento confiavel, atribuir capacidade a uma bateria especifica
        # seria adivinhacao. Melhor declarar indisponivel do que errar o alvo.
        $out.Detalhe = ("contagens divergentes entre as classes ({0} x {1}): correlacao por bateria nao e confiavel" -f $est.Count, $ful.Count)
        return $out
    }

    $itens = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $est.Count; $i++) {
        [void]$itens.Add([pscustomobject]@{
            Indice    = $i
            Instancia = "$($est[$i].InstanceName)"
            Projetada = (Get-BatteryNumero $est[$i].DesignedCapacity)
            Total     = (Get-BatteryNumero $ful[$i].FullChargedCapacity)
        })
    }
    $out.Itens = @($itens)
    $out.Disponivel = $true
    # As classes nao expoem chave de juncao com Win32_Battery: a correlacao e pela
    # ordem de enumeracao, e isso fica declarado no relatorio.
    $out.Metodo = $(if ($est.Count -eq 1) { 'instancia unica' } else { 'correlacao por ordem de enumeracao' })
    return $out
}

function Get-BatterySaude {
    <# Calcula a saude e valida a coerencia fisica dos valores.
       Devolve { Ok, Percentual, Estado, Detalhe }. #>
    param([AllowNull()][object]$Projetada, [AllowNull()][object]$Total)

    $out = [pscustomobject]@{ Ok = $false; Percentual = $null; Estado = 'nao verificada'; Detalhe = '' }
    $p = Get-BatteryNumero $Projetada
    $t = Get-BatteryNumero $Total

    if ($null -eq $p -or $p -le 0) { $out.Detalhe = 'capacidade projetada ausente ou invalida'; return $out }
    if ($null -eq $t) { $out.Detalhe = 'capacidade de carga total ausente'; return $out }
    if ($t -lt 0)     { $out.Detalhe = 'capacidade de carga total negativa: fonte nao confiavel'; $out.Estado = 'inconsistente'; return $out }
    if ($t -eq 0)     { $out.Detalhe = 'capacidade de carga total igual a zero: leitura provavelmente indisponivel, nao bateria esgotada'; $out.Estado = 'inconsistente'; return $out }

    $pct = [math]::Round(($t / $p) * 100, 1)
    $out.Percentual = $pct
    $out.Ok = $true

    # Capacidade total ACIMA da projetada ocorre apos calibracao e em firmware que
    # arredonda para cima. O valor bruto e preservado e a inconsistencia declarada,
    # em vez de "corrigir" o numero em silencio.
    if ($t -gt $p) {
        $out.Estado = 'inconsistente'
        $out.Detalhe = ('capacidade de carga total ({0}) maior que a projetada ({1}): valor mantido como recebido' -f $t, $p)
    } elseif ($pct -lt 60) { $out.Estado = 'degradada' }
    elseif ($pct -lt 80)   { $out.Estado = 'desgaste perceptivel' }
    else                   { $out.Estado = 'saudavel' }
    return $out
}

function Get-BatteryAlimentacao {
    <# Deriva alimentacao externa e carregamento a partir de BatteryStatus.

       'AC conectado' e 'carregando' sao estados RELACIONADOS mas distintos: um
       notebook com limite de carga fica na tomada sem carregar. Valores nao
       mapeados permanecem desconhecidos em vez de virar 'na bateria'. #>
    param([AllowNull()][object]$BatteryStatus)
    $out = [pscustomobject]@{ AC = 'Desconhecida'; Carregando = 'Desconhecido' }
    $c = Get-BatteryNumero $BatteryStatus
    if ($null -eq $c) { return $out }
    $n = [int]$c
    # 2=AC, 3=totalmente carregada, 6..9=carregando  ->  energia externa
    # 1=descarregando, 4=baixa, 5=critica            ->  na bateria
    # 10=indefinido, 11=carga parcial                ->  ambiguo, fica desconhecido
    if ($n -in @(2, 3, 6, 7, 8, 9)) { $out.AC = 'Sim' }
    elseif ($n -in @(1, 4, 5))      { $out.AC = 'Nao' }
    if ($n -in @(6, 7, 8, 9))       { $out.Carregando = 'Sim' }
    elseif ($n -in @(1, 2, 3, 4, 5)) { $out.Carregando = 'Nao' }
    return $out
}

function Show-BatteryInfo {
    $bat = Test-Bateria
    if (-not $bat.Ok) { Set-BatteryResult 'WARN'; return }
    $baterias = @($bat.Baterias)
    if ($baterias.Count -eq 0) { $script:result = 'UNSUPPORTED'; return }

    $status = @{
        1 = 'Descarregando'; 2 = 'Conectada a energia'; 3 = 'Totalmente carregada'; 4 = 'Baixa'
        5 = 'Critica'; 6 = 'Carregando'; 7 = 'Carregando (alta)'; 8 = 'Carregando (baixa)'
        9 = 'Carregando (critica)'; 10 = 'Indefinido'; 11 = 'Carga parcial'
    }
    $cap = Get-BatteryCapacidades
    $semSaude = 0
    $i = 0

    foreach ($b in $baterias) {
        $i++
        $alim = Get-BatteryAlimentacao -BatteryStatus $b.BatteryStatus
        $rotulo = $(if ($baterias.Count -eq 1) { 'Bateria' } else { "Bateria $i" })

        $pares = [ordered]@{
            'Bateria'            = $b.Name
            # Win32_Battery nao expoe fabricante: DeviceID e um identificador, nao um
            # nome. E Chemistry e um codigo numerico, como BatteryStatus logo abaixo.
            'Identificador'      = $b.DeviceID
            'Quimica'            = $(
                $q = @{ 1 = 'Outra'; 2 = 'Desconhecida'; 3 = 'Chumbo-acido'; 4 = 'Niquel-cadmio'
                        5 = 'Niquel-hidreto metalico'; 6 = 'Ions de litio'; 7 = 'Zinco-ar'; 8 = 'Litio-polimero' }
                if ($q.ContainsKey([int]$b.Chemistry)) { $q[[int]$b.Chemistry] } else { "Codigo $($b.Chemistry)" }
            )
            'Carga estimada'     = $(
                $c = Get-BatteryNumero $b.EstimatedChargeRemaining
                if ($null -ne $c -and $c -ge 0 -and $c -le 100) { "$([int]$c)%" } else { 'n/d' })
            'Status'             = $(if ($status.ContainsKey([int]$b.BatteryStatus)) { $status[[int]$b.BatteryStatus] } else { "Codigo $($b.BatteryStatus)" })
            'Alimentacao externa' = $alim.AC
            'Carregando'          = $alim.Carregando
            # 71582788 min e o sentinela de "desconhecido" do Win32_Battery. Antes, o
            # ramo de queda afirmava "conectada a energia" - uma INFERENCIA publicada
            # como fato: estimativa ausente virava atestado de que havia tomada.
            'Autonomia estimada' = $(
                $rt = Get-BatteryNumero $b.EstimatedRunTime
                if ($null -ne $rt -and $rt -gt 0 -and $rt -lt 71582788) { "$([int]$rt) min" } else { 'nao informada pelo sistema' })
            'Voltagem'           = $(
                $v = Get-BatteryNumero $b.DesignVoltage
                if ($null -ne $v -and $v -gt 0) { "$([int]$v) mV" } else { 'n/d' })
        }

        # Capacidade e saude ESTA bateria, nao a da primeira.
        $item = $null
        if ($cap.Disponivel) { $item = @($cap.Itens | Where-Object { $_.Indice -eq ($i - 1) }) | Select-Object -First 1 }

        if ($item) {
            $saude = Get-BatterySaude -Projetada $item.Projetada -Total $item.Total
            $pares['Capacidade projetada'] = $(if ($null -ne $item.Projetada) { "$($item.Projetada) mWh" } else { 'n/d' })
            $pares['Capacidade atual']     = $(if ($null -ne $item.Total) { "$($item.Total) mWh" } else { 'n/d' })
            $pares['Metodo de correlacao'] = $cap.Metodo

            if ($saude.Ok) {
                $pares['Saude da bateria'] = "$($saude.Percentual)% (calculada)"
                if ($saude.Estado -eq 'inconsistente') {
                    $pares['Consistencia'] = $saude.Detalhe
                    Add-CompartDiskFinding -Severity INFO -Area 'Bateria' `
                        -Message ("{0}: dados de capacidade inconsistentes - {1}." -f $rotulo, $saude.Detalhe) `
                        -Recommendation 'Valor mantido como recebido do firmware. Recalibracao ou atualizacao de firmware pode normalizar a leitura.'
                } elseif ($saude.Percentual -lt 60) {
                    Add-CompartDiskFinding -Severity CRIT -Area 'Bateria' `
                        -Message ("{0}: saude em {1}% da capacidade original ({2} de {3} mWh)." -f $rotulo, $saude.Percentual, $item.Total, $item.Projetada) `
                        -Recommendation 'Substituicao recomendada.'
                    Set-BatteryResult 'WARN'
                } elseif ($saude.Percentual -lt 80) {
                    Add-CompartDiskFinding -Severity WARN -Area 'Bateria' `
                        -Message ("{0}: saude em {1}% da capacidade original ({2} de {3} mWh)." -f $rotulo, $saude.Percentual, $item.Total, $item.Projetada) `
                        -Recommendation 'Desgaste perceptivel; monitorar autonomia.'
                    # Achado WARN sem resultado WARN e sinal mascarado: so o ramo de
                    # 60% escalava o resultado, e o relatorio consolidado saia OK.
                    Set-BatteryResult 'WARN'
                } else {
                    Add-CompartDiskFinding -Severity OK -Area 'Bateria' `
                        -Message ("{0}: saude em {1}% da capacidade original." -f $rotulo, $saude.Percentual)
                }
            } else {
                $pares['Saude da bateria'] = "nao verificada ($($saude.Detalhe))"
                $semSaude++
            }
        } else {
            $pares['Saude da bateria'] = 'nao verificada (capacidade nao publicada)'
            $semSaude++
        }

        foreach ($k in $pares.Keys) { Write-CompartDiskKeyValue $k $pares[$k] -Pad 22 }
        Write-Color ''
        # Titulo por bateria: com duas baterias, a versao anterior criava duas secoes
        # com o MESMO titulo 'Bateria' e status fixo OK no relatorio.
        $st = 'OK'
        if ($pares['Saude da bateria'] -like 'nao verificada*') { $st = 'WARN' }
        Add-CompartDiskSection -Title $(if ($baterias.Count -eq 1) { 'Bateria' } else { "$rotulo - $($b.Name)" }) `
            -Status $st -Pairs $pares -Summary ("{0} | {1}" -f $pares['Status'], $pares['Saude da bateria'])
    }

    # Saude indisponivel NAO e bateria saudavel: sem o achado abaixo, a ausencia de
    # dados de capacidade saia do modulo como silencio e resultado OK.
    if ($semSaude -gt 0) {
        $motivo = $(if ($cap.Detalhe) { $cap.Detalhe } else { 'capacidade nao publicada pelo firmware' })
        Write-Log WARN ("Saude nao verificada em {0} de {1} bateria(s): {2}." -f $semSaude, $baterias.Count, $motivo)
        Add-CompartDiskFinding -Severity WARN -Area 'Bateria' `
            -Message ("Saude nao verificada em {0} de {1} bateria(s): {2}." -f $semSaude, $baterias.Count, $motivo) `
            -Recommendation 'Usar a acao Report (powercfg /batteryreport) para o historico de capacidade fornecido pelo Windows.'
        Set-BatteryResult 'WARN'
    }
    Write-Log OK ("Informacoes de {0} bateria(s) coletadas." -f $baterias.Count)
}

function Test-BatteryArquivoGerado {
    <# Arquivo so conta como gerado se existe, foi gravado NESTA execucao e tem
       conteudo. Test-Path sozinho aceita o arquivo de uma tentativa anterior da
       mesma sessao e nao percebe saida truncada. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][datetime]$Desde)
    $out = [pscustomobject]@{ Ok = $false; Bytes = 0; Detalhe = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $out.Detalhe = 'o arquivo nao foi criado'; return $out }
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $out.Bytes = [long]$fi.Length
        if ($fi.LastWriteTime -lt $Desde.AddSeconds(-5)) { $out.Detalhe = 'arquivo preexistente: nao foi gravado por esta execucao'; return $out }
        if ($fi.Length -le 0) { $out.Detalhe = 'arquivo gerado vazio'; return $out }
        $out.Ok = $true
    } catch { $out.Detalhe = $_.Exception.Message }
    return $out
}

function Test-BatteryPowercfg {
    if (Test-Path -LiteralPath $script:powercfg) { return $true }
    Write-Log ERR 'powercfg.exe nao localizado em System32.'
    Add-CompartDiskFinding -Severity WARN -Area 'Energia' `
        -Message 'powercfg.exe nao localizado: o relatorio nativo nao pode ser gerado.' `
        -Recommendation 'Componente nativo ausente: avaliar a integridade do Windows com SFC /scannow.'
    Set-BatteryResult 'ERROR'
    return $false
}

function New-BatteryReport {
    $bat = Test-Bateria
    if (-not $bat.Ok) { Set-BatteryResult 'WARN'; return }
    if (@($bat.Baterias).Count -eq 0) { $script:result = 'UNSUPPORTED'; return }
    if (-not (Test-BatteryPowercfg)) { return }

    $destino = Join-Path $Global:CompartDisk.OutDir "Relatorio_Bateria_$($Global:CompartDisk.Session).html"
    Write-Log INFO 'Gerando relatorio nativo de bateria (powercfg /batteryreport)...'
    $inicio = Get-Date

    # Sem -Critical: a falha do powercfg e condicao esperada (privilegio, disco,
    # diretiva) e nao deve subir ao catch global como "Excecao no modulo".
    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $script:powercfg -Arguments @('/batteryreport', '/output', "`"$destino`"") -TimeoutSeconds 180
    } -Activity 'powercfg /batteryreport' -Silent

    $codigo = $(if ($r.Success -and $null -ne $r.Value) { [int]$r.Value.ExitCode } else { -1 })
    $val = Test-BatteryArquivoGerado -Path $destino -Desde $inicio

    if ($val.Ok -and $codigo -eq 0) {
        Write-Log OK ("Relatorio gerado: {0} ({1} bytes)." -f $destino, $val.Bytes)
        Add-CompartDiskSection -Title 'Relatorio de bateria' -Status OK -Pairs ([ordered]@{
            'Arquivo' = $destino; 'Bytes' = $val.Bytes; 'Codigo do powercfg' = $codigo
        }) -Summary 'Relatorio nativo gerado e confirmado no disco'
        Add-CompartDiskFinding -Severity OK -Area 'Bateria' -Message 'Relatorio detalhado de bateria gerado.' -Recommendation "Arquivo: $destino"
        $ab = Invoke-SafeCommand { Start-Process $destino } -Activity 'Abrir relatorio' -Silent
        if (-not $ab.Success) { Write-Log WARN 'Nao foi possivel abrir o relatorio automaticamente.' }
        return
    }

    # "powercfg executou" nao e prova de relatorio: confirma-se o arquivo.
    $motivo = $(if (-not $val.Ok) { $val.Detalhe }
                elseif ($codigo -ne 0) { "powercfg retornou $codigo" }
                elseif ($r.Error) { "$($r.Error.Exception.Message)" }
                else { 'falha nao identificada' })
    Write-Log ERR ("O relatorio de bateria nao foi gerado: {0}." -f $motivo)
    Add-CompartDiskSection -Title 'Relatorio de bateria' -Status CRIT -Pairs ([ordered]@{
        'Situacao' = 'nao gerado'; 'Motivo' = $motivo; 'Codigo do powercfg' = $codigo; 'Destino' = $destino
    }) -Summary 'Relatorio nao gerado'
    Add-CompartDiskFinding -Severity CRIT -Area 'Bateria' `
        -Message ("O relatorio nativo de bateria nao foi gerado: {0}." -f $motivo) `
        -Recommendation 'Verificar permissao de escrita no diretorio da sessao e repetir como administrador.'
    Set-BatteryResult 'ERROR'
}

function New-SleepReport {
    if (-not (Test-BatteryPowercfg)) { return }

    $destino = Join-Path $Global:CompartDisk.OutDir "Diagnostico_Energia_$($Global:CompartDisk.Session).html"
    if (-not (Test-Administrator)) {
        Write-Log WARN 'powercfg /energy exige privilegio administrativo: o diagnostico tende a falhar sem elevacao.'
    }
    Write-Log INFO 'Executando diagnostico de energia (powercfg /energy, 60 segundos)...'
    $inicio = Get-Date

    $r = Invoke-SafeCommand {
        Invoke-NativeCommand -FilePath $script:powercfg -Arguments @('/energy', '/output', "`"$destino`"", '/duration', '60') -TimeoutSeconds 300
    } -Activity 'powercfg /energy' -Silent

    $val = Test-BatteryArquivoGerado -Path $destino -Desde $inicio
    if ($val.Ok) {
        Write-Log OK ("Diagnostico de energia gerado: {0} ({1} bytes)." -f $destino, $val.Bytes)
        Add-CompartDiskFinding -Severity INFO -Area 'Energia' -Message 'Diagnostico de eficiencia energetica gerado.' -Recommendation "Arquivo: $destino"
        $ab = Invoke-SafeCommand { Start-Process $destino } -Activity 'Abrir diagnostico' -Silent
        if (-not $ab.Success) { Write-Log WARN 'Nao foi possivel abrir o diagnostico automaticamente.' }
    } else {
        $motivo = $(if ($val.Detalhe) { $val.Detalhe } elseif ($r.Error) { "$($r.Error.Exception.Message)" } else { 'falha nao identificada' })
        $extra = $(if (-not (Test-Administrator)) { ' Execucao sem privilegio administrativo.' } else { '' })
        Write-Log WARN ("O diagnostico de energia nao produziu arquivo de saida: {0}.{1}" -f $motivo, $extra)
        Add-CompartDiskFinding -Severity WARN -Area 'Energia' `
            -Message ("O diagnostico de energia nao produziu arquivo de saida: {0}.{1}" -f $motivo, $extra) `
            -Recommendation 'Reexecutar o Launcher como administrador.'
        Set-BatteryResult 'WARN'
    }

    $s = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $script:powercfg -Arguments @('/a') -TimeoutSeconds 60 } -Activity 'powercfg /a' -Silent
    if ($s.Success -and $null -ne $s.Value -and $s.Value.StdOut) {
        Write-Output $s.Value.StdOut
        Add-CompartDiskSection -Title 'Estados de suspensao disponiveis' -Status INFO -Pairs ([ordered]@{
            'powercfg /a' = ($s.Value.StdOut -replace '\s+', ' ').Trim()
        })
    } else {
        Add-CompartDiskSection -Title 'Estados de suspensao disponiveis' -Status WARN -Summary 'Nao consultados (powercfg /a nao respondeu)'
    }
}

try {
    if (-not (Start-CompartDiskModule -Name 'Battery' -Action $Action -Quiet:$Quiet)) {
        # O estado persistido para o Report.ps1 vem de $result e o finally roda mesmo
        # com este exit: sair sem marcar gravava "Resultado=OK" para uma execucao
        # recusada, enquanto o processo devolvia 2.
        $result = 'ERROR'
        exit $Global:CompartDisk.Exit.ERROR
    }
    switch ($Action) {
        'Info'   { Show-BatteryInfo }
        'Report' { New-BatteryReport }
        'Sleep'  { New-SleepReport }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Battery (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Bateria' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
