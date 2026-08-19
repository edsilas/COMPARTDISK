# Guia de Utilização

**COMPARTDISK 1.4.4** · Desenvolvido por Edsilas

Como usar a ferramenta no dia a dia. Se você quer a explicação de cada opção
individualmente, vá para o [Manual do Usuário](MANUAL-DO-USUARIO.md).

---

## Como navegar

A ferramenta funciona inteiramente por **teclas numéricas**. Não há mouse, não há
campos para preencher.

1. A tela mostra uma lista de opções numeradas.
2. Você aperta o número desejado.
3. A ação começa imediatamente — **não é preciso apertar Enter**.

Em todas as telas:

- **`0`** volta para a tela anterior (no menu principal, encerra o programa).
- Ao terminar uma operação, aperte qualquer tecla para voltar ao menu.

## As três cores das mensagens

| Cor | Significado |
|---|---|
| Verde | Deu certo |
| Amarelo | Terminou, mas com ressalvas — vale ler |
| Vermelho | Falhou |
| Ciano | Informação, andamento |

## Operações demoradas

Algumas opções levam bastante tempo. **É normal, e não travou.**

| Operação | Tempo típico |
|---|---|
| Reparo Profundo (SFC + DISM) | 15 a 45 minutos |
| Varredura Completa do Defender | 1 a 4 horas |
| Auditoria Completa | 1 a 5 minutos |
| Limpeza Profunda | 2 a 15 minutos |
| Reparo Geral Automático | 20 a 60 minutos |

Durante essas operações a tela pode ficar parada por vários minutos sem mostrar
progresso. Não feche a janela.

---

## Roteiros práticos

### "Meu computador está lento"

1. **[8] → [2]** Auditoria Rápida — para ver se há algo evidente
2. **[4] → [4]** Simular Limpeza — descobre quanto espaço dá para liberar
3. **[4] → [1]** Limpeza Customizada — libera de fato
4. **[4] → [6]** Análise de Desempenho — mostra o que pesa na inicialização
5. **[7] → [1]** Saúde Física dos Discos — disco com defeito é causa comum de lentidão

### "Estou sem internet"

1. **[3] → [4]** Diagnóstico de Adaptadores — mostra o estado da rede
2. **[3] → [5]** Teste de Conectividade — identifica onde a conexão para
3. **[3] → [1]** Reset Completo — resolve a maioria dos casos

> Depois do reset, **reinicie o computador**. Sem reiniciar, a correção pode não valer.

### "O Windows Update não funciona"

1. **[5] → [6]** Status e Histórico — mostra os serviços e o que já foi instalado
2. **[5] → [2]** Destravar Windows Update — reinicia os componentes
3. **[5] → [7]** Procurar Atualizações Pendentes

### "O Windows está com erros estranhos"

1. **[5] → [1]** Reparo Profundo — verifica e repara os arquivos do sistema
2. Ao terminar, **reinicie**
3. **[8] → [1]** Auditoria Completa — confirma que ficou tudo certo

### "Quero saber tudo sobre esta máquina"

**[8] → [1]** Auditoria Completa. Ao final, o relatório HTML abre sozinho no
navegador, com resumo executivo e todas as seções.

### "Não sei o que fazer — quero que resolva sozinho"

**[1] Reparo Geral Automático**. Executa, em sequência: limpeza, reset de rede,
reparo do Windows Update, fila de impressão, Explorer, reparo profundo do sistema e
relatório final.

Leva de 20 a 60 minutos. Ao terminar, **reinicie o computador**.

---

### Roteiro 5 — Computador novo, cheio de aplicativos de fábrica

| Passo | Teclas | O que acontece |
|---|---|---|
| 1 | `8` `2` | Auditoria rápida, para ter o retrato inicial |
| 2 | `4` `9` `1` | Simula o desbloat e lista o que seria removido |
| 3 | `4` `9` `9` `2` | Registra o estado atual, antes de mudar qualquer coisa |
| 4 | `4` `9` `2` | Executa o nível Seguro |
| 5 | `4` `9` `8` | Compacta os componentes obsoletos |
| 6 | — | Reinicia |
| 7 | `8` `3` | Consolida o relatório da sessão |

Reserve de vinte a quarenta minutos, quase todos no passo 5. Se algum programa fizer
falta depois, `4` `9` `9` `4` desfaz.

---

## Lendo o relatório HTML

O relatório abre no navegador e tem três partes:

**Topo** — contadores de itens críticos, em atenção e conformes. É o resumo:
se estiver tudo em verde, a máquina está bem.

**Filtro** — botões para mostrar apenas críticos, apenas avisos, etc.

**Seções** — clique no título para abrir ou fechar. Cada linha traz um marcador:

| Marcador | O que significa |
|---|---|
| `[ OK ]` | Está como deveria |
| `[WARN]` | Merece atenção, mas não é urgente |
| `[CRIT]` | Precisa de providência |
| `[INFO]` | Só informação |

O arquivo é independente: você pode enviá-lo por e-mail ou anexar a um chamado.
Ele não precisa de internet para abrir.

---

## Recomendações

- Antes de usar opções que alteram o sistema, rode uma auditoria — assim você tem
  um retrato do "antes".
- Prefira sempre as opções de leitura (menus [8] e [9], e as de status) para
  entender o problema antes de agir.
- Reinicie o computador depois de reparos de rede ou de sistema.
- Se algo der errado, o arquivo `Relatorio_Manutencao.txt` registra tudo que foi feito.

Mais em [Boas Práticas](BOAS-PRATICAS.md).

---

[Voltar ao índice](../README.md) · Próximo: [Manual do Usuário](MANUAL-DO-USUARIO.md)
