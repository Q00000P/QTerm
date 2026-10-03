namespace QTermWin.Terminal;

/// <summary>Словарь популярных команд (канон мака/андроида, ~170, под его стек).</summary>
public static class CommandDict
{
    public static readonly string[] Common =
    {
        "ls -la", "cd", "pwd", "cat", "less", "tail -f", "head", "grep -r", "find / -name",
        "df -h", "du -sh", "free -m", "top", "htop", "ps aux", "kill", "killall", "pkill",
        "uname -a", "uptime", "whoami", "id", "date", "history", "clear", "exit", "reboot",
        "shutdown -h now", "mount", "umount", "lsblk", "fdisk -l", "dmesg", "journalctl -u",
        "journalctl -f", "systemctl status", "systemctl restart", "systemctl stop",
        "systemctl start", "systemctl enable", "systemctl disable", "systemctl daemon-reload",
        "service", "crontab -e", "crontab -l", "chmod +x", "chmod 600", "chmod 644",
        "chmod 755", "chown -R", "ln -s", "cp -r", "mv", "rm -rf", "mkdir -p", "touch",
        "tar -xzf", "tar -czf", "unzip", "zip -r", "gzip", "gunzip", "scp", "rsync -avz",
        "wget", "curl -O", "curl -I", "curl -s", "ssh", "ssh-keygen -t ed25519",
        "ssh-copy-id", "sftp", "ping", "ping -c 4", "traceroute", "mtr", "dig", "dig +short",
        "nslookup", "host", "whois", "ip a", "ip r", "ip link", "ip -6 a", "ss -tulpn",
        "ss -s", "netstat -tulpn", "arp -a", "ifconfig", "route -n", "tcpdump -i",
        "nft list ruleset", "iptables -L -n -v", "iptables -t nat -L -n", "ufw status",
        "ufw allow", "wg show", "wg-quick up", "wg-quick down", "awg show",
        "xray run -config", "xray version", "x-ui", "x-ui status", "x-ui restart",
        "systemctl restart xray", "systemctl status xray", "mihomo -d", "xkeen -restart",
        "xkeen -status", "opkg update", "opkg install", "opkg list-installed", "opkg remove",
        "apt update", "apt upgrade -y", "apt install -y", "apt remove", "apt autoremove",
        "apt search", "dpkg -l", "dnf install", "yum install", "pacman -S",
        "docker ps", "docker ps -a", "docker images", "docker logs -f", "docker exec -it",
        "docker restart", "docker stop", "docker rm", "docker rmi", "docker compose up -d",
        "docker compose down", "docker compose logs -f", "docker compose pull",
        "docker system prune -af", "git status", "git pull", "git push", "git add .",
        "git commit -m", "git log --oneline", "git diff", "git clone", "git checkout",
        "git branch", "git stash", "git reset --hard", "nginx -t", "nginx -s reload",
        "systemctl restart nginx", "certbot renew", "certbot certificates",
        "unbound-checkconf", "unbound-control status", "unbound-control reload",
        "systemctl restart unbound", "systemctl restart AdGuardHome", "AdGuardHome -s restart",
        "nano", "vi", "vim", "mc", "tmux", "tmux attach", "screen -r", "watch -n 1",
        "which", "whereis", "type", "alias", "export", "env", "echo $PATH", "source ~/.bashrc",
        "hostnamectl", "timedatectl", "localectl", "loginctl", "last", "w", "who",
        "passwd", "useradd -m", "usermod -aG", "visudo", "sudo -i", "su -",
        "fail2ban-client status", "sshd -t", "systemctl restart sshd",
    };
}
