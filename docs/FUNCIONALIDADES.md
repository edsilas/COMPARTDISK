# Descrição das Funcionalidades

**COMPARTDISK 1.4.5** · Desenvolvido por Edsilas

Descrição técnica do que cada recurso faz. Para a explicação em linguagem simples,
veja o [Manual do Usuário](MANUAL-DO-USUARIO.md).

---

## Matriz de módulos e ações

| Módulo | Ações |
|---|---|
| `Network.ps1` | `Info` `Reset` `Hosts` `Firewall` `Test` `Proxy` `Wifi` |
| `Repair.ps1` | `Full` `Sfc` `Dism` `Scan` `Chkdsk` `Component` |
| `Update.ps1` | `Status` `History` `Reset` `Cache` `Services` `Search` |
| `Defender.ps1` | `Status` `Update` `QuickScan` `FullScan` `CustomScan` `Exclusions` `History` |
| `Cleanup.ps1` | `Analyze` `Standard` `Deep` `Browsers` `Logs` |
| `Security.ps1` | `Status` `GpoReset` `Takeown` `Firewall` `Uac` |
| `Users.ps1` | `List` `Groups` `Audit` `ClearPassword` `SetPassword` `EnableAdmin` `DisableAdmin` |
| `Telemetry.ps1` | `Status` `Disable` `Enable` |
| `Debloat.ps1` | `Analyze` `Apps` `Services` `Tasks` `Privacy` `Tweaks` `Components` `Full` `Backup` `Restore` `RestorePoint` |
| `Performance.ps1` | `Analyze` `Ultimate` `Balanced` `Startup` `Processes` `Services` |
| `Hardware.ps1` | `Info` `Full` `Gpu` `Memory` `Devices` `Temperature` |
| `Drivers.ps1` | `List` `Problems` `Backup` `Unsigned` `Export` `Diagnose` `Validate` `Restore` `Package` `Last` |
| `Smart.ps1` | `Status` `Detail` `Volumes` `Shadow` `Spaces` |
| `Battery.ps1` | `Info` `Report` `Sleep` |
| `Bitlocker.ps1` | `Status` `Report` `Keys` |
| `Explorer.ps1` | `Restart` `ClearCache` `Spooler` `ResetView` |
| `Apps.ps1` | `Menu` `Install` `InstallCategory` `InstallAll` `List` `Central` |
| `Winget.ps1` | `Menu` `Status` `Prepare` `Repair` |
| `Audit.ps1` | `Full` `Quick` `Events` `Software` `License` |
| `Report.ps1` | `Build` `Consolidate` `Open` |

---

## Rede e conectividade

**Reset completo** executa nove passos: liberação e renovação de endereço, limpeza do
cache de nomes, reinicialização do Winsock, do TCP/IP e do IPv6, limpeza da tabela
ARP, remoção do proxy do WinHTTP e novo registro no DNS.

**Arquivo hosts** é restaurado ao conteúdo padrão da Microsoft, com cópia do anterior
gravada antes.

**Firewall** é exportado para arquivo `.wfw` antes de qualquer reset, e os três perfis
são reativados ao final.

**Diagnóstico** cobre adaptadores, endereçamento, servidores DNS, concessão DHCP,
unidade máxima de transmissão e tabela de rotas.

**Teste de conectividade** verifica em três níveis: resposta ICMP, resolução de nomes
e requisição HTTP — o que permite identificar em qual camada a conexão falha.

---

## Reparo do sistema

**Reparo profundo** executa, em ordem: verificação da imagem, restauração da imagem e
verificação dos arquivos de sistema. A análise do registro do verificador identifica
quantos arquivos foram efetivamente reparados.

**Verificação de disco** usa comandos não interativos. A implementação original em
Batch dependia de confirmação por tecla, o que falhava conforme o idioma do Windows.

**Windows Update** — o reset renomeia as pastas de distribuição e de catálogo para
`.old`, em vez de apagá-las, permitindo reversão manual. Vinte e uma bibliotecas são
registradas novamente e uma nova busca é disparada.

