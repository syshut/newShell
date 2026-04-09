#!/bin/bash

# 设置虚拟内存
curl -O https://raw.githubusercontent.com/syshut/myShell/refs/heads/main/create_swap.sh
chmod +x create_swap.sh && sudo ./create_swap.sh
apt update && apt upgrade -y

# 检查 jq 是否安装，如果没有安装，则进行安装
if ! command -v jq &> /dev/null; then
	echo "jq 未安装，正在安装 jq..."
	sudo apt install -y jq
fi

# 安装 xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

XRAY_CONFIG_DIR="/usr/local/etc/xray/confs"
mkdir -p /usr/local/etc/xray/secrets ${XRAY_CONFIG_DIR}

# 使用 sed 替换 ExecStart 行
SOURCE_FILE="/etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf"
TARGET_FILE="/etc/systemd/system/xray.service.d/multi_conf.conf"
if [ -f "$SOURCE_FILE" ]; then
	cp "${SOURCE_FILE}" "${TARGET_FILE}"
	sed -i "s|ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json|ExecStart=/usr/local/bin/xray run -confdir $XRAY_CONFIG_DIR|" "$TARGET_FILE"
else
	echo "源文件不存在：$SOURCE_FILE"
	exit 1
fi

# Step 1: 生成 uuid、key、shortid 到文件
cd ${XRAY_CONFIG_DIR} || exit
/usr/local/bin/xray uuid > uuid
/usr/local/bin/xray uuid > uuid2
/usr/local/bin/xray x25519 > key
openssl rand -hex 8 > sid

# 检查文件是否成功生成
if [ ! -s uuid ] || [ ! -s uuid2 ] || [ ! -s key ] || [ ! -s sid ]; then
	echo "生成 uuid、key 或 sid 失败！"
	exit 1
fi

# 从生成的文件中读取数据
UUID=$(cat uuid)
UUID1=$(cat uuid1)
PRIVATE_KEY=$(awk -F ': ' '/PrivateKey/ {print $2}' key)
PUBLIC_KEY=$(awk -F ': ' '/Password/ {print $2}' key)
SHORTID=$(cat sid)

# Step 2: 下载配置文件
CONFIG_FILE="${XRAY_CONFIG_DIR}/VLESS-XHTTP-REALITY.json"

for i in {1..3}; do
	curl -sSL -o "${CONFIG_FILE}" "https://raw.githubusercontent.com/syshut/newShell/refs/heads/main/config_server.json" && break
	echo "尝试重新下载配置文件 ($i/3)..."
	sleep 2
done

if [ ! -f "${CONFIG_FILE}" ] || [ ! -s "${CONFIG_FILE}" ]; then
	echo "配置文件下载失败！"
	exit 1
fi

# 用户选择是否偷自己
echo "请选择是否偷自己（输入1选择偷自己，输入2选择偷别人）"
read -p "请输入选择（1/2）: " CHOICE
if [ "$CHOICE" -eq 1 ]; then
	echo "您选择了偷自己"
	read -p "请输入您的自有域名 (不含 www，如 example.com): " DOMAIN
	if [ -z "$DOMAIN" ]; then
		echo "Domain 不能为空！"
		exit 1
	fi
else
	echo "您选择了偷别人"
	read -p "请输入 target 伪装域名 (如 www.uclahealth.org): " DOMAIN
	if [ -z "$DOMAIN" ]; then
		echo "target 不能为空！"
		exit 1
	fi
fi

read -p "请输入别名: " REMARKS

read -p "请输入网站的端口号 (如 443): " PORT

if [ "$CHOICE" -eq 1 ]; then
	read -p "请输入 Reality 的端口号 (如 8443): " RPORT
fi

