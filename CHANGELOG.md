# Histórico de Mudanças — COMPARTDISK

Todas as mudanças relevantes do projeto são registradas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e o
versionamento segue [Versionamento Semântico](https://semver.org/lang/pt-BR/).

---

## [Não lançado]

Sem alterações pendentes.

---

## [1.4.0] — 2026-08-14

**Instalação de aplicativos via WinGet**, acrescentada ao lado da atualização que já
existia — mais a manutenção acumulada desde a 1.3.1. Publicação em
[Releases](https://github.com/edsilas/COMPARTDISK/releases/tag/v1.4.0).

Manutenção do `Launcher.bat` e dos módulos `Drivers.ps1`, `Debloat.ps1`,
`Repair.ps1`, `Smart.ps1`, `Network.ps1`, `Users.ps1`, `Hardware.ps1`,
`Collectors.ps1`, `Report.ps1`, `Core.ps1`, `Cleanup.ps1`, `Defender.ps1` e
`Battery.ps1`, correção de ordenação nos relatórios de todos os módulos, e o novo
módulo `Apps.ps1`, que **acrescenta** a instalação de aplicativos à área de
aplicativos já existente.

**Nenhuma tecla de menu mudou de posição ou de destino, e nenhum caminho de fallback
Batch existente foi alterado.** A única mudança de rótulo é a da tecla `2` do menu
principal, que passa de `Atualizar Programas (Winget)` para `Aplicativos: Atualizar e
Instalar (Winget)`: a tecla continua abrindo a mesma área, e a atualização passa a ser
a opção `[1]` dela, com a mesma rotina e o mesmo comportamento. As cinco ações existentes do módulo de drivers
(`List` `Problems` `Backup` `Unsigned` `Export`) continuam válidas com o mesmo
significado, e as novas são acessíveis por `-Action` sem aparecer no menu. No módulo
de debloat, os três níveis, a precedência de seleção, o vocabulário de resultado e as
listas de proteção permanecem exatamente como estavam.

> **Versão.** A entrega acrescenta funcionalidade sem remover nem alterar o que
> existia, o que caracteriza uma versão **menor** em Versionamento Semântico: a
> numeração passa de `1.3.1` para `1.4.0` em `Core.ps1`, `Launcher.bat`, `remote.ps1`,
> `README.md`, no cabeçalho de todos os módulos e de todos os documentos.

### Alterado

- **Título da janela** passa a ser `COMPARTDISK 1.4.0 — ASSISTENTE DE REPARO WINDOWS`,
  em caixa alta. O travessão é o único caractere não ASCII do `Launcher.bat` e depende
  do `chcp 65001` que já executava na inicialização; se a troca de página de código
  falhar, o título cai automaticamente para a variante com hífen, em vez de exibir
  caracteres corrompidos.
- **Link oficial de *Releases*** passa a aparecer na tela de encerramento e na ajuda de
  linha de comando (`/?`), além do `README.md` e dos guias de instalação e atualização:
  https://github.com/edsilas/COMPARTDISK/releases
- **`remote.ps1` passa a apontar para a tag `v1.4.0`.** O SHA-256 do pacote publicado
  é lido das notas da release, mecanismo que o próprio script já implementava; a
  validação de integridade continua obrigatória antes da execução.

### Corrigido

- **`Network.ps1` dava a camada de endereço IPv4 como saudável quando todos os
  endereços eram APIPA.** A regra era `$ips.Count -gt 0 -and -not ($ips.Count -eq 1
  -and $apipa)`, que só reconhecia APIPA quando havia **exatamente um** endereço no
  sistema. Num notebook com Ethernet e Wi-Fi, ambos sem concessão DHCP, havia dois
  `169.254.x`, a condição ficava falsa e a camada era dada como `OK` — exatamente o
  cenário que ela existe para detectar. A decisão passa a ser pela classe do
  endereço (APIPA, loopback, privado, CGNAT, público, inválido), não por contagem.
- **A configuração IP por interface era exibida mas nunca avaliada.** A seção saía
  com `Status OK` fixo e nenhum finding era gerado: uma interface conectada com
  endereço APIPA, sem gateway e sem DNS aparecia no relatório idêntica a uma
  interface saudável. Passa a avaliar APIPA sem endereço roteável, ausência de IP
  utilizável, ausência de gateway e ausência de DNS — sem transformar em problema
  os casos legítimos: interface parada, VPN ou adaptador virtual sem gateway
  padrão, e rede somente IPv6.
- **O fallback CIM descartava toda interface virtual.** O filtro era
  `PhysicalAdapter=True`, então VPN, Hyper-V, VMware, VirtualBox, WSL e Bluetooth
  PAN sumiam do inventário justamente na máquina em que os cmdlets modernos não
  existem. O critério passa a ser ter `NetConnectionID` — inclui os virtuais reais
  e continua excluindo miniportas WAN e adaptadores de túnel internos.
- **MTU e DHCP eram associados à interface pelo nome.** `Get-NetAdapter` e
  `Get-NetIPInterface` eram correlacionados por `InterfaceAlias`, que é editável
  pelo usuário e pode repetir-se em ambiente com muitos adaptadores virtuais. A
  correlação passa a ser por `InterfaceIndex`, com o nome apenas como recurso
  secundário.
- **Adaptador ausente era contado como desconectado.** O mapa de
  `NetConnectionStatus` colapsava "hardware desabilitado" e "hardware com falha" em
  `Down`, e a contagem somava "Not Present" a desconectados. Os estados passam a
  ser normalizados em `Healthy`, `Disconnected`, `Disabled`, `NotPresent`, `Error`
  e `Unknown`, contabilizados separadamente.

> As ações `Reset`, `Hosts` e `Firewall` **não foram tocadas**: o diff se restringe
> aos caminhos de leitura. Nenhuma linha alterada envolve `netsh`, redefinição de
> pilha, arquivo `hosts` ou política de firewall.

- **`Smart.ps1` declarava disco saudável sem ter lido um único atributo
  S.M.A.R.T.** Uma gaveta USB, controladora RAID ou disco virtual reporta
  `HealthStatus = Healthy` pelo subsistema de armazenamento mesmo sem repassar
  S.M.A.R.T. ao Windows, e o módulo emitia "Disco X: saúde Healthy" como se
  tivesse lido atributos — falso negativo exatamente onde mais importa. O estado
  passa a distinguir `Healthy` (confirmado por evidência) de `NotSupported`
  (nenhum atributo legível), com a evidência declarada por disco.
- **A seção "Discos físicos" era sempre `OK`,** mesmo com um disco em `Pred Fail`
  e predição de falha iminente: o relatório mostrava a seção verde enquanto os
  findings diziam crítico. O status passa a refletir o pior disco encontrado.
- **Um volume com percentual ilegível abortava a análise de todos os demais.**
  `[double]("n/d")` lança, a exceção subia até o `catch` global e um volume a 97%
  logo abaixo nunca era avaliado. A conversão passa a devolver "não interpretado"
  em vez de lançar, e o volume problemático é reportado.
- **Alerta de desgaste era descartado em valor fracionário.** O padrão exigia
  `^(\d+)%$`, então `87,5%` não casava e o aviso nunca era emitido.
- **`Smart.ps1` rebaixava erro para aviso.** O estado era atribuído diretamente
  por cada função: em `Detail`, não conseguir enumerar disco algum marcava `ERROR`
  e a análise de contadores logo abaixo rebaixava para `WARN`.
- **Falha de contador por disco era engolida.** O `catch { continue }` descartava
  o erro sem log, sem finding e sem efeito no resultado; com todos os discos
  falhando, a função terminava em silêncio e o módulo reportava `OK`.
- **`Detail` consultava os mesmos discos duas vezes.** `Get-PhysicalDisk` e
  `Get-StorageReliabilityCounter` eram chamados pelo coletor e repetidos logo em
  seguida. Passam a ser coletados uma vez e reutilizados.
- **O modo `-Quiet` não silenciava as tabelas.** Elas eram emitidas com
  `Out-String | Write-Output`, que escreve no stream de sucesso do script e ignora
  o parâmetro. Passam por um formatador que respeita `-Quiet`, sem alterar logs,
  findings nem seções.
- **Volume ou pool não saudável não gerava finding.** `Get-Volume` e
  `Get-StoragePool` eram listados sem que `HealthStatus` fosse avaliado.
- **Sem conseguir iniciar, o módulo saía com erro mas persistia estado `OK`** no
  `state_Smart_*.json` — mesmo defeito já corrigido em `Drivers.ps1` e `Repair.ps1`.

> Nenhuma dependência externa foi introduzida. O `smartctl` nunca fez parte do
> projeto e continua fora: o módulo usa apenas o que o Windows expõe
> (`Get-PhysicalDisk`, `Get-StorageReliabilityCounter`,
> `MSStorageDriver_FailurePredictStatus`, WMI/CIM). Para NVMe, o desgaste passa a
> ser rotulado como `Percentage Used`, e o relatório declara explicitamente que
> `Available Spare`, `Critical Warning` e `Media Errors` **não** são expostos pelo
> subsistema nativo — em vez de omitir a limitação.

- **`Repair.ps1` rebaixava erro para aviso.** O estado do módulo era atribuído
  diretamente por cada função, sem ordem. Numa ação `Full`, um `ScanHealth` que
  falhava marcava `ERROR` e o `RestoreHealth` seguinte rebaixava para `WARN`: o
  módulo devolvia "atenção" ao Launcher para uma execução em que o DISM não pôde
  nem ser localizado. O estado passa a ser monotônico (`OK → WARN → ERROR`, nunca
  regride), no mesmo padrão de `Drivers.ps1` e `Debloat.ps1`.
- **O SFC ignorava o código de retorno.** A classificação usava apenas a contagem
  de padrões no `CBS.log`, e a função encerrava com `Write-Log OK` mesmo quando o
  `sfc.exe` não conseguia iniciar — `SFC finalizado (codigo 1)` era gravado como
  sucesso e o finding dizia "não encontrou violações". O código passa a decidir
  primeiro, distinguindo íntegro, reparos aplicados, corrupção não reparada e
  execução não concluída.
- **O SFC contava reparos históricos como se fossem da execução atual.** O
  `CBS.log` é cumulativo e sobrevive a reinícios; ler as últimas 4000 linhas
  contabilizava um reparo de semanas atrás. A leitura passa a filtrar pelo carimbo
  de data/hora a partir do início da execução, e quando o carimbo não pode ser
  interpretado a contagem é descartada em vez de gerar número falso.
- **Falha de `DISM RestoreHealth` era tratada como simples aviso.** Qualquer código
  diferente de `0`/`3010` virava `WARN`, inclusive numa imagem que continuava
  corrompida. Falha da operação de reparo passa a ser `ERROR`; `ScanHealth` e
  `CheckHealth`, que apenas diagnosticam, permanecem `WARN`. Os códigos passam a
  ser traduzidos no relatório, e o motivo do fallback para `Dism.exe` é registrado.
- **A ação `Component` terminava sempre em `OK`.** O código de retorno do
  `AnalyzeComponentStore` era apenas logado e nunca afetava o resultado, e o
  `Dism.exe` era invocado sem verificação de existência — numa máquina sem ele, a
  ação caía no `catch` global como falha não tratada.
- **A ação `Chkdsk` não validava a unidade.** `-Drive ''`, `-Drive 'CC'` ou um
  caminho arbitrário seguiam direto para `Repair-Volume` e para `fsutil dirty set`.
  Passa a normalizar e validar (letra única, volume existente, não é rede nem
  mídia óptica) e a recusar entrada inválida antes de qualquer operação de disco.
- **O `Chkdsk` declarava agendamento sem confirmar.** O volume era marcado como
  sujo com base apenas no código de saída do `fsutil`. O estado passa a ser
  reconsultado com `fsutil dirty query`, e o agendamento só é declarado quando
  confirmado. O `chkntfs` passa a ser interpretado no log em vez de despejado com
  `Write-Output` no stream de sucesso do script.
- **O `Chkdsk` forçava verificação offline mesmo em disco íntegro.** O volume era
  marcado incondicionalmente, o que impõe um CHKDSK completo no próximo boot —
  horas em disco grande — mesmo quando a varredura online acabara de confirmar que
  não havia erro. O reparo offline passa a ser agendado quando há erro confirmado,
  quando o diagnóstico é inconclusivo, ou por pedido explícito com `-Forcar`.
- **Falha do `Repair-Volume` era ignorada por completo.** Sem log, sem finding e
  sem efeito no resultado.
- **Sem privilégio administrativo, o módulo saía com erro mas persistia estado
  `OK`.** O `exit` direto dispara o `finally`, que gravava o estado ainda em `OK`
  no `state_Repair_*.json`; o relatório consolidado não via a falha.
- **A ação `Full` executava `ScanHealth` e `RestoreHealth` sempre.** Quando o scan
  confirma imagem íntegra, o `RestoreHealth` passa a ser dispensado e registrado
  como tal — a etapa custa dezenas de minutos e não teria o que reparar. A
  sequência ganha uma seção de consolidação que reflete o pior estado encontrado.
- **O `Launcher.bat` sempre saía com código 0, mesmo quando todos os módulos
  falhavam.** Os contadores de desfecho já existiam e eram corretos, mas não
  alimentavam o código de saída. Em `/autofix`, `/audit`, `/report` e `/clean` —
  exatamente os modos consumidos por RMM, GPO e tarefa agendada — a automação
  registrava sucesso de uma execução que não reparou nada. Passa a devolver `1`
  quando houve atenção e `2` quando houve erro. **No modo interativo o código
  continua `0`:** ali quem encerra é o operador e ninguém lê o valor.
- **O One-Click Fix declarava conclusão sem verificar nenhuma etapa.** As sete
  etapas eram encadeadas sem checagem e a rotina gravava
  `[ OK ] === REPARO AUTOMATICO CONCLUIDO ===` incondicionalmente — se as sete
  falhassem, o operador lia "concluído". Cada etapa passa a ser medida
  individualmente e o desfecho final distingue concluído, concluído com
  ressalvas e incompleto, com a contagem por etapa no log.
- **BitLocker era classificado como ausente em máquina que o possui.** O
  pré-flight validava com `manage-bde -status`, que exige privilégio
  administrativo; no caminho degradado (UAC recusado) a chamada falhava por
  permissão e o menu passava a oferecer o fallback errado. Sem privilégio, a
  presença do binário passa a ser o que se afirma.
- **A elevação por PowerShell descartava o parâmetro da linha de comando.** O
  caminho alternativo, usado quando o Windows Script Host está bloqueado,
  repassava apenas `/elevated`: `Launcher.bat /autofix` reabria elevado no menu
  em vez de executar o reparo, e a execução desassistida ficava parada
  esperando alguém digitar. Um argumento entre aspas também fechava a cadeia de
  aspas montada para o VBS e a elevação falhava sem explicação.
- **`Debloat.ps1` aplicava ajustes na plataforma errada e os reportava como
  sucesso.** `TaskbarDa` e `TaskbarMn` só existem no shell do Windows 11 e
  `EnableFeeds` só no do Windows 10, mas os três eram gravados em qualquer máquina.
  Na plataforma errada o valor não falha — fica inerte, e era contado como
  `Aplicado`. Cada item do catálogo passa a declarar build mínima, build máxima e
  família; o que não se aplica sai como `NaoSuportado` com o motivo, em vez de ser
  gravado sem efeito.
- **`Debloat.ps1` não distinguia ramo de registro protegido de valor barrado por
  segurança.** Os dois casos produziam o mesmo texto, o que impedia dizer se a
  alteração parou por estrutura do sistema ou por controle de segurança. Passam a
  ser motivos separados.
- **Os pares de campo/valor apareciam fora de ordem em todos os relatórios, e em
  ordem diferente a cada execução.** `Add-CompartDiskSection` declarava
  `[hashtable]$Pairs`, e todos os módulos montam os pares com `[ordered]@{}` porque
  a ordem é parte da informação — destino antes de tamanho, tentativa antes de
  resultado. O PowerShell convertia o `OrderedDictionary` para `Hashtable`, que não
  tem ordem definida, e as chaves chegavam embaralhadas ao TXT, ao CSV, ao HTML e ao
  `state_*.json`. O `Report.ps1` chegava a reconstruir um `[ordered]` a partir do
  JSON justamente para preservar a sequência, e a conversão anulava esse esforço. O
  parâmetro passa a ser `[System.Collections.IDictionary]`, que aceita `Hashtable` e
  `OrderedDictionary` sem converter nenhum dos dois. Afeta os 15 módulos que montam
  seções com pares; nenhuma chamada existente precisou mudar.
- **`Drivers.ps1` falhava ao localizar backups em máquina que nunca concluiu um
  backup.** `Split-Path -Parent` era chamado com a cadeia vazia do estado persistente
  e lançava exceção — ou seja, no caso mais comum. Afetava a listagem de backups e,
  por consequência, toda ação que precisasse localizar um backup existente.
- **Data do driver lida do INF podia sair com mês e dia trocados.** O campo
  `DriverVer` é sempre `MM/DD/YYYY` por especificação do formato INF, mas era
  interpretado pelo analisador genérico de datas, que tenta `dd/MM/yyyy` primeiro:
  `05/12/2023` virava 5 de dezembro. Passa a usar o formato exato, com o analisador
  genérico apenas como alternativa.
- **O destino padrão do backup ficava dentro do diretório de relatórios da sessão**,
  que é recriado a cada execução. O backup não sobrevivia à sessão seguinte —
  justamente quando ele é necessário — e divergia do caminho persistente usado pela
  cópia em Batch. Passa a usar seleção de destino persistente e auditável.
- **O destino informado em `-Path` não era verificado contra caminhos protegidos.**
  Um caminho dentro de `%SystemRoot%`, da raiz do volume ou do próprio repositório de
  drivers era aceito. Passa a ser recusado antes de qualquer escrita.
- **Argumento de caminho terminado em barra invertida podia escapar a aspa de
  fechamento** na linha de comando do `pnputil` (`"D:\Dir\"` chega como `D:\Dir"`),
  gravando a exportação em local diferente do informado.
- **Espaço livre insuficiente abortava o backup mesmo quando a estimativa era
  reconhecidamente pessimista.** A estimativa mede o repositório inteiro, incluindo
  os pacotes do próprio Windows, que não são exportados. O aborto continua sendo o
  padrão; `-Force` permite prosseguir com o risco declarado e registrado.
- **A validação do backup lia apenas um `.inf` de amostra.** Passa a amostrar vários
  pacotes distribuídos, contar arquivos de tamanho zero e pacotes sem `.inf`.
- Remoção do diretório de execução vazia passa a exigir que **nenhum arquivo** exista
  em qualquer nível abaixo dele, e que o alvo seja comprovadamente o diretório criado
  naquela execução.
- Removido código morto (`Get-DriverFindingSeverity`, nunca chamada) e um parâmetro
  interno sem uso que poderia envenenar o cache do inventário se acionado.
- `-ErrorAction SilentlyContinue` retirado da contagem de backups anteriores, que
  falhava sem deixar rastro.

#### Users

- **`ClearPassword` não passava pela guarda de conta Microsoft.** O ramo `if ($Clear)`
  retornava **antes** da verificação de `PrincipalSource`, que só protegia
  `SetPassword`. A senha local de uma conta que entra por e-mail era removida sem
  aviso — sem alterar a credencial da Microsoft e podendo impedir a entrada no
  Windows. A guarda passa a ser aplicada às duas ações, antes de qualquer alteração.
- **O achado "grupo de administradores possui N membros" era gerado com N desconhecido.**
  No caminho de queda CIM a coluna `Total` vale `n/d`, e a comparação `'n/d' -gt 3` é
  resolvida como texto (`'n/d' -gt '3'` é verdadeiro): **toda** execução por esse
  caminho publicava o achado com a contagem `n/d`. A contagem só é avaliada quando é
  numérica; indisponível vira achado informativo de "não foi possível listar".
- **Falha ao consultar os membros de um grupo virava "(vazio)".** `Get-LocalGroupMember`
  falha em cenários comuns (SID órfão de conta removida, membro de domínio
  irresolvível) e o resultado era um grupo aparentemente sem membros. Passa a ser
  reportado como indisponível.
- **A ausência de eventos `4625` era reconhecida pelo texto traduzido da exceção**
  (`No events were found|Nenhum evento`). Em Windows não inglês a classificação
  depende da tradução exata do recurso. A decisão passa a usar
  `FullyQualifiedErrorId` (`NoMatchingEventsFound`, `NoMatchingLogsFound`), que não é
  traduzido — mesmo discriminador que `Update.ps1` já usa. **A distinção entre
  "nenhuma falha" e "não foi possível verificar" continua intacta**: nenhum ramo de
  erro produz atestado de ausência de falhas.
- **`net accounts` não tinha validação alguma.** Não se verificava a existência do
  executável, o código de saída nem `stderr`, e saída parcial era publicada como
  política de contas válida. Falha ou indisponibilidade passa a produzir seção e
  achado explícitos de "não verificada"; formato não reconhecido preserva a saída
  original em vez de publicar uma política vazia.
- **Alterações de conta eram dadas como concluídas sem releitura.** Nem a troca/remoção
  de senha nem a habilitação do Administrador interno verificavam o estado posterior —
  a mesma classe de defeito que `Set-CompartDiskRegistryValue` já trata no registro.
  Passam a confirmar por `PasswordLastSet` (ou `PasswordAge`, no caminho ADSI) e por
  releitura do estado da conta; sem confirmação o resultado é `não-confirmado`, nunca
  `OK`.
- **Execução recusada por falta de privilégio gravava `Resultado=OK`.** O `exit` no ramo
  de `Start-CompartDiskModule` não marcava `$result`, então o `finally` persistia
  `OK` em `state_Users_<Ação>.json` enquanto o processo devolvia `2`, e o relatório
  consolidado herdava esse `OK`.
- **A comparação das duas senhas digitadas materializava a senha em texto claro.**
  `PtrToStringAuto` criava duas `String` gerenciadas que o coletor de lixo só recupera
  depois e que não podem ser zeradas. A comparação passa a ser feita sobre a memória
  não gerenciada do BSTR (zerada por `ZeroFreeBSTR`), os `SecureString` são
  descartados, e `Enter` vazio passa a cancelar — como o texto na tela já prometia —
  em vez de terminar em erro técnico.
- **A guarda de conta Microsoft ficava inativa no caminho CIM.** `Win32_UserAccount` não
  publica `PrincipalSource`; a leitura devolvia `$null` e a operação seguia como se a
  conta fosse local. Origem desconhecida deixa de ser tratada como local e passa a
  exigir confirmação explícita.
- **`AutoAdminLogon=1` era atribuído à conta em edição.** O aviso não consultava
  `DefaultUserName` e afirmava "este computador entra sozinho" para qualquer conta.
  `DefaultPassword` **nunca é lida**: apenas a existência do valor é verificada, por
  `GetValueNames()`.
- Uma consulta com falha na auditoria interrompia toda a ação `Audit`; as cinco etapas
  passam a ser independentes.
- Falha total de `Get-LocalGroup` era silenciada por `-ErrorAction SilentlyContinue` e
  a lista vazia era registrada como "Grupos locais listados" com resultado `OK`.
- Rejeição de senha pela política do Windows subia até o `catch` global e virava achado
  `CRIT` "Exceção no módulo"; passa a ser erro de operação com o motivo do Windows
  exibido ao operador. O módulo continua **sem** impor requisitos próprios de
  complexidade.
- O grupo de administradores era reconhecido pela expressão `Administrador|Administrators`,
  que não casa com `Administratoren` nem `Administrateurs`; passa a ser identificado
  pelo SID `S-1-5-32-544`, com o texto apenas como último recurso.
- O módulo não tentava importar `Microsoft.PowerShell.LocalAccounts`: no PowerShell 7,
  `Get-Command` encontra os cmdlets mas a importação falha por edição, e o módulo caía
  para CIM/`net.exe` num ambiente em que os cmdlets funcionam.
- Enumerações repetidas de contas (`List` + `Groups` + busca do Administrador na mesma
  auditoria) passam a reutilizar um índice único de SID por execução.

> As sete ações (`List` `Groups` `Audit` `ClearPassword` `SetPassword` `EnableAdmin`
> `DisableAdmin`) continuam válidas com o mesmo significado, os códigos de saída
> continuam `0/1/2/3`, e nenhum rótulo de menu ou caminho `:FB_USERS*` foi alterado.
> A identificação do Administrador interno pelo SID terminado em `-500`, a exigência
> da palavra `REMOVER` e as confirmações de troca de senha foram **preservadas**.

#### Hardware

- **Todo `ConfigManagerErrorCode` diferente de zero era publicado como achado `CRIT`**
  com a recomendação "reinstalar o driver". Um dispositivo deliberadamente
  desabilitado (código 22) ou simplesmente desconectado (código 45) — situações
  normais — geravam falha crítica, e o **mesmo equipamento recebia severidades
  contraditórias** de `Hardware.ps1` e de `Drivers.ps1`, que já classificava esses
  códigos como `INFO`. A severidade passa a ser por código.
- **A falha da consulta de dispositivos virava atestado de saúde.** Quando a consulta
  não respondia, a coleção vazia caía no ramo `else` e o módulo publicava "Nenhum
  dispositivo com código de erro" como achado `OK`. Falha de consulta e ausência de
  problema passam a ser estados distintos.
- **A enumeração USB primária era código morto no PowerShell 7.** O caminho percorria
  `Win32_USBControllerDevice` resolvendo cada referência com o acelerador `[wmi]`, que
  **não existe no PowerShell 7** — e o `Launcher.bat` procura o `pwsh` 7 **antes** do
  `powershell.exe`. Na engine preferida do projeto a conversão lançava, um `catch {}`
  vazio silenciava, e o inventário caía sem aviso para `PNPClass='USB'`, que vê apenas
  hubs e controladores: teclado, mouse, webcam e áudio USB sumiam do relatório. A
  enumeração passa a ser por `DeviceID`, idêntica em 5.1 e 7, com VID/PID e o método
  de coleta registrado.
- **Temperatura sem validação de faixa.** `(CurrentTemperature / 10) - 273.15` era
  publicado direto: um firmware que reporta `0` produzia **-273,15 °C** apresentado
  como leitura real, e `2732` (zero absoluto, sentinela usual de "sem sensor") virava
  "0 °C". Leituras fora de 5 °C a 125 °C passam a ser descartadas e contabilizadas.
- **Falha em um componente cancelava o inventário inteiro.** Qualquer exceção subia ao
  `catch` global e a ação terminava: uma consulta de GPU indisponível impedia a
  enumeração da placa-mãe, dos discos e de todo o restante. As etapas passam a ser
  independentes.
- **`AdapterRAM` é `UInt32` e satura em 4 GB**: qualquer placa de 4 GB ou mais era
  publicada como "4 GB". Passa a tentar o valor que o próprio driver grava
  (`qwMemorySize`) e, quando ele não existe, declara o limite em vez de afirmar um
  número.
- Achado `WARN` de uso de memória entre 80% e 90% não escalava o resultado do módulo,
  enquanto o ramo de 90% escalava — o relatório consolidado registrava `OK`.
- `Show-Gpu` não produzia seção, achado nem log quando nenhum adaptador era retornado.
- Módulos de memória ilegíveis encerravam a ação sem seção e sem achado; a ausência de
  SMBIOS tipo 17 (comum em máquina virtual) passa a ser limitação declarada, não falha.
- Velocidade **nominal** e velocidade **configurada** dos módulos de memória eram
  colapsadas numa só coluna, e `PartNumber` não era coletado. Velocidades diferentes
  entre módulos passam a gerar achado informativo, nunca defeito.
- `Get-CompartDiskHardwareInfo` era consultado duas vezes em `Info` e em `Full`, e
  `Win32_ComputerSystem` era reconsultado depois de `Get-CompartDiskSystemInfo`. Cada
  coletor passa a ser consultado uma única vez por execução.
- Estados de TPM colapsados numa cadeia única passam a distinguir ausente, presente,
  habilitado e pronto — ausência de TPM não é defeito de hardware.
- Presença de bateria entra no inventário; **desktop sem bateria nunca gera achado**. A
  saúde e o desgaste continuam sendo responsabilidade exclusiva do `Battery.ps1`.
- Adicionada seção de controladoras e barramentos, derivada da mesma leitura de
  `Win32_PnPEntity`, sem consulta adicional.

#### Collectors

- **`Get-CompartDiskDriverInfo -OnlyProblems` enumerava `Win32_PnPSignedDriver` inteira
  e descartava o resultado.** É uma das classes mais lentas do repositório, e o custo
  era pago por `Hardware.ps1`, `Drivers.ps1` e `Audit.ps1` a cada consulta de
  dispositivos com problema. O retorno antecipado é anterior à enumeração e a saída é
  idêntica.
- `Get-CompartDiskMemoryModules` passa a publicar `PartNumber`,
  `VelocidadeConfigurada` e os valores crus de capacidade e frequência; `Speed` nulo
  deixa de virar a cadeia `" MHz"`. Tipos LPDDR/LPDDR5 e DDR2 FB-DIMM reconhecidos.
- `Get-CompartDiskGpuInfo` passa a publicar `PNPDeviceID` e `AdapterRAM` cru, para que
  o consumidor distinga adaptador físico de virtual sem comparar nome traduzível.
- Adicionada `Get-CompartDiskDeviceErrorSeverity`, espelhando a tabela canônica de
  `Drivers.ps1`. *As duas tabelas permanecem duplicadas: consolidá-las numa única fonte
  é trabalho para o próprio `Drivers.ps1` e não foi feito aqui.*

> As seis ações de hardware (`Info` `Full` `Gpu` `Memory` `Devices` `Temperature`)
> continuam válidas com o mesmo significado, `Temperature` continua devolvendo
> `UNSUPPORTED` quando não há sensor, e as teclas `5` e `6` do menu não mudaram. O
> módulo permanece **exclusivamente diagnóstico**: nenhum comando que altere registro,
> serviço, driver, dispositivo, energia, partição ou firmware foi introduzido.

#### Report

- **Falha total da geração era publicada como sucesso.** `New-Report` captura a falha
  de cada formato individualmente e devolve apenas o que gravou; o módulo registrava
  `[ OK ] Relatorio consolidado gerado (0 arquivos)` e **devolvia `0` ao Launcher**
  mesmo com nenhum arquivo no disco. Reproduzido com o diretório de saída somente
  leitura: os quatro formatos falhavam e a execução terminava em sucesso. Passa a
  confirmar arquivo a arquivo — o mesmo que `Drivers.ps1` já fazia, com o comentário
  *"New-Report executou não é prova"* — e a devolver `ERROR` quando nada é confirmado.
- **Módulo que terminou com `ERROR` não afetava o relatório.** O resultado de cada
  módulo era exibido numa tabela e nunca escalava o estado do `Report` nem gerava
  achado — e um módulo que falha frequentemente não publica achado nenhum, então
  desaparecia por completo do resumo. Cada `ERROR` passa a gerar achado `CRIT`.
- **Um único campo malformado descartava o módulo inteiro.** Uma severidade fora do
  `ValidateSet` fazia `Add-CompartDiskFinding` lançar, e o `catch` por arquivo
  descartava **todas** as seções e **todos** os achados daquele módulo. Verificado:
  1 severidade inválida custava 2 seções e 3 achados. A importação passa a ser item a
  item, com a severidade original preservada na mensagem.
- **Estado ilegível sumia do console.** O aviso era gravado com `-NoConsole` e a
  contagem informada incluía os arquivos que falharam, então "3 estados agregados"
  podia significar 2 lidos e 1 perdido.
- **A cobertura da coleta não era declarada.** O relatório passa a informar
  explicitamente `Coleta completa` ou `Coleta parcial`, com estados encontrados,
  lidos, ilegíveis, itens descartados e a contagem de módulos por resultado.
- **Escrita não atômica.** A gravação ia direto no caminho final: uma interrupção
  deixava arquivo truncado com aparência de válido, e uma falha destruía o relatório
  anterior antes de falhar. Passa a gravar em temporário, validar e só então
  substituir — verificado que o relatório anterior sobrevive byte a byte a uma falha,
  sem deixar `.tmp` órfão.
- **Codificação divergia conforme o motor.** `Set-Content -Encoding UTF8` grava BOM no
  Windows PowerShell 5.1 e **não** grava no PowerShell 7 — e o Launcher prefere o
  pwsh 7. O CSV saía sem BOM justamente no motor preferido, e o Excel abre a
  acentuação corrompida. Passa a ser explícito e igual nos dois motores: BOM em
  TXT/CSV/HTML, sem BOM em JSON (parsers estritos recusam BOM).
- Material secreto publicado por engano como par chave/valor (`DefaultPassword`,
  `RecoveryPassword`, token, senha de recuperação) passa a ser ocultado antes de
  chegar a qualquer formato. A regra compara o **nome completo** da chave: `Tamanho
  mínimo da senha` continua visível por ser diagnóstico legítimo.
- Formato solicitado que não chega ao disco passa a ser reportado como perda parcial,
  nomeando o formato ausente, em vez de contar como sucesso pleno.
- `Open` deixa de terminar em sucesso quando o arquivo não abre ou está vazio.

#### Core

- Adicionada `Write-CompartDiskReportFile`: escrita atômica, verificada e com
  codificação explícita, usada por `New-Report` para os quatro formatos. Beneficia
  também `Audit.ps1`, `Bitlocker.ps1` e `Drivers.ps1`.
- A verificação por tamanho não distinguia arquivo de diretório: em PowerShell
  `.Length` devolve `1` para qualquer objeto escalar, inclusive um `DirectoryInfo`, e
  um diretório ocupando o caminho do relatório passava por arquivo válido enquanto o
  temporário era movido para dentro dele. A checagem passa a exigir `PSIsContainer`
  falso. *A mesma verificação em `Drivers.ps1` tem a limitação e não foi alterada.*

> As três ações (`Build` `Consolidate` `Open`) continuam válidas com o mesmo
> significado, os nomes dos arquivos (`Relatorio_Consolidado_<sessão>.*`) e os quatro
> formatos permanecem, o HTML continua **autocontido e offline** (zero referências
> externas), e o `state_Report*` continua sendo excluído da reagregação — verificado
> que três consolidações seguidas não duplicam achados.

#### Cleanup

Endurecimento da **guarda de caminhos**. O catálogo de alvos é byte a byte idêntico:
nenhum alvo foi criado, removido ou reapontado, e os 14 alvos legítimos continuam
sendo aceitos.

- **`%SystemDrive%` vale `"C:"`, sem barra — e `"C:"` é um caminho relativo à
  unidade.** `GetFullPath("C:")` devolve o *diretório corrente* daquela unidade, não a
  raiz, então a entrada protegida gerada a partir de `%SystemDrive%` apontava para o
  diretório de trabalho do processo. Consequência real: com o diretório corrente
  coincidindo com um alvo, aquele alvo era recusado em silêncio. `C:\` permanecia
  protegido pela checagem independente de raiz de volume. O `Core.ps1` já documentava
  e corrigia essa mesma armadilha em `Test-CompartDiskProtectedPath`; a guarda passa a
  existir também aqui.
- **A lista de caminhos proibidos era comparada apenas por igualdade.** Como
  `%SystemRoot%` é raiz permitida (é de lá que saem `Windows\Temp`,
  `SoftwareDistribution\Download` e `Prefetch`), qualquer caminho sob ela que não
  fosse *idêntico* a uma entrada passava pela guarda: `System32\config\SAM`,
  `System32\DriverStore\FileRepository`, `WinSxS\Backup`, `Windows\Installer`,
  `Windows\Fonts` e `System32\catroot2` eram todos aceitos. As proteções passam a ter
  duas classes — `Exato` para raízes das quais se pode descer, e `Subárvore` para
  árvores onde nada pode ser removido em nenhuma profundidade. **Nenhum alvo do
  catálogo apontava para essas árvores**: era uma fraqueza da guarda, não uma remoção
  indevida em curso.
- **Varredura de reparse points falhava em silêncio.** A busca por junction aninhada
  usava `-ErrorAction SilentlyContinue`: um subdiretório sem permissão de leitura era
  pulado sem rastro e uma junction escondida dentro dele não era detectada, deixando o
  diretório elegível para `Remove-Item -Recurse` — que no Windows PowerShell 5.1 pode
  atravessar a junction e apagar a árvore de destino, exatamente o risco que o próprio
  comentário do módulo já descrevia. A varredura passa a **falhar fechado**: scan
  incompleto preserva o item. Perde-se limpeza, nunca dados.
- **Raiz permitida que seja raiz de volume passa a ser descartada.** Com `%TEMP%`
  apontando para `C:\` por ambiente corrompido, `C:\` viraria raiz permitida e a guarda
  de escopo perderia o efeito.

> As cinco ações (`Analyze` `Standard` `Deep` `Browsers` `Logs`) continuam válidas com
> o mesmo significado, `Analyze` continua **estritamente somente leitura**, e o módulo
> continua sem encerrar processos, sem parar serviços e sem tocar em registro,
> energia, WinSxS, DriverStore ou componentes do Windows. Toda remoção de diretório
> continua passando por `Remove-CompartDiskPathSafely` do `Core.ps1` — o módulo possui
> apenas dois comandos destrutivos próprios: a remoção do `MEMORY.DMP` (arquivo único,
> após validação) e `Clear-RecycleBin`.

#### Battery

- **Com duas baterias, a saúde da primeira era atribuída a todas.** As classes
  `BatteryStaticData` e `BatteryFullChargedCapacity` eram consultadas **dentro** do
  laço de baterias e sempre com `Select-Object -First 1`: num equipamento com duas
  baterias, a segunda recebia a capacidade e a saúde da primeira, e o mesmo achado
  era publicado duas vezes. Reproduzido: bateria 1 a 90,7% e bateria 2 a **44%** —
  ambas reportadas como 90,7%, com o módulo terminando em `OK`. **Uma bateria em
  estado crítico ficava invisível.** A capacidade passa a ser correlacionada por
  bateria, com o método de correlação declarado no relatório; quando as contagens
  das classes divergem, a saúde é declarada não verificável em vez de atribuída ao
  alvo errado.
- **Falha de consulta era publicada como "nenhuma bateria presente".**
  `Get-CompartDiskCim` devolve `$null` tanto para ausência de bateria quanto para
  recusa do WMI, e o módulo afirmava ausência nos dois casos — num notebook, com
  saída `UNSUPPORTED`. Passa a usar `-ThrowOnError` para separar as duas condições.
  **Desktop sem bateria continua `UNSUPPORTED`, nunca erro.**
- **Ausência de estimativa de autonomia era publicada como "conectada a energia".**
  O ramo de queda de `EstimatedRunTime` afirmava alimentação externa — uma inferência
  apresentada como fato. Reproduzido: o relatório exibia `Status: Descarregando` e
  `Autonomia: conectada a energia` simultaneamente. Passa a informar "não informada
  pelo sistema", e alimentação externa e carregamento passam a ser derivados de
  `BatteryStatus`, como estados distintos — um notebook com limite de carga fica na
  tomada sem carregar.
- **Saúde indisponível saía do módulo como silêncio e resultado `OK`.** Quando o
  firmware não publica as capacidades — situação comum —, nenhum achado era gerado.
  Passa a declarar explicitamente que a saúde não foi verificada e por quê.
- **O cálculo de saúde não tinha validação.** Sem verificar `FullCharge > 0` nem a
  relação com a capacidade projetada: capacidade total igual a zero (leitura ausente)
  produziria 0% e o achado `CRIT` "substituição recomendada". Capacidade acima da
  projetada — comum após calibração — passa a ser declarada como inconsistência **com
  o valor bruto preservado**, sem "corrigir" o número em silêncio.
- **Relatório de bateria vazio era reportado como gerado.** A verificação era só
  `Test-Path`: um arquivo de 0 byte, ou o arquivo de uma tentativa anterior da mesma
  sessão, contava como sucesso, e o código de saída do `powercfg` era ignorado. Passa
  a confirmar existência, tamanho e gravação nesta execução — mesmo critério que o
  `Cleanup.ps1` já aplica aos backups de log.
- `Invoke-SafeCommand -Critical` no `/batteryreport` fazia uma falha esperada
  (privilégio, disco, diretiva) subir ao `catch` global como `CRIT` "Exceção no
  módulo"; passa a ser classificada. `powercfg.exe` passa a ser validado antes do uso,
  e `powercfg /energy` avisa quando executado sem elevação.
- Achado `WARN` de saúde entre 60% e 80% não escalava o resultado do módulo, enquanto
  o ramo de 60% escalava — o relatório consolidado registrava `OK`.
- As classes de capacidade passam a ser consultadas **uma vez por execução** (eram
  duas consultas por bateria), e cada bateria ganha seção própria: antes, duas
  baterias geravam duas seções com o mesmo título `Bateria` e status fixo `OK`.

> As três ações (`Info` `Report` `Sleep`) continuam válidas com o mesmo significado e
> as faixas de saúde (`< 60%` crítica, `< 80%` atenção) foram **preservadas**. O módulo
> permanece **exclusivamente diagnóstico**: `powercfg` é invocado apenas com
> `/batteryreport`, `/energy` e `/a` — nenhum `setactive`, `/change`, `/hibernate` ou
> alteração de plano de energia, firmware, driver ou dispositivo.

#### Defender

- **Estado desconhecido da proteção em tempo real era publicado como "proteção
  ativa".** A verificação era `if (RTP -eq 'False') { CRIT } else { OK }`: qualquer
  valor que não fosse exatamente `False` — incluindo `n/d`, vazio ou a chave ausente —
  caía no `else` e gerava o achado `OK` "Proteção em tempo real ativa", com o módulo
  terminando em `0`. Falso negativo no controle mais importante do módulo. Passa a ser
  tri-estado: sem leitura, o resultado é "não verificado".
- **Antivírus de terceiros ativo produzia falso crítico.** Com o Defender em modo
  passivo — configuração legítima e comum — `RealTimeProtectionEnabled` é `False`, e o
  módulo publicava `CRIT` "Proteção em tempo real desabilitada" recomendando reativá-la,
  o que colocaria dois antivírus disputando a mesma função. O estado passa a ser
  contextualizado por `AMRunningMode` e pelos produtos registrados no Security Center.
  **O caso genuinamente grave — proteção desligada sem nenhum outro antivírus — continua
  `CRIT`.**
- **Detecção já remediada mantinha a máquina em atenção para sempre.** Toda entrada do
  histórico gerava `WARN`, sem distinguir ameaça pendente de ameaça tratada com
  sucesso. Passa a classificar por `ThreatStatusID`: quarentena, limpeza, remoção e
  bloqueio são resultado positivo (`INFO`); detecção ativa, remediação falha, abandono
  e ameaça permitida são pendências (`CRIT`).
- **Falha na atualização de definições virava exceção não tratada.** `Invoke-WithRetry`
  relança na última tentativa, então uma condição esperada — sem rede, serviço de
  atualização parado, bloqueio por diretiva — subia ao `catch` global e virava
  "Falha não tratada no módulo" com `CRIT` genérico. Passa a ser classificada com causa
  e recomendação.
- **A atualização era declarada concluída sem comparar antes e depois.** `Update-MpSignature`
  devolve sucesso mesmo quando já está na versão corrente. Passa a registrar
  `versão anterior → comando → versão atual`, distinguir "atualizado" de "já estava
  corrente", e avisar quando o comando é aceito mas as definições continuam antigas.
- **`Get-MpPreference` era chamado sem proteção** em `Exclusions` e derrubava o módulo
  com `CRIT` "Exceção no módulo" — mesma classe de defeito já corrigida neste arquivo
  para `Get-MpComputerStatus` e `Start-MpScan`. O cmdlet recusa em modo passivo e sem
  privilégio suficiente.
- **Qualquer exclusão era tratada como vulnerabilidade.** Passa a classificar a
  abrangência (raiz de unidade, diretório de sistema, extensão executável de uso geral,
  interpretador como `powershell.exe`/`rundll32.exe`) e publica uma linha por exclusão
  com `tipo → valor → abrangência → motivo`. Exclusões específicas deixam de gerar
  alarme; as amplas geram `WARN` pedindo revisão, sem afirmar comprometimento.
  `ExclusionExtension` e `ExclusionIpAddress`, antes exibidas mas não contabilizadas,
  entram na conta.
- **Assinatura atualizada no mesmo dia não gerava evidência.** O ramo `elseif ($idade -gt 0)`
  descartava justamente o melhor caso, e uma conversão que falhasse no `catch` vazio
  produzia `$idade = 0` — indistinguível de "atualizada hoje". Agora são três estados.
- `Get-MpThreat` era consultado **uma vez por detecção** (até 30 chamadas CIM para
  montar uma tabela); passa a ser consultado uma vez e indexado por `ThreatID`.
- Tamper Protection desativada passa a gerar achado próprio, e execução recusada por
  falta de privilégio deixa de persistir `Resultado=OK` para o `Report.ps1`.

> As sete ações (`Status` `Update` `QuickScan` `FullScan` `CustomScan` `Exclusions`
> `History`) continuam válidas com o mesmo significado e `Start-MpScan` continua
> reportando **solicitação aceita**, nunca varredura concluída. O módulo permanece
> **exclusivamente de auditoria**: não há um único comando que altere o Defender —
> nenhum `Set-MpPreference`, `Add-MpPreference`, `Remove-MpThreat` ou manipulação de
> registro/serviço. Nenhuma exclusão é removida e nenhuma política é alterada.

### Adicionado

#### Instalação de aplicativos (novo módulo `Apps.ps1`)

Nova área de **instalação** de aplicativos de suporte técnico, ao lado da atualização
que já existia. As duas capacidades são independentes.

> **A atualização existente não foi alterada.** A rotina `:MOD_WINGET` do
> `Launcher.bat` — `winget source update` seguido de `winget upgrade --all
> --include-unknown --accept-package-agreements --accept-source-agreements`, com o
> mesmo tratamento de retorno e as mesmas mensagens — permanece byte a byte como
> estava. O que mudou foi apenas o destino de retorno do seu invólucro
> `:MOD_WINGET_MENU`, que agora volta ao submenu de aplicativos em vez do menu
> principal. Nenhum outro módulo, rotina de fallback, código de saída, variável de
> ambiente ou parâmetro de linha de comando foi tocado.

- **A tecla `2` do menu principal continua sendo a área de aplicativos**, agora como
  submenu: `[1] Atualizar aplicativos` (a rotina de sempre) e `[2] Instalar
  aplicativos` (novo). Nenhuma outra tecla de menu mudou de posição ou de significado.
- **Catálogo declarativo com 26 itens** em seis categorias — Hardware, Windows /
  Sistema, Rede, Acesso Remoto, Produtividade e Utilitários (esta última criada como
  ponto de extensão, sem itens, para não mover nenhum aplicativo de categoria). Menus,
  numeração, lote, instalação global e verificação são derivados do catálogo:
  acrescentar uma ferramenta é acrescentar uma entrada.
- **Todos os identificadores foram conferidos no catálogo oficial do WinGet** (índice
  da fonte `winget` e manifestos de `microsoft/winget-pkgs`, em 14/08/2026), junto com
  editor, tipo de instalador, escopo e arquitetura. Nenhum ID foi deduzido.
- **Instala apenas o que está ausente.** Atualizar continua sendo responsabilidade da
  opção `[1]`: o módulo nunca executa `winget upgrade`. Item já presente é reportado
  como `JA INSTALADO` e ignorado.
- **Sysinternals sem download redundante**: as cinco ferramentas individuais declaram
  a suíte que já as contém; com a Sysinternals Suite instalada, elas não são baixadas
  de novo.
- **`RDP` é tratado como recurso nativo** (`mstsc.exe`): nenhum ID é inventado e o
  Remote Desktop **não** é habilitado. **`RustDesk` não possui pacote na fonte oficial
  do WinGet** e é exibido como `Não disponível via WinGet` — sem URL substituta e sem
  download fora do WinGet.
- **Notepad++** (`Notepad++.Notepad++`) entra em Windows / Sistema e **Google Chrome**
  (`Google.Chrome`) em Produtividade. O Chrome não é definido como navegador padrão.
- **Resultado por código real do WinGet**, não por ausência de exceção: `INSTALADO`,
  `JA INSTALADO`, `NAO ENCONTRADO`, `NAO DISPONIVEL`, `ERRO`, `CANCELADO`,
  `SEM INTERNET`, `FONTE INDISPONIVEL`, `ACESSO NEGADO`,
  `REINICIALIZACAO NECESSARIA` e `RECURSO NATIVO`. Depois de instalar, o estado final
  é confirmado por consulta ao sistema — código 0 sozinho não é aceito como prova.
- **Falha individual não interrompe o lote**; ao final, resumo consolidado com
  instalados, já instalados, não disponíveis e falhas, e uma seção nos relatórios.
- **Controles exclusivamente numéricos** em toda a área nova, inclusive confirmação
  (`[1]` confirma, `[0]` cancela). Entrada com letras é recusada.
- **Automação preservada e determinística**: `-Action Install -Id`,
  `-Action InstallCategory -Category`, `-Action InstallAll` e `-Action List` executam
  sem prompt; `-Action Menu` sem console interativo devolve `3` (não suportado) em vez
  de bloquear. Alvo fora do catálogo interno é recusado antes de qualquer chamada ao
  WinGet.
- **Fallback Batch completo** (`:FB_APPS_*` no `Launcher.bat`) com o mesmo catálogo,
  os mesmos identificadores, a mesma ordem e os mesmos controles numéricos, para
  quando o PowerShell estiver ausente ou bloqueado. O código de retorno do WinGet é
  comparado textualmente com `0`, porque `if errorlevel 1` é falso para os HRESULT
  negativos que o WinGet devolve — um erro seria lido como sucesso.
- **WinGet ausente** produz tela própria e código `3` (não suportado), nos dois
  caminhos. O COMPARTDISK não instala nem baixa o WinGet.

#### Debloat

- **Cobertura ampliada de 150 para 197 itens de catálogo** (129 famílias Appx, contra
  88). Entram WhatsApp, Messenger, Telegram e Viber; a coleção completa de jogos
  casuais da Microsoft (Mahjong, Sudoku, Jigsaw, Minesweeper, Treasure Hunt, Ultimate
  Word Games, além do Solitaire já coberto); versões de avaliação de antivírus e VPN
  (McAfee, Norton, Avast, AVG, ExpressVPN); e mais promocionais de fabricante.
- **Copilot, Recall e Widgets tratados em todas as camadas.** Antes só o aplicativo
  `Microsoft.Copilot` era removido, o que deixava o botão na barra, a política ausente
  e a experiência voltando na atualização seguinte. Agora cada camada é um item
  próprio: aplicativo e pacotes de IA (Seguro); `TurnOffWindowsCopilot` de máquina e
  de usuário, `ShowCopilotButton`, `DisableAIDataAnalysis`, `AllowRecallEnablement`,
  `DisableSearchBoxSuggestions` e `AllowNewsAndInterests` (Moderado, reversíveis).
- **Gate de compatibilidade por plataforma.** Itens declaram `MinBuild`, `MaxBuild` e
  `Familia`; os que não se aplicam são reportados como `NaoSuportado` com o motivo, em
  vez de aplicados inertes. Plataforma não identificada libera o item — perder a
  detecção não pode zerar o módulo.
- **Classificação de risco por item**, exposta no relatório ao lado do resultado:
  `ESSENCIAL`, `SISTEMA`, `SEGURANCA`, `DEPENDENCIA`, `RECOMENDADO_PRESERVAR`,
  `DEBLOAT_SEGURO`, `DEBLOAT_MODERADO`, `OPCIONAL`, `INEXISTENTE`, `INCOMPATIVEL` e
  `ERRO`. As quatro primeiras vêm das listas de proteção e explicam por que o item não
  foi tocado. É um eixo distinto do vocabulário de resultado, que permanece inalterado.

> As listas de proteção não foram afetadas. O pacote dos Widgets
> (`MicrosoftWindows.Client.WebExperience`) continua protegido pelo prefixo do shell do
> Windows 11 e **não é removido**: os Widgets são desligados por política, o que é
> reversível. A precedência `Proteção > -Exclude > -Include > -Level` permanece
> intacta, e `-Include "*"` continua sem vencer a proteção.

#### Drivers

- **`Diagnose`** — verificação prévia somente leitura: privilégio, `pnputil`,
  repositório WMI, repositório de drivers, destino, espaço livre, assinatura,
  duplicidades e dispositivos com driver ausente. Não cria nem altera nada.
- **`Validate`** — validação real de um backup: estrutura, contagem, arquivos vazios,
  leitura efetiva por amostragem e conferência de hashes contra o manifesto.
- **`Restore`** — restauração dos pacotes de um backup validado, por
  `pnputil /add-driver /install`. **Simulação é o padrão**; `-Force` aplica e
  `-DryRun` vence `-Force`. Nunca remove nem substitui driver existente, ignora
  pacotes já publicados (idempotência) e confirma o resultado por reconsulta ao
  repositório, não pelo código de retorno. Filtros `-InfName`, `-Provider`,
  `-DeviceClass` e `-OnlyMissing`.
- **`Package`** — preparação de pacote para transporte, separada do backup: seleção
  por filtro, cópia verificada, manifesto próprio, `.zip` opcional (`-Compress`)
  reaberto e conferido, e SHA-256 do arquivo final.
- **`Last`** — localiza os backups conhecidos e valida rapidamente o mais recente.
- **Manifesto do backup** (`Manifest/Drivers_Manifesto.json`): computador, usuário,
  Windows, build, arquitetura, PowerShell, método, totais e, por pacote, INF,
  provedor, versão, data, classe, catálogo, tamanho e SHA-256 do `.inf` e do `.cat`.
  Gravação atômica com releitura e conferência de contagem, no mesmo padrão de
  `Debloat.ps1` — manifesto truncado é pior que manifesto nenhum.
- **Seleção inteligente de destino**, auditável em seção própria do relatório: último
  destino usado, diretório persistente do projeto, documentos do usuário, volume fixo
  com espaço suficiente, diretório da sessão. Detecta mídia removível e rede, recusa
  caminhos protegidos e comprova permissão de escrita gravando um arquivo temporário.
- **Estrutura de backup previsível** — `Drivers/`, `Manifest/`, `Metadata/`,
  `Validation/` — com nome `Drivers_AAAA-MM-DD_HH-mm-ss`. Backups no formato anterior
  (pacotes na raiz) continuam sendo lidos, validados, empacotados e restaurados.
- Inventário passa a expor origem (Windows ou terceiro), localização, `DeviceID` e ID
  de hardware, obtidos na mesma consulta já existente.
- Estado operacional explícito por operação: `NaoIniciado`, `EmPreparacao`,
  `EmExecucao`, `Concluido`, `ConcluidoComAvisos`, `Falhou`, `Cancelado`.

### Segurança

- O módulo continua **sem** `Invoke-Expression`, sem executar qualquer arquivo
  encontrado no backup (apenas `.inf`, apenas por `pnputil`), sem `/delete-driver`,
  sem `/force` do `pnputil` e sem tocar em política de assinatura de drivers.
- `Restore` recusa backup reprovado na validação e recusa backup com hash divergente
  do manifesto — conteúdo alterado após a criação não é instalado.
- Nomes de pasta derivados de dados do sistema são neutralizados contra travessia de
  caminho antes de virarem caminho de arquivo.
- **Não foi criada nenhuma integração de upload**: o projeto não possui backend de
  envio, e nenhum envio é simulado.

---

## [1.3.1] — 2026-08-06

Versão de correção. **Nenhuma tecla de menu mudou de posição, nenhuma ação foi
adicionada ou removida, nenhuma assinatura de função pública foi alterada.**

### Corrigido

#### Crítico

- **Submenus executavam opções que o usuário não escolheu.** `if errorlevel N`
  significa "maior ou igual a N", e os oito submenus usavam `call`, que retorna e
  deixa o encadeamento continuar contra o código de saída do módulo. Um módulo que
  saía com `WARN` (1), `ERROR` (2) ou `UNSUPPORTED` (3) reativava os testes de baixo.
  Exemplo reproduzível: `[3]` › `[5]` "Testar Conectividade" numa máquina sem
  internet devolvia `WARN`, e a redefinição completa da pilha de rede — que não pede
  confirmação — era executada em seguida. A tecla escolhida passa a ser congelada em
  `MENU_OPC` e comparada por igualdade.

#### Alto

- **`Defender.ps1`** afirmava "Histórico de ameaças limpo" quando
  `Get-MpThreatDetection` falhava — situação comum com o Defender em modo passivo.
  Consulta recusada passa a ser reportada como não verificada.
- **`Explorer.ps1`** encerrava o shell para limpar o cache de ícones e o reiniciava
  com uma única tentativa e erro silenciado, informando sucesso. Passa a usar a mesma
  verificação com três tentativas de `Restart-ShellExplorer`.
- **`Network.ps1`** gravava o backup do arquivo `hosts` dentro de
  `System32\drivers\etc`, sem verificar o resultado da cópia e anunciando o backup
  sempre. O backup passa a ir para o diretório de relatórios e só é anunciado quando
  o arquivo existe.
- **`Collectors.ps1`** atribuía o prognóstico SMART ao disco errado em máquinas com
  mais de um disco: o casamento `-like "*<id>*"` encontrava o dígito em qualquer
  posição do `InstanceName`. Passa a casar o índice ao final da cadeia.
- **`Collectors.ps1`** truncava a contagem de eventos em 60 por log antes do
  agrupamento, sem informar. O truncamento passa a ser registrado.
- **`Launcher.bat` `:FB_LIMPEZA`** apagava a pasta `Network` dos navegadores
  Chromium, que guarda `Cookies` e `TransportSecurity` — desconectando o usuário de
  todos os sites. O caminho PowerShell nunca a tocou, e `:FB_LIMPEZA_NAVEGADORES`
  também não. As três listas de subcache foram alinhadas.

#### Médio

- `Core.ps1` — `Test-CompartDiskProtectedPath` não cobria a forma `C:` sem barra,
  que o PowerShell resolve como diretório corrente da unidade.
- `Core.ps1` — `Invoke-NativeCommand -PassThruOutput` emitia no stream de sucesso e
  fazia o retorno virar array.
- `Audit.ps1` — as tabelas de discos, volumes e eventos eram capturadas por
  `Invoke-SafeCommand` e nunca chegavam à tela.
- `Audit.ps1` — a seção do Defender sumia do relatório quando a consulta falhava.
- `Collectors.ps1` — eventos ordenados alfabeticamente por nível colocavam os avisos
  à frente dos críticos.
- `Collectors.ps1` — a coluna `SenhaExpira` vinha invertida no caminho de queda WMI.
- `Hardware.ps1` — falta de privilégio para ler sensores ACPI era reportada como
  ausência de sensor no firmware.
- `Hardware.ps1` — WMI degradado produzia o achado "Uso de memória em 0%" com
  severidade OK.
- `Smart.ps1` — discos com `Pred Fail`, `Degraded` ou `NonRecover` no caminho WMI não
  geravam achado algum.
- `Smart.ps1` — a coluna `TamanhoCluster` publicava o tamanho da partição.
- `Users.ps1` — falha ao ler o log de Segurança virava "nenhuma falha de logon".
- `Users.ps1` — nome de conta com curinga podia desativar a guarda de conta Microsoft.
- `Update.ps1` — reexecutar o reset destruía o backup original de
  `SoftwareDistribution`, e a própria ferramenta recomenda reexecutar.
- `Update.ps1` — os serviços eram declarados reconfigurados sem verificação.
- `Performance.ps1` — os efeitos visuais eram alterados mesmo quando a troca do plano
  de energia falhava.
- `Bitlocker.ps1` — a ausência de senha de recuperação era avaliada no conjunto dos
  volumes, e não no volume do sistema.
- `Launcher.bat` — `:TRACE` não higienizava o argumento e quebrava quando o caminho
  da ferramenta continha `&`.
- `Launcher.bat` — `:FB_USERS_SENHA` existia completa e nenhuma linha a chamava.
- `Launcher.bat` — dezessete caminhos `C:\Windows` fixos passaram a `%SystemRoot%`.
- `remote.ps1` — `Set-StrictMode -Version 2.0` e as preferências vazavam para a
  sessão do administrador, porque `iex` executa no escopo do chamador.

#### Baixo

- `Cleanup.ps1` — "Cache DNS limpo" era emitido sem verificação.
- `Debloat.ps1` — a reconfirmação de pacotes protegidos não alcançava os
  provisionados.
- `Debloat.ps1` — `exit` dentro do `try` fazia `Stop-CompartDiskModule` executar duas
  vezes nos caminhos de saída antecipada.
- `Battery.ps1` — o rótulo "Fabricante" exibia o `DeviceID`, e a química da bateria
  saía como código numérico.
- `remote.ps1` — o fallback de extração não limpava um destino parcialmente extraído.

### Documentação

- `LIMITACOES.md` — a afirmação de que a ferramenta "não contata servidores" e "não
  baixa pacotes" foi corrigida: `Test-Internet` contata servidores de teste de
  conectividade e `Update-MpSignature` baixa definições do Defender.
- `LIMITACOES.md` — a limitação "o perfil usado é o de quem elevou" listava três
  operações afetadas; são pelo menos sete.
- `MANUAL-TECNICO.md` — a proteção de caminhos é por igualdade exata, não
  hierárquica.
- `EXECUCAO-REMOTA.md` — a tabela de tratamento de erros prometia recusa
  incondicional por SHA-256, contradizendo a nota da seção 3.

---

## [1.3.0] — 2026-08-05

### Adicionado

- **Módulo de Desbloat (`Modules/Debloat.ps1`).** Onze ações: `Analyze`, `Apps`,
  `Services`, `Tasks`, `Privacy`, `Tweaks`, `Components`, `Full`, `Backup`, `Restore`
  e `RestorePoint`, em três níveis de risco — `Safe`, `Moderate` e `Aggressive`.
  Acessível pelo menu `[4]` › `[9]`. Nenhuma tecla de menu existente mudou de posição.
- **Catálogo declarativo único.** Cada item traz tipo, categoria, nível mínimo, motivo
  técnico e reversibilidade. Simulação, execução e relatório derivam da mesma fonte,
  o que garante que a prévia descreva exatamente o que a execução fará.
- **Listas de proteção com precedência absoluta.** Famílias Appx, prefixos de runtime,
  serviços e ramos de registro protegidos são avaliados depois de `-Include`,
  justamente para que a proteção não possa ser contornada por parâmetro. Pacotes
  casados por curinga são reconferidos pelo nome real antes da remoção.
- **Manifesto de reversão.** Toda alteração registra o estado *anterior* em JSON, em
  duas cópias: no diretório da sessão e em `COMPARTDISK_Restauracao`, fora dela. A
  ação `Restore` devolve serviços, tarefas e registro ao valor exato de origem —
  inclusive removendo valores que não existiam antes, em vez de gravar zero.
- **Ponto de restauração do sistema.** A rotina completa cria um antes de qualquer
  alteração e **aborta** se não conseguir, salvo `-SkipRestorePoint` explícito. Trata
  os dois motivos clássicos de falha: proteção desligada e o intervalo mínimo de 24 h.
- **Validação prévia** de edição do Windows, privilégio, reinício pendente,
  disponibilidade dos módulos Appx e ScheduledTasks e espaço livre em disco.
- **Simulação como padrão.** `Analyze` nunca altera nada, e `-DryRun` aplica a mesma
  proteção a qualquer outra ação.
- **Decisão condicional por hardware.** O `SysMain` é preservado em disco mecânico,
  onde o Superfetch traz ganho real, e só é desativado em SSD.
- Rotinas Batch `:FB_DEBLOAT*` para serviços, tarefas, registro, componentes e ponto
  de restauração, mantendo a promessa de degradação sem PowerShell. A remoção de
  aplicativos não tem equivalente Batch e é informada como tal.

### Documentação

- **`docs/DESBLOAT.md`** — referência completa do módulo: os três níveis com objetivo,
  público, cenários, impactos, grau de segurança, tempo e necessidade de reinício; os
  sete submódulos com o que exatamente alteram, componentes do Windows envolvidos,
  dependências, compatibilidade e reversibilidade; as listas de proteção; o manifesto
  de reversão; parâmetros de linha de comando e a cobertura em modo Batch.
- README ganhou seção própria sobre o desbloat e índice renumerado para treze seções.
- Manual do Usuário explica o módulo em linguagem simples, com o significado de cada
  palavra que aparece na tela durante a execução.
- Manual do Administrador registra por que o módulo não está exposto na linha de
  comando, e como usá-lo em parque quando essa for a decisão.
- Manual Técnico documenta como estender o catálogo, incluindo o motivo de usar chaves
  nomeadas em vez de arrays posicionais.
- Arquitetura passa a declarar as fronteiras entre Cleanup, Telemetry, Performance e
  Debloat, para que não existam duas fontes de verdade sobre o mesmo alvo.
- Guia de Utilização, Boas Práticas, FAQ e Solução de Problemas cobrem o módulo nos
  respectivos recortes.

### Correção de defeitos

Correção de defeitos e endurecimento de guardas de segurança. Nenhuma funcionalidade
foi adicionada ou removida; nenhuma tecla de menu mudou de posição.

### Corrigido

- **Raiz do disco não era reconhecida como caminho protegido.** A lista de proteção
  guardava `C:\` enquanto o alvo era normalizado para `C:`, e a comparação nunca
  casava. O efeito prático era permitir `takeown` e reescrita de ACL recursivos sobre
  todo o volume de sistema. A decisão passou a morar em ponto único no `Core.ps1`
  (`Test-CompartDiskProtectedPath`), com normalização aplicada aos dois lados.
- **Troca de senha travava ao final.** Uma chamada a `Write-Color` sem argumento fazia
  o PowerShell abrir prompt de parâmetro obrigatório logo após a senha ser redefinida.
- **Backup dos logs de eventos era anunciado mesmo quando falhava.** A mensagem de
  êxito e o achado do relatório passaram a refletir quantos logs foram realmente
  exportados antes da limpeza, que é irreversível.
- **`Invoke-NativeCommand` podia travar indefinidamente.** A leitura de saída padrão e
  de erro era sequencial: o processo filho bloqueava ao encher o canal ainda não lido,
  e o tempo limite jamais chegava a ser avaliado. Os dois canais passaram a ser
  drenados de forma concorrente, e o tempo limite tornou-se efetivo.
- **Relatório consolidado duplicava achados.** Consolidar duas vezes na mesma sessão
  reagregava o próprio estado do módulo `Report`, dobrando cada constatação e os
  contadores do resumo executivo.
- **Constatações perdidas quando o mesmo módulo era executado duas vezes.** O arquivo
  de estado era nomeado apenas pelo módulo; a segunda ação sobrescrevia a primeira.
  O nome passou a incluir a ação. Afetava seis opções de menu.
- **Senha em texto claro permanecia em memória.** O `BSTR` gerado na confirmação nunca
  era liberado com `ZeroFreeBSTR`, e a cadeia gerenciada sobrevivia até uma coleta
  futura. Ambos passaram a ser zerados e liberados de forma determinística.
- **Ativação e desativação da conta interna geravam texto malformado** no log e no
  relatório (`habilitarda`, `desabilitarda`).
- **Variável de cor inexistente no relatório HTML.** A classe `.brand` referenciava
  `--accent`, que nunca foi declarada.
- **Fallback de `Write-Color` poluía o valor de retorno.** Ao falhar, a função escrevia
  no fluxo de saída, o que podia transformar o código devolvido por
  `Stop-CompartDiskModule` em um vetor.
- **`Users.ps1` e `remote.ps1` estavam sem marca de ordem de bytes**, contrariando a
  convenção registrada no Manual Técnico.

### Alterado

- **Rotina Batch de contas alinhada ao caminho PowerShell.** A listagem deixou de
  emendar a *remoção* de senha e o encadeamento automático da conta interna de
  Administrador. Agora termina na listagem e exige escolha deliberada, como já
  acontecia com o PowerShell disponível. A auditoria de contas passou a usar uma
  rotina somente leitura.
- **Modo desassistido não abre mais o navegador.** `/audit` e `/report` deixaram de
  exibir o relatório HTML ao final. O modo interativo permanece inalterado.
- **Relatório JSON gravado sem marca de ordem de bytes.** O mesmo arquivo era gerado
  com BOM no Windows PowerShell 5.1 e sem BOM no PowerShell 7. TXT, CSV e HTML não
  mudaram.
- **Limpeza preserva os artefatos da própria ferramenta em `%TEMP%`.** Na execução
  remota o pacote é extraído ali, e a limpeza profunda removia os módulos da instância
  em execução.
- Duas opções que se tornavam silenciosas sem PowerShell — exclusões do Defender e
  troca de senha — passaram a informar a indisponibilidade.
- Nome de conta e caminho digitados no Launcher têm aspas removidas antes de compor
  os argumentos, o que também faz funcionar o texto colado com **Copiar como caminho**
  do Explorer.
- Documentação alinhada ao comportamento real: código de saída do modo desassistido,
  condições da validação SHA-256 e limitação de perfil sob elevação.

---

## [1.2.0] — 2026-07-31

Versão oficial de publicação. Consolida a identidade **COMPARTDISK**, padroniza o
versionamento e entrega a documentação completa.

### Adicionado

- **Execução remota em um comando.** `irm .../remote.ps1 | iex` baixa e executa a
  versão estável mais recente, com validação de integridade por SHA-256 e remoção
  automática dos arquivos temporários. É um método adicional de inicialização: não
  altera nem substitui nenhum fluxo existente.
- Guia de Execução Remota, com passo a passo, tratamento de erros e configuração
  por variáveis de ambiente para espelho interno ou versão fixada.
- Documentação completa pronta para publicação: guias de instalação, configuração e
  utilização, manuais do usuário, do administrador e técnico, FAQ, solução de
  problemas, arquitetura, estrutura, requisitos, compatibilidade, limitações, boas
  práticas, política de atualização e créditos.
- Arquivo de licença (MIT) e histórico de mudanças.
- Assinatura de autoria padronizada em toda a interface, relatórios, logs e documentação.
- Tela **Ambiente de Execução** com identificação de produto, versão e autoria.

### Alterado

- Interface do Launcher redesenhada: fundo escuro de baixo contraste no lugar do azul
  intenso, cor aplicada com parcimônia e hierarquia construída por espaçamento e
  alinhamento. Nenhuma tecla de menu mudou de posição.
- Subtítulo da aplicação padronizado como **Assistente de Reparo**, na janela do
  console e na tela principal.
- Capitalização unificada em títulos, subtítulos, cabeçalhos e rótulos de opção.
  A convenção está registrada no cabeçalho do `Launcher.bat`.
- Mensagens de log com marcador de largura fixa — `[ OK ]`, `[WARN]`, `[ERRO]`,
  `[INFO]` — alinhadas em coluna. O formato gravado em arquivo permanece o anterior.
- Identidade unificada sob o nome **COMPARTDISK**, sem variações ou sufixos de numeração interna.
- Versão padronizada em **1.2.0** em todos os pontos: launcher, menus, título da janela,
  banners, cabeçalhos de arquivo, relatórios, logs e documentação.
- Banner do menu principal recentralizado para 80 colunas exatas.

### Mantido

- Nenhuma funcionalidade removida ou alterada.
- Estrutura de menus, sequências de teclas e fluxos de execução preservados integralmente.
- Compatibilidade com Windows 10 e Windows 11 inalterada.

---

## [1.1.0] — 2026-07-31

Correção de falha crítica de inicialização e endurecimento da partida.

### Corrigido

- **Log vazio.** Mensagens contendo `|` eram expandidas antes do reconhecimento de
  operadores pelo interpretador de comandos, transformando a linha de log em uma
  cadeia de comandos inválida. O arquivo de log ficava com apenas o separador. O
  escritor de log agora higieniza `|`, `&`, `<` e `>` na origem.
- **Janela fechando logo após o UAC.** A detecção de privilégio usava apenas
  `net session`, que falha quando o serviço *Server* está parado ou desabilitado —
  comum em Windows Home e imagens corporativas. Um administrador legítimo era
  tratado como usuário comum e a ferramenta se relançava em ciclo.

### Adicionado

- Detecção de privilégio em camadas: `fltmc`, depois `net session`, depois escrita de teste em `HKLM`.
- Sentinela interna de reentrada, que torna o ciclo de reelevação estruturalmente impossível.
- Janela protegida: em falha catastrófica a janela permanece aberta exibindo o erro.
- Trace de inicialização em `%TEMP%\COMPARTDISK_Bootstrap.log`, com doze estágios numerados.
- Detecção automática de encerramento anormal na execução anterior.
- Fallback de diretório de log em três níveis: pasta do programa, Área de Trabalho, pasta temporária.
- Degradação para texto puro quando o console não aceita cores.
- Elevação por `cscript` explícito, com PowerShell como segunda via e instrução manual como terceira.
- Verificação de *Command Extensions* na partida.

---

## [1.0.0] — 2026-07-30

Primeira versão da arquitetura modular.

### Adicionado

- Arquitetura híbrida: Batch como interface e controle de fluxo, PowerShell como
  motor de operações complexas.
- Dezenove módulos PowerShell: biblioteca central, coletores e dezessete módulos de domínio.
- Relatórios em TXT, CSV, JSON e HTML, com resumo executivo e seções colapsáveis.
- Relatório HTML totalmente offline, sem dependência de internet ou fontes externas.
- Rotina Batch equivalente para cada função, usada quando o PowerShell está indisponível.
- Modo desassistido por linha de comando.
- Registro estruturado com data, hora, computador, usuário, versão do Windows, módulo,
  tempo de execução, resultado e rastreamento de exceção.
- Modo de simulação de limpeza, que mede o espaço recuperável sem apagar nada.
- Restauração de telemetria e de plano de energia ao padrão do Windows.
- Backup automático antes de operações destrutivas.

### Corrigido em relação à ferramenta original em Batch

- Verificação de disco não depende mais de confirmação por idioma do Windows.
- Conta interna de Administrador localizada pelo identificador de segurança, e não
  pelo nome — funciona em qualquer idioma do sistema.
- Reset do Windows Update renomeia as pastas em vez de apagá-las, permitindo reversão.

---

[1.4.0]: https://github.com/edsilas/COMPARTDISK/releases/tag/v1.4.0
[1.3.1]: https://github.com/edsilas/COMPARTDISK/releases/tag/v1.3.1
[1.3.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.3.0
[1.2.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.2.0
[1.1.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.1.0
[1.0.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.0.0
