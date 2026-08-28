# Limitações Conhecidas

**COMPARTDISK 1.4.8** · Desenvolvido por Edsilas

Ser honesto sobre o que a ferramenta **não** faz é tão importante quanto documentar o
que ela faz. Esta página lista os limites reais.

---

## Limites por decisão de projeto

### Só usa componentes nativos do Windows

O projeto não usa bibliotecas, módulos ou programas de terceiros. Isso garante que
funcione em qualquer máquina sem instalação e sem risco de dependências, mas impõe
limites:

- **Temperatura de componentes** — o Windows expõe pouca informação térmica. Muitos
  equipamentos não reportam nada, e a leitura pode aparecer vazia.
- **Dados SMART detalhados** — a ferramenta lê os contadores de confiabilidade que o
  Windows expõe. Programas dedicados leem atributos SMART brutos que o Windows não
  disponibiliza.
- **Velocidade de ventoinhas e tensões** — não disponível pelas interfaces nativas.

### Não instala nem baixa nada

Não atualiza drivers pela internet e não baixa pacotes de reparo do Windows. O backup
de drivers salva os que já estão instalados; ele não busca versões novas.

São três os pontos em que a ferramenta contata a rede por conta própria, todos
explícitos na interface: o **teste de conectividade** (`[3]` › `[5]`), que consulta os
servidores de teste da Microsoft e o DNS público `8.8.8.8`; a **atualização de
definições do Defender** (`[6]` › `[3]`), que baixa as assinaturas dos servidores da
Microsoft; e o **reparo profundo da imagem** (`[5]` › `[1]`, também executado pelo
Reparo Geral Automático), em que o `DISM /RestoreHealth` busca no Windows Update os
arquivos que faltam no armazenamento local de componentes. Nenhum dado da máquina é
enviado em nenhum dos três.

> A atualização de definições do Defender **não** faz parte do Reparo Geral
> Automático: ela é executada apenas quando você escolhe `[6]` › `[3]`.

### Não altera arquivos pessoais

Nenhuma função da ferramenta apaga, move ou modifica documentos, fotos ou arquivos do
usuário. As limpezas atuam exclusivamente sobre temporários e caches.

---

## Limites técnicos

### Operações que exigem reinicialização

Algumas correções só passam a valer depois de reiniciar o Windows:

- reset de rede (Winsock, TCP/IP);
- verificação de disco (executa antes da tela de logon);
- parte dos reparos de arquivos de sistema;
- reset de componentes do Windows Update.

A ferramenta avisa quando isso se aplica.

### Remoção de aplicativos não é reversível localmente

O módulo de Desbloat reverte serviços, tarefas agendadas e ajustes de registro ao
valor exato anterior, a partir do manifesto gravado em cada execução. **Aplicativos
removidos são exceção:** o Windows não retém o pacote original em disco após a
remoção, então a reversão apenas lista o que foi removido para reinstalação pela
Microsoft Store. Antes de aplicar qualquer nível acima de Seguro, use a simulação.

A limpeza do armazenamento de componentes também é definitiva, e com `/ResetBase`
(nível Avançado) as atualizações já instaladas deixam de ser desinstaláveis.

### O perfil usado é o de quem elevou
A ferramenta roda elevada. Quando a elevação é feita com **uma conta de administrador
diferente** da que está usando o computador — cenário comum em ambiente corporativo —
as operações que dependem do perfil do usuário atuam sobre o perfil do administrador,
não sobre o de quem está logado. Isso afeta:

- limpeza de caches de navegadores;
- redefinição das preferências de exibição de pastas;
- inventário de programas instalados apenas para o usuário;
- ajuste dos efeitos visuais pelos planos de energia (`[2]` › `[1]` e `[2]` › `[2]`);
- identificador de publicidade e retorno de experiência, no módulo de telemetria;
- sugestões e conteúdo entregue pelo Windows, no módulo de desbloat;
- leitura da configuração de proxy (`[3]` › `[6]`), que reporta o proxy do
  administrador, não o do usuário logado.

Quando a elevação é a do próprio usuário (o caso doméstico, em que o Windows apenas
pede a confirmação do Controle de Conta de Usuário), o perfil é o mesmo e não há
divergência.

