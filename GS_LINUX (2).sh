#!/bin/bash
#==============================================================================
# Script  : GS_LINUX.sh
# Objetivo: Automatizar no AlmaLinux a implantação de um servidor com:
#           - IP fixo (estático)
#           - DNS (BIND) com zona, sem recursão e sem transferência de zona
#           - Web (Apache) com versão oculta no cabeçalho HTTP
#           - Deploy de um Template HTML baixado da Internet
#           - Serviços DNS/HTTP iniciando junto com o sistema
#           - Reboot final (somente se tudo ocorrer com sucesso)
# Uso     : sudo ./GS_LINUX.sh
# Autor   : Thais Akemi - RM 573199
#==============================================================================

#------------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
#------------------------------------------------------------------------------
# Link do template HTML (.zip) usado como padrão
TEMPLATE_URL_PADRAO="https://github.com/StartBootstrap/startbootstrap-grayscale/archive/refs/heads/master.zip"

WEB_ROOT="/var/www/html"                  # Diretório raiz do Apache
HTTPD_CONF="/etc/httpd/conf/httpd.conf"   # Configuração principal do Apache
NAMED_CONF="/etc/named.conf"              # Configuração principal do BIND
ZONE_DIR="/var/named"                     # Diretório das zonas do BIND
TMP_DIR="/tmp/template_gs"                # Diretório temporário do template
DNS_EXTERNO="8.8.8.8"                     # DNS reserva (se nenhum DNS atual for detectado)
RECORDS=()                                # Lista de registros DNS informados
SUCESSO=1                                 # Vira 0 se algum teste final falhar

# Cores usadas nas mensagens
VERDE='\e[32m'; AMARELO='\e[33m'; VERMELHO='\e[31m'; AZUL='\e[36m'; NC='\e[0m'

#------------------------------------------------------------------------------
# FUNÇÕES DE MENSAGEM (informações, avisos, erros e títulos dos passos)
#------------------------------------------------------------------------------
info()  { echo -e "${VERDE}[INFO]${NC}  $*"; }
aviso() { echo -e "${AMARELO}[AVISO]${NC} $*"; }
erro()  { echo -e "${VERMELHO}[ERRO]${NC}  $*" >&2; }
passo() { echo -e "\n${AZUL}==== $* ====${NC}"; }

#------------------------------------------------------------------------------
# FUNÇÃO: confirmar
# Pede confirmação (s/N). Se a resposta não for "s", encerra o script.
#------------------------------------------------------------------------------
confirmar() {
    local resp
    read -e -r -p "$1 [s/N]: " resp
    case "${resp,,}" in
        s|sim) return 0 ;;
        *) aviso "Operação cancelada pelo usuário."; exit 0 ;;
    esac
}

#------------------------------------------------------------------------------
# FUNÇÕES DE VALIDAÇÃO (IPv4, IPv6, domínio e prefixo de rede)
#------------------------------------------------------------------------------
valida_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra oct <<< "$ip"
    for o in "${oct[@]}"; do (( o <= 255 )) || return 1; done
}
valida_ipv6() { [[ $1 =~ ^[0-9a-fA-F:]+$ && $1 == *:* ]]; }
valida_dominio() { [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
valida_prefixo() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 32 )); }

# Lê um valor e só aceita se passar na função de validação informada
ler_valido() {
    local pergunta=$1 func=$2 valor
    while true; do
        read -e -r -p "$pergunta" valor
        if $func "$valor"; then echo "$valor"; return; fi
        erro "Valor inválido, tente novamente." >&2
    done
}

# Igual à anterior, mas Enter aceita o valor padrão sugerido
ler_padrao() {
    local pergunta=$1 padrao=$2 func=$3 valor
    while true; do
        read -e -r -p "${pergunta} [${padrao}]: " valor
        valor=${valor:-$padrao}
        if $func "$valor"; then echo "$valor"; return; fi
        erro "Valor inválido, tente novamente." >&2
    done
}

