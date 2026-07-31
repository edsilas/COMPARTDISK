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

Nenhum erro aberto nesta versão.

Encontrou um? Abra uma *issue* em
https://github.com/edsilas/compartdisk/issues, anexando o relatório HTML e o arquivo
`%TEMP%\COMPARTDISK_Bootstrap.log`.

---

[Voltar ao índice](../README.md) · Próximo: [Boas Práticas](BOAS-PRATICAS.md)
