#!/bin/bash
# Autor: Thais Akemi - RM 573199

TEMPLATE_URL_PADRAO="https://www.free-css.com/assets/files/free-css-templates/download/page296/oxygen.zip"

WEB_ROOT="/var/www/html"
NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named"
TMP_DIR="/tmp/template_gs"
RECORDS=()

VERDE='\e[32m'; AMARELO='\e[33m'; VERMELHO='\e[31m'; AZUL='\e[36m'; NC='\e[0m'

info()  { echo -e "${VERDE}[INFO]${NC}  $*"; }
aviso() { echo -e "${AMARELO}[AVISO]${NC} $*"; }
erro()  { echo -e "${VERMELHO}[ERRO]${NC}  $*" >&2; }
passo() { echo -e "\n${AZUL}==== $* ====${NC}"; }

confirmar() {
    local resp
    read -e -r -p "$1 [s/N]: " resp
    case "${resp,,}" in
        s|sim) return 0 ;;
        *) aviso "Operação cancelada pelo usuário."; exit 0 ;;
    esac
}

valida_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra oct <<< "$ip"
    for o in "${oct[@]}"; do (( o <= 255 )) || return 1; done
}
valida_ipv6() { [[ $1 =~ ^[0-9a-fA-F:]+$ && $1 == *:* ]]; }
valida_dominio() { [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

ler_valido() {
    local pergunta=$1 func=$2 valor
    while true; do
        read -e -r -p "$pergunta" valor
        if $func "$valor"; then echo "$valor"; return; fi
        erro "Valor inválido, tente novamente." >&2
    done
}

fqdn() {
    local alvo=$1
    if [[ $alvo == *. ]]; then echo "$alvo"
    elif [[ $alvo == *.* ]]; then echo "${alvo}."
    else echo "${alvo}.${DOMINIO}."; fi
}

clear
echo "=============================================================="
echo "  AUTOMAÇÃO DE SERVIDOR DNS (BIND) + WEB (APACHE) - AlmaLinux"
echo "  Autor: Thais Akemi - RM 573199"
echo "=============================================================="

if [[ $EUID -ne 0 ]]; then
    erro "Execute como root (use: sudo $0)"
    exit 1
fi

aviso "Este script irá instalar pacotes e alterar configurações do servidor."
confirmar "Deseja continuar?"

passo "PASSO 1 - Coleta de informações"

DOMINIO=$(ler_valido "Informe o nome do domínio (ex: empresa.com.br): " valida_dominio)
DOMINIO=${DOMINIO,,}

IP_SERVIDOR=$(ler_valido "Informe o IPv4 deste servidor (será o NS/ns1): " valida_ipv4)

RECORDS+=("ns1 IN A ${IP_SERVIDOR}")

echo
info "Agora informe os registros DNS desejados para ${DOMINIO}."
info "Use '@' para o domínio raiz (ex: @ ou www)."

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

echo
info "Resumo da configuração:"
echo "  Domínio    : ${DOMINIO}"
echo "  IP servidor: ${IP_SERVIDOR}"
echo "  Registros  : ${#RECORDS[@]}"
echo "  Template   : ${TEMPLATE_URL}"
confirmar "Confirma os dados e deseja iniciar a instalação?"

passo "PASSO 2 - Instalando BIND, Apache e utilitários"
info "Executando: dnf install -y bind bind-utils httpd wget unzip"
if ! dnf install -y bind bind-utils httpd wget unzip; then
    erro "Falha na instalação dos pacotes. Verifique a conexão com a Internet."
    exit 1
fi
info "Pacotes instalados com sucesso."

passo "PASSO 3 - Configurando o servidor DNS (BIND)"

info "Fazendo backup de ${NAMED_CONF}..."
cp -n "$NAMED_CONF" "${NAMED_CONF}.bkp"

info "Liberando escuta e consultas na rede (listen-on / allow-query)..."
sed -i 's/listen-on port 53 *{[^}]*}/listen-on port 53 { any; }/' "$NAMED_CONF"
sed -i 's/listen-on-v6 port 53 *{[^}]*}/listen-on-v6 port 53 { any; }/' "$NAMED_CONF"
sed -i 's/allow-query *{[^}]*}/allow-query     { any; }/' "$NAMED_CONF"

ZONE_FILE="${ZONE_DIR}/db.${DOMINIO}"

if grep -q "zone \"${DOMINIO}\"" "$NAMED_CONF"; then
    aviso "A zona ${DOMINIO} já existe no named.conf. Não será duplicada."
else
    info "Declarando a zona ${DOMINIO} no named.conf..."
    cat >> "$NAMED_CONF" <<EOF

zone "${DOMINIO}" IN {
    type master;
    file "db.${DOMINIO}";
    allow-update { none; };
};
EOF
fi

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

info "Validando configuração (named-checkconf / named-checkzone)..."
if ! named-checkconf "$NAMED_CONF"; then
    erro "Erro de sintaxe no named.conf. Restaure com: cp ${NAMED_CONF}.bkp ${NAMED_CONF}"
    exit 1
fi
if ! named-checkzone "$DOMINIO" "$ZONE_FILE"; then
    erro "Erro de sintaxe no arquivo de zona."
    exit 1
fi

info "Habilitando e iniciando o serviço named..."
systemctl enable named >/dev/null 2>&1
systemctl restart named
systemctl is-active --quiet named && info "named em execução." || { erro "named não iniciou."; exit 1; }

passo "PASSO 4 - Configurando o servidor Web (Apache) e publicando o template"

rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"

info "Baixando template: ${TEMPLATE_URL}"
if wget -q -O "${TMP_DIR}/template.zip" "$TEMPLATE_URL" && \
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

info "Habilitando e iniciando o serviço httpd..."
systemctl enable httpd >/dev/null 2>&1
systemctl restart httpd
systemctl is-active --quiet httpd && info "httpd em execução." || { erro "httpd não iniciou."; exit 1; }

passo "PASSO 5 - Liberando portas no firewall"
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=dns  >/dev/null
    firewall-cmd --permanent --add-service=http >/dev/null
    firewall-cmd --reload >/dev/null
    info "Serviços dns e http liberados no firewalld."
else
    aviso "firewalld inativo. Nenhuma regra foi necessária."
fi

passo "PASSO 6 - Testes finais"
info "Teste DNS: dig @127.0.0.1 ns1.${DOMINIO} +short"
dig @127.0.0.1 "ns1.${DOMINIO}" +short
info "Teste Web: curl -sI http://localhost | head -n 1"
curl -sI http://localhost | head -n 1

echo
info "Processo concluído com sucesso!"
info "Domínio: ${DOMINIO} | Zona: ${ZONE_FILE} | Site: http://${IP_SERVIDOR}"
aviso "Para testar de outra máquina, aponte o DNS dela para ${IP_SERVIDOR}."