# Garante que o alvo de CNAME/MX termine com ponto (nome completo)
fqdn() {
    local alvo=$1
    if [[ $alvo == *. ]]; then echo "$alvo"
    elif [[ $alvo == *.* ]]; then echo "${alvo}."
    else echo "${alvo}.${DOMINIO}."; fi
}

#------------------------------------------------------------------------------
# PASSO 0: Verificações iniciais e confirmação do usuário
#------------------------------------------------------------------------------
clear
echo "=============================================================="
echo "  AUTOMAÇÃO DE SERVIDOR DNS (BIND) + WEB (APACHE) - AlmaLinux"
echo "  Autor: Thais Akemi - RM 573199"
echo "=============================================================="

# O script altera configurações do sistema, então exige root
if [[ $EUID -ne 0 ]]; then
    erro "Execute como root (use: sudo $0)"
    exit 1
fi

aviso "Este script instala pacotes, fixa o IP, configura os serviços e REINICIA o servidor no final."
confirmar "Deseja continuar?"

#------------------------------------------------------------------------------
# PASSO 1: Coleta de dados (domínio, rede e registros DNS)
#------------------------------------------------------------------------------
passo "PASSO 1 - Coleta de informações"

DOMINIO=$(ler_valido "Informe o nome do domínio (ex: thais.lab): " valida_dominio)
DOMINIO=${DOMINIO,,}

IP_SERVIDOR=$(ler_valido "Informe o IPv4 fixo deste servidor (será o NS/ns1): " valida_ipv4)

# Detecta interface, gateway e prefixo atuais para sugerir como padrão
IFACE_PAD=$(ip route | awk '/^default/ {print $5; exit}')
GW_PAD=$(ip route | awk '/^default/ {print $3; exit}')
PREFIXO_PAD=$(ip -o -4 addr show dev "$IFACE_PAD" 2>/dev/null | awk '{print $4}' | cut -d/ -f2 | head -n 1)

read -e -r -p "Interface de rede [${IFACE_PAD}]: " IFACE
IFACE=${IFACE:-$IFACE_PAD}
PREFIXO=$(ler_padrao "Prefixo da máscara (ex: 24)" "${PREFIXO_PAD:-24}" valida_prefixo)
GATEWAY=$(ler_padrao "Gateway" "${GW_PAD:-10.0.2.2}" valida_ipv4)

# O NS do domínio (ns1) sempre aponta para o IP do servidor
RECORDS+=("ns1 IN A ${IP_SERVIDOR}")

echo
info "Agora informe os registros DNS desejados para ${DOMINIO}."
info "Use '@' para o domínio raiz (ex: @ ou www)."

# Loop de menu: o usuário escolhe o tipo de registro até digitar 0
while true; do
    echo
    echo "Tipos de registro disponíveis:"
    echo "  1) A       2) AAAA    3) CNAME    4) MX    5) TXT"
    echo "  0) Concluir"
    read -e -r -p "Escolha uma opção: " op
    case $op in
        1)  read -e -r -p "  Nome (ex: @ ou www): " nome
            ip=$(ler_valido "  Endereço IPv4: " valida_ipv4)
            RECORDS+=("${nome} IN A ${ip}")
            info "Registro A adicionado: ${nome} -> ${ip}" ;;
        2)  read -e -r -p "  Nome (ex: @ ou www): " nome
            ip=$(ler_valido "  Endereço IPv6: " valida_ipv6)
            RECORDS+=("${nome} IN AAAA ${ip}")
            info "Registro AAAA adicionado: ${nome} -> ${ip}" ;;
        3)  read -e -r -p "  Nome do alias (ex: ftp): " nome
            read -e -r -p "  Aponta para (ex: www): " alvo
            alvo=$(fqdn "$alvo")
            RECORDS+=("${nome} IN CNAME ${alvo}")
            info "Registro CNAME adicionado: ${nome} -> ${alvo}" ;;
        4)  read -e -r -p "  Prioridade (ex: 10): " prio
            [[ $prio =~ ^[0-9]+$ ]] || { erro "Prioridade inválida."; continue; }
            read -e -r -p "  Servidor de e-mail (ex: mail): " alvo
            alvo=$(fqdn "$alvo")
            RECORDS+=("@ IN MX ${prio} ${alvo}")
            info "Registro MX adicionado: ${prio} ${alvo}" ;;
        5)  read -e -r -p "  Nome (ex: @): " nome
            read -e -r -p "  Texto: " txt
            txt=${txt//\"/}
            RECORDS+=("${nome} IN TXT \"${txt}\"")
            info "Registro TXT adicionado: ${nome}" ;;
        0)  break ;;
        *)  erro "Opção inválida." ;;
    esac
