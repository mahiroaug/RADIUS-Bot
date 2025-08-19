#!/bin/bash
# Generate self-signed certificates for development
set -e

CERT_DIR="/etc/freeradius/3.0/certs"

# Generate CA private key
openssl genrsa -out ca.key 4096

# Generate CA certificate
openssl req -new -x509 -days 365 -key ca.key -out ca.pem -subj "/C=JP/ST=Tokyo/L=Tokyo/O=RadiusDev/CN=RadiusCA"

# Generate server private key
openssl genrsa -out server.key 2048

# Generate server certificate request
openssl req -new -key server.key -out server.csr -subj "/C=JP/ST=Tokyo/L=Tokyo/O=RadiusDev/CN=radius.local"

# Generate server certificate signed by CA
openssl x509 -req -days 365 -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem

# Generate DH parameters
openssl dhparam -out dh 2048

# Set permissions
chmod 600 *.key
chmod 644 *.pem *.csr dh

echo "Certificates generated successfully!"
ls -la
