#甬哥x-ui脚本改良一键版

#1、申请证书并放到CERT_BASE="/root/ygkkkca"

#参数【ziyuming】就是vps要绑定的子域名

curl -fsSL "https://raw.githubusercontent.com/pixian5/ygxui/main/1%E7%94%B3%E8%AF%B7%E8%AF%81%E4%B9%A6%E5%88%B0%E5%8B%87%E5%93%A5%E7%9B%AE%E5%BD%95.sh" -o step1.sh
bash step1.sh ziyuming

#2、自动下载x-ui备份，备份里已经填好了证书、用户名、密码、路径

curl -fsSL "https://raw.githubusercontent.com/pixian5/ygxui/main/%E5%86%8D%E5%AE%89%E8%A3%85%E7%94%AC%E5%93%A5xui.sh" -o step2.sh

bash step2.sh