done

read -e -r -p "URL do template HTML (.zip) [Enter = padrão]: " TEMPLATE_URL
TEMPLATE_URL=${TEMPLATE_URL:-$TEMPLATE_URL_PADRAO}

# Resumo para o usuário conferir antes de aplicar as mudanças
echo
info "Resumo da configuração:"
echo "  Domínio    : ${DOMINIO}"
echo "  IP fixo    : ${IP_SERVIDOR}/${PREFIXO} (interface ${IFACE}, gateway ${GATEWAY})"
echo "  Registros  : ${#RECORDS[@]}"
echo "  Template   : ${TEMPLATE_URL}"
confirmar "Confirma os dados e deseja iniciar a instalação?"

#------------------------------------------------------------------------------
# PASSO 2: Instalação dos pacotes (BIND, Apache e utilitários)
#------------------------------------------------------------------------------
passo "PASSO 2 - Instalando BIND, Apache e utilitários"
info "Executando: dnf install -y bind bind-utils httpd wget unzip"
if ! dnf install -y bind bind-utils httpd wget unzip; then
    erro "Falha na instalação dos pacotes. Verifique a conexão com a Internet."
    exit 1
fi
info "Pacotes instalados com sucesso."

#------------------------------------------------------------------------------
# PASSO 3: Configuração de IP fixo (estático) via NetworkManager
#------------------------------------------------------------------------------
passo "PASSO 3 - Configurando IP fixo (estático)"

# Descobre o nome da conexão do NetworkManager ligada à interface
CON=$(nmcli -t -f GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | cut -d: -f2)
if [[ -z $CON ]]; then
    erro "Nenhuma conexão do NetworkManager encontrada para a interface ${IFACE}."
    exit 1
fi

# Mantém os DNS atuais da rede (ex: DNS do laboratório); se não houver, usa o reserva
DNS_ATUAL=$(nmcli -t -f IP4.DNS device show "$IFACE" 2>/dev/null | cut -d: -f2 | paste -sd, -)
DNS_USAR=${DNS_ATUAL:-$DNS_EXTERNO}

info "Conexão: ${CON} | IP: ${IP_SERVIDOR}/${PREFIXO} | Gateway: ${GATEWAY} | DNS: ${DNS_USAR}"
# Método manual = IP fixo (deixa de usar DHCP)
if ! nmcli con mod "$CON" ipv4.method manual \
        ipv4.addresses "${IP_SERVIDOR}/${PREFIXO}" \
        ipv4.gateway "$GATEWAY" ipv4.dns "$DNS_USAR"; then
    erro "Falha ao configurar o IP fixo."
    exit 1
fi
info "Aplicando a configuração de rede..."
nmcli con up "$CON" >/dev/null 2>&1
sleep 3
ip -4 addr show dev "$IFACE" | grep -q "$IP_SERVIDOR" \
    && info "IP fixo ${IP_SERVIDOR} aplicado em ${IFACE}." \
    || { erro "O IP fixo não foi aplicado."; exit 1; }

#------------------------------------------------------------------------------
# PASSO 4: Configuração do DNS (BIND)
#------------------------------------------------------------------------------
passo "PASSO 4 - Configurando o servidor DNS (BIND)"

info "Fazendo backup de ${NAMED_CONF}..."
cp -n "$NAMED_CONF" "${NAMED_CONF}.bkp"

