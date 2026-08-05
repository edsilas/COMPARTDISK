# Limitações Conhecidas

**COMPARTDISK 1.2.0** · Desenvolvido por Edsilas

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

Não atualiza drivers pela internet, não baixa pacotes de reparo e não contata
servidores. O backup de drivers salva os que já estão instalados; ele não busca
versões novas.

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
- inventário de programas instalados apenas para o usuário.

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

### Sem PowerShell, o diagnóstico é mais simples

Quando o PowerShell está indisponível, todas as funções continuam acessíveis, mas:

- os relatórios em HTML, JSON e CSV não são gerados — apenas o log em texto;
- algumas leituras de hardware ficam menos detalhadas;
- o resumo executivo com classificação de severidade não é produzido.

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