### Arquivos em uso

Pastas e arquivos abertos por processos ativos não podem ser renomeados ou apagados.
Nesses casos a ferramenta registra um aviso, em vez de falhar silenciosamente. O caso
mais comum é a pasta de distribuição do Windows Update, quando o serviço não parou
completamente.

### Limpeza é irreversível

Arquivos apagados pelas opções de limpeza **não vão para a lixeira**. Por isso existe
a opção de simulação (menu `4` → `4`), que mede o espaço recuperável sem apagar nada.

### Os backups do Windows Update não são apagados automaticamente

**Pendência operacional — limpeza manual.**

O reset do Windows Update (`[5]` › `[2]`, e a etapa 3 do Reparo Geral Automático) não
apaga os repositórios: renomeia. A cada execução em que houve o que redefinir, ficam
no disco:

| Backup | Conteúdo | Tamanho típico |
|---|---|---|
| `C:\Windows\SoftwareDistribution.old[_<carimbo>]` | `DataStore.edb` (histórico de atualizações), `ReportingEvents.log`, downloads | dezenas de MB |
| `C:\Windows\System32\catroot2.old[_<carimbo>]` | bases de catálogo do CryptSvc | dezenas de MB |

O primeiro backup fica sem carimbo de data: é o estado anterior à primeira execução da
ferramenta, e é o que se preserva de propósito. Os seguintes recebem carimbo.

**A ferramenta não remove nenhum deles, e isso é deliberado.** O `DataStore.edb` guarda
o histórico de atualizações da máquina, que não é regenerável; a própria ferramenta
recomenda repetir o reset quando algo fica bloqueado, de modo que um backup antigo pode
ser a única cópia do estado anterior. Exclusão automática dentro de `C:\Windows`, em
execução desassistida, seria destrutiva por natureza — não há política de retenção
suficientemente segura definida pelo projeto.

Quando o Windows Update voltar a funcionar e o espaço fizer falta, a remoção é decisão
do administrador, feita à mão, em sessão elevada, conferindo antes o que cada pasta
contém. Não existe tarefa agendada, rotina automática nem opção de menu para isso.

> No modo degradado, sem PowerShell, o `catroot2.old` anterior **é** removido antes de
> um novo reset. A rotina Batch usa nome de destino fixo, e `ren` falha quando o destino
> já existe: sem a remoção, o `catroot2` não seria redefinido a partir da segunda
> execução. O `SoftwareDistribution.old` continua preservado também nesse caminho,
> porque ali o nome do backup recebe o identificador da sessão.

### A proteção de endereço fixo é decidida pelo IPv4

O reset de rede pula a redefinição da pilha quando encontra interface com endereço IPv4
fixo — ou quando não consegue determinar o modo de endereçamento. Esse mesmo critério
decide as duas famílias: IPv4 **e** IPv6.

A consequência é declarada: numa interface que receba IPv4 por DHCP e tenha IPv6
configurado à mão, o reset é permitido e o `netsh int ipv6 reset` devolve também o IPv6
ao padrão. É uma configuração incomum, e o critério é o mesmo nos dois caminhos — módulo
PowerShell e rotina Batch —, então não há divergência entre eles. Quem mantiver IPv6
manual deve conferir a configuração depois do reset, ou não executar a opção.

Endereço IPv6 de link local (`fe80::`) não conta como configuração manual: ele é gerado
pelo próprio Windows e recriado sozinho.

### Sem PowerShell, o diagnóstico é mais simples

Quando o PowerShell está indisponível, todas as funções continuam acessíveis, mas:

- os relatórios em HTML, JSON e CSV não são gerados — apenas o log em texto;
- algumas leituras de hardware ficam menos detalhadas;
- o resumo executivo com classificação de severidade não é produzido.

### O reparo de impressão não prova que a página vai sair

O módulo de impressão valida toda correção relendo o estado real: serviço, chave de
registro, impressora padrão, conectividade. Nenhuma dessas leituras prova que um
documento será impresso — só um teste de impressão real confirma isso, e o módulo diz
isso explicitamente ao final de cada correção.