# Escuta em todas as interfaces e aceita consultas da rede
info "Liberando escuta e consultas na rede (listen-on / allow-query)..."
sed -i 's/listen-on port 53 *{[^}]*}/listen-on port 53 { any; }/' "$NAMED_CONF"
sed -i 's/listen-on-v6 port 53 *{[^}]*}/listen-on-v6 port 53 { any; }/' "$NAMED_CONF"
sed -i 's/allow-query *{[^}]*}/allow-query     { any; }/' "$NAMED_CONF"

# SEGURANÇA: desativa consultas recursivas (servidor só responde por seus domínios)
info "Desativando consultas recursivas (recursion no)..."
sed -i 's/recursion yes;/recursion no;/' "$NAMED_CONF"

# SEGURANÇA: proíbe transferência de zona para outros servidores (global)
if ! grep -q "allow-transfer" "$NAMED_CONF"; then
    info "Proibindo transferência de zona (allow-transfer { none; })..."
    sed -i '/recursion no;/a\        allow-transfer { none; };' "$NAMED_CONF"
fi

ZONE_FILE="${ZONE_DIR}/db.${DOMINIO}"

# Declara a zona no named.conf (se ainda não existir), também sem transferência
if grep -q "zone \"${DOMINIO}\"" "$NAMED_CONF"; then
    aviso "A zona ${DOMINIO} já existe no named.conf. Não será duplicada."
else
    info "Declarando a zona ${DOMINIO} no named.conf..."
    cat >> "$NAMED_CONF" <<EOF

zone "${DOMINIO}" IN {
    type master;
    file "db.${DOMINIO}";
    allow-update { none; };
    allow-transfer { none; };
};
EOF
fi

# Cria o arquivo de zona com SOA, NS e os registros informados
info "Criando o arquivo de zona ${ZONE_FILE}..."
SERIAL=$(date +%Y%m%d01)
{
    echo "\$TTL 86400"
    echo "@   IN  SOA ns1.${DOMINIO}. admin.${DOMINIO}. ("
    echo "        ${SERIAL} ; Serial"
    echo "        3600      ; Refresh"
    echo "        1800      ; Retry"
    echo "        604800    ; Expire"
    echo "        86400 )   ; Minimum TTL"
    echo "@   IN  NS  ns1.${DOMINIO}."
    for r in "${RECORDS[@]}"; do echo "$r"; done
} > "$ZONE_FILE"

info "Ajustando permissões e contexto SELinux..."
chown root:named "$ZONE_FILE"
chmod 640 "$ZONE_FILE"
restorecon -v "$ZONE_FILE" >/dev/null 2>&1

# Valida a sintaxe antes de reiniciar o serviço
info "Validando configuração (named-checkconf / named-checkzone)..."
if ! named-checkconf "$NAMED_CONF"; then
    erro "Erro de sintaxe no named.conf. Restaure com: cp ${NAMED_CONF}.bkp ${NAMED_CONF}"
    exit 1
fi
if ! named-checkzone "$DOMINIO" "$ZONE_FILE"; then
    erro "Erro de sintaxe no arquivo de zona."
    exit 1
fi

info "Reiniciando o serviço named..."
systemctl restart named
systemctl is-active --quiet named && info "named em execução." || { erro "named não iniciou."; exit 1; }

#------------------------------------------------------------------------------
# PASSO 5: Configuração do Web (Apache) e publicação do template
#------------------------------------------------------------------------------
passo "PASSO 5 - Configurando o servidor Web (Apache) e publicando o template"

# SEGURANÇA: oculta a versão do Apache no cabeçalho HTTP e nas páginas de erro
info "Ocultando a versão do Apache (ServerTokens Prod / ServerSignature Off)..."
grep -q "^ServerTokens" "$HTTPD_CONF" || echo "ServerTokens Prod" >> "$HTTPD_CONF"
grep -q "^ServerSignature" "$HTTPD_CONF" || echo "ServerSignature Off" >> "$HTTPD_CONF"
httpd -t >/dev/null 2>&1 || { erro "Erro de sintaxe na configuração do Apache."; exit 1; }

rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"