**Explorer** — reinício do processo, reconstrução do cache de ícones e miniaturas, e
limpeza da fila de impressão.

---

## Limpeza

**Modo de análise** é uma simulação: percorre todos os alvos, mede o espaço ocupado e
apresenta o total recuperável **sem apagar nada**.

**Alvos por grupo:**

| Grupo | Conteúdo |
|---|---|
| Padrão | Temporários do usuário e do sistema, lixeira, prefetch |
| Profundo | Cache de atualizações, otimização de entrega, perfis antigos |
| Navegadores | Cache de Edge, Chrome, Brave e Firefox, em todos os perfis |
| Registros | Logs de eventos, despejos de memória, relatórios de erro |

A limpeza de registros exporta os logs para arquivos `.evtx` antes de limpá-los.

A remoção de arquivos passa por uma função com lista de caminhos protegidos, que
nunca remove a pasta do Windows, `System32` ou raiz de unidade.

---

## Desbloat

`Debloat.ps1` — remove aplicativos pré-instalados, ajusta serviços e tarefas agendadas,
aplica ajustes de privacidade e compacta o armazenamento de componentes.

| Ação | O que faz |
|---|---|
| `Analyze` | Simula todas as categorias. Não altera nada |
| `Apps` | Remove aplicativos da loja, por usuário e no provisionamento |
| `Services` | Ajusta o tipo de inicialização de 15 serviços |
| `Tasks` | Desativa 14 tarefas agendadas |
| `Privacy` | Grava 23 valores de registro contra sugestões e coleta implícita |
| `Tweaks` | Grava 10 valores de preferência de interface e sistema |
| `Components` | `AnalyzeComponentStore` e `StartComponentCleanup` via DISM |
| `Full` | Ponto de restauração, backup e todas as categorias em sequência |
| `Backup` | Retrato do estado atual de todos os alvos, sem alterar |
| `Restore` | Reverte pelo manifesto |
| `RestorePoint` | Cria um ponto de restauração do sistema |

**Catálogo declarativo.** Todas as ações derivam de uma fonte única, com 150 itens que
declaram tipo, categoria, nível mínimo, motivo técnico e reversibilidade. Simulação,
execução e relatório usam o mesmo catálogo, o que garante que a prévia descreva
exatamente o que a execução fará.

**Níveis cumulativos.** `Safe` seleciona 104 itens, `Moderate` 143 e `Aggressive` 150.

**Proteção com precedência.** As listas — 48 aplicativos por nome, 7 por prefixo de
família, 56 serviços e 4 ramos de registro — são avaliadas depois de `-Include`, para
que não possam ser contornadas por parâmetro. Pacotes casados por curinga são
reconferidos pelo nome real antes da remoção.

**Manifesto.** Cada alteração grava o estado anterior em JSON, em duas cópias: no
diretório da sessão e em `COMPARTDISK_Restauracao`, fora dela.

**Decisão por hardware.** O `SysMain` é preservado em disco mecânico e só desativado em
estado sólido. A decisão ocorre em tempo de execução e o motivo aparece no relatório.

Referência completa em [Módulo de Desbloat](DESBLOAT.md).

---

## Segurança

**Postura de segurança** reporta Secure Boot, TPM, segurança baseada em virtualização,
proteção de credenciais, integridade de código, integridade de memória, proteção do
processo de autoridade de segurança local, Controle de Conta de Usuário, SmartScreen e
Windows Hello.

**Defender** — estado do serviço, versão das assinaturas, proteção em tempo real,
proteção na nuvem, envio de amostras, exclusões configuradas e histórico de ameaças.
Exclusões são sinalizadas como possível vetor de evasão.

**Diretivas de grupo** — as pastas são copiadas antes do reset.

**Assumir controle** recusa caminhos críticos do sistema, mesmo com privilégio
administrativo.