# 验证输入是否为1到5位的数字，并且在1到65535之间
if ! [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$PORT" -gt 65535 ]; then
	echo "端口号无效！"
	exit 1
fi

read -p "请输入 path (如 xhttp / VLSpdG9k): " path
if [ -z "$path" ]; then
	echo "path 不能为空！"
	exit 1
fi

# Step 3: 修改 routing 域名
# 修改 "port" 字段
sed -i "s|\"example\\.com\"|\"domain:${DOMAIN}\"|g" "${CONFIG_FILE}"

# Step 4: 修改配置文件
# 修改 "port" 字段
sed -i "/\"inbounds\":/,/]/s/\"port\": 80/\"port\": $PORT/" "$CONFIG_FILE"

# Step 5: 替换 "id" 字段
sed -i "s/\"id\": \".*\"/\"id\": \"$UUID\"/" "$CONFIG_FILE"

# Step 6: inbounds 中 serverNames 域名
# 修改 "port" 字段
sed -i "s|\"h3a.example.com\"|\"${DOMAIN}\"|g" "${CONFIG_FILE}"

# Step 7: 修改 "target" 和 "serverNames" 中的域名
if [ "$CHOICE" -eq 1 ]; then
  sed -i "s/\"target\": \".*\"/\"target\": \"\/dev\/shm\/uds${RPORT}.sock\"/" "$CONFIG_FILE"
  sed -i "s/\"xver\": .*/\"xver\": 1,/" "$CONFIG_FILE"
else
  sed -i "s/\"target\": \".*\"/\"target\": \"$DOMAIN:443\"/" "$CONFIG_FILE"
fi
jq --arg dom "$DOMAIN" '(.. | select(has("serverNames")?)).serverNames = [$dom]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

# Step 8: 修改 "privateKey"
sed -i "s|\"privateKey\": \".*\"|\"privateKey\": \"$PRIVATE_KEY\"|" "$CONFIG_FILE"

# Step 9: 修改 "shortIds"
jq --arg sid "$SHORTID" '(.. | select(has("shortIds")?)).shortIds = [$sid]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

# Step 10: 修改 "path"
sed -i "s|\"path\": \"\"|\"path\": \"/$path\"|" "$CONFIG_FILE"

# Step 11: 修改 "domainStrategy" 字段
sed -i 's/"domainStrategy": "IPIfNonMatch"/"domainStrategy": "AsIs"/' "$CONFIG_FILE"


# Step 12: 替换 "id" 字段
sed -i "s|af7d5cf8-442d-4bb3-8a76-eb367178781d|$UUID1|" "$CONFIG_FILE"

# Step 13: 拆分配置文件，生成不同部分的单独文件
echo "正在拆分配置文件..."
for FIELD in log routing inbounds outbounds policy; do
	OUTPUT_FILE="${XRAY_CONFIG_DIR}/${FIELD}.json"

	# 对于对象类型（如 log、routing、policy），保留最外层的大括号
	if [ "$FIELD" == "log" ] || [ "$FIELD" == "routing" ] || [ "$FIELD" == "policy" ]; then
		jq ". | {${FIELD}: .${FIELD}}" "$CONFIG_FILE" > "$OUTPUT_FILE"
	# 对于数组类型（如 inbounds、outbounds），保留父级包裹结构
	elif [ "$FIELD" == "inbounds" ] || [ "$FIELD" == "outbounds" ]; then
		jq ". | {${FIELD}: .${FIELD}}" "$CONFIG_FILE" > "$OUTPUT_FILE"
	fi

	# 确保文件生成成功
	if [ ! -s "$OUTPUT_FILE" ]; then
		echo "拆分文件失败：$OUTPUT_FILE"
		exit 1
	fi

	echo "已生成拆分文件：$OUTPUT_FILE"
done

# 删除原始配置文件，因为已拆分
rm -f "$CONFIG_FILE"

# 重载并重启服务
systemctl daemon-reload
if systemctl restart xray; then
	echo "Xray 服务已成功重启"
else
	echo "Xray 服务重启失败"
	systemctl status xray
	exit 1
fi

# 如果选择偷自己，则安装 nginx 和申请 ssl 证书
if [ "$CHOICE" -eq 1 ]; then
	# 安装 nginx
	# 参见 https://docs.nginx.com/nginx/admin-guide/installing-nginx/installing-nginx-open-source/
	sudo apt install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring

	curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
		| sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

	gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg

	echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
	http://nginx.org/packages/mainline/debian `lsb_release -cs` nginx" \
		| sudo tee /etc/apt/sources.list.d/nginx.list


	echo "Package: *
	Pin: origin nginx.org
	Pin: release o=nginx
	Pin-Priority: 900" | sudo tee /etc/apt/preferences.d/99nginx

	apt update
	apt install -y nginx


	# 安装 acme.sh
	apt update && apt install -y socat
	curl https://get.acme.sh | sh -s email=my@example.com
 	# 设置为自动升级
	/root/.acme.sh/acme.sh --upgrade --auto-upgrade


	# 将默认的 zerossl 设置为 lets encrypt
	# /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

	# 申请证书。多域名 SAN模式，https://github.com/acmesh-official/acme.sh/wiki/How-to-issue-a-cert
	# DNS Cloudflare API， https://github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_cf

	if systemctl is-active --quiet nginx; then
		sudo systemctl stop nginx
	fi


	read -p "请输入 Cloudflare 用户 ID: " CF_Account_ID
	read -p "请输入 Cloudflare DNS 令牌: " CF_Token
	export CF_Account_ID="$CF_Account_ID"
	export CF_Token="$CF_Token"

	/root/.acme.sh/acme.sh --issue --dns dns_cf -d $DOMAIN -d *.$DOMAIN --keylength ec-384

	mkdir -p /usr/local/etc/xray/ssl
	/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
		--cert-file /usr/local/etc/xray/ssl/${DOMAIN}.cer \
		--key-file /usr/local/etc/xray/ssl/${DOMAIN}.key \
		--fullchain-file /usr/local/etc/xray/ssl/${DOMAIN}.fullchain.cer \
		--reloadcmd "systemctl restart xray"

	if [ ! -f "/usr/local/etc/xray/ssl/${DOMAIN}.cer" ]; then
		echo "证书生成失败！"
		exit 1
	fi


	# Step 1: 创建 /etc/nginx/conf.d/reality.conf 文件
	NGINX_CONFIG_FILE="/etc/nginx/conf.d/reality.conf"

	# Step 2: 下载文件并提取配置
	curl -o "$NGINX_CONFIG_FILE" "https://raw.githubusercontent.com/syshut/newShell/refs/heads/main/server.conf"

	# Step 3: 替换端口
	sudo sed -i 's/88888/'"$RPORT"'/g' "$NGINX_CONFIG_FILE"

	# Step 4: 替换 server_name
	sudo sed -i "s|\bh2y\.example\.com\b|${DOMAIN} www.${DOMAIN}|g" "$NGINX_CONFIG_FILE"

	# Step 5: 获取 /etc/nginx/conf.d/default.conf 中的 root 指令内容并替换
	DEFAULT_CONF="/etc/nginx/conf.d/default.conf"
	NEW_ROOT=$(awk '/location \/ {/,/}/ {if ($1 == "root") print $2}' "$DEFAULT_CONF" | tr -d ';')
	# 检查是否成功提取到 root 值
	if [ -z "$NEW_ROOT" ]; then
		echo "Error: Could not find 'root' directive in $default_conf"
		exit 1
	fi
	echo "Extracted root: $NEW_ROOT"

	# 使用 sed 替换 reality.conf 文件中的 root 值
	sed -i "s|^\(\s*\)root .*;|\1root $NEW_ROOT;|" "$NGINX_CONFIG_FILE"

	# 确认修改成功
	if grep -q "root $NEW_ROOT;" "$NGINX_CONFIG_FILE"; then
		echo "Updated root directive in $NGINX_CONFIG_FILE to: $NEW_ROOT"
	else
		echo "Error: Failed to update root directive in $NGINX_CONFIG_FILE"
		exit 1
	fi

	# Step 6: 修改 ssl_certificate 和 ssl_certificate_key 路径
	sudo sed -i "s|^\(\s*ssl_certificate\s\+\)[^;]\+|\1/usr/local/etc/xray/ssl/${DOMAIN}.fullchain.cer|" "$NGINX_CONFIG_FILE"
	sudo sed -i "s|^\(\s*ssl_certificate_key\s\+\)[^;]\+|\1/usr/local/etc/xray/ssl/${DOMAIN}.key|" "$NGINX_CONFIG_FILE"

	curl -o "${NEW_ROOT}/index.html" https://raw.githubusercontent.com/syshut/myShell/refs/heads/main/netdisk.html

	# Step 7: 修改路径
	sed -i 's|location /VLSpdG9k|location /'"$path"'|g' "$NGINX_CONFIG_FILE"

	# Step 8: 修改端口
	sudo sed -i 's/99999/'"$PORT"'/g' "$NGINX_CONFIG_FILE"

<<'EDIT_NGINX_CONFIG'
	config_file="/etc/nginx/nginx.conf"

	# 检查文件是否存在
	if [ ! -f "$config_file" ]; then
	    echo "错误: 配置文件 $config_file 不存在"
	    exit 1
	fi

	# 使用 sed 在 http { 之前插入内容
	sed -i "/^http {/i\
	stream {\\
	    server {\\
	        listen ${PORT} udp reuseport;\\
	        listen [::]:${PORT} udp reuseport;\\
	        proxy_pass 127.0.0.1:${RPORT};\\
	        proxy_timeout 20s;\\
	    }\\
	}\\
	\\
	" "$config_file"

	sed -i 's/\$remote_addr/\$client_ip/g' "$config_file"

	sed -i '0,/\$client_ip/{
	    /\$client_ip/{
	        i\
	    #创建自定义变量 $client_ip 获取客户端真实 IP，其配置如下：\
	    map $http_x_forwarded_for $client_ip {\
	        "" $remote_addr;\
	        "~*(?P<firstAddr>([0-9a-f]{0,4}:){1,7}[0-9a-f]{1,4}|([0-9]{1,3}\\.){3}[0-9]{1,3})$" $firstAddr;\
	    }\

	    }
	}' "$config_file"
EDIT_NGINX_CONFIG

	systemctl restart nginx && systemctl restart xray
fi

# 输出分享链接
IP=$(curl -s https://api.ipify.org || curl -s https://icanhazip.com)

echo "分享链接：vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&insecure=0&allowInsecure=0&type=xhttp&host=www.$DOMAIN&path=%2F$path&mode=packet-up& &extra=%7B%22downloadSettings%22%3A%7B%22address%22%3A%22$DOMAIN%22%2C%22port%22%3A$PORT%2C%22network%22%3A%22xhttp%22%2C%22security%22%3A%22reality%22%2C%22realitySettings%22%3A%7B%22serverName%22%3A%22$DOMAIN%22%2C%22publicKey%22%3A%22$PUBLIC_KEY%22%2C%22shortId%22%3A%22$SHORTID%22%2C%22spiderX%22%3A%22%22%2C%22fingerprint%22%3A%22chrome%22%7D%2C%22xhttpSettings%22%3A%7B%22path%22%3A%22%2F$path%22%2C%22mode%22%3A%22stream-one%22%7D%7D%7D#$REMARKS"