# Baixa o template, extrai e localiza a pasta que contém o index.html
info "Baixando template: ${TEMPLATE_URL}"
if wget -q --user-agent="Mozilla/5.0" -O "${TMP_DIR}/template.zip" "$TEMPLATE_URL" && \
   unzip -q -o "${TMP_DIR}/template.zip" -d "${TMP_DIR}/extraido"; then

    INDEX=$(find "${TMP_DIR}/extraido" -iname "index.html" | head -n 1)
    if [[ -n $INDEX ]]; then
        ORIGEM=$(dirname "$INDEX")
        info "Template encontrado em: ${ORIGEM}"
        info "Limpando ${WEB_ROOT} e copiando arquivos do template..."
        rm -rf "${WEB_ROOT:?}"/*
        cp -r "${ORIGEM}"/. "$WEB_ROOT"/
    else
        aviso "index.html não encontrado no template. Criando página padrão."
        echo "<h1>Bem-vindo a ${DOMINIO}</h1>" > "${WEB_ROOT}/index.html"
    fi
else
    aviso "Não foi possível baixar/extrair o template. Criando página padrão."
    echo "<h1>Bem-vindo a ${DOMINIO}</h1>" > "${WEB_ROOT}/index.html"
fi

info "Ajustando permissões e contexto SELinux de ${WEB_ROOT}..."
chown -R apache:apache "$WEB_ROOT"
restorecon -R "$WEB_ROOT" >/dev/null 2>&1

info "Reiniciando o serviço httpd..."
systemctl restart httpd
systemctl is-active --quiet httpd && info "httpd em execução." || { erro "httpd não iniciou."; exit 1; }

#------------------------------------------------------------------------------
# PASSO 6: Inicialização automática dos serviços com o sistema (boot)
#------------------------------------------------------------------------------
passo "PASSO 6 - Habilitando DNS e HTTP na inicialização do sistema"
info "Executando: systemctl enable named httpd"
systemctl enable named httpd >/dev/null 2>&1
for s in named httpd; do
    if systemctl is-enabled --quiet "$s"; then
        info "Serviço ${s} habilitado no boot."
    else
        erro "Serviço ${s} NÃO foi habilitado no boot."; SUCESSO=0
    fi
done

#------------------------------------------------------------------------------
# PASSO 7: Firewall (libera DNS e HTTP)
#------------------------------------------------------------------------------
passo "PASSO 7 - Liberando portas no firewall"
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=dns  >/dev/null
    firewall-cmd --permanent --add-service=http >/dev/null
    firewall-cmd --reload >/dev/null
    info "Serviços dns e http liberados no firewalld."
else
    aviso "firewalld inativo. Nenhuma regra foi necessária."
fi

#------------------------------------------------------------------------------
# PASSO 8: Testes finais (qualquer falha impede o reboot)
#------------------------------------------------------------------------------
passo "PASSO 8 - Testes finais"

info "Teste DNS: dig @127.0.0.1 ns1.${DOMINIO} +short"
RESP_DNS=$(dig @127.0.0.1 "ns1.${DOMINIO}" +short)
echo "$RESP_DNS"
[[ $RESP_DNS == "$IP_SERVIDOR" ]] || { erro "DNS não respondeu o IP esperado."; SUCESSO=0; }

info "Teste Web: código HTTP de http://localhost"
COD_HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://localhost)
echo "HTTP ${COD_HTTP}"
[[ $COD_HTTP == "200" ]] || { erro "Apache não respondeu 200."; SUCESSO=0; }

info "Cabeçalho Server (não deve mostrar a versão):"
curl -sI http://localhost | grep -i '^Server'

#------------------------------------------------------------------------------
# PASSO 9: Reboot (somente se tudo foi realizado com sucesso)
#------------------------------------------------------------------------------
passo "PASSO 9 - Finalização"
if [[ $SUCESSO -eq 1 ]]; then
    info "Processo concluído com sucesso!"
    info "Domínio: ${DOMINIO} | Zona: ${ZONE_FILE} | Site: http://${IP_SERVIDOR}"
    aviso "O servidor será REINICIADO em 10 segundos (Ctrl+C para cancelar)..."
    sleep 10
    reboot
else
    erro "Houve falhas durante o processo. O servidor NÃO será reiniciado."
    exit 1
fi
