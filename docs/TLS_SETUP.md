# TLS/HTTPS Setup Guide for zhttpd

## Overview

zhttpd uses the high-performance httpz library as its HTTP server core. Since httpz is optimized for performance and does not include native TLS/SSL support, HTTPS connections should be handled through TLS termination at a reverse proxy.

This is actually a **best practice** for production deployments because:

1. **Separation of concerns** - The web server focuses on application logic while the reverse proxy handles encryption
2. **Better performance** - Dedicated TLS handling with hardware acceleration
3. **Easier certificate management** - Centralized certificate handling
4. **Enhanced security** - Reverse proxies provide additional security features (DDoS protection, WAF, etc.)

## Recommended Architecture

```
                    ┌─────────────────┐
    HTTPS (443)     │  Reverse Proxy  │     HTTP (8080)
Client ──────────►  │  (nginx/Caddy)  │  ──────────────► zhttpd
                    │  TLS Termination│
                    └─────────────────┘
```

## Option 1: nginx (Recommended for Production)

### Installation

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install nginx

# RHEL/CentOS
sudo yum install nginx
```

### Configuration

Create `/etc/nginx/sites-available/zhttpd`:

```nginx
# Redirect HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name example.com www.example.com;
    
    # ACME challenge for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com www.example.com;

    # SSL Certificate (Let's Encrypt)
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    
    # Modern TLS configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # HSTS (HTTP Strict Transport Security)
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    
    # Proxy settings
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        
        # Preserve client IP
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        
        # WebSocket support
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Buffering
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
    }
    
    # Health check bypass (for load balancers)
    location /health {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        access_log off;
    }
}
```

### Enable the site

```bash
sudo ln -s /etc/nginx/sites-available/zhttpd /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

## Option 2: Caddy (Automatic HTTPS)

Caddy automatically handles Let's Encrypt certificates, making it the easiest option for TLS setup.

### Installation

```bash
# Ubuntu/Debian
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

### Configuration

Create `/etc/caddy/Caddyfile`:

```
example.com {
    # Automatic HTTPS with Let's Encrypt
    
    # Reverse proxy to zhttpd
    reverse_proxy localhost:8080 {
        # WebSocket support
        header_up Upgrade {http.request.header.Upgrade}
        header_up Connection {http.request.header.Connection}
        
        # Health checks
        health_uri /health
        health_interval 30s
    }
    
    # HSTS
    header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    
    # Security headers (zhttpd already adds these, but extra layer doesn't hurt)
    header X-Content-Type-Options nosniff
    header X-Frame-Options SAMEORIGIN
    
    # Logging
    log {
        output file /var/log/caddy/access.log
    }
}
```

### Start Caddy

```bash
sudo systemctl enable caddy
sudo systemctl start caddy
```

Caddy will automatically obtain and renew Let's Encrypt certificates!

## Option 3: HAProxy (Load Balancing + TLS)

For high-traffic deployments with multiple zhttpd instances.

### Configuration

```haproxy
global
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    tune.ssl.default-dh-param 2048

frontend https_frontend
    bind *:443 ssl crt /etc/ssl/private/example.com.pem
    mode http
    
    # HSTS
    http-response set-header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    
    # Forward real IP
    option forwardfor
    http-request set-header X-Forwarded-Proto https
    
    default_backend zhttpd_backend

backend zhttpd_backend
    mode http
    balance roundrobin
    option httpchk GET /health
    
    server zhttpd1 127.0.0.1:8080 check
    server zhttpd2 127.0.0.1:8081 check
    server zhttpd3 127.0.0.1:8082 check
```

## Let's Encrypt Certificate Management

### Using Certbot (for nginx)

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Obtain certificate
sudo certbot --nginx -d example.com -d www.example.com

# Test auto-renewal
sudo certbot renew --dry-run
```

### Certificate renewal automation

Certbot automatically adds a cron job or systemd timer. To verify:

```bash
# Check systemd timer
sudo systemctl status certbot.timer

# Or check crontab
sudo crontab -l
```

## Security Best Practices

### 1. TLS Configuration

- Use TLS 1.2 or 1.3 only (disable older versions)
- Use strong cipher suites (ECDHE-based)
- Enable OCSP stapling
- Enable HTTP/2 for better performance

### 2. HSTS (HTTP Strict Transport Security)

Always enable HSTS with a long max-age:

```
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
```

### 3. Certificate Transparency

Use Certificate Transparency logs to detect rogue certificates.

### 4. Certificate Pinning (Advanced)

For high-security applications, consider HPKP (deprecated) or Certificate Transparency.

## zhttpd Configuration for Behind Proxy

When running behind a reverse proxy, configure zhttpd to trust proxy headers:

```yaml
# zhttpd.yaml
host: "127.0.0.1"  # Only listen locally
port: 8080
security_headers: true  # Still enable security headers
```

## Testing Your TLS Configuration

### SSL Labs Test

Visit https://www.ssllabs.com/ssltest/ and enter your domain for a comprehensive TLS assessment.

### Command-line testing

```bash
# Check certificate
openssl s_client -connect example.com:443 -servername example.com

# Check cipher suites
nmap --script ssl-enum-ciphers -p 443 example.com

# Check HSTS
curl -sI https://example.com | grep -i strict
```

## Troubleshooting

### Certificate issues

```bash
# Check certificate expiry
echo | openssl s_client -connect example.com:443 2>/dev/null | openssl x509 -noout -dates

# Verify certificate chain
openssl s_client -connect example.com:443 -showcerts
```

### Connection issues

```bash
# Test backend connectivity
curl -v http://127.0.0.1:8080/health

# Check nginx logs
sudo tail -f /var/log/nginx/error.log
```

## See Also

- [OWASP TLS Best Practices](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html)
- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