Além disso, ele **não** age no servidor de impressão: quando a causa está lá (servidor
desatualizado, compartilhamento sem permissão, driver não publicado para a arquitetura
do cliente), o diagnóstico identifica e localiza o problema, mas a correção é do lado
do servidor.

### Diagnóstico de impressão sem PowerShell é apenas leitura

A rotina Batch de contingência mostra spooler, impressoras e políticas, e declara em
tela o que não consegue verificar (conectividade do servidor, SMB, RPC, fila, drivers
e portas). Ela **não** aplica correção alguma: sem PowerShell não há como gravar o
backup do valor anterior, e uma correção sem backup seria irreversível.

### A reversão de impressão cobre só o que o módulo alterou

A opção `[7]` › `[10]` restaura exclusivamente valores gravados pelo próprio módulo,
na mesma máquina, e que ainda não foram revertidos. Ela não desfaz configuração de
impressão anterior ao uso da ferramenta, não restaura estado de outro computador e não
reconhece backup sem identificação.

### Códigos de erro de impressão vêm do log dos últimos 7 dias

A identificação do código exato depende do que o Windows registrou em
`Microsoft-Windows-PrintService/Admin` e no log `System`. Esse log costuma vir
desabilitado, a leitura é limitada aos 500 eventos mais recentes de nível 1 a 3, e um
erro mais antigo que a janela consultada não aparece. Nesses casos o diagnóstico
continua funcionando pelas pré-condições observadas, mas informa que o código não foi
observado, em vez de afirmar qual erro ocorreu.

O reconhecimento da resposta "nenhum evento encontrado" é feito pelo texto da mensagem,
em português e em inglês. Em um Windows com outro idioma de exibição essa resposta pode
não ser reconhecida, e o log passa a ser reportado como **não consultado**. A degradação
é conservadora — a ferramenta deixa de afirmar "nenhum erro no período" e passa a dizer
que não conseguiu consultar —, mas é uma limitação real.

### Quando o WMI não responde, o diagnóstico de impressão não conclui

Impressoras, fila, drivers e portas são lidos pelo repositório WMI. Quando ele não
responde — repositório corrompido, serviço parado, acesso negado —, o módulo declara cada
uma dessas leituras como **não consultada** e as regras que dependem delas saem como
**não avaliadas**. Ele não conclui "nenhuma impressora instalada" nem "nenhum problema
encontrado" a partir de uma consulta que falhou. O diagnóstico correto nesse caso é tratar
a integridade do Windows primeiro, pela opção `5` do menu principal.

---

## Limites de escopo

### Não é antivírus

A ferramenta consulta e aciona o Microsoft Defender, mas não faz detecção própria de
ameaças e não remove malware por conta própria.

### Não é ferramenta de recuperação de dados

Ela informa quando um disco está com problema, mas não recupera arquivos perdidos nem
repara sistemas de arquivos gravemente corrompidos.

### Não substitui backup

Nenhuma função aqui faz backup dos seus arquivos. O "backup de drivers" salva apenas
drivers. Mantenha uma rotina de backup própria.

### Não faz otimização mágica

As opções de desempenho ajustam plano de energia e efeitos visuais, e mostram o que
pesa na inicialização. Elas não aceleram hardware antigo além do que ele permite.

---

## Situações não suportadas

| Situação | Observação |
|---|---|
| Windows 8.1 e anteriores | Fora do escopo do projeto |
| Windows em modo de segurança | Vários serviços necessários não estão ativos |
| Execução sem privilégio administrativo | Funciona em modo muito reduzido; avisa na tela |
| Ambiente de recuperação (WinRE) | Não suportado |
| Contêineres e Windows Sandbox | Não testado |

---

## Erros conhecidos

Nenhum erro aberto nesta versão. Os defeitos já corrigidos estão listados no
[Histórico de Mudanças](../CHANGELOG.md).

Encontrou um? Abra uma *issue* em
https://github.com/edsilas/compartdisk/issues, anexando o relatório HTML e o arquivo
`%TEMP%\COMPARTDISK_Bootstrap.log`.

---

[Voltar ao índice](../README.md) · Próximo: [Boas Práticas](BOAS-PRATICAS.md)