**Contas locais** — a conta interna de Administrador é localizada pelo identificador
de segurança terminado em `-500`, e não pelo nome, o que funciona em qualquer idioma.
Remover a senha de uma conta exige digitar literalmente a palavra `REMOVER`, e o ato é
registrado no log como evento de segurança.

---

## Hardware e discos

**Saúde de discos** combina o estado reportado pelo subsistema de armazenamento com os
contadores de confiabilidade: horas ligado, ciclos de carga, dados lidos e escritos,
setores realocados e temperatura, quando disponível.

**Inventário completo** cobre processador, módulos de memória individualmente, placa de
vídeo, monitores com identificação decodificada, dispositivos USB e PCI, placa-mãe,
BIOS e TPM.

**Bateria** calcula o desgaste real comparando a capacidade de projeto com a capacidade
de carga completa atual. Gera também o relatório de bateria e o diagnóstico de energia
do próprio Windows.

**Drivers** — inventário completo, dispositivos com código de erro, drivers sem
assinatura digital e backup por exportação, com verificação prévia de espaço livre.

O ciclo completo do módulo é `Diagnose` → `Backup` → `Validate` → `Package` →
`Restore`, e cada etapa é uma ação independente:

| Ação | Escreve? | Administrador | O que faz |
|---|---|---|---|
| `List` `Problems` `Unsigned` `Export` | não | não | inventário, códigos de erro, assinatura e relatórios |
| `Diagnose` | não | não | verificação prévia: privilégio, `pnputil`, repositório WMI, destino, espaço, duplicidades |
| `Last` | não | não | localiza os backups conhecidos e valida rapidamente o mais recente |
| `Validate` | apenas o registro da validação | não | confere estrutura, contagem, arquivos vazios, leitura real e hashes do manifesto |
| `Backup` | sim | **sim** | exporta os pacotes por `pnputil /export-driver`, gera manifesto e valida |
| `Package` | sim | não | prepara um subconjunto para transporte, com manifesto e `.zip` verificado |
| `Restore` | sim | **sim** | adiciona pacotes de um backup validado por `pnputil /add-driver /install` |

**Destino do backup.** Sem `-Path`, o destino é escolhido nesta ordem: último destino
usado com sucesso, diretório persistente do projeto, área de documentos do usuário,
volume fixo com espaço suficiente e, em último caso, o diretório da sessão. Cada
candidato é validado quanto a caminho protegido, permissão de escrita comprovada por
gravação real e espaço livre. `-Path` informado pelo operador sempre prevalece e nunca
é substituído em silêncio: um caminho inválido interrompe a operação.

**Restauração.** É **simulação por padrão** — sem `-Force` nada é instalado, e a ação
apenas lista o que faria. `-DryRun` força a simulação mesmo com `-Force`. A restauração
exige um backup aprovado na validação (inclusive hashes), nunca remove nem substitui um
driver existente, ignora pacotes já publicados no repositório e confirma o resultado por
reconsulta ao `pnputil`, não pelo código de retorno. Filtros disponíveis: `-InfName`,
`-Provider`, `-DeviceClass` e `-OnlyMissing` (apenas pacotes cujos IDs de hardware
correspondem a dispositivos que hoje reportam driver ausente ou inválido).

**Não existe upload.** O COMPARTDISK não possui integração de envio — `remote.ps1`
apenas baixa o projeto. `Package` entrega o pacote pronto com caminho, tamanho e
SHA-256 para transporte manual, e nenhum envio é tentado ou simulado.

**BitLocker** é somente leitura. Chaves de recuperação podem ser exibidas na tela, mas
**nunca são gravadas em arquivo**.

---

## Aplicativos

Três opções, sob a opção `2` do menu principal, na ordem real de uso: **verificar /
preparar o WinGet**, **Central de Aplicativos** e **atualizar aplicativos**.

**Atualizar aplicativos** permanece a rotina Batch `:MOD_WINGET`: `winget upgrade
--all --include-unknown`, precedida de teste da fonte. Nada nela foi alterado.

