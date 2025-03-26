# HAProxy Load Balancer for Microsoft Exchange

## Overview
Enterprise-grade HAProxy configuration optimized for Microsoft Exchange deployments with NTLM authentication support.

## Critical Requirements
### Certificate Configuration
❗ **Identical SSL certificates required** on both HAProxy and Exchange servers for proper NTLM handshake

**Solutions:**
1. **SSL Pass-Through** (TCP mode) - Preserves end-to-end encryption
2. **Certificate Mirroring** - Use same certificate on HAProxy and Exchange

## Deployment Specifications
**Current Environment (2025-03-26):**
```bash
# OS
NAME="AlmaLinux"
VERSION="8.10 (Cerulean Leopard)"

# HAProxy
HAProxy 3.1.5-076df02 (2025/02/20)
EOL: Q1 2026
```

## Build from source using RPM builder
```bash
git clone https://github.com/philyuchkoff/HAProxy-3-RPM-builder
```
## Copy and Validate config
```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```
## Runtime control
```bash
sudo systemctl restart haproxy
sudo journalctl -u haproxy -f
```

## Certbot
```bash
sudo certbot renew --dry-run
```
## Use update_cert.sh for create pem cert for https
```bash
sudo nano /etc/haproxy/update_cert.sh
sudo chmod +x /etc/haproxy/update_cert.sh
sudo /etc/haproxy/update_cert.sh
```

>Update the HAProxy configuration file
  >> sed -i "s|bind \*:443 ssl crt .*|bind \*:443 ssl crt ${COMBINED_CERT} alpn h2,http/1.1|g" "${HAPROXY_CFG}"
  log "info" "Updated HAProxy configuration file."

## 
```bash
echo | openssl s_client -connect IP_HAPROXY:443 -servername IP_HAPROXY: 2>/dev/null | openssl x509 -outform PEM -out internal.pem
echo | openssl s_client -connect IP_EXCH:443 -servername IP_EXCH 2>/dev/null | openssl x509 -outform PEM -out external.pem
# Compare fingerprints
openssl x509 -noout -fingerprint -sha256 -in internal.pem
openssl x509 -noout -fingerprint -sha256 -in external.pem
# Check Subject Alternative Names
openssl x509 -noout -text -in internal.pem | grep -A1 "Subject Alternative Name"
openssl x509 -noout -text -in external.pem | grep -A1 "Subject Alternative Name"
```
## Must be identical
```bash
SHA256 Fingerprint=10:CD:39:===:03:19:AA:19
SHA256 Fingerprint=10:CD:39:===:03:19:AA:19
            X509v3 Subject Alternative Name:
                DNS:autodiscover.SITE.com, DNS:mail.SITE.com
            X509v3 Subject Alternative Name:
                DNS:autodiscover.SITE.com, DNS:mail.SITE.com
```

## Verify
```bash
# Verify certificate consistency
openssl x509 -noout -modulus -in cert.pem | openssl md5
# Test MAPI connectivity
curl -v -k --ntlm -u 'DOMAIN\user' https://mail.site.com/mapi/
```

## Rsyslog
```bash
sudo systemctl status rsyslog
sudo nano /etc/rsyslog.d/49-haproxy.conf
sudo systemctl restart rsyslog.service
```