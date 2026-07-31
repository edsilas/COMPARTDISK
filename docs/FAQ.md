# Perguntas Frequentes

**COMPARTDISK 1.2.0** · Desenvolvido por Edsilas

---

## Sobre a ferramenta

**O que é o COMPARTDISK?**
Um programa de manutenção para Windows 10 e 11. Reúne em menus as tarefas de reparo,
limpeza, diagnóstico e verificação de segurança que normalmente exigiriam muitos
comandos digitados à mão.

**Preciso saber programar?**
Não. Você navega por menus numerados e aperta teclas.

**É gratuito?**
Sim, sob a Licença MIT. Você pode usar, copiar, modificar e distribuir.

**Preciso instalar?**
Não. Descompacte e execute. Para remover, apague a pasta.

**Funciona em Windows 7 ou 8?**
Não é suportado. O projeto tem como alvo Windows 10 e 11. Veja
[Compatibilidade](COMPATIBILIDADE.md).

**Funciona em Windows Home?**
Sim, integralmente. Recursos que a edição Home não possui — como diretivas de grupo —
são detectados e reportados como indisponíveis, sem erro.

---

## Segurança

**É seguro?**
O código é aberto e legível: são arquivos de texto que você pode abrir no Bloco de
Notas. Usa apenas componentes que já vêm no Windows, não baixa nada da internet e não
envia dados para lugar nenhum.

**Vai apagar meus arquivos?**
Não. As limpezas atuam sobre arquivos temporários e caches. Documentos, fotos, senhas
de navegador e favoritos não são tocados.

**Por que o antivírus reclamou?**
Porque a ferramenta mexe em rede, registro e serviços — comportamento que antivírus
tratam com desconfiança por padrão. É um falso positivo. Se confiar, adicione a pasta
às exclusões.

**Por que precisa de administrador?**
Reparar o Windows, alterar rede e ler informações de hardware exigem esse nível de
permissão. Sem ele, o Windows recusaria quase tudo.

**A ferramenta envia dados para alguém?**
Não. Nenhuma função faz conexão de saída, exceto as que existem para isso: atualizar
programas, procurar atualizações do Windows e o teste de conectividade.

---

## Uso

**Por onde começo?**
Menu `8`, opção `2` (Auditoria Rápida). Não altera nada e mostra o estado da máquina.

**Qual opção resolve mais coisas?**
Menu `1` (Reparo Geral Automático). Mas leva de 20 a 60 minutos.

**Travou. A tela não muda há minutos.**
Provavelmente não travou. Reparo Profundo e varreduras completas ficam longos
períodos sem exibir progresso.

**Preciso reiniciar depois?**
Depois de reparos de rede, de sistema ou do Windows Update, sim.

**Posso usar o computador enquanto roda?**
Nas operações de leitura, sim. Durante reparos e varreduras, é melhor não.

**Com que frequência devo usar?**
Não há necessidade de uso periódico. Use quando houver um problema, ou uma auditoria
de vez em quando para acompanhar a saúde dos discos.

---

## Relatórios

**Onde ficam os relatórios?**
Na pasta `COMPARTDISK_Relatorios`, dentro da pasta do programa — ou na sua Área de
Trabalho, se a pasta do programa for somente-leitura. O caminho exato aparece no
rodapé do menu principal.

**Qual arquivo devo enviar ao suporte?**
O `.html`. É completo e abre em qualquer navegador, sem precisar de internet.

**Posso apagar relatórios antigos?**
Sim. Apague as subpastas à vontade.

**O relatório mostra dados pessoais?**
Mostra nome do computador, nome de usuário, número de série do equipamento e lista de
programas instalados. Não contém senhas, arquivos pessoais nem histórico de navegação.
Chaves de recuperação do BitLocker são exibidas na tela, mas **nunca gravadas em
arquivo**.

---

## Problemas comuns

**Aparece "O Windows protegeu o computador".**
É o SmartScreen. Clique em **Mais informações** e depois em **Executar assim mesmo**.

**A janela abre e fecha na hora.**
Consulte [Solução de Problemas](SOLUCAO-DE-PROBLEMAS.md). O arquivo
`COMPARTDISK_Bootstrap.log`, na pasta temporária do Windows, aponta exatamente onde
a partida parou.

**Diz "Motor: Batch" — está errado?**
Não. Significa que o PowerShell não está disponível ou foi bloqueado por política.
Todas as funções continuam acessíveis; apenas o diagnóstico fica mais simples.

**Uma opção respondeu "recurso não suportado".**
Seu hardware ou sua edição do Windows não tem aquele recurso — por exemplo, relatório
de bateria em computador de mesa, ou BitLocker em edição que não o oferece. É o
comportamento correto.

**O log está vazio ou incompleto.**
Verifique se a pasta aceita gravação. A ferramenta tenta a pasta do programa, depois a
Área de Trabalho, depois a pasta temporária.

---

## Em ambiente corporativo

**Posso usar em computador da empresa?**
Tecnicamente sim, mas confirme com o setor de TI. As opções do menu `6` podem desfazer
configurações aplicadas de propósito pela organização.

**Dá para rodar sem interação, por script?**
Sim. Veja [Manual do Administrador](MANUAL-DO-ADMINISTRADOR.md).

**Funciona a partir de um compartilhamento de rede?**
Sim. Se o compartilhamento for somente-leitura, os relatórios vão para a Área de
Trabalho automaticamente.

---

## Projeto

**Como reporto um problema ou sugiro algo?**
Abra uma *issue* em https://github.com/edsilas/compartdisk/issues.

**Como sei qual versão tenho?**
No topo da tela principal, ou no menu `9`.

**Como atualizo?**
Baixe a versão nova e substitua os arquivos. Veja
[Política de Atualização](ATUALIZACAO.md).

**Quem desenvolveu?**
Edsilas. Veja [Créditos](CREDITOS.md).

---

[Voltar ao índice](../README.md) · Próximo: [Solução de Problemas](SOLUCAO-DE-PROBLEMAS.md)