**O catálogo de suporte técnico** é o módulo `Apps.ps1`, que instala **apenas o que
estiver ausente**. Não atualiza, não reinstala e não remove — atualizar continua sendo
responsabilidade da outra opção. Ele **deixou de ser opção do menu**: a Central de
Aplicativos passou a ser o caminho único de instalação, e manter as duas era oferecer
a mesma capacidade duas vezes. O catálogo continua íntegro no módulo e disponível em
automação; a Central usa a mesma rotina de instalação — nada foi removido dele.

O catálogo é declarativo: nome, identificador Winget, categoria, descrição, editor,
tipo de instalador, escopo, arquitetura e observações. Menus, numeração, lote,
instalação global e verificação são **derivados** dele; incluir uma ferramenta é
acrescentar uma entrada.

| Categoria | Itens |
|---|---|
| Hardware | HWiNFO, CPU-Z, GPU-Z, CrystalDiskInfo, CrystalDiskMark, OCCT |
| Windows / Sistema | Sysinternals Suite, Process Explorer, Process Monitor, Autoruns, TCPView, RAMMap, WizTree, Everything, Notepad++ |
| Rede | Wireshark, Nmap, Advanced IP Scanner, iperf3, PuTTY, WinSCP |
| Acesso Remoto | TeamViewer, AnyDesk |
| Produtividade | ONLYOFFICE Desktop Editors, Google Chrome |
| Utilitários | 7-Zip, Rufus |

Antes de cada instalação o módulo verifica, nesta ordem: presença do Winget,
disponibilidade da fonte oficial, cobertura pela Sysinternals Suite, presença do
pacote no sistema e existência do identificador na fonte. Só então instala, e
**confirma o estado final** consultando o sistema — código de saída zero não é tratado
como prova de instalação.

Cada item recebe um resultado do vocabulário `INSTALADO`, `JA INSTALADO`,
`NAO ENCONTRADO`, `NAO DISPONIVEL`, `ERRO`, `CANCELADO`, `SEM INTERNET`,
`FONTE INDISPONIVEL`, `ACESSO NEGADO`, `REINICIALIZACAO NECESSARIA` ou
`RECURSO NATIVO`, traduzido do código de retorno real do Winget. Uma falha individual
não interrompe o lote.

Todo item do catálogo possui pacote na fonte oficial do Winget. Os campos `Native` e
`Available` continuam disponíveis para declarar item **não instalável** — recurso
nativo do Windows ou sem pacote oficial —, e o módulo o reporta como `RECURSO NATIVO`
ou `NAO DISPONIVEL` sem inventar identificador. Nenhum download fora do Winget é
realizado.

As cinco ferramentas Sysinternals individuais declaram a suíte que já as contém:
se a Sysinternals Suite estiver instalada, elas não são baixadas de novo.

Em automação, `-Action Install -Id <id>`, `-Action InstallCategory -Category <nome>`,
`-Action InstallAll` e `-Action List` operam sem prompt. O alvo precisa existir no
catálogo interno: identificadores arbitrários são recusados antes de qualquer chamada
ao Winget.

### Central de Aplicativos

**Central de Aplicativos** é a ação `Central` do mesmo `Apps.ps1`: pesquisa pelo nome
na fonte oficial e instala em poucos passos, para quem não conhece o `winget`. É o
caminho de instalação oferecido pelo menu, com a mesma rotina de instalação e as
mesmas verificações do catálogo curado.

A pesquisa normaliza o termo (maiúsculas, acentos, espaços e hífens são ignorados;
**letra de qualquer alfabeto é preservada**), consulta um **catálogo declarativo de**
**apelidos** — `$script:ApelidosCentral`, no próprio módulo — e consulta o Winget. Os
resultados das consultas são consolidados, as duplicidades removidas por identificador
e a ordem é decidida por relevância: correspondência exata, início do nome, parte do
nome, editor, apelido conhecido e, por último, aproximação por distância de edição.
A escada é **nome exato › palavra completa do nome › início do nome › pacote exato ›
parte do nome › início do pacote › parte do pacote › editor**. O nome do aplicativo
pesa mais que o identificador porque `Editor.Pacote` é dado técnico, não é como a
pessoa chama o programa: `cloud` acha o *Google Cloud SDK* pelo **nome**, não porque o
identificador contenha `Cloud`. O identificador é comparado sem o moniker do editor
(`Netpack.XFB` responde por `xfb`), e o editor entra como fator secundário — sem isso,
uma pesquisa por `net` trazia todo pacote da `NetEase` como se o nome começasse por
`net`.

Palavra completa vale mais que ocorrência incidental: em `cloud`, *Google Cloud SDK* e
*Adobe Creative Cloud* ficam à frente de *Nextcloud Desktop*. A **posição** da palavra
no nome entra como desempate leve, e a **cobertura** premia o resultado que atende
todas as palavras do termo — `google chrome` separa o Chrome de qualquer outro
programa do Google por larga margem. A proximidade é medida contra o texto que
**produziu** a correspondência, e não sempre contra o nome. Empates são desfeitos pela
posição em que a fonte oficial devolveu cada resultado — a opinião do próprio Winget
entra como desempate, nunca como critério principal.

Correspondência aproximada nunca supera correspondência direta: em `chrome`, o
*Chromium* fica atrás do *Google Chrome* por construção da escada.

Uma **segunda etapa** de classificação cuida da diversidade: variações do mesmo pacote
— reconhecidas pela família do identificador publicado, os dois primeiros segmentos,
como `Google.Chrome` e `Google.Chrome.Beta` ou `Mozilla.Firefox` e
`Mozilla.Firefox.ESR` — não ocupam várias das primeiras posições: a melhor de cada
família mantém o lugar e as irmãs recuam. **Não é filtro**: nada sai da lista.

### Preferência de idioma

Muitos pacotes publicam uma variante por localidade (`Mozilla.Firefox.af`,
`Mozilla.Firefox.pt-BR`). `Get-AppsPrioridadeIdioma` é a **regra central** — mudar a
preferência é mudar essa função, e só ela: **`pt-BR` › pacote base › `pt` / `pt-PT` ›
`en-US` / `en` › demais localidades**. `pt-PT` não é tratado como equivalente de
`pt-BR`. O peso entra somado à relevância e **nunca filtra**: variante estrangeira
continua listada, em *mais resultados relacionados*.

Um caso não tem localidade a declarar: o pacote sem segmento de idioma no
identificador que publica o **nome em outra escrita** (`Lenovo.LenovoVoice`, exibido em
chinês). `Test-AppsEscritaNaoLatina` constata isso — texto com letras e **nenhuma**
delas latina — e o item passa a pesar como as demais localidades. Não é detecção de
idioma nem vira localidade: `Get-AppsLocalidade` continua lendo só o identificador. O
fator não se aplica quando a **pesquisa** também é em outra escrita: quem procura em
chinês está procurando o que foi publicado em chinês.

`Get-AppsLocalidade` só usa dado objetivo do resultado: o **segmento final do
identificador publicado** (`Mozilla.Firefox.pt-BR`). **Editor não indica idioma** e
**nome exibido também não**: `Mozilla Firefox (en-US)` é o rótulo do pacote *base*
`Mozilla.Firefox` — informa o idioma padrão dele, não que ele seja a variante `en-US`,
que tem identificador próprio (`Mozilla.Firefox.en-US`). O sufixo entre parênteses do
nome entra **apenas para confirmar** um segmento do identificador que as culturas do
.NET não conhecem; sozinho ele nunca cria uma localidade. Um código só é aceito quando
está entre as culturas do .NET **ou** quando identificador e nome declaram o mesmo
código — é o par que confirma `Mozilla.Firefox.ast` sem que `Mozilla.Firefox.ESR`,
`Google.Chrome.Dev` ou `Adobe.Acrobat.Reader.64-bit` sejam confundidos com localidade.

A classificação distingue três coisas que não se misturam: **pacote base**
(`Mozilla.Firefox`, sem localidade), **variante de idioma** (`Mozilla.Firefox.pt-BR`,
localidade explícita) e **outra variante do pacote** (`Mozilla.Firefox.ESR`,
`Mozilla.Firefox.MSIX` — outra edição do mesmo aplicativo, nunca um idioma chamado
`ESR` ou `MSIX`). Pacote sem localidade declarada pesa igual ao base: o que separa
`Mozilla.Firefox.ESR` de `Mozilla.Firefox` é a correspondência com o termo digitado,
não a regra de idioma.

`Get-AppsCodigoLocalidade` normaliza `pt-BR`, `pt_br`, `PTBR` e `ptbr` para a mesma
forma **apenas para comparar**; o nome exibido continua sendo exatamente o que o WinGet
devolveu — o COMPARTDISK não traduz nome de aplicativo.

No recuo por família, o escalonamento vale só para as variantes estrangeiras: base,
`pt-BR`, `pt-PT` e `en-US` recuam por igual, para que a ordem entre elas continue sendo
a da preferência de idioma e não a da fila.

Sem correspondência direta valem, pela melhor delas: **palavras** do termo espalhadas
pelo nome (comparadas uma a uma, sem depender da ordem), semelhança textual e, por
último, coincidência apenas no editor. O cálculo de semelhança sai na frente quando a
diferença de tamanho já reprova o limite — o que mantém rápida uma pesquisa ampla.

**Oficialidade.** O único vínculo que os dados do Winget permitem afirmar é o editor
que consta no identificador publicado: `Google.Chrome` responde por `Google`,
`arjun-g.google-meet-desktop` não. Quando o termo procurado é igual a esse editor, o
pacote recebe reforço; quando existe um pacote do editor procurado, os homônimos de
terceiros perdem posição — mas **continuam listados**. Nada é deduzido a partir do nome
do programa, e nenhum vínculo oficial é inventado.

Rótulos que o próprio Winget publica no nome (`Beta`, `Dev`, `Nightly`, `Insiders`,
`Preview`, `Unofficial`…) reduzem a pontuação para não passarem na frente da versão
principal. São comparados **palavra a palavra**, de modo que `Betaflight` nunca é
confundido com `Beta`, e não penalizam nada quando o operador pediu o rótulo.

Cada resultado guarda `Name`, `Id`, `Publisher`, `Version`, `Source` e a posição
devolvida pela fonte. A tela usa nome, editor e pacote; o resto serve à classificação
e à conferência antes de instalar.

A classificação marca cada item como **destaque** — correspondência direta ou apelido
conhecido, sem nenhuma penalização — e é isso que separa *Melhores resultados* de
*Mais resultados relacionados* na tela. `Get-AppsPesquisa` devolve a lista inteira já
classificada: **nenhum resultado válido do Winget é descartado**; quem exibe é que
decide quantos cabem (oito) e informa o total quando há mais.
`crome` chega a Google Chrome, `7 zip` a 7-Zip, `vs code` a Visual Studio Code e
`vlc` a VLC.

Cada entrada do catálogo declara uma **lista** de identificadores, do mais provável
para o menos: um termo genérico aceita mais de uma resposta legítima, e `office`
coloca Microsoft 365, LibreOffice e ONLYOFFICE à frente dos complementos de nome
parecido. Apenas o primeiro identificador é sondado quando a pesquisa por nome não o
traz; os demais chegam pela própria pesquisa, sem custo adicional.

O catálogo de apelidos **não é uma fonte de pacotes**: ele traduz o termo digitado e
dá preferência ao pacote esperado. Tudo o que aparece na tela e tudo o que é
instalado vem do Winget — um identificador que saia do ar degrada para a pesquisa
normal, sem oferecer item que a fonte oficial não confirme.

Custo típico: **uma** chamada ao Winget por pesquisa. A segunda só ocorre quando o
apelido aponta um pacote que a primeira consulta não trouxe; a terceira, só quando a
primeira não trouxe nada.

A instalação reaproveita integralmente `Invoke-AppInstalacao`, com as mesmas
verificações e o mesmo vocabulário de resultado. Antes da confirmação a Central
checa se o pacote **já está instalado** e, se estiver, informa e não instala:
atualizar continua sendo responsabilidade da opção `1`.

O termo digitado é higienizado, limitado a 60 caracteres e viaja **entre aspas** como
valor de `--query`; `Invoke-NativeCommand` não usa shell. O identificador instalado é
sempre o que o Winget devolveu, validado por forma (`Editor.Pacote`) e confirmado na
fonte oficial. A ação exige console interativo: em automação continuam valendo
`Install`, `InstallCategory`, `InstallAll` e `List`.

### Quando o WinGet não está disponível

`Test-WingetAvailability`, no `Core.ps1`, é o **dono único** do diagnóstico: devolve um
estado estruturado — `Available`, `Outdated`, `Broken`, `Missing`, `Blocked`,
`Unsupported` ou `Unknown` — junto com sistema, build, arquitetura, estado do pacote
App Installer, versão, fonte, Microsoft Store, política e privilégio. Ausência de
`winget.exe` **não** é tratada como prova de que o App Installer não existe: o pacote
AppX é consultado antes de qualquer conclusão, porque o executável é um alias de
execução que some quando o registro do pacote se perde.

`Winget.ps1` age sobre esse estado, usando **apenas mecanismos oficiais**:

| Situação | O que é feito |
|---|---|
| Instalado, mas sem `winget` | Registra novamente o pacote local (`Add-AppxPackage -Register`). Sem download |
| Ausente | Encaminha para a página oficial do App Installer na Microsoft Store |
| Desatualizado | Encaminha para a tela oficial de atualizações da Store |
| Bloqueado por política | Informa e para. Nenhuma política é alterada |
| Windows incompatível | Informa o requisito e para, sem tentar instalar |

Nada é baixado por fora do Windows, não há instalador próprio do WinGet e nenhuma
proteção do sistema é desativada para viabilizar a instalação.

Depois de agir, `Test-WingetHealth` valida o resultado em seis etapas — pacote,
executável, versão, `--info`, fontes e uma consulta de teste. Sucesso só é declarado
quando todas passam.

Em automação, `-Action Status` diagnostica, `-Action Repair` tenta apenas o reparo
local e `-Action Prepare` faz o ciclo completo. Em execução desassistida o módulo
**não abre a Microsoft Store** — uma janela esperando o operador não serve para nada
em máquina sem operador; nesse caso a limitação é declarada e nada é alterado.

---

## Diagnóstico e relatórios

**Auditoria rápida** cobre sistema, hardware, discos, rede, segurança, antivírus,
BitLocker e Windows Update.

**Auditoria completa** acrescenta drivers, contas, serviços, processos, energia,
licenciamento, aplicativos instalados, eventos e integridade — e emite os quatro
formatos de relatório.

**Consolidação** agrega o estado de todos os módulos executados na sessão em um
relatório único.

Cada constatação recebe uma severidade — crítico, atenção, conforme ou informativo — e
uma recomendação de ação. O resumo executivo contabiliza cada categoria.

---

## Registro

Cada entrada de log contém data, hora, computador, usuário, versão e build do Windows,
versão do PowerShell, módulo de origem, tempo de execução, resultado, e — em caso de
exceção — o tipo, o código e o rastreamento de pilha.

O escritor de log higieniza caracteres que o interpretador de comandos trataria como
operadores, o que garante que nenhuma mensagem possa corromper o arquivo.

---

## Modo desassistido

| Parâmetro | Efeito |
|---|---|
| `/autofix` | Reparo geral automático |
| `/audit` | Auditoria completa com os quatro relatórios |
| `/report` | Consolidação e emissão dos relatórios |
| `/clean` | Limpeza profunda |
| `/?` | Ajuda |

---

[Voltar ao índice](../README.md) · Próximo: [Manual do Administrador](MANUAL-DO-ADMINISTRADOR.md)
